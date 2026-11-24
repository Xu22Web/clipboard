#Requires -Version 5.1
<#
  tools\bundler\bundler.ps1 - build a bundle out of the module list cli.ini names.

      cli bundle -Inspect              say which modules a bundle cannot inline
      cli bundle -Entry core           build one entry
      cli bundle -Entry core -Config x.ini
      cli bundle -Entry core -From x.cs -Out y.dll    the same entry, another source

  A bundle is one file made of several modules. The stages are the ones a front-end bundler has,
  and each is a plugin under plugins\ so an entry only borrows the ones its product lists:

      resolve       which files, in which order                 (cli.ini [entry.*])
      treeshake     which definitions a load-time path reaches   (the AST)
      renderModule  minify and rename one module, original names (tools\utils\minify.ps1)
      merge         the modules as one text, statement by statement through the AST
      renderChunk   one pass over the glued text
      verify        read the bundle back and compare it with its modules

  The rule that shapes all of it: a module boundary is a parser node, never a line of text.
  Nothing here searches for "function", splits on blank lines or replaces a comment marker.

  Driving it from the package build and from the watcher is a later step: today the package
  build still walks cli.ini [build] Includes, and this tool builds the entries cli.ini
  declares so the merge can be proved before the package layout changes.
#>
param(
  [string]$Entry = '',
  [string]$Config = '',
  [string]$Out = '',
  # the root file of a C# entry, or the modules of a bundle, when a caller compiles a copy of
  # the same source somewhere else (the test suite builds a client out of a temp src tree)
  [string]$From = '',
  [switch]$All,
  [switch]$Worker,
  [switch]$Inspect,
  [switch]$Suggest,
  [switch]$Quiet,
  [switch]$Silent
)

$ErrorActionPreference = 'Stop'
# this file lives in tools\bundler\: the tooling is one level up, the repository two
$here = Split-Path -Parent $PSCommandPath
$tools = Split-Path -Parent $here
$root = Split-Path -Parent $tools

. (Join-Path $tools 'utils\console.ps1')
Set-LogLevelFrom -Quiet:$Quiet -Silent:$Silent
foreach ($tool in @('utils\ini.ps1', 'utils\schema.ps1', 'utils\minify.ps1', 'utils\csc.ps1')) {
  $toolPath = Join-Path $tools $tool
  if (-not (Test-Path -LiteralPath $toolPath)) { Write-Fail ('missing: ' + $toolPath); exit 1 }
  . $toolPath
}
foreach ($lib in @('ast', 'graph', 'emit', 'surface')) {
  $libPath = Join-Path $here ('lib\' + $lib + '.ps1')
  if (-not (Test-Path -LiteralPath $libPath)) { Write-Fail ('missing: ' + $libPath); exit 1 }
  . $libPath
}

# ---------------------------------------------------------------- settings
# The configuration is the repository's one config file, cli.ini, the way a vite project keeps
# its entries and plugins in vite.config. This script is the engine that reads that file (rollup
# behind the config), and `-Config` exists so a test can point it at a copy without touching the
# repository's own.
if (-not $Config) { $Config = Join-Path $root 'cli.ini' }
if (-not (Test-Path -LiteralPath $Config)) { Write-Fail ('missing settings file: ' + $Config); exit 1 }
$cfg = Import-IniMap $Config
$problems = @(Test-ToolConfigMap (Import-ToolSchema (Join-Path $tools 'schema\cli.ps1')) $cfg (Split-Path -Leaf $Config))
if ($problems.Count -gt 0) {
  foreach ($p in $problems) { Write-Fail $p }
  exit 1
}

# a bundler key is written inside [build] like every other switch of a build
function Cfg([string]$key) {
  foreach ($candidate in @(('build.' + $key), $key)) {
    if ($cfg.ContainsKey($candidate)) { return [string]$cfg[$candidate] }
  }
  return ''
}

function CfgBool([string]$key) {
  return @('1', 'true', 'yes', 'on') -contains (Cfg $key).ToLowerInvariant()
}

# an entry may override a bundler default; "" means "use the default"
function EntryValue([string]$name, [string]$key) {
  $flat = 'entry.' + $name + '.' + $key
  if ($cfg.ContainsKey($flat)) { return ([string]$cfg[$flat]).Trim() }
  return ''
}

function EntryBool([string]$name, [string]$key, [bool]$default) {
  $raw = EntryValue $name $key
  if (-not $raw) { return $default }
  return @('1', 'true', 'yes', 'on') -contains $raw.ToLowerInvariant()
}

# the entry names, in the order cli.ini declares them
function Get-EntryNames {
  $out = New-Object System.Collections.Generic.List[string]
  $seen = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  # a hashtable has no order, so the document is read again for its keys: the order an entry is
  # built in (and its log printed in) is the one the file writes, not whatever the table yields
  $ordered = @($cfg.Keys)
  try { $ordered = @((Read-IniDoc ([IO.File]::ReadAllLines($Config, [Text.Encoding]::UTF8))).Keys) } catch { }
  foreach ($k in $ordered) {
    $key = [string]$k
    if (-not $key.StartsWith('entry.', [StringComparison]::Ordinal)) { continue }
    $rest = $key.Substring(6)
    $dot = $rest.IndexOf('.')
    if ($dot -lt 1) { continue }
    $name = $rest.Substring(0, $dot)
    if ($seen.Add($name)) { $out.Add($name) }
  }
  return $out.ToArray()
}

# the product names, in the order cli.ini declares them
function Get-ProductNames {
  $out = New-Object System.Collections.Generic.List[string]
  $seen = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  foreach ($k in @($cfg.Keys)) {
    $key = [string]$k
    if (-not $key.StartsWith('product.', [StringComparison]::Ordinal)) { continue }
    $rest = $key.Substring(8)
    $dot = $rest.IndexOf('.')
    if ($dot -lt 1) { continue }
    $name = $rest.Substring(0, $dot)
    if ($seen.Add($name)) { $out.Add($name) }
  }
  return $out.ToArray()
}

function Get-RelativePath([string]$full) {
  $base = $root.TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($base.Length) }
  return $full
}

# ---------------------------------------------------------------- plugins
# cli.ini names a chain per product; every plugin file declares one $Plugin table with a
# Name and the hooks it supplies.
#
# The files are loaded HERE, at the script's own scope, once. A plugin that is dot-sourced
# inside a function hands back scriptblocks bound to that function's frame, and PowerShell 5.1
# then fails to bind arguments to them after the function has returned (ArgumentException, with
# no frame of its own to point at) - so the load has to happen where it is safe.
$script:ProductHooks = @{}
$script:ProductChains = @{}
foreach ($productName in @(Get-ProductNames)) {
  $chain = ''
  foreach ($candidate in @(('product.' + $productName + '.Chain'), ('product.' + $productName))) {
    if ($cfg.ContainsKey($candidate)) { $chain = [string]$cfg[$candidate]; break }
  }
  if (-not $chain) { Write-Fail ('[product.' + $productName + '] has no Chain='); exit 1 }
  $hooks = @{}
  $names = New-Object System.Collections.Generic.List[string]
  $dir = Join-Path $here 'plugins'
  foreach ($one in @($chain -split '[,;]')) {
    $name = $one.Trim()
    if (-not $name) { continue }
    $found = @(Get-ChildItem -LiteralPath $dir -File -Filter ('*-' + $name + '.ps1') | Sort-Object Name)
    if ($found.Count -ne 1) {
      Write-Fail ('plugin "' + $name + '" matched ' + $found.Count + ' file(s) under tools\bundler\plugins')
      exit 1
    }
    . $found[0].FullName
    if ($null -eq $Plugin -or $null -eq $Plugin.Hooks) {
      Write-Fail ('plugin file has no $Plugin table: ' + $found[0].Name)
      exit 1
    }
    foreach ($k in @($Plugin.Hooks.Keys)) { $hooks[[string]$k] = $Plugin.Hooks[$k] }
    if (-not $names.Contains($name)) { $names.Add($name) }
  }
  $script:ProductHooks[$productName] = $hooks
  $script:ProductChains[$productName] = ($names -join ', ')
}

# one detail line, the way tools\build.ps1 prints its settings: a short label in one column and
# the value beside it, so a run reads as a block of facts under its step
function Write-Field([string]$label, [string]$value) {
  Write-Note ($label.PadRight(9) + $value)
}

function Get-BundleChain([string]$product) {
  if ($script:ProductChains.ContainsKey($product)) { return $script:ProductChains[$product] }
  return ''
}

function Get-BundleHooks([string]$product) {
  if (-not $script:ProductHooks.ContainsKey($product)) { throw ('no [product.' + $product + '] in ' + (Split-Path -Leaf $Config)) }
  return $script:ProductHooks[$product]
}

function Test-BundleHook($hooks, [string]$stage) {
  if (-not $hooks.ContainsKey($stage)) { throw ('stage "' + $stage + '" has no plugin in the chain') }
}

# ---------------------------------------------------------------- inspect
# Every module a bundle could be asked to take, and the first thing that would stop it. This is
# the list to read before writing a module list for an entry.
function Invoke-BundleInspect {
  $sw = Start-Step
  Write-Step 'inspect src'
  $srcRoot = Join-Path $root 'src'
  $files = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Filter '*.ps1' | Sort-Object FullName)
  $good = 0
  $entryOnly = New-Object System.Collections.Generic.List[string]
  $bad = New-Object System.Collections.Generic.List[string]
  $opaque = New-Object System.Collections.Generic.List[string]
  foreach ($f in $files) {
    $rel = Get-RelativePath $f.FullName
    $parsed = Get-BundleParse ([IO.File]::ReadAllText($f.FullName))
    $reason = Get-BundleRejectReason $parsed
    if ($reason) {
      # a param block or a #Requires line is fine in the one file whose header survives
      if (-not (Get-BundleRejectReason $parsed -Entry)) {
        $entryOnly.Add(('  {0,-44} {1}' -f $rel, ('only as the entry: ' + $reason)))
        continue
      }
      $bad.Add(('  {0,-44} {1}' -f $rel, $reason))
      continue
    }
    $good++
    $why = @(Test-BundleOpaque $parsed.Ast | Select-Object -Unique)
    if ($why.Count -gt 0) { $opaque.Add(('  {0,-44} {1}' -f $rel, ($why -join '; '))) }
  }
  Write-Text ''
  Write-Note ('  can be inlined     ' + $good)
  Write-Note ('  only as an entry   ' + $entryOnly.Count)
  foreach ($line in $entryOnly) { Write-Text $line }
  Write-Note ('  cannot be inlined  ' + $bad.Count)
  foreach ($line in $bad) { Write-Text $line }
  Write-Note ('  calls no name can follow  ' + $opaque.Count)
  foreach ($line in $opaque) { Write-Text $line }

  # the declared surface: which modules say what they need, and what the rest of the code needs
  # from them. A module that is called from somewhere else but exports nothing is the shape a
  # #@export line is missing, so -Suggest prints the list to paste in.
  $records = New-Object System.Collections.Generic.List[object]
  foreach ($f in $files) {
    $rel = Get-RelativePath $f.FullName
    $parsed = Get-BundleParse ([IO.File]::ReadAllText($f.FullName))
    if (Get-BundleRejectReason $parsed) { continue }
    $decl = Get-BundleDirectives $parsed
    $records.Add(@{
        Id        = (Get-BundleModuleId $root $f.FullName)
        Rel       = $rel
        Ast       = $parsed.Ast
        Functions = @(Get-BundleFunctionNames $parsed.Ast)
        Uses      = @($decl.Uses)
        Exports   = @($decl.Exports)
      })
  }
  $surface = Get-BundleSurfaceReport $records.ToArray()
  Write-Note ('  declare edges      ' + $surface.Declared + ' of ' + $surface.Total + ' module(s), ' + $surface.Edges + ' cross-module call(s)')
  foreach ($p in @($surface.Problems)) { Write-Fail $p }
  if ($Suggest) {
    Write-Text ''
    Write-Title '  suggested directives (what other modules call, and what this one calls elsewhere)'
    # one pass to build the sets: walking every AST once per pair made this quadratic and slow
    $funcSets = @{}
    $cmdSets = @{}
    $owners = @{}
    foreach ($r in $records) {
      $fs = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
      foreach ($name in @($r.Functions)) {
        [void]$fs.Add($name)
        $key = $name.ToLowerInvariant()
        if ($owners.ContainsKey($key)) { $owners[$key] = @($owners[$key]) + @([string]$r.Id) } else { $owners[$key] = @([string]$r.Id) }
      }
      $funcSets[[string]$r.Id] = $fs
      $cs = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
      foreach ($name in @(Get-BundleCommandNames $r.Ast)) { [void]$cs.Add($name) }
      $cmdSets[[string]$r.Id] = $cs
    }
    # a name is called from elsewhere when another module's command set holds it
    $called = @{}
    foreach ($r in $records) {
      foreach ($name in @($cmdSets[[string]$r.Id])) {
        $key = $name.ToLowerInvariant()
        if ($owners.ContainsKey($key)) { $called[$key] = $true }
      }
    }
    foreach ($r in $records) {
      $id = [string]$r.Id
      $exported = New-Object System.Collections.Generic.List[string]
      foreach ($name in @($r.Functions)) {
        if (-not $called.ContainsKey($name.ToLowerInvariant())) { continue }
        if (-not $exported.Contains($name)) { $exported.Add($name) }
      }
      $uses = New-Object System.Collections.Generic.List[string]
      foreach ($name in @($cmdSets[$id])) {
        if ($funcSets[$id].Contains($name)) { continue }
        $key = $name.ToLowerInvariant()
        if (-not $owners.ContainsKey($key)) { continue }
        foreach ($owner in @($owners[$key])) {
          if ($owner -eq $id) { continue }
          if (-not $uses.Contains($owner)) { $uses.Add($owner) }
        }
      }
      if ($exported.Count -eq 0 -and $uses.Count -eq 0) { continue }
      Write-Text ('  ' + $id)
      if ($exported.Count -gt 0) { Write-Text ('      #@export ' + ($exported -join ', ')) }
      if ($uses.Count -gt 0) { Write-Text ('      #@use ' + ($uses -join ', ')) }
    }
  }
  Write-Done $sw ('inspected ' + $files.Count + ' module(s)')
}

# ---------------------------------------------------------------- one C# entry
# The source list comes from the root file's #part lines; the compiler is given that list and
# nothing else. A product with no source is not a smaller product, so both stages are required.
function Invoke-BundleCompile([string]$name) {
  $product = EntryValue $name 'Product'
  $to = EntryValue $name 'To'
  $from = EntryValue $name 'From'
  if (-not $product) { throw ('entry ' + $name + ' has no Product=') }
  if (-not $to) { throw ('entry ' + $name + ' has no To=') }
  # -From names the root file of another copy of the same source; without it the entry's own
  # From= is used, resolved against the repository root
  if ($From) { $from = $From }
  if (-not $from) { throw ('entry ' + $name + ' has no From=') }
  $append = @()
  foreach ($one in @((EntryValue $name 'Append') -split '[,;]')) {
    $oneGlob = $one.Trim()
    if ($oneGlob) { $append += $oneGlob }
  }

  $outPath = $to
  if ([IO.Path]::IsPathRooted($Out)) { $outPath = $Out }
  elseif ($Out) { $outPath = Join-Path $root $Out }
  elseif (-not [IO.Path]::IsPathRooted($outPath)) { $outPath = Join-Path $root $outPath }

  $hooks = Get-BundleHooks $product
  foreach ($stage in @('part', 'compile')) { Test-BundleHook $hooks $stage }
  $ctx = @{
    Root  = $root
    Tmp   = $env:TEMP
    Entry = @{
      Name       = $name
      Product    = $product
      From       = $from
      Append     = $append
      Target     = (EntryValue $name 'Target')
      References = @()
      Out        = $outPath
    }
  }

  $sw = Start-Step
  Write-Step ('compile ' + $name)
  $target = 'library'
  if ($ctx.Entry.Target) { $target = $ctx.Entry.Target }
  Write-Field 'product' ($product + '   target ' + $target + '   optimize on')
  Write-Field 'output' (Get-RelativePath $outPath)
  $rootShown = $from
  if (-not [IO.Path]::IsPathRooted($rootShown)) { $rootShown = Join-Path $root $rootShown }
  Write-Field 'root' (Get-RelativePath $rootShown)
  Write-Field 'plugins' (Get-BundleChain $product)
  $files = @(& $hooks['part'] $ctx)
  $result = & $hooks['compile'] $ctx $files
  $kb = [Math]::Round($result.Bytes / 1024, 1)
  Write-Done $sw ('compiled ' + (Split-Path -Leaf $outPath) + '   ' + $kb + ' KB   ' + $result.Files + ' file(s)')
}

# ---------------------------------------------------------------- one entry
function Invoke-BundleEntry([string]$name) {
  $kind = EntryValue $name 'Kind'
  if ($kind -eq 'cs') { Invoke-BundleCompile $name; return }
  $product = EntryValue $name 'Product'
  $to = EntryValue $name 'To'
  if (-not $product) { throw ('entry ' + $name + ' has no Product=') }
  if (-not $to) { throw ('entry ' + $name + ' has no To=') }
  $modules = @()
  foreach ($one in @((EntryValue $name 'Modules') -split '[,;]')) {
    $rel = $one.Trim()
    if ($rel) { $modules += $rel }
  }
  if ($modules.Count -eq 0) { throw ('entry ' + $name + ' has no Modules=') }
  $keep = @()
  foreach ($one in @((EntryValue $name 'Keep') -split '[,;]')) {
    $oneKey = $one.Trim()
    if ($oneKey) { $keep += $oneKey }
  }

  $options = @{
    Minify    = EntryBool $name 'Minify' (CfgBool 'Minify')
    Rename    = EntryBool $name 'Rename' (CfgBool 'Rename')
    Treeshake = EntryBool $name 'Treeshake' (CfgBool 'Treeshake')
  }
  $hooks = Get-BundleHooks $product
  foreach ($stage in @('resolve', 'treeshake', 'renderModule', 'merge', 'renderChunk', 'verify')) {
    Test-BundleHook $hooks $stage
  }

  $ctx = @{
    Root    = $root
    Tmp     = $null
    Maps    = $null
    Options = $options
    Entry   = @{ Name = $name; Product = $product; Modules = $modules; Keep = $keep; To = $to }
  }

  $sw = Start-Step
  Write-Step ('bundle ' + $name)
  Write-Field 'product' ($product + '   minify ' + $(if ($options.Minify) { 'yes' } else { 'no' }) + '   rename ' + $(if ($options.Rename) { 'yes' } else { 'no' }) + '   treeshake ' + $(if ($options.Treeshake) { 'yes' } else { 'no' }))
  Write-Field 'entry' ($to)
  Write-Field 'plugins' (Get-BundleChain $product)

  $tmpRoot = Join-Path $env:TEMP ('bundle-' + $name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
  $ctx.Tmp = $tmpRoot
  try {
    $paths = @(& $hooks['resolve'] $ctx)
    $sourceBytes = 0
    foreach ($one in $paths) { $sourceBytes += (Get-Item -LiteralPath $one).Length }
    $mods = New-Object System.Collections.Generic.List[object]
    foreach ($p in $paths) {
      $rel = Get-RelativePath $p
      $parsed = Get-BundleParse ([IO.File]::ReadAllText($p))
      $reason = Get-BundleRejectReason $parsed
      if ($reason) { throw ($rel + ' ' + $reason + ' - a bundle cannot inline it') }
      $decl = Get-BundleDirectives $parsed
      $mods.Add(@{
          Path        = $p
          Rel         = $rel
          Id          = (Get-BundleModuleId $root $p)
          Ast         = $parsed.Ast
          Functions   = @(Get-BundleFunctionNames $parsed.Ast)
          Uses        = @($decl.Uses)
          Exports     = @($decl.Exports)
          Opaque      = @(Test-BundleOpaque $parsed.Ast)
          BlockInvoke = (Test-BundleBlockInvoke $parsed.Ast)
          Kept        = $null
          Dropped     = @()
        })
    }
    Write-Field 'modules' ([string]$mods.Count + ' module(s)')

    # the declared import and export lists are checked before anything is rendered: a call to
    # something a module does not export is a mistake in the list, not in the output
    $surface = Get-BundleSurfaceReport $mods.ToArray()
    Write-Field 'surface' ('' + $surface.Declared + ' of ' + $surface.Total + ' module(s) declare edges   ' + $surface.Edges + ' cross-module call(s)   ' + $surface.Exported + ' export(s)')
    foreach ($w in @($surface.Warnings)) { Write-Warn $w }
    if (@($surface.Problems).Count -gt 0) {
      foreach ($p in @($surface.Problems)) { Write-Fail $p }
      throw ('entry ' + $name + ' does not match its declared imports and exports')
    }
    if (@($surface.Unused).Count -gt 0 -and $surface.Declared -eq $surface.Total) {
      Write-Note ('would drop   ' + (@($surface.Unused) -join ', ') + ' (nothing declares an edge to it)')
    } elseif ($surface.Declared -lt $surface.Total) {
      # a module with no declaration may well be the only caller of another one, so the
      # answer would be a guess: it is reported only when every module says what it needs
      Write-Note ('would drop   not known: ' + ($surface.Total - $surface.Declared) + ' module(s) declare no edges')
    }

    # a generic List must never be wrapped in @(): this PowerShell 5.1 throws an
    # ArgumentException for that, with no frame to point at. The list goes in as an array.
    $mods = @(& $hooks['treeshake'] $ctx $mods.ToArray())
    $mods = @(& $hooks['renderModule'] $ctx $mods)
    $chunk = & $hooks['merge'] $ctx $mods
    # the description the finished text has to match is taken before the last pass
    $expected = @{ Functions = $chunk.Functions; Commands = $chunk.Commands; Shapes = $chunk.Shapes }
    $before = ([string]$chunk.Text).Length
    $chunk = & $hooks['renderChunk'] $ctx $chunk
    $report = & $hooks['verify'] $ctx $expected ([string]$chunk.Text)

    $outDir = Cfg 'OutDir'
    if (-not $outDir) { $outDir = 'dist' }
    $outRoot = $outDir
    if (-not [IO.Path]::IsPathRooted($outRoot)) { $outRoot = Join-Path $root $outRoot }
    $outPath = Join-Path $outRoot $to
    $outParent = Split-Path -Parent $outPath
    if (-not (Test-Path -LiteralPath $outParent)) { New-Item -ItemType Directory -Path $outParent -Force | Out-Null }
    $overwrite = CfgBool 'Overwrite'
    if ((Test-Path -LiteralPath $outPath) -and -not $overwrite) { throw ('already exists: ' + $outPath) }
    [IO.File]::WriteAllText($outPath, [string]$chunk.Text, (New-Object System.Text.UTF8Encoding $false))

    $dropped = 0
    foreach ($m in $mods) { $dropped += @($m.Dropped).Count }
    $after = ([string]$chunk.Text).Length
    $fromSource = 0
    if ($sourceBytes -gt 0) { $fromSource = [Math]::Round(100 * (1 - $after / $sourceBytes)) }

    # the per-module rows tools\build.ps1 prints for a package: what each file was, what it
    # became, and one total that says the same number the finished file has
    if ($options.Minify -or $options.Rename) {
      Write-Text ''
      foreach ($m in $mods) {
        $was = [int]$m.SizeBefore
        $now = [int]$m.SizeAfter
        $pct = 0
        if ($was -gt 0) { $pct = [Math]::Round(100 * (1 - $now / $was)) }
        Write-Text ('  {0,-30} {1,8} -> {2,7}  ({3}%)' -f ([string]$m.Id), $was, $now, $pct)
      }
      Write-Text ('  {0,-30} {1,8} -> {2,7}  ({3}%)' -f 'total', $sourceBytes, $after, $fromSource)
      Write-Text ''
    }
    Write-Field 'verify' ('' + $report.Functions + ' definition(s)   ' + $report.Shapes + ' statement(s)   ' + $report.Commands + ' command(s)   ' + $dropped + ' dropped')
    Write-Done $sw ('bundled ' + $name + '   ' + $after + ' bytes   ' + $mods.Count + ' module(s)')
  } finally {
    if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

# ---------------------------------------------------------------- main
if ($Inspect) {
  Invoke-BundleInspect
  exit 0
}
# ---------------------------------------------------------------- every entry, side by side
# One entry is one process: the renderer bundles and the C# products share nothing but this
# script, and a worker that dies takes only its own entry with it. A worker writes its output
# where the serial build would, so a parallel run and a serial one leave the same tree behind.
# The logs are printed in the order cli.ini declares the entries, so a parallel build reads
# like a serial one afterwards.
function Invoke-BundleMany($all, [int]$workers) {
  $sw = Start-Step
  Write-Step ('bundle ' + $all.Count + ' entries')
  Write-Field 'entries' ($all -join ', ')
  Write-Field 'workers' ([string]$workers)
  $logs = @{}
  $running = @{}
  $queue = New-Object System.Collections.Generic.Queue[string]
  foreach ($n in $all) { $queue.Enqueue($n) }
  $failed = New-Object System.Collections.Generic.List[string]
  while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($queue.Count -gt 0 -and $running.Count -lt $workers) {
      $n = $queue.Dequeue()
      $log = Join-Path $env:TEMP ('bundle-' + $n + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
      $logs[$n] = $log
      $workerArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Entry', $n, '-Worker')
      if ($Config) { $workerArgs += @('-Config', $Config) }
      if ($Out) { $workerArgs += @('-Out', $Out) }
      if ($Quiet) { $workerArgs += @('-Quiet') }
      $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $workerArgs -NoNewWindow -PassThru -RedirectStandardOutput $log
      # without this the process object never reads its exit code back and every worker looks
      # like it failed - measured on this PowerShell: ExitCode stays empty after HasExited
      $proc.EnableRaisingEvents = $true
      $running[$n] = $proc
    }
    Start-Sleep -Milliseconds 120
    foreach ($n in @($running.Keys)) {
      if (-not $running[$n].HasExited) { continue }
      if ($running[$n].ExitCode -ne 0) { $failed.Add([string]$n) }
      $running.Remove($n)
    }
  }
  foreach ($n in $all) {
    $text = ''
    if ($logs.ContainsKey($n) -and (Test-Path -LiteralPath $logs[$n])) { $text = [IO.File]::ReadAllText($logs[$n]) }
    foreach ($line in @($text -split "`r?`n")) { if ($line.Trim()) { Write-Raw $line } }
    if ($logs.ContainsKey($n)) { Remove-Item -LiteralPath $logs[$n] -Force -ErrorAction SilentlyContinue }
  }
  if ($failed.Count -gt 0) {
    foreach ($n in $failed) { Write-Fail ('entry ' + $n + ' failed') }
    Write-Done $sw ('built ' + ($all.Count - $failed.Count) + ' of ' + $all.Count + ' entr(y/ies)')
    return $false
  }
  Write-Done $sw ('built ' + $all.Count + ' entr(y/ies)   ' + $workers + ' worker(s)')
  return $true
}

# ---------------------------------------------------------------- main
$names = @(Get-EntryNames)
if ($All) {
  if ($names.Count -eq 0) { Write-Fail ('no [entry.*] in ' + (Split-Path -Leaf $Config)); exit 1 }
  $workers = 0
  $raw = Cfg 'Workers'
  if ($raw) { [void][int]::TryParse($raw, [ref]$workers) }
  if ($workers -le 0) { $workers = [Environment]::ProcessorCount }
  if ($workers -gt $names.Count) { $workers = $names.Count }
  if ($workers -le 1) {
    $ok = $true
    foreach ($n in $names) {
      try { Invoke-BundleEntry $n } catch { Write-Fail $_.Exception.Message; $ok = $false }
    }
    if (-not $ok) { exit 1 }
    exit 0
  }
  if (Invoke-BundleMany $names $workers) { exit 0 }
  exit 1
}
if (-not $Entry) {
  if ($names.Count -eq 1) {
    $Entry = $names[0]
  } else {
    Write-Fail ('no -Entry given; ' + (Split-Path -Leaf $Config) + ' declares: ' + ($names -join ', ') + '   (use -All)')
    exit 1
  }
}
if ($names -notcontains $Entry) {
  Write-Fail ('no [entry.' + $Entry + '] in ' + (Split-Path -Leaf $Config) + '   (declared: ' + ($names -join ', ') + ')')
  exit 1
}
try {
  Invoke-BundleEntry $Entry
} catch {
  Write-Fail $_.Exception.Message
  # a localized message says nothing useful in a console with another code page, so the type and
  # the line that threw are printed as well - they are ASCII and always readable
  Write-Note ([string]$_.Exception.GetType().FullName)
  if ($_.InvocationInfo) { Write-Note ([string]$_.InvocationInfo.PositionMessage) }
  if ($_.ScriptStackTrace) { Write-Note ([string]$_.ScriptStackTrace) }
  exit 1
}
exit 0

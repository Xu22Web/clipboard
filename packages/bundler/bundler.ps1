#Requires -Version 5.1
<#
  packages\bundler\bundler.ps1 - build one target, or every target, out of a resolved input.

      bundler.ps1 -TargetFile x.json -Entry renderer      one target by name
      bundler.ps1 -TargetFile x.json -All                 every target, side by side
      bundler.ps1 -TargetFile x.json -Entry preload -From y.cs -Out z.dll
      bundler.ps1 -Inspect                                say which modules cannot be inlined

  A bundle is one file made of several modules. The stages are the ones a front-end bundler has,
  and each is a plugin under plugins\ so a target only borrows the ones its Plugins= lists:

      resolve       which files, in which order                  (the target file)
      treeshake     which definitions a load-time path reaches   (the AST)
      renderModule  minify and rename one module, original names (utils\minify.ps1)
      merge         the modules as one text, statement by statement through the AST
      renderChunk   one pass over the glued text
      verify        read the bundle back and compare it with its modules

  The rule that shapes all of it: a module boundary is a parser node, never a line of text.
  Nothing here searches for "function", splits on blank lines or replaces a comment marker.

  This file reads no configuration. packages\cli resolves cli.ini and writes the target file;
  a JSON document with Root, OutDir, Workers and a Targets list is the whole of this file's
  input, which is the same split rolldown keeps from vite.
#>
param(
  # the resolved input: { Root, OutDir, Workers, Targets: [...] }
  [string]$TargetFile = '',
  # one target of that file, by name; without it -All is required
  [string]$Entry = '',
  [string]$Out = '',
  # the root file of a C# target, or the modules of a bundle, when a caller compiles a copy of
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
$packages = Split-Path -Parent $here
$root = Split-Path -Parent $packages

# this package is a tool of its own: it loads the copies under its own utils\, so a change made
# for the release script cannot change how a bundle is parsed, and the other way round
. (Use-Module './utils/console.ps1' $PSCommandPath -Named Set-LogLevelFrom, Start-Step, Write-Done, Write-Fail, Write-Note, Write-Raw, Write-Step, Write-Text, Write-Title, Write-Warn)
Set-LogLevelFrom -Quiet:$Quiet -Silent:$Silent
. (Use-Module './utils/ini.ps1' $PSCommandPath)
. (Use-Module './utils/minify.ps1' $PSCommandPath)
. (Use-Module './utils/csc.ps1' $PSCommandPath)
. (Use-Module './utils/globs.ps1' $PSCommandPath -Named Expand-Glob)
. (Use-Module './lib/ast.ps1' $PSCommandPath -Named Get-BundleCommandNames, Get-BundleFunctionNames, Get-BundleParse, Get-BundleRejectReason, Test-BundleBlockInvoke, Test-BundleOpaque)
. (Use-Module './lib/graph.ps1' $PSCommandPath)
. (Use-Module './lib/emit.ps1' $PSCommandPath)
. (Use-Module './lib/surface.ps1' $PSCommandPath -Named Get-BundleDirectives, Get-BundleModuleId, Get-BundleSurfaceReport)
. (Use-Module './lib/chunk.ps1' $PSCommandPath -Named Format-BundleOutput, Get-BundleChunkDefault, Get-BundleHash, Split-BundleChunks)

# ---------------------------------------------------------------- the target file
# What to build arrives as a document, not as a config file: packages\cli reads cli.ini, decides
# the chain, the sources, the output path and the three rewrite switches, and writes them here.
# That is the split rolldown keeps from vite - the engine is handed a resolved input and knows
# nothing about the file it came from.
#
#   { "Root": "...", "OutDir": "dist", "Workers": 0,
#     "Targets": [ { "Name", "Kind", "Plugins", "Input", "Output", "External", "Target",
#                    "Minify", "Rename", "Treeshake" } ] }
#
# A value that is absent means "not given": Kind empty is a script target, Output empty is an
# error the target reports, Minify/Rename/Treeshake false is the engine default.
$script:Spec = $null
if ($TargetFile) {
  if (-not (Test-Path -LiteralPath $TargetFile)) { Write-Fail ('missing target file: ' + $TargetFile); exit 1 }
  $script:Spec = [IO.File]::ReadAllText($TargetFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
  if ($script:Spec.Root) { $root = [string]$script:Spec.Root }
}

# one key of one target, trimmed; "" when the target does not name it
function TargetValue($target, [string]$key) {
  if ($null -eq $target) { return '' }
  $v = $target.$key
  if ($null -eq $v) { return '' }
  return ([string]$v).Trim()
}

function TargetBool($target, [string]$key, [bool]$default) {
  $raw = TargetValue $target $key
  if (-not $raw) { return $default }
  return @('1', 'true', 'yes', 'on') -contains $raw.ToLowerInvariant()
}

# The alias table of one target: resolve.alias in a vite config, a name and the folder it stands
# for. A #@use id that starts with a name is expanded before the module is looked up, so a module
# can be named by the short form the config declares instead of its path under src\.
function Get-TargetAlias($target) {
  $out = @{}
  if ($null -eq $target) { return $out }
  $value = $target.Alias
  if ($null -eq $value -or -not ($value -is [System.Collections.IDictionary])) { return $out }
  foreach ($k in @($value.Keys)) {
    $name = ([string]$k).Trim()
    $dir = ([string]$value[$k]).Trim().TrimEnd([char]92, [char]47)
    if ($name -and $dir) { $out[$name] = $dir }
  }
  return $out
}

# one key of one target read as a list: a JSON array keeps its items, a comma separated string is
# split. Both shapes appear because a config may write either.
function TargetList($target, [string]$key) {
  $out = New-Object System.Collections.Generic.List[string]
  if ($null -eq $target) { return $out.ToArray() }
  $value = $target.$key
  if ($null -eq $value) { return $out.ToArray() }
  foreach ($one in @($value)) {
    foreach ($part in @(([string]$one) -split '[,;]')) {
      $item = $part.Trim()
      if ($item) { $out.Add($item) }
    }
  }
  return $out.ToArray()
}

# the entries of one target: an input table as a name and a path each. A plain string list is
# accepted as well, with the file name standing in for the key.
function TargetEntries($target) {
  $out = New-Object System.Collections.Generic.List[object]
  if ($null -eq $target) { return $out.ToArray() }
  $value = $target.Entries
  if ($null -eq $value) { return $out.ToArray() }
  foreach ($one in @($value)) {
    if ($null -eq $one) { continue }
    $name = ''
    $path = ''
    if ($one -is [string]) { $path = ([string]$one).Trim() }
    else { $name = ([string]$one.Name).Trim(); $path = ([string]$one.Path).Trim() }
    if (-not $path) { continue }
    if (-not $name) { $name = [IO.Path]::GetFileNameWithoutExtension($path) }
    $out.Add(@{ Name = $name; Path = $path })
  }
  return $out.ToArray()
}

# the targets to build, in the order the caller wrote them
function Get-SpecTargets {
  if ($null -eq $script:Spec) { return @() }
  return @($script:Spec.Targets)
}

# the folder an output lands in when the target names no absolute path
function Get-SpecOutDir {
  $outDir = 'dist'
  if ($null -ne $script:Spec -and $script:Spec.OutDir) { $outDir = [string]$script:Spec.OutDir }
  if ([IO.Path]::IsPathRooted($outDir)) { return $outDir }
  return (Join-Path $root $outDir)
}

function Get-RelativePath([string]$full) {
  $base = $root.TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($base.Length) }
  return $full
}

# OutDir is disposable: a build owns the folder under it that its Output= names, so every run
# starts from an empty one. A chunk's file name carries its content hash, so a name left by an
# earlier build would otherwise sit beside the new one for good - the same rule electron's outDir
# follows. Only a path inside OutDir is cleared: an absolute Output= or -Out names a file that
# belongs to whoever wrote it.
function Reset-SpecOutPath([string]$path) {
  if (-not $path) { return }
  $outDir = Get-SpecOutDir
  $full = $path
  if (-not [IO.Path]::IsPathRooted($full)) { $full = Join-Path $outDir $full }
  $full = [IO.Path]::GetFullPath($full)
  $base = $outDir.TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
    # what vite says about an outDir outside the project root: it is not emptied, and the run
    # does not pretend otherwise
    Write-Warn ('Output= ' + (Get-RelativePath $full) + ' is outside ' + (Get-RelativePath $outDir) + ': that folder is not cleared')
    return
  }
  $under = $full.Substring($base.Length)
  # Output= names the file and the folder above it; that folder is the part the build owns
  $cut = $under.IndexOfAny([char[]]@([char]92, [char]47))
  if ($cut -lt 1) { return }
  $folder = Join-Path $outDir $under.Substring(0, $cut)
  if (-not (Test-Path -LiteralPath $folder)) { return }
  Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
  Write-Note ('cleared ' + (Get-RelativePath $folder))
}

# ---------------------------------------------------------------- plugins
# every target names its chain in Plugins=; every plugin file declares one $Plugin table with a
# Name and the hooks it supplies.
#
# Every file is loaded HERE, at the script's own scope, once. A plugin that is dot-sourced
# inside a function hands back scriptblocks bound to that function's frame, and PowerShell 5.1
# then fails to bind arguments to them after the function has returned (ArgumentException, with
# no frame of its own to point at) - so the load has to happen where it is safe.
$script:PluginHooks = @{}
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $here 'plugins') -File -Filter '*.ps1' | Sort-Object Name)) {
  $Plugin = $null
  . $file.FullName
  if ($null -eq $Plugin -or $null -eq $Plugin.Hooks) {
    Write-Fail ('plugin file has no $Plugin table: ' + $file.Name)
    exit 1
  }
  # the name is what follows the leading number: "50-cs-part" is the plugin "cs-part"
  $pluginName = [IO.Path]::GetFileNameWithoutExtension($file.Name)
  $dash = $pluginName.IndexOf('-')
  if ($dash -ge 0) { $pluginName = $pluginName.Substring($dash + 1) }
  $script:PluginHooks[$pluginName] = $Plugin.Hooks
}

# one detail line, the way tools\build.ps1 prints its settings: a short label in one column and
# the value beside it, so a run reads as a block of facts under its step
function Write-Field([string]$label, [string]$value) {
  Write-Note ($label.PadRight(9) + $value)
}

function Get-BundleChain([string]$chain) {
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($one in @($chain -split '[,;]')) {
    $n = $one.Trim()
    if ($n -and -not $names.Contains($n)) { $names.Add($n) }
  }
  return ($names -join ', ')
}

# the hooks of one chain, in the order the chain names them
function Get-BundleHooks([string]$chain) {
  if (-not $chain) { throw 'the target names no Plugins=' }
  $hooks = @{}
  foreach ($one in @($chain -split '[,;]')) {
    $name = $one.Trim()
    if (-not $name) { continue }
    if (-not $script:PluginHooks.ContainsKey($name)) {
      throw ('no plugin named "' + $name + '" under packages\bundler\plugins')
    }
    foreach ($k in @($script:PluginHooks[$name].Keys)) { $hooks[[string]$k] = $script:PluginHooks[$name][$k] }
  }
  return $hooks
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
  $surface = Get-BundleSurfaceReport $records.ToArray() $null $null
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

# ------------------------------------------------------------------ one C# target
# The source list comes from the root file's #part lines; the compiler is given that list and
# nothing else. A target with no source is not a smaller product, so both stages are required.
function Invoke-BundleCompile($t) {
  $name = TargetValue $t 'Name'
  $to = TargetValue $t 'Output'
  $from = TargetValue $t 'Input'
  if (-not $to) { throw ('target ' + $name + ' has no Output=') }
  # -From names the root file of another copy of the same source; without it the target's own
  # Input= is used, resolved against the repository root
  if ($From) { $from = $From }
  if (-not $from) { throw ('target ' + $name + ' has no Input=') }
  $append = @()
  foreach ($one in @((TargetValue $t 'Append') -split '[,;]')) {
    $oneGlob = $one.Trim()
    if ($oneGlob) { $append += $oneGlob }
  }

  $outPath = $to
  if ([IO.Path]::IsPathRooted($Out)) { $outPath = $Out }
  elseif ($Out) { $outPath = Join-Path $root $Out }
  # a cs target without -Out lands under OutDir at the path it declares, the same way a script
  # target does (the relative path is the package path, not a repository path)
  elseif (-not [IO.Path]::IsPathRooted($outPath)) { $outPath = Join-Path (Get-SpecOutDir) $outPath }

  $chain = TargetValue $t 'Plugins'
  $hooks = Get-BundleHooks $chain
  foreach ($stage in @('part', 'compile')) { Test-BundleHook $hooks $stage }
  $ctx = @{
    Root  = $root
    Tmp   = $env:TEMP
    Entry = @{
      Name       = $name
      Product    = $chain
      From       = $from
      Append     = $append
      Target     = (TargetValue $t 'Target')
      References = @()
      Out        = $outPath
    }
  }

  $sw = Start-Step
  Write-Step ('compile ' + $name)
  $target = 'library'
  if ($ctx.Entry.Target) { $target = $ctx.Entry.Target }
  Write-Field 'chain' ($chain + '   target ' + $target + '   optimize on')
  Write-Field 'output' (Get-RelativePath $outPath)
  $rootShown = $from
  if (-not [IO.Path]::IsPathRooted($rootShown)) { $rootShown = Join-Path $root $rootShown }
  Write-Field 'root' (Get-RelativePath $rootShown)
  Write-Field 'plugins' (Get-BundleChain $chain)
  # the target's folder under OutDir is rebuilt from scratch; -Out names a file elsewhere
  if (-not $Out) { Reset-SpecOutPath $outPath }
  $files = @(& $hooks['part'] $ctx)
  $result = & $hooks['compile'] $ctx $files
  $kb = [Math]::Round($result.Bytes / 1024, 1)
  Write-Done $sw ('compiled ' + (Split-Path -Leaf $outPath) + '   ' + $kb + ' KB   ' + $result.Files + ' file(s)')
}

# ---------------------------------------------------------------- one target
# one set of files as the module objects every stage works on
# A module is parsed once and reused: the resolver has already read every candidate, and a chunk
# render that read the file again would repeat that work for every piece. The cache lives on the
# run ($ctx.Mods), so a module object is shared by the pieces that mention it and by no one else.
function New-BundleModules([string]$root, [string[]]$paths, $cache = $null) {
  $mods = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($paths)) {
    $key = [IO.Path]::GetFullPath([string]$p).ToLowerInvariant()
    if ($cache -and $cache.ContainsKey($key)) { $mods.Add($cache[$key]); continue }
    $rel = Get-RelativePath $p
    $parsed = Get-BundleParse ([IO.File]::ReadAllText($p))
    $reason = Get-BundleRejectReason $parsed
    if ($reason) { throw ($rel + ' ' + $reason + ' - a bundle cannot inline it') }
    $decl = Get-BundleDirectives $parsed
    $mod = @{
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
      }
    if ($cache) { $cache[$key] = $mod }
    $mods.Add($mod)
  }
  return , $mods.ToArray()
}

# one chunk through the rewrite stages: the text it becomes, and the proof that it still is the
# modules it was made of
function New-BundleChunkText($ctx, $hooks, $mods) {
  $work = @(& $hooks['treeshake'] $ctx $mods)
  $work = @(& $hooks['renderModule'] $ctx $work)
  $piece = & $hooks['merge'] $ctx $work
  # the description the finished text has to match is taken before the last pass
  $expected = @{ Functions = $piece.Functions; Commands = $piece.Commands; Shapes = $piece.Shapes }
  $before = ([string]$piece.Text).Length
  $piece = & $hooks['renderChunk'] $ctx $piece
  $report = & $hooks['verify'] $ctx $expected ([string]$piece.Text)
  return @{
    Mods   = $work
    Text   = [string]$piece.Text
    Report = $report
    Before = $before
    After  = ([string]$piece.Text).Length
  }
}

function Invoke-BundleEntry($t) {
  $name = TargetValue $t 'Name'
  $kind = TargetValue $t 'Kind'
  if ($kind -eq 'cs') { Invoke-BundleCompile $t; return }
  $to = TargetValue $t 'Output'
  if (-not $to) { throw ('target ' + $name + ' has no Output=') }
  # a chunk more than one entry loads has its own template, the way rolldown separates
  # entryFileNames from chunkFileNames; without one the default is '[name]-[hash]' in the folder
  # and extension the entry template names
  $toChunk = TargetValue $t 'ChunkOutput'
  if (-not $toChunk) { $toChunk = Get-BundleChunkDefault $to }
  $modules = @()
  foreach ($one in @((TargetValue $t 'Input') -split '[,;]')) {
    $rel = $one.Trim()
    if (-not $rel) { continue }
    # Input= takes globs as well as names: a pattern is expanded where it is written, and the
    # files it matches keep the order the pattern gives them
    if ($rel -match '[*?]') {
      $hits = @(Expand-Glob $root $rel)
      if ($hits.Count -eq 0) { throw ('target ' + $name + ' Input= matched no file: ' + $rel) }
      # the resolver joins each name to the repository root, so an absolute hit is written back
      # as a path relative to it
      foreach ($hit in $hits) { $modules += (Get-RelativePath $hit) }
      continue
    }
    $modules += $rel
  }
  if ($modules.Count -eq 0 -and (TargetEntries $t).Count -eq 0) { throw ('target ' + $name + ' has no Input=') }
  $keep = @()
  foreach ($one in @((TargetValue $t 'Keep') -split '[,;]')) {
    $oneKey = $one.Trim()
    if ($oneKey) { $keep += $oneKey }
  }
  # modules the bundle does not carry: the #@use edges into them describe how the two files meet
  # at run time, and the Files list keeps them in the package as they are
  $externals = @()
  foreach ($one in @((TargetValue $t 'External') -split '[,;]')) {
    $oneKey = ($one.Trim()) -replace '\\', '/'
    if ($oneKey) { $externals += $oneKey }
  }

  # the caller has already merged its defaults into these three, so the engine's own answer is
  # "no" for all of them
  $options = @{
    Minify    = (TargetBool $t 'Minify' $false)
    Rename    = (TargetBool $t 'Rename' $false)
    Treeshake = (TargetBool $t 'Treeshake' $false)
  }
  $chain = TargetValue $t 'Plugins'
  $hooks = Get-BundleHooks $chain
  foreach ($stage in @('resolve', 'treeshake', 'renderModule', 'merge', 'renderChunk', 'verify')) {
    Test-BundleHook $hooks $stage
  }

  # the paths of the entries, in the order the config wrote them; the multi-entry branch replaces
  # this per entry before each resolve
  $entryPaths = @()
  foreach ($one in @(TargetEntries $t)) { $entryPaths += [string]$one.Path }

  $ctx = @{
    Root    = $root
    Tmp     = $null
    Maps    = $null
    Mods    = @{}
    Options = $options
    Entry   = @{ Name = $name; Product = $chain; Modules = $modules; Keep = $keep; To = $to; Entries = $entryPaths; Scan = (TargetList $t 'Scan'); Alias = (Get-TargetAlias $t) }
  }

  $sw = Start-Step
  Write-Step ('bundle ' + $name)
  Write-Field 'chain' ($chain + '   minify ' + $(if ($options.Minify) { 'yes' } else { 'no' }) + '   rename ' + $(if ($options.Rename) { 'yes' } else { 'no' }) + '   treeshake ' + $(if ($options.Treeshake) { 'yes' } else { 'no' }))
  Write-Field 'entry' ($to)
  Write-Field 'plugins' (Get-BundleChain $chain)

  $tmpRoot = Join-Path $env:TEMP ('bundle-' + $name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
  $ctx.Tmp = $tmpRoot
  try {
    # ---------------------------------------------------------------- one chunk per entry
    # Every entry is resolved on its own, then the closures are split: a module more than one
    # entry reaches becomes the shared chunk, the rest stays with the entry that alone reaches it.
    # Each piece goes through the same stages, so a chunk is verified like any other bundle.
    $entryList = TargetEntries $t
    if ($entryList.Count -gt 0) {
      $entryNames = @{}
      foreach ($one in $entryList) { $entryNames[([string]$one.Name).ToLowerInvariant()] = $true }
      $toParent = Split-Path -Parent ([string]$to)
      $leaves = New-Object System.Collections.Generic.List[string]
      $closures = [ordered]@{}
      foreach ($one in $entryList) {
        $leaf = [string]$one.Name
        $leaves.Add($leaf)
        $ctx.Entry['Entries'] = @([string]$one.Path)
        $closures[$leaf] = @(& $hooks['resolve'] $ctx)
      }
      # rolldown's grouping: identical reachability sets form one chunk, and the pieces arrive in
      # the order they load in - the shared one first
      $split = Split-BundleChunks $closures
      $pieces = [ordered]@{}
      foreach ($piece in @($split.Pieces)) { $pieces[[string]$piece.Name] = @($piece.Files) }

      # a #@use into a module another piece carries is a boundary, not a missing file
      $idsByPiece = @{}
      foreach ($pieceName in @($pieces.Keys)) {
        $ids = New-Object System.Collections.Generic.List[string]
        foreach ($f in @($pieces[$pieceName])) { $ids.Add([string](Get-BundleModuleId $root $f)) }
        $idsByPiece[$pieceName] = $ids.ToArray()
      }

      $outRoot = Get-SpecOutDir
      # every chunk of this target lands under one folder, and the run owns all of it
      Reset-SpecOutPath $to
      # the name of a chunk changes with its content, so the loader reads the names from here
      # instead of hard-coding one that goes stale on the next edit
      $written = [ordered]@{}
      foreach ($pieceName in @($pieces.Keys)) {
        $files = @($pieces[$pieceName])
        $mods = New-BundleModules $root $files $ctx.Mods
        # a #@use into a module this piece does not carry is a boundary: one the target declared
        # as External, or one another chunk carries
        $others = New-Object System.Collections.Generic.List[string]
        foreach ($id in @($externals)) { $others.Add([string]$id) }
        foreach ($other in @($pieces.Keys)) {
          if ($other -eq $pieceName) { continue }
          foreach ($id in @($idsByPiece[$other])) { $others.Add([string]$id) }
        }
        $surface = Get-BundleSurfaceReport $mods $others.ToArray() (Get-TargetAlias $t)
        foreach ($w in @($surface.Warnings)) { Write-Warn $w }
        if (@($surface.Problems).Count -gt 0) {
          foreach ($p in @($surface.Problems)) { Write-Fail $p }
          throw ('target ' + $name + ' does not match its declared imports and exports')
        }

        $ctx.Entry['Entries'] = @()
        $result = New-BundleChunkText $ctx $hooks $mods
        $hash = Get-BundleHash $result.Text
        # an entry chunk keeps the entry's name; anything else is a chunk several entries load
        # and goes under the chunk template, which is where the shared pieces belong
        $isEntry = $entryNames.ContainsKey(([string]$pieceName).ToLowerInvariant())
        $template = $to
        if (-not $isEntry) { $template = $toChunk }
        $rel = Format-BundleOutput $template (( [string]$pieceName).ToLowerInvariant()) $hash
        $outPath = $rel
        if (-not [IO.Path]::IsPathRooted($outPath)) { $outPath = Join-Path $outRoot $rel }
        $outParent = Split-Path -Parent $outPath
        if (-not (Test-Path -LiteralPath $outParent)) { New-Item -ItemType Directory -Path $outParent -Force | Out-Null }
        [IO.File]::WriteAllText($outPath, $result.Text, (New-Object System.Text.UTF8Encoding $false))

        $droppedPiece = 0
        foreach ($m in @($result.Mods)) { $droppedPiece += @($m.Dropped).Count }
        $r = $result.Report
        # the manifest sits in the folder Output= names, so it holds paths from there: an entry
        # chunk is a file beside it, a shared chunk is one folder down under assets\
        $relFromManifest = $rel.Replace('\', '/')
        if ($toParent) {
          $prefix = $toParent.Replace('\', '/') + '/'
          if ($relFromManifest.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $relFromManifest = $relFromManifest.Substring($prefix.Length) }
        }
        $written[$pieceName] = $relFromManifest
        Write-Field $pieceName ([string](@($result.Mods).Count) + ' module(s)   ' + $result.After + ' bytes   ' + $hash)
        Write-Note ('  ' + $r.Functions + ' definition(s)   ' + $r.Shapes + ' statement(s)   ' + $r.Commands + ' command(s)   ' + $droppedPiece + ' dropped')
      }

      $manifestDir = $outRoot
      if ($toParent) { $manifestDir = Join-Path $outRoot $toParent }
      if (-not (Test-Path -LiteralPath $manifestDir)) { New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null }
      $manifestLines = New-Object System.Collections.Generic.List[string]
      $manifestLines.Add('[chunks]')
      foreach ($k in @($written.Keys)) { $manifestLines.Add(([string]$k + '=' + [string]$written[$k])) }
      # which source files each chunk already carries: a package leaves exactly these out, so a
      # module the windows share is shipped once - inside the chunk - and a base module that no
      # chunk carries keeps its own file
      $manifestLines.Add('[modules]')
      foreach ($k in @($written.Keys)) { $manifestLines.Add(([string]$k + '=' + (@($idsByPiece[$k]) -join ','))) }
      [IO.File]::WriteAllLines((Join-Path $manifestDir 'manifest.ini'), $manifestLines.ToArray(), (New-Object System.Text.UTF8Encoding $false))

      Write-Done $sw ('bundled ' + $name + '   ' + $pieces.Count + ' chunk(s)')
      return
    }

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
    $surface = Get-BundleSurfaceReport $mods.ToArray() $externals (Get-TargetAlias $t)
    Write-Field 'surface' ('' + $surface.Declared + ' of ' + $surface.Total + ' module(s) declare edges   ' + $surface.Edges + ' cross-module call(s)   ' + $surface.Exported + ' export(s)')
    foreach ($w in @($surface.Warnings)) { Write-Warn $w }
    if (@($surface.Problems).Count -gt 0) {
      foreach ($p in @($surface.Problems)) { Write-Fail $p }
      throw ('target ' + $name + ' does not match its declared imports and exports')
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

    $outRoot = Get-SpecOutDir
    # -Out names the file itself, which is what a caller staging a package needs: `cli build`
    # asks for the bundle where the package keeps it, not where a development run would. Without
    # it the file lands under OutDir at the path the target declares, and that folder is rebuilt.
    if ([IO.Path]::IsPathRooted($Out)) { $outPath = $Out }
    elseif ($Out) { $outPath = Join-Path $root $Out }
    else {
      $outPath = Join-Path $outRoot $to
      Reset-SpecOutPath $outPath
    }
    $outParent = Split-Path -Parent $outPath
    if (-not (Test-Path -LiteralPath $outParent)) { New-Item -ItemType Directory -Path $outParent -Force | Out-Null }
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
  $names = New-Object System.Collections.Generic.List[string]
  $byName = @{}
  foreach ($one in @($all)) {
    $n = TargetValue $one 'Name'
    $names.Add($n)
    $byName[$n] = $one
  }
  $sw = Start-Step
  Write-Step ('bundle ' + $names.Count + ' target(s)')
  Write-Field 'targets' ($names -join ', ')
  Write-Field 'workers' ([string]$workers)
  $logs = @{}
  $specs = @{}
  $running = @{}
  $queue = New-Object System.Collections.Generic.Queue[string]
  foreach ($n in $names) { $queue.Enqueue($n) }
  $failed = New-Object System.Collections.Generic.List[string]
  while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($queue.Count -gt 0 -and $running.Count -lt $workers) {
      $n = $queue.Dequeue()
      $tag = $n + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
      $log = Join-Path $env:TEMP ('bundle-' + $tag + '.log')
      $logs[$n] = $log
      # one target per worker, in a file of its own: a worker reads the shape the caller wrote
      $specFile = Join-Path $env:TEMP ('bundle-' + $tag + '.json')
      $specs[$n] = $specFile
      $doc = @{ Root = $root; OutDir = (Get-SpecOutDir); Workers = 1; Targets = @($byName[$n]) }
      [IO.File]::WriteAllText($specFile, ($doc | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
      $workerArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path (Split-Path -Parent $here) 'module\bin\module.ps1'), $PSCommandPath, '-TargetFile', $specFile, '-Worker')
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
  foreach ($n in $names) {
    $text = ''
    if ($logs.ContainsKey($n) -and (Test-Path -LiteralPath $logs[$n])) { $text = [IO.File]::ReadAllText($logs[$n]) }
    foreach ($line in @($text -split "`r?`n")) { if ($line.Trim()) { Write-Raw $line } }
    if ($logs.ContainsKey($n)) { Remove-Item -LiteralPath $logs[$n] -Force -ErrorAction SilentlyContinue }
    if ($specs.ContainsKey($n)) { Remove-Item -LiteralPath $specs[$n] -Force -ErrorAction SilentlyContinue }
  }
  if ($failed.Count -gt 0) {
    foreach ($n in $failed) { Write-Fail ('target ' + $n + ' failed') }
    Write-Done $sw ('built ' + ($names.Count - $failed.Count) + ' of ' + $names.Count + ' target(s)')
    return $false
  }
  Write-Done $sw ('built ' + $names.Count + ' target(s)   ' + $workers + ' worker(s)')
  return $true
}

# ---------------------------------------------------------------- main
$targets = @(Get-SpecTargets)
if ($All) {
  if ($targets.Count -eq 0) { Write-Fail ('no target in ' + (Split-Path -Leaf $TargetFile)); exit 1 }
  $workers = 0
  if ($null -ne $script:Spec -and $script:Spec.Workers) { [void][int]::TryParse([string]$script:Spec.Workers, [ref]$workers) }
  if ($workers -le 0) { $workers = [Environment]::ProcessorCount }
  if ($workers -gt $targets.Count) { $workers = $targets.Count }
  if ($workers -le 1) {
    $ok = $true
    foreach ($t in $targets) {
      try { Invoke-BundleEntry $t } catch { Write-Fail $_.Exception.Message; $ok = $false }
    }
    if (-not $ok) { exit 1 }
    exit 0
  }
  if (Invoke-BundleMany $targets $workers) { exit 0 }
  exit 1
}
if (-not $Entry) {
  if ($targets.Count -eq 1) {
    $Entry = TargetValue $targets[0] 'Name'
  } else {
    $declared = @($targets | ForEach-Object { TargetValue $_ 'Name' })
    Write-Fail ('no -Entry given; ' + (Split-Path -Leaf $TargetFile) + ' carries: ' + ($declared -join ', ') + '   (use -All)')
    exit 1
  }
}
$picked = @($targets | Where-Object { (TargetValue $_ 'Name') -eq $Entry })
if ($picked.Count -eq 0) {
  $declared = @($targets | ForEach-Object { TargetValue $_ 'Name' })
  Write-Fail ('no target named ' + $Entry + ' in ' + (Split-Path -Leaf $TargetFile) + '   (carried: ' + ($declared -join ', ') + ')')
  exit 1
}
try {
  Invoke-BundleEntry $picked[0]
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


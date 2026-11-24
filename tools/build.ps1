#Requires -Version 5.1
<#
  tools\build.ps1 - package the tool the way a front-end build packages a bundle: the
  output is still plain PowerShell, but every .ps1 is rewritten from its syntax tree
  (comments and indentation gone, internal functions and local variables renamed), so the
  folder keeps the same shape and behaviour while being noticeably smaller. The two C#
  products are compiled on the way in, so no .cs reaches the package when a compiler is
  around.

      cli build                          settings from cli.ini
      cli build -Config other.ini         a different settings file

  cli.ini holds the tooling settings: [build] is the output folder, whether to
  minify and rename, whether to verify the result by running the CLI suite against it,
  whether to also write a zip; [dev] and [test] belong to the other two commands. The
  version is not a build option: package.ini owns it. The development copy reads it
  at run time (src\lib\base.ps1); the build replaces that block with a literal, so a package
  carries the version and reads no file.

  Two batch files from scripts\ are copied next to the program's entry: install.bat (config
  init + migrate + install) and uninstall.bat (stop + uninstall purge).

  What goes in: the files cli.ini [copy] Includes names, and only those. Nothing here knows
  what a file is: tools\bundler\assets.ps1 holds one table - a .ps1 is minified, a .cmd/.bat
  compressed, a .sh compressed, an .ini stripped of its comments, a .cs under a product folder
  compiled - and this script only walks the list. The default list is the program scripts, the
  three launchers, the themes, the two batch helpers and the two product sources.
  What never goes in: src\data\, src\<name>.ini, tests\, tools\, dist\, .git - a package
  carries the program, not the history, the settings or the tooling.
#>
param(
  [string]$Config = '',
  # quiet keeps warnings and failures, silent keeps failures only
  [switch]$Quiet,
  [switch]$Silent
)

$ErrorActionPreference = 'Stop'
# this file lives in tools\: the repository root is one level up
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
# every tool prints its steps, warnings and failures the same way
. (Join-Path $root 'tools\utils\console.ps1')
Set-LogLevelFrom -Quiet:$Quiet -Silent:$Silent
# the program lives in src\, the build tooling and the docs stay at the repo root
$srcRoot = Join-Path $root 'src'
if (-not (Test-Path -LiteralPath $srcRoot)) { Fail ('missing: ' + $srcRoot) }

# Where a shipped file lands in the package: a file under src\ keeps the path it has there, a
# file outside src\ keeps the path it has under the repository root, and the rows in
# tools\bundler\assets.ps1 name the few that belong at the package root instead.
function Get-PackageRel([string]$file) {
  $full = [IO.Path]::GetFullPath($file)
  $srcFull = [IO.Path]::GetFullPath($srcRoot).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($srcFull, [StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($srcFull.Length) }
  $rootFull = [IO.Path]::GetFullPath($root).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
    $rel = $full.Substring($rootFull.Length)
    if (Test-Flatten $rel) { return (Split-Path -Leaf $full) }
    return $rel
  }
  return (Split-Path -Leaf $full)
}

# ---------------------------------------------------------------- settings
# cli.ini and package.ini are read by the tooling's own copy of the ini parser
# (tools\utils\ini.ps1): "Key=Value" per line, "#" or ";" comments, and a "[section]" line
# grouping the keys that follow - so "[build]" + "OutDir=dist" is the same key as
# "build.OutDir=dist". Nothing here loads a module out of src\: the tooling stands alone.
$iniTools = Join-Path $root 'tools\utils\ini.ps1'
if (-not (Test-Path -LiteralPath $iniTools)) { Fail ('missing: ' + $iniTools) }
. $iniTools

if (-not $Config) { $Config = Join-Path $root 'cli.ini' }
if (-not (Test-Path -LiteralPath $Config)) { Fail ('missing settings file: ' + $Config) }
$cfg = Import-IniMap $Config

# An entry marked Ship=1 is a package file rather than a check: its modules are merged into one
# script and the copy below leaves them out, so the package carries one copy of each.
$shipEntries = @{}
foreach ($entryKey in @($cfg.Keys)) {
  $entryMatch = [regex]::Match([string]$entryKey, '^entry\.([A-Za-z0-9_-]+)\.Ship$')
  if (-not $entryMatch.Success) { continue }
  if (@('1', 'true', 'yes', 'on') -notcontains ([string]$cfg[$entryKey]).ToLowerInvariant()) { continue }
  $entryName = $entryMatch.Groups[1].Value
  $shipTo = ([string]$cfg[('entry.' + $entryName + '.To')]) -replace '/', '\'
  if (-not $shipTo) { Fail ('[entry.' + $entryName + '] is Ship=1 but names no To=') }
  $shipMods = New-Object System.Collections.Generic.List[string]
  foreach ($one in @(([string]$cfg[('entry.' + $entryName + '.Modules')]) -split ',')) {
    $text = $one.Trim()
    if (-not $text) { continue }
    $shipMods.Add((($text -replace '^src/', '') -replace '/', '\'))
  }
  if ($shipMods.Count -eq 0) { Fail ('[entry.' + $entryName + '] is Ship=1 but lists no Modules=') }
  $shipEntries[$entryName] = @{ Rel = $shipTo; Modules = $shipMods.ToArray() }
}
$bundler = Join-Path $root 'tools\bundler\bundler.ps1'

# cli.ini is the only place a build setting may live. It is checked against
# tools\schema\cli.ps1 before anything else happens: a missing key, an unknown key, a value of
# the wrong type or a number outside its range stops the build with the list of problems, so a
# typo cannot turn into "the build quietly stopped minifying".
. (Join-Path $root 'tools\utils\schema.ps1')
$problems = @(Test-ToolConfigMap (Import-ToolSchema (Join-Path $root 'tools\schema\cli.ps1')) $cfg (Split-Path -Leaf $Config) 'build,copy')
if ($problems.Count -gt 0) {
  foreach ($p in $problems) { Write-Fail $p }
  exit 1
}

function Cfg([string]$key) {
  # a build key may be written inside [build] or with its dotted name at the top level.
  # The dotted name is built first: "@('build.' + $key, $key)" would join the two into one
  # string, because "," binds tighter than "+" inside an array literal.
  foreach ($candidate in @(('build.' + $key), $key)) {
    if ($cfg.ContainsKey($candidate)) { return [string]$cfg[$candidate] }
  }
  return ''
}

function CfgBool([string]$key) {
  return @('1', 'true', 'yes', 'on') -contains (Cfg $key).ToLowerInvariant()
}

# What a release carries is [copy], how it is produced is [build]: the copy list says which files
# ship and where they are read from, the build section says how each of them is rewritten. A key
# of the copy list may also be written with its dotted name at the top level, like a build one.
function CopyCfg([string]$key) {
  foreach ($candidate in @(('copy.' + $key), $key)) {
    if ($cfg.ContainsKey($candidate)) { return [string]$cfg[$candidate] }
  }
  return ''
}

function CopyCfgList([string]$key) {
  return @(Split-GlobList (CopyCfg $key))
}

# package.ini owns the version and the command shortcuts; the build only reads it here
$pkg = Import-IniMap (Join-Path $root 'package.ini')
$version = ''
foreach ($candidate in @('package.Version', 'Version')) {
  if ($pkg.ContainsKey($candidate) -and [string]$pkg[$candidate]) { $version = [string]$pkg[$candidate]; break }
}
$version = $version.Trim()
if (-not $version) { Fail 'no Version= in package.ini' }
$version = ($version -replace '[^0-9A-Za-z\.\-_]', '')
if ($version -notmatch '^\d+\.\d+\.\d+$') { Fail ('Version= in package.ini is not <major>.<minor>.<patch>: ' + $version) }

$app = ''
foreach ($candidate in @('package.Name', 'Name')) {
  if ($pkg.ContainsKey($candidate) -and [string]$pkg[$candidate]) { $app = ([string]$pkg[$candidate]).Trim(); break }
}
if (-not $app) { Fail 'no Name= in package.ini' }
$name = $app + '-' + $version
$outSetting = Cfg 'OutDir'
if (-not $outSetting) { Fail 'cli.ini [build] OutDir is empty' }
$outDir = if ([IO.Path]::IsPathRooted($outSetting)) { $outSetting } else { Join-Path $root $outSetting }
$dest = Join-Path $outDir $name
$minify = CfgBool 'Minify'
$rename = CfgBool 'Rename'
$verify = CfgBool 'Verify'
$overwrite = CfgBool 'Overwrite'
$wantZip = CfgBool 'Zip'
# the include and exclude lists use the same glob syntax, and the same splitter, as [dev]
. (Join-Path $root 'tools\utils\globs.ps1')
# What one file becomes, and which folder of C# becomes one file: both tables live beside the
# bundler, because a handler here does the same job as an entry there - several inputs, one
# output. The build reads them; it does not own them.
. (Join-Path $root 'tools\bundler\assets.ps1')
. (Join-Path $root 'tools\bundler\products.ps1')
# the handler for a kind of file is a file of its own under assets\
Initialize-AssetHandlers (Join-Path $root 'tools\bundler\assets')
$includeGlobs = CopyCfgList 'Includes'
$excludeGlobs = CopyCfgList 'Excludes'
# every glob is written relative to BaseUrl: "." keeps them at the repository root, so a shipped
# path reads like the one on disk (src\..., scripts\...)
$baseSetting = (CopyCfg 'BaseUrl').Trim()
if (-not $baseSetting) { Fail 'cli.ini [copy] BaseUrl is empty' }
$baseDir = Resolve-BaseDir $root $baseSetting
if (-not (Test-Path -LiteralPath $baseDir)) { Fail ('cli.ini [copy] BaseUrl does not exist: ' + $baseSetting) }

$swBuild = Start-Step
Write-Step ('build ' + $name)
Write-Note ('settings ' + (Split-Path -Leaf $Config) + '   version ' + $version + '   from package.ini')
Write-Note ('output   ' + $dest)
Write-Note ('minify   ' + $(if ($minify) { 'yes' } else { 'no' }) + '   rename ' + $(if ($rename) { 'yes' } else { 'no' }) + '   verify ' + $(if ($verify) { 'yes' } else { 'no' }) + '   zip ' + $(if ($wantZip) { 'yes' } else { 'no' }))
Write-Note ('files    ' + [string]$includeGlobs.Count + ' glob(s)   overwrite ' + $(if ($overwrite) { 'yes' } else { 'no' }))

if ((Test-Path -LiteralPath $dest) -and -not $overwrite) { Fail ('already exists: ' + $dest + '   (set Overwrite=1 to replace it)') }

# ---------------------------------------------------------------- the file list
# cli.ini [copy] Includes is the package and Excludes removes from it: one expansion for both,
# through the same call the watcher uses, so the two tools agree on what a glob means.
$pkgFiles = @(Expand-GlobList $baseDir $includeGlobs $excludeGlobs)
if ($pkgFiles.Count -eq 0) { Fail 'cli.ini [copy] Includes reaches no file' }
$dropped = @(Expand-GlobList $baseDir $includeGlobs @()).Count - $pkgFiles.Count
if ($dropped -gt 0) { Write-Note ('excluded ' + [string]$dropped + ' file(s) listed in cli.ini [copy] Excludes') }

# ---------------------------------------------------------------- shipped entries
# A shipped entry is merged here, before the rename tables are built: the bundle is one more
# script the package carries, so it has to be minified and renamed by the same tables as the
# files beside it. Two renamers - one in the bundler, one here - would hand the same short name
# to two different things, which is what a package cannot survive.
$shipProducts = @{}
if ($shipEntries.Count -gt 0) {
  $shipTmp = Join-Path $env:TEMP ('ships-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $shipTmp -Force | Out-Null
  foreach ($entryName in @($shipEntries.Keys | Sort-Object)) {
    $shipOne = $shipEntries[$entryName]
    $shipFile = Join-Path $shipTmp ($entryName + '.ps1')
    $swShip = Start-Step
    Write-Step ('bundling ' + $shipOne.Rel)
    $shipLog = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bundler -Entry $entryName -Out $shipFile 2>&1
    if (-not (Test-Path -LiteralPath $shipFile)) {
      foreach ($line in @($shipLog)) {
        $text = ([string]$line).Trim()
        if ($text) { Write-Note $text }
      }
      Fail ('the bundler wrote no ' + $shipOne.Rel + ' - a package cannot start without it')
    }
    $shipKb = [Math]::Round((Get-Item -LiteralPath $shipFile).Length / 1KB, 1)
    Write-Done $swShip ('merged ' + $shipOne.Rel + '   ' + $shipKb + ' KB')
    $shipProducts[$shipFile] = $shipOne.Rel
  }
}
# what a shipped entry already carries as one file: those modules are neither copied nor renamed
$shipSources = @{}
foreach ($entryName in @($shipEntries.Keys)) {
  foreach ($one in @($shipEntries[$entryName].Modules)) { $shipSources[([string]$one).ToLowerInvariant()] = $true }
}
$scriptFiles = @($pkgFiles | Where-Object { $_ -like '*.ps1' -and -not $shipSources.ContainsKey((Get-PackageRel $_).ToLowerInvariant()) })
$scriptFiles += @($shipProducts.Keys)

# ---------------------------------------------------------------- products (ahead of time)
# A .cs under a product folder means "compile this folder into one file": the list decides
# which products exist and tools\bundler\products.ps1 says how. Compiling writes into src\ before
# anything is staged, so a source run and `cli dev` use the same binary the release ships. A
# compiler that is missing, or a dll held open by a running resident, leaves the product out:
# its sources then travel instead and the program compiles them at run time.
$productSources = @{}
$plainFiles = New-Object System.Collections.Generic.List[string]
foreach ($f in $pkgFiles) {
  $p = Get-ProductFor (Get-PackageRel $f)
  if ($null -eq $p) { $plainFiles.Add($f); continue }
  if (-not $productSources.ContainsKey($p.Dir)) { $productSources[$p.Dir] = New-Object System.Collections.Generic.List[string] }
  $productSources[$p.Dir].Add($f)
}
# the merged bundles are ordinary scripts from here on: the loop below stages them at the path
# their entry names
foreach ($f in @($shipProducts.Keys)) { $plainFiles.Add($f) }
$productOut = @{}
# the compile command belongs to the entry the table names, not to this script: products.ps1
# runs it through the bundler, and what comes back is a log and whether the file is there
foreach ($p in @(Get-ProductList)) {
  if (-not $productSources.ContainsKey($p.Dir)) { continue }
  $swProduct = Start-Step
  $r = Invoke-ProductBuild $p $bundler $srcRoot
  # The build reports the step and the bundler reports its stages; forwarding its success line
  # as well said the same thing twice, the first time indented as a detail. Only what it says
  # when something went wrong is worth passing on.
  foreach ($line in @($r.Log)) {
    $text = ([string]$line).Trim()
    if (-not $text -or $text.StartsWith('[ok]')) { continue }
    Write-Note $text
  }
  if ($r.Ok) {
    $kb = [Math]::Round((Get-Item -LiteralPath $r.Out).Length / 1KB, 1)
    Write-Done $swProduct ('compiled ' + $p.Label + '   ' + $kb + ' KB')
    $productOut[$p.Out] = $r.Out
  } else {
    Write-Note ('no ' + $p.Label + ' - its sources travel and the program compiles them')
    foreach ($s in @($productSources[$p.Dir])) { $plainFiles.Add($s) }
  }
}
# a package that cannot start says so here, not when someone double-clicks it
foreach ($p in @(Get-ProductList)) {
  if (-not $p.Required) { continue }
  if (-not ($productOut.ContainsKey($p.Out) -or $productSources.ContainsKey($p.Dir))) {
    Fail ('cli.ini [copy] Includes carries neither ' + $p.Dir + ' nor ' + $p.Out + ': a package cannot start without it')
  }
}

# ---------------------------------------------------------------- stage
$stageRoot = Join-Path $env:TEMP ($app + '-build-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$stage = Join-Path $stageRoot $name
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
  $swStage = Start-Step
  Write-Step ('staging ' + $name)

  $map = @{}
  $scopeMaps = @{}
  $globalMap = @{}
  if ($minify) {
    . (Join-Path $root 'tools\utils\minify.ps1')
    if ($rename) {
      $map = New-FunctionMap $scriptFiles
      Write-Note ('internal functions renamed: ' + $map.Count)
      # one scope for the main script and everything it dot-sources, one per script the
      # program calls by path (the table in tools\bundler\assets.ps1 names that folder)
      $sharedFiles = @($scriptFiles | Where-Object { -not (Test-OwnScope (Get-PackageRel $_)) })
      $shared = New-ScriptVariableMap $sharedFiles
      foreach ($file in @($scriptFiles | Where-Object { Test-OwnScope (Get-PackageRel $_) })) {
        $scopeMaps[$file] = New-ScriptVariableMap @($file)
      }
      $scopeCount = $shared.Count
      foreach ($k in $scopeMaps.Keys) { $scopeCount += $scopeMaps[$k].Count }
      Write-Note ('script variables renamed: ' + $scopeCount)
      $scopeMaps['*'] = $shared
      # Names assigned outside every function (constants, defaults, paths) live in the one
      # scope the dot-sourced modules share, so they need one project-wide table. Without
      # it lib\base.ps1 could pick the same short name as the entry file and overwrite $Root.
      $globalMap = New-GlobalVariableMap $sharedFiles
      Write-Note ('shared scope variables renamed: ' + $globalMap.Count)
    }
  }

  # declared products land at their own package path, once, whatever else the list holds
  foreach ($outRel in @($productOut.Keys)) {
    $target = Join-Path $stage $outRel
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $productOut[$outRel] -Destination $target -Force
  }

  # Everything else goes through the table in tools\bundler\assets.ps1: the handler for a path
  # says how the file is rewritten, and the path it keeps in the package is the one it had
  # under src\. A new kind of file is a row there, never a branch here.
  $ascii = New-Object System.Text.ASCIIEncoding
  # an ini can carry words outside ASCII, so it is written as UTF-8 with a BOM - the form the
  # program reads its language files in; the other text handlers keep their plain encoding
  $utf8Bom = New-Object System.Text.UTF8Encoding $true
  $before = 0
  $after = 0
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($f in $plainFiles) {
    # a merged bundle keeps the path its entry names, not the one it was built at
    if ($shipProducts.ContainsKey($f)) { $rel = [string]$shipProducts[$f] } else { $rel = Get-PackageRel $f }
    # a module the bundle already carries is not copied as well
    if ($shipSources.ContainsKey($rel.ToLowerInvariant())) { continue }
    $target = Join-Path $stage $rel
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    # What the file becomes is the handler's business, not this loop's: the row above named it
    # and the handler behind that name decides. The context is everything a handler may need -
    # the read and write paths, the two switches, and the maps the renamer works from.
    $ctx = @{
      Handler      = (Get-LibraryHandler $rel)
      Path         = $f
      Source       = $f
      OutPath      = $target
      Rel          = $rel
      Minify       = $minify
      Rename       = $rename
      FunctionMap  = $map
      ScriptVarMap = @{}
      GlobalVarMap = @{}
      Version      = $version
      StageRoot    = $stageRoot
      Ascii        = $ascii
      Utf8Bom      = $utf8Bom
    }
    if ($minify -and $rename) {
      # one scope for the main script and everything it dot-sources; a folder the table names
      # runs in a scope of its own, so its names are its own
      $ctx.ScriptVarMap = $scopeMaps['*']
      $ctx.GlobalVarMap = $globalMap
      if ($scopeMaps.ContainsKey($f)) {
        $ctx.ScriptVarMap = $scopeMaps[$f]
        $ctx.GlobalVarMap = @{}
      }
    }
    $converted = Invoke-AssetConvert $ctx
    $before += [int]$converted.Before
    $after += [int]$converted.After
    if ($null -ne $converted.Row) { $rows.Add($converted.Row) }
  }

  # a folder that cannot start is worth saying out loud here rather than when someone
  # double-clicks it: the three launchers are named after the program, so nothing is hard-coded
  foreach ($ext in @('.ps1', '.cmd', '.sh')) {
    $need = $app + $ext
    if (-not (Test-Path -LiteralPath (Join-Path $stage $need))) {
      Fail ('cli.ini [copy] Includes does not ship ' + $need)
    }
  }

  # a package never carries the user's history, settings or build leftovers
  foreach ($leak in @('data', ($app + '.ini'), 'cli.ini', 'tests', 'tools', 'package.ini', 'src')) {
    $p = Join-Path $stage $leak
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
  }

  if ($minify -and $rows.Count -gt 0) {
    Write-Text ''
    foreach ($r in $rows) {
      $pct = 0
      if ($r.Before -gt 0) { $pct = [Math]::Round(100 * (1 - $r.After / $r.Before)) }
      Write-Text ('  {0,-26} {1,8} -> {2,7}  ({3}%)' -f (Split-Path -Leaf $r.Path), $r.Before, $r.After, $pct)
    }
    $totalPct = 0
    if ($before -gt 0) { $totalPct = [Math]::Round(100 * (1 - $after / $before), 1) }
    Write-Text ('  {0,-26} {1,8} -> {2,7}  ({3}%)' -f 'scripts total', $before, $after, $totalPct)
    Write-Text ''
  }

  # ------------------------------------------------------------ publish
  if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
  if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
  Move-Item -LiteralPath $stage -Destination $dest
  $count = @(Get-ChildItem -LiteralPath $dest -Recurse -File).Count
  Write-Done $swStage ('staged ' + $name + '   ' + $count + ' files')
} catch {
  Write-Fail $_.Exception.Message
  exit 1
} finally {
  if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- verify
if ($verify) {
  $suite = Join-Path $root 'tests\run.ps1'
  if (-not (Test-Path -LiteralPath $suite)) { Fail ('test suite not found: ' + $suite) }
  $swVerify = Start-Step
  Write-Step 'running the CLI suite against the package'
  # -Serial: the packaging part runs the package's own copy, which drives the machine clipboard,
  # and a CLI part that reads the clipboard at the same moment fails on timing rather than on
  # behaviour. One part at a time is slower but is the only reading that can be trusted.
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File $suite -Integration -Source $dest -Serial
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
    Fail 'the packaged copy failed its own tests, output removed'
  }
  # the suite runs the packaged copy itself, so that copy has just created its own data\
  # and settings; they are the user's, never the package's, so they go away again here.
  foreach ($leak in @('data', ($app + '.ini'))) {
    $p = Join-Path $dest $leak
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
  }
  Write-Done $swVerify 'the packaged copy passed its own tests'
}

# ---------------------------------------------------------------- zip (optional)
if ($wantZip) {
  $zip = Join-Path $outDir ($name + '.zip')
  $swZip = Start-Step
  Compress-Archive -LiteralPath $dest -DestinationPath $zip -CompressionLevel Optimal -Force
  $size = [Math]::Round((Get-Item -LiteralPath $zip).Length / 1KB, 1)
  Write-Done $swZip ('packed ' + $zip + '   ' + $size + ' KB')
}

Write-Text ''
Write-Done $swBuild ('build finished - ' + $dest)
Write-Text ''
Write-Note ('install.bat                   settings template + startup / desktop shortcuts')
Write-Note ('uninstall.bat                 stop, remove the shortcuts, delete data\ and the ini')
Write-Note ($app + '.cmd config init      write a commented ' + $app + '.ini')
Write-Note ($app + '.cmd install         startup shortcut + desktop shortcut')
exit 0

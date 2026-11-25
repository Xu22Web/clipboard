#Requires -Version 5.1
<#
  packages\builder\package.ps1 - write the release out of finished outputs and a file list.

  The inputs are the ones electron-builder takes: a folder of outputs (already built by
  packages\cli) and the file list in builder.ini. Nothing here builds a target, reads cli.ini or
  knows what a plugin chain is - a path arrives, a path lands in the package.

  Request:
      Root      the repository root
      App       the program name (package.ini [package] Name)
      Version   <major>.<minor>.<patch> (package.ini [package] Version)
      Outputs   @( @{ Rel = 'renderer\picker.27afbde2.ps1'; Path = '<abs>'; Replaces = @('src\...) } )
                the finished files, at the path the package keeps them, plus the sources they
                replace (those are not packed as well)
#>
param(
  # the document packages\cli wrote: Root, App, Version, Outputs
  [string]$RequestFile = '',
  # builder.ini itself; a test points this at a copy so the repository's own file is untouched
  [string]$Config = ''
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$packages = Split-Path -Parent $here
$root = Split-Path -Parent $packages

. (Join-Path $here 'utils\console.ps1')
. (Join-Path $here 'utils\ini.ps1')
. (Join-Path $here 'utils\schema.ps1')
. (Join-Path $here 'utils\globs.ps1')
. (Join-Path $here 'utils\minify.ps1')
. (Join-Path $here 'assets.ps1')
Initialize-AssetHandlers (Join-Path $here 'assets')
# the extension plugins this package brings: the file list
foreach ($pluginFile in @(Get-ChildItem -LiteralPath (Join-Path $here 'plugins') -File -Filter '*.ps1' | Sort-Object Name)) {
  . $pluginFile.FullName
}

# the request is written by packages\cli: what to pack, under which name, out of which outputs
if (-not $RequestFile -or -not (Test-Path -LiteralPath $RequestFile)) { Write-Fail 'no -RequestFile given'; exit 1 }
$Request = [IO.File]::ReadAllText($RequestFile, [Text.Encoding]::UTF8) | ConvertFrom-Json

# ---------------------------------------------------------------- settings
# builder.ini is this package's only config, and the sections are electron-builder's.
if (-not $Config) { $Config = Join-Path $root 'builder.ini' }
if (-not (Test-Path -LiteralPath $Config)) { Fail ('missing settings file: ' + $Config) }
$cfg = Import-IniMap $Config
$problems = @(Test-ToolConfigMap (Import-ToolSchema (Join-Path $here 'schema\builder.ps1')) $cfg (Split-Path -Leaf $Config))
if ($problems.Count -gt 0) {
  foreach ($p in $problems) { Write-Fail $p }
  exit 1
}

function CfgValue([string]$section, [string]$key) {
  $flat = $section + '.' + $key
  if ($cfg.ContainsKey($flat)) { return [string]$cfg[$flat] }
  if ($cfg.ContainsKey($key)) { return [string]$cfg[$key] }
  return ''
}

$outSetting = (CfgValue 'directories' 'Output').Trim()
if (-not $outSetting) { $outSetting = 'dist' }
$outDir = if ([IO.Path]::IsPathRooted($outSetting)) { $outSetting } else { Join-Path $root $outSetting }
$baseSetting = (CfgValue 'directories' 'BaseUrl').Trim()
if (-not $baseSetting) { $baseSetting = '.' }
$baseDir = Resolve-BaseDir $root $baseSetting
if (-not (Test-Path -LiteralPath $baseDir)) { Fail ('builder.ini [directories] BaseUrl does not exist: ' + $baseSetting) }

# electron-builder's compression: store keeps every file as it is, normal rewrites each .ps1 from
# its syntax tree, maximum also renames. A release always replaces a folder of the same version,
# which is what electron-builder does as well, so there is no switch for it.
$compression = 'normal'
if ($cfg.ContainsKey('compression') -and [string]$cfg['compression']) { $compression = ([string]$cfg['compression']).Trim().ToLowerInvariant() }
if (@('store', 'normal', 'maximum') -notcontains $compression) { Fail ('builder.ini compression is store, normal or maximum: ' + $compression) }
$minify = ($compression -ne 'store')
$rename = ($compression -eq 'maximum')

$app = ([string]$Request.App).Trim()
$version = ([string]$Request.Version).Trim()
if (-not $app) { Fail 'no program name: packages\cli did not pass App' }
if (-not $version) { Fail 'no version: packages\cli did not pass Version' }
if ($version -notmatch '^\d+\.\d+\.\d+$') { Fail ('version is not <major>.<minor>.<patch>: ' + $version) }
$name = $app + '-' + $version
$dest = Join-Path $outDir $name

# ---------------------------------------------------------------- the file list
# files.Files is one list in which "!pattern" removes; the expansion lives in plugins\files.ps1, so
# the watcher and this script answer the same question the same way.
$list = Get-BuilderFileList -Config $cfg -BaseDir $baseDir
$includeGlobs = @($list.Include)
$excludeGlobs = @($list.Exclude)
$pkgFiles = @($list.Files)

# a file's path in the package: relative to src\, so src\clipboard.ps1 lands at the root; a file
# outside src\ keeps the folders it has here (scripts\install.bat), and the rows the asset table
# flattens become flat anyway
function Get-PackageRel([string]$file) {
  $full = [IO.Path]::GetFullPath($file)
  $srcRoot = Join-Path $root 'src'
  $srcFull = ([IO.Path]::GetFullPath($srcRoot)).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($srcFull, [StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($srcFull.Length) }
  $rootFull = ([IO.Path]::GetFullPath($root)).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
    $rel = $full.Substring($rootFull.Length)
    # the rows assets.ps1 flattens belong at the package root (scripts\install.bat)
    if (Test-Flatten $rel) { return (Split-Path -Leaf $full) }
    return $rel
  }
  return (Split-Path -Leaf $full)
}

# the outputs packages\cli built, and the sources each one replaces
$outputMap = @{}
$replaced = @{}
foreach ($one in @($Request.Outputs)) {
  if ($null -eq $one) { continue }
  $relOut = ([string]$one.Rel) -replace '/', '\'
  if (-not $relOut) { continue }
  $outputMap[$relOut] = [string]$one.Path
  foreach ($src in @($one.Replaces)) {
    # the same coordinate Get-PackageRel speaks, so the two sets compare directly
    $key = Get-PackageRel (Join-Path $root ([string]$src))
    if ($key) { $replaced[$key.ToLowerInvariant()] = $true }
  }
}

# What is packed: the file list minus the sources an output replaces, and the outputs themselves,
# which land at the path the target named.
$scriptFiles = New-Object System.Collections.Generic.List[string]
$plainFiles = New-Object System.Collections.Generic.List[string]
foreach ($f in $pkgFiles) {
  $rel = Get-PackageRel $f
  if ($replaced.ContainsKey($rel.ToLowerInvariant())) { continue }
  $plainFiles.Add($f)
  if ($f -like '*.ps1') { $scriptFiles.Add($f) }
}
foreach ($relOut in @($outputMap.Keys)) {
  if ($relOut -like '*.ps1' -and (Test-Path -LiteralPath $outputMap[$relOut])) { $scriptFiles.Add($outputMap[$relOut]) }
}

$swBuild = Start-Step
Write-Step ('build ' + $name)
Write-Note ('settings ' + (Split-Path -Leaf $Config) + '   version ' + $version + '   from package.ini')
Write-Note ('output   ' + $dest)
Write-Note ('files    ' + [string]$includeGlobs.Count + ' glob(s)   compression ' + $compression)

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
  if ($minify -and $rename) {
    $map = New-FunctionMap $scriptFiles
    Write-Note ('internal functions renamed: ' + $map.Count)
    # one scope for the main script and everything it dot-sources, one per script the program
    # calls by path (the table in assets.ps1 names that folder)
    $sharedFiles = @($scriptFiles | Where-Object { -not (Test-OwnScope (Get-PackageRel $_)) })
    $shared = New-ScriptVariableMap $sharedFiles
    foreach ($file in @($scriptFiles | Where-Object { Test-OwnScope (Get-PackageRel $_) })) {
      $scopeMaps[$file] = New-ScriptVariableMap @($file)
    }
    $scopeCount = $shared.Count
    foreach ($k in $scopeMaps.Keys) { $scopeCount += $scopeMaps[$k].Count }
    Write-Note ('script variables renamed: ' + $scopeCount)
    $scopeMaps['*'] = $shared
    # Names assigned outside every function (constants, defaults, paths) live in the one scope
    # the dot-sourced modules share, so they need one project-wide table.
    $globalMap = New-GlobalVariableMap $sharedFiles
    Write-Note ('shared scope variables renamed: ' + $globalMap.Count)
  }

  # declared outputs land at their own package path, once, whatever else the list holds
  foreach ($outRel in @($outputMap.Keys)) {
    $targetPath = Join-Path $stage $outRel
    $outParent = Split-Path -Parent $targetPath
    if (-not (Test-Path -LiteralPath $outParent)) { New-Item -ItemType Directory -Path $outParent -Force | Out-Null }
    Copy-Item -LiteralPath $outputMap[$outRel] -Destination $targetPath -Force
  }

  # Everything else goes through the table in assets.ps1: the handler for a path says how the
  # file is rewritten, and the path it keeps in the package is the one it had under BaseUrl.
  $ascii = New-Object System.Text.ASCIIEncoding
  # an ini can carry words outside ASCII, so it is written as UTF-8 with a BOM - the form the
  # program reads its language files in; the other text handlers keep their plain encoding
  $utf8Bom = New-Object System.Text.UTF8Encoding $true
  $before = 0
  $after = 0
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($f in $plainFiles) {
    $rel = Get-PackageRel $f
    $targetPath = Join-Path $stage $rel
    $outParent = Split-Path -Parent $targetPath
    if (-not (Test-Path -LiteralPath $outParent)) { New-Item -ItemType Directory -Path $outParent -Force | Out-Null }
    $ctx = @{
      Handler      = (Get-LibraryHandler $rel)
      Path         = $f
      Source       = $f
      OutPath      = $targetPath
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
      Fail ('builder.ini [files] Files does not ship ' + $need)
    }
  }

  # a package never carries the user's history, settings or build leftovers
  foreach ($leak in @('data', ($app + '.ini'), 'cli.ini', 'builder.ini', 'tests', 'packages', 'package.ini', 'src')) {
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

  # electron-builder writes the resolved configuration beside the package
  # (builder-effective-config.yaml) so a build can be read back; this is the same file in the
  # format the rest of this repository reads, and it sits in Output= rather than in the package
  $effective = New-Object System.Collections.Generic.List[string]
  $effective.Add('[directories]')
  $effective.Add('Output=' + $outSetting)
  $effective.Add('BaseUrl=' + $baseSetting)
  $effective.Add('[files]')
  $effective.Add('Files=' + (@($includeGlobs) -join ','))
  $effective.Add('[build]')
  $effective.Add('Version=' + $version)
  $effective.Add('Compression=' + $compression)
  $effective.Add('Packages=' + $count)
  $effectivePath = Join-Path $outDir 'builder-effective-config.ini'
  [IO.File]::WriteAllLines($effectivePath, $effective.ToArray(), (New-Object System.Text.UTF8Encoding $false))
  Write-Note ('config   ' + (Split-Path -Leaf $effectivePath) + '   (written beside the package)')
} catch {
  Write-Fail $_.Exception.Message
  exit 1
} finally {
  if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Text ''
Write-Done $swBuild ('build finished - ' + $dest)
# where the package landed, for the caller that asked for it: a release has to check the folder
# this run wrote, and it is the only one that knows the name
[IO.File]::WriteAllText(($RequestFile + '.result'), $dest, (New-Object System.Text.UTF8Encoding $false))
Write-Text ''
Write-Note ('install.bat                   settings template + startup / desktop shortcuts')
Write-Note ('uninstall.bat                 stop, remove the shortcuts, delete data\ and the ini')
Write-Note ($app + '.cmd config init      write a commented ' + $app + '.ini')
Write-Note ($app + '.cmd install         startup shortcut + desktop shortcut')
exit 0


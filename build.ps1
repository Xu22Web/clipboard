#Requires -Version 5.1
<#
  build.ps1 - package the tool the way a front-end build packages a bundle: the output is
  still plain PowerShell, but every .ps1 is rewritten from its syntax tree (comments and
  indentation gone, internal functions and local variables renamed), so the folder keeps
  the same shape and behaviour while being noticeably smaller. Nothing is compiled.

      powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
      powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Config other.ini

  Every setting lives in build.ini next to this script: version, output folder, whether to
  minify and rename, whether to verify the result by running the CLI test suite against
  it, whether to also write a zip. The only switch is -Config.

  What goes in: everything under src\ (clipboard.ps1, the two launchers, lib\, the
  selected plugins and themes) plus (by default) the documentation. What never goes in:
  src\data\, src\clipboard.ini, tests\, build\, dist\, .git - a package carries the
  program, not your history or your settings. Reading only src\ is also what keeps the
  build from walking into its own output.
#>
param(
  [string]$Config = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
# the program lives in src\, the build tooling and the docs stay at the repo root
$srcRoot = Join-Path $root 'src'
if (-not (Test-Path -LiteralPath $srcRoot)) { Write-Host ('[x] missing: ' + $srcRoot); exit 1 }

function Write-Step([string]$text) { Write-Host ('[..] ' + $text) }
function Fail([string]$text) { Write-Host ('[x] ' + $text); exit 1 }

# ---------------------------------------------------------------- settings
function Read-Settings([string]$path) {
  $map = @{}
  if (-not (Test-Path -LiteralPath $path)) { return $map }
  foreach ($line in [IO.File]::ReadAllLines($path)) {
    $t = $line.Trim()
    if (-not $t) { continue }
    if ($t.StartsWith('#') -or $t.StartsWith(';')) { continue }
    if ($t.StartsWith('[')) { continue }
    $i = $t.IndexOf('=')
    if ($i -lt 1) { continue }
    $map[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
  }
  return $map
}

if (-not $Config) { $Config = Join-Path $root 'build.ini' }
$cfg = Read-Settings $Config
if (-not (Test-Path -LiteralPath $Config)) {
  Write-Step ('no ' + (Split-Path -Leaf $Config) + ', using built-in defaults')
}

function Cfg([string]$key, [string]$fallback) {
  if ($cfg.ContainsKey($key)) {
    $v = [string]$cfg[$key]
    if ($v -ne '') { return $v }
  }
  return $fallback
}

function CfgBool([string]$key, [bool]$fallback) {
  $v = (Cfg $key '').ToLowerInvariant()
  if (-not $v) { return $fallback }
  return @('1', 'true', 'yes', 'on') -contains $v
}

function CfgList([string]$key) {
  $raw = Cfg $key ''
  return @($raw -split '[,;\s]+' | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}

$version = Cfg 'Version' ''
if (-not $version) {
  try {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) { $version = [string](& git -C $root describe --tags --always --dirty 2>$null) }
  } catch { $version = '' }
  if (-not $version) { $version = Get-Date -Format 'yyyyMMdd' }
}
$version = ($version.Trim() -replace '[^0-9A-Za-z\.\-_]', '')
if (-not $version) { Fail 'Version= in the settings file is not usable' }

$name = 'clipboard-' + $version
$outSetting = Cfg 'OutDir' 'dist'
$outDir = if ([IO.Path]::IsPathRooted($outSetting)) { $outSetting } else { Join-Path $root $outSetting }
$dest = Join-Path $outDir $name
$minify = CfgBool 'Minify' $true
$rename = CfgBool 'Rename' $true
$verify = CfgBool 'Verify' $true
$includeDocs = CfgBool 'IncludeDocs' $true
$overwrite = CfgBool 'Overwrite' $false
$wantZip = CfgBool 'Zip' $false
$pluginNames = CfgList 'Plugins'
$themeNames = CfgList 'Themes'

Write-Step ('settings ' + $Config)
Write-Step ('  version ' + $version)
Write-Step ('  output  ' + $dest)
Write-Step ('  minify  ' + $(if ($minify) { 'yes' } else { 'no' }) + '   rename ' + $(if ($rename) { 'yes' } else { 'no' }) + '   verify ' + $(if ($verify) { 'yes' } else { 'no' }) + '   zip ' + $(if ($wantZip) { 'yes' } else { 'no' }))
Write-Step ('  docs    ' + $(if ($includeDocs) { 'yes' } else { 'no' }) + '   overwrite ' + $(if ($overwrite) { 'yes' } else { 'no' }))
Write-Step ('  plugins ' + $(if ($pluginNames.Count) { $pluginNames -join ',' } else { 'all' }) + '   themes ' + $(if ($themeNames.Count) { $themeNames -join ',' } else { 'all' }))

if ((Test-Path -LiteralPath $dest) -and -not $overwrite) { Fail ('already exists: ' + $dest + '   (set Overwrite=1 to replace it)') }

# ---------------------------------------------------------------- resolve inputs
foreach ($f in @('clipboard.ps1', 'clipboard.cmd', 'clipboard')) {
  if (-not (Test-Path -LiteralPath (Join-Path $srcRoot $f))) { Fail ('missing: src\' + $f) }
}
if (-not (Test-Path -LiteralPath (Join-Path $srcRoot 'lib'))) { Fail 'missing: src\lib\' }

$pluginFiles = @()
$themeFiles = @()
foreach ($kind in @(@{ Dir = 'plugins'; Ext = '.ps1'; Names = $pluginNames }, @{ Dir = 'themes'; Ext = '.ini'; Names = $themeNames })) {
  $srcDir = Join-Path $srcRoot $kind.Dir
  if (-not (Test-Path -LiteralPath $srcDir)) { Fail ('missing: src\' + $kind.Dir + '\') }
  $picked = @()
  if ($kind.Names.Count -eq 0) {
    $picked = @(Get-ChildItem -LiteralPath $srcDir -File | ForEach-Object { $_.FullName })
  } else {
    foreach ($n in $kind.Names) {
      $file = Join-Path $srcDir ($n + $kind.Ext)
      if (-not (Test-Path -LiteralPath $file)) { Fail ('not found in ' + $kind.Dir + ': ' + $n) }
      $picked += $file
      # an item's own page travels with it
      $doc = Join-Path $srcDir ($n + '.md')
      if (Test-Path -LiteralPath $doc) { $picked += $doc }
    }
  }
  if ($kind.Dir -eq 'plugins') { $pluginFiles = $picked } else { $themeFiles = $picked }
}

# ---------------------------------------------------------------- stage
$stageRoot = Join-Path $env:TEMP ('clipboard-build-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$stage = Join-Path $stageRoot $name
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
  Write-Step ('staging ' + $name)

  # the scripts that go through the minifier, in a stable order
  $scriptFiles = @()
  $scriptFiles += Join-Path $srcRoot 'clipboard.ps1'
  $scriptFiles += @(Get-ChildItem -LiteralPath (Join-Path $srcRoot 'lib') -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
  $scriptFiles += @($pluginFiles | Where-Object { $_ -like '*.ps1' })

  $map = @{}
  if ($minify) {
    . (Join-Path $root 'build\minify.ps1')
    if ($rename) {
      $map = New-FunctionMap $scriptFiles
      Write-Step ('internal functions renamed: ' + $map.Count)
    }
  }

  $before = 0
  $after = 0
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($file in $scriptFiles) {
    $rel = $file.Substring($srcRoot.Length).TrimStart([char]92, [char]47)
    $target = Join-Path $stage $rel
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if ($minify) {
      if ($rename) { $r = Invoke-MinifyFile -Path $file -OutPath $target -FunctionMap $map }
      else { $r = Invoke-MinifyFile -Path $file -OutPath $target -NoRename }
      $before += $r.Before
      $after += $r.After
      $rows.Add($r)
    } else {
      Copy-Item -LiteralPath $file -Destination $target -Force
      $len = (Get-Item -LiteralPath $file).Length
      $before += $len
      $after += $len
    }
  }

  # everything else is copied as it is
  foreach ($f in @('clipboard.cmd', 'clipboard')) {
    Copy-Item -LiteralPath (Join-Path $srcRoot $f) -Destination $stage -Force
  }
  foreach ($f in @($pluginFiles) + @($themeFiles)) {
    if ($f -like '*.ps1') { continue }
    $rel = $f.Substring($srcRoot.Length).TrimStart([char]92, [char]47)
    $target = Join-Path $stage $rel
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $f -Destination $target -Force
  }
  if ($includeDocs) {
    foreach ($f in @('README.md', 'LICENSE')) {
      $src = Join-Path $root $f
      if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $stage -Force }
    }
    $docs = Join-Path $root 'docs'
    if (Test-Path -LiteralPath $docs) { Copy-Item -LiteralPath $docs -Destination $stage -Recurse -Force }
  }

  # a package never carries the user's history, settings or build leftovers
  foreach ($leak in @('data', 'clipboard.ini', 'tests', 'dist', 'build.ini', 'src')) {
    $p = Join-Path $stage $leak
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
  }

  if ($minify -and $rows.Count -gt 0) {
    Write-Host ''
    foreach ($r in $rows) {
      $pct = 0
      if ($r.Before -gt 0) { $pct = [Math]::Round(100 * (1 - $r.After / $r.Before)) }
      Write-Host ('  {0,-26} {1,8} -> {2,7}  ({3}%)' -f (Split-Path -Leaf $r.Path), $r.Before, $r.After, $pct)
    }
    $totalPct = 0
    if ($before -gt 0) { $totalPct = [Math]::Round(100 * (1 - $after / $before), 1) }
    Write-Host ('  {0,-26} {1,8} -> {2,7}  ({3}%)' -f 'scripts total', $before, $after, $totalPct)
    Write-Host ''
  }

  # ------------------------------------------------------------ publish
  if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
  if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
  Move-Item -LiteralPath $stage -Destination $dest
  $count = @(Get-ChildItem -LiteralPath $dest -Recurse -File).Count
  Write-Host ('[ok] ' + $dest + '   ' + $count + ' files')
} catch {
  Write-Host ('[x] ' + $_.Exception.Message)
  exit 1
} finally {
  if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- verify
if ($verify) {
  $suite = Join-Path $root 'tests\run-tests.ps1'
  if (-not (Test-Path -LiteralPath $suite)) { Fail ('test suite not found: ' + $suite) }
  Write-Step 'running the CLI suite against the package'
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File $suite -Integration -Source $dest 2>&1
  $code = $LASTEXITCODE
  $total = @($out | Where-Object { [string]$_ -match '^TOTAL ' }) | Select-Object -Last 1
  if ($code -ne 0) {
    Write-Host ($out | Select-Object -Last 15 | Out-String)
    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
    Fail 'the packaged copy failed its own tests, output removed'
  }
  if ($total) { Write-Step ('tests: ' + ([string]$total).Trim()) }
}

# ---------------------------------------------------------------- zip (optional)
if ($wantZip) {
  $zip = Join-Path $outDir ($name + '.zip')
  Write-Step ('packing ' + $zip)
  Compress-Archive -LiteralPath $dest -DestinationPath $zip -CompressionLevel Optimal -Force
  $size = [Math]::Round((Get-Item -LiteralPath $zip).Length / 1KB, 1)
  Write-Host ('[ok] ' + $zip + '   ' + $size + ' KB')
}

Write-Host ''
Write-Host 'result:'
Write-Host ('  ' + $dest)
Write-Host '  clipboard.cmd config init      write a commented clipboard.ini'
Write-Host '  clipboard.cmd install         startup shortcut + desktop shortcut'
exit 0

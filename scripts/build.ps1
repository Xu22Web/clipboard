#Requires -Version 5.1
<#
  scripts\build.ps1 - package the tool the way a front-end build packages a bundle: the
  output is still plain PowerShell, but every .ps1 is rewritten from its syntax tree
  (comments and indentation gone, internal functions and local variables renamed), so the
  folder keeps the same shape and behaviour while being noticeably smaller. Nothing is
  compiled.

      cli build                          settings from build.ini
      cli build -Config other.ini         a different settings file

  build.ini holds the build options only: output folder, whether to minify and rename,
  whether to verify the result by running the CLI suite against it, whether to also write a
  zip. The version is not a build option: package.ini owns it. The development copy reads it
  at run time (src\lib\base.ps1); the build replaces that block with a literal, so a package
  carries the version and reads no file.

  Two batch files are written next to clipboard.ps1: install.bat (config init + migrate +
  install) and uninstall.bat (stop + uninstall purge).

  What goes in: everything under src\ (the entry file, the two launchers, lib\ with its
  modules, utils\ with the pure helpers, the selected plugins and themes) plus (by default)
  the documentation. What never goes in: src\data\, src\clipboard.ini, tests\, scripts\,
  dist\, .git - a package carries the program, not the history, the settings or the tooling.
  Reading only src\ is also what keeps the build from walking into its own output.
#>
param(
  [string]$Config = ''
)

$ErrorActionPreference = 'Stop'
# this file lives in scripts\: the repository root is one level up
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
# the program lives in src\, the build tooling and the docs stay at the repo root
$srcRoot = Join-Path $root 'src'
if (-not (Test-Path -LiteralPath $srcRoot)) { Write-Host ('[x] missing: ' + $srcRoot); exit 1 }

function Write-Step([string]$text) { Write-Host ('[..] ' + $text) }
function Fail([string]$text) { Write-Host ('[x] ' + $text); exit 1 }

# ---------------------------------------------------------------- settings
# build.ini and package.ini are read by the layer the program itself uses
# (src\utils\ini.ps1 + inifile.ps1): "Key=Value" per line, "#" or ";" comments, and a
# "[section]" line grouping the keys that follow - so "[build]" + "OutDir=dist" is the same
# key as "build.OutDir=dist".
$iniTools = Join-Path $srcRoot 'utils'
foreach ($tool in @('ini', 'inifile')) {
  $toolPath = Join-Path $iniTools ($tool + '.ps1')
  if (-not (Test-Path -LiteralPath $toolPath)) { Fail ('missing: ' + $toolPath) }
  . $toolPath
}

if (-not $Config) { $Config = Join-Path $root 'build.ini' }
$cfg = Import-IniMap $Config
if (-not (Test-Path -LiteralPath $Config)) {
  Write-Step ('no ' + (Split-Path -Leaf $Config) + ', using built-in defaults')
}

function Cfg([string]$key, [string]$fallback) {
  # a build key may be written inside [build] or with its dotted name at the top level.
  # The dotted name is built first: "@('build.' + $key, $key)" would join the two into one
  # string, because "," binds tighter than "+" inside an array literal.
  $dotted = 'build.' + $key
  foreach ($candidate in @($dotted, $key)) {
    if (-not $cfg.ContainsKey($candidate)) { continue }
    $v = [string]$cfg[$candidate]
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

# src\lib\base.ps1 keeps the version between two markers for the development run; a package
# gets the number itself instead of code that reads package.ini.
function Get-VersionPatchedText([string]$text, [string]$version) {
  $begin = $text.IndexOf('#@version-begin')
  $end = $text.IndexOf('#@version-end')
  if ($begin -lt 0 -or $end -lt $begin) { Fail 'src\lib\base.ps1 has no #@version-begin / #@version-end block' }
  $head = $text.Substring(0, $begin)
  $tail = $text.Substring($text.IndexOf("`n", $end) + 1)
  return ($head + "`$script:Version = '" + $version + "'`r`n" + $tail)
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
Write-Step ('  version ' + $version + '   (package.ini)')
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
if (-not (Test-Path -LiteralPath (Join-Path $srcRoot 'utils'))) { Fail 'missing: src\utils\' }
if (-not (Test-Path -LiteralPath (Join-Path $srcRoot 'schema'))) { Fail 'missing: src\schema\' }

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

# A plugin's keys are described by its own schema file (src\schema\plugins\<name>.ps1), so
# the shipped schemas follow the shipped plugins: a package documents what it can run.
$pluginSchemas = @()
$schemaPluginDir = Join-Path $srcRoot 'schema\plugins'
if (Test-Path -LiteralPath $schemaPluginDir) {
  if ($pluginNames.Count -eq 0) {
    $pluginSchemas = @(Get-ChildItem -LiteralPath $schemaPluginDir -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
  } else {
    foreach ($n in $pluginNames) {
      $file = Join-Path $schemaPluginDir ($n + '.ps1')
      if (Test-Path -LiteralPath $file) { $pluginSchemas += $file }
    }
  }
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
  $scriptFiles += @(Get-ChildItem -LiteralPath (Join-Path $srcRoot 'lib') -Filter '*.ps1' -File -Recurse | ForEach-Object { $_.FullName })
  $scriptFiles += @(Get-ChildItem -LiteralPath (Join-Path $srcRoot 'utils') -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
  # the schema files are data, but they name the variables Apply-Config writes through, so
  # they are renamed with the rest of the shared scope instead of being copied verbatim
  $scriptFiles += @(Get-ChildItem -LiteralPath (Join-Path $srcRoot 'schema') -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
  $scriptFiles += @($pluginFiles | Where-Object { $_ -like '*.ps1' })

  $map = @{}
  $scopeMaps = @{}
  $globalMap = @{}
  if ($minify) {
    . (Join-Path $root 'scripts\minify.ps1')
    if ($rename) {
      $map = New-FunctionMap $scriptFiles
      Write-Step ('internal functions renamed: ' + $map.Count)
      # one scope for the main script and everything it dot-sources, one per plugin
      $sharedFiles = @($scriptFiles | Where-Object { $_ -notlike (Join-Path $srcRoot 'plugins*') })
      $shared = New-ScriptVariableMap $sharedFiles
      foreach ($file in @($scriptFiles | Where-Object { $_ -like (Join-Path $srcRoot 'plugins*') })) {
        $scopeMaps[$file] = New-ScriptVariableMap @($file)
      }
      $scopeCount = $shared.Count
      foreach ($k in $scopeMaps.Keys) { $scopeCount += $scopeMaps[$k].Count }
      Write-Step ('script variables renamed: ' + $scopeCount)
      $scopeMaps['*'] = $shared
      # Names assigned outside every function (constants, defaults, paths) live in the one
      # scope the dot-sourced modules share, so they need one project-wide table. Without
      # it lib\base.ps1 could pick the same short name as the entry file and overwrite $Root.
      $globalMap = New-GlobalVariableMap $sharedFiles
      Write-Step ('shared scope variables renamed: ' + $globalMap.Count)
    }
  }

  $before = 0
  $after = 0
  $rows = New-Object System.Collections.Generic.List[object]
  $baseFile = Join-Path $srcRoot 'lib\base.ps1'
  foreach ($file in $scriptFiles) {
    $rel = $file.Substring($srcRoot.Length).TrimStart([char]92, [char]47)
    $target = Join-Path $stage $rel
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    # The development copy reads the version from package.ini. A package carries the number
    # itself, so it needs neither that file nor a code path that looks for it.
    $input = $file
    if ($file -eq $baseFile) {
      $input = Join-Path $stageRoot 'verpatch\base.ps1'
      New-Item -ItemType Directory -Path (Split-Path -Parent $input) -Force | Out-Null
      [IO.File]::WriteAllText($input, (Get-VersionPatchedText ([IO.File]::ReadAllText($file)) $version))
    }
    if ($minify) {
      if ($rename) {
        $vars = $scopeMaps['*']
        if ($scopeMaps.ContainsKey($file)) { $vars = $scopeMaps[$file] }
        $globals = $globalMap
        if ($scopeMaps.ContainsKey($file)) { $globals = @{} }   # a plugin has a scope of its own
        $r = Invoke-MinifyFile -Path $input -OutPath $target -FunctionMap $map -ScriptVarMap $vars -GlobalVarMap $globals
      } else { $r = Invoke-MinifyFile -Path $input -OutPath $target -NoRename }
      $r.Path = $file
      $before += $r.Before
      $after += $r.After
      $rows.Add($r)
    } else {
      Copy-Item -LiteralPath $input -Destination $target -Force
      $len = (Get-Item -LiteralPath $input).Length
      $before += $len
      $after += $len
    }
  }

  # everything else is copied as it is
  foreach ($f in @('clipboard.cmd', 'clipboard')) {
    Copy-Item -LiteralPath (Join-Path $srcRoot $f) -Destination $stage -Force
  }
  # a packaged copy is set up by double-clicking, so the two scripts sit next to
  # clipboard.ps1 and only call commands the program already has
  $installBat = @(
    '@echo off',
    'rem clipboard - write a commented clipboard.ini, upgrade an older history, then create',
    'rem the two shortcuts.',
    'setlocal',
    'powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0clipboard.ps1" config init',
    'powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0clipboard.ps1" migrate',
    'powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0clipboard.ps1" install',
    'echo.',
    'echo done. the hotkey is the Hotkey= line in clipboard.ini.',
    'pause',
    'endlocal'
  ) -join "`r`n"
  $uninstallBat = @(
    '@echo off',
    'rem clipboard - stop the resident, remove the shortcuts, delete data\ and clipboard.ini.',
    'setlocal',
    'powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0clipboard.ps1" stop',
    'timeout /t 2 /nobreak >nul',
    'powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0clipboard.ps1" uninstall purge',
    'echo.',
    'echo done. data\ and clipboard.ini are gone.',
    'pause',
    'endlocal'
  ) -join "`r`n"
  $ascii = New-Object System.Text.ASCIIEncoding
  [IO.File]::WriteAllText((Join-Path $stage 'install.bat'), ($installBat + "`r`n"), $ascii)
  [IO.File]::WriteAllText((Join-Path $stage 'uninstall.bat'), ($uninstallBat + "`r`n"), $ascii)
  Write-Step 'wrote install.bat and uninstall.bat'
  foreach ($f in @($pluginFiles) + @($themeFiles)) {
    if ($f -like '*.ps1') { continue }
    $rel = $f.Substring($srcRoot.Length).TrimStart([char]92, [char]47)
    $target = Join-Path $stage $rel
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $f -Destination $target -Force
  }
  # plugin schemas are data, not code: they are copied verbatim, and only for the plugins
  # that actually ship
  foreach ($f in @($pluginSchemas)) {
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
  foreach ($leak in @('data', 'clipboard.ini', 'tests', 'scripts', 'build.ini', 'package.ini', 'src')) {
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
  # the suite runs the packaged copy itself, so that copy has just created its own data\
  # and settings; they are the user's, never the package's, so they go away again here.
  foreach ($leak in @('data', 'clipboard.ini')) {
    $p = Join-Path $dest $leak
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
  }
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
Write-Host '  install.bat                   clipboard.ini template + startup / desktop shortcuts'
Write-Host '  uninstall.bat                 stop, remove the shortcuts, delete data\ and the ini'
Write-Host '  clipboard.cmd config init      write a commented clipboard.ini'
Write-Host '  clipboard.cmd install         startup shortcut + desktop shortcut'
exit 0

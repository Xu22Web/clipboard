#Requires -Version 5.1
<#
  tools\build.ps1 - package the tool the way a front-end build packages a bundle: the
  output is still plain PowerShell, but every .ps1 is rewritten from its syntax tree
  (comments and indentation gone, internal functions and local variables renamed), so the
  folder keeps the same shape and behaviour while being noticeably smaller. Nothing is
  compiled.

      cli build                          settings from cli.ini
      cli build -Config other.ini         a different settings file

  cli.ini holds the tooling settings: the [build] section is the output folder, whether to
  minify and rename, whether to verify the result by running the CLI suite against it,
  whether to also write a zip; [dev] and [test] belong to the other two commands. The
  version is not a build option: package.ini owns it. The development copy reads it
  at run time (src\lib\base.ps1); the build replaces that block with a literal, so a package
  carries the version and reads no file.

  Two batch files are written next to clipboard.ps1: install.bat (config init + migrate +
  install) and uninstall.bat (stop + uninstall purge).

  What goes in: everything under src\ (the entry file, the two launchers, lib\ with its
  modules, utils\ with the pure helpers, the selected plugins and themes) plus (by default)
  the documentation. What never goes in: src\data\, src\clipboard.ini, tests\, tools\,
  dist\, .git - a package carries the program, not the history, the settings or the tooling.
  Reading only src\ is also what keeps the build from walking into its own output.
#>
param(
  [string]$Config = ''
)

$ErrorActionPreference = 'Stop'
# this file lives in tools\: the repository root is one level up
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
# the program lives in src\, the build tooling and the docs stay at the repo root
$srcRoot = Join-Path $root 'src'
if (-not (Test-Path -LiteralPath $srcRoot)) { Write-Host ('[x] missing: ' + $srcRoot); exit 1 }

function Write-Step([string]$text) { Write-Host ('[..] ' + $text) }
function Fail([string]$text) { Write-Host ('[x] ' + $text); exit 1 }

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

# cli.ini is the only place a build setting may live: a missing key is a broken file, not a
# default to fall back on, so the whole [build] section is checked once here. An empty value
# is valid - Plugins= and Themes= mean "everything", Includes= and Excludes= mean "none".
$requiredKeys = @('OutDir', 'Minify', 'Rename', 'Verify', 'IncludeDocs', 'Overwrite', 'Zip',
  'Client', 'Assembly', 'Plugins', 'Themes', 'Includes', 'Excludes')
$missingKeys = @()
foreach ($key in $requiredKeys) {
  if (-not $cfg.ContainsKey('build.' + $key) -and -not $cfg.ContainsKey($key)) { $missingKeys += $key }
}
if ($missingKeys.Count -gt 0) {
  Fail ((Split-Path -Leaf $Config) + ' [build] is missing: ' + ($missingKeys -join ', '))
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

function CfgList([string]$key) {
  return @((Cfg $key) -split '[,;\s]+' | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
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
$outSetting = Cfg 'OutDir'
if (-not $outSetting) { Fail 'cli.ini [build] OutDir is empty' }
$outDir = if ([IO.Path]::IsPathRooted($outSetting)) { $outSetting } else { Join-Path $root $outSetting }
$dest = Join-Path $outDir $name
$minify = CfgBool 'Minify'
$rename = CfgBool 'Rename'
$verify = CfgBool 'Verify'
$includeDocs = CfgBool 'IncludeDocs'
$overwrite = CfgBool 'Overwrite'
$wantZip = CfgBool 'Zip'
# the native client is an accelerator, never a requirement: without a compiler the package
# still works, one ~1 s slower per command
$client = CfgBool 'Client'
$assembly = CfgBool 'Assembly'
$pluginNames = CfgList 'Plugins'
$themeNames = CfgList 'Themes'
$includeGlobs = CfgList 'Includes'
$excludeGlobs = CfgList 'Excludes'
# the include and exclude lists use the same glob syntax as cli.ini [dev]
. (Join-Path $root 'tools\utils\globs.ps1')

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

# cli.ini [build] Excludes removes files from every set below, and the page list follows the
# plugins that still ship. Includes then adds what the default set does not cover.
$dropFiles = @{}
if ($excludeGlobs.Count -gt 0) {
  foreach ($glob in $excludeGlobs) {
    foreach ($f in @(Expand-Glob $srcRoot $glob)) { $dropFiles[$f] = $true }
  }
  $pluginFiles = @($pluginFiles | Where-Object { -not $dropFiles.ContainsKey($_) })
  $themeFiles = @($themeFiles | Where-Object { -not $dropFiles.ContainsKey($_) })
  $pluginSchemas = @($pluginSchemas | Where-Object { -not $dropFiles.ContainsKey($_) })
}

# The pages under docs\ plugin and theme describe a plugin or a theme, so they follow the
# same choice: a package ships the pages of what it can run and nothing else.
$pageKeep = @{ plugin = @{}; theme = @{} }
foreach ($pair in @(@('plugin', $pluginFiles), @('theme', $themeFiles))) {
  foreach ($f in @($pair[1])) { $pageKeep[$pair[0]][[IO.Path]::GetFileNameWithoutExtension([string]$f)] = $true }
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

  # cli.ini [build] Includes adds what the default set does not carry: a .ps1 joins the
  # scripts that are minified and renamed with the rest, anything else is copied as it is.
  # Excludes already ran over the plugins and themes; it runs again here last of all.
  $extraCopies = New-Object System.Collections.Generic.List[string]
  foreach ($glob in $includeGlobs) {
    foreach ($f in @(Expand-Glob $srcRoot $glob)) {
      if ($dropFiles.ContainsKey($f)) { continue }
      if ($f -like '*.ps1') {
        if ($scriptFiles -notcontains $f) { $scriptFiles += $f }
      } elseif (-not $extraCopies.Contains($f)) {
        $extraCopies.Add($f)
      }
    }
  }
  if ($dropFiles.Count -gt 0) {
    $beforeCount = $scriptFiles.Count
    $scriptFiles = @($scriptFiles | Where-Object { -not $dropFiles.ContainsKey($_) })
    Write-Step ('excluded ' + ($beforeCount - $scriptFiles.Count) + ' script(s) listed in cli.ini [build] Excludes')
  }

  $map = @{}
  $scopeMaps = @{}
  $globalMap = @{}
  if ($minify) {
    . (Join-Path $root 'tools\utils\minify.ps1')
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
  # files cli.ini [build] Includes added beyond the ps1 scripts (data, not code)
  foreach ($f in @($extraCopies)) {
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
    if (Test-Path -LiteralPath $docs) {
      Copy-Item -LiteralPath $docs -Destination $stage -Recurse -Force
      foreach ($sec in @(@{ Dir = 'plugin'; Keep = $pageKeep['plugin'] }, @{ Dir = 'theme'; Keep = $pageKeep['theme'] })) {
        $dir = Join-Path (Join-Path $stage 'docs') $sec.Dir
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($page in @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File)) {
          if ($sec.Keep.ContainsKey([IO.Path]::GetFileNameWithoutExtension($page.Name))) { continue }
          Remove-Item -LiteralPath $page.FullName -Force
        }
        if (@(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) { Remove-Item -LiteralPath $dir -Recurse -Force }
      }
    }
  }

  # a package never carries the user's history, settings or build leftovers
  foreach ($leak in @('data', 'clipboard.ini', 'cli.ini', 'tests', 'tools', 'package.ini', 'src')) {
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

  # ------------------------------------------------------------ native client (optional)
  # A compiled client turns a proxied command into a ~150 ms call instead of ~1 s, because it
  # is started before any PowerShell exists. clipboard.cmd falls back to the script when the
  # file is missing, so a machine without the .NET Framework compiler still gets a package.
  # lib\assembly\clipboard.dll comes from the same compiler: src\lib\assembly compiled ahead
  # of time (loading it costs milliseconds where a cold source compile costs ~1.2 s). Both are
  # separate products with separate switches, but only the client can be left out entirely.
  $clientOut = Join-Path $stage 'client.exe'
  $asmOut = Join-Path $stage 'lib\assembly\clipboard.dll'
  if ($client -or $assembly) { Write-Step 'compiling the accelerators' }
  if ($client) {
    $clientScript = Join-Path $root 'tools\build-client.ps1'
    if (Test-Path -LiteralPath $clientScript) {
      $log = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $clientScript -Out $clientOut 2>&1
      foreach ($line in @($log)) { Write-Host ('    ' + ([string]$line).Trim()) }
      if (-not (Test-Path -LiteralPath $clientOut)) { Write-Step '  (no client compiled: the package uses the PowerShell client)' }
    }
  }
  if ($assembly) {
    $assemblyScript = Join-Path $root 'tools\build-assembly.ps1'
    if (Test-Path -LiteralPath $assemblyScript) {
      $log = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $assemblyScript -Out $asmOut 2>&1
      foreach ($line in @($log)) { Write-Host ('    ' + ([string]$line).Trim()) }
    }
  }
  # Without a compiled assembly the package has to carry the source: lib\native.ps1 and
  # lib\panel\keyhook.ps1 read lib\assembly\*.cs and compile them in-process, which is what
  # makes the accelerator optional. A package with neither cannot open its panel at all, so
  # Assembly=0 (or a machine without csc) means "ship the source instead", not "ship nothing".
  if (-not (Test-Path -LiteralPath $asmOut)) {
    $csSrc = Join-Path $srcRoot 'lib\assembly'
    $shipped = 0
    if (Test-Path -LiteralPath $csSrc) {
      $csDst = Join-Path $stage 'lib\assembly'
      if (-not (Test-Path -LiteralPath $csDst)) { New-Item -ItemType Directory -Path $csDst -Force | Out-Null }
      foreach ($f in @(Get-ChildItem -LiteralPath $csSrc -Filter '*.cs' -File)) {
        Copy-Item -LiteralPath $f.FullName -Destination $csDst -Force
        $shipped++
      }
    }
    if ($shipped -eq 0) { Fail 'no clipboard.dll and no C# source: the package could not open its panel' }
    Write-Step ('  no clipboard.dll: shipped ' + $shipped + ' C# source file(s) to compile at run time')
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
  $suite = Join-Path $root 'tests\run.ps1'
  if (-not (Test-Path -LiteralPath $suite)) { Fail ('test suite not found: ' + $suite) }
  Write-Step 'running the CLI suite against the package'
  # no -Serial: the driver sees that -Source is not src\ and keeps the cli parts one at a time
  # (a packaged copy has no fake clipboard), while the packaging part still runs beside them
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

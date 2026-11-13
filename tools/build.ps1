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

  cli.ini holds the tooling settings: the [build] section is the output folder, whether to
  minify and rename, whether to verify the result by running the CLI suite against it,
  whether to also write a zip; [dev] and [test] belong to the other two commands. The
  version is not a build option: package.ini owns it. The development copy reads it
  at run time (src\lib\base.ps1); the build replaces that block with a literal, so a package
  carries the version and reads no file.

  Two batch files from scripts\ are copied next to the program's entry: install.bat (config
  init + migrate + install) and uninstall.bat (stop + uninstall purge).

  What goes in: the files cli.ini [build] Includes names, and only those. Nothing here knows
  what a file is: tools\utils\pipeline.ps1 holds one table - a .ps1 is minified, a .cmd/.bat
  compressed, a .sh compressed, an .ini stripped of its comments, a .cs under a product folder
  compiled - and this script only walks the list. The default list is the program scripts, the
  three launchers, the themes, the two batch helpers and the two product sources.
  What never goes in: src\data\, src\<name>.ini, tests\, tools\, dist\, .git - a package
  carries the program, not the history, the settings or the tooling.
#>
param(
  [string]$Config = ''
)

$ErrorActionPreference = 'Stop'
# this file lives in tools\: the repository root is one level up
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
# every tool prints its steps, warnings and failures the same way
. (Join-Path $root 'tools\utils\console.ps1')
# the program lives in src\, the build tooling and the docs stay at the repo root
$srcRoot = Join-Path $root 'src'
if (-not (Test-Path -LiteralPath $srcRoot)) { Fail ('missing: ' + $srcRoot) }

# Where a shipped file lands in the package: a file under src\ keeps the path it has there, a
# file outside src\ keeps the path it has under the repository root, and the rows in
# tools\utils\pipeline.ps1 name the few that belong at the package root instead.
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

# cli.ini is the only place a build setting may live. It is checked against
# tools\schema\cli.ps1 before anything else happens: a missing key, an unknown key, a value of
# the wrong type or a number outside its range stops the build with the list of problems, so a
# typo cannot turn into "the build quietly stopped minifying".
. (Join-Path $root 'tools\utils\schema.ps1')
$problems = @(Test-ToolConfigMap (Import-ToolSchema (Join-Path $root 'tools\schema\cli.ps1')) $cfg (Split-Path -Leaf $Config) 'build')
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

function CfgList([string]$key) {
  return @(Split-GlobList (Cfg $key))
}

# src\lib\base.ps1 keeps the version between two markers for the development run; a package
# gets the number itself instead of code that reads package.ini. The rule that sends a file
# here lives in tools\utils\pipeline.ps1, so $rel is whatever that path was.
function Get-VersionPatchedText([string]$text, [string]$version, [string]$rel) {
  $begin = $text.IndexOf('#@version-begin')
  $end = $text.IndexOf('#@version-end')
  if ($begin -lt 0 -or $end -lt $begin) { Fail ($rel + ' carries no #@version-begin / #@version-end block') }
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
# what to do with each file is one table, shared with the watcher
. (Join-Path $root 'tools\utils\pipeline.ps1')
$includeGlobs = CfgList 'Includes'
$excludeGlobs = CfgList 'Excludes'
# every glob is written relative to BaseUrl, which this same file sets: "." keeps them at the
# repository root, so a shipped path reads like the one on disk (src\..., scripts\...)
$baseSetting = (Cfg 'BaseUrl').Trim()
if (-not $baseSetting) { Fail 'cli.ini [build] BaseUrl is empty' }
$baseDir = Resolve-BaseDir $root $baseSetting
if (-not (Test-Path -LiteralPath $baseDir)) { Fail ('cli.ini [build] BaseUrl does not exist: ' + $baseSetting) }

$swBuild = Start-Step
Write-Step ('build ' + $name)
Write-Note ('settings ' + (Split-Path -Leaf $Config) + '   version ' + $version + '   from package.ini')
Write-Note ('output   ' + $dest)
Write-Note ('minify   ' + $(if ($minify) { 'yes' } else { 'no' }) + '   rename ' + $(if ($rename) { 'yes' } else { 'no' }) + '   verify ' + $(if ($verify) { 'yes' } else { 'no' }) + '   zip ' + $(if ($wantZip) { 'yes' } else { 'no' }))
Write-Note ('files    ' + [string]$includeGlobs.Count + ' glob(s)   overwrite ' + $(if ($overwrite) { 'yes' } else { 'no' }))

if ((Test-Path -LiteralPath $dest) -and -not $overwrite) { Fail ('already exists: ' + $dest + '   (set Overwrite=1 to replace it)') }

# ---------------------------------------------------------------- the file list
# cli.ini [build] Includes is the package and Excludes removes from it: one expansion for both,
# through the same call the watcher uses, so the two tools agree on what a glob means.
$pkgFiles = @(Expand-GlobList $baseDir $includeGlobs $excludeGlobs)
if ($pkgFiles.Count -eq 0) { Fail 'cli.ini [build] Includes reaches no file' }
$dropped = @(Expand-GlobList $baseDir $includeGlobs @()).Count - $pkgFiles.Count
if ($dropped -gt 0) { Write-Note ('excluded ' + [string]$dropped + ' file(s) listed in cli.ini [build] Excludes') }
$scriptFiles = @($pkgFiles | Where-Object { $_ -like '*.ps1' })

# ---------------------------------------------------------------- products (ahead of time)
# A .cs under a product folder means "compile this folder into one file": the list decides
# which products exist and tools\utils\pipeline.ps1 says how. Compiling writes into src\ before
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
$productOut = @{}
foreach ($p in @(Get-ProductList)) {
  if (-not $productSources.ContainsKey($p.Dir)) { continue }
  $built = Join-Path $srcRoot $p.Out
  $compiler = Join-Path $root $p.Script
  if (Test-Path -LiteralPath $compiler) {
    $swProduct = Start-Step
    $log = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $compiler -Out $built 2>&1
    # The product script reports its own result, and this loop reports the step: forwarding its
    # success line as well said the same thing twice, the first time indented as a detail. Only
    # what it says when something went wrong is worth passing on.
    foreach ($line in @($log)) {
      $text = ([string]$line).Trim()
      if (-not $text -or $text.StartsWith('[ok]')) { continue }
      Write-Note $text
    }
    if (Test-Path -LiteralPath $built) {
      $kb = [Math]::Round((Get-Item -LiteralPath $built).Length / 1KB, 1)
      Write-Done $swProduct ('compiled ' + $p.Label + '   ' + $kb + ' KB')
    }
  }
  if (Test-Path -LiteralPath $built) {
    $productOut[$p.Out] = $built
  } else {
    Write-Note ('no ' + $p.Label + ' - its sources travel and the program compiles them')
    foreach ($s in @($productSources[$p.Dir])) { $plainFiles.Add($s) }
  }
}
# a package that cannot start says so here, not when someone double-clicks it
foreach ($p in @(Get-ProductList)) {
  if (-not $p.Required) { continue }
  if (-not ($productOut.ContainsKey($p.Out) -or $productSources.ContainsKey($p.Dir))) {
    Fail ('cli.ini [build] Includes carries neither ' + $p.Dir + ' nor ' + $p.Out + ': a package cannot start without it')
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
      # program calls by path (the table in tools\utils\pipeline.ps1 names that folder)
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

  # Everything else goes through the table in tools\utils\pipeline.ps1: the handler for a path
  # says how the file is rewritten, and the path it keeps in the package is the one it had
  # under src\. A new kind of file is a row there, never a branch here.
  $ascii = New-Object System.Text.ASCIIEncoding
  $before = 0
  $after = 0
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($f in $plainFiles) {
    $rel = Get-PackageRel $f
    $target = Join-Path $stage $rel
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $source = $f
    $handler = Get-LibraryHandler $rel
    if ($handler -eq 'version') {
      # The development copy reads the version from package.ini. A package carries the number
      # itself, so the block is replaced before the minifier sees the file.
      $source = Join-Path $stageRoot ('verpatch\' + (Split-Path -Leaf $f))
      New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force | Out-Null
      [IO.File]::WriteAllText($source, (Get-VersionPatchedText ([IO.File]::ReadAllText($f)) $version $rel))
      $handler = 'script'
    }
    switch ($handler) {
      'script' {
        if (-not $minify) {
          Copy-Item -LiteralPath $source -Destination $target -Force
          $len = (Get-Item -LiteralPath $source).Length
          $before += $len
          $after += $len
          break
        }
        if ($rename) {
          $vars = $scopeMaps['*']
          if ($scopeMaps.ContainsKey($f)) { $vars = $scopeMaps[$f] }
          $globals = $globalMap
          if ($scopeMaps.ContainsKey($f)) { $globals = @{} }   # a plugin has a scope of its own
          $r = Invoke-MinifyFile -Path $source -OutPath $target -FunctionMap $map -ScriptVarMap $vars -GlobalVarMap $globals
        } else {
          $r = Invoke-MinifyFile -Path $source -OutPath $target -NoRename
        }
        $r.Path = $f
        $before += $r.Before
        $after += $r.After
        $rows.Add($r)
      }
      'batch' {
        # CRLF: cmd.exe reads both, and a batch file written with LF alone breaks on some
        # versions of the goto/label handling
        $text = [IO.File]::ReadAllText($f).Replace("`r`n", "`n").Replace("`n", "`r`n").TrimEnd()
        if ($minify) { $text = Compress-Batch $text }
        [IO.File]::WriteAllText($target, ($text + "`r`n"), $ascii)
      }
      'shell' {
        # the shell launchers need LF: sh would take the CR as part of the command
        $text = [IO.File]::ReadAllText($f)
        if ($minify) { $text = (Compress-Shell $text).TrimEnd() + "`n" }
        [IO.File]::WriteAllText($target, $text, $ascii)
      }
      'ini' {
        if ($minify) {
          $text = (Compress-Ini ([IO.File]::ReadAllText($f))).TrimEnd() + "`r`n"
          [IO.File]::WriteAllText($target, $text, $ascii)
        } else { Copy-Item -LiteralPath $f -Destination $target -Force }
      }
      default { Copy-Item -LiteralPath $f -Destination $target -Force }
    }
  }

  # a folder that cannot start is worth saying out loud here rather than when someone
  # double-clicks it: the three launchers are named after the program, so nothing is hard-coded
  foreach ($ext in @('.ps1', '.cmd', '.sh')) {
    $need = $app + $ext
    if (-not (Test-Path -LiteralPath (Join-Path $stage $need))) {
      Fail ('cli.ini [build] Includes does not ship ' + $need)
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
  # no -Serial: the driver sees that -Source is not src\ and keeps the cli parts one at a time
  # (a packaged copy has no fake clipboard), while the packaging part still runs beside them
  # The suite stays attached to this console instead of being piped into a variable: it prints
  # a row per part and a block with everything that failed, and capturing the stream turned a
  # run of several minutes into one silent line. A failing part says why on its own row.
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File $suite -Integration -Source $dest
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

Write-Host ''
Write-Done $swBuild ('build finished - ' + $dest)
Write-Host ''
Write-Note ('install.bat                   settings template + startup / desktop shortcuts')
Write-Note ('uninstall.bat                 stop, remove the shortcuts, delete data\ and the ini')
Write-Note ($app + '.cmd config init      write a commented ' + $app + '.ini')
Write-Note ($app + '.cmd install         startup shortcut + desktop shortcut')
exit 0

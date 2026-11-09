#Requires -Version 5.1
<#
  Self tests that have to run in-process.

  Two parts live here because they cannot be isolated the way the command line parts are:
  the structure guards (they parse the sources) and the unit tests (they dot-source the tool
  and call its functions by name). Everything that talks to the command line lives in
  tests\cli\*.ps1 and tests\pkg\*.ps1, the resident run in tests\e2e\serve.ps1, and
  tests\run.ps1 runs all of them.

  Usage:
    tests\run.ps1                                        every part, several at a time
    powershell -NoProfile -ExecutionPolicy Bypass -Sta -File tests\unit\unit.ps1
                                                         just this part

  -Sta is required: clipboard.ps1 uses System.Windows.Forms.
  Every group runs inside a sandbox copy of the tool under %TEMP%, so the store and
  clipboard.ini in the repo are never touched. The real clipboard is saved and
  restored around the run. Exit code is 1 when any check fails.
#>
[CmdletBinding()]
param(
  # directory holding clipboard.ps1 + lib + plugins + themes; default is this repo.
  # A packaged copy has minified internals, so the unit checks cannot run against one.
  [string]$Source = '',
  # tests\run.ps1 reads back one json file per part
  [string]$ResultFile = '',
  # the file tests\run.ps1 reads the progress line from; empty when run by hand
  [string]$ProgressFile = '',
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$defaultSource = Join-Path $repoRoot 'src'
if (-not $Source) { $Source = $defaultSource }
if (-not (Test-Path -LiteralPath $Source)) { Write-Error ('no such -Source: ' + $Source); exit 2 }
$srcRoot = (Resolve-Path -LiteralPath $Source).Path
$clipPs1 = Join-Path $srcRoot 'clipboard.ps1'
if (-not (Test-Path -LiteralPath $clipPs1)) { Write-Error ('cannot find ' + $clipPs1); exit 2 }

# this file is the unit group: it always runs, there is no switch to turn it off
$Unit = $true

# A packaged copy has its internal function names minified, so the unit checks (which call
# them by name through -Library) cannot run against one - the command line parts can.
$isPackaged = -not [string]::Equals($srcRoot.TrimEnd([char]92, [char]47), (Resolve-Path -LiteralPath $defaultSource).Path.TrimEnd([char]92, [char]47), [StringComparison]::OrdinalIgnoreCase)
if ($isPackaged) {
  Write-Output 'unit group skipped: a packaged copy has renamed internals'
  # nothing to run, and an empty result file would read as a broken part
  if ($ResultFile) {
    $payload = @{ Part = 'unit'; Source = $srcRoot; Results = @() }
    [IO.File]::WriteAllText($ResultFile, ($payload | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
  }
  exit 0
}

$script:results = New-Object System.Collections.Generic.List[object]

# This file is its own harness (it cannot dot-source tests\lib\harness.ps1: it owns the one
# sandbox the whole part shares), so it loads the reporter and the progress contract itself.
. (Join-Path $repoRoot 'tests\lib\reporter.ps1')
Initialize-TestReporter -Mode 'verbose' -Quiet:$Quiet
$script:unitTimings = New-Object System.Collections.Generic.List[object]
$script:unitProgress = @{ Pass = 0; Fail = 0; Skip = 0; Last = ''; At = [DateTime]::MinValue }

function Write-UnitProgress {
  $file = [string]$ProgressFile
  if (-not $file) { return }
  $now = Get-Date
  # five writes a second is enough for a progress line and keeps 579 checks cheap
  if (($now - $script:unitProgress.At).TotalMilliseconds -lt 200) { return }
  $script:unitProgress.At = $now
  $p = $script:unitProgress
  $line = [string]$p['Pass'] + ' ' + [string]$p['Fail'] + ' ' + [string]$p['Skip'] + ' ' + [string]$p['Last']
  $enc = $Utf8
  if ($null -eq $enc) { $enc = New-Object Text.UTF8Encoding $false }
  try { [IO.File]::WriteAllText($file, $line, $enc) } catch { }
}

function Add-UnitTiming([string]$what, [long]$ms) {
  $script:unitTimings.Add([pscustomobject]@{ What = $what; Ms = $ms })
}

# The version lives in package.ini. A development copy reads it at run time, a package
# carries it as a constant, so this is the number both of them have to report.
$programVersion = ''
$verFile = Join-Path $repoRoot 'package.ini'
if (Test-Path -LiteralPath $verFile) {
  # the key is Version=; .NET regex is case-sensitive, so the test reads it either way
  $verMatch = [regex]::Match([IO.File]::ReadAllText($verFile), '(?mi)^\s*version\s*=\s*(\S+)\s*$')
  if ($verMatch.Success) { $programVersion = $verMatch.Groups[1].Value }
}

function Check([string]$group, [string]$name, [bool]$ok, [string]$detail) {
  $now = Get-Date
  $ms = 0
  if ($null -ne $script:TestReport.LastMark) { $ms = [int](($now - $script:TestReport.LastMark).TotalMilliseconds) }
  $script:TestReport.LastMark = $now
  $result = $(if ($ok) { 'PASS' } else { 'FAIL' })
  $script:results.Add([pscustomobject]@{
      Group  = $group
      Test   = $name
      Result = $result
      Detail = $detail
      Ms     = $ms
    })
  $p = $script:unitProgress
  if ($result -eq 'PASS') { $p['Pass'] = [int]$p['Pass'] + 1 } else { $p['Fail'] = [int]$p['Fail'] + 1 }
  $p['Last'] = $name
  Write-TestCheck $group $name $result $detail $ms
  Write-UnitProgress
}

function Skip([string]$group, [string]$name, [string]$why) {
  $script:results.Add([pscustomobject]@{ Group = $group; Test = $name; Result = 'SKIP'; Detail = $why; Ms = 0 })
  $script:unitProgress['Skip'] = [int]$script:unitProgress['Skip'] + 1
  $script:unitProgress['Last'] = $name
  Write-TestCheck $group $name 'SKIP' $why 0
  Write-UnitProgress
}

# The drawing helpers take a Graphics plus plain values, so the unit group paints them onto
# a bitmap instead of needing a window. That needs the drawing assemblies loaded.
function Use-Drawing {
  foreach ($a in @('System.Drawing', 'System.Windows.Forms')) {
    try { Add-Type -AssemblyName $a -ErrorAction Stop } catch { }
  }
}

# A sandbox is a throw-away copy of the tool (script + lib + plugins + themes): the
# settings file sits next to the script, so DataDir= and the store stay inside the sandbox.
function New-Sandbox([string]$name) {
  $dir = Join-Path $tmpRoot $name
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Copy-Item -LiteralPath $clipPs1 -Destination $dir -Force
  foreach ($sub in @('lib', 'utils', 'schema', 'plugins', 'themes')) {
    $src = Join-Path $srcRoot $sub
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dir -Recurse -Force }
  }
  # the version lives in package.ini, one level above src\ in the repository and beside the
  # script in a sandbox - copying it keeps the sandbox reporting the real number
  $pkgIni = Join-Path $repoRoot 'package.ini'
  if (Test-Path -LiteralPath $pkgIni) { Copy-Item -LiteralPath $pkgIni -Destination $dir -Force }
  return $dir
}

# A sandbox whose clipboard is a file instead of the machine's: the one file that touches
# Windows is replaced (see tests\lib\fake-clip.ps1), so the sandbox can run beside another one
# and never disturbs what the user has copied.
function New-FakeSandbox([string]$name) {
  $dir = New-Sandbox $name
  $fake = Join-Path $repoRoot 'tests\lib\fake-clip.ps1'
  if (Test-Path -LiteralPath $fake) {
    Copy-Item -LiteralPath $fake -Destination (Join-Path $dir 'lib\clip.ps1') -Force
  }
  return $dir
}

# ---------------------------------------------------------------- cli.ini
# cli.ini (repository root) is the harness configuration, read with the parser the tool itself
# uses: utils\ini.ps1 is pure, and the repository copy is loaded rather than $srcRoot, so this
# also works when -Source points at a minified package whose function names are rewritten.
$repoIniParser = Join-Path $defaultSource 'utils\ini.ps1'
if (Test-Path -LiteralPath $repoIniParser) { . $repoIniParser }
$script:TestIni = @{}
$testIniPath = Join-Path $repoRoot 'cli.ini'
if ((Test-Path -LiteralPath $testIniPath) -and (Get-Command Read-IniDoc -ErrorAction SilentlyContinue)) {
  $script:TestIni = (Read-IniDoc ([IO.File]::ReadAllLines($testIniPath, [Text.Encoding]::UTF8))).Map
}

# One CLI call in its own process: a command has to start from nothing, the way the user's shell
# does. (Sharing one process and running each call in a runspace looked like a 3.4 s -> 1.0 s
# win, but a plugin loaded there calls back into the tool through a script block whose session
# state is stale, so `pin` lost Set-RecordMark. Speed comes from running sandboxes side by side
# instead - see the [test] section of cli.ini.)
function Clip([string]$sandbox, [string[]]$cliArgs) {
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', (Join-Path $sandbox 'clipboard.ps1')) + $cliArgs
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $out = (& powershell @a 2>&1 | Out-String)
  $watch.Stop()
  Add-UnitTiming ($cliArgs -join ' ') $watch.ElapsedMilliseconds
  return $out
}

function Test-MutexFree([string]$name) {
  try {
    $m = New-Object System.Threading.Mutex($false, $name)
    $free = $m.WaitOne(0)
    if ($free) { $m.ReleaseMutex() }
    $m.Dispose()
    return $free
  } catch { return $true }
}

# the resident polls the clipboard, so a write can lose the race - retry a few times
function Set-Clip([string]$value) {
  for ($i = 0; $i -lt 6; $i++) {
    try { Set-Clipboard -Value $value -ErrorAction Stop; return $true } catch { Start-Sleep -Milliseconds 150 }
  }
  return $false
}

$tmpRoot = Join-Path $env:TEMP ('clipboard-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$unitDir = New-Sandbox 'unit'
# the command line sandboxes carry their own clipboard (tests\lib\fake-clip.ps1), so the parts
# can run side by side and the machine clipboard is left alone
$intDir = New-FakeSandbox 'integration'
# a package runs without dot-sourcing the tool, so the encoding the fixtures
# write with has to exist here instead of coming from the main script
$Utf8 = New-Object System.Text.UTF8Encoding $false

$clipBak = ''
try { $clipBak = (Get-Clipboard -Raw -ErrorAction Stop) } catch { }

# A running resident records every clipboard write the tests make, so pause it for the
# duration of the run and resume it afterwards - the real history stays untouched.
$wePaused = $false
if (-not (Test-MutexFree 'Local\clipboard.daemon')) {
  $st = & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $clipPs1 status 2>&1 | Out-String
  if ($st -match 'capture     : paused') {
    Write-Output 'resident is already paused - leaving it paused'
  }
  else {
    [void](& powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $clipPs1 pause 2>&1)
    $wePaused = $true
    Write-Output 'resident paused for the run (resumed at the end)'
  }
}

try {

  # ------------------------------------------------------------ structure guards
  # The program is one entry file plus lib\ modules that are dot-sourced into a single
  # scope. These assertions keep that contract from decaying: a module must not derive
  # paths from its own location, must not take parameters, and must not redefine a name
  # another module already owns. They run for a packaged copy too, where the only extra
  # rule (sizes, the $Root line) would not survive renaming.
  $entryPath = Join-Path $srcRoot 'clipboard.ps1'
  $libPath = Join-Path $srcRoot 'lib'
  $utilsPath = Join-Path $srcRoot 'utils'
  $schemaPath = Join-Path $srcRoot 'schema'
  $libFiles = @()
  if (Test-Path -LiteralPath $libPath) { $libFiles = @(Get-ChildItem -LiteralPath $libPath -Filter '*.ps1' -File -Recurse | Sort-Object -Property Name) }
  # the pure helpers and the schema files follow the same rules (no param block, no path
  # from their own file, no duplicate name, a line budget), so they are walked as well
  if (Test-Path -LiteralPath $utilsPath) { $libFiles += @(Get-ChildItem -LiteralPath $utilsPath -Filter '*.ps1' -File -Recurse | Sort-Object -Property Name) }
  if (Test-Path -LiteralPath $schemaPath) { $libFiles += @(Get-ChildItem -LiteralPath $schemaPath -Filter '*.ps1' -File | Sort-Object -Property Name) }

  # the entry file names these by relative path; a package must carry all of them
  $requiredLib = @('lib\base', 'lib\native', 'lib\panel\keyhook', 'lib\theme-stub', 'lib\settings', 'lib\marks', 'lib\ordering',
    'lib\media', 'lib\cfhtml', 'lib\clip', 'lib\blobs', 'lib\store', 'lib\migrate', 'lib\transfer', 'lib\modifiers', 'lib\apprules', 'lib\entry', 'lib\query', 'lib\select', 'lib\panel\picker-geom', 'lib\panel\anim',
    'lib\panel\picker-draw', 'lib\panel\picker-edit', 'lib\panel\media-render', 'lib\panel\pinlist', 'lib\panel\preview', 'lib\panel\picker', 'lib\serve', 'lib\shortcut',
    'lib\config', 'lib\config-template', 'lib\usage', 'lib\dispatch',
    'utils\ini', 'utils\inifile', 'utils\schema', 'utils\log', 'utils\time', 'utils\format', 'utils\dpi', 'utils\hotkey',
    'utils\query-words', 'utils\pinyin', 'utils\transfer', 'utils\apprules', 'utils\fileio',
    'utils\hash', 'utils\cfhtml', 'utils\image',
    'schema\clipboard', 'schema\theme')
  $missingLib = @()
  foreach ($m in $requiredLib) {
    if (-not (Test-Path -LiteralPath (Join-Path $srcRoot ($m + '.ps1')))) { $missingLib += $m }
  }
  Check 'struct' 'every required module exists' ($missingLib.Count -eq 0) ($missingLib -join ', ')

  # the plugin layer is three files; a package carries all of them or none (plugins.ps1 is
  # the optional one, and the other two mean nothing without it)
  $pluginLayer = @('plugins', 'plugin-settings', 'plugin-marks')
  $pluginPresent = @($pluginLayer | Where-Object { Test-Path -LiteralPath (Join-Path $libPath ($_ + '.ps1')) })
  Check 'struct' 'plugin layer ships complete' (($pluginPresent.Count -eq 0) -or ($pluginPresent.Count -eq $pluginLayer.Count)) ($pluginPresent -join ', ')

  $badParse = @()
  $badParam = @()
  $badPath = @()
  foreach ($f in $libFiles) {
    $tk = $null
    $pe = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tk, [ref]$pe)
    if ($pe.Count -gt 0) { $badParse += ($f.Name + ': ' + $pe[0].Message); continue }
    if ($ast.ParamBlock) { $badParam += $f.Name }
    # $PSScriptRoot inside lib\ points at lib\, so any path built from it is one level
    # deep. Look at the code, not at the prose: the module headers explain this rule.
    $selfPaths = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and [string]$node.VariablePath.UserPath -match '(?i)(^|:)(PSScriptRoot|PSCommandPath)$' }, $true))
    if ($selfPaths.Count -gt 0) { $badPath += $f.Name }
  }
  Check 'struct' 'every module parses' ($badParse.Count -eq 0) ($badParse -join '; ')
  Check 'struct' 'modules declare no param block' ($badParam.Count -eq 0) ($badParam -join ', ')
  Check 'struct' 'modules never derive paths from their own file' ($badPath.Count -eq 0) ($badPath -join ', ')

  # a duplicate top-level name lets one module silently overwrite another (shared scope);
  # theme-stub.ps1 is the documented exception - lib/themes.ps1 replaces its stubs
  $owner = @{}
  $dups = @()
  foreach ($f in @(Get-Item -LiteralPath $entryPath) + $libFiles) {
    $tk = $null
    $pe = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tk, [ref]$pe)
    if ($pe.Count -gt 0 -or -not $ast.EndBlock) { continue }
    foreach ($st in $ast.EndBlock.Statements) {
      if ($st -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
      $fnName = [string]$st.Name
      if (-not $owner.ContainsKey($fnName)) { $owner[$fnName] = $f.Name; continue }
      $prevOwner = [string]$owner[$fnName]
      $both = @($prevOwner, $f.Name)
      if (($both -contains 'theme-stub.ps1') -and ($both -contains 'themes.ps1')) { continue }
      $dups += ($fnName + ' (' + $prevOwner + ', ' + $f.Name + ')')
    }
  }
  Check 'struct' 'no duplicate function names' ($dups.Count -eq 0) ($dups -join ', ')

  # A WH_KEYBOARD_LL hook outlives the panel's own teardown and swallows every key in the
  # system, so it has to be released from a finally block: releasing it after the message
  # loop means one exception on the way out leaves the keyboard dead.
  $pickerText = [IO.File]::ReadAllText((Join-Path $srcRoot 'lib\panel\picker.ps1'))
  Check 'struct' 'no whole-window opacity transition' (-not ($pickerText -match '\$form\.Opacity\s*=')) ''

  # A payload kind is a leading character. Every module asks base.ps1's predicates instead of
  # comparing that character itself, so adding a kind stays a change in two files.
  $prefixFiles = @($libFiles | Where-Object { $_.Name -notin @('base.ps1', 'entry.ps1', 'media.ps1') })
  $prefixFiles += @(Get-ChildItem -LiteralPath (Join-Path $srcRoot 'plugins') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
  $offenders = @()
  foreach ($f in $prefixFiles) {
    if ([IO.File]::ReadAllText($f.FullName) -match '\[char\](1|3)\b') { $offenders += $f.Name }
  }
  Check 'struct' 'payload kinds go through the predicates' ($offenders.Count -eq 0) ($offenders -join ', ')

  # The panel layout and its timers are read from the two tables base.ps1 publishes, so a
  # theme or a tuning pass touches one place. A bare literal creeping back into the draw
  # code is how the row height and the hit test drifted apart before. The table names are
  # renamed in a package, so only the source can be checked.
  if (-not $isPackaged) {
    $metricRefs = [regex]::Matches($pickerText, '\$m\[').Count
    $timingRefs = [regex]::Matches($pickerText, '\$script:Timing\[').Count
    Check 'struct' 'row layout comes from the metric table' ($metricRefs -ge 12) ($metricRefs -as [string])
    Check 'struct' 'panel timers come from the timing table' ($timingRefs -ge 8) ($timingRefs -as [string])
  }
  if (-not $isPackaged) {
    # the packaged copy has its function names minified, so only the source can be checked
    $pickerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $srcRoot 'lib\panel\picker.ps1'), [ref]$null, [ref]$null)
    $finallyText = (@($pickerAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true) |
        ForEach-Object { $_.Finally.Extent.Text }) -join "`n")
    Check 'struct' 'the key hook is released in a finally' ($finallyText -match 'Disable-KeyHook') ''
  }

  # sizes and the single $Root line only make sense in the readable source
  if (-not $isPackaged) {
    $entryLines = @([IO.File]::ReadAllLines($entryPath)).Count
    # 220, not 200: the entry also decides whether the resident answers the command instead of
    # a fresh process (the proxy block), which is a table plus a few lines of glue
    Check 'struct' 'entry file stays an entry point' ($entryLines -le 220) ([string]$entryLines + ' lines')

    # the entry loads only the module groups a command can reach. A command the dispatcher
    # knows and the table does not would reach the default group and fail at run time, so the
    # two lists have to line up; the group lists in turn have to name files that exist.
    $entryText = [IO.File]::ReadAllText($entryPath)
    $dispatchText = [IO.File]::ReadAllText((Join-Path $srcRoot 'lib\dispatch.ps1'))
    $dispatched = @([regex]::Matches($dispatchText, "(?m)^  '([a-z0-9-]+)' \{") | ForEach-Object { $_.Groups[1].Value })
    $groupBlock = ($entryText -split '\$groupModules = @\{')[1]
    if ($groupBlock) { $groupBlock = ($groupBlock -split "\r?\n\}")[0] } else { $groupBlock = '' }
    $tableBlock = ($entryText -split '\$commandGroups = @\{')[1]
    if ($tableBlock) { $tableBlock = ($tableBlock -split "\r?\n\}")[0] } else { $tableBlock = '' }
    $tableKeys = @([regex]::Matches($tableBlock, "(?m)^  '([a-z0-9-]+)'") | ForEach-Object { $_.Groups[1].Value })
    $groupNames = @([regex]::Matches($groupBlock, '(?m)^  ([a-z]+)\s+=') | ForEach-Object { $_.Groups[1].Value })
    # ui and serve are answered by the panel branch of the entry, everything else by the table
    $unmapped = @($dispatched | Where-Object { $tableKeys -notcontains $_ -and @('ui', 'serve') -notcontains $_ })
    Check 'struct' 'every dispatched command is in the module table' ($dispatched.Count -ge 15 -and $unmapped.Count -eq 0) (($unmapped -join ', ') + ' / ' + $dispatched.Count + ' commands')
    $unknownCommand = @($tableKeys | Where-Object { $dispatched -notcontains $_ })
    Check 'struct' 'the module table names no unknown command' ($tableKeys.Count -ge 15 -and $unknownCommand.Count -eq 0) ($unknownCommand -join ', ')
    $usedGroups = @($tableBlock -split "'" | Where-Object { $groupNames -contains $_ } | Select-Object -Unique)
    Check 'struct' 'the module table names groups that exist' ($groupNames.Count -ge 4 -and $usedGroups.Count -ge 1) (($groupNames -join ', ') + ' / used ' + ($usedGroups -join ', '))
    $groupFiles = @([regex]::Matches($groupBlock, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -match '^[a-z]' })
    $missingGroupFile = @($groupFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $srcRoot ($_ + '.ps1'))) })
    Check 'struct' 'every module in a group exists' ($groupFiles.Count -ge 15 -and $missingGroupFile.Count -eq 0) (($missingGroupFile -join ', ') + ' / ' + $groupFiles.Count + ' modules')

    # the renamer replaces a variable by its parsed extent, and a splat's extent starts at
    # the '@': rebuilding it as `$name` turns `f @h` into `f $h`, a positional argument
    $minifyPath = Join-Path $repoRoot 'tools\utils\minify.ps1'
    if (Test-Path -LiteralPath $minifyPath) {
      . $minifyPath
      $tmpIn = Join-Path ([IO.Path]::GetTempPath()) ('splat-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
      $tmpOut = $tmpIn + '.min.ps1'
      try {
        [IO.File]::WriteAllText($tmpIn, ("function f { param(`$x, `$y) `$x }" + "`r`n`r`n" + "`$h = @{ x = 1; y = 2 }" + "`r`n`r`n" + "f @h" + "`r`n"), $Utf8)
        [void](Invoke-MinifyFile -Path $tmpIn -OutPath $tmpOut)
        $min = [IO.File]::ReadAllText($tmpOut)
        Check 'struct' 'the renamer keeps a splat a splat' ($min -match '(?m)^f @[A-Za-z_]') $min.Trim()
      } finally {
        Remove-Item -LiteralPath $tmpIn, $tmpOut -Force -ErrorAction SilentlyContinue
      }
    }

    # the tooling lives outside src\: package.ini declares the commands, cli runs them
    $tooling = @('package.ini', 'cli.ini', 'cli.ps1', 'cli.cmd', 'cli.sh',
      'tools\build.ps1', 'tools\dev.ps1', 'tools\test.ps1', 'tools\bench.ps1', 'tools\shot.ps1',
      'tools\build-client.ps1', 'tools\build-assembly.ps1',
      'tools\utils\minify.ps1', 'tools\utils\ini.ps1', 'tools\utils\globs.ps1', 'tools\utils\csc.ps1',
      'tools\utils\console.ps1', 'tools\utils\pipeline.ps1',
      'src\lib\client\client.cs', 'src\lib\assembly\cb.native.cs', 'src\lib\assembly\cb.keyhook.cs')
    $missingTool = @()
    foreach ($tool in $tooling) {
      if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $tool))) { $missingTool += $tool }
    }
    Check 'struct' 'the tooling ships with the repo' ($missingTool.Count -eq 0) ($missingTool -join ', ')
    $pkgText = ''
    if (Test-Path -LiteralPath (Join-Path $repoRoot 'package.ini')) { $pkgText = [IO.File]::ReadAllText((Join-Path $repoRoot 'package.ini')) }
    # keys are PascalCase: [package] holds Name/Version, [scripts] holds one key per command
    $scriptBlock = ''
    $sm = [regex]::Match($pkgText, '(?ms)^\s*\[scripts\]\s*$(.*?)(?=^\s*\[|\z)')
    if ($sm.Success) { $scriptBlock = $sm.Groups[1].Value }
    $noCmd = @()
    foreach ($cmd in @('Dev', 'Build', 'Client', 'Assembly', 'Test', 'Shot')) {
      if (-not ($scriptBlock -match ('(?m)^' + $cmd + '=\S'))) { $noCmd += $cmd }
    }
    Check 'struct' 'package.ini declares every command' (($pkgText -match '(?m)^Name=\S') -and ($pkgText -match '(?m)^Version=\d+\.\d+\.\d+') -and $noCmd.Count -eq 0) ($noCmd -join ', ')
    # every tracked ini follows the shared convention: lower case section names, PascalCase keys
    $badIni = @()
    foreach ($iniRel in @('package.ini', 'cli.ini', 'src\themes\win11-dark.ini', 'src\themes\win11-light.ini')) {
      $iniFile = Join-Path $repoRoot $iniRel
      if (-not (Test-Path -LiteralPath $iniFile)) { $badIni += ($iniRel + ': missing'); continue }
      foreach ($line in [IO.File]::ReadAllLines($iniFile)) {
        $l = $line.Trim()
        if ($l.Length -eq 0 -or $l.StartsWith('#') -or $l.StartsWith(';')) { continue }
        if ($l.StartsWith('[')) {
          if ($l -cnotmatch '^\[[a-z-]+\]$') { $badIni += ($iniRel + ': ' + $l) }
          continue
        }
        if ($l -cnotmatch '^[A-Z][A-Za-z0-9]*=') { $badIni += ($iniRel + ': ' + $l) }
      }
    }
    Check 'struct' 'ini files use lower case sections and PascalCase keys' ($badIni.Count -eq 0) ($badIni -join ', ')

    # The program and the tooling each carry an ini parser (src\utils\ini.ps1 + inifile.ps1 and
    # tools\utils\ini.ps1). The rules are the same on paper; this keeps them the same in fact,
    # because a rule that holds for clipboard.ini and not for cli.ini fails silently. Both files
    # define Read-IniDoc, so the program copy is parsed first and then replaced by the tool copy.
    # The tooling schemas and the two settings files need no test here: every command validates
    # the file it reads against its schema before acting on it.
    $iniSample = @(
      '# a comment', '; another', '[section]', 'Key=value', 'Quoted="a b"',
      'Empty=', 'NoEquals', '  padded  =  text  ', 'Dup=1', 'Dup=2', 'Top=1'
    )
    . (Join-Path $defaultSource 'utils\ini.ps1')
    $programDoc = Read-IniDoc $iniSample
    . (Join-Path $repoRoot 'tools\utils\ini.ps1')
    $toolDoc = Read-IniDoc $iniSample
    $iniDiff = @()
    foreach ($k in @($programDoc.Map.Keys)) {
      if (-not $toolDoc.Map.ContainsKey($k)) { $iniDiff += ('src only: ' + $k); continue }
      if ([string]$programDoc.Map[$k] -cne [string]$toolDoc.Map[$k]) { $iniDiff += ('differs: ' + $k) }
    }
    foreach ($k in @($toolDoc.Map.Keys)) {
      if (-not $programDoc.Map.ContainsKey($k)) { $iniDiff += ('tools only: ' + $k) }
    }
    # order matters as much as the values: both readers hand the keys out in file order, and
    # `config` prints them that way
    if ((@($programDoc.Keys) -join '|') -cne (@($toolDoc.Keys) -join '|')) { $iniDiff += 'key order differs' }
    Check 'struct' 'the program and the tooling parse ini the same way' ($iniDiff.Count -eq 0) ($iniDiff -join ', ')

    $rootHits = ([regex]::Matches([IO.File]::ReadAllText($entryPath), '(?m)^\$Root = Split-Path -Parent \$PSCommandPath\s*$')).Count
    Check 'struct' 'tool root is computed once, in the entry' ($rootHits -eq 1) ([string]$rootHits + ' occurrence(s)')

    # The panel must never take the foreground: a low-level keyboard hook feeds its controls
    # instead (lib/panel/keyhook.ps1), so the user's window keeps the focus and the caret. The
    # takeover fallback (no hook, or an IME) still hands the foreground back on close.
    $pickerText = [IO.File]::ReadAllText((Join-Path $libPath 'panel\picker.ps1'))
    Check 'struct' 'panel is shown without ShowDialog' (-not ($pickerText -match '\$form\.ShowDialog\(')) 'form.ShowDialog found'
    $topHits = ([regex]::Matches($pickerText, '(?m)^\s*\$form\.TopMost\s*=')).Count
    Check 'struct' 'panel is raised without the TopMost property' ($topHits -eq 0) ([string]$topHits + ' assignment(s)')
    $showHits = ([regex]::Matches($pickerText, '(?m)^\s*\$form\.Show\(\)\s*$')).Count
    Check 'struct' 'panel is shown once, non-modally' ($showHits -eq 1) ([string]$showHits + ' call(s)')
    $winText = [IO.File]::ReadAllText((Join-Path $libPath 'native.ps1'))
    # the platform C# lives in lib\assembly (a package ships only the compiled
    # lib\assembly\clipboard.dll), so the check reads the repository source even when -Source
    # points at a package
    $winCs = Join-Path $defaultSource 'lib\assembly\cb.native.cs'
    if (Test-Path -LiteralPath $winCs) { $winText += [IO.File]::ReadAllText($winCs) }
    Check 'struct' 'the panel form never activates' (($winText -match 'ShowWithoutActivation') -and ($winText -match '0x08000000')) 'no-activate override missing'
    Check 'struct' 'panel hands the foreground back when it closes' ($pickerText -match 'SetForegroundWindow\(\$prev\)') 'restore call missing'
    Check 'struct' 'panel installs and removes the key hook' (($pickerText -match 'Enable-KeyHook') -and ($pickerText -match 'Disable-KeyHook')) 'hook calls missing'
    # the rows are painted by Cb.PinList, which has no Items collection: a leftover
    # $lst.Items.Count silently reads 0 and the row never repaints
    Check 'struct' 'panel reads the list through its own members' (-not ($pickerText -match '\$lst\.Items\b')) '$lst.Items found'
    Check 'struct' 'paste releases the key hook before injecting' (($pickerText -match '(?s)function Paste-Clip\s*\{.{0,400}Disable-KeyHook')) 'Disable-KeyHook missing before SendKeys'
    # A drop-down that outlives the panel keeps the menu filter WinForms installed for it,
    # and that filter eats every later click of the process: whichever path closes the panel
    # has to close the menu first, and a click on the open menu is never a click outside.
    Check 'struct' 'panel closes the menu before it closes itself' ($pickerText -match '(?s)Add_FormClosing\(\{.{0,600}\$cm\.Close\(\)') 'menu not closed in FormClosing'
    Check 'struct' 'an open menu never counts as a click outside' ($pickerText -match '\$cm\.Visible[^\r\n]*-and -not \$form\.Bounds') 'outside-click check ignores the menu'
    # per-open GDI handles: the group heading font and the rounded region the form paints with
    $drawText = [IO.File]::ReadAllText((Join-Path $libPath 'panel\picker-draw.ps1'))
    Check 'struct' 'panel releases its menu font and form region' (($pickerText -match 'groupFont\.Dispose\(\)') -and ($drawText -match 'function Update-PanelRegion')) 'GDI handles released nowhere'
    # hover is a card that waits and is prepared once, not a tooltip rebuilt on every move
    Check 'struct' 'hover shows a card, not a tooltip' (-not ($pickerText -match 'Windows\.Forms\.ToolTip')) 'ToolTip found in the picker'
    # an activating popup deactivates the window the user came from; Explorer's address bar and
    # search box collapse then, and the paste that follows lands nowhere
    Check 'struct' 'the context menu never takes the foreground' ($pickerText -match '(?s)\[void\]\$cm\.Handle.{0,200}0x08000000') 'menu activation guard missing'
    Check 'struct' 'the card waits for the cursor to rest' ($pickerText -match 'PvIdx[^\r\n]*PvAt') 'no hover rest timer'

    # the Shown handler must go through Focus-Search: taking the real focus there would
    # activate the panel and defeat the hook model
    $tk = $null
    $pe = $null
    $pickerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $libPath 'panel\picker.ps1'), [ref]$tk, [ref]$pe)
    $shownBlocks = @($pickerAst.FindAll({
          param($node)
          $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
          [string]$node.Member.Value -eq 'Add_Shown' -and $node.Arguments.Count -gt 0
        }, $true))
    $shownFocus = 0
    $shownPaint = 0
    $shownHelper = 0
    foreach ($b in $shownBlocks) {
      $text = $b.Arguments[0].Extent.Text
      if ($text -match '\.Focus\(') { $shownFocus++ }
      if ($text -match 'SearchFocus\s*=\s*\$true') { $shownPaint++ }
      if ($text -match 'Focus-Search') { $shownHelper++ }
    }
    Check 'struct' 'the Shown handler never takes the real focus' ($shownBlocks.Count -eq 1 -and $shownFocus -eq 0) ([string]$shownBlocks.Count + ' handler(s), ' + [string]$shownFocus + ' Focus call(s)')
    Check 'struct' 'the Shown handler asks Focus-Search' ($shownHelper -eq 1) ([string]$shownHelper + ' call(s)')
    Check 'struct' 'the Shown handler paints the search box active' ($shownPaint -eq 1) ([string]$shownPaint + ' mark(s)')
  }

  # ---------------------------------------------------------------- unit tests
  if ($Unit) {
    . (Join-Path $unitDir 'clipboard.ps1') -Library
    $ErrorActionPreference = 'Continue'   # the dot-sourced script sets Stop

    # the store has a single API (records); tests only care about the payloads
    function Payloads {
      $o = New-Object System.Collections.Generic.List[string]
      foreach ($r in @(Get-Records)) { $o.Add($r.Payload) }
      return $o.ToArray()
    }

    $h = Parse-Hotkey 'Ctrl+Alt+V'
    Check 'unit' 'Parse-Hotkey mods ctrl+alt' ($h.Mods -eq 3) ('mods=0x' + $h.Mods.ToString('X2'))
    Check 'unit' 'Parse-Hotkey vk V' ($h.Vk -eq 0x56) ('vk=0x' + $h.Vk.ToString('X2'))

    $h = Parse-Hotkey 'Win+Shift+V'
    Check 'unit' 'Parse-Hotkey mods win+shift' ($h.Mods -eq 0x0C) ('mods=0x' + $h.Mods.ToString('X2'))

    $h = Parse-Hotkey 'ctrl + alt + f9'
    Check 'unit' 'Parse-Hotkey F9 case/space' ($h.Vk -eq 0x78 -and $h.Mods -eq 3) ('vk=0x' + $h.Vk.ToString('X2'))

    $h = Parse-Hotkey 'Ctrl+Alt+`'
    Check 'unit' 'Parse-Hotkey backtick' ($h.Vk -eq 0x60) ('vk=0x' + $h.Vk.ToString('X2'))

    Check 'unit' 'Parse-Hotkey unknown key' ((Parse-Hotkey 'Ctrl+Nope').Vk -eq 0) ''

    Check 'unit' 'Format-Item newlines' ((Format-Item "a`r`nb" 40) -eq 'a <NL> b') ''

    $files = ([string][char]1) + "C:\x\a.txt`nD:\y\b.txt"
    Check 'unit' 'Format-Item file drop' ((Format-Item $files 80) -eq '[files] a.txt, b.txt') (Format-Item $files 80)

    $cut = Format-Item ('x' * 50) 10
    Check 'unit' 'Format-Item truncates' ($cut.Length -eq 13 -and $cut.EndsWith('...')) $cut

    # hover preview: the payload is clamped before it is split, so the card costs the same
    # whatever the size of the entry is
    $pvLines = Get-PreviewLines ((('line ' + [Environment]::NewLine) * 4000)) 40 6
    Check 'unit' 'preview fills the card and marks the rest' ($pvLines.Count -eq 6 -and $pvLines[5] -eq '...') ([string]$pvLines.Count + ' lines, last=' + $pvLines[5])
    $pvCut = Get-PreviewLines ('x' * 500) 20 2
    Check 'unit' 'preview cuts a long line to the card width' ($pvCut.Count -eq 1 -and $pvCut[0].Length -eq 20 -and $pvCut[0].EndsWith('...')) ([string]$pvCut[0].Length)
    $pvInfo = Get-PreviewInfo ('a' * 9000)
    Check 'unit' 'preview counts the clamped head' ($pvInfo -match '6000\+ chars') $pvInfo
    # PreviewChars is a setting now, so the card really reads only that much
    $savedChars = $script:PreviewChars
    $script:PreviewChars = 200
    $pvSmall = Get-PreviewLines ('y' * 900) 60 4
    Check 'unit' 'PreviewChars bounds what the card reads' ($pvSmall.Count -eq 1 -and $pvSmall[0].Length -eq 60 -and $pvSmall[0].EndsWith('...')) ([string]$pvSmall.Count)
    $script:PreviewChars = $savedChars
    $pvFiles = Get-PreviewLines $files 60 3
    Check 'unit' 'preview names the files of a file list' ($pvFiles[0] -match '\[files\]' -and $pvFiles[0] -match 'a.txt') $pvFiles[0]

    # config file
    $cfg = Join-Path $unitDir 'clipboard.ini'
    if (Test-Path -LiteralPath $cfg) { Remove-Item -LiteralPath $cfg -Force }
    $written = Write-IniTemplate
    Check 'unit' 'Write-IniTemplate creates file' (Test-Path -LiteralPath $written) $written
    $template = [IO.File]::ReadAllText($written)
    Check 'unit' 'template has defaults' (($template -match 'Hotkey=Ctrl\+Alt\+V') -and ($template -match 'MaxItems=300')) ''

    $lines = @('# hash comment', '; semi comment', 'Hotkey=Ctrl+Shift+F9', 'Theme = light ', 'Quoted="a b"', 'Garbage', 'MaxItems=7')
    [IO.File]::WriteAllLines($cfg, $lines, $Utf8)
    $kv = Read-Ini
    Check 'unit' 'Read-Ini skips comments' (-not $kv.ContainsKey('# hash comment')) ''
    Check 'unit' 'Read-Ini trims value' ($kv['Theme'] -eq 'light') ('Theme=' + $kv['Theme'])
    Check 'unit' 'Read-Ini strips quotes' ($kv['Quoted'] -eq 'a b') ('Quoted=' + $kv['Quoted'])
    Check 'unit' 'Read-Ini skips malformed' (-not $kv.ContainsKey('Garbage')) ''
    Check 'unit' 'Read-Ini keeps number' ($kv['MaxItems'] -eq '7') ('MaxItems=' + $kv['MaxItems'])
    Check 'unit' 'Read-Ini reads hotkey' ($kv['Hotkey'] -eq 'Ctrl+Shift+F9') ('Hotkey=' + $kv['Hotkey'])

    # every .ini follows one rule: "[a]" + "b=1" is the same key as "a.b=1", written flat
    [IO.File]::WriteAllLines($cfg, @('Theme=win11-dark', '[item-marks]', 'MaxPins=50', 'StickyPins=1'), $Utf8)
    $kv = Read-Ini
    Check 'unit' 'a section prefixes the keys that follow' (($kv['item-marks.MaxPins'] -eq '50') -and ($kv['item-marks.StickyPins'] -eq '1') -and ($kv['Theme'] -eq 'win11-dark')) ($kv['item-marks.MaxPins'])
    [void](Set-IniKey 'item-marks.MaxPins' '7')
    $secText = [IO.File]::ReadAllText($cfg)
    Check 'unit' 'a grouped key is rewritten inside its section' (($secText -match '(?m)^\[item-marks\]\r?$') -and ($secText -match '(?m)^MaxPins=7\r?$') -and (-not ($secText -match '(?m)^item-marks\.MaxPins='))) $secText.Trim()
    $kv = Read-Ini
    Check 'unit' 'the rewritten key reads back' ($kv['item-marks.MaxPins'] -eq '7') ($kv['item-marks.MaxPins'])

    # one engine for every .ini: a parse is cached per file and re-used until the file changes
    [IO.File]::WriteAllLines($cfg, @('MaxItems=11'), $Utf8)
    $firstRead = Read-Ini
    $secondRead = Read-Ini
    Check 'unit' 'an unchanged file is parsed once' ([object]::ReferenceEquals($firstRead, $secondRead)) ''
    # the length is the same as the value below, so only the write time tells them apart
    [IO.File]::WriteAllLines($cfg, @('MaxItems=12'), $Utf8)
    $external = Read-Ini
    Check 'unit' 'an external rewrite is noticed' ($external['MaxItems'] -eq '12') ('MaxItems=' + $external['MaxItems'])
    [void](Set-IniKey 'MaxItems' '13')
    $afterWrite = Read-Ini
    Check 'unit' 'a write through the engine is noticed' ($afterWrite['MaxItems'] -eq '13') ('MaxItems=' + $afterWrite['MaxItems'])
    # a repeated key keeps the last value; the file order is what the command list is drawn from
    $parsed = Read-IniDoc @('[pkg]', 'B=1', 'A=2', 'B=3')
    Check 'unit' 'a repeated key keeps the last value' ($parsed.Map['pkg.B'] -eq '3') ('B=' + $parsed.Map['pkg.B'])
    Check 'unit' 'the key order follows the file' (($parsed.Keys -join ',') -eq 'pkg.B,pkg.A') ($parsed.Keys -join ',')

    # Apply-Config must pick up the paste timings and the fallback list
    [IO.File]::WriteAllLines($cfg, @('ModReleaseTimeout=1500', 'PasteSettle=250', 'HotkeyFallbacks=Alt+Q;Alt+W'), $Utf8)
    Apply-Config
    Check 'unit' 'Apply-Config ModReleaseTimeout' ($script:ModReleaseTimeout -eq 1500) ('value=' + $script:ModReleaseTimeout)
    Check 'unit' 'Apply-Config PasteSettle' ($script:PasteSettle -eq 250) ('value=' + $script:PasteSettle)
    Check 'unit' 'Apply-Config HotkeyFallbacks' ($script:HotkeyFallbacks -eq 'Alt+Q;Alt+W') ('value=' + $script:HotkeyFallbacks)

    # store (records only - there is no payload-only view any more)
    Save-Records @()
    Check 'unit' 'store empty at start' (@(Get-Records).Count -eq 0) ''

    Add-Item 'one'; Add-Item 'two'; Add-Item 'three'
    $items = Payloads
    Check 'unit' 'store newest first' ($items.Count -eq 3 -and $items[0] -eq 'three') ($items -join '|')

    Add-Item 'one'
    $items = Payloads
    Check 'unit' 'store dedupe moves to top' ($items.Count -eq 3 -and $items[0] -eq 'one') ($items -join '|')

    Add-Item 'one'
    $items = Payloads
    Check 'unit' 'store dedupe keeps count' ($items.Count -eq 3) ($items -join '|')

    $savedMax = $MaxItems
    $MaxItems = 2
    Add-Item 'four'
    $items = Payloads
    Check 'unit' 'store trims to MaxItems' ($items.Count -eq 2) ($items -join '|')
    $MaxItems = $savedMax

    $savedBytes = $script:MaxTextBytes
    $script:MaxTextBytes = 3
    $before = @(Get-Records).Count
    Add-Item 'toolong'
    Check 'unit' 'store skips oversize entry' (@(Get-Records).Count -eq $before) ''
    $script:MaxTextBytes = $savedBytes

    $before = @(Get-Records).Count
    $script:ExcludePattern = '^SECRET'
    Add-Item 'SECRET token'
    Check 'unit' 'store honours exclude pattern' (@(Get-Records).Count -eq $before) ''
    $script:ExcludePattern = ''

    $before = @(Get-Records).Count
    Add-Item '   '
    Check 'unit' 'store ignores blank input' (@(Get-Records).Count -eq $before) ''

    # Pasting a row is "this one again": it moves to the top instead of staying where it was,
    # and it keeps its marks, its rich sidecar and its blob reference - re-deriving the entry
    # from its text is what used to turn a formatted row into a plain one.
    $touchRichRef = 'H:' + ('a' * 40) + ':100'
    $touchRich = New-Record 'rich row' ((Get-Epoch) - 300) 'p'
    $touchRich.Rich = $touchRichRef
    $touchList = New-Object System.Collections.Generic.List[object]
    $touchList.Add((New-Record 'plain top' (Get-Epoch) ''))
    $touchList.Add((New-Record 'middle row' ((Get-Epoch) - 100) ''))
    $touchList.Add($touchRich)
    Save-Records $touchList.ToArray()
    $moved = Touch-Record 'rich row'
    $afterTouch = @(Get-Records)
    Check 'unit' 'a pasted row moves to the top' ($moved -and ([string]$afterTouch[0].Payload -ceq 'rich row')) ([string]$afterTouch[0].Payload)
    Check 'unit' 'a moved row keeps its marks and its rich sidecar' ((([string]$afterTouch[0].Marks) -ceq 'p') -and (([string]$afterTouch[0].Rich) -ceq $touchRichRef)) ([string]$afterTouch[0].Marks + ' / ' + [string]$afterTouch[0].Rich)
    Check 'unit' 'a row already on top is left alone' (-not (Touch-Record 'rich row')) ''

    # A capture appends one line instead of rewriting the file; the read side reverses it and
    # hides the duplicate, so a payload captured twice is one row carrying the newer time and
    # the marks it already had.
    Save-Records @()
    Add-Item 'first'; Add-Item 'second'
    $linesAfterTwo = [int]$script:RecLines
    $rawTwo = [IO.File]::ReadAllText($StoreFile)
    Add-Item 'first'
    $linesAfterRepeat = [int]$script:RecLines
    $rawRepeat = [IO.File]::ReadAllText($StoreFile)
    Check 'unit' 'a capture appends a line instead of rewriting' (($linesAfterTwo -eq 2) -and ($linesAfterRepeat -eq 3) -and ($rawRepeat.Length -gt $rawTwo.Length)) ([string]$linesAfterTwo + ' -> ' + [string]$linesAfterRepeat)
    $repeated = @(Get-Records)
    Check 'unit' 'the repeated capture is one row on top' (($repeated.Count -eq 2) -and ([string]$repeated[0].Payload -ceq 'first')) ([string]$repeated.Count + ' / ' + [string]$repeated[0].Payload)

    # The file may carry rows the history already hides; twice MaxItems is where it is folded
    # back into a clean list, so a long session cannot grow the file without bound.
    $savedAppendMax = $script:MaxItems
    $script:MaxItems = 3
    for ($k = 0; $k -lt 6; $k++) { Add-Item ('grow ' + [string]$k) }
    $script:MaxItems = $savedAppendMax
    Check 'unit' 'the append log is folded back at twice MaxItems' ([int]$script:RecLines -le 6) ([string]$script:RecLines + ' lines')
    $grown = @(Get-Records)
    Check 'unit' 'the folded list keeps the newest rows' (($grown.Count -le 6) -and ($grown.Count -gt 0)) ([string]$grown.Count)

    # ------------------------------------------------------------- record store
    $rawHead = [IO.File]::ReadAllText($StoreFile)
    Check 'unit' 'the store starts with the tag and its layout version' ($rawHead.StartsWith($TAG + $RS + [string]$script:DataVersion)) ($rawHead.Substring(0, [Math]::Min(9, $rawHead.Length)) -replace [string][char]30, '<RS>')

    # ------------------------------------------- generic marks (base owns no mark meaning)
    $markPlugin = @{
      Name       = 'marks'
      Marks      = [ordered]@{
        p = @{ Set = 'pin'; Unset = 'unpin'; Word = 'pinned'; Hint = 'Ctrl+P'; Protected = $false }
        s = @{ Set = 'star'; Unset = 'unstar'; Word = 'starred'; Hint = 'Ctrl+S'; Protected = $true }
      }
      SortMark   = 'p'
      ClearKeeps = @('p')
    }
    $script:Plugins = @($markPlugin)
    Check 'unit' 'mark names come from the declaration' ((@(Get-MarkNames) -join ',') -eq 'p,s') (@(Get-MarkNames) -join ',')
    Check 'unit' 'mark word lookup' ((Get-MarkWord 's') -eq 'starred') (Get-MarkWord 's')
    Check 'unit' 'undeclared mark falls back to its character' ((Get-MarkWord 'z') -eq 'z') (Get-MarkWord 'z')
    Check 'unit' 'protected marks come from the declaration' ((@(Get-ProtectedMarks) -join ',') -eq 's') (@(Get-ProtectedMarks) -join ',')

    # A mark change is an append too: the row comes back with the same payload and time and its
    # new marks, so pinning costs one line instead of a rewrite of the whole history.
    Save-Records @()
    Add-Item 'm-one'; Add-Item 'm-two'; Add-Item 'm-three'
    $beforePin = (@(Get-Records) | ForEach-Object { [string]$_.Payload }) -join ','
    $linesBeforePin = [int]$script:RecLines
    [void](Set-Mark 'm-two' 'p' $true)
    $linesAfterPin = [int]$script:RecLines
    $afterPin = @(Get-Records)
    $afterPinText = ($afterPin | ForEach-Object { [string]$_.Payload }) -join ','
    Check 'unit' 'a mark change appends a line' ($linesAfterPin -eq ($linesBeforePin + 1)) ([string]$linesBeforePin + ' -> ' + [string]$linesAfterPin)
    # the row keeps its payload, its time and its marks, but not its slot: the sort mark floats
    # it to the top of the list, which is the run the panel freezes. A write that left it where
    # it was made the pin invisible until the next full parse.
    Check 'unit' 'a pinned row floats to the top' ($afterPinText -ceq 'm-two,m-three,m-one') ($afterPinText + ' vs m-two,m-three,m-one')
    $markedRow = @($afterPin | Where-Object { [string]$_.Payload -ceq 'm-two' })
    Check 'unit' 'the appended version carries the mark' (($markedRow.Count -eq 1) -and (Test-Mark $markedRow[0] 'p')) ''
    # the older line holds a copy of the row, so the two must not become two rows
    Check 'unit' 'the older version of a row is not a second row' ($afterPin.Count -eq 3) ([string]$afterPin.Count)

    # A delete is a tombstone: one line naming the payload, and the read side drops every line
    # for it, so the row goes without the file being rewritten.
    $linesBeforeDel = [int]$script:RecLines
    $delResult = Remove-Record 'm-two'
    $rowsAfterDel = @(Get-Records)
    $delText = ($rowsAfterDel | ForEach-Object { [string]$_.Payload }) -join ','
    Check 'unit' 'a delete appends a tombstone' (($delResult -eq 'removed') -and ([int]$script:RecLines -eq ($linesBeforeDel + 1)) -and ([int]$script:RecGone -ge 1)) ([string]$delResult + ' lines=' + [string]$script:RecLines + ' gone=' + [string]$script:RecGone)
    Check 'unit' 'the tombstoned row is gone' (-not ($delText.Contains('m-two'))) $delText

    # a payload captured twice and then deleted must not come back through its older line
    Add-Item 'dup'; Add-Item 'dup'
    [void](Remove-Record 'dup')
    $dupRows = @(Get-Records | Where-Object { [string]$_.Payload -ceq 'dup' })
    Check 'unit' 'a tombstone also hides the older copies' ($dupRows.Count -eq 0) ([string]$dupRows.Count)

    # folding drops the tombstones and the stale lines in one rewrite
    $savedFoldMax = $script:MaxItems
    $script:MaxItems = 4
    for ($k = 0; $k -lt 10; $k++) { Add-Item ('fold ' + [string]$k) }
    $script:MaxItems = $savedFoldMax
    $rawFolded = [IO.File]::ReadAllText($StoreFile)
    Check 'unit' 'folding leaves no tombstones behind' ((-not ($rawFolded.Contains($RS + 'x'))) -and ([int]$script:RecGone -eq 0)) ([string]$script:RecGone + ' gone, ' + [string]$script:RecLines + ' lines')
    Check 'unit' 'sort mark comes from the declaration' ((Get-SortMark) -eq 'p') (Get-SortMark)
    Check 'unit' 'clear keeps the declared marks' ((@(Get-ClearKeepMarks) -join ',') -eq 'p,s') (@(Get-ClearKeepMarks) -join ',')
    Check 'unit' 'clear -All keeps only protected marks' ((@(Get-ClearKeepMarks -All) -join ',') -eq 's') (@(Get-ClearKeepMarks -All) -join ',')

    $now = Get-Epoch
    $recList = New-Object System.Collections.Generic.List[object]
    $recList.Add((New-Record 'alpha' ($now - 60) 'p'))
    $recList.Add((New-Record 'beta' ($now - 30) ''))
    Save-Records $recList.ToArray()
    $r2 = @(Get-Records)
    Check 'unit' 'records roundtrip payloads' (((Payloads) -join '|') -eq 'alpha|beta') ((Payloads) -join '|')
    Check 'unit' 'record roundtrip time' (($r2[0].Time -eq ($now - 60)) -and ($r2[1].Time -eq ($now - 30))) ($r2[0].Time -as [string])
    Check 'unit' 'record roundtrip marks' ((Test-Mark $r2[0] 'p') -and (-not (Test-Mark $r2[1] 'p'))) ''
    Check 'unit' 'record keeps a mark the base never heard of' ((Test-Mark (New-Record 'x' 0 'zq') 'z') -and (Test-Mark (New-Record 'x' 0 'zq') 'q')) ''

    # a payload above BlobChars lives in its own file: the history keeps a reference, so the
    # rewrite a capture costs stays small, and the record still comes back whole
    $bigText = ('big line ' + [Environment]::NewLine) * 5000
    $blobList = New-Object System.Collections.Generic.List[object]
    $blobList.Add((New-Record $bigText $now 'p'))
    $blobList.Add((New-Record 'small tail' $now ''))
    Save-Records $blobList.ToArray()
    $rawStore = [IO.File]::ReadAllText($StoreFile, $Utf8)
    $blobFiles = @(Get-ChildItem -LiteralPath (Get-BlobDir) -Filter '*.txt' -ErrorAction SilentlyContinue)
    Check 'unit' 'a big payload leaves the history file' ((-not $rawStore.Contains('big line')) -and $blobFiles.Count -eq 1) ([string]$blobFiles.Count + ' blob(s), store ' + $rawStore.Length + ' chars')
    $back = @(Get-Records)
    Check 'unit' 'a big payload comes back whole' (($back.Count -eq 2) -and ($back[0].Payload -ceq $bigText) -and [string]$back[0].Blob) ([string]$back[0].Payload.Length)
    Save-Records @($back[1])
    $leftBlobs = @(Get-ChildItem -LiteralPath (Get-BlobDir) -Filter '*.txt' -ErrorAction SilentlyContinue)
    Check 'unit' 'a dropped record takes its blob with it' ($leftBlobs.Count -eq 0) ([string]$leftBlobs.Count + ' left')
    # BlobChars is a setting: a lower value pushes more payloads into data\blobs
    $savedBlob = $script:BlobChars
    $script:BlobChars = 100
    $inlineList = New-Object System.Collections.Generic.List[object]
    $inlineList.Add((New-Record ('z' * 400) $now ''))
    Save-Records $inlineList.ToArray()
    $inlineRaw = [IO.File]::ReadAllText($StoreFile, $Utf8)
    $inlineBlobs = @(Get-ChildItem -LiteralPath (Get-BlobDir) -Filter '*.txt' -ErrorAction SilentlyContinue)
    Check 'unit' 'BlobChars decides what leaves the file' ((-not $inlineRaw.Contains('zzzz')) -and $inlineBlobs.Count -eq 1) ([string]$inlineBlobs.Count + ' blob(s)')
    $script:BlobChars = $savedBlob
    # the four new settings are real schema entries with the shipped defaults
    $sch = $script:IniSchema
    Check 'unit' 'preview and blob settings carry defaults' (($sch['PreviewHover'].Default -eq 1) -and ($sch['PreviewDelay'].Default -eq 350) -and ($sch['PreviewChars'].Default -eq 6000) -and ($sch['BlobChars'].Default -eq 32768)) ''
    Check 'unit' 'media settings carry defaults' (($sch['CaptureImages'].Default -eq 1) -and ($sch['MaxImageBytes'].Default -eq 16777216) -and ($sch['CaptureRich'].Default -eq 1) -and ($sch['MaxHtmlBytes'].Default -eq 20971520) -and ($sch['MaxRtfBytes'].Default -eq 20971520) -and ($sch['RtfImagesUpToBytes'].Default -eq 8388608) -and ($sch['InlineImageUpToBytes'].Default -eq 4194304) -and ($sch['PasteRich'].Default -eq 1) -and ($sch['MaxMediaTotalBytes'].Default -eq 134217728)) ''

    # ------------------------------------------------------- export and import
    # the shapes first: a document this build writes has to be one it reads
    $xRows = @(
      @{ Text = 'one'; Time = 100; Marks = ''; Media = $null },
      @{ Text = ('two' + [Environment]::NewLine + 'lines'); Time = 200; Marks = 'p'; Media = $null }
    )
    $backDoc = ConvertFrom-TransferJson (ConvertTo-TransferJson $xRows)
    Check 'unit' 'a json export reads back' (($null -ne $backDoc) -and (@($backDoc.Rows).Count -eq 2) -and (@($backDoc.Rows)[1].Marks -eq 'p')) ''
    Check 'unit' 'a json export keeps a line break in the payload' ((@($backDoc.Rows)[1].Text) -like ('two' + [Environment]::NewLine + 'lines')) (@($backDoc.Rows)[1].Text)
    Check 'unit' 'a foreign json is refused' ($null -eq (ConvertFrom-TransferJson '{"format":"something-else"}')) ''
    $csvBack = ConvertFrom-TransferCsv (ConvertTo-TransferCsv $xRows)
    Check 'unit' 'a csv export reads back' (($null -ne $csvBack) -and (@($csvBack.Rows).Count -eq 2) -and ((@($csvBack.Rows)[1].Text) -like 'two*')) ''
    Check 'unit' 'csv with another header is refused' ($null -eq (ConvertFrom-TransferCsv "a,b`r`n1,2")) ''
    # then the round trip through the store: export, empty, import, and the marks come back
    Save-Records @((New-Record 'export me' $now ''), (New-Record 'and me' ($now - 10) 's'))
    $xfile = Join-Path $unitDir 'history-export.json'
    $ex = Invoke-Export $xfile
    Check 'unit' 'export writes the history' (($ex.Ok) -and (Test-Path -LiteralPath $xfile)) $ex.Message
    Save-Records @()
    $im = Invoke-Import $xfile
    Check 'unit' 'import brings the entries back' (($im.Ok) -and (@(Get-Records).Count -eq 2)) $im.Message
    Check 'unit' 'an imported mark survives' (@(Get-Records | Where-Object { Test-Mark $_ 's' }).Count -eq 1) ''
    $im2 = Invoke-Import $xfile
    Check 'unit' 'a second import keeps what is already there' ((@(Get-Records).Count -eq 2) -and ($im2.Kept -eq 2)) $im2.Message
    Check 'unit' 'an unreadable file is refused' (-not (Invoke-Import (Join-Path $unitDir 'nope.json')).Ok) ''
    # a snapshot is a zip of the data folder, so pictures travel with the history
    $bk = Save-Snapshot 'unit'
    Check 'unit' 'a snapshot is a zip in data\backup' (($bk.Ok) -and ($bk.Path -like '*.zip')) $bk.Path
    $bkName = [IO.Path]::GetFileNameWithoutExtension($bk.Path)
    Save-Records @()
    # not $rs: that is case-insensitively the same variable as the store's record separator
    $restored = Invoke-Restore $bkName
    Check 'unit' 'a snapshot restores the history' (($restored.Ok) -and (@(Get-Records).Count -eq 2)) $restored.Message
    Save-Records @()

    # ------------------------------------------------------- per program paste rules
    # the text form first: separated by ';' or ',', names lowercased, '.exe' filled in
    $ruleMap = ConvertFrom-AppRuleText 'WindowsTerminal:plain, Code.EXE:rich; *:no-paste'
    Check 'unit' 'a rule list parses into program keys' (($ruleMap.Contains('windowsterminal.exe')) -and ($ruleMap.Contains('code.exe')) -and ($ruleMap.Contains('*'))) ([string]$ruleMap.Count + ' rule(s)')
    Check 'unit' 'a rule keeps its action' (($ruleMap['windowsterminal.exe'] -eq 'plain') -and ($ruleMap['*'] -eq 'no-paste')) $ruleMap['windowsterminal.exe']
    Check 'unit' 'an empty rule list is empty' ((ConvertFrom-AppRuleText '').Count -eq 0) ''
    $okRule = Test-AppRuleText 'notepad:plain;*:no-paste'
    Check 'unit' 'a good rule list is accepted' (($okRule.Ok) -and ($okRule.Value -eq 'notepad.exe:plain;*:no-paste')) $okRule.Value
    Check 'unit' 'an unknown action is refused' (-not (Test-AppRuleText 'notepad:cursive').Ok) (Test-AppRuleText 'notepad:cursive').Error
    Check 'unit' 'a rule without an action is refused' (-not (Test-AppRuleText 'notepad').Ok) ''
    Check 'unit' 'a name that is not a program is refused' (-not (Test-AppRuleText '..\evil:plain').Ok) ''
    # then the lookup: an exact name beats the '*' fallback, and no rule means ''
    $savedRules = $script:AppRules
    $script:AppRules = 'windowsterminal.exe:plain;*:no-paste'
    Check 'unit' 'an exact rule wins over the fallback' ((Get-AppRuleAction 'windowsterminal') -eq 'plain') (Get-AppRuleAction 'windowsterminal')
    Check 'unit' 'anything else takes the fallback' ((Get-AppRuleAction 'notepad') -eq 'no-paste') (Get-AppRuleAction 'notepad')
    $script:AppRules = 'windowsterminal.exe:plain'
    Check 'unit' 'a program without a rule is left alone' ((Get-AppRuleAction 'notepad') -eq '') ''
    $script:AppRules = ''
    Check 'unit' 'no rules means no answer' ((Get-AppRuleAction 'notepad') -eq '') ''
    $script:AppRules = $savedRules
    Check 'unit' 'the rule setting carries a default' ($null -ne $sch['AppRules'] -and $sch['AppRules'].Default -eq '') ''

    # ------------------------------------------------------- editing an entry
    Save-Records @((New-Record 'typo herr' $now 'p'), (New-Record 'other text' ($now - 5) ''))
    $beforeEdit = @(Get-Records)
    $editKey = [int]$beforeEdit[0].Key
    $editRes = Update-RecordText 'typo herr' 'typo here'
    $afterEdit = @(Get-Records)
    Check 'unit' 'an edit replaces the text' (($editRes.Ok) -and ($afterEdit[0].Payload -eq 'typo here')) ([string]$editRes.Error)
    Check 'unit' 'an edit keeps the time, the marks and the row count' (($afterEdit.Count -eq 2) -and ($afterEdit[0].Time -eq $now) -and ($afterEdit[0].Marks -eq 'p')) ''
    Check 'unit' 'an edit bumps the key so the caches redraw' ($afterEdit[0].Key -ne $editKey) ([string]$afterEdit[0].Key)
    Check 'unit' 'an edit that changes nothing is accepted' ((Update-RecordText 'typo here' 'typo here').Ok) ''
    Check 'unit' 'an edit onto another entry is refused' (-not (Update-RecordText 'typo here' 'other text').Ok) ''
    Check 'unit' 'an edit to nothing is refused' (-not (Update-RecordText 'typo here' '   ').Ok) ''
    Check 'unit' 'an edit of a missing entry is refused' (-not (Update-RecordText 'not here' 'x').Ok) ''
    Save-Records @()

    # ------------------------------------------------------- images and rich text
    # 1x1 transparent PNG: the bytes are what makes the identity, so any picture works
    $png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')
    $p1 = New-ImagePayload $png 1 1 'PNG'
    $p2 = New-ImagePayload $png 1 1 'PNG'
    Check 'unit' 'an image payload is derived from its bytes' ($p1.Length -gt 0 -and $p1[0] -eq [char]3 -and $p1 -ceq $p2) $p1
    $iref = Get-ImageRef $p1
    Check 'unit' 'an image payload parses back' (($null -ne $iref) -and $iref.W -eq 1 -and $iref.H -eq 1 -and $iref.Bytes -eq $png.Length -and $iref.Sha1.Length -eq 40) ''
    Check 'unit' 'a text payload is not an image' (-not (Test-ImagePayload 'hello')) ''
    Check 'unit' 'an image row says what it is' ((Get-ItemLabel $p1 $true) -like '[[]image] 1x1*PNG*') (Get-ItemLabel $p1 $true)
    Check 'unit' 'an image entry has its own kind' ((Get-EntryKind $p1) -eq 'image') (Get-EntryKind $p1)
    Check 'unit' 'byte sizes read like sizes' (((Format-Size 512) -eq '512 B') -and ((Format-Size 2048) -eq '2 KB') -and ((Format-Size 2411724) -eq '2.3 MB')) (Format-Size 2411724)

    [void](Write-ImageMedia $p1 $png)
    Check 'unit' 'an image lands in the media folder' (Test-Path -LiteralPath (Get-MediaPath $iref.Sha1 'png')) ''
    [void](Write-ImageMedia $p1 $png)
    Check 'unit' 'the same picture is stored once' (@(Get-ChildItem -LiteralPath (Get-MediaDir) -Filter '*.png').Count -eq 1) ([string]@(Get-ChildItem -LiteralPath (Get-MediaDir) -Filter '*.png').Count)
    $imgRec = New-Record $p1 $now ''
    Check 'unit' 'a record knows its media weight' ((Get-RecordMediaBytes $imgRec) -eq $png.Length) ([string](Get-RecordMediaBytes $imgRec))
    # the row thumbnail is a small copy of the picture, drawn into the icon slot
    $thumb = Get-RowThumbBitmap $imgRec 28
    Check 'unit' 'a picture row gets a thumbnail' (($null -ne $thumb) -and ($thumb.Width -le 28) -and ($thumb.Height -le 28)) ''
    Check 'unit' 'the same row reuses its thumbnail' ([object]::ReferenceEquals($thumb, (Get-RowThumbBitmap $imgRec 28))) ''
    Check 'unit' 'a text row has no thumbnail' ($null -eq (Get-RowThumbBitmap (New-Record 'plain text' 1 '') 28)) ''
    $canvas = New-Object Drawing.Bitmap 28, 28
    $gfx = [Drawing.Graphics]::FromImage($canvas)
    Check 'unit' 'Draw-RowThumb refuses a missing picture' ((Draw-RowThumb $gfx $null 0 0 28) -eq $false) ''
    $drew = Draw-RowThumb $gfx $thumb 0 0 28
    $gfx.Dispose()
    $canvas.Dispose()
    Check 'unit' 'Draw-RowThumb paints into the slot' $drew ''

    $richRtf = '{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Segoe UI;}}\f0\fs24\b bold title\b0\par second line\par third line\par}'
    $richCap = @{ Html = $Utf8.GetBytes('<html><body><p>hi</p></body></html>'); Rtf = $richRtf }
    $rref = New-RichRef $richCap
    Check 'unit' 'a rich reference is stable' (($rref -ceq (New-RichRef $richCap)) -and $rref.StartsWith('H:')) $rref
    $rr = Get-RichRef $rref
    Check 'unit' 'a rich reference parses back' (($null -ne $rr) -and $rr.Bytes -gt 0) $rref
    [void](Write-RichMedia $rref $richCap)
    Check 'unit' 'formatted text comes back as stored' (((Read-RichRtf $rref) -eq $richRtf) -and ((Read-RichHtml $rref).Length -eq $richCap.Html.Length)) ''
    # RTF is an 8-bit format: it is stored as bytes, so high bytes (and any style table byte)
    # survive instead of going through a UTF-8 decode
    $rtfHigh = New-Object byte[] 5
    $rtfHigh[0] = 0x7B; $rtfHigh[1] = 0x80; $rtfHigh[2] = 0xFF; $rtfHigh[3] = 0x5C; $rtfHigh[4] = 0x7D
    $highRef = New-RichRef @{ Html = $null; Rtf = $rtfHigh }
    [void](Write-RichMedia $highRef @{ Html = $null; Rtf = $rtfHigh })
    $highBack = Read-RichRtfBytes $highRef
    Check 'unit' 'rtf keeps its high bytes' (($highBack.Length -eq 5) -and ($highBack[1] -eq 0x80) -and ($highBack[2] -eq 0xFF)) ([string]$highBack.Length + ' bytes')
    # the card draws the document into a bitmap: an empty one would mean the layout never ran
    $renderFont = New-Object Drawing.Font 'Segoe UI', 10.5
    $richBmp = Get-RichPreviewBitmap $rref 380 200 $renderFont ([Drawing.Color]::White)
    $richInk = 0
    if ($null -ne $richBmp) { $richInk = Get-InkBottom $richBmp ([Drawing.Color]::White) }
    Check 'unit' 'formatted text paints into the card' (($null -ne $richBmp) -and ($richBmp.Width -eq 380) -and ($richInk -gt 20) -and ($richInk -le 200)) ([string]$richInk + ' px of ink')
    $richAgain = Get-RichPreviewBitmap $rref 380 200 $renderFont ([Drawing.Color]::White)
    Check 'unit' 'a painted page is reused' ([object]::ReferenceEquals($richBmp, $richAgain)) ''
    Clear-MediaCache
    $richRec = New-Record 'hi there' $now ''
    $richRec.Rich = $rref
    Check 'unit' 'a formatted row says so' ((Get-RecordLabel $richRec $true) -eq '[rich] hi there') (Get-RecordLabel $richRec $true)

    # the card knows all three kinds, and a missing media file degrades to a message
    $pcImg = Get-PreviewContent $imgRec 40 6
    Check 'unit' 'the card knows an image' ($pcImg.Kind -eq 'image' -and $pcImg.Ref -and ($pcImg.Head -like 'image - 1x1*')) ([string]$pcImg.Kind + ' / ' + [string]$pcImg.Head)
    $pcRich = Get-PreviewContent $richRec 40 6
    Check 'unit' 'the card knows formatted text' ($pcRich.Kind -eq 'rich' -and ($pcRich.Head -like 'formatted -*') -and $pcRich.Lines.Count -gt 0) ([string]$pcRich.Head)
    $pcText = Get-PreviewContent (New-Record 'plain body' $now '') 40 6
    Check 'unit' 'the card still knows plain text' ($pcText.Kind -eq 'text' -and $pcText.Lines.Count -eq 1) ([string]$pcText.Kind)

    # CF_HTML keeps byte offsets into its own buffer: the fragment has to come out exactly
    $fragText = '<p>inside</p>'
    $fragBytes = [Text.Encoding]::UTF8.GetBytes($fragText)
    $stub = 'Version:0.9' + "`r`n" + 'StartHTML:0000000000' + "`r`n" + 'EndHTML:0000000000' + "`r`n" + 'StartFragment:0000000000' + "`r`n" + 'EndFragment:0000000000' + "`r`n"
    $fragAt = $Utf8.GetByteCount($stub)
    $fragEnd = $fragAt + $fragBytes.Length
    $cfHtml = 'Version:0.9' + "`r`n" + ('StartHTML:' + ([string]$fragAt).PadLeft(10, [char]48)) + "`r`n" + ('EndHTML:' + ([string]$fragEnd).PadLeft(10, [char]48)) + "`r`n" + ('StartFragment:' + ([string]$fragAt).PadLeft(10, [char]48)) + "`r`n" + ('EndFragment:' + ([string]$fragEnd).PadLeft(10, [char]48)) + "`r`n" + $fragText
    Check 'unit' 'cf_html offsets select the fragment' ((Get-HtmlText ($Utf8.GetBytes($cfHtml))) -eq 'inside') (Get-HtmlText ($Utf8.GetBytes($cfHtml)))
    Check 'unit' 'html is read as words when there is no rtf' ((Get-HtmlText ($Utf8.GetBytes('<p>a &amp; b</p><p>c</p>'))) -eq ("a & b`nc")) (Get-HtmlText ($Utf8.GetBytes('<p>a &amp; b</p><p>c</p>')))

    # a formatted entry owns one file per block, each named by the hash of its own bytes
    function New-DibFixture([int]$w, [int]$h) {
      # [int] rounds in PowerShell, so the stride is floored explicitly
      $stride = [int][Math]::Floor((($w * 32) + 31) / 32) * 4
      $size = $stride * $h
      $dib = New-Object byte[] (40 + $size)
      [Array]::Copy([BitConverter]::GetBytes([int]40), 0, $dib, 0, 4)
      [Array]::Copy([BitConverter]::GetBytes([int]$w), 0, $dib, 4, 4)
      [Array]::Copy([BitConverter]::GetBytes([int]$h), 0, $dib, 8, 4)
      [Array]::Copy([BitConverter]::GetBytes([int16]1), 0, $dib, 12, 2)
      [Array]::Copy([BitConverter]::GetBytes([int16]32), 0, $dib, 14, 2)
      [Array]::Copy([BitConverter]::GetBytes([int]$size), 0, $dib, 20, 4)
      for ($i = 40; $i -lt $dib.Length; $i += 4) {
        $dib[$i] = 0x40; $dib[$i + 1] = 0x80; $dib[$i + 2] = 0xC0; $dib[$i + 3] = 0xFF
      }
      return , $dib
    }

    function New-CfHtmlFixture([string]$frag) {
      $pre = '<html><body><!--StartFragment-->'
      $post = '<!--EndFragment--></body></html>'
      $stub = 'Version:0.9' + "`r`n" + 'StartHTML:0000000000' + "`r`n" + 'EndHTML:0000000000' + "`r`n" + 'StartFragment:0000000000' + "`r`n" + 'EndFragment:0000000000' + "`r`n"
      $startHtml = $Utf8.GetByteCount($stub)
      $startFrag = $startHtml + $Utf8.GetByteCount($pre)
      $endFrag = $startFrag + $Utf8.GetByteCount($frag)
      $endHtml = $startHtml + $Utf8.GetByteCount($pre + $frag + $post)
      return ('Version:0.9' + "`r`n" +
        ('StartHTML:' + $startHtml.ToString('0000000000')) + "`r`n" +
        ('EndHTML:' + $endHtml.ToString('0000000000')) + "`r`n" +
        ('StartFragment:' + $startFrag.ToString('0000000000')) + "`r`n" +
        ('EndFragment:' + $endFrag.ToString('0000000000')) + "`r`n" + $pre + $frag + $post)
    }

    $dibPixels = New-DibFixture 2 2
    $blockCap = @{ Html = $richCap.Html; Rtf = $richCap.Rtf; Blocks = @(@{ Tag = 'D'; Data = $dibPixels }) }
    $bRef = New-RichRef $blockCap
    [void](Write-RichMedia $bRef $blockCap)
    $bParsed = Get-RichRef $bRef
    Check 'unit' 'a reference names every block' (($null -ne $bParsed) -and ($bParsed.Blocks.Count -eq 3) -and ($bParsed.Blocks[2].Tag -eq 'D')) ([string]$bRef)
    Check 'unit' 'the block bytes come back' ((Read-RichBlock $bRef 'D').Length -eq $dibPixels.Length) ''
    Check 'unit' 'a v1 reference is not a reference' ($null -eq (Get-RichRef 'R:0123456789012345678901234567890123456789:120')) ''
    Check 'unit' 'unknown block tags are rejected' ($null -eq (Get-RichRef 'X:0123456789012345678901234567890123456789:1')) ''
    Check 'unit' 'a reference counts every block' ($bParsed.Bytes -eq ($richCap.Html.Length + $Utf8.GetByteCount($richRtf) + $dibPixels.Length)) ([string]$bParsed.Bytes)
    $dibBitmap = ConvertFrom-MediaBytes $dibPixels 'D'
    Check 'unit' 'a bitmap block decodes' (($null -ne $dibBitmap) -and ($dibBitmap.Width -eq 2) -and ($dibBitmap.Height -eq 2)) ''
    if ($null -ne $dibBitmap) { $dibBitmap.Dispose() }
    $picBmp = Get-RichImageBitmap $bRef 120 120
    Check 'unit' 'the card falls back to the first picture' (($null -ne $picBmp) -and ($picBmp.Width -le 120)) ''
    Clear-MediaCache

    # html that points at a temp picture: the file is read once and inlined as a data uri, then
    # the four offsets are recomputed for the longer buffer
    $tmpPic = Join-Path $tmpRoot 'inline-fixture.png'
    [IO.File]::WriteAllBytes($tmpPic, $png)
    $picUrl = 'file:///' + ($tmpPic -replace '\\', '/')
    $inHtml = New-CfHtmlFixture ('<p>pic</p><img src="' + $picUrl + '">')
    $inlined = Get-CfHtmlInlined ($Utf8.GetBytes($inHtml)) 2097152 0
    $inText = $Utf8.GetString($inlined)
    Check 'unit' 'a temp picture is inlined' (($inText -match 'src="data:image/png;base64,') -and ($inText.Length -gt $inHtml.Length)) ''
    Check 'unit' 'the inlined offsets still select the fragment' ((Get-HtmlText $inlined) -eq 'pic') (Get-HtmlText $inlined)
    $kept = Get-CfHtmlInlined ($Utf8.GetBytes($inHtml)) 1 0
    Check 'unit' 'a picture over the cap is left alone' (([BitConverter]::ToString($kept)) -eq ([BitConverter]::ToString($Utf8.GetBytes($inHtml)))) ''
    $noInline = Get-CfHtmlInlined ($Utf8.GetBytes($inHtml)) 0 0
    Check 'unit' 'inlining can be switched off' (([BitConverter]::ToString($noInline)) -eq ([BitConverter]::ToString($Utf8.GetBytes($inHtml)))) ''
    # Word writes an <img> fallback and a VML <v:imagedata src="file:...">. The inliner
    # rewrites every src that names a file, not just the <img> ones, so the VML path survives
    # the temp folder being deleted as well - a shape is what Word draws from.
    $vmlHtml = New-CfHtmlFixture ('<p>vml</p><v:shape><v:imagedata src="' + $picUrl + '"/></v:shape>')
    $vmlInlined = $Utf8.GetString((Get-CfHtmlInlined ($Utf8.GetBytes($vmlHtml)) 2097152 0))
    Check 'unit' 'a vml picture is inlined too' (($vmlInlined -notmatch 'file:') -and ($vmlInlined -match 'v:imagedata src="data:image/png;base64,')) ''
    Remove-Item -LiteralPath $tmpPic -Force

    # A block the clipboard wrapper hands over as a string (the fallback when the raw read
    # could not open the clipboard) still carries the allocator padding and, when the ANSI
    # decode ate a character, one byte less than EndHTML. The first is cut back, the second
    # is dropped: a fragment whose tags lost a '<' is worse than no formatting at all.
    $fbText = New-CfHtmlFixture '<p>fallback</p>'
    $fbBytes = $Utf8.GetBytes($fbText)
    $fbPadded = Get-CfHtmlFromString ($fbText + ('?' * 12))
    $fbSame = ($null -ne $fbPadded) -and ([BitConverter]::ToString([byte[]]$fbPadded) -eq [BitConverter]::ToString($fbBytes))
    Check 'unit' 'a string read is cut back to its end' $fbSame ([string]$fbPadded.Length)
    $fbShort = Get-CfHtmlFromString ($fbText.Substring(0, $fbText.Length - 1))
    Check 'unit' 'a string read that lost a byte is dropped' ($null -eq $fbShort) ''
    $fbMarked = Get-CfHtmlFromString ($fbText.Insert(20, ([string][char]0xFFFD)))
    Check 'unit' 'a string read with a replacement character is dropped' ($null -eq $fbMarked) ''
    Check 'unit' 'an empty string is not an html block' ($null -eq (Get-CfHtmlFromString '')) ''
    $fbNoHead = Get-CfHtmlFromString ('<p>no header</p>' + ([string][char]0) + ([string][char]0))
    Check 'unit' 'nul padding goes without a header' (($null -ne $fbNoHead) -and ([Text.Encoding]::ASCII.GetString([byte[]]$fbNoHead) -eq '<p>no header</p>')) ''

    # the bytes of a formatted block have to stay bytes end to end: an Object[] from the
    # pipeline used to be stringified into "123 92 114 ..." and written as that text
    $rtfPic = '{\rtf1\ansi{\fonttbl{\f0 Arial;}}\f0 hello {\pict\pngblip\picw2\pich2 89504e47}world}'
    $rtfBytes = $Utf8.GetBytes($rtfPic)
    $cutRich = @{ Html = $null; Rtf = $rtfBytes; Blocks = @() }
    $cutRef = New-RichRef $cutRich
    [void](Write-RichMedia $cutRef $cutRich)
    $cutSha = (@((Get-RichRef $cutRef).Blocks))[0].Sha1
    $cutBack = [IO.File]::ReadAllBytes((Get-MediaPath $cutSha 'rtf'))
    Check 'unit' 'an rtf block is written as bytes' (([BitConverter]::ToString($cutBack)) -eq ([BitConverter]::ToString($rtfBytes))) ''

    # store round trip: the extra field carries the reference, the bytes stay out of the file
    $blockRec = New-Record 'with a picture' $now ''
    $blockRec.Rich = $bRef
    $mixList = New-Object System.Collections.Generic.List[object]
    $mixList.Add($imgRec)
    $mixList.Add($richRec)
    $mixList.Add($blockRec)
    $mixList.Add((New-Record 'plain' $now ''))
    Save-Records $mixList.ToArray()
    $mixBack = @(Get-Records)
    Check 'unit' 'an image record survives a save' (($mixBack.Count -eq 4) -and ([string]$mixBack[0].Payload -ceq $p1)) ([string]$mixBack.Count)
    Check 'unit' 'a rich reference survives a save' ([string]$mixBack[1].Rich -ceq $rref) ([string]$mixBack[1].Rich)
    Check 'unit' 'a block reference survives a save' ([string]$mixBack[2].Rich -ceq $bRef) ([string]$mixBack[2].Rich)
    Check 'unit' 'the blocks of a saved record stay on disk' ((Test-Path -LiteralPath (Get-MediaPath (Get-RichPictureBlock $bRef).Sha1 'dib'))) ''
    Check 'unit' 'a plain record has no rich reference' (-not [string]$mixBack[3].Rich) ([string]$mixBack[3].Rich)
    Check 'unit' 'the image type letter is written' (([IO.File]::ReadAllText($StoreFile)).Contains($RS + 'i')) ''
    Check 'unit' 'pixels never enter the history file' (-not ([IO.File]::ReadAllText($StoreFile)).Contains('PNG' + [string][char]1)) ''

    # the clipboard itself: an image goes back as an image, formatted text keeps its formats
    # The clipboard is shared with every other program on the machine: an outside write can
    # land between ours and our read, which used to surface as an unrelated failure (it also
    # reproduced with none of the code under test changed). Retry the pair a few times; a real
    # regression still fails every attempt.
    function Get-ClipBack([string]$entry, [string]$rich = '', [int]$tries = 4) {
      # a picture entry has no text of its own: the clipboard carries the bitmap only, so
      # the read-back is judged by the image, not by the payload string
      $wantImage = (Test-ImagePayload $entry)
      for ($i = 0; $i -lt $tries; $i++) {
        if (-not (Set-ClipItem $entry $rich)) { continue }
        Start-Sleep -Milliseconds 60
        $cap = Get-ClipCapture
        if ($null -eq $cap) { continue }
        if ($wantImage) {
          if ($null -ne $cap.Image) { return $cap }
          continue
        }
        if ([string]$cap.Text -cne $entry) { continue }
        if ($rich -and $null -eq $cap.Rich) { continue }
        return $cap
      }
      return $null
    }
    function Get-RichBack([string]$text, [string]$ref, [int]$tries = 4) {
      for ($i = 0; $i -lt $tries; $i++) {
        if (-not (Set-RichItem $text $ref)) { return $null }
        Start-Sleep -Milliseconds 60
        $bh = $null
        $br = $null
        $bp = $null
        $bd = $null
        $be = $null
        [Cb.Win]::ReadRichFormats([ref]$bh, [ref]$br, [ref]$bp, [ref]$bd, [ref]$be)
        if (($null -ne $bh) -or ($null -ne $bd)) {
          return @{ Html = $bh; Rtf = $br; Png = $bp; Dib = $bd; Emf = $be }
        }
      }
      return $null
    }
    $capBack = Get-ClipBack $p1
    Check 'unit' 'an image goes back to the clipboard' (($null -ne $capBack) -and ($null -ne $capBack.Image)) ''
    $sameImage = ($null -ne $capBack) -and ($null -ne $capBack.Image) -and ((New-ImagePayload $capBack.Image.Png $capBack.Image.W $capBack.Image.H $capBack.Image.Fmt) -ceq $p1)
    Check 'unit' 'a captured image is the same picture' $sameImage ''
    $capRich = Get-ClipBack 'hi there' $rref
    Check 'unit' 'formatted text keeps its formats on the clipboard' (($null -ne $capRich) -and [string]$capRich.Text -eq 'hi there') ''
    $htmlSame = ($null -ne $capRich) -and ($null -ne $capRich.Rich.Html) -and ([BitConverter]::ToString($capRich.Rich.Html) -eq [BitConverter]::ToString($richCap.Html))
    Check 'unit' 'the html block comes back byte for byte' $htmlSame ''
    $rtfSame = ($null -ne $capRich) -and ($null -ne $capRich.Rich.Rtf) -and ([Text.Encoding]::Default.GetString($capRich.Rich.Rtf) -ceq $richRtf)
    Check 'unit' 'the rtf block comes back byte for byte' $rtfSame ''
    # the same block as raw bytes through the OLE data object: that is the path the capture
    # takes when another window holds the clipboard and the open above is refused
    $oleHtml = $null
    try { $oleHtml = [Cb.Win]::ReadFormatBytes('HTML Format') } catch { $oleHtml = $null }
    $oleSame = ($null -ne $oleHtml) -and ([BitConverter]::ToString([byte[]]$oleHtml) -eq [BitConverter]::ToString($richCap.Html))
    Check 'unit' 'the data object hands the same html bytes over' $oleSame ([string]$(if ($null -eq $oleHtml) { 'null' } else { $oleHtml.Length }))
    # the raw read has to say when it could not open the clipboard, so the capture can retry
    # it instead of falling back to the string path that loses bytes
    $opened = $false
    for ($i = 0; $i -lt 5; $i++) {
      $openedHtml = $null
      $openedRtf = $null
      [Cb.Win]::ReadRichFormats([ref]$openedHtml, [ref]$openedRtf)
      if ([Cb.Win]::ClipboardOpen) { $opened = $true; break }
      Start-Sleep -Milliseconds 40
    }
    Check 'unit' 'a raw clipboard read says whether it opened the clipboard' $opened ''
    # A UTF-8 CF_HTML block that goes through a .NET string is decoded with the ANSI code page
    # and stored re-encoded, which is what made Word and Excel paste mojibake. The bytes the
    # clipboard hands over have to come back unchanged.
    $cnChar = [char]0x4E2D
    $cnHtml = $Utf8.GetBytes('<html><body><p>' + $cnChar + '</p></body></html>')
    $cnRef = New-RichRef @{ Html = $cnHtml; Rtf = $null }
    [void](Write-RichMedia $cnRef @{ Html = $cnHtml; Rtf = $null })
    $cnBack = Get-ClipBack ([string]$cnChar) $cnRef
    $cnHtmlBack = $null
    if ($null -ne $cnBack -and $null -ne $cnBack.Rich) { $cnHtmlBack = $cnBack.Rich.Html }
    $cnSame = ($null -ne $cnHtmlBack) -and ([BitConverter]::ToString($cnHtmlBack) -eq [BitConverter]::ToString($cnHtml))
    Check 'unit' 'utf-8 html keeps its bytes on the clipboard' $cnSame ''
    Check 'unit' 'utf-8 html reads back as its text' (($null -ne $cnHtmlBack) -and ((Get-HtmlText $cnHtmlBack) -eq [string]$cnChar)) ([string]$cnChar)

    # the picture blocks travel with the text: a target that prefers a bitmap over html (a
    # chart, a shape, PowerPoint) still gets one
    $fmtBack = Get-RichBack 'hi there' $bRef
    $bd = $null
    $bh = $null
    if ($null -ne $fmtBack) { $bd = $fmtBack.Dib; $bh = $fmtBack.Html }
    Check 'unit' 'the bitmap block goes back' (($null -ne $bd) -and ([BitConverter]::ToString($bd) -eq [BitConverter]::ToString($dibPixels))) ([string]$(if ($null -ne $bd) { $bd.Length } else { -1 }) + ' vs ' + [string]$dibPixels.Length)
    Check 'unit' 'the html goes back with its blocks' (($null -ne $bh) -and ($bh.Length -eq $richCap.Html.Length)) ''

    # Word, Excel and PowerPoint resolve <img> through a file the buffer names, never through a
    # data: uri - an entry stored with its pictures inlined (so it survives the source folder
    # disappearing) has to hand them back as files, or the text arrives and each picture is an
    # empty frame. This is the paste path, so it runs on the bytes the store holds.
    function New-CfHtmlSample([string]$fragment) {
      $head = "Version:0.9`r`nStartHTML:0000000000`r`nEndHTML:0000000000`r`nStartFragment:0000000000`r`nEndFragment:0000000000`r`n"
      $len = $Utf8.GetByteCount($head)
      $head = $head.Replace('StartHTML:0000000000', ('StartHTML:' + $len.ToString('0000000000')))
      return (Set-CfHtmlOffsets ($Utf8.GetBytes($head + $fragment)))
    }
    $b64 = [Convert]::ToBase64String($png)
    $dataFrag = '<html><body><!--StartFragment--><p>a <img src="data:image/png;base64,' + $b64 + '"> b</p><!--EndFragment--></body></html>'
    $dataBytes = New-CfHtmlSample $dataFrag
    $onDisk = Get-CfHtmlOnDisk $dataBytes
    $onDiskText = $Utf8.GetString($onDisk)
    Check 'unit' 'a pasted picture becomes a file reference' ((-not ($onDiskText -match 'data:image')) -and ($onDiskText -match 'src="file:')) ([regex]::Match($onDiskText, 'src="(.{0,30})').Groups[1].Value)
    $imgUrl = [regex]::Match($onDiskText, 'src="(file:[^"]+)"')
    $imgPath = ''
    if ($imgUrl.Success) { try { $imgPath = ([uri]$imgUrl.Groups[1].Value).LocalPath } catch { $imgPath = '' } }
    $sameFile = $false
    if ($imgPath -and (Test-Path -LiteralPath $imgPath)) {
      $sameFile = ([BitConverter]::ToString([IO.File]::ReadAllBytes($imgPath)) -eq [BitConverter]::ToString($png))
    }
    Check 'unit' 'the picture file carries the same bytes' $sameFile $imgPath
    $pasteHead = [int](Get-CfHtmlHeadLength $onDiskText)
    Check 'unit' 'the pasted html keeps valid offsets' (($pasteHead -gt 0) -and ($onDiskText.Substring($pasteHead, 5) -eq '<html')) ([string]$pasteHead)
    $plainBytes = New-CfHtmlSample '<html><body><!--StartFragment--><p>plain</p><!--EndFragment--></body></html>'
    $plainBack = Get-CfHtmlOnDisk $plainBytes
    Check 'unit' 'html without pictures is left alone' (([BitConverter]::ToString($plainBack)) -eq ([BitConverter]::ToString($plainBytes))) ''

    # a picture the entry could not keep: the html still names the temp file, and that file is
    # gone by paste time. Every such tag becomes a dashed frame of the same footprint, so a
    # reader sees that a picture belonged there instead of an empty frame.
    $goneUrl = 'file:///' + ((Join-Path $tmpRoot 'gone-picture.png') -replace '\\', '/')
    $goneFrag = '<html><body><!--StartFragment--><p>before <img src="' + $goneUrl + '" width="240" height="180"> after</p><!--EndFragment--></body></html>'
    $goneText = $Utf8.GetString((Get-CfHtmlOnDisk (New-CfHtmlSample $goneFrag)))
    Check 'unit' 'a picture that is gone becomes a placeholder' ((-not ($goneText -match '<img')) -and ($goneText -match 'image not saved') -and ($goneText -match 'width:240px')) ([regex]::Match($goneText, 'width:\d+px').Value)
    $goneAt = [int](Get-CfHtmlHeadLength $goneText)
    Check 'unit' 'the placeholder keeps the fragment offsets' (($goneAt -gt 0) -and ($goneText.Substring($goneAt, 5) -eq '<html')) ([string]$goneAt)

    # a picture whose file is still there is copied next to the paste, so the target keeps a
    # readable file even after the source application deletes its temp folder
    $livePath = Join-Path $tmpRoot 'live-picture.png'
    [IO.File]::WriteAllBytes($livePath, $png)
    $liveFrag = '<html><body><!--StartFragment--><p><img src="file:///' + ($livePath -replace '\\', '/') + '"></p><!--EndFragment--></body></html>'
    $liveText = $Utf8.GetString((Get-CfHtmlOnDisk (New-CfHtmlSample $liveFrag)))
    $live = [regex]::Match($liveText, 'src="(file:[^"]+)"')
    $liveCopy = ''
    $liveOk = $false
    if ($live.Success) {
      try { $liveCopy = ([uri]$live.Groups[1].Value).LocalPath } catch { $liveCopy = '' }
      if ($liveCopy -and (Test-Path -LiteralPath $liveCopy)) {
        $liveOk = ([BitConverter]::ToString([IO.File]::ReadAllBytes($liveCopy)) -eq [BitConverter]::ToString($png))
      }
    }
    Check 'unit' 'a picture whose file survives is copied out' ($liveOk -and (-not ($liveText -match 'image not saved'))) $liveCopy
    Remove-Item -LiteralPath $livePath -Force

    # a remote picture is fetched by the target itself, so the tag stays as it is
    $webBytes = New-CfHtmlSample '<html><body><!--StartFragment--><p><img src="https://example.invalid/x.png"></p><!--EndFragment--></body></html>'
    $webBack = Get-CfHtmlOnDisk $webBytes
    Check 'unit' 'a web picture is left alone' (([BitConverter]::ToString($webBack)) -eq ([BitConverter]::ToString($webBytes))) ''
    # a header whose StartHTML was left at zero still gets its offsets repaired
    $zeroHead = "Version:0.9`r`nStartHTML:0000000000`r`nEndHTML:0000000000`r`nStartFragment:0000000000`r`nEndFragment:0000000000`r`n"
    $zeroBytes = $Utf8.GetBytes($zeroHead + '<html><body><!--StartFragment--><p>x</p><!--EndFragment--></body></html>')
    $zeroFixed = Set-CfHtmlOffsets $zeroBytes
    $zeroText = $Utf8.GetString($zeroFixed)
    $zeroAt = [int](Get-CfHtmlHeadLength $zeroText)
    Check 'unit' 'a zero StartHTML is discovered and repaired' (($zeroAt -gt 0) -and ($zeroText.Substring($zeroAt, 5) -eq '<html')) ([string]$zeroAt)

    # The card lays a formatted entry out with an off-screen RichTextBox, and that engine drops
    # an RTF picture written as \pngblip - which is what Word and Excel write when a picture is
    # copied. The words appeared on the card and every picture was missing, so the picture is
    # re-spelled as a device independent bitmap before the layout runs.
    $cardPng = New-Object Drawing.Bitmap 48, 48
    $cardG = [Drawing.Graphics]::FromImage($cardPng)
    $cardG.Clear([Drawing.Color]::FromArgb(255, 220, 20, 20))
    $cardG.Dispose()
    $cardMs = New-Object IO.MemoryStream
    $cardPng.Save($cardMs, [Drawing.Imaging.ImageFormat]::Png)
    $cardBytes = $cardMs.ToArray()
    $cardPng.Dispose()
    $cardMs.Dispose()
    $cardHex = (([BitConverter]::ToString($cardBytes)) -replace '-', '')
    $cardRtf = '{\rtf1\ansi\deff0\fs20 before {\pict\pngblip\picw48\pich48\picwgoal720\pichgoal720 ' + $cardHex + '} after\par}'
    $cardFixed = ConvertTo-CardRtf $cardRtf
    Check 'unit' 'a png picture is re-spelled for the layout' ((-not ($cardFixed -match '\\pngblip')) -and ($cardFixed -match '\\dibitmap0')) ([string]$cardFixed.Length + ' chars')
    Check 'unit' 'rtf without a picture is left alone' ((ConvertTo-CardRtf '{\rtf1\ansi plain words\par}') -ceq '{\rtf1\ansi plain words\par}') ''
    # a picture the card will not convert is still held by the entry and still pastes back, so
    # the card marks the spot instead of leaving a blank strip nobody can explain
    $savedCardPng = $script:CardRtfMaxPng
    $script:CardRtfMaxPng = 64
    $cardCapped = ConvertTo-CardRtf $cardRtf
    $script:CardRtfMaxPng = $savedCardPng
    Check 'unit' 'a picture too big for the card leaves a block marker' ((-not ($cardCapped -match '\\pngblip')) -and ($cardCapped -match '\@cbimg\@')) ([string]$cardCapped.Length + ' chars')
    $savedCardDib = $script:CardRtfMaxDib
    $script:CardRtfMaxDib = 64
    $cardBudget = ConvertTo-CardRtf $cardRtf
    $script:CardRtfMaxDib = $savedCardDib
    Check 'unit' 'the layout budget leaves a block marker as well' ((-not ($cardBudget -match '\\pngblip')) -and ($cardBudget -match '\@cbimg\@')) ''
    $cardRef = New-RichRef @{ Html = $null; Rtf = $Utf8.GetBytes($cardRtf) }
    [void](Write-RichMedia $cardRef @{ Html = $null; Rtf = $Utf8.GetBytes($cardRtf) })
    Clear-MediaCache
    $cardFont = New-Object Drawing.Font 'Segoe UI', 9
    $cardShot = Get-RichPreviewBitmap $cardRef 380 200 $cardFont ([Drawing.Color]::White)
    $redPixels = 0
    if ($null -ne $cardShot) {
      for ($cy = 0; $cy -lt $cardShot.Height; $cy += 2) {
        for ($cx = 0; $cx -lt $cardShot.Width; $cx += 2) {
          $cpx = $cardShot.GetPixel($cx, $cy)
          if (($cpx.R - $cpx.B) -gt 40 -and $cpx.R -gt 80) { $redPixels++ }
        }
      }
    }
    Check 'unit' 'the card draws the picture of a formatted entry' ($redPixels -gt 100) ([string]$redPixels + ' coloured pixels')
    Clear-MediaCache
    # three sizes, three cards: laid out with its pictures, laid out with a marker where each
    # picture was, or the words alone when the rtf was not kept at all
    Check 'unit' 'the preview mode follows the rtf size' (((Get-RichPreviewMode 0) -eq 'none') -and ((Get-RichPreviewMode 1000) -eq 'full') -and ((Get-RichPreviewMode 9000000) -eq 'plain') -and ((Get-RichPreviewMode 30000000) -eq 'text')) ''
    # a formatted entry is never shown as a picture: only one without any rtf (an Excel copy)
    # has nothing else to show
    Check 'unit' 'a formatted entry never stands in as a picture' ((Test-RichPictureStandIn 'none') -and (-not (Test-RichPictureStandIn 'full')) -and (-not (Test-RichPictureStandIn 'plain')) -and (-not (Test-RichPictureStandIn 'text'))) ''
    $plainShot = Get-RichPreviewBitmap $cardRef 380 200 $cardFont ([Drawing.Color]::White) 'plain'
    # the marker is grey like the panel's secondary text: the colour is appended to the
    # document's own table (or a table is made), so no existing \cfN index moves
    $grayNew = Add-RtfGrayColor '{\rtf1\ansi words}'
    Check 'unit' 'the card marker gets a grey colour' (($grayNew.Index -eq 2) -and ($grayNew.Text -match '\\colortbl ;\\red140\\green140\\blue140;')) ''
    $grayOld = Add-RtfGrayColor '{\rtf1\ansi{\colortbl ;\red255\green0\blue0;} words}'
    Check 'unit' 'an existing colour table keeps its indexes' (($grayOld.Index -eq 3) -and ($grayOld.Text -match '\\blue0;\\red140')) $grayOld.Text
    # Word nests the hex behind a picprop chain; a regex cannot follow that, the brace walk can
    $deepPic = '{\rtf1\ansi a {\*\shppict{\pict{\*\picprop{\sp{\sn shapeType}{\sv 75}}}89504e47}} b}'
    $deepBoxes = @()
    Add-Native
    $deepPlain = [Cb.Rtf]::PadPictures($deepPic, '@cbimg@', 17, 180, 60, 6, [ref]$deepBoxes)
    Check 'unit' 'a deeply nested picture is padded too' (($deepPlain -notmatch '\\pict') -and ($deepPlain -match 'shppict') -and ($deepPlain -match ' b') -and ($deepBoxes.Length -eq 2)) $deepPlain
    $plainShot = Get-RichPreviewBitmap $cardRef 380 200 $cardFont ([Drawing.Color]::White) 'plain'
    Check 'unit' 'a plain card is still laid out' ($null -ne $plainShot) ([string]$cardRtf.Length + ' chars')
    Clear-MediaCache
    Check 'unit' 'the rtf size comes from the reference' (((Get-RichRtfSize $cardRef) -eq $Utf8.GetBytes($cardRtf).Length) -and ((Get-RichRtfSize 'H:' + ('a' * 40) + ':10') -eq 0)) ([string](Get-RichRtfSize $cardRef))
    # a rendered card is kept on disk, so the next hover (or the next session) is a file read
    $cachePath = Get-PreviewCachePath $cardRef 380 200
    # the card cache is derived data: it keeps a week, a file count and a byte budget, and the
    # oldest go first when either budget is passed. The temp folder itself is redirected here,
    # so a card another run left behind cannot make the counts vague.
    $savedTemp = $env:TEMP
    $savedTmp = $env:TMP
    $tempBase = Join-Path $tmpRoot 'cachetest'
    [void](New-Item -ItemType Directory -Path $tempBase -Force)
    $env:TEMP = $tempBase
    $env:TMP = $tempBase
    $cacheDir = Get-PreviewCacheDir
    $savedMaxFiles = $script:PreviewCacheMaxFiles
    $savedMaxBytes = $script:PreviewCacheMaxBytes
    $script:PreviewCacheMaxFiles = 2
    $script:PreviewCacheMaxBytes = 1048576
    foreach ($n in 1..4) {
      $tp = Join-Path $cacheDir ('t' + $n + '.png')
      [IO.File]::WriteAllBytes($tp, $png)
      (Get-Item -LiteralPath $tp).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-$n)
    }
    Clear-OldPreviewCache
    $leftCards = @(Get-ChildItem -LiteralPath $cacheDir -Filter '*.png' -ErrorAction SilentlyContinue)
    Check 'unit' 'the card cache keeps only the newest few' (($leftCards.Count -eq 2) -and ($leftCards[0].Name -eq 't1.png') -and ($leftCards[1].Name -eq 't2.png')) ($leftCards.Name -join ',')
    $stalePath = Join-Path $cacheDir 'tstale.png'
    [IO.File]::WriteAllBytes($stalePath, $png)
    (Get-Item -LiteralPath $stalePath).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-9)
    Clear-OldPreviewCache
    Check 'unit' 'a week-old card is dropped' (-not (Test-Path -LiteralPath $stalePath)) ''
    $script:PreviewCacheMaxFiles = $savedMaxFiles
    $script:PreviewCacheMaxBytes = $savedMaxBytes
    $env:TEMP = $savedTemp
    $env:TMP = $savedTmp
    Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    $probeCard = New-Object Drawing.Bitmap 40, 20
    $probeCard.Save($cachePath, [Drawing.Imaging.ImageFormat]::Png)
    $probeCard.Dispose()
    $backCard = Read-PreviewCache $cachePath
    Check 'unit' 'a cached card reads back' (($null -ne $backCard) -and ($backCard.Width -eq 40) -and ($backCard.Height -eq 20)) ''
    if ($null -ne $backCard) { $backCard.Dispose() }
    Remove-Item -LiteralPath $cachePath -Force
    Check 'unit' 'a card with no job and no fade has nothing to step' (-not (Step-PreviewCard (New-PreviewState))) ''
    # a flyout fades in: the alpha ramps up over PreviewFade and stays whole afterwards
    $fadeState = New-PreviewState
    $fadeState.FadeAt = Get-Date
    $fadeMid = Get-PreviewAlpha $fadeState
    $fadeState.FadeAt = (Get-Date).AddSeconds(-2)
    $fadeEnd = Get-PreviewAlpha $fadeState
    $fadeState.FadeAt = $null
    Check 'unit' 'the card fades in and stays whole' (($fadeMid -lt 255) -and ($fadeMid -ge 0) -and ($fadeEnd -eq 255) -and ((Get-PreviewAlpha $fadeState) -eq 255)) ([string]$fadeMid)
    $fg = New-Object Drawing.Font 'Segoe UI', 9
    $fadeCfg = New-PreviewConfig @{ Surface = [Drawing.Color]::FromArgb(32, 32, 32); Border = [Drawing.Color]::FromArgb(22, 255, 255, 255); Text = [Drawing.Color]::White; Dim = [Drawing.Color]::FromArgb(170, 170, 170) } (New-PickerStringFormats).Ellipsis $fg $fg
    # a Win11 flyout never cuts text mid-glyph: the card has to ellipsize like the rows do
    Check 'unit' 'the card ellipsizes instead of clipping' ($fadeCfg.Sf.Trimming -eq [Drawing.StringTrimming]::EllipsisCharacter) ''

    # a big picture: the card scales it down once and keeps a small copy beside it
    $bigBmp = New-Object Drawing.Bitmap 1600, 900
    $bgfx = [Drawing.Graphics]::FromImage($bigBmp)
    $bgfx.Clear([Drawing.Color]::Teal)
    $bgfx.Dispose()
    $bmStream = New-Object IO.MemoryStream
    $bigBmp.Save($bmStream, [Drawing.Imaging.ImageFormat]::Png)
    $bigBmp.Dispose()
    $bigPng = $bmStream.ToArray()
    $bigPay = New-ImagePayload $bigPng 1600 900 'PNG'
    [void](Write-ImageMedia $bigPay $bigPng)
    $bigRef = Get-ImageRef $bigPay
    Clear-MediaCache
    $card = Get-ImagePreviewBitmap $bigRef.Sha1 380 200
    $cardW = 0
    $cardH = 0
    if ($null -ne $card) { $cardW = $card.Width; $cardH = $card.Height }
    Check 'unit' 'a big picture is scaled into the card' (($null -ne $card) -and ($cardW -le 380) -and ($cardH -le 200) -and ($cardH -gt 100)) ([string]$cardW + 'x' + [string]$cardH)
    Check 'unit' 'the card leaves a small copy behind' (Test-Path -LiteralPath (Get-ImageThumbPath $bigRef.Sha1)) ''
    Clear-MediaCache
    $fromThumb = Get-ImagePreviewBitmap $bigRef.Sha1 380 200
    Check 'unit' 'the small copy renders the same picture' (($null -ne $fromThumb) -and ($fromThumb.Width -eq $cardW) -and ($fromThumb.Height -eq $cardH)) ''
    Clear-MediaCache
    $bigList = New-Object System.Collections.Generic.List[object]
    $bigList.Add((New-Record $bigPay $now ''))
    Save-Records $bigList.ToArray()
    Check 'unit' 'a thumbnail lives while its picture is referenced' (Test-Path -LiteralPath (Get-ImageThumbPath $bigRef.Sha1)) ''
    Save-Records @()
    Check 'unit' 'a thumbnail goes with its picture' ((-not (Test-Path -LiteralPath (Get-ImageThumbPath $bigRef.Sha1))) -and (-not (Test-Path -LiteralPath (Get-MediaPath $bigRef.Sha1 'png')))) ''

    # media is dropped with the record it belongs to
    Save-Records @($mixBack[2])
    Check 'unit' 'dropping an image removes its file' (-not (Test-Path -LiteralPath (Get-MediaPath $iref.Sha1 'png'))) ''
    $rSha = (Get-RichRef $rref).Sha1
    Check 'unit' 'dropping formatted text removes both sidecars' ((-not (Test-Path -LiteralPath (Get-MediaPath $rSha 'html'))) -and (-not (Test-Path -LiteralPath (Get-MediaPath $rSha 'rtf')))) ''

    # the media budget is counted apart from MaxTextTotalBytes: pictures go first, text rows
    # never do
    $savedMediaTotal = $script:MaxMediaTotalBytes
    [void](Write-ImageMedia $p1 $png)
    $script:MaxMediaTotalBytes = [long]10
    $budget = New-Object System.Collections.Generic.List[object]
    $budget.Add($imgRec)
    $budget.Add((New-Record 'a' $now ''))
    Trim-Records $budget
    Check 'unit' 'the media budget drops a picture over the cap' (($budget.Count -eq 1) -and ([string]$budget[0].Payload -eq 'a')) ([string]$budget.Count)
    $script:MaxMediaTotalBytes = [long]($png.Length + 10)
    $budget2 = New-Object System.Collections.Generic.List[object]
    $budget2.Add($imgRec)
    $budget2.Add((New-Record 'a' $now ''))
    Trim-Records $budget2
    Check 'unit' 'the media budget keeps a picture under the cap' ($budget2.Count -eq 2) ([string]$budget2.Count)
    $script:MaxMediaTotalBytes = $savedMediaTotal

    # a file whose header is not the current layout is not parsed, not overwritten and not
    # backed up by the reader: `migrate` is the only thing that may touch it
    [IO.File]::WriteAllText($StoreFile, ('CBHIST' + $RS + '0' + $RS + 't' + $US + [string]$now + $US + $US + 'old text'), $Utf8)
    $sv = Get-StoreVersion
    Check 'unit' 'an older layout is recognised, not read' (($sv.Kind -eq 'old') -and ($sv.Version -eq 0) -and (@(Get-Records).Count -eq 0)) ($sv.Kind + ' v' + $sv.Version)
    Add-Item 'must not overwrite'
    Check 'unit' 'an older layout is never overwritten' (([IO.File]::ReadAllText($StoreFile)).Contains('old text')) ''
    # the version is one constant, and it is what the panel and the CLI report
    Check 'unit' 'the program carries one version' ([string]$script:Version -match '^\d+\.\d+\.\d+$') ([string]$script:Version)

    # no other format support: a file without the CBHIST tag is ignored and left alone
    [IO.File]::WriteAllText($StoreFile, ('alpha' + $RS + 'beta'), $Utf8)
    $uv = Get-StoreVersion
    Check 'unit' 'unknown store format ignored' ((@(Get-Records).Count -eq 0) -and ($uv.Kind -eq 'unknown') -and ($uv.Version -eq -1)) ($uv.Kind + ' v' + $uv.Version)
    Check 'unit' 'unknown format is not backed up' (-not (Test-Path -LiteralPath (Join-Path $unitDir 'history.v1.bak'))) ''
    # a file that is newer than this build is reported, never downgraded
    [IO.File]::WriteAllText($StoreFile, ('CBHIST' + $RS + '9' + $RS + 't' + $US + [string]$now + $US + $US + 'future'), $Utf8)
    $nv = Get-StoreVersion
    Check 'unit' 'a newer layout is reported as newer' (($nv.Kind -eq 'newer') -and ($nv.Version -eq 9)) ($nv.Kind + ' v' + $nv.Version)
    [IO.File]::WriteAllText($StoreFile, '', $Utf8)

    # ---------------------------------------------------------------- migration
    Check 'unit' 'no file needs no migration' ((Invoke-DataMigration).Message -like 'no history file*') ''
    Save-Records @()
    Check 'unit' 'a current file needs no migration' ((Invoke-DataMigration).Message -like 'already CBHIST v*') (Invoke-DataMigration).Message
    # an older file with no step for it is refused, and -Purge archives it instead of guessing
    [IO.File]::WriteAllText($StoreFile, ('CBHIST' + $RS + '0' + $RS + 't' + $US + [string]$now + $US + $US + 'old text'), $Utf8)
    $mr = Invoke-DataMigration
    Check 'unit' 'a version with no step is refused' ((-not $mr.Changed) -and $mr.Message.StartsWith('[!]')) $mr.Message
    Check 'unit' 'a refused migration leaves the file' (([IO.File]::ReadAllText($StoreFile)).Contains('old text')) ''
    $mp = Invoke-DataMigration -Purge
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $unitDir 'data\backup') -Filter '*.dat' -ErrorAction SilentlyContinue)
    Check 'unit' 'purge archives an unreadable file' ($mp.Changed -and $backups.Count -eq 1 -and -not (Test-Path -LiteralPath $StoreFile)) ([string]$backups.Count + ' backup(s)')
    Check 'unit' 'the archived copy keeps the old bytes' (([IO.File]::ReadAllText($backups[0].FullName)).Contains('old text')) ''
    Save-Records @()
    Check 'unit' 'the store is writable again after a purge' (([IO.File]::ReadAllText($StoreFile)).StartsWith($TAG)) ''
    # a newer file is never touched, not even by -Purge
    [IO.File]::WriteAllText($StoreFile, ('CBHIST' + $RS + '9' + $RS + 't' + $US + [string]$now + $US + $US + 'future'), $Utf8)
    $mn = Invoke-DataMigration -Purge
    Check 'unit' 'a newer file is never touched' ((-not $mn.Changed) -and (([IO.File]::ReadAllText($StoreFile)).Contains('future'))) $mn.Message
    [IO.File]::WriteAllText($StoreFile, '', $Utf8)

    Save-Records $recList.ToArray()
    Add-Item 'alpha'
    $r3 = @(Get-Records)
    Check 'unit' 'sorted mark stays on top after add' ($r3[0].Payload -eq 'alpha') $r3[0].Payload
    [void](Set-Mark 'beta' 'p' $true)
    Add-Item 'beta'
    $stillMarked = $false
    foreach ($r in @(Get-Records)) { if ($r.Payload -ceq 'beta' -and (Test-Mark $r 'p')) { $stillMarked = $true } }
    Check 'unit' 'dedupe keeps the marks' $stillMarked ''

    $savedItems = $MaxItems
    $MaxItems = 2
    Save-Records @()
    Add-Item 'p1'
    [void](Set-Mark 'p1' 's' $true)
    foreach ($t in @('n1', 'n2', 'n3', 'n4')) { Add-Item $t }
    $r5 = @(Get-Records)
    $hasMark = $false
    foreach ($r in $r5) { if ($r.Payload -ceq 'p1' -and (Test-Mark $r 's')) { $hasMark = $true } }
    Check 'unit' 'trim keeps a protected mark' ($r5.Count -eq 2 -and $hasMark) (($r5.Count -as [string]) + ' ' + ((Payloads) -join '|'))
    $MaxItems = $savedItems

    # a plugin that limits its own mark needs one pass over the whole list
    Save-Records @()
    Add-Item 'a1'
    Add-Item 'a2'
    [void](Set-Mark 'a1' 'p' $true)
    [void](Set-Mark 'a2' 'p' $true)
    $cleared = Update-Records {
      param($list)
      $n = 0
      foreach ($r in $list) { if (Test-Mark $r 'p') { [void](Set-RecordMark $r 'p' $false); $n++ } }
      return $n
    }
    Check 'unit' 'Update-Records returns the body result' ($cleared -eq 2) ($cleared -as [string])
    Check 'unit' 'Update-Records saved in one write' (-not (@(Get-Records) | Where-Object { Test-Mark $_ 'p' })) ''

    Save-Records @()
    Add-Item 'c1'
    Add-Item 'c2'
    [void](Set-Mark 'c1' 'p' $true)
    Clear-Store (Get-ClearKeepMarks)
    $afterKeep = @(Get-Records)
    Check 'unit' 'clear keeps marked rows' ($afterKeep.Count -eq 1 -and $afterKeep[0].Payload -eq 'c1') ((Payloads) -join '|')
    Clear-Store (Get-ClearKeepMarks -All)
    Check 'unit' 'clear -All drops an unprotected mark' (@(Get-Records).Count -eq 0) ''
    $script:Plugins = @()

    Save-Records @()
    Add-Item 'u1'
    Add-Item 'u2'
    Add-Item 'u3'
    $victim = @(Get-Records)[1]
    [void](Remove-Record $victim.Payload)
    Check 'unit' 'Remove-Record drops one entry' (((Payloads) -join '|') -eq 'u3|u1') ((Payloads) -join '|')
    Restore-Record $victim 1
    Check 'unit' 'Restore-Record puts it back' (((Payloads) -join '|') -eq 'u3|u2|u1') ((Payloads) -join '|')
    Save-Records @()

    # ------------------------------------------------------------ panel helpers
    Check 'unit' 'Get-VisibleRowCount 10 rows' ((Get-VisibleRowCount 340 34) -eq 10) ((Get-VisibleRowCount 340 34) -as [string])
    Check 'unit' 'Get-VisibleRowCount floors' ((Get-VisibleRowCount 100 34) -eq 2) ''
    Check 'unit' 'Get-VisibleRowCount never 0' ((Get-VisibleRowCount 10 40) -eq 1) ''

    # ---------------------------------------------------------------- transitions
    $st = New-AnimState
    Check 'unit' 'anim starts at rest' (($st.Hover -eq 0) -and ($st.HoverTarget -eq 0) -and ($st.HoverIndex -eq -1)) ''
    Set-AnimHover $st 3
    Check 'unit' 'anim hover targets one row' (($st.HoverIndex -eq 3) -and ($st.HoverTarget -eq 1)) ''
    # a separate state, so the eased Hover value below still starts from rest
    $st2 = New-AnimState
    Set-AnimHover $st2 3
    Set-AnimHover $st2 4
    Check 'unit' 'anim hover remembers the row it left' (($st2.HoverIndex -eq 4) -and ($st2.PrevHoverIndex -eq 3)) ($st2.PrevHoverIndex -as [string])
    Set-AnimHover $st2 4
    Check 'unit' 'anim hover ignores a repeat' ($st2.PrevHoverIndex -eq 3) ''
    Set-AnimHover $st2 -1
    Check 'unit' 'leaving the list repaints the last row' (($st2.HoverIndex -eq -1) -and ($st2.PrevHoverIndex -eq 4)) ($st2.PrevHoverIndex -as [string])
    $mask = Invoke-AnimFrame $st 0.5
    Check 'unit' 'anim frame eases by a fraction' ((($mask -band 1) -ne 0) -and ($st.Hover -eq 0.5)) ($mask -as [string])
    $null = Invoke-AnimFrame $st 1.0
    Check 'unit' 'anim frame settles and then idles' (($st.Hover -eq 1) -and ((Invoke-AnimFrame $st 0.5) -eq 0)) ''
    Set-AnimTarget $st 'Hover' 0.0
    $null = Invoke-AnimFrame $st 0.995
    Check 'unit' 'anim frame snaps to the target when close' (($st.Hover -eq 0) -and ((Invoke-AnimFrame $st 0.5) -eq 0)) ($st.Hover -as [string])
    Set-AnimSelection $st 2
    Check 'unit' 'anim selection starts empty' (($st.SelIndex -eq 2) -and ($st.PrevSelIndex -eq -1) -and ($st.Sel -eq 0)) ''
    Set-AnimSelection $st 5
    Check 'unit' 'anim selection remembers the previous row' (($st.PrevSelIndex -eq 2) -and ($st.SelIndex -eq 5) -and ($st.Sel -eq 0)) ''
    Set-AnimSelection $st 5
    Check 'unit' 'anim selection ignores a repeat' ($st.PrevSelIndex -eq 2) ''
    $ac = Scale-Alpha ([Drawing.Color]::FromArgb(200, 10, 20, 30)) 0.5
    Check 'unit' 'Scale-Alpha halves the alpha' (($ac.A -eq 100) -and ($ac.R -eq 10) -and ($ac.B -eq 30)) ($ac.A -as [string])
    Check 'unit' 'Scale-Alpha keeps full strength' ((Scale-Alpha ([Drawing.Color]::FromArgb(200, 10, 20, 30)) 1.0).A -eq 200) ''
    Check 'unit' 'Scale-Alpha fades to nothing' ((Scale-Alpha ([Drawing.Color]::FromArgb(200, 10, 20, 30)) 0).A -eq 0) ''
    $abmp = New-Object Drawing.Bitmap 120, 40
    $agr = [Drawing.Graphics]::FromImage($abmp)
    try {
      $asel = [Drawing.Color]::FromArgb(60, 96, 205, 255)
      $ahov = [Drawing.Color]::FromArgb(30, 255, 255, 255)
      Draw-RowBackdrop $agr 0 0 120 40 4 $null $asel $ahov 0.0 0.0
      Check 'unit' 'row backdrop draws nothing at rest' ($abmp.GetPixel(60, 20).A -eq 0) $abmp.GetPixel(60, 20).ToString()
      Draw-RowBackdrop $agr 0 0 120 40 4 $null $asel $ahov 1.0 0.0
      Check 'unit' 'row backdrop draws the selection' (($abmp.GetPixel(60, 20).A -gt 0) -and ($abmp.GetPixel(60, 20).B -eq 255)) $abmp.GetPixel(60, 20).ToString()
      $tbmp = New-Object Drawing.Bitmap 60, 40
      $tgr = [Drawing.Graphics]::FromImage($tbmp)
      try {
        Draw-RowBackdrop $tgr 0 0 60 40 4 ([Drawing.Color]::FromArgb(255, 0, 255, 0)) $asel $ahov 0.0 0.0
        Check 'unit' 'row backdrop draws a tint' (($tbmp.GetPixel(30, 20).G -eq 255) -and ($tbmp.GetPixel(30, 20).R -eq 0)) $tbmp.GetPixel(30, 20).ToString()
      } finally { $tgr.Dispose(); $tbmp.Dispose() }
    } finally { $agr.Dispose(); $abmp.Dispose() }
    # the height is always chrome + whole rows, so raising the row count can never cut a row
    Check 'unit' 'Get-PanelHeight adds the chrome' ((Get-PanelHeight 10 40 110) -eq 510) ((Get-PanelHeight 10 40 110) -as [string])
    Check 'unit' 'Get-PanelHeight never trims below one row' ((Get-PanelHeight 0 40 110) -eq 150) ''
    Check 'unit' 'Get-RowFit floors the rows' ((Get-RowFit 510 40 110) -eq 10) ((Get-RowFit 510 40 110) -as [string])
    Check 'unit' 'Get-RowFit keeps one row in a tiny area' ((Get-RowFit 100 40 110) -eq 1) ''
    Check 'unit' 'Get-RowsForScreen caps by the screen' ((Get-RowsForScreen 50 510 40 110 3) -eq 10) ((Get-RowsForScreen 50 510 40 110 3) -as [string])
    Check 'unit' 'Get-RowsForScreen keeps the request when it fits' ((Get-RowsForScreen 5 510 40 110 3) -eq 5) ''
    Check 'unit' 'Get-RowsForScreen never goes below the floor' ((Get-RowsForScreen 50 200 40 110 3) -eq 3) ''
    Check 'unit' 'Get-RowsForScreen unknown screen keeps the rows' ((Get-RowsForScreen 7 0 40 110 3) -eq 7) ''
    Check 'unit' 'panel chrome is the header plus the footer' ((Get-PanelChrome) -eq ($script:Metric['HeadHeight'] + $script:Metric['FootHeight'] + 2)) ((Get-PanelChrome) -as [string])
    Check 'unit' 'QuickKey maps from TopIndex' ((Get-QuickKeyIndex 0 5 20 10) -eq 5) ''
    Check 'unit' 'QuickKey follows scroll' ((Get-QuickKeyIndex 3 7 20 10) -eq 10) ''
    Check 'unit' 'QuickKey past the end' ((Get-QuickKeyIndex 9 15 20 10) -eq -1) ''
    Check 'unit' 'QuickKey beyond visible rows' ((Get-QuickKeyIndex 9 0 20 8) -eq -1) ''
    Check 'unit' 'QuickKey only 0-9' ((Get-QuickKeyIndex 10 0 20 10) -eq -1) ''
    Check 'unit' 'QuickKey label: nine rows read 1-9' (((0..8 | ForEach-Object { Get-QuickKeyLabel $_ }) -join '') -eq '123456789') ((0..8 | ForEach-Object { Get-QuickKeyLabel $_ }) -join '')
    Check 'unit' 'QuickKey label: tenth row reads 0' ((Get-QuickKeyLabel 9) -eq '0') (Get-QuickKeyLabel 9)
    Check 'unit' 'QuickKey label: out of range is empty' ((Get-QuickKeyLabel 10) -eq '') ''
    Check 'unit' 'QuickKey digit maps to the keypad row' (((0..9 | ForEach-Object { Get-QuickKeyOffset $_ }) -join ',') -eq '9,0,1,2,3,4,5,6,7,8') ((0..9 | ForEach-Object { Get-QuickKeyOffset $_ }) -join ',')
    Check 'unit' 'QuickKey digit out of range' ((Get-QuickKeyOffset 12) -eq -1) ''
    Check 'unit' 'QuickKey digit 0 picks the tenth row' ((Get-QuickKeyIndex (Get-QuickKeyOffset 0) 0 20 10) -eq 9) ''
    Check 'unit' 'QuickKey digit 1 picks the first row' ((Get-QuickKeyIndex (Get-QuickKeyOffset 1) 4 20 10) -eq 4) ''

    $areas = @(
      [pscustomobject]@{ Left = 0; Top = 0; Width = 1920; Height = 1080 },
      [pscustomobject]@{ Left = 1920; Top = 0; Width = 1920; Height = 1080 }
    )
    $fbArea = [pscustomobject]@{ Left = 0; Top = 0; Width = 1920; Height = 1080 }
    $b = Get-PickerBounds 660 430 '100' '200' $areas $fbArea
    Check 'unit' 'Get-PickerBounds uses saved position' (($b.Left -eq 100) -and ($b.Top -eq 200) -and (-not $b.Fitted)) (($b.Left -as [string]) + ',' + ($b.Top -as [string]))
    $b = Get-PickerBounds 660 430 '5000' '9000' $areas $fbArea
    Check 'unit' 'Get-PickerBounds off-screen falls back' ($b.Fitted -and ($b.Left -eq 630) -and ($b.Top -eq 217)) (($b.Left -as [string]) + ',' + ($b.Top -as [string]))
    $b = Get-PickerBounds 660 430 '1500' '100' $areas $fbArea
    Check 'unit' 'Get-PickerBounds clamps into the screen' ($b.Left -eq 1260) ($b.Left -as [string])
    $b = Get-PickerBounds 660 430 '' '' $areas $fbArea
    Check 'unit' 'Get-PickerBounds empty = centred' $b.Fitted ''

    $marks = Get-HitMarks 'Hello World' @('wor')
    Check 'unit' 'Get-HitMarks case-insensitive' ($marks[6] -and $marks[7] -and $marks[8] -and (-not $marks[0])) ''

    # ------------------------------------------------------------ sticky pins
    Check 'unit' 'StickyRowLimit honours the declared cap' ((Get-StickyRowLimit 10 3) -eq 3) ((Get-StickyRowLimit 10 3) -as [string])
    Check 'unit' 'StickyRowLimit 0 turns the feature off' ((Get-StickyRowLimit 10 0) -eq 0) ''
    Check 'unit' 'StickyRowLimit keeps one row for the results' ((Get-StickyRowLimit 10 -1) -eq 9) ((Get-StickyRowLimit 10 -1) -as [string])
    Check 'unit' 'StickyRowLimit clamps a cap larger than the area' ((Get-StickyRowLimit 2 5) -eq 1) ((Get-StickyRowLimit 2 5) -as [string])
    Check 'unit' 'StickyRowLimit needs room for a result row' ((Get-StickyRowLimit 1 3) -eq 0) ''
    # the same cap drives `config set`: it is what Rows leaves after one row for the results
    Check 'unit' 'StickyRowCap leaves one row for results' ((Get-StickyRowCap 10) -eq 9) ((Get-StickyRowCap 10) -as [string])
    Check 'unit' 'StickyRowCap has no room in a single row' ((Get-StickyRowCap 1) -eq 0) ''

    $stickyRows = @(
      (New-Record 'pinned one' 100 'p'),
      (New-Record 'pinned two' 99 'p'),
      (New-Record 'pinned three' 98 'p'),
      (New-Record 'alpha' 97 ''),
      (New-Record 'beta' 96 '')
    )
    # the search is a plain match: a pin that does not match is hidden like any other row
    $rows = @(Select-QueryRows $stickyRows @('alpha'))
    Check 'unit' 'the search hides an unmatched pin' (((@($rows) | ForEach-Object { $_.Payload }) -join '|') -eq 'alpha') ((@($rows) | ForEach-Object { $_.Payload }) -join '|')
    $rows = @(Select-QueryRows $stickyRows @())
    Check 'unit' 'no query shows every row' (@($rows).Count -eq 5) (@($rows).Count -as [string])

    # ---- query line: the words are cut up by utils/query-words.ps1 and given meaning here
    Check 'unit' 'a quoted phrase keeps its space' (((Split-QueryText 'a "b c" d') -join '|') -eq 'a|b c|d') ((Split-QueryText 'a "b c" d') -join '|')
    Check 'unit' 'an unclosed quote runs to the end of the line' (((Split-QueryText 'a "b c') -join '|') -eq 'a|b c') ((Split-QueryText 'a "b c') -join '|')
    $qp = Get-QueryPart '-type:image'
    Check 'unit' 'a leading minus negates and a colon names a field' (($qp.Negated) -and ($qp.Field -eq 'type') -and ($qp.Value -eq 'image')) ($qp.Field + '/' + $qp.Value)
    # 'https' looks like a field name to the lexer, so the compiler is what keeps a url whole
    Check 'unit' 'a url stays a plain word' ((@(Invoke-Query @(New-Record 'see https://example.com/x now' 1 '') (New-Query -Line 'https://example.com/x')).Count) -eq 1) ''
    $qRows = @(
      (New-Record 'alpha one' 100 ''),
      (New-Record 'alpha two' 90 'p'),
      (New-Record 'beta three' 80 '')
    )
    Check 'unit' 'a word matches whatever its case' ((@(Invoke-Query $qRows (New-Query -Line 'ALPHA')).Count) -eq 2) ''
    Check 'unit' 'a negated word is dropped' ((@(Invoke-Query $qRows (New-Query -Line 'alpha -two')).Count) -eq 1) ''
    Check 'unit' 'a quoted phrase matches as one word' ((@(Invoke-Query $qRows (New-Query -Line '"alpha t"')).Count) -eq 1) ''
    Check 'unit' 'type:text keeps every text row' ((@(Invoke-Query $qRows (New-Query -Line 'type:text')).Count) -eq 3) ''
    $fileRow = New-Record ([char]1 + 'C:\a.txt') 10 ''
    Check 'unit' 'type:files picks the file list out' ((@(Invoke-Query @($qRows + $fileRow) (New-Query -Line 'type:files')).Count) -eq 1) ''
    Check 'unit' 'mark:p keeps the marked row' ((@(Invoke-Query $qRows (New-Query -Line 'mark:p')).Count) -eq 1) ''
    Check 'unit' 'a negated mark drops the marked row' ((@(Invoke-Query $qRows (New-Query -Line '-mark:p')).Count) -eq 2) ''
    Check 'unit' 're: matches a pattern' ((@(Invoke-Query $qRows (New-Query -Line 're:^alpha t')).Count) -eq 1) ''
    $badRegex = New-Query -Line 're:('
    Check 'unit' 'a broken pattern is reported and matches nothing' (($badRegex.Bad.Count -eq 1) -and (@(Invoke-Query $qRows $badRegex).Count -eq 0)) ''
    $badType = New-Query -Line 'type:nonsense'
    Check 'unit' 'an unknown type is reported' ($badType.Bad.Count -eq 1) ([string]$badType.Bad[0])
    $nowSec = Get-Epoch
    $ageRows = @((New-Record 'fresh row' ($nowSec - 60) ''), (New-Record 'stale row' ($nowSec - 172800) ''))
    $aged = @(Invoke-Query $ageRows (New-Query -Line 'age:1d'))
    Check 'unit' 'age:1d keeps only the old row' ((@($aged).Count -eq 1) -and (@($aged)[0].Payload -eq 'stale row')) ''
    $today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    Check 'unit' 'newer: keeps what arrived today' ((@(Invoke-Query $ageRows (New-Query -Line ('newer:' + $today))).Count) -eq 1) ''
    # pinyin initials: level-1 hanzi are ordered by pinyin in GB2312, so this is a range lookup
    $han = ([char]0x4E2D).ToString() + ([char]0x56FD).ToString()
    Check 'unit' 'a hanzi gives its initial' ((Get-PinyinInitial ([char]0x4E2D)) -eq 'Z') (Get-PinyinInitial ([char]0x4E2D))
    Check 'unit' 'a latin letter carries no initial' (((Get-PinyinInitial ([char]'a')) -eq '')) (Get-PinyinInitial ([char]'a'))
    Check 'unit' 'py: matches the initials of a phrase' ((@(Invoke-Query @(New-Record $han 1 '') (New-Query -Line 'py:zg')).Count) -eq 1) ''
    # the empty list explains itself, and a filter nobody understands says so
    $es = Get-EmptyState @() (New-Query -Line 'x') 'x' @{ History = 'H'; Search = 'S' }
    Check 'unit' 'an empty store gets its own hint' (($es.Title -eq 'Clipboard history is empty') -and ($es.Glyph -eq 'H')) $es.Title
    $es = Get-EmptyState $qRows (New-Query -Line 'zzz') 'zzz' @{ History = 'H'; Search = 'S' }
    Check 'unit' 'a search with no results says so' ($es.Title -like 'No results*') $es.Title
    $es = Get-EmptyState $qRows (New-Query -Line 'type:nonsense') 'type:nonsense' @{ History = 'H'; Search = 'S' }
    Check 'unit' 'a filter nobody understands explains itself' ($es.Title -eq 'The search was not understood') $es.Title

    # Typing one character at a time reuses the previous answer as the candidate set, so the
    # panel stops rescanning rows the earlier keystroke already rejected. Every step must still
    # equal a cold run of the same line on its own copy of the rows.
    function Get-ColdPayloads($rows, [string]$line) {
      $copy = @($rows)
      return (@(Invoke-Query $copy (New-Query -Line $line)) | ForEach-Object { [string]$_.Payload }) -join ','
    }
    $narrowRows = @(
      (New-Record 'alpha one' 100 ''),
      (New-Record 'alpha two' 90 ''),
      (New-Record 'alphabet soup' 80 ''),
      (New-Record 'beta three' 70 '')
    )
    $steps = @('a', 'al', 'alp', 'alph', 'alpha', 'alpha o', 'alpha on')
    $drift = @()
    $lastCount = $narrowRows.Count
    foreach ($step in $steps) {
      $live = (@(Invoke-Query $narrowRows (New-Query -Line $step)) | ForEach-Object { [string]$_.Payload }) -join ','
      if ($live -cne (Get-ColdPayloads $narrowRows $step)) { $drift += $step }
    }
    Check 'unit' 'typing narrows without changing the answer' ($drift.Count -eq 0) ($drift -join ' | ')
    # the helper above ran on its own copy, so ask once more on the real array before looking
    [void](Invoke-Query $narrowRows (New-Query -Line 'alpha on'))
    Check 'unit' 'the last keystroke only kept the rows the previous one did' (([object]::ReferenceEquals($script:QueryNarrow.Array, $narrowRows)) -and ($script:QueryNarrow.Rows.Count -le 2)) ([string]$script:QueryNarrow.Rows.Count)
    # a line that does not start with the previous one is a new question, not a narrower one
    $restart = (@(Invoke-Query $narrowRows (New-Query -Line 'beta')) | ForEach-Object { [string]$_.Payload }) -join ','
    Check 'unit' 'a fresh word is answered from the whole list' ($restart -ceq (Get-ColdPayloads $narrowRows 'beta')) $restart
    # extending an exclusion widens the answer, so the old row set must not be reused
    $exclRows = @(
      (New-Record 'ab here' 100 ''),
      (New-Record 'abc here' 90 ''),
      (New-Record 'nothing' 80 '')
    )
    $narrowedAway = @(Invoke-Query $exclRows (New-Query -Line 'here -ab'))
    $widened = @(Invoke-Query $exclRows (New-Query -Line 'here -abc'))
    Check 'unit' 'a longer exclusion is not treated as a narrower one' (($narrowedAway.Count -eq 0) -and ($widened.Count -eq 1)) ([string]$narrowedAway.Count + ' -> ' + [string]$widened.Count)

    # ---- batch selection (lib/select.ps1): positions in the filtered list, nothing else
    $sel = New-Selection
    Check 'unit' 'a new selection holds nothing' ((Get-SelectionCount $sel) -eq 0) ''
    Update-Selection $sel $null 2 $false $false
    Check 'unit' 'a plain click selects one row' (((Get-SelectionCount $sel) -eq 1) -and (Test-RowSelected $sel 2)) ''
    Update-Selection $sel $null 5 $false $true
    Check 'unit' 'shift takes the run from the anchor' (((Get-SelectionCount $sel) -eq 4) -and (Test-RowSelected $sel 5)) ((Get-SelectionCount $sel) -as [string])
    Update-Selection $sel $null 3 $true $false
    Check 'unit' 'ctrl toggles a selected row off' (-not (Test-RowSelected $sel 3)) ''
    Update-Selection $sel $null 3 $true $false
    Check 'unit' 'ctrl toggles it back on' (Test-RowSelected $sel 3) ''
    Update-Selection $sel $null 9 $false $false
    Check 'unit' 'a plain click starts over' ((Get-SelectionCount $sel) -eq 1) ((Get-SelectionCount $sel) -as [string])
    $pickRows = @(@{ Payload = 'a' }, @{ Payload = 'b' }, @{ Payload = 'c' })
    Update-Selection $sel $null 0 $false $false
    Update-Selection $sel $null 2 $true $false
    $picked = @(Get-SelectedRecords $sel $pickRows)
    $pickedText = (@($picked | ForEach-Object { [string]$_.Payload }) -join '')
    Check 'unit' 'a batch keeps list order, not click order' ($pickedText -eq 'ac') $pickedText
    Trim-Selection $sel 2
    Check 'unit' 'a shorter list drops the stale positions' (((Get-SelectionCount $sel) -eq 1) -and (Test-RowSelected $sel 0)) ''
    Select-AllRows $sel $null 3
    Check 'unit' 'select all marks every row' ((Get-SelectionCount $sel) -eq 3) ''
    Clear-Selection $sel
    Check 'unit' 'clearing drops the whole set' (((Get-SelectionCount $sel) -eq 0) -and ($sel.Anchor -eq -1)) ''
    # a batch of rows that carry no text has nothing to copy, and says so by returning nothing
    $mixSel = New-Selection
    Select-AllRows $mixSel $null 2
    $noText = @(@{ Payload = ([char]1 + 'C:\a.txt') }, @{ Payload = ([char]3 + 'image:x:1x1:1:PNG') })
    Check 'unit' 'a batch with no text copies nothing' ($null -eq (Invoke-SelectionCopy $mixSel $noText)) ''
    # one write for the whole set: the store is rewritten once, not once per row
    Save-Records @((New-Record 'batch one' $now ''), (New-Record 'batch two' $now ''))
    $batchRows = @(Get-Records)
    $delSel = New-Selection
    Select-AllRows $delSel $null $batchRows.Count
    $delNote = Invoke-SelectionDelete $delSel $batchRows
    Check 'unit' 'a batch delete removes the whole set' ((@(Get-Records).Count -eq 0) -and ($delNote -like 'deleted 2*')) $delNote
    # freezing is a scrolling behaviour: the leading run of pins is what stays put
    Check 'unit' 'sticky top counts the leading pins' ((Get-StickyTopRows $stickyRows 'p' 5) -eq 3) ((Get-StickyTopRows $stickyRows 'p' 5) -as [string])
    Check 'unit' 'sticky top obeys the declared cap' ((Get-StickyTopRows $stickyRows 'p' 2) -eq 2) ((Get-StickyTopRows $stickyRows 'p' 2) -as [string])
    Check 'unit' 'sticky top stops at the first plain row' ((Get-StickyTopRows @($stickyRows[0], $stickyRows[3], $stickyRows[1]) 'p' 5) -eq 1) ((Get-StickyTopRows @($stickyRows[0], $stickyRows[3], $stickyRows[1]) 'p' 5) -as [string])
    Check 'unit' 'sticky top is off without a mark' ((Get-StickyTopRows $stickyRows '' 5) -eq 0) ''
    Check 'unit' 'sticky top is off with a zero cap' ((Get-StickyTopRows $stickyRows 'p' 0) -eq 0) ''
    # the pin guard reads the same cap: the smaller of the sticky rows and what Rows leaves
    $stickyProbe = @{
      Name       = 'sticky-probe'
      Marks      = [ordered]@{ p = @{ Set = 'pin'; Unset = 'unpin'; Word = 'pinned'; Protected = $false } }
      SortMark   = 'p'
      StickyMark = 'p'
      StickyRows = 3
    }
    $script:Plugins = @($stickyProbe)
    Check 'unit' 'sticky cap is the declared sticky rows' ((Get-PluginStickyCap 10) -eq 3) ([string](Get-PluginStickyCap 10))
    Check 'unit' 'sticky cap shrinks with the visible rows' ((Get-PluginStickyCap 2) -eq 1) ([string](Get-PluginStickyCap 2))
    $stickyProbe['StickyRows'] = -1
    Check 'unit' 'a negative cap means every row but one' ((Get-PluginStickyCap 10) -eq 9) ([string](Get-PluginStickyCap 10))
    $stickyProbe['StickyRows'] = 0
    Check 'unit' 'sticky cap is off when the feature is off' ((Get-PluginStickyCap 10) -eq 0) ([string](Get-PluginStickyCap 10))
    $script:Plugins = @($markPlugin)
    $plan = Get-StickyPlan 10
    Check 'unit' 'sticky plan is off without plugins' (($plan.Mark -eq '') -and ($plan.Max -eq 0)) (($plan.Mark -as [string]) + '/' + ($plan.Max -as [string]))

    Check 'unit' 'Get-ItemLabel collapses newlines' ((Get-ItemLabel "a`r`nb" $false) -eq 'a b') (Get-ItemLabel "a`r`nb" $false)
    Check 'unit' 'Get-ItemLabel keeps marker' ((Get-ItemLabel "a`nb" $true) -eq 'a <NL> b') (Get-ItemLabel "a`nb" $true)
    $files5 = ([string][char]1) + "C:\x\a.txt`nC:\x\b.txt`nC:\x\c.txt`nC:\x\d.txt`nC:\x\e.txt"
    Check 'unit' 'Get-ItemLabel file count' ((Get-ItemLabel $files5 $true) -eq '[files] a.txt, b.txt, c.txt (+2)') (Get-ItemLabel $files5 $true)

    # ------------------------------------------------------------ config schema
    Check 'unit' 'Convert-IniValue bool on' ((Convert-IniValue 'ShowTime' 'on').Value -eq '1') ''
    Check 'unit' 'Convert-IniValue bool bad' (-not (Convert-IniValue 'ShowTime' 'maybe').Ok) ''
    Check 'unit' 'Convert-IniValue int ok' ((Convert-IniValue 'Rows' '12').Value -eq '12') ''
    Check 'unit' 'Convert-IniValue int too small' (-not (Convert-IniValue 'Rows' '1').Ok) ''
    Check 'unit' 'Convert-IniValue int too big' (-not (Convert-IniValue 'MaxItems' '999999999').Ok) ''
    Check 'unit' 'Convert-IniValue install flag' ((Convert-IniValue 'Autostart' 'off').Value -eq '0') ''
    Check 'unit' 'Convert-IniValue int not a number' (-not (Convert-IniValue 'MaxItems' 'many').Ok) ''
    Check 'unit' 'Convert-IniValue theme normalises case' ((Convert-IniValue 'Theme' 'WIN11-LIGHT').Value -eq 'win11-light') ''
    Check 'unit' 'Convert-IniValue enum bad' (-not (Convert-IniValue 'Theme' 'blue').Ok) ''
    Check 'unit' 'Convert-IniValue regex bad' (-not (Convert-IniValue 'ExcludePattern' '(').Ok) ''
    Check 'unit' 'Convert-IniValue hotkey bad' (-not (Convert-IniValue 'Hotkey' 'Ctrl+Nope').Ok) ''
    Check 'unit' 'Convert-IniValue list ok' ((Convert-IniValue 'Plugins' 'item-marks, extra').Value -eq 'item-marks,extra') ''
    Check 'unit' 'Convert-IniValue list rejects bad chars' (-not (Convert-IniValue 'Plugins' 'a b').Ok) ''
    Check 'unit' 'animations default on' ([string]$script:IniSchema['Animations'].Default -eq '1') ([string]$script:IniSchema['Animations'].Default)
    Check 'unit' 'Convert-IniValue unknown key' (-not (Convert-IniValue 'Nope' '1').Ok) ''

    # -------------------------------------------------------------------- themes
    $tn = @(Get-ThemeNames)
    Check 'unit' 'theme files discovered' (($tn -contains 'win11-dark') -and ($tn -contains 'win11-light')) ($tn -join ',')
    Check 'unit' 'theme matches by file name' ((Resolve-ThemeName 'win11-light') -eq 'win11-light') ''
    Check 'unit' 'theme name is case-insensitive' ((Resolve-ThemeName 'WIN11-DARK') -eq 'win11-dark') ''
    Check 'unit' 'theme alias is rejected' (-not (Convert-IniValue 'Theme' 'dark').Ok) ((Convert-IniValue 'Theme' 'dark').Error)
    Check 'unit' 'theme unknown falls back' ((Resolve-ThemeName 'nope') -eq 'win11-dark') ''
    Check 'unit' 'theme colour opaque' ((Convert-ThemeColor '#202020').R -eq 32) ''
    Check 'unit' 'theme colour alpha' ((Convert-ThemeColor '#1CFFFFFF').A -eq 28) ''
    Check 'unit' 'theme colour rejects junk' ($null -eq (Convert-ThemeColor 'red')) ''
    Check 'unit' 'missing theme file is null' ($null -eq (Read-Theme 'nosuch')) ''
    Check 'unit' 'Convert-IniValue theme ok' ((Convert-IniValue 'Theme' 'win11-light').Value -eq 'win11-light') ''
    Check 'unit' 'Convert-IniValue theme alias is rejected' (-not (Convert-IniValue 'Theme' 'light').Ok) ((Convert-IniValue 'Theme' 'light').Error)
    Check 'unit' 'Convert-IniValue theme bad' (-not (Convert-IniValue 'Theme' 'nosuch').Ok) ''
    $script:Theme = 'win11-dark'; Apply-Theme
    $pal = Get-UiPalette
    Check 'unit' 'dark surface' ($pal.Surface.ToArgb() -eq [Drawing.Color]::FromArgb(32, 32, 32).ToArgb()) $pal.Surface.ToString()
    Check 'unit' 'dark accent' ($pal.Accent.ToArgb() -eq [Drawing.Color]::FromArgb(96, 205, 255).ToArgb()) $pal.Accent.ToString()
    Check 'unit' 'dark border keeps alpha' ($pal.Border.A -eq 22) ($pal.Border.A -as [string])
    $script:Theme = 'win11-light'; Apply-Theme
    $pal = Get-UiPalette
    Check 'unit' 'light surface' ($pal.Surface.ToArgb() -eq [Drawing.Color]::FromArgb(243, 243, 243).ToArgb()) $pal.Surface.ToString()
    Check 'unit' 'light text' ($pal.Text.ToArgb() -eq [Drawing.Color]::FromArgb(26, 26, 26).ToArgb()) $pal.Text.ToString()
    Check 'unit' 'theme fonts loaded' ($script:ThemeFonts.Count -ge 4) (($script:ThemeFonts.Keys | Sort-Object) -join ',')
    Check 'unit' 'theme keeps base metrics' ($script:Metric['RowHeight'] -eq 40) ($script:Metric['RowHeight'] -as [string])

    # [metrics] in a theme restyles the rows; the next theme starts from the built-in table
    # again, so an override cannot leak from one theme into another
    $probeTheme = Join-Path $unitDir 'themes\probe-metrics.ini'
    [IO.File]::WriteAllLines($probeTheme, @('name = probe-metrics', '[metrics]', 'TimeWidth = 60', 'RowGap = 4'), $Utf8)
    $script:Theme = 'probe-metrics'
    Apply-Theme
    Check 'unit' 'a theme can restyle row metrics' (($script:Metric['TimeWidth'] -eq 60) -and ($script:Metric['RowGap'] -eq 4)) ($script:Metric['TimeWidth'] -as [string])
    $script:Theme = 'win11-light'
    Apply-Theme
    $leaked = @()
    foreach ($k in @($script:MetricDefault.Keys)) {
      if ([int]$script:Metric[$k] -ne [int]$script:MetricDefault[$k]) { $leaked += $k }
    }
    Check 'unit' 'a theme without metrics restores the built-ins' ($leaked.Count -eq 0) ($leaked -join ', ')
    Remove-Item -LiteralPath $probeTheme -Force -ErrorAction SilentlyContinue
    $script:Theme = 'nosuch-theme'; Apply-Theme
    Check 'unit' 'unknown theme resolves to default' (($script:Theme -eq 'win11-dark') -and ((Get-UiPalette).Surface.ToArgb() -eq [Drawing.Color]::FromArgb(32, 32, 32).ToArgb())) $script:Theme

    $cfg = Join-Path $unitDir 'clipboard.ini'
    [IO.File]::WriteAllLines($cfg, @('# keep me', 'Theme=dark', 'MaxItems=7'), $Utf8)
    [void](Set-IniKey 'Theme' 'win11-light')
    [void](Set-IniKey 'ShowTime' '0')
    $iniText = [IO.File]::ReadAllText($cfg)
    Check 'unit' 'Set-IniKey replaces' ($iniText -match '(?m)^Theme=win11-light\r?$') ''
    Check 'unit' 'Set-IniKey appends' ($iniText -match '(?m)^ShowTime=0\r?$') ''
    Check 'unit' 'Set-IniKey keeps comments' ($iniText -match '# keep me') ''
    Check 'unit' 'Set-IniKey keeps other keys' ($iniText -match '(?m)^MaxItems=7\r?$') ''
    Check 'unit' 'Get-IniKey reads back' ((Get-IniKey 'Theme') -eq 'win11-light') (Get-IniKey 'Theme')

    Apply-Config
    Check 'unit' 'Apply-Config Theme' ($script:Theme -eq 'win11-light') $script:Theme
    Check 'unit' 'Apply-Config ShowTime=0' (-not $script:ShowTime) ''
    Check 'unit' 'Apply-Config MaxItems' ($MaxItems -eq 7) ($MaxItems -as [string])
    Check 'unit' 'install shortcuts default on' ($script:Autostart -and $script:DesktopShortcut) ''
    [IO.File]::WriteAllLines($cfg, @('Rows=1', 'MaxItems=0', 'Highlight=abc'), $Utf8)
    Apply-Config
    Check 'unit' 'Apply-Config rejects out of range' (($script:Rows -eq 10) -and ($MaxItems -eq 300) -and $script:HighlightOn) ('rows=' + $script:Rows + ' items=' + $MaxItems)

    # Apply-Config walks the schema, so a key with a Ref needs a Default and the variable it
    # points at has to end up holding that default whenever the file says nothing
    $noRef = @()
    $drifting = @()
    foreach ($k in @($script:IniSchema.Keys)) {
      $spec = $script:IniSchema[$k]
      if (-not $spec.Contains('Ref')) { continue }
      $slot = $spec['Ref']
      if (-not ($slot -is [System.Management.Automation.PSReference])) { $noRef += $k; continue }
      $def = $spec['Default']
      if ([string]$spec['Type'] -eq 'bool') { $def = ([int]$def -ne 0) }
      elseif ([string]$spec['Type'] -eq 'int' -and [string]$def -ne '') { $def = [int]$def }
      if ([string]$slot.Value -ne [string]$def) { $drifting += ($k + '=' + $slot.Value + '/' + $def) }
    }
    Check 'unit' 'every schema key points at a live variable' ($noRef.Count -eq 0) ($noRef -join ', ')
    Check 'unit' 'the applied values are the schema defaults' ($drifting.Count -eq 0) (($drifting | Select-Object -First 4) -join '; ')

    # ------------------------------------------------------- entry kinds / glyphs
    # the base only separates a file list from text; finer typing is a plugin job
    Check 'unit' 'Get-EntryKind text' ((Get-EntryKind 'plain words') -eq 'text') ''
    Check 'unit' 'Get-EntryKind link is text in base' ((Get-EntryKind 'https://a.b/c') -eq 'text') ''
    Check 'unit' 'Get-EntryKind files' ((Get-EntryKind (([string][char]1) + 'C:\a.txt')) -eq 'files') ''
    Check 'unit' 'Get-EntryKind empty' ((Get-EntryKind '') -eq 'empty') ''

    # a file list carries paths, one per line, and pasting it may also put them on as text
    $fpay = ([string][char]1) + 'C:\one.txt' + "`n" + 'C:\two words.txt'
    $fpaths = @(Get-FilePayloadPaths $fpay)
    Check 'unit' 'a file payload yields its paths' (($fpaths.Count -eq 2) -and ($fpaths[1] -eq 'C:\two words.txt')) ($fpaths -join '|')
    Check 'unit' 'a text payload yields no paths' (@(Get-FilePayloadPaths 'hello').Count -eq 0) ''
    Load-Forms
    $pasteBoth = $false
    try { [void](Set-ClipItem $fpay ''); $pasteBoth = ([Windows.Forms.Clipboard]::ContainsFileDropList()) -and ([Windows.Forms.Clipboard]::ContainsText()) } catch { }
    Check 'unit' 'a pasted file list also carries text' $pasteBoth ''
    $savedFilesAsText = $script:PasteFilesAsText
    $script:PasteFilesAsText = $false
    $dropOnly = $false
    try { [void](Set-ClipItem $fpay ''); $dropOnly = ([Windows.Forms.Clipboard]::ContainsFileDropList()) -and (-not [Windows.Forms.Clipboard]::ContainsText()) } catch { }
    $script:PasteFilesAsText = $savedFilesAsText
    Check 'unit' 'PasteFilesAsText=0 leaves the list alone' $dropOnly ''

    # no plugin means no row icon at all: typing an entry is a plugin's job
    $script:Plugins = @()
    Check 'unit' 'no plugin means no row icon' ((Get-RowGlyph 'https://a.b/c') -eq '') (Get-RowGlyph 'https://a.b/c')
    Check 'unit' 'no plugin means no icon for a file list' ((Get-RowGlyph (([string][char]1) + 'C:\a.txt')) -eq '') ''

    # ------------------------------------------------- plugin loader (opt-in only)
    $pdir = Join-Path $unitDir 'plugins'
    New-Item -ItemType Directory -Path $pdir -Force | Out-Null
    [IO.File]::WriteAllLines((Join-Path $pdir 'one.ps1'), @(
        "@{ Name = 'one'; Description = 'test'; TypeGlyph = { param(`$p) 'L' };";
        "   Commands = @{ 'hi' = { param(`$v) Write-Host ('hi ' + `$v) } };"
        "   Transform = { param(`$p) ('T:' + `$p) };"
        "   RowDecor = { param(`$r) if (`$r.Marks -match 's') { @{ Marks = @( @{ Glyph = 'M'; Color = '#112233' } ); TextColor = '#445566' } } } ;"
        "   Tick = @{ Seconds = 5; Action = { param(`$now) } };"
        "   PanelKeys = @( @{ Key = 'O'; Ctrl = `$true; Label = 'open it'; Test = { param(`$r) `$true }; Invoke = { param(`$r) } } );"
        "   Init = { `$global:cbInitRan = 1 };"
        "   ContextMenu = @( @{ Label = 'Do'; Test = { param(`$r) `$true }; Invoke = { param(`$r) } } ) }"), $Utf8)
    [IO.File]::WriteAllLines((Join-Path $pdir 'two.ps1'), @("@{ Name = 'two' }"), $Utf8)
    [IO.File]::WriteAllLines((Join-Path $pdir 'nameless.ps1'), @("@{ Description = 'x' }"), $Utf8)
    [IO.File]::WriteAllLines((Join-Path $pdir 'boom.ps1'), @('throw "boom"'), $Utf8)
    # a plugin's keys live in its own schema file: the sandbox root carries the real schema
    # folder, so this test plugin only adds one file to schema\plugins
    [IO.File]::WriteAllLines((Join-Path $unitDir 'schema\plugins\one.ps1'), @(
        "@{ Name = 'one'; File = 'clipboard.ini'; Description = 'test';",
        "   Properties = [ordered]@{ Flag = @{ Type = 'bool'; Default = 0; Description = 'test flag' } };",
        "   ThemeProperties = [ordered]@{ Tint = @{ Type = 'color'; Default = '#000000'; Description = 'themeable tint' } } }"), $Utf8)
    # a plugin's keys live in its own schema file: the sandbox root carries the real schema
    # folder, so this test plugin only adds one file to schema\plugins
    [IO.File]::WriteAllLines((Join-Path $unitDir 'schema\plugins\one.ps1'), @(
        "@{ Name = 'one'; File = 'clipboard.ini'; Description = 'test';";
        "   Properties = [ordered]@{ Flag = @{ Type = 'bool'; Default = 0; Description = 'test flag' } };";
        "   ThemeProperties = [ordered]@{ Tint = @{ Type = 'color'; Default = '#000000'; Description = 'themeable tint' } } }"), $Utf8)

    Check 'unit' 'empty Plugins list loads nothing' (@(Load-Plugins $pdir @()).Count -eq 0) ''
    Check 'unit' 'Plugins list loads one' ((@(Load-Plugins $pdir @('one') | ForEach-Object { $_.Name }) -join ',') -eq 'one') ''
    Check 'unit' 'Plugins match ignores case' (@(Load-Plugins $pdir @('ONE')).Count -eq 1) ''
    Check 'unit' 'Plugins ignores unlisted files' ((@(Load-Plugins $pdir @('two', 'one') | ForEach-Object { $_.Name } | Sort-Object) -join ',') -eq 'one,two') ''
    Check 'unit' 'Plugins order is the list order' ((@(Load-Plugins $pdir @('two', 'one') | ForEach-Object { $_.Name }) -join ',') -eq 'two,one') (@(Load-Plugins $pdir @('two', 'one') | ForEach-Object { $_.Name }) -join ',')
    Check 'unit' 'plugin without Name is ignored' (@(Load-Plugins $pdir @('nameless')).Count -eq 0) ''
    Check 'unit' 'broken plugin does not throw' (@(Load-Plugins $pdir @('boom')).Count -eq 0) ''
    [void](Load-Plugins $pdir @('nosuch', 'one'))
    Check 'unit' 'missing plugin name reported' ((@(Get-PluginMissingNames) -join ',') -eq 'nosuch') (@(Get-PluginMissingNames) -join ',')
    Check 'unit' 'missing folder reports every name' ((@(Load-Plugins (Join-Path $unitDir 'nope') @('x')).Count -eq 0) -and ((@(Get-PluginMissingNames) -join ',') -eq 'x')) ''

    $script:Plugins = @(Load-Plugins $pdir @('one', 'two'))
    $pcmd = Get-PluginCommand 'hi'
    Check 'unit' 'Get-PluginCommand returns scriptblock' ($pcmd -is [scriptblock]) ''
    Check 'unit' 'Get-PluginCommand unknown is null' ($null -eq (Get-PluginCommand 'nope')) ''
    $acts = @(Get-PluginActions)
    Check 'unit' 'Get-PluginActions label' (($acts.Count -eq 1) -and ($acts[0].Label -eq 'Do')) ($acts.Count -as [string])
    $rec = [pscustomobject]@{ Payload = 'https://a.b/c'; Flags = 't'; Time = 0; DelIndex = 0 }
    Check 'unit' 'Test-PluginAction true' (Test-PluginAction $acts[0] $rec) ''
    $keys = @(Get-PluginPanelKeys)
    Check 'unit' 'PanelKeys are collected' (($keys.Count -eq 1) -and ($keys[0].Key -eq 'O') -and $keys[0].Ctrl -and ($keys[0].Plugin -eq 'one')) ($keys.Count -as [string])
    Check 'unit' 'PanelKeys match a key press' ($null -ne (Get-PluginPanelKey 'O' $true $false $false)) ''
    Check 'unit' 'PanelKeys need their modifiers' ($null -eq (Get-PluginPanelKey 'O' $false $false $false)) ''
    Check 'unit' 'PanelKeys ignore other keys' ($null -eq (Get-PluginPanelKey 'Q' $true $false $false)) ''
    $script:PluginInitDone = $false
    $global:cbInitRan = 0
    Invoke-PluginInit
    Check 'unit' 'Init hook runs once' ($global:cbInitRan -eq 1) ([string]$global:cbInitRan)
    $global:cbInitRan = 0
    Invoke-PluginInit
    Check 'unit' 'Init hook does not repeat' ($global:cbInitRan -eq 0) ([string]$global:cbInitRan)
    $global:cbInitRan = 0
    Check 'unit' 'Test-PluginAction non-hashtable' (-not (Test-PluginAction 'x' $rec)) ''
    Check 'unit' 'plugin glyph block wins' ((Get-EntryGlyph 'https://a.b/c') -eq 'L') (Get-EntryGlyph 'https://a.b/c')

    # the base never paints an icon of its own
    $script:Plugins = @()
    Check 'unit' 'base glyph: none for text' ((Get-RowGlyph 'https://a.b/c') -eq '') (Get-RowGlyph 'https://a.b/c')
    Check 'unit' 'base glyph: none for code' ((Get-RowGlyph 'function Foo { 1 }') -eq '') (Get-RowGlyph 'function Foo { 1 }')
    Check 'unit' 'base glyph: none for files' ((Get-RowGlyph (([string][char]1) + 'C:\a.txt')) -eq '') ''

    # the shipped plugin is opt-in and loads by file name
    Check 'unit' 'shipped plugin off by default' (@(Load-Plugins (Join-Path $srcRoot 'plugins') @()).Count -eq 0) ''
    $real = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('entry-actions'))
    Check 'unit' 'shipped plugin loads by name' ((@($real | ForEach-Object { $_.Name }) -join ',') -eq 'entry-actions') (@($real | ForEach-Object { $_.Name }) -join ',')
    $script:Plugins = $real
    Check 'unit' 'shipped command: open' ((Get-PluginCommand 'open') -is [scriptblock]) ''
    Check 'unit' 'shipped command: kind' ((Get-PluginCommand 'kind') -is [scriptblock]) ''
    Check 'unit' 'shipped panel key: Ctrl+O' ($null -ne (Get-PluginPanelKey 'O' $true $false $false)) ''
    Check 'unit' 'entry-actions supplies a row icon' ((Get-RowGlyph 'https://a.b/c') -ne '') (Get-RowGlyph 'https://a.b/c')
    Check 'unit' 'entry-actions types a link before a path' ((Get-RowGlyph 'https://a.b/c') -ne (Get-RowGlyph 'C:\temp\a.txt')) ((Get-RowGlyph 'https://a.b/c') + ' vs ' + (Get-RowGlyph 'C:\temp\a.txt'))

    # -------------------------------------------------- plugin settings (own keys)
    $script:Plugins = @(Load-Plugins $pdir @('one'))
    Register-PluginSettings
    Check 'unit' 'plugin setting joins the schema' ($script:IniSchema.Contains('one.Flag')) ''
    Check 'unit' 'plugin setting validates like a base key' ((Convert-IniValue 'one.Flag' 'on').Value -eq '1') ''
    Check 'unit' 'plugin setting rejects bad value' (-not (Convert-IniValue 'one.Flag' 'maybe').Ok) ''
    [IO.File]::WriteAllLines($cfg, @('one.Flag=1'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'plugin setting reads ini value' ((Get-PluginSetting 'one' 'Flag') -eq '1') (Get-PluginSetting 'one' 'Flag')
    [IO.File]::WriteAllLines($cfg, @('one.Flag=maybe'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'plugin setting falls back on bad value' ((Get-PluginSetting 'one' 'Flag') -eq '0') (Get-PluginSetting 'one' 'Flag')
    Check 'unit' 'unknown plugin setting is empty' ((Get-PluginSetting 'one' 'Nope') -eq '') ''

    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('entry-actions'))
    Register-PluginSettings
    [IO.File]::WriteAllLines($cfg, @(), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'shipped plugin declares settings' (($script:IniSchema.Contains('entry-actions.Browser')) -and ($script:IniSchema.Contains('entry-actions.Reveal'))) ''
    Check 'unit' 'shipped setting default' ((Get-PluginSetting 'entry-actions' 'Reveal') -eq '1') (Get-PluginSetting 'entry-actions' 'Reveal')
    Check 'unit' 'shipped setting empty default' ((Get-PluginSetting 'entry-actions' 'Browser') -eq '') ''
    $script:Plugins = @()

    # ------------------------------------------------------ plugin lifecycle hooks
    $script:Plugins = @(Load-Plugins $pdir @('one'))
    $decorRec = [pscustomobject]@{ Payload = 'x'; Time = 0; Marks = 's' }
    $dec = Get-PluginRowDecor $decorRec
    Check 'unit' 'RowDecor marks list' (($dec.Marks.Count -eq 1) -and ($dec.Marks[0].Glyph -eq 'M')) ($dec.Marks.Count -as [string])
    Check 'unit' 'RowDecor mark colour' ($dec.Marks[0].Color -eq '#112233') $dec.Marks[0].Color
    Check 'unit' 'RowDecor text colour' ($dec.TextColor -eq '#445566') $dec.TextColor
    Check 'unit' 'RowDecor has no leading-bar key' (-not $dec.ContainsKey('Emphasis')) ''
    Check 'unit' 'RowDecor empty when nothing applies' (((Get-PluginRowDecor ([pscustomobject]@{ Payload = 'x'; Marks = '' })).Marks).Count -eq 0) ''
    Check 'unit' 'Transform applied' ((Invoke-PluginTransform 'abc') -eq 'T:abc') (Invoke-PluginTransform 'abc')
    $ticks = @(Get-PluginTicks)
    Check 'unit' 'Tick registered' (($ticks.Count -eq 1) -and ($ticks[0].Name -eq 'one') -and ($ticks[0].Seconds -eq 5)) ($ticks.Count -as [string])
    Check 'unit' 'Tick throttles' ($script:PluginTimers.Count -eq 0) ''
    Invoke-PluginTicks
    Check 'unit' 'Tick ran once' ($script:PluginTimers.ContainsKey('tick:one')) ''
    $script:Plugins = @()
    Check 'unit' 'no plugin transform is passthrough' ((Invoke-PluginTransform 'abc') -eq 'abc') ''
    Check 'unit' 'no plugin decor is empty' (((Get-PluginRowDecor $decorRec).Marks).Count -eq 0) ''
    Check 'unit' 'no plugin ticks' (@(Get-PluginTicks).Count -eq 0) ''

    # ------------------------------------------ shipped plugins share their own logic
    # a Tick interval may be computed at runtime, so a plugin needs no timer state
    $script:Plugins = @(@{ Name = 'timed'; Tick = @{ Seconds = { 120 }; Action = { param($now) } } })
    $timed = @(Get-PluginTicks)
    Check 'unit' 'Tick seconds may be a scriptblock' (($timed.Count -eq 1) -and ($timed[0].Seconds -eq 120)) ($timed[0].Seconds -as [string])

    # a plugin may build its menu items at load time, so one setting can produce several
    $script:Plugins = @(@{
        Name        = 'dyn'
        ContextMenu = { @(@{ Label = 'A'; Invoke = { param($r) } }, @{ Label = 'B'; Invoke = { param($r) } }) }
      })
    $dyn = @(Get-PluginActions)
    Check 'unit' 'ContextMenu may be a scriptblock' (($dyn.Count -eq 2) -and ($dyn[0]['Label'] -eq 'A') -and ($dyn[1]['Plugin'] -eq 'dyn')) ($dyn.Count -as [string])
    $script:Plugins = @(@{ Name = 'boom'; ContextMenu = { throw 'boom' } })
    Check 'unit' 'a broken menu scriptblock is skipped' (@(Get-PluginActions).Count -eq 0) ''
    $script:Plugins = @()

    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('item-marks'))
    $menuActs = @(Get-PluginActions)
    $allMarks = [pscustomobject]@{ Payload = 'x'; Time = 0; Marks = 'psh' }
    $noMarks = [pscustomobject]@{ Payload = 'x'; Time = 0; Marks = '' }
    Check 'unit' 'menu caption: every action resolves its own text' ((@($menuActs | ForEach-Object { Get-ActionText $_ $allMarks }) -join '|') -eq 'Remove pin|Remove star|Clear highlight') (@($menuActs | ForEach-Object { Get-ActionText $_ $allMarks }) -join '|')
    Check 'unit' 'menu caption: plain labels for an unmarked row' ((@($menuActs | ForEach-Object { Get-ActionText $_ $noMarks }) -join '|') -eq 'Pin to top|Star|Highlight') (@($menuActs | ForEach-Object { Get-ActionText $_ $noMarks }) -join '|')
    Check 'unit' 'menu caption: static label wins over the fallback' ((Get-ActionText @{ Label = 'Open' } $null) -eq 'Open') ''
    Check 'unit' 'menu caption: missing label falls back' ((Get-ActionText @{} $null) -eq 'Plugin action') ''
    Check 'unit' 'menu caption: a throwing label falls back' ((Get-ActionText @{ Label = { throw 'boom' } } $null) -eq 'Plugin action') ''
    Check 'unit' 'menu actions carry their owner' ((@($menuActs | ForEach-Object { $_['Plugin'] } | Select-Object -Unique) -join ',') -eq 'item-marks') (@($menuActs | ForEach-Object { $_['Plugin'] } | Select-Object -Unique) -join ',')

    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('transform'))
    Register-PluginSettings
    [IO.File]::WriteAllLines($cfg, @('transform.Mode=snake'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    $apply = Get-PluginData 'transform' 'Apply'
    Check 'unit' 'transform exposes one rewrite block' ($apply -is [scriptblock]) ''
    Check 'unit' 'transform hook uses that block' ((Invoke-PluginTransform 'Hello World') -eq (& $apply 'Hello World' 'snake')) (Invoke-PluginTransform 'Hello World')
    Check 'unit' 'transform leaves file lists alone' ((& $apply (([string][char]1) + 'C:\a.txt') 'upper') -eq (([string][char]1) + 'C:\a.txt')) ''
    Check 'unit' 'transform reports the configured mode' ((& (Get-PluginData 'transform' 'CurrentMode')) -eq 'snake') (& (Get-PluginData 'transform' 'CurrentMode'))
    $tActs = @(Get-PluginActions)
    Check 'unit' 'transform lists every mode by default' (($tActs.Count -eq 7) -and ($tActs[0]['Plugin'] -eq 'transform')) ($tActs.Count -as [string])
    $tMenu = $tActs[0]
    Check 'unit' 'transform menu caption names the mode' ((Get-ActionText $tMenu ([pscustomobject]@{ Payload = 'Hello World'; Marks = '' })) -eq 'Transform as plain text') (Get-ActionText $tMenu ([pscustomobject]@{ Payload = 'Hello World'; Marks = '' }))
    Check 'unit' 'transform menu shows for text rows' ((Test-PluginAction $tMenu ([pscustomobject]@{ Payload = 'Hello World'; Marks = '' })) -eq $true) ''
    Check 'unit' 'transform menu hides for file lists' ((Test-PluginAction $tMenu ([pscustomobject]@{ Payload = (([string][char]1) + 'C:\a.txt'); Marks = '' })) -eq $false) ''
    Check 'unit' 'transform menu hides an empty row' ((Test-PluginAction $tMenu ([pscustomobject]@{ Payload = ''; Marks = '' })) -eq $false) ''
    Check 'unit' 'transform menu skips a null row' ((Test-PluginAction $tMenu $null) -eq $false) ''

    # transform.Modes decides how many entries the menu gets, in the written order
    $tRow = [pscustomobject]@{ Payload = 'Hello World demo'; Marks = '' }
    [IO.File]::WriteAllLines($cfg, @('transform.Mode=keep', 'transform.Modes=upper, kebab ,snake'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    $tActs = @(Get-PluginActions)
    Check 'unit' 'Modes lists one entry per mode' ($tActs.Count -eq 3) ($tActs.Count -as [string])
    Check 'unit' 'Modes keeps the written order' ((@($tActs | ForEach-Object { Get-ActionText $_ $tRow }) -join '|') -eq 'Transform as UPPER|Transform as kebab-case|Transform as snake_case') (@($tActs | ForEach-Object { Get-ActionText $_ $tRow }) -join '|')
    Check 'unit' 'Modes works while the paste mode stays keep' ((Test-PluginAction $tActs[0] $tRow) -eq $true) ''
    [void](& $tActs[1]['Invoke'] $tRow)
    Check 'unit' 'each Modes entry rewrites with its own mode' ([string](@(Get-Records)[0].Payload) -eq 'hello-world-demo') ([string](@(Get-Records)[0].Payload))

    [IO.File]::WriteAllLines($cfg, @('transform.Mode=snake', 'transform.Modes=foo,snake'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'unknown Modes value falls back and is reported' ((@(Get-PluginActions).Count -eq 7) -and (@(Get-ConfigProblems).Count -ge 1)) (@(Get-PluginActions).Count -as [string])

    [IO.File]::WriteAllLines($cfg, @('transform.Mode=keep', 'transform.Modes=keep'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'invalid Modes is reported once' (@(Get-ConfigProblems | Where-Object { $_ -match '^transform\.Modes=' }).Count -eq 1) (@(Get-ConfigProblems) -join ';')
    Check 'unit' 'invalid Modes keeps the default list' (@(Get-PluginActions).Count -eq 7) (@(Get-PluginActions).Count -as [string])
    [IO.File]::WriteAllLines($cfg, @('transform.Mode=snake', 'transform.Modes=snake'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings

    # several items from one plugin stay one block: a setting changes the count, the
    # grouping follows the plugin, and the plugins follow the load order
    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('item-marks', 'transform'))
    Register-PluginSettings
    [IO.File]::WriteAllLines($cfg, @('transform.Modes=upper,snake,kebab'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    $owners = @(Get-PluginActions | ForEach-Object { [string]$_['Plugin'] })
    Check 'unit' 'menu keeps one block per plugin' (($owners -join ',') -eq 'item-marks,item-marks,item-marks,transform,transform,transform') ($owners -join ',')
    Check 'unit' 'a plugin block stays contiguous' ((@($owners | Select-Object -Unique) -join ',') -eq 'item-marks,transform') (@($owners | Select-Object -Unique) -join ',')

    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('transform', 'item-marks'))
    Register-PluginSettings
    [IO.File]::WriteAllLines($cfg, @('transform.Mode=snake'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    $owners = @(Get-PluginActions | ForEach-Object { [string]$_['Plugin'] })
    $blocks = @()
    foreach ($o in $owners) { if ($blocks.Count -eq 0 -or $blocks[-1] -ne $o) { $blocks += $o } }
    Check 'unit' 'load order follows the Plugins list' (($blocks -join ',') -eq 'transform,item-marks') ($blocks -join ',')
    $names = @($script:Plugins | ForEach-Object { [string]$_['Name'] })
    Check 'unit' 'plugin list keeps the written order' (($names -join ',') -eq 'transform,item-marks') ($names -join ',')
    $script:Plugins = @()

    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('entry-actions'))
    Register-PluginSettings
    [IO.File]::WriteAllLines($cfg, @(), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'entry-actions exposes one open rule' ((& (Get-PluginData 'entry-actions' 'CanOpen') ([pscustomobject]@{ Payload = 'https://a.b/c' })) -eq $true) ''
    Check 'unit' 'open rule rejects plain text' ((& (Get-PluginData 'entry-actions' 'CanOpen') ([pscustomobject]@{ Payload = 'hello world' })) -eq $false) ''
    Check 'unit' 'open rule accepts a file list' ((& (Get-PluginData 'entry-actions' 'CanOpen') ([pscustomobject]@{ Payload = (([string][char]1) + 'C:\a.txt') })) -eq $true) ''
    Check 'unit' 'open rule ignores a null row' ((& (Get-PluginData 'entry-actions' 'CanOpen') $null) -eq $false) ''
    Check 'unit' 'sniffers live in one block' (((& (Get-PluginData 'entry-actions' 'Sniff') '{"a":1}') -join ',') -match 'json') ''

    # retention: protected rows survive, the sort mark can be kept too
    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('item-marks', 'retention'))
    Register-PluginSettings
    [IO.File]::WriteAllLines($cfg, @('retention.MaxAgeDays=1', 'retention.KeepPinned=1'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    $now = Get-Epoch
    $old = $now - (3 * 86400)
    $age = New-Object System.Collections.Generic.List[object]
    $age.Add((New-Record 'old-plain' $old ''))
    $age.Add((New-Record 'old-star' $old 's'))
    $age.Add((New-Record 'old-pin' $old 'p'))
    $age.Add((New-Record 'fresh' $now ''))
    Save-Records $age.ToArray()
    $dropped = [int](& (Get-PluginData 'retention' 'Sweep'))
    $leftSet = (@((Get-Records) | ForEach-Object { $_.Payload }) | Sort-Object) -join ','
    Check 'unit' 'retention drops only the unprotected old row' ($dropped -eq 1) ([string]$dropped)
    Check 'unit' 'retention keeps protected and pinned rows' ($leftSet -eq 'fresh,old-pin,old-star') $leftSet
    [IO.File]::WriteAllLines($cfg, @('retention.MaxAgeDays=0'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'retention off removes nothing' ((& (Get-PluginData 'retention' 'Sweep')) -eq 0) ''
    $script:Plugins = @()
    Use-StoreLock { Save-Records @() }

    # ----------------------------------------------- protected marks and the store
    $script:Plugins = @($markPlugin)
    Use-StoreLock { Save-Records @() }
    Add-Item 'star-me'
    $r0 = @(Get-Records)[0]
    Check 'unit' 'record starts unmarked' ([string]$r0.Marks -eq '') ([string]$r0.Marks)
    Check 'unit' 'Set-Mark on' (Set-Mark 'star-me' 's' $true) ''
    Check 'unit' 'mark survives a reload' (Test-Mark @(Get-Records)[0] 's') ''
    Check 'unit' 'Set-Mark is idempotent' (-not (Set-Mark 'star-me' 's' $true)) ''
    Check 'unit' 'delete refuses a protected row' ((Remove-Record 'star-me') -eq 'protected:s') (Remove-Record 'star-me')
    Check 'unit' 'delete -Force removes it' ((Remove-Record 'star-me' -Force) -eq 'removed') ''

    $tl = New-Object System.Collections.Generic.List[object]
    $tl.Add((New-Record 'keep-star' 1 's'))
    $tl.Add((New-Record 'drop-1' 2 ''))
    $tl.Add((New-Record 'drop-2' 3 ''))
    $oldMax = $MaxItems
    $MaxItems = 1
    Trim-Records $tl
    $MaxItems = $oldMax
    Check 'unit' 'trim keeps a protected row' (($tl.Count -eq 1) -and ($tl[0].Payload -eq 'keep-star')) (($tl | ForEach-Object { $_.Payload }) -join ',')

    Use-StoreLock { Save-Records @() }
    Add-Item 'keep-on-clear'
    [void](Set-Mark 'keep-on-clear' 's' $true)
    Add-Item 'drop-on-clear'
    Clear-Store (Get-ClearKeepMarks)
    Check 'unit' 'clear keeps a protected row' (((@(Get-Records) | ForEach-Object { $_.Payload }) -join ',') -eq 'keep-on-clear') (((@(Get-Records) | ForEach-Object { $_.Payload }) -join ','))
    Use-StoreLock { Save-Records @() }

    # a mark nobody protects is stored, printed and dropped like any other row
    Add-Item 'mark-me'
    $h0 = @(Get-Records)[0]
    Check 'unit' 'record starts unhighlighted' (-not (Test-Mark $h0 'h')) ''
    Check 'unit' 'Set-Mark on an undeclared mark' (Set-Mark 'mark-me' 'h' $true) ''
    Check 'unit' 'undeclared mark survives a reload' (Test-Mark @(Get-Records)[0] 'h') ''
    $rawStore = [IO.File]::ReadAllText($StoreFile)
    Check 'unit' 'mark stored in the flag string' ($rawStore.Contains([string][char]30 + 'th' + [string][char]31)) ''
    Check 'unit' 'Set-Mark is idempotent for a display mark' (-not (Set-Mark 'mark-me' 'h' $true)) ''
    Check 'unit' 'unprotected mark does not block a delete' ((Remove-Record 'mark-me') -eq 'removed') ''
    Add-Item 'mark-clear'
    [void](Set-Mark 'mark-clear' 'h' $true)
    Clear-Store (Get-ClearKeepMarks -All)
    Check 'unit' 'clear drops unprotected marks' (@(Get-Records).Count -eq 0) ([string]@(Get-Records).Count)
    $script:Plugins = @()
    Use-StoreLock { Save-Records @() }

    # -------------------------------------- theme is a package, not ini colour knobs
    [IO.File]::WriteAllLines($cfg, @('Theme.Accent=#FF6600'), $Utf8)
    $script:IniCache = $null
    $script:Theme = 'win11-dark'
    Apply-Theme
    Check 'unit' 'theme colours are not ini keys' (-not $script:IniSchema.Contains('Theme.Accent')) ''
    Check 'unit' 'palette ignores unknown Theme.* keys' ((Get-UiPalette).Accent.ToArgb() -eq [Drawing.Color]::FromArgb(96, 205, 255).ToArgb()) (Get-UiPalette).Accent.ToString()
    Check 'unit' 'palette comes from the theme file' ((Get-UiPalette).Surface.ToArgb() -eq [Drawing.Color]::FromArgb(32, 32, 32).ToArgb()) (Get-UiPalette).Surface.ToString()
    [IO.File]::WriteAllLines($cfg, @(), $Utf8)
    $script:IniCache = $null
    Apply-Theme

    $script:Theme = 'win11-light'
    Apply-Theme
    Check 'unit' 'light palette still switches by name' ((Get-UiPalette).Surface.ToArgb() -eq [Drawing.Color]::FromArgb(243, 243, 243).ToArgb()) (Get-UiPalette).Surface.ToString()
    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('item-marks'))
    Register-PluginSettings
    Register-PluginThemeSettings
    Apply-PluginSettings
    Apply-PluginTheme
    Check 'unit' 'theme restyles a plugin ThemeSetting' ((Get-PluginTheme 'item-marks' 'StarColor') -eq '#9D5D00') (Get-PluginTheme 'item-marks' 'StarColor')
    Check 'unit' 'theme restyles the emphasis ink' ((Get-PluginTheme 'item-marks' 'EmphasisInk') -eq '#005FB8') (Get-PluginTheme 'item-marks' 'EmphasisInk')
    $hrec = [pscustomobject]@{ Payload = 'hi'; Time = 0; Marks = 'h' }
    $hdec = Get-PluginRowDecor $hrec
    Check 'unit' 'highlight decor paints the text' ($hdec.TextColor -eq '#005FB8') $hdec.TextColor
    Check 'unit' 'highlight decor paints the background' ($hdec.BackColor -eq '#24005FB8') $hdec.BackColor

    # the highlight colours are theme items: no ini key may override them
    Check 'unit' 'highlight ink is not an ini key' (-not $script:IniSchema.Contains('item-marks.HighlightColor')) ''
    Check 'unit' 'highlight fill is not an ini key' (-not $script:IniSchema.Contains('item-marks.HighlightBg')) ''
    Check 'unit' 'highlight colours are theme settings' (($script:PluginThemeValues.ContainsKey('item-marks.EmphasisInk')) -and ($script:PluginThemeValues.ContainsKey('item-marks.EmphasisFill'))) ''
    Check 'unit' 'highlight ink comes from the theme' ($hdec.TextColor -eq (Get-PluginTheme 'item-marks' 'EmphasisInk')) $hdec.TextColor
    Check 'unit' 'highlight fill comes from the theme' ($hdec.BackColor -eq (Get-PluginTheme 'item-marks' 'EmphasisFill')) $hdec.BackColor
    # an ini line with the old key is ignored, the theme keeps painting the row
    [IO.File]::WriteAllLines($cfg, @('item-marks.HighlightColor=#123456', 'item-marks.HighlightBg=#99123456'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    $idec = Get-PluginRowDecor $hrec
    Check 'unit' 'a stale ini highlight key is ignored' (($idec.TextColor -eq $hdec.TextColor) -and ($idec.BackColor -eq $hdec.BackColor)) ($idec.TextColor + ' / ' + $idec.BackColor)
    [IO.File]::WriteAllLines($cfg, @(), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    $prec = [pscustomobject]@{ Payload = 'hi'; Time = 0; Marks = 'ps' }
    $pdec = Get-PluginRowDecor $prec
    Check 'unit' 'pin and star both become glyph marks' ($pdec.Marks.Count -eq 2) ($pdec.Marks.Count -as [string])
    Check 'unit' 'pin and star draw no leading bar' (-not $pdec.ContainsKey('Emphasis')) ''
    Check 'unit' 'theme leaves plugin Settings alone' (-not $script:IniSchema.Contains('item-marks.StarGlyph')) ''
    Check 'unit' 'plugin ThemeSettings are not ini keys' (-not $script:IniSchema.Contains('item-marks.StarColor')) ''
    $script:Plugins = @()
    $script:Theme = 'win11-dark'
    Apply-Theme

    # ThemeSettings default when the theme has no section for the plugin
    $script:Theme = 'win11-dark'
    Apply-Theme
    $script:ThemeOverrides = @{}
    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('item-marks'))
    Register-PluginThemeSettings
    Apply-PluginTheme
    Check 'unit' 'ThemeSettings fall back to the plugin default' ((Get-PluginTheme 'item-marks' 'StarGlyph') -eq [string][char]0xE735) ''
    $script:Plugins = @()

    Save-Records @()
  }

    # the drawing helpers live in lib/panel/picker-draw.ps1 and take a Graphics plus plain values,
    # so they can be exercised without a window - that is what "no form state" buys.
    # Unit only (the helpers come from the -Library load) and source only: a packaged copy
    # has renamed internals, so the names do not exist there.
    if ($Unit -and -not $isPackaged) {
      Use-Drawing
      $script:FBody = New-Object Drawing.Font('Tahoma', [single]10)
      $script:FSmall = New-Object Drawing.Font('Tahoma', [single]9)
      $drawOk = $true
      $drawErr = ''
      $bmp = New-Object Drawing.Bitmap 240, 48
      $gfx = [Drawing.Graphics]::FromImage($bmp)
      try {
        Draw-KeyChips $gfx 4 18 @(@('Enter', 'Paste'), @('Esc', 'Close')) ([Drawing.Color]::Gray) ([Drawing.Color]::DimGray) 240
        Draw-Highlight $gfx 'hello world' (New-Object Drawing.RectangleF 0, 0, 120, 20) @('wor') ([Drawing.Brushes]::White) ([Drawing.Brushes]::Yellow)
      }
      catch {
        $drawOk = $false
        $drawErr = $_.Exception.Message
      }
      finally {
        $gfx.Dispose()
        $bmp.Dispose()
      }
      Check 'unit' 'drawing helpers run on a plain bitmap' $drawOk $drawErr

      # one hint pair reaches the function flattened by PowerShell's list handling; it must
      # still be drawn as [Esc] Close instead of three single-character chips
      $flatOk = $true
      $flatErr = ''
      $bmp2 = New-Object Drawing.Bitmap 240, 48
      $gfx2 = [Drawing.Graphics]::FromImage($bmp2)
      try {
        Draw-KeyChips $gfx2 4 18 @('Esc', 'Close') ([Drawing.Color]::Gray) ([Drawing.Color]::DimGray) 240
        $col = $bmp2.GetPixel(8, 18)
        if ($col.R -eq 0 -and $col.G -eq 0 -and $col.B -eq 0) { throw 'nothing was drawn' }
      }
      catch {
        $flatOk = $false
        $flatErr = $_.Exception.Message
      }
      finally {
        $gfx2.Dispose()
        $bmp2.Dispose()
      }
      Check 'unit' 'a flattened single hint pair still draws a chip' $flatOk $flatErr

      # The footer lists only what is possible right now: a batch can be copied and deleted
      # but not pasted or edited, only a plain text row offers F2, and Esc clears the search
      # before it closes the panel.
      function Get-HintText($pairs) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($p in @($pairs)) {
          if ($p -is [array]) { $parts.Add([string]$p[0] + ' ' + [string]$p[1]) }
          else { $parts.Add([string]$p) }
        }
        return ($parts -join ' | ')
      }
      $hSingle = Get-HintText (Get-PanelHints 5 0 $true 0 $false @())
      Check 'unit' 'a text row offers paste, copy, edit, delete' ((($hSingle -match 'Enter') -and ($hSingle -match 'Paste')) -and (($hSingle -match 'F2') -and ($hSingle -match 'Edit')) -and (($hSingle -match 'Del') -and ($hSingle -match 'Delete')) -and ($hSingle -match 'Close')) $hSingle
      $hPic = Get-HintText (Get-PanelHints 5 0 $false 0 $false @())
      Check 'unit' 'a row that cannot be edited offers no F2' ((-not ($hPic -match 'Edit')) -and ($hPic -match 'Paste')) $hPic
      $picRec = New-Record (New-ImagePayload $png 2 2 'PNG') 1 ''
      Check 'unit' 'a picture row cannot be edited' (-not (Test-RowEditable $picRec)) (Get-RowEditBlock $picRec)
      $listPay = [string][char]1 + 'C:\a.txt'
      $listRec = New-Record $listPay 1 ''
      Check 'unit' 'a file list row cannot be edited' (-not (Test-RowEditable $listRec)) (Get-RowEditBlock $listRec)
      $fmtRec = New-Record 'hello' 1 ''
      $fmtRec.Rich = 'H1'
      Check 'unit' 'a formatted row cannot be edited' (-not (Test-RowEditable $fmtRec)) (Get-RowEditBlock $fmtRec)
      Check 'unit' 'a plain text row can be edited' (Test-RowEditable (New-Record 'hello' 1 '')) ''
      $hMulti = Get-HintText (Get-PanelHints 5 3 $true 0 $false @())
      Check 'unit' 'a batch offers copy and delete with its size' ((($hMulti -match 'Copy 3') -and ($hMulti -match 'Delete 3')) -and (-not ($hMulti -match 'Paste')) -and (-not ($hMulti -match 'Edit'))) $hMulti
      $hQuery = Get-HintText (Get-PanelHints 5 0 $true 4 $false @())
      Check 'unit' 'a search turns the Escape hint into clear' (($hQuery -match 'Clear') -and (-not ($hQuery -match 'Close'))) $hQuery
      $hEmpty = Get-HintText (Get-PanelHints 0 0 $false 0 $false @())
      Check 'unit' 'an empty list only offers close' (($hEmpty -match 'Close') -and (-not ($hEmpty -match 'Paste'))) $hEmpty
      $hCtrl = Get-HintText (Get-PanelHints 5 3 $true 0 $true @() $false $true)
      Check 'unit' 'the Ctrl footer counts a batch too' (($hCtrl -match 'Copy 3') -and ($hCtrl -match 'Undo')) $hCtrl
      # one key/action pair per chip: a flattened first pair drew [Ctrl+Enter Copy] as one chip
      $ctrlPairs = @(Get-PanelHints 5 3 $true 0 $true @(@{ Key = 'O'; Hint = 'Open' }) $false $true)
      $shapeOk = $ctrlPairs.Count -gt 0
      foreach ($p in $ctrlPairs) {
        if ($p -isnot [array] -or @($p).Count -ne 2) { $shapeOk = $false }
      }
      $pluginChip = @($ctrlPairs | Where-Object { @($_)[0] -eq 'Ctrl+O' })
      if ($pluginChip.Count -ne 1 -or [string](@($pluginChip[0])[1]) -ne 'Open') { $shapeOk = $false }
      Check 'unit' 'every Ctrl hint is one key/action pair' $shapeOk ((@($ctrlPairs | ForEach-Object { @($_).Count }) -join ','))
      $hNoUndo = Get-HintText (Get-PanelHints 5 0 $true 0 $true @() $false $false)
      Check 'unit' 'the Ctrl footer drops undo while it is off' (-not ($hNoUndo -match 'Undo')) $hNoUndo
      $hEdit = Get-HintText (Get-PanelHints 5 0 $true 0 $false @() $true $true)
      Check 'unit' 'an edit in progress lists only the editor keys' ((($hEdit -match 'Save') -and ($hEdit -match 'Newline')) -and (-not ($hEdit -match 'Paste'))) $hEdit

      # The self-painted list freezes its first rows. 10 visible rows of 10px, 3 frozen, so
      # the scrollable window is 7 rows tall and TopIndex can never drop below 3.
      Add-PinList
      $pl = New-Object Cb.PinList
      $pl.ItemHeight = 10
      $pl.SetBounds(0, 0, 200, 100)
      $pl.ItemCount = 30
      $pl.PinnedCount = 3
      $pl.TopIndex = 3
      Check 'unit' 'the scrollable part starts under the frozen block' ($pl.TopIndex -eq 3) ([string]$pl.TopIndex)
      $pl.ScrollBy(-5)
      Check 'unit' 'scrolling up never drags a pin away' ($pl.TopIndex -eq 3) ([string]$pl.TopIndex)
      Check 'unit' 'a frozen row keeps its place' ($pl.GetItemRectangle(0).Y -eq 0) ([string]$pl.GetItemRectangle(0).Y)
      $before = $pl.GetItemRectangle(3).Y
      $pl.ScrollBy(2)
      Check 'unit' 'a scrollable row moves with the list' ($pl.GetItemRectangle(3).Y -eq ($before - 20)) ([string]$pl.GetItemRectangle(3).Y)
      Check 'unit' 'the frozen block stays put while scrolling' ($pl.GetItemRectangle(0).Y -eq 0) ([string]$pl.GetItemRectangle(0).Y)
      $pl.ScrollTo(999)
      Check 'unit' 'the last row can reach the bottom edge' (($pl.MaxTop -eq 23) -and ($pl.TopIndex -eq 23)) ([string]$pl.TopIndex + '/' + [string]$pl.MaxTop)
      # the control keeps a row count only: the labels stay with the caller
      Check 'unit' 'the list stores a row count, not the labels' (-not ($pl.PSObject.Properties.Name -contains 'Items')) ''
      # a Control that only syncs the scrollbar leaves the wheel dead: the list scrolls itself
      $pl.WheelRows = 2
      $pl.ScrollTo(3)
      # the panel moves its scrollbar thumb from this event, so a scroll has to report it
      $script:plScrolls = 0
      $pl.Add_ScrollChanged({ $script:plScrolls = $script:plScrolls + 1 })
      $wheelM = $pl.GetType().GetMethod('OnMouseWheel', [System.Reflection.BindingFlags]'Instance,NonPublic')
      $wheelArg = New-Object 'object[]' 1
      $wheelArg[0] = [Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::None, 0, 10, 10, -120)
      [void]$wheelM.Invoke($pl, $wheelArg)
      Check 'unit' 'the wheel scrolls the list itself' ($pl.TopIndex -eq 5) ([string]$pl.TopIndex)
      Check 'unit' 'a scroll tells the panel to move the thumb' ($script:plScrolls -gt 0) ([string]$script:plScrolls)
      $pl.ScrollTo(999)
      [void]$wheelM.Invoke($pl, $wheelArg)
      Check 'unit' 'the wheel never scrolls past the last row' (($pl.TopIndex -eq $pl.MaxTop) -and ($pl.TopIndex + $pl.VisibleRows - $pl.PinnedCount - 1 -eq ($pl.ItemCount - 1))) ([string]$pl.TopIndex + '/' + [string]$pl.MaxTop)
      $pl.Dispose()
    }

}
catch {
  # an unexpected exception used to skip every remaining group and still exit 0, which
  # reads as a green run; report it as a failure instead
  Check 'harness' 'run finished without an exception' $false $_.Exception.Message
}
finally {
  # Restore the clipboard while capture is still paused: whatever is left on the clipboard
  # is recorded by the resident as soon as capture resumes, so it must not be test junk.
  if ($clipBak) { [void](Set-Clip $clipBak) } else { [void](Set-Clip '') }
  if ($wePaused) { [void](& powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $clipPs1 resume 2>&1) }
  try { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# tests\run.ps1 reads this back; a plain run leaves the file alone
if ($ResultFile) {
  # ToArray, not @($list): wrapping a List[object] throws "Argument types do not match" in 5.1
  $payload = @{ Part = 'unit'; Source = $srcRoot; Results = $script:results.ToArray(); Timings = $script:unitTimings.ToArray() }
  try {
    [IO.File]::WriteAllText($ResultFile, ($payload | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
  } catch { Write-Output ('[!] cannot write ' + $ResultFile + ': ' + $_.Exception.Message) }
}

$pass = @($script:results | Where-Object { $_.Result -eq 'PASS' }).Count
$fail = @($script:results | Where-Object { $_.Result -eq 'FAIL' }).Count
$skipped = @($script:results | Where-Object { $_.Result -eq 'SKIP' }).Count
if (-not $Quiet) {
  Write-Host ''
  Write-TestCounts 'Checks' $pass $fail $skipped $script:results.Count
  Write-Output ('TOTAL ' + $script:results.Count + '   PASS ' + $pass + '   FAIL ' + $fail + '   SKIP ' + $skipped)
}
if ($fail -gt 0) { exit 1 }
exit 0

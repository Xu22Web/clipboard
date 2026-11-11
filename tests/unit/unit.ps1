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

# This file owns the one sandbox the whole part shares, so it does not call Start-TestPart:
# it takes the describe/it layer from the shared harness and keeps its own results and
# sandbox below. harness.ps1 loads the reporter as well.
. (Join-Path $repoRoot 'tests\lib\harness.ps1')
$script:results = New-Object System.Collections.Generic.List[object]
# the label every row prints with
$script:Harness.Part = 'unit\unit'
Initialize-TestReporter -Mode 'verbose' -Quiet:$Quiet
$script:unitStarted = Get-Date
if (-not $Quiet) { Write-TestBanner $programVersion ([string]$srcRoot) }
$script:unitTimings = New-Object System.Collections.Generic.List[object]

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
# the rows record through the shared harness, so the progress line comes from its writer
$script:Harness.Utf8 = $Utf8
$script:Harness.ProgressFile = $ProgressFile

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
  # another module already owns. The rows that read a name or a size out of the source run
  # for the readable copy only, because a packaged one renames its internals.
  Describe 'struct' {
    # decided while the rows are collected, because that is when -Skip is read
    $script:StructMinified = ''
    if ($isPackaged) { $script:StructMinified = 'a packaged copy renames its internals' }

    # the files the rules apply to: lib\, the pure helpers in utils\ and the two schema files
    # (the schema plugins\ directory holds manifests, not dot-sourced modules)
    BeforeAll {
      $script:StructEntryPath = Join-Path $srcRoot 'clipboard.ps1'
      $script:StructLibPath = Join-Path $srcRoot 'lib'
      $files = @()
      if (Test-Path -LiteralPath $script:StructLibPath) { $files = @(Get-ChildItem -LiteralPath $script:StructLibPath -Filter '*.ps1' -File -Recurse | Sort-Object -Property Name) }
      $utilsPath = Join-Path $srcRoot 'utils'
      if (Test-Path -LiteralPath $utilsPath) { $files += @(Get-ChildItem -LiteralPath $utilsPath -Filter '*.ps1' -File -Recurse | Sort-Object -Property Name) }
      $schemaPath = Join-Path $srcRoot 'schema'
      if (Test-Path -LiteralPath $schemaPath) { $files += @(Get-ChildItem -LiteralPath $schemaPath -Filter '*.ps1' -File | Sort-Object -Property Name) }
      $script:StructFiles = $files
    }

    Describe 'module set' {
      It 'every required module exists' {
        # the entry file names these by relative path; a package must carry all of them
        $requiredLib = @('lib\base', 'lib\native', 'lib\panel\keyhook', 'lib\theme-stub', 'lib\settings', 'lib\marks', 'lib\ordering',
          'lib\media', 'lib\cfhtml', 'lib\clip', 'lib\blobs', 'lib\store', 'lib\migrate', 'lib\transfer', 'lib\modifiers', 'lib\apprules', 'lib\entry', 'lib\query', 'lib\select', 'lib\panel\picker-geom', 'lib\panel\anim',
          'lib\panel\picker-draw', 'lib\panel\picker-edit', 'lib\panel\media-render', 'lib\panel\pinlist', 'lib\panel\preview', 'lib\panel\picker', 'lib\serve', 'lib\shortcut',
          'lib\config', 'lib\config-template', 'lib\usage', 'lib\dispatch',
          'utils\ini', 'utils\inifile', 'utils\schema', 'utils\log', 'utils\time', 'utils\format', 'utils\dpi', 'utils\hotkey',
          'utils\query-words', 'utils\transfer', 'utils\apprules', 'utils\fileio',
          'utils\hash', 'utils\cfhtml', 'utils\image',
          'schema\clipboard', 'schema\theme')
        $missingLib = @()
        foreach ($m in $requiredLib) {
          if (-not (Test-Path -LiteralPath (Join-Path $srcRoot ($m + '.ps1')))) { $missingLib += $m }
        }
        Expect ($missingLib.Count -eq 0) ($missingLib -join ', ')
      }

      It 'plugin layer ships complete' {
        # the plugin layer is three files; a package carries all of them or none (plugins.ps1
        # is the optional one, and the other two mean nothing without it)
        $pluginLayer = @('plugins', 'plugin-settings', 'plugin-marks')
        $pluginPresent = @($pluginLayer | Where-Object { Test-Path -LiteralPath (Join-Path $script:StructLibPath ($_ + '.ps1')) })
        Expect (($pluginPresent.Count -eq 0) -or ($pluginPresent.Count -eq $pluginLayer.Count)) ($pluginPresent -join ', ')
      }

      It 'modules are plain dot-sourced scripts' {
        # $PSScriptRoot inside lib\ points at lib\, so any path built from it is one level
        # deep. Look at the code, not at the prose: the module headers explain this rule.
        $badParse = @()
        $badParam = @()
        $badPath = @()
        foreach ($f in $script:StructFiles) {
          $tk = $null
          $pe = $null
          $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tk, [ref]$pe)
          if ($pe.Count -gt 0) { $badParse += ($f.Name + ': ' + $pe[0].Message); continue }
          if ($ast.ParamBlock) { $badParam += $f.Name }
          $selfPaths = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and [string]$node.VariablePath.UserPath -match '(?i)(^|:)(PSScriptRoot|PSCommandPath)$' }, $true))
          if ($selfPaths.Count -gt 0) { $badPath += $f.Name }
        }
        Expect ($badParse.Count -eq 0) ($badParse -join '; ')
        Expect ($badParam.Count -eq 0) ($badParam -join ', ')
        Expect ($badPath.Count -eq 0) ($badPath -join ', ')
      }

      It 'no duplicate function names' {
        # a duplicate top-level name lets one module silently overwrite another (shared
        # scope); theme-stub.ps1 is the documented exception - lib/themes.ps1 replaces it
        $owner = @{}
        $dups = @()
        foreach ($f in @(Get-Item -LiteralPath $script:StructEntryPath) + $script:StructFiles) {
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
        Expect ($dups.Count -eq 0) ($dups -join ', ')
      }

      It 'payload kinds go through the predicates' {
        # A payload kind is a leading character. Every module asks base.ps1's predicates instead
        # of comparing that character itself, so adding a kind stays a change in two files.
        $prefixFiles = @($script:StructFiles | Where-Object { $_.Name -notin @('base.ps1', 'entry.ps1', 'media.ps1') })
        $prefixFiles += @(Get-ChildItem -LiteralPath (Join-Path $srcRoot 'plugins') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
        $offenders = @()
        foreach ($f in $prefixFiles) {
          if ([IO.File]::ReadAllText($f.FullName) -match '\[char\](1|3)\b') { $offenders += $f.Name }
        }
        Expect ($offenders.Count -eq 0) ($offenders -join ', ')
      }
    }

    # sizes and the single $Root line only make sense in the readable source
    Describe 'entry point' {
      It 'stays an entry point' {
        $entryLines = @([IO.File]::ReadAllLines($script:StructEntryPath)).Count
        # 224, not 200: the entry also decides whether the resident answers the command instead
        # of a fresh process (the proxy block), which is a table plus a few lines of glue, and
        # `status` needs a group of its own for the panel geometry it prints
        Expect ($entryLines -le 224) ([string]$entryLines + ' lines')
      } -Skip $script:StructMinified

      It 'computes the tool root once' {
        $rootHits = ([regex]::Matches([IO.File]::ReadAllText($script:StructEntryPath), '(?m)^\$Root = Split-Path -Parent \$PSCommandPath\s*$')).Count
        Expect ($rootHits -eq 1) ([string]$rootHits + ' occurrence(s)')
      } -Skip $script:StructMinified
    }

    Describe 'module table' {
      BeforeAll {
        # the entry loads only the module groups a command can reach. A command the dispatcher
        # knows and the table does not would reach the default group and fail at run time, so
        # the two lists have to line up; the group lists in turn have to name files that exist.
        $entryText = [IO.File]::ReadAllText($script:StructEntryPath)
        $dispatchText = [IO.File]::ReadAllText((Join-Path $srcRoot 'lib\dispatch.ps1'))
        $script:StructDispatched = @([regex]::Matches($dispatchText, "(?m)^  '([a-z0-9-]+)' \{") | ForEach-Object { $_.Groups[1].Value })
        $groupBlock = ($entryText -split '\$groupModules = @\{')[1]
        if ($groupBlock) { $groupBlock = ($groupBlock -split "\r?\n\}")[0] } else { $groupBlock = '' }
        $tableBlock = ($entryText -split '\$commandGroups = @\{')[1]
        if ($tableBlock) { $tableBlock = ($tableBlock -split "\r?\n\}")[0] } else { $tableBlock = '' }
        $script:StructTableKeys = @([regex]::Matches($tableBlock, "(?m)^  '([a-z0-9-]+)'") | ForEach-Object { $_.Groups[1].Value })
        $script:StructGroupNames = @([regex]::Matches($groupBlock, '(?m)^  ([a-z]+)\s+=') | ForEach-Object { $_.Groups[1].Value })
        $script:StructUsedGroups = @($tableBlock -split "'" | Where-Object { $script:StructGroupNames -contains $_ } | Select-Object -Unique)
        $script:StructGroupFiles = @([regex]::Matches($groupBlock, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -match '^[a-z]' })
      }

      It 'maps every dispatched command to the module table' {
        # ui and serve are answered by the panel branch of the entry, everything else by the table
        $unmapped = @($script:StructDispatched | Where-Object { $script:StructTableKeys -notcontains $_ -and @('ui', 'serve') -notcontains $_ })
        Expect ($script:StructDispatched.Count -ge 15 -and $unmapped.Count -eq 0) (($unmapped -join ', ') + ' / ' + $script:StructDispatched.Count + ' commands')
      } -Skip $script:StructMinified

      It 'names no unknown command or group' {
        $unknownCommand = @($script:StructTableKeys | Where-Object { $script:StructDispatched -notcontains $_ })
        Expect ($script:StructTableKeys.Count -ge 15 -and $unknownCommand.Count -eq 0) ($unknownCommand -join ', ')
        Expect ($script:StructGroupNames.Count -ge 4 -and $script:StructUsedGroups.Count -ge 1) (($script:StructGroupNames -join ', ') + ' / used ' + ($script:StructUsedGroups -join ', '))
      } -Skip $script:StructMinified

      It 'names only modules that exist' {
        $missingGroupFile = @($script:StructGroupFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $srcRoot ($_ + '.ps1'))) })
        Expect ($script:StructGroupFiles.Count -ge 15 -and $missingGroupFile.Count -eq 0) (($missingGroupFile -join ', ') + ' / ' + $script:StructGroupFiles.Count + ' modules')
      } -Skip $script:StructMinified

      It 'every command can reach the functions it calls' {
        # `status` prints the panel size and shape, which needs picker-geom: without it the
        # one-shot path throws, reloads every group and registers the plugins a second time -
        # which is where the "duplicate key" lines in the log came from
        $entryText = [IO.File]::ReadAllText($script:StructEntryPath)
        $groupBlock = ($entryText -split '\$groupModules = @\{')[1]
        if ($groupBlock) { $groupBlock = ($groupBlock -split "\r?\n\}")[0] }
        $need = @{
          'status' = @('lib\panel\picker-geom')
          'list'   = @('lib\store')
          'config' = @('lib\config-template')
        }
        foreach ($cmd in @($need.Keys)) {
          $line = [regex]::Match($entryText, "(?m)^  '" + $cmd + "'\s*= @\(([^)]*)\)")
          Expect ($line.Success) ($cmd + ' is not in the module table')
          $files = @()
          foreach ($g in @([regex]::Matches($line.Groups[1].Value, "'([a-z]+)'") | ForEach-Object { $_.Groups[1].Value })) {
            $m = [regex]::Match($groupBlock, "(?m)^  " + $g + "\s+= @\(([^)]*)\)")
            if ($m.Success) { $files += @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
          }
          $missing = @($need[$cmd] | Where-Object { $files -notcontains $_ })
          Expect ($missing.Count -eq 0) ($cmd + ' cannot reach ' + ($missing -join ', '))
        }
      } -Skip $script:StructMinified
    }

    # the tooling lives outside src\: package.ini declares the commands, cli runs them
    Describe 'tooling' {
      It 'ships with the repo' {
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
        Expect ($missingTool.Count -eq 0) ($missingTool -join ', ')
      } -Skip $script:StructMinified

      It 'package.ini declares every command' {
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
        Expect (($pkgText -match '(?m)^Name=\S') -and ($pkgText -match '(?m)^Version=\d+\.\d+\.\d+') -and $noCmd.Count -eq 0) ($noCmd -join ', ')
      } -Skip $script:StructMinified

      It 'ini files use lower case sections and PascalCase keys' {
        # every tracked ini follows the shared convention
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
        Expect ($badIni.Count -eq 0) ($badIni -join ', ')
      } -Skip $script:StructMinified

      # the renamer replaces a variable by its parsed extent, and a splat's extent starts at
      # the '@': rebuilding it as `$name` turns `f @h` into `f $h`, a positional argument
      if (Test-Path -LiteralPath (Join-Path $repoRoot 'tools\utils\minify.ps1')) {
        It 'the renamer keeps a splat a splat' {
          . (Join-Path $repoRoot 'tools\utils\minify.ps1')
          $tmpIn = Join-Path ([IO.Path]::GetTempPath()) ('splat-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
          $tmpOut = $tmpIn + '.min.ps1'
          try {
            [IO.File]::WriteAllText($tmpIn, ("function f { param(`$x, `$y) `$x }" + "`r`n`r`n" + "`$h = @{ x = 1; y = 2 }" + "`r`n`r`n" + "f @h" + "`r`n"), $Utf8)
            [void](Invoke-MinifyFile -Path $tmpIn -OutPath $tmpOut)
            $min = [IO.File]::ReadAllText($tmpOut)
            Expect ($min -match '(?m)^f @[A-Za-z_]') $min.Trim()
          } finally {
            Remove-Item -LiteralPath $tmpIn, $tmpOut -Force -ErrorAction SilentlyContinue
          }
        } -Skip $script:StructMinified
      }

      It 'the program and the tooling parse ini the same way' {
        # The program and the tooling each carry an ini parser (src\utils\ini.ps1 + inifile.ps1
        # and tools\utils\ini.ps1). The rules are the same on paper; this keeps them the same in
        # fact, because a rule that holds for clipboard.ini and not for cli.ini fails silently.
        # Both files define Read-IniDoc, so the program copy is parsed first and then replaced
        # by the tool copy. The two settings files need no test here: every command validates
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
        Expect ($iniDiff.Count -eq 0) ($iniDiff -join ', ')
      } -Skip $script:StructMinified
    }

    # The panel must never take the foreground: a low-level keyboard hook feeds its controls
    # instead (lib/panel/keyhook.ps1), so the user's window keeps the focus and the caret. The
    # takeover fallback (no hook, or an IME) still hands the foreground back on close.
    Describe 'panel' {
      BeforeAll {
        $script:StructPickerText = [IO.File]::ReadAllText((Join-Path $script:StructLibPath 'panel\picker.ps1'))
        $script:StructDrawText = [IO.File]::ReadAllText((Join-Path $script:StructLibPath 'panel\picker-draw.ps1'))
        $winText = [IO.File]::ReadAllText((Join-Path $script:StructLibPath 'native.ps1'))
        # the platform C# lives in lib\assembly (a package ships only the compiled
        # lib\assembly\clipboard.dll), so the check reads the repository source even when
        # -Source points at a package
        $winCs = Join-Path $defaultSource 'lib\assembly\cb.native.cs'
        if (Test-Path -LiteralPath $winCs) { $winText += [IO.File]::ReadAllText($winCs) }
        $script:StructWinText = $winText
      }

      It 'is shown without a dialog and without TopMost' {
        # a modal dialog would block the hook that feeds the panel, and TopMost would raise the
        # panel over the window the user is working in
        Expect (-not ($script:StructPickerText -match '\$form\.ShowDialog\(')) 'form.ShowDialog found'
        $topHits = ([regex]::Matches($script:StructPickerText, '(?m)^\s*\$form\.TopMost\s*=')).Count
        Expect ($topHits -eq 0) ([string]$topHits + ' assignment(s)')
      }

      It 'is shown once, non-modally' {
        $showHits = ([regex]::Matches($script:StructPickerText, '(?m)^\s*\$form\.Show\(\)\s*$')).Count
        Expect ($showHits -eq 1) ([string]$showHits + ' call(s)')
      }

      It 'the panel form never activates' {
        Expect (($script:StructWinText -match 'ShowWithoutActivation') -and ($script:StructWinText -match '0x08000000')) 'no-activate override missing'
      }

      It 'hands the foreground back when it closes' {
        Expect ($script:StructPickerText -match 'SetForegroundWindow\(\$prev\)') 'restore call missing'
      }

      It 'installs and removes the key hook' {
        Expect (($script:StructPickerText -match 'Enable-KeyHook') -and ($script:StructPickerText -match 'Disable-KeyHook')) 'hook calls missing'
      }

      It 'the key hook is released in a finally' {
        # A WH_KEYBOARD_LL hook outlives the panel's own teardown and swallows every key in the
        # system, so it has to be released from a finally block: releasing it after the message
        # loop means one exception on the way out leaves the keyboard dead.
        $pickerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:StructLibPath 'panel\picker.ps1'), [ref]$null, [ref]$null)
        $finallyText = (@($pickerAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true) |
            ForEach-Object { $_.Finally.Extent.Text }) -join "`n")
        Expect ($finallyText -match 'Disable-KeyHook') ''
      } -Skip $script:StructMinified

      It 'paste releases the key hook before injecting' {
        Expect ($script:StructPickerText -match '(?s)function Paste-Clip[^\r\n]*\{.{0,600}Disable-KeyHook') 'Disable-KeyHook missing before SendKeys'
      }

      It 'the paste target is the window in front, and never one of ours' {
        # after an input-method hand-over the panel itself is in front; the daemon's console can
        # be too. Neither is somewhere to paste into, so the window the panel came from is used.
        Expect ($script:StructPickerText -match 'Get-PasteTarget') 'no Get-PasteTarget in the picker'
        Expect ($script:StructPickerText -match 'IsOwnWindow') 'the paste may be aimed at one of our own windows'
        Expect ($script:StructPickerText -match 'Format-PasteTarget') 'the paste target is not written to the log'
      }

      It 'the foreground is taken by one helper, shared with the hand-over' {
        # the panel is refused the foreground while another process owns it, and the documented
        # workaround (AttachThreadInput) is worth writing once, not twice
        Expect ($script:StructPickerText -match 'Take-Foreground') 'the paste does not use Take-Foreground'
        $khText = [IO.File]::ReadAllText((Join-Path $script:StructLibPath 'panel\keyhook.ps1'))
        Expect ($khText -match '(?s)function Take-Foreground') 'Take-Foreground missing'
        Expect ($khText -match '(?s)function Switch-ToTakeover[^\r\n]*\{(?:(?!function ).){0,600}Take-Foreground') 'the hand-over does not use Take-Foreground'
        Expect (-not ($khText -match '(?s)function Switch-ToTakeover[^\r\n]*\{(?:(?!function ).){0,600}AttachThreadInput')) 'the attach is still written in Switch-ToTakeover as well'
      }

      It 'the foreground is checked again after the panel hides' {
        # hiding the panel can leave another window in front - the keys only mean anything while
        # the target still has it, so the check cannot be left at the moment of the hand-over
        Expect ($script:StructPickerText -match '(?s)\$form\.Hide\(\).{0,600}GetForegroundWindow') 'the foreground is not re-checked after the panel hid'
      }

      It 'a modifier still held at the timeout is released' {
        # Control.ModifierKeys reads the calling thread's key state, and the panel never owns the
        # keyboard: waiting on it alone would send Ctrl+V with Alt still down
        $modText = [IO.File]::ReadAllText((Join-Path $script:StructLibPath 'modifiers.ps1'))
        $khText = [IO.File]::ReadAllText((Join-Path $script:StructLibPath 'panel\keyhook.ps1'))
        Expect ($modText -match '(?s)function Get-HeldModifier\s*\{.{0,400}GetAsyncKeyState') 'the modifier wait does not read the real key state'
        Expect ($modText -match 'function Test-Modifiers-Up\s*\{\s*return \(\(Get-HeldModifier\)') 'Test-Modifiers-Up still reads the thread key state'
        Expect ($khText -match '(?s)function Release-HeldModifiers') 'no Release-HeldModifiers'
        Expect ($script:StructPickerText -match 'Release-HeldModifiers') 'a held modifier is never released before the paste'
      }

      It 'gives the caret back after the foreground was moved' {
        # a window that comes back is not a caret that comes back: the focused control is saved
        # when the panel opens and asked for again after a hand-over and after a paste
        Expect ($script:StructPickerText -match 'Save-TargetFocus') 'no Save-TargetFocus in the picker'
        Expect ($script:StructPickerText -match 'Restore-TargetFocus') 'no Restore-TargetFocus in the picker'
      }

      It 'the window size comes from the preset, not from the settings directly' {
        Expect ($script:StructPickerText -match '\$preset = Get-PanelPreset') 'no preset resolved in the picker'
        Expect ($script:StructPickerText -match '\$form\.Width = Px \$preset\.Width') 'the width is not taken from the preset'
        Expect ($script:StructPickerText -match 'Get-PresetChrome \$preset') 'the chrome is not taken from the preset'
        Expect (-not ($script:StructPickerText -match 'Get-PanelChrome\)')) 'the theme chrome is still read by the picker'
      }

      It 'the compact shape drops the time column and the corner count' {
        Expect ($script:StructPickerText -match '\$script:PanelPreset\.ShowTime') 'the time column ignores the preset'
        Expect ($script:StructPickerText -match '\$footR\.Visible = \[bool\]\$preset\.ShowFootRight') 'the corner count ignores the preset'
        # placing the label happens before Show(), where Visible is still false: the decision
        # has to come from the preset or the count lands in the top left corner
        Expect ($script:StructPickerText -match '(?s)function Layout-Chrome\s*\{.{0,800}if \(\$preset\.ShowFootRight\)') 'the corner count is placed from Visible instead of the preset'
      }

      It 'the width is fixed: no drag grip and no saved width' {
        Expect (-not ($script:StructPickerText -match '\$grip')) 'the drag grip is still in the picker'
        Expect (-not ($script:StructPickerText -match 'SaveWinWidth')) 'a saved width is still read by the picker'
      }

      It 'the caret anchors the compact panel' {
        Expect ($script:StructPickerText -match 'Get-CaretAnchor') 'the picker never asks for the caret'
        Expect ($script:StructPickerText -match '\$preset\.AnchorCaret') 'the caret anchor ignores the preset'
        # no single API covers the field: the caret, UI Automation's text selection and the
        # focused control are all tried, cheapest first, and a hung window is skipped
        Expect ($script:StructWinText -match 'function Get-CaretAnchor') 'the anchor helper is missing'
        Expect ($script:StructWinText -match 'function Get-UiaCaretRect') 'the uia tier is missing'
        Expect ($script:StructWinText -match 'IsResponsive') 'a hung window is never skipped'
        Expect ($script:StructWinText -match 'FocusControlBounds') 'the focused-control tier is missing'
        Expect ($script:StructWinText -match 'Current\.ProcessId') 'the focused element is trusted without a process check'
      }

      It 'the caret is read in screen pixels' {
        # a Win32 edit control answers rcCaret inside its own client area - measured: a text box
        # at 308,231 with the caret after "hello" answers 104,1 - so the rect has to be moved to
        # the screen, or the panel anchors at the top left corner of the window it came from
        Expect ($script:StructWinText -match '(?s)CaretOfWindow.{0,2000}ClientToScreen') 'the caret rect is not moved to screen coordinates'
      }

      It 'paste can type instead of injecting a paste key' {
        # PasteTyping=1 hands the text to SendInput: the paste path has to keep that branch,
        # and it must stay inside Paste-Clip so the hand-over and the settle still happen first
        Expect ($script:StructPickerText -match '(?s)function Paste-Clip[^\r\n]*\{.{0,3000}SendUnicode\(\$TypedText\)') 'SendUnicode branch missing in Paste-Clip'
        Expect ($script:StructPickerText -match '\$script:PasteTyping') 'PasteTyping never read'
      }

      It 'reads the list through its own members' {
        # the rows are painted by Cb.PinList, which has no Items collection: a leftover
        # $lst.Items.Count silently reads 0 and the row never repaints
        Expect (-not ($script:StructPickerText -match '\$lst\.Items\b')) '$lst.Items found'
      }

      It 'closes the menu before it closes itself' {
        # A drop-down that outlives the panel keeps the menu filter WinForms installed for it,
        # and that filter eats every later click of the process: whichever path closes the panel
        # has to close the menu first
        Expect ($script:StructPickerText -match '(?s)Add_FormClosing\(\{.{0,600}\$cm\.Close\(\)') 'menu not closed in FormClosing'
      }

      It 'an open menu never counts as a click outside' {
        Expect ($script:StructPickerText -match '\$cm\.Visible[^\r\n]*-and -not \$form\.Bounds') 'outside-click check ignores the menu'
      }

      It 'releases its menu font and form region' {
        # per-open GDI handles: the group heading font and the rounded region the form paints with
        Expect (($script:StructPickerText -match 'groupFont\.Dispose\(\)') -and ($script:StructDrawText -match 'function Update-PanelRegion')) 'GDI handles released nowhere'
      }

      It 'shows a hover card, not a tooltip' {
        # hover is a card that waits and is prepared once, not a tooltip rebuilt on every move
        Expect (-not ($script:StructPickerText -match 'Windows\.Forms\.ToolTip')) 'ToolTip found in the picker'
      }

      It 'the card waits for the cursor to rest' {
        Expect ($script:StructPickerText -match 'PvIdx[^\r\n]*PvAt') 'no hover rest timer'
      }

      It 'the context menu never takes the foreground' {
        # an activating popup deactivates the window the user came from; Explorer's address bar
        # and search box collapse then, and the paste that follows lands nowhere
        Expect ($script:StructPickerText -match '(?s)\[void\]\$cm\.Handle.{0,200}0x08000000') 'menu activation guard missing'
      }

      It 'no whole-window opacity transition' {
        Expect (-not ($script:StructPickerText -match '\$form\.Opacity\s*=')) ''
      }

      It 'row layout and timers come from the published tables' {
        # The panel layout and its timers are read from the two tables base.ps1 publishes, so a
        # theme or a tuning pass touches one place. A bare literal creeping back into the draw
        # code is how the row height and the hit test drifted apart before.
        $metricRefs = [regex]::Matches($script:StructPickerText, '\$m\[').Count
        $timingRefs = [regex]::Matches($script:StructPickerText, '\$script:Timing\[').Count
        Expect ($metricRefs -ge 12) ([string]$metricRefs + ' metric refs')
        Expect ($timingRefs -ge 8) ([string]$timingRefs + ' timing refs')
      } -Skip $script:StructMinified

      It 'the Shown handler paints the search box active' {
        # the handler must go through Focus-Search: taking the real focus there would activate
        # the panel and defeat the hook model
        $pickerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:StructLibPath 'panel\picker.ps1'), [ref]$null, [ref]$null)
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
        Expect ($shownBlocks.Count -eq 1 -and $shownFocus -eq 0) ([string]$shownBlocks.Count + ' handler(s), ' + [string]$shownFocus + ' Focus call(s)')
        Expect ($shownHelper -eq 1) ([string]$shownHelper + ' Focus-Search call(s)')
        Expect ($shownPaint -eq 1) ([string]$shownPaint + ' search box mark(s)')
      } -Skip $script:StructMinified

      It 'a click in the search area takes the keyboard for real' {
        # opening only paints the field (the hook keeps the window in front untouched); a click
        # on the field is a request for the keyboard, and the hook cannot deliver that without
        # the panel owning the foreground - so the search area hands over instead
        Expect ($script:StructPickerText -match '(?s)function Claim-Search\s*\{.{0,400}Switch-ToTakeover') 'Claim-Search does not hand the keyboard over'
        foreach ($handler in @('\$head', '\$box', '\$txt', '\$ph', '\$icon')) {
          $hit = ($script:StructPickerText -match ($handler + '\.Add_Click\(\{ Claim-Search \}\)'))
          Expect $hit ($handler + ' still focuses without claiming')
        }
        # the placeholder covers the empty field: without its own claim an empty box would only
        # take the keyboard when the text box, hidden under it, happened to be hit
        Expect (([regex]::Matches($script:StructPickerText, '\.Add_Click\(\{ Claim-Search \}\)')).Count -ge 5) 'search area handlers missing'
      } -Skip $script:StructMinified
    }
  }

  # The queue runs here and the phase stays at "run" from this point on: the rows below are
  # written where their setup is, in the order the part needs, so each one executes in place
  # instead of being collected first.
  Invoke-TestQueue
  # these rows are only the head of the part, so the total falls back to the cached count
  $script:Harness.Progress.Total = 0

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

    # the settings file the rows write and read: the tool keeps it beside its own script
    $script:UnitCfg = Join-Path $unitDir 'clipboard.ini'

    # ---- pure helpers: hotkeys, the one-line form of a payload, the hover preview
    Describe 'hotkey and text helpers' {
      It 'Parse-Hotkey reads the modifiers' {
        $h = Parse-Hotkey 'Ctrl+Alt+V'
        Expect ($h.Mods -eq 3) ('mods=0x' + $h.Mods.ToString('X2'))
        $win = Parse-Hotkey 'Win+Shift+V'
        Expect ($win.Mods -eq 0x0C) ('mods=0x' + $win.Mods.ToString('X2'))
      }

      It 'Parse-Hotkey reads the key and ignores case and spaces' {
        $v = Parse-Hotkey 'Ctrl+Alt+V'
        Expect ($v.Vk -eq 0x56) ('vk=0x' + $v.Vk.ToString('X2'))
        $f9 = Parse-Hotkey 'ctrl + alt + f9'
        Expect ($f9.Vk -eq 0x78 -and $f9.Mods -eq 3) ('vk=0x' + $f9.Vk.ToString('X2'))
        $tick = Parse-Hotkey 'Ctrl+Alt+`'
        Expect ($tick.Vk -eq 0x60) ('vk=0x' + $tick.Vk.ToString('X2'))
      }

      It 'Parse-Hotkey leaves an unknown key empty' {
        Expect ((Parse-Hotkey 'Ctrl+Nope').Vk -eq 0) ''
      }

      It 'Format-Item gives a payload one line' {
        Expect ((Format-Item "a`r`nb" 40) -eq 'a <NL> b') ''
        $cut = Format-Item ('x' * 50) 10
        Expect ($cut.Length -eq 13 -and $cut.EndsWith('...')) $cut
      }

      It 'Format-Item names the files of a file drop' {
        $files = ([string][char]1) + "C:\x\a.txt`nD:\y\b.txt"
        Expect ((Format-Item $files 80) -eq '[files] a.txt, b.txt') (Format-Item $files 80)
      }

      It 'the hover preview clamps the payload before it splits' {
        # the card costs the same whatever the size of the entry is
        $pvLines = Get-PreviewLines ((('line ' + [Environment]::NewLine) * 4000)) 40 6
        Expect ($pvLines.Count -eq 6 -and $pvLines[5] -eq '...') ([string]$pvLines.Count + ' lines, last=' + $pvLines[5])
        $pvCut = Get-PreviewLines ('x' * 500) 20 2
        Expect ($pvCut.Count -eq 1 -and $pvCut[0].Length -eq 20 -and $pvCut[0].EndsWith('...')) ([string]$pvCut[0].Length)
      }

      It 'the hover preview counts the clamped head' {
        $pvInfo = Get-PreviewInfo ('a' * 9000)
        Expect ($pvInfo -match '6000\+ chars') $pvInfo
      }

      It 'PreviewChars bounds what the card reads' {
        # PreviewChars is a setting now, so the card really reads only that much
        $saved = $script:PreviewChars
        try {
          $script:PreviewChars = 200
          $pvSmall = Get-PreviewLines ('y' * 900) 60 4
          Expect ($pvSmall.Count -eq 1 -and $pvSmall[0].Length -eq 60 -and $pvSmall[0].EndsWith('...')) ([string]$pvSmall.Count)
        } finally { $script:PreviewChars = $saved }
      }

      It 'the hover preview names the files of a file drop' {
        $files = ([string][char]1) + "C:\x\a.txt`nD:\y\b.txt"
        $pvFiles = Get-PreviewLines $files 60 3
        Expect ($pvFiles[0] -match '\[files\]' -and $pvFiles[0] -match 'a.txt') $pvFiles[0]
      }
    }

    # ---- the settings file: template, reader, sections, cache, Apply-Config
    Describe 'settings file' {
      It 'Write-IniTemplate writes a file with the defaults' {
        if (Test-Path -LiteralPath $script:UnitCfg) { Remove-Item -LiteralPath $script:UnitCfg -Force }
        $written = Write-IniTemplate
        Expect (Test-Path -LiteralPath $written) $written
        $template = [IO.File]::ReadAllText($written)
        Expect (($template -match 'Hotkey=Ctrl\+Alt\+V') -and ($template -match 'MaxItems=300')) ''
      }

      It 'Read-Ini truncates what it reads and skips what it cannot' {
        $lines = @('# hash comment', '; semi comment', 'Hotkey=Ctrl+Shift+F9', 'Theme = light ', 'Quoted="a b"', 'Garbage', 'MaxItems=7')
        [IO.File]::WriteAllLines($script:UnitCfg, $lines, $Utf8)
        $kv = Read-Ini
        Expect (-not $kv.ContainsKey('# hash comment')) ''
        Expect ($kv['Theme'] -eq 'light') ('Theme=' + $kv['Theme'])
        Expect ($kv['Quoted'] -eq 'a b') ('Quoted=' + $kv['Quoted'])
        Expect (-not $kv.ContainsKey('Garbage')) ''
        Expect ($kv['MaxItems'] -eq '7') ('MaxItems=' + $kv['MaxItems'])
        Expect ($kv['Hotkey'] -eq 'Ctrl+Shift+F9') ('Hotkey=' + $kv['Hotkey'])
      }

      It 'a section prefixes the keys that follow' {
        # every .ini follows one rule: "[a]" + "b=1" is the same key as "a.b=1", written flat
        [IO.File]::WriteAllLines($script:UnitCfg, @('Theme=win11-dark', '[item-marks]', 'MaxPins=50', 'StickyPins=1'), $Utf8)
        $kv = Read-Ini
        Expect (($kv['item-marks.MaxPins'] -eq '50') -and ($kv['item-marks.StickyPins'] -eq '1') -and ($kv['Theme'] -eq 'win11-dark')) ($kv['item-marks.MaxPins'])
        [void](Set-IniKey 'item-marks.MaxPins' '7')
        $secText = [IO.File]::ReadAllText($script:UnitCfg)
        Expect (($secText -match '(?m)^\[item-marks\]\r?$') -and ($secText -match '(?m)^MaxPins=7\r?$') -and (-not ($secText -match '(?m)^item-marks\.MaxPins='))) $secText.Trim()
        $kv = Read-Ini
        Expect ($kv['item-marks.MaxPins'] -eq '7') ($kv['item-marks.MaxPins'])
      }

      It 'a parse is cached until the file changes' {
        # one engine for every .ini: a parse is cached per file and re-used until the file changes
        [IO.File]::WriteAllLines($script:UnitCfg, @('MaxItems=11'), $Utf8)
        $firstRead = Read-Ini
        $secondRead = Read-Ini
        Expect ([object]::ReferenceEquals($firstRead, $secondRead)) ''
        # the length is the same as the value below, so only the write time tells them apart
        [IO.File]::WriteAllLines($script:UnitCfg, @('MaxItems=12'), $Utf8)
        $external = Read-Ini
        Expect ($external['MaxItems'] -eq '12') ('MaxItems=' + $external['MaxItems'])
        [void](Set-IniKey 'MaxItems' '13')
        $afterWrite = Read-Ini
        Expect ($afterWrite['MaxItems'] -eq '13') ('MaxItems=' + $afterWrite['MaxItems'])
      }

      It 'a repeated key keeps the last value, in file order' {
        # the file order is what the command list is drawn from
        $parsed = Read-IniDoc @('[pkg]', 'B=1', 'A=2', 'B=3')
        Expect ($parsed.Map['pkg.B'] -eq '3') ('B=' + $parsed.Map['pkg.B'])
        Expect (($parsed.Keys -join ',') -eq 'pkg.B,pkg.A') ($parsed.Keys -join ',')
        # the line a key was written on is the last one it appears on
        Expect ((Get-IniDocLine $parsed 'pkg.B') -eq 'B=3') (Get-IniDocLine $parsed 'pkg.B')
      }

      It 'a template keeps the values the file already holds' {
        # fitting a file to the template is one pure step: the template brings the headings, the
        # order and one line per key, the file brings the values
        $doc = Read-IniDoc @('', '# ---- panel behaviour ----', 'ShowTime=0', '[item-marks]', 'MaxPins=7', 'Leftover=1')
        $tpl = @('# head', '', '# ---- panel behaviour ----', '# about it', 'ShowTime=1', 'CompactMode=0', '', '# ---- plugin: item-marks ----', '[item-marks]', 'MaxPins=50')
        $r = Merge-IniDocTemplate $doc $tpl
        $text = ($r.Lines -join '|')
        Expect ($text.Contains('ShowTime=0')) ('value kept: ' + $text)
        Expect ($text.Contains('CompactMode=0')) ('template line kept: ' + $text)
        Expect ($text.Contains('[item-marks]|MaxPins=7')) ('plugin value kept: ' + $text)
        Expect ($r.Added -eq 1) ('added=' + $r.Added)
        # a key this version does not know survives as a comment, at the end
        Expect ($r.Unknown -eq 1) ('unknown=' + $r.Unknown)
        Expect ($text.Contains('# [unknown] Leftover=1')) ('unknown key kept: ' + $text)
        Expect (($r.Lines[$r.Lines.Count - 1]) -eq '# [unknown] Leftover=1') 'the unknown key is not last'
      }

      It 'the same lines compare equal, trailing whitespace aside' {
        Expect (Test-IniLinesSame @('A=1', 'B=2') @('A=1', 'B=2')) ''
        Expect (Test-IniLinesSame @('A=1  ') @('A=1')) ''
        Expect (-not (Test-IniLinesSame @('A=1') @('A=2'))) ''
        Expect (-not (Test-IniLinesSame @('A=1') @('A=1', 'B=2'))) ''
      }

      It 'Apply-Config picks up the paste timings and the fallback list' {
        [IO.File]::WriteAllLines($script:UnitCfg, @('ModReleaseTimeout=1500', 'PasteSettle=250', 'HotkeyFallbacks=Alt+Q;Alt+W'), $Utf8)
        Apply-Config
        Expect ($script:ModReleaseTimeout -eq 1500) ('value=' + $script:ModReleaseTimeout)
        Expect ($script:PasteSettle -eq 250) ('value=' + $script:PasteSettle)
        Expect ($script:HotkeyFallbacks -eq 'Alt+Q;Alt+W') ('value=' + $script:HotkeyFallbacks)
      }
    }

    # ---- the store: records only, there is no payload-only view any more
    Describe 'store' {
      It 'a capture lands on top and dedupes' {
        Save-Records @()
        Expect (@(Get-Records).Count -eq 0) ''
        Add-Item 'one'; Add-Item 'two'; Add-Item 'three'
        $items = Payloads
        Expect ($items.Count -eq 3 -and $items[0] -eq 'three') ($items -join '|')
        Add-Item 'one'
        $items = Payloads
        Expect ($items.Count -eq 3 -and $items[0] -eq 'one') ($items -join '|')
        Add-Item 'one'
        $items = Payloads
        Expect ($items.Count -eq 3) ($items -join '|')
      }

      It 'the store trims to MaxItems' {
        Save-Records @()
        Add-Item 'one'; Add-Item 'two'; Add-Item 'three'
        $saved = $script:MaxItems
        try {
          $script:MaxItems = 2
          Add-Item 'four'
          $items = Payloads
          Expect ($items.Count -eq 2) ($items -join '|')
        } finally { $script:MaxItems = $saved }
      }

      It 'the store drops what it must not keep' {
        Save-Records @()
        Add-Item 'one'
        $savedBytes = $script:MaxTextBytes
        try {
          $script:MaxTextBytes = 3
          $before = @(Get-Records).Count
          Add-Item 'toolong'
          Expect (@(Get-Records).Count -eq $before) ''
        } finally { $script:MaxTextBytes = $savedBytes }
        $before = @(Get-Records).Count
        $script:ExcludePattern = '^SECRET'
        try {
          Add-Item 'SECRET token'
          Expect (@(Get-Records).Count -eq $before) ''
        } finally { $script:ExcludePattern = '' }
        $before = @(Get-Records).Count
        Add-Item '   '
        Expect (@(Get-Records).Count -eq $before) ''
      }

      It 'a pasted row moves to the top and keeps its sidecar' {
        # Pasting a row is "this one again": it moves to the top instead of staying where it was,
        # and it keeps its marks, its rich sidecar and its blob reference - re-deriving the entry
        # from its text is what used to turn a formatted row into a plain one.
        $richRef = 'H:' + ('a' * 40) + ':100'
        $rich = New-Record 'rich row' ((Get-Epoch) - 300) 'p'
        $rich.Rich = $richRef
        $list = New-Object System.Collections.Generic.List[object]
        $list.Add((New-Record 'plain top' (Get-Epoch) ''))
        $list.Add((New-Record 'middle row' ((Get-Epoch) - 100) ''))
        $list.Add($rich)
        Save-Records $list.ToArray()
        $moved = Touch-Record 'rich row'
        $after = @(Get-Records)
        Expect ($moved -and ([string]$after[0].Payload -ceq 'rich row')) ([string]$after[0].Payload)
        Expect ((([string]$after[0].Marks) -ceq 'p') -and (([string]$after[0].Rich) -ceq $richRef)) ([string]$after[0].Marks + ' / ' + [string]$after[0].Rich)
        Expect (-not (Touch-Record 'rich row')) ''
      }

      It 'a capture appends a line instead of rewriting' {
        # the read side reverses the file and hides the duplicate, so a payload captured twice is
        # one row carrying the newer time and the marks it already had
        Save-Records @()
        Add-Item 'first'; Add-Item 'second'
        $linesAfterTwo = [int]$script:RecLines
        $rawTwo = [IO.File]::ReadAllText($StoreFile)
        Add-Item 'first'
        $linesAfterRepeat = [int]$script:RecLines
        $rawRepeat = [IO.File]::ReadAllText($StoreFile)
        Expect (($linesAfterTwo -eq 2) -and ($linesAfterRepeat -eq 3) -and ($rawRepeat.Length -gt $rawTwo.Length)) ([string]$linesAfterTwo + ' -> ' + [string]$linesAfterRepeat)
        $repeated = @(Get-Records)
        Expect (($repeated.Count -eq 2) -and ([string]$repeated[0].Payload -ceq 'first')) ([string]$repeated.Count + ' / ' + [string]$repeated[0].Payload)
      }

      It 'the append log is folded back at twice MaxItems' {
        # The file may carry rows the history already hides; twice MaxItems is where it is folded
        # back into a clean list, so a long session cannot grow the file without bound.
        Save-Records @()
        $saved = $script:MaxItems
        try {
          $script:MaxItems = 3
          for ($k = 0; $k -lt 6; $k++) { Add-Item ('grow ' + [string]$k) }
        } finally { $script:MaxItems = $saved }
        Expect ([int]$script:RecLines -le 6) ([string]$script:RecLines + ' lines')
        $grown = @(Get-Records)
        Expect (($grown.Count -le 6) -and ($grown.Count -gt 0)) ([string]$grown.Count)
      }
    }

    # ------------------------------------------------------------- record store
    # the schema table the later sections read defaults from
    $sch = $script:IniSchema
    # the clock the store, the blob and the export rows share
    $now = Get-Epoch
    # the two rows the sort-mark rows further down start from
    $recList = New-Object System.Collections.Generic.List[object]
    $recList.Add((New-Record 'alpha' ($now - 60) 'p'))
    $recList.Add((New-Record 'beta' ($now - 30) ''))
    # base owns no mark meaning: a plugin declares it, and the later sections swap in their own
    $markPlugin = @{
      Name       = 'marks'
      Marks      = [ordered]@{
        p = @{ Set = 'pin'; Unset = 'unpin'; Word = 'pinned'; Hint = 'Ctrl+P'; Protected = $false }
        s = @{ Set = 'star'; Unset = 'unstar'; Word = 'starred'; Hint = 'Ctrl+S'; Protected = $true }
      }
      SortMark   = 'p'
      ClearKeeps = @('p')
    }

    Describe 'records' {
      It 'the store starts with the tag and its layout version' {
        $rawHead = [IO.File]::ReadAllText($StoreFile)
        Expect ($rawHead.StartsWith($TAG + $RS + [string]$script:DataVersion)) ($rawHead.Substring(0, [Math]::Min(9, $rawHead.Length)) -replace [string][char]30, '<RS>')
      }

      Describe 'generic marks' {
        BeforeAll { $script:Plugins = @($markPlugin) }

        It 'the declaration provides names, words and protection' {
          Expect ((@(Get-MarkNames) -join ',') -eq 'p,s') (@(Get-MarkNames) -join ',')
          Expect ((Get-MarkWord 's') -eq 'starred') (Get-MarkWord 's')
          Expect ((Get-MarkWord 'z') -eq 'z') (Get-MarkWord 'z')
          Expect ((@(Get-ProtectedMarks) -join ',') -eq 's') (@(Get-ProtectedMarks) -join ',')
        }

        It 'a mark change appends a line and floats the row' {
          # The row comes back with the same payload and time and its new marks, so pinning
          # costs one line instead of a rewrite of the whole history. It does not keep its
          # slot: the sort mark floats it to the top, which is the run the panel freezes. A
          # write that left it where it was made the pin invisible until the next full parse.
          Save-Records @()
          Add-Item 'm-one'; Add-Item 'm-two'; Add-Item 'm-three'
          $linesBeforePin = [int]$script:RecLines
          [void](Set-Mark 'm-two' 'p' $true)
          $linesAfterPin = [int]$script:RecLines
          $afterPin = @(Get-Records)
          $afterPinText = ($afterPin | ForEach-Object { [string]$_.Payload }) -join ','
          Expect ($linesAfterPin -eq ($linesBeforePin + 1)) ([string]$linesBeforePin + ' -> ' + [string]$linesAfterPin)
          Expect ($afterPinText -ceq 'm-two,m-three,m-one') ($afterPinText + ' vs m-two,m-three,m-one')
          $markedRow = @($afterPin | Where-Object { [string]$_.Payload -ceq 'm-two' })
          Expect (($markedRow.Count -eq 1) -and (Test-Mark $markedRow[0] 'p')) ''
          # the older line holds a copy of the row, so the two must not become two rows
          Expect ($afterPin.Count -eq 3) ([string]$afterPin.Count)
        }

        It 'a delete appends a tombstone' {
          # one line naming the payload, and the read side drops every line for it, so the row
          # goes without the file being rewritten
          $linesBeforeDel = [int]$script:RecLines
          $delResult = Remove-Record 'm-two'
          $rowsAfterDel = @(Get-Records)
          $delText = ($rowsAfterDel | ForEach-Object { [string]$_.Payload }) -join ','
          Expect (($delResult -eq 'removed') -and ([int]$script:RecLines -eq ($linesBeforeDel + 1)) -and ([int]$script:RecGone -ge 1)) ([string]$delResult + ' lines=' + [string]$script:RecLines + ' gone=' + [string]$script:RecGone)
          Expect (-not ($delText.Contains('m-two'))) $delText
          # a payload captured twice and then deleted must not come back through its older line
          Add-Item 'dup'; Add-Item 'dup'
          [void](Remove-Record 'dup')
          $dupRows = @(Get-Records | Where-Object { [string]$_.Payload -ceq 'dup' })
          Expect ($dupRows.Count -eq 0) ([string]$dupRows.Count)
        }

        It 'folding drops the tombstones and the stale lines' {
          $saved = $script:MaxItems
          try {
            $script:MaxItems = 4
            for ($k = 0; $k -lt 10; $k++) { Add-Item ('fold ' + [string]$k) }
          } finally { $script:MaxItems = $saved }
          $rawFolded = [IO.File]::ReadAllText($StoreFile)
          Expect ((-not ($rawFolded.Contains($RS + 'x'))) -and ([int]$script:RecGone -eq 0)) ([string]$script:RecGone + ' gone, ' + [string]$script:RecLines + ' lines')
        }

        It 'the sort and clear marks come from the declaration' {
          Expect ((Get-SortMark) -eq 'p') (Get-SortMark)
          Expect ((@(Get-ClearKeepMarks) -join ',') -eq 'p,s') (@(Get-ClearKeepMarks) -join ',')
          Expect ((@(Get-ClearKeepMarks -All) -join ',') -eq 's') (@(Get-ClearKeepMarks -All) -join ',')
        }
      }

      It 'a record roundtrips payload, time and marks' {
        $list = New-Object System.Collections.Generic.List[object]
        $list.Add((New-Record 'alpha' ($now - 60) 'p'))
        $list.Add((New-Record 'beta' ($now - 30) ''))
        Save-Records $list.ToArray()
        $r2 = @(Get-Records)
        Expect (((Payloads) -join '|') -eq 'alpha|beta') ((Payloads) -join '|')
        Expect (($r2[0].Time -eq ($now - 60)) -and ($r2[1].Time -eq ($now - 30))) ($r2[0].Time -as [string])
        Expect ((Test-Mark $r2[0] 'p') -and (-not (Test-Mark $r2[1] 'p'))) ''
        # a mark the base never heard of is carried, not filtered away
        Expect ((Test-Mark (New-Record 'x' 0 'zq') 'z') -and (Test-Mark (New-Record 'x' 0 'zq') 'q')) ''
      }

      It 'a big payload lives in its own file' {
        # the history keeps a reference, so the rewrite a capture costs stays small, and the
        # record still comes back whole
        $bigText = ('big line ' + [Environment]::NewLine) * 5000
        $list = New-Object System.Collections.Generic.List[object]
        $list.Add((New-Record $bigText $now 'p'))
        $list.Add((New-Record 'small tail' $now ''))
        Save-Records $list.ToArray()
        $rawStore = [IO.File]::ReadAllText($StoreFile, $Utf8)
        $blobFiles = @(Get-ChildItem -LiteralPath (Get-BlobDir) -Filter '*.txt' -ErrorAction SilentlyContinue)
        Expect ((-not $rawStore.Contains('big line')) -and $blobFiles.Count -eq 1) ([string]$blobFiles.Count + ' blob(s), store ' + $rawStore.Length + ' chars')
        $back = @(Get-Records)
        Expect (($back.Count -eq 2) -and ($back[0].Payload -ceq $bigText) -and [string]$back[0].Blob) ([string]$back[0].Payload.Length)
        Save-Records @($back[1])
        $leftBlobs = @(Get-ChildItem -LiteralPath (Get-BlobDir) -Filter '*.txt' -ErrorAction SilentlyContinue)
        Expect ($leftBlobs.Count -eq 0) ([string]$leftBlobs.Count + ' left')
      }

      It 'BlobChars decides what leaves the file' {
        $saved = $script:BlobChars
        try {
          $script:BlobChars = 100
          $list = New-Object System.Collections.Generic.List[object]
          $list.Add((New-Record ('z' * 400) $now ''))
          Save-Records $list.ToArray()
          $inlineRaw = [IO.File]::ReadAllText($StoreFile, $Utf8)
          $inlineBlobs = @(Get-ChildItem -LiteralPath (Get-BlobDir) -Filter '*.txt' -ErrorAction SilentlyContinue)
          Expect ((-not $inlineRaw.Contains('zzzz')) -and $inlineBlobs.Count -eq 1) ([string]$inlineBlobs.Count + ' blob(s)')
        } finally { $script:BlobChars = $saved }
      }

      It 'preview, blob and media settings carry the shipped defaults' {
        Expect (($sch['PreviewHover'].Default -eq 1) -and ($sch['PreviewDelay'].Default -eq 350) -and ($sch['PreviewChars'].Default -eq 6000) -and ($sch['BlobChars'].Default -eq 32768)) ''
        Expect (($sch['CaptureImages'].Default -eq 1) -and ($sch['MaxImageBytes'].Default -eq 16777216) -and ($sch['CaptureRich'].Default -eq 1) -and ($sch['MaxHtmlBytes'].Default -eq 20971520) -and ($sch['MaxRtfBytes'].Default -eq 20971520) -and ($sch['RtfImagesUpToBytes'].Default -eq 8388608) -and ($sch['InlineImageUpToBytes'].Default -eq 4194304) -and ($sch['PasteRich'].Default -eq 1) -and ($sch['MaxMediaTotalBytes'].Default -eq 134217728)) ''
      }
    }

    # ------------------------------------------------------- export and import
    Describe 'export and import' {
      It 'a json and a csv export read back' {
        # the shapes first: a document this build writes has to be one it reads
        $xRows = @(
          @{ Text = 'one'; Time = 100; Marks = ''; Media = $null },
          @{ Text = ('two' + [Environment]::NewLine + 'lines'); Time = 200; Marks = 'p'; Media = $null }
        )
        $backDoc = ConvertFrom-TransferJson (ConvertTo-TransferJson $xRows)
        Expect (($null -ne $backDoc) -and (@($backDoc.Rows).Count -eq 2) -and (@($backDoc.Rows)[1].Marks -eq 'p')) ''
        Expect ((@($backDoc.Rows)[1].Text) -like ('two' + [Environment]::NewLine + 'lines')) (@($backDoc.Rows)[1].Text)
        Expect ($null -eq (ConvertFrom-TransferJson '{"format":"something-else"}')) ''
        $csvBack = ConvertFrom-TransferCsv (ConvertTo-TransferCsv $xRows)
        Expect (($null -ne $csvBack) -and (@($csvBack.Rows).Count -eq 2) -and ((@($csvBack.Rows)[1].Text) -like 'two*')) ''
        Expect ($null -eq (ConvertFrom-TransferCsv "a,b`r`n1,2")) ''
      }

      It 'an export survives a round trip through the store' {
        Save-Records @((New-Record 'export me' $now ''), (New-Record 'and me' ($now - 10) 's'))
        $xfile = Join-Path $unitDir 'history-export.json'
        $ex = Invoke-Export $xfile
        Expect (($ex.Ok) -and (Test-Path -LiteralPath $xfile)) $ex.Message
        Save-Records @()
        $im = Invoke-Import $xfile
        Expect (($im.Ok) -and (@(Get-Records).Count -eq 2)) $im.Message
        Expect (@(Get-Records | Where-Object { Test-Mark $_ 's' }).Count -eq 1) ''
        # a second import adds nothing
        $im2 = Invoke-Import $xfile
        Expect ((@(Get-Records).Count -eq 2) -and ($im2.Kept -eq 2)) $im2.Message
        Expect (-not (Invoke-Import (Join-Path $unitDir 'nope.json')).Ok) ''
      }

      It 'a snapshot is a zip the store restores from' {
        # a snapshot is a zip of the data folder, so pictures travel with the history
        Save-Records @((New-Record 'export me' $now ''), (New-Record 'and me' ($now - 10) 's'))
        $bk = Save-Snapshot 'unit'
        Expect (($bk.Ok) -and ($bk.Path -like '*.zip')) $bk.Path
        $bkName = [IO.Path]::GetFileNameWithoutExtension($bk.Path)
        Save-Records @()
        # not $rs: that is case-insensitively the same variable as the store's record separator
        $restored = Invoke-Restore $bkName
        Expect (($restored.Ok) -and (@(Get-Records).Count -eq 2)) $restored.Message
        Save-Records @()
      }
    }

    # ------------------------------------------------------- per program paste rules
    Describe 'paste rules' {
      It 'a rule list parses into program keys and actions' {
        # the text form first: separated by ';' or ',', names lowercased, '.exe' filled in
        $ruleMap = ConvertFrom-AppRuleText 'WindowsTerminal:plain, Code.EXE:rich; *:no-paste'
        Expect (($ruleMap.Contains('windowsterminal.exe')) -and ($ruleMap.Contains('code.exe')) -and ($ruleMap.Contains('*'))) ([string]$ruleMap.Count + ' rule(s)')
        Expect (($ruleMap['windowsterminal.exe'] -eq 'plain') -and ($ruleMap['*'] -eq 'no-paste')) $ruleMap['windowsterminal.exe']
        Expect ((ConvertFrom-AppRuleText '').Count -eq 0) ''
      }

      It 'a rule list is checked before it is stored' {
        $okRule = Test-AppRuleText 'notepad:plain;*:no-paste'
        Expect (($okRule.Ok) -and ($okRule.Value -eq 'notepad.exe:plain;*:no-paste')) $okRule.Value
        Expect (-not (Test-AppRuleText 'notepad:cursive').Ok) (Test-AppRuleText 'notepad:cursive').Error
        Expect (-not (Test-AppRuleText 'notepad').Ok) ''
        Expect (-not (Test-AppRuleText '..\evil:plain').Ok) ''
      }

      It 'the lookup prefers an exact name over the fallback' {
        $saved = $script:AppRules
        try {
          $script:AppRules = 'windowsterminal.exe:plain;*:no-paste'
          Expect ((Get-AppRuleAction 'windowsterminal') -eq 'plain') (Get-AppRuleAction 'windowsterminal')
          Expect ((Get-AppRuleAction 'notepad') -eq 'no-paste') (Get-AppRuleAction 'notepad')
          $script:AppRules = 'windowsterminal.exe:plain'
          Expect ((Get-AppRuleAction 'notepad') -eq '') ''
          $script:AppRules = ''
          Expect ((Get-AppRuleAction 'notepad') -eq '') ''
        } finally { $script:AppRules = $saved }
      }

      It 'the rule setting carries a default' {
        Expect ($null -ne $sch['AppRules'] -and $sch['AppRules'].Default -eq '') ''
      }
    }

    # ------------------------------------------------------- editing an entry
    Describe 'editing an entry' {
      It 'an edit replaces the text and keeps the rest' {
        Save-Records @((New-Record 'typo herr' $now 'p'), (New-Record 'other text' ($now - 5) ''))
        $beforeEdit = @(Get-Records)
        $editKey = [int]$beforeEdit[0].Key
        $editRes = Update-RecordText 'typo herr' 'typo here'
        $afterEdit = @(Get-Records)
        Expect (($editRes.Ok) -and ($afterEdit[0].Payload -eq 'typo here')) ([string]$editRes.Error)
        Expect (($afterEdit.Count -eq 2) -and ($afterEdit[0].Time -eq $now) -and ($afterEdit[0].Marks -eq 'p')) ''
        # the caches redraw from the key, so an edit has to bump it
        Expect ($afterEdit[0].Key -ne $editKey) ([string]$afterEdit[0].Key)
        Expect ((Update-RecordText 'typo here' 'typo here').Ok) ''
      }

      It 'an edit that cannot apply is refused' {
        Save-Records @((New-Record 'typo herr' $now 'p'), (New-Record 'other text' ($now - 5) ''))
        Expect (-not (Update-RecordText 'typo herr' 'other text').Ok) ''
        Expect (-not (Update-RecordText 'typo herr' '   ').Ok) ''
        Expect (-not (Update-RecordText 'not here' 'x').Ok) ''
        Save-Records @()
      }
    }

    # ------------------------------------------------------- images and rich text
    # The fixtures the whole section shares: one 1x1 PNG and the records, references and media
    # files built from it. Later sections read them as well, so they are made once here.
    # 1x1 transparent PNG: the bytes are what makes the identity, so any picture works
    $png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')
    $p1 = New-ImagePayload $png 1 1 'PNG'
    $iref = Get-ImageRef $p1
    [void](Write-ImageMedia $p1 $png)
    $imgRec = New-Record $p1 $now ''
    $richRtf = '{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Segoe UI;}}\f0\fs24\b bold title\b0\par second line\par third line\par}'
    $richCap = @{ Html = $Utf8.GetBytes('<html><body><p>hi</p></body></html>'); Rtf = $richRtf }
    $rref = New-RichRef $richCap
    [void](Write-RichMedia $rref $richCap)
    $richRec = New-Record 'hi there' $now ''
    $richRec.Rich = $rref

    Describe 'image payloads' {
      It 'a payload is derived from its bytes' {
        $p2 = New-ImagePayload $png 1 1 'PNG'
        Expect ($p1.Length -gt 0 -and $p1[0] -eq [char]3 -and $p1 -ceq $p2) $p1
        Expect (($null -ne $iref) -and $iref.W -eq 1 -and $iref.H -eq 1 -and $iref.Bytes -eq $png.Length -and $iref.Sha1.Length -eq 40) ''
        Expect (-not (Test-ImagePayload 'hello')) ''
      }

      It 'an image row says what it is' {
        Expect ((Get-ItemLabel $p1 $true) -like '[[]image] 1x1*PNG*') (Get-ItemLabel $p1 $true)
        Expect ((Get-EntryKind $p1) -eq 'image') (Get-EntryKind $p1)
        Expect (((Format-Size 512) -eq '512 B') -and ((Format-Size 2048) -eq '2 KB') -and ((Format-Size 2411724) -eq '2.3 MB')) (Format-Size 2411724)
      }

      It 'a picture is stored once in the media folder' {
        Expect (Test-Path -LiteralPath (Get-MediaPath $iref.Sha1 'png')) ''
        [void](Write-ImageMedia $p1 $png)
        $pngFiles = @(Get-ChildItem -LiteralPath (Get-MediaDir) -Filter '*.png')
        Expect ($pngFiles.Count -eq 1) ([string]$pngFiles.Count)
        Expect ((Get-RecordMediaBytes $imgRec) -eq $png.Length) ([string](Get-RecordMediaBytes $imgRec))
      }

      It 'a picture row gets a thumbnail drawn into the icon slot' {
        $thumb = Get-RowThumbBitmap $imgRec 28
        Expect (($null -ne $thumb) -and ($thumb.Width -le 28) -and ($thumb.Height -le 28)) ''
        Expect ([object]::ReferenceEquals($thumb, (Get-RowThumbBitmap $imgRec 28))) ''
        Expect ($null -eq (Get-RowThumbBitmap (New-Record 'plain text' 1 '') 28)) ''
        $canvas = New-Object Drawing.Bitmap 28, 28
        $gfx = [Drawing.Graphics]::FromImage($canvas)
        try {
          Expect ((Draw-RowThumb $gfx $null 0 0 28) -eq $false) ''
          Expect (Draw-RowThumb $gfx $thumb 0 0 28) ''
        } finally {
          $gfx.Dispose()
          $canvas.Dispose()
        }
      }
    }

    Describe 'rich references' {
      It 'a reference is stable and parses back' {
        Expect (($rref -ceq (New-RichRef $richCap)) -and $rref.StartsWith('H:')) $rref
        $rr = Get-RichRef $rref
        Expect (($null -ne $rr) -and $rr.Bytes -gt 0) $rref
        Expect (((Read-RichRtf $rref) -eq $richRtf) -and ((Read-RichHtml $rref).Length -eq $richCap.Html.Length)) ''
      }

      It 'rtf keeps its high bytes' {
        # RTF is an 8-bit format: it is stored as bytes, so high bytes (and any style table
        # byte) survive instead of going through a UTF-8 decode
        $rtfHigh = New-Object byte[] 5
        $rtfHigh[0] = 0x7B; $rtfHigh[1] = 0x80; $rtfHigh[2] = 0xFF; $rtfHigh[3] = 0x5C; $rtfHigh[4] = 0x7D
        $highRef = New-RichRef @{ Html = $null; Rtf = $rtfHigh }
        [void](Write-RichMedia $highRef @{ Html = $null; Rtf = $rtfHigh })
        $highBack = Read-RichRtfBytes $highRef
        Expect (($highBack.Length -eq 5) -and ($highBack[1] -eq 0x80) -and ($highBack[2] -eq 0xFF)) ([string]$highBack.Length + ' bytes')
      }

      It 'a formatted page paints into the card and is reused' {
        # the card draws the document into a bitmap: an empty one would mean the layout never ran
        $renderFont = New-Object Drawing.Font 'Segoe UI', 10.5
        $richBmp = Get-RichPreviewBitmap $rref 380 200 $renderFont ([Drawing.Color]::White)
        $richInk = 0
        if ($null -ne $richBmp) { $richInk = Get-InkBottom $richBmp ([Drawing.Color]::White) }
        Expect (($null -ne $richBmp) -and ($richBmp.Width -eq 380) -and ($richInk -gt 20) -and ($richInk -le 200)) ([string]$richInk + ' px of ink')
        Expect ([object]::ReferenceEquals($richBmp, (Get-RichPreviewBitmap $rref 380 200 $renderFont ([Drawing.Color]::White)))) ''
      }

      It 'a formatted row says so' {
        Clear-MediaCache
        Expect ((Get-RecordLabel $richRec $true) -eq '[rich] hi there') (Get-RecordLabel $richRec $true)
      }
    }

    Describe 'preview content' {
      It 'the card knows all three kinds' {
        $pcImg = Get-PreviewContent $imgRec 40 6
        Expect ($pcImg.Kind -eq 'image' -and $pcImg.Ref -and ($pcImg.Head -like 'image - 1x1*')) ([string]$pcImg.Kind + ' / ' + [string]$pcImg.Head)
        $pcRich = Get-PreviewContent $richRec 40 6
        Expect ($pcRich.Kind -eq 'rich' -and ($pcRich.Head -like 'formatted -*') -and $pcRich.Lines.Count -gt 0) ([string]$pcRich.Head)
        $pcText = Get-PreviewContent (New-Record 'plain body' $now '') 40 6
        Expect ($pcText.Kind -eq 'text' -and $pcText.Lines.Count -eq 1) ([string]$pcText.Kind)
      }
    }

    Describe 'cf_html' {
      It 'the offsets select the fragment' {
        # CF_HTML keeps byte offsets into its own buffer: the fragment has to come out exactly
        $fragText = '<p>inside</p>'
        $fragBytes = [Text.Encoding]::UTF8.GetBytes($fragText)
        $stub = 'Version:0.9' + "`r`n" + 'StartHTML:0000000000' + "`r`n" + 'EndHTML:0000000000' + "`r`n" + 'StartFragment:0000000000' + "`r`n" + 'EndFragment:0000000000' + "`r`n"
        $fragAt = $Utf8.GetByteCount($stub)
        $fragEnd = $fragAt + $fragBytes.Length
        $cfHtml = 'Version:0.9' + "`r`n" + ('StartHTML:' + ([string]$fragAt).PadLeft(10, [char]48)) + "`r`n" + ('EndHTML:' + ([string]$fragEnd).PadLeft(10, [char]48)) + "`r`n" + ('StartFragment:' + ([string]$fragAt).PadLeft(10, [char]48)) + "`r`n" + ('EndFragment:' + ([string]$fragEnd).PadLeft(10, [char]48)) + "`r`n" + $fragText
        Expect ((Get-HtmlText ($Utf8.GetBytes($cfHtml))) -eq 'inside') (Get-HtmlText ($Utf8.GetBytes($cfHtml)))
      }

      It 'html is read as words when there is no rtf' {
        Expect ((Get-HtmlText ($Utf8.GetBytes('<p>a &amp; b</p><p>c</p>'))) -eq ("a & b`nc")) (Get-HtmlText ($Utf8.GetBytes('<p>a &amp; b</p><p>c</p>')))
      }
    }

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

    # the block fixtures this section and the paste rows share
    $dibPixels = New-DibFixture 2 2
    $blockCap = @{ Html = $richCap.Html; Rtf = $richCap.Rtf; Blocks = @(@{ Tag = 'D'; Data = $dibPixels }) }
    $bRef = New-RichRef $blockCap
    [void](Write-RichMedia $bRef $blockCap)
    $blockRec = New-Record 'with a picture' $now ''
    $blockRec.Rich = $bRef

    Describe 'rich blocks' {
      It 'a reference names every block' {
        $bParsed = Get-RichRef $bRef
        Expect (($null -ne $bParsed) -and ($bParsed.Blocks.Count -eq 3) -and ($bParsed.Blocks[2].Tag -eq 'D')) ([string]$bRef)
        Expect ((Read-RichBlock $bRef 'D').Length -eq $dibPixels.Length) ''
        Expect ($bParsed.Bytes -eq ($richCap.Html.Length + $Utf8.GetByteCount($richRtf) + $dibPixels.Length)) ([string]$bParsed.Bytes)
        Expect ($null -eq (Get-RichRef 'R:0123456789012345678901234567890123456789:120')) ''
        Expect ($null -eq (Get-RichRef 'X:0123456789012345678901234567890123456789:1')) ''
      }

      It 'a dib block decodes and the card falls back to it' {
        $dibBitmap = ConvertFrom-MediaBytes $dibPixels 'D'
        try {
          Expect (($null -ne $dibBitmap) -and ($dibBitmap.Width -eq 2) -and ($dibBitmap.Height -eq 2)) ''
        } finally { if ($null -ne $dibBitmap) { $dibBitmap.Dispose() } }
        $picBmp = Get-RichImageBitmap $bRef 120 120
        Expect (($null -ne $picBmp) -and ($picBmp.Width -le 120)) ''
        Clear-MediaCache
      }
    }

    Describe 'cf_html inlining' {
      It 'a temp picture is inlined as a data uri' {
        # html that points at a temp picture: the file is read once and inlined as a data uri,
        # then the four offsets are recomputed for the longer buffer
        $tmpPic = Join-Path $tmpRoot 'inline-fixture.png'
        [IO.File]::WriteAllBytes($tmpPic, $png)
        try {
          $picUrl = 'file:///' + ($tmpPic -replace '\\', '/')
          $inHtml = New-CfHtmlFixture ('<p>pic</p><img src="' + $picUrl + '">')
          $inlined = Get-CfHtmlInlined ($Utf8.GetBytes($inHtml)) 2097152 0
          $inText = $Utf8.GetString($inlined)
          Expect (($inText -match 'src="data:image/png;base64,') -and ($inText.Length -gt $inHtml.Length)) ''
          Expect ((Get-HtmlText $inlined) -eq 'pic') (Get-HtmlText $inlined)
        } finally { Remove-Item -LiteralPath $tmpPic -Force -ErrorAction SilentlyContinue }
      }

      It 'a picture over the cap or inlining off is left alone' {
        $tmpPic = Join-Path $tmpRoot 'inline-fixture.png'
        [IO.File]::WriteAllBytes($tmpPic, $png)
        try {
          $picUrl = 'file:///' + ($tmpPic -replace '\\', '/')
          $inHtml = New-CfHtmlFixture ('<p>pic</p><img src="' + $picUrl + '">')
          $kept = Get-CfHtmlInlined ($Utf8.GetBytes($inHtml)) 1 0
          Expect (([BitConverter]::ToString($kept)) -eq ([BitConverter]::ToString($Utf8.GetBytes($inHtml)))) ''
          $noInline = Get-CfHtmlInlined ($Utf8.GetBytes($inHtml)) 0 0
          Expect (([BitConverter]::ToString($noInline)) -eq ([BitConverter]::ToString($Utf8.GetBytes($inHtml)))) ''
        } finally { Remove-Item -LiteralPath $tmpPic -Force -ErrorAction SilentlyContinue }
      }

      It 'a vml picture is inlined too' {
        # Word writes an <img> fallback and a VML <v:imagedata src="file:...">. The inliner
        # rewrites every src that names a file, not just the <img> ones, so the VML path
        # survives the temp folder being deleted as well - a shape is what Word draws from.
        $tmpPic = Join-Path $tmpRoot 'inline-fixture.png'
        [IO.File]::WriteAllBytes($tmpPic, $png)
        try {
          $picUrl = 'file:///' + ($tmpPic -replace '\\', '/')
          $vmlHtml = New-CfHtmlFixture ('<p>vml</p><v:shape><v:imagedata src="' + $picUrl + '"/></v:shape>')
          $vmlInlined = $Utf8.GetString((Get-CfHtmlInlined ($Utf8.GetBytes($vmlHtml)) 2097152 0))
          Expect (($vmlInlined -notmatch 'file:') -and ($vmlInlined -match 'v:imagedata src="data:image/png;base64,')) ''
        } finally { Remove-Item -LiteralPath $tmpPic -Force -ErrorAction SilentlyContinue }
      }
    }

    Describe 'cf_html from a string' {
      It 'a padded read is cut back, a damaged one is dropped' {
        # A block the clipboard wrapper hands over as a string (the fallback when the raw read
        # could not open the clipboard) still carries the allocator padding and, when the ANSI
        # decode ate a character, one byte less than EndHTML. The first is cut back, the second
        # is dropped: a fragment whose tags lost a '<' is worse than no formatting at all.
        $fbText = New-CfHtmlFixture '<p>fallback</p>'
        $fbBytes = $Utf8.GetBytes($fbText)
        $fbPadded = Get-CfHtmlFromString ($fbText + ('?' * 12))
        Expect (($null -ne $fbPadded) -and ([BitConverter]::ToString([byte[]]$fbPadded) -eq [BitConverter]::ToString($fbBytes))) ([string]$fbPadded.Length)
        Expect ($null -eq (Get-CfHtmlFromString ($fbText.Substring(0, $fbText.Length - 1)))) ''
        Expect ($null -eq (Get-CfHtmlFromString ($fbText.Insert(20, ([string][char]0xFFFD))))) ''
        Expect ($null -eq (Get-CfHtmlFromString '')) ''
        $fbNoHead = Get-CfHtmlFromString ('<p>no header</p>' + ([string][char]0) + ([string][char]0))
        Expect (($null -ne $fbNoHead) -and ([Text.Encoding]::ASCII.GetString([byte[]]$fbNoHead) -eq '<p>no header</p>')) ''
      }

      It 'an rtf block is written as bytes' {
        # the bytes of a formatted block have to stay bytes end to end: an Object[] from the
        # pipeline used to be stringified into "123 92 114 ..." and written as that text
        $rtfPic = '{\rtf1\ansi{\fonttbl{\f0 Arial;}}\f0 hello {\pict\pngblip\picw2\pich2 89504e47}world}'
        $rtfBytes = $Utf8.GetBytes($rtfPic)
        $cutRef = New-RichRef @{ Html = $null; Rtf = $rtfBytes; Blocks = @() }
        [void](Write-RichMedia $cutRef @{ Html = $null; Rtf = $rtfBytes; Blocks = @() })
        $cutSha = (@((Get-RichRef $cutRef).Blocks))[0].Sha1
        $cutBack = [IO.File]::ReadAllBytes((Get-MediaPath $cutSha 'rtf'))
        Expect (([BitConverter]::ToString($cutBack)) -eq ([BitConverter]::ToString($rtfBytes))) ''
      }
    }

    # store round trip: the extra field carries the reference, the bytes stay out of the file
    Describe 'records with media' {
      It 'an image, a rich reference and a block reference survive a save' {
        $mixList = New-Object System.Collections.Generic.List[object]
        $mixList.Add($imgRec)
        $mixList.Add($richRec)
        $mixList.Add($blockRec)
        $mixList.Add((New-Record 'plain' $now ''))
        Save-Records $mixList.ToArray()
        $mixBack = @(Get-Records)
        Expect (($mixBack.Count -eq 4) -and ([string]$mixBack[0].Payload -ceq $p1)) ([string]$mixBack.Count)
        Expect ([string]$mixBack[1].Rich -ceq $rref) ([string]$mixBack[1].Rich)
        Expect ([string]$mixBack[2].Rich -ceq $bRef) ([string]$mixBack[2].Rich)
        Expect ((Test-Path -LiteralPath (Get-MediaPath (Get-RichPictureBlock $bRef).Sha1 'dib'))) ''
        Expect (-not [string]$mixBack[3].Rich) ([string]$mixBack[3].Rich)
        $rawStore = [IO.File]::ReadAllText($StoreFile)
        Expect ($rawStore.Contains($RS + 'i')) ''
        Expect (-not $rawStore.Contains('PNG' + [string][char]1)) ''
      }
    }

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
    Describe 'the clipboard round trip' {
      It 'an image goes back to the clipboard as the same picture' {
        $capBack = Get-ClipBack $p1
        Expect (($null -ne $capBack) -and ($null -ne $capBack.Image)) ''
        $sameImage = ($null -ne $capBack) -and ($null -ne $capBack.Image) -and ((New-ImagePayload $capBack.Image.Png $capBack.Image.W $capBack.Image.H $capBack.Image.Fmt) -ceq $p1)
        Expect $sameImage ''
      }

      It 'formatted text keeps its formats on the clipboard' {
        $capRich = Get-ClipBack 'hi there' $rref
        Expect (($null -ne $capRich) -and [string]$capRich.Text -eq 'hi there') ''
        $htmlSame = ($null -ne $capRich) -and ($null -ne $capRich.Rich.Html) -and ([BitConverter]::ToString($capRich.Rich.Html) -eq [BitConverter]::ToString($richCap.Html))
        Expect $htmlSame ''
        $rtfSame = ($null -ne $capRich) -and ($null -ne $capRich.Rich.Rtf) -and ([Text.Encoding]::Default.GetString($capRich.Rich.Rtf) -ceq $richRtf)
        Expect $rtfSame ''
        # the same block as raw bytes through the OLE data object: that is the path the capture
        # takes when another window holds the clipboard and the open above is refused
        $oleHtml = $null
        try { $oleHtml = [Cb.Win]::ReadFormatBytes('HTML Format') } catch { $oleHtml = $null }
        $oleSame = ($null -ne $oleHtml) -and ([BitConverter]::ToString([byte[]]$oleHtml) -eq [BitConverter]::ToString($richCap.Html))
        Expect $oleSame ([string]$(if ($null -eq $oleHtml) { 'null' } else { $oleHtml.Length }))
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
        Expect $opened ''
      }

      It 'utf-8 html keeps its bytes on the clipboard' {
        # A UTF-8 CF_HTML block that goes through a .NET string is decoded with the ANSI code
        # page and stored re-encoded, which is what made Word and Excel paste mojibake. The
        # bytes the clipboard hands over have to come back unchanged.
        $cnChar = [char]0x4E2D
        $cnHtml = $Utf8.GetBytes('<html><body><p>' + $cnChar + '</p></body></html>')
        $cnRef = New-RichRef @{ Html = $cnHtml; Rtf = $null }
        [void](Write-RichMedia $cnRef @{ Html = $cnHtml; Rtf = $null })
        $cnBack = Get-ClipBack ([string]$cnChar) $cnRef
        $cnHtmlBack = $null
        if ($null -ne $cnBack -and $null -ne $cnBack.Rich) { $cnHtmlBack = $cnBack.Rich.Html }
        $cnSame = ($null -ne $cnHtmlBack) -and ([BitConverter]::ToString($cnHtmlBack) -eq [BitConverter]::ToString($cnHtml))
        Expect $cnSame ''
        Expect (($null -ne $cnHtmlBack) -and ((Get-HtmlText $cnHtmlBack) -eq [string]$cnChar)) ([string]$cnChar)
      }

      It 'the picture blocks travel with the text' {
        # a target that prefers a bitmap over html (a chart, a shape, PowerPoint) still gets one
        $fmtBack = Get-RichBack 'hi there' $bRef
        $bd = $null
        $bh = $null
        if ($null -ne $fmtBack) { $bd = $fmtBack.Dib; $bh = $fmtBack.Html }
        Expect (($null -ne $bd) -and ([BitConverter]::ToString($bd) -eq [BitConverter]::ToString($dibPixels))) ([string]$(if ($null -ne $bd) { $bd.Length } else { -1 }) + ' vs ' + [string]$dibPixels.Length)
        Expect (($null -ne $bh) -and ($bh.Length -eq $richCap.Html.Length)) ''
      }
    }

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
    Describe 'the pasted html names files' {
      It 'a data uri becomes a file reference with the same bytes' {
        $b64 = [Convert]::ToBase64String($png)
        $dataFrag = '<html><body><!--StartFragment--><p>a <img src="data:image/png;base64,' + $b64 + '"> b</p><!--EndFragment--></body></html>'
        $onDisk = Get-CfHtmlOnDisk (New-CfHtmlSample $dataFrag)
        $onDiskText = $Utf8.GetString($onDisk)
        Expect ((-not ($onDiskText -match 'data:image')) -and ($onDiskText -match 'src="file:')) ([regex]::Match($onDiskText, 'src="(.{0,30})').Groups[1].Value)
        $imgUrl = [regex]::Match($onDiskText, 'src="(file:[^"]+)"')
        $imgPath = ''
        if ($imgUrl.Success) { try { $imgPath = ([uri]$imgUrl.Groups[1].Value).LocalPath } catch { $imgPath = '' } }
        $sameFile = $false
        if ($imgPath -and (Test-Path -LiteralPath $imgPath)) {
          $sameFile = ([BitConverter]::ToString([IO.File]::ReadAllBytes($imgPath)) -eq [BitConverter]::ToString($png))
        }
        Expect $sameFile $imgPath
        $pasteHead = [int](Get-CfHtmlHeadLength $onDiskText)
        Expect (($pasteHead -gt 0) -and ($onDiskText.Substring($pasteHead, 5) -eq '<html')) ([string]$pasteHead)
      }

      It 'html without pictures is left alone' {
        $plainBytes = New-CfHtmlSample '<html><body><!--StartFragment--><p>plain</p><!--EndFragment--></body></html>'
        Expect (([BitConverter]::ToString((Get-CfHtmlOnDisk $plainBytes))) -eq ([BitConverter]::ToString($plainBytes))) ''
      }

      It 'a picture that is gone becomes a placeholder' {
        # a picture the entry could not keep: the html still names the temp file, and that file
        # is gone by paste time. Every such tag becomes a dashed frame of the same footprint, so
        # a reader sees that a picture belonged there instead of an empty frame.
        $goneUrl = 'file:///' + ((Join-Path $tmpRoot 'gone-picture.png') -replace '\\', '/')
        $goneFrag = '<html><body><!--StartFragment--><p>before <img src="' + $goneUrl + '" width="240" height="180"> after</p><!--EndFragment--></body></html>'
        $goneText = $Utf8.GetString((Get-CfHtmlOnDisk (New-CfHtmlSample $goneFrag)))
        Expect ((-not ($goneText -match '<img')) -and ($goneText -match 'image not saved') -and ($goneText -match 'width:240px')) ([regex]::Match($goneText, 'width:\d+px').Value)
        $goneAt = [int](Get-CfHtmlHeadLength $goneText)
        Expect (($goneAt -gt 0) -and ($goneText.Substring($goneAt, 5) -eq '<html')) ([string]$goneAt)
      }

      It 'a picture whose file survives is copied out' {
        # so the target keeps a readable file even after the source deletes its temp folder
        $livePath = Join-Path $tmpRoot 'live-picture.png'
        [IO.File]::WriteAllBytes($livePath, $png)
        try {
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
          Expect ($liveOk -and (-not ($liveText -match 'image not saved'))) $liveCopy
        } finally { Remove-Item -LiteralPath $livePath -Force -ErrorAction SilentlyContinue }
      }

      It 'a web picture is left alone' {
        # a remote picture is fetched by the target itself, so the tag stays as it is
        $webBytes = New-CfHtmlSample '<html><body><!--StartFragment--><p><img src="https://example.invalid/x.png"></p><!--EndFragment--></body></html>'
        Expect (([BitConverter]::ToString((Get-CfHtmlOnDisk $webBytes))) -eq ([BitConverter]::ToString($webBytes))) ''
      }

      It 'a zero StartHTML is discovered and repaired' {
        # a header whose StartHTML was left at zero still gets its offsets repaired
        $zeroHead = "Version:0.9`r`nStartHTML:0000000000`r`nEndHTML:0000000000`r`nStartFragment:0000000000`r`nEndFragment:0000000000`r`n"
        $zeroBytes = $Utf8.GetBytes($zeroHead + '<html><body><!--StartFragment--><p>x</p><!--EndFragment--></body></html>')
        $zeroText = $Utf8.GetString((Set-CfHtmlOffsets $zeroBytes))
        $zeroAt = [int](Get-CfHtmlHeadLength $zeroText)
        Expect (($zeroAt -gt 0) -and ($zeroText.Substring($zeroAt, 5) -eq '<html')) ([string]$zeroAt)
      }
    }

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
    $cardRef = New-RichRef @{ Html = $null; Rtf = $Utf8.GetBytes($cardRtf) }
    [void](Write-RichMedia $cardRef @{ Html = $null; Rtf = $Utf8.GetBytes($cardRtf) })

    Describe 'the card' {
      It 'a png picture is re-spelled for the layout' {
        $cardFixed = ConvertTo-CardRtf $cardRtf
        Expect ((-not ($cardFixed -match '\\pngblip')) -and ($cardFixed -match '\\dibitmap0')) ([string]$cardFixed.Length + ' chars')
        Expect ((ConvertTo-CardRtf '{\rtf1\ansi plain words\par}') -ceq '{\rtf1\ansi plain words\par}') ''
      }

      It 'a picture over a card budget leaves a block marker' {
        # a picture the card will not convert is still held by the entry and still pastes back,
        # so the card marks the spot instead of leaving a blank strip nobody can explain
        $savedPng = $script:CardRtfMaxPng
        try {
          $script:CardRtfMaxPng = 64
          $cardCapped = ConvertTo-CardRtf $cardRtf
          Expect ((-not ($cardCapped -match '\\pngblip')) -and ($cardCapped -match '\@cbimg\@')) ([string]$cardCapped.Length + ' chars')
        } finally { $script:CardRtfMaxPng = $savedPng }
        $savedDib = $script:CardRtfMaxDib
        try {
          $script:CardRtfMaxDib = 64
          $cardBudget = ConvertTo-CardRtf $cardRtf
          Expect ((-not ($cardBudget -match '\\pngblip')) -and ($cardBudget -match '\@cbimg\@')) ''
        } finally { $script:CardRtfMaxDib = $savedDib }
      }

      It 'the card draws the picture of a formatted entry' {
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
        Expect ($redPixels -gt 100) ([string]$redPixels + ' coloured pixels')
        Clear-MediaCache
      }

      It 'the preview mode follows the rtf size' {
        # three sizes, three cards: laid out with its pictures, laid out with a marker where each
        # picture was, or the words alone when the rtf was not kept at all
        Expect (((Get-RichPreviewMode 0) -eq 'none') -and ((Get-RichPreviewMode 1000) -eq 'full') -and ((Get-RichPreviewMode 9000000) -eq 'plain') -and ((Get-RichPreviewMode 30000000) -eq 'text')) ''
        # a formatted entry is never shown as a picture: only one without any rtf (an Excel copy)
        # has nothing else to show
        Expect ((Test-RichPictureStandIn 'none') -and (-not (Test-RichPictureStandIn 'full')) -and (-not (Test-RichPictureStandIn 'plain')) -and (-not (Test-RichPictureStandIn 'text'))) ''
      }

      It 'the card marker gets a grey that moves no colour index' {
        # the marker is grey like the panel's secondary text: the colour is appended to the
        # document's own table (or a table is made), so no existing \cfN index moves
        $grayNew = Add-RtfGrayColor '{\rtf1\ansi words}'
        Expect (($grayNew.Index -eq 2) -and ($grayNew.Text -match '\\colortbl ;\\red140\\green140\\blue140;')) ''
        $grayOld = Add-RtfGrayColor '{\rtf1\ansi{\colortbl ;\red255\green0\blue0;} words}'
        Expect (($grayOld.Index -eq 3) -and ($grayOld.Text -match '\\blue0;\\red140')) $grayOld.Text
      }

      It 'a deeply nested picture is padded too' {
        # Word nests the hex behind a picprop chain; a regex cannot follow that, the brace walk can
        $deepPic = '{\rtf1\ansi a {\*\shppict{\pict{\*\picprop{\sp{\sn shapeType}{\sv 75}}}89504e47}} b}'
        $deepBoxes = @()
        Add-Native
        $deepPlain = [Cb.Rtf]::PadPictures($deepPic, '@cbimg@', 17, 180, 60, 6, [ref]$deepBoxes)
        Expect (($deepPlain -notmatch '\\pict') -and ($deepPlain -match 'shppict') -and ($deepPlain -match ' b') -and ($deepBoxes.Length -eq 2)) $deepPlain
      }

      It 'a plain card is still laid out' {
        Clear-MediaCache
        $cardFont = New-Object Drawing.Font 'Segoe UI', 9
        $plainShot = Get-RichPreviewBitmap $cardRef 380 200 $cardFont ([Drawing.Color]::White) 'plain'
        Expect ($null -ne $plainShot) ([string]$cardRtf.Length + ' chars')
        Clear-MediaCache
        # the size comes from the reference, and an old reference form carries none
        Expect (((Get-RichRtfSize $cardRef) -eq $Utf8.GetBytes($cardRtf).Length) -and ((Get-RichRtfSize 'H:' + ('a' * 40) + ':10') -eq 0)) ([string](Get-RichRtfSize $cardRef))
      }
    }

    Describe 'the preview cache' {
      It 'the cache keeps only the newest few and drops a week-old card' {
        # the card cache is derived data: it keeps a week, a file count and a byte budget, and
        # the oldest go first when either budget is passed. The temp folder itself is redirected
        # here, so a card another run left behind cannot make the counts vague.
        $savedTemp = $env:TEMP
        $savedTmp = $env:TMP
        $tempBase = Join-Path $tmpRoot 'cachetest'
        [void](New-Item -ItemType Directory -Path $tempBase -Force)
        $savedMaxFiles = $script:PreviewCacheMaxFiles
        $savedMaxBytes = $script:PreviewCacheMaxBytes
        try {
          $env:TEMP = $tempBase
          $env:TMP = $tempBase
          $cacheDir = Get-PreviewCacheDir
          $script:PreviewCacheMaxFiles = 2
          $script:PreviewCacheMaxBytes = 1048576
          foreach ($n in 1..4) {
            $tp = Join-Path $cacheDir ('t' + $n + '.png')
            [IO.File]::WriteAllBytes($tp, $png)
            (Get-Item -LiteralPath $tp).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-$n)
          }
          Clear-OldPreviewCache
          $leftCards = @(Get-ChildItem -LiteralPath $cacheDir -Filter '*.png' -ErrorAction SilentlyContinue)
          Expect (($leftCards.Count -eq 2) -and ($leftCards[0].Name -eq 't1.png') -and ($leftCards[1].Name -eq 't2.png')) ($leftCards.Name -join ',')
          $stalePath = Join-Path $cacheDir 'tstale.png'
          [IO.File]::WriteAllBytes($stalePath, $png)
          (Get-Item -LiteralPath $stalePath).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-9)
          Clear-OldPreviewCache
          Expect (-not (Test-Path -LiteralPath $stalePath)) ''
        } finally {
          $script:PreviewCacheMaxFiles = $savedMaxFiles
          $script:PreviewCacheMaxBytes = $savedMaxBytes
          $env:TEMP = $savedTemp
          $env:TMP = $savedTmp
          Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
        }
      }

      It 'a cached card reads back' {
        # a rendered card is kept on disk, so the next hover (or the next session) is a file read
        $cachePath = Get-PreviewCachePath $cardRef 380 200
        $probeCard = New-Object Drawing.Bitmap 40, 20
        $probeCard.Save($cachePath, [Drawing.Imaging.ImageFormat]::Png)
        $probeCard.Dispose()
        $backCard = Read-PreviewCache $cachePath
        try {
          Expect (($null -ne $backCard) -and ($backCard.Width -eq 40) -and ($backCard.Height -eq 20)) ''
        } finally {
          if ($null -ne $backCard) { $backCard.Dispose() }
          Remove-Item -LiteralPath $cachePath -Force
        }
      }
    }

    Describe 'the flyout' {
      It 'a card with no job and no fade has nothing to step' {
        Expect (-not (Step-PreviewCard (New-PreviewState))) ''
      }

      It 'the card fades in and stays whole' {
        # a flyout fades in: the alpha ramps up over PreviewFade and stays whole afterwards
        $fadeState = New-PreviewState
        $fadeState.FadeAt = Get-Date
        $fadeMid = Get-PreviewAlpha $fadeState
        $fadeState.FadeAt = (Get-Date).AddSeconds(-2)
        $fadeEnd = Get-PreviewAlpha $fadeState
        $fadeState.FadeAt = $null
        Expect (($fadeMid -lt 255) -and ($fadeMid -ge 0) -and ($fadeEnd -eq 255) -and ((Get-PreviewAlpha $fadeState) -eq 255)) ([string]$fadeMid)
      }

      It 'the card ellipsizes instead of clipping' {
        # a Win11 flyout never cuts text mid-glyph: the card has to ellipsize like the rows do
        $fg = New-Object Drawing.Font 'Segoe UI', 9
        $fadeCfg = New-PreviewConfig @{ Surface = [Drawing.Color]::FromArgb(32, 32, 32); Border = [Drawing.Color]::FromArgb(22, 255, 255, 255); Text = [Drawing.Color]::White; Dim = [Drawing.Color]::FromArgb(170, 170, 170) } (New-PickerStringFormats).Ellipsis $fg $fg
        Expect ($fadeCfg.Sf.Trimming -eq [Drawing.StringTrimming]::EllipsisCharacter) ''
      }
    }

    Describe 'a big picture' {
      It 'is scaled into the card and leaves a small copy behind' {
        # the card scales it down once and keeps a small copy beside it
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
        Expect (($null -ne $card) -and ($cardW -le 380) -and ($cardH -le 200) -and ($cardH -gt 100)) ([string]$cardW + 'x' + [string]$cardH)
        Expect (Test-Path -LiteralPath (Get-ImageThumbPath $bigRef.Sha1)) ''
        Clear-MediaCache
        $fromThumb = Get-ImagePreviewBitmap $bigRef.Sha1 380 200
        Expect (($null -ne $fromThumb) -and ($fromThumb.Width -eq $cardW) -and ($fromThumb.Height -eq $cardH)) ''
        Clear-MediaCache
        # a thumbnail lives while its picture is referenced, and goes with it
        $bigList = New-Object System.Collections.Generic.List[object]
        $bigList.Add((New-Record $bigPay $now ''))
        Save-Records $bigList.ToArray()
        Expect (Test-Path -LiteralPath (Get-ImageThumbPath $bigRef.Sha1)) ''
        Save-Records @()
        Expect ((-not (Test-Path -LiteralPath (Get-ImageThumbPath $bigRef.Sha1))) -and (-not (Test-Path -LiteralPath (Get-MediaPath $bigRef.Sha1 'png')))) ''
      }
    }

    Describe 'media follows the record' {
      It 'dropping a record removes its media' {
        # media is dropped with the record it belongs to
        Save-Records @($blockRec)
        Expect (-not (Test-Path -LiteralPath (Get-MediaPath $iref.Sha1 'png'))) ''
        $rSha = (Get-RichRef $rref).Sha1
        Expect ((-not (Test-Path -LiteralPath (Get-MediaPath $rSha 'html'))) -and (-not (Test-Path -LiteralPath (Get-MediaPath $rSha 'rtf')))) ''
      }

      It 'the media budget drops pictures but never text rows' {
        # counted apart from MaxTextTotalBytes: pictures go first, text rows never do
        $saved = $script:MaxMediaTotalBytes
        try {
          [void](Write-ImageMedia $p1 $png)
          $script:MaxMediaTotalBytes = [long]10
          $budget = New-Object System.Collections.Generic.List[object]
          $budget.Add($imgRec)
          $budget.Add((New-Record 'a' $now ''))
          Trim-Records $budget
          Expect (($budget.Count -eq 1) -and ([string]$budget[0].Payload -eq 'a')) ([string]$budget.Count)
          $script:MaxMediaTotalBytes = [long]($png.Length + 10)
          $budget2 = New-Object System.Collections.Generic.List[object]
          $budget2.Add($imgRec)
          $budget2.Add((New-Record 'a' $now ''))
          Trim-Records $budget2
          Expect ($budget2.Count -eq 2) ([string]$budget2.Count)
        } finally { $script:MaxMediaTotalBytes = $saved }
      }
    }

    Describe 'store version' {
      It 'an older layout is recognised and never overwritten' {
        # a file whose header is not the current layout is not parsed, not overwritten and not
        # backed up by the reader: `migrate` is the only thing that may touch it
        [IO.File]::WriteAllText($StoreFile, ('CBHIST' + $RS + '0' + $RS + 't' + $US + [string]$now + $US + $US + 'old text'), $Utf8)
        $sv = Get-StoreVersion
        Expect (($sv.Kind -eq 'old') -and ($sv.Version -eq 0) -and (@(Get-Records).Count -eq 0)) ($sv.Kind + ' v' + $sv.Version)
        Add-Item 'must not overwrite'
        Expect (([IO.File]::ReadAllText($StoreFile)).Contains('old text')) ''
      }

      It 'a file without the tag is ignored and left alone' {
        # no other format support
        [IO.File]::WriteAllText($StoreFile, ('alpha' + $RS + 'beta'), $Utf8)
        $uv = Get-StoreVersion
        Expect ((@(Get-Records).Count -eq 0) -and ($uv.Kind -eq 'unknown') -and ($uv.Version -eq -1)) ($uv.Kind + ' v' + $uv.Version)
        Expect (-not (Test-Path -LiteralPath (Join-Path $unitDir 'history.v1.bak'))) ''
      }

      It 'a newer layout is reported, never downgraded' {
        [IO.File]::WriteAllText($StoreFile, ('CBHIST' + $RS + '9' + $RS + 't' + $US + [string]$now + $US + $US + 'future'), $Utf8)
        $nv = Get-StoreVersion
        Expect (($nv.Kind -eq 'newer') -and ($nv.Version -eq 9)) ($nv.Kind + ' v' + $nv.Version)
        [IO.File]::WriteAllText($StoreFile, '', $Utf8)
      }

      It 'the program carries one version' {
        # the version is one constant, and it is what the panel and the CLI report
        Expect ([string]$script:Version -match '^\d+\.\d+\.\d+$') ([string]$script:Version)
      }
    }

    # ---------------------------------------------------------------- migration
    Describe 'store migration' {
      It 'a missing or current file needs no migration' {
        Expect ((Invoke-DataMigration).Message -like 'no history file*') ''
        Save-Records @()
        Expect ((Invoke-DataMigration).Message -like 'already CBHIST v*') (Invoke-DataMigration).Message
      }

      It 'a version with no step is refused' {
        # an older file with no step for it is refused rather than guessed at
        [IO.File]::WriteAllText($StoreFile, ('CBHIST' + $RS + '0' + $RS + 't' + $US + [string]$now + $US + $US + 'old text'), $Utf8)
        $mr = Invoke-DataMigration
        Expect ((-not $mr.Changed) -and $mr.Message.StartsWith('[!]')) $mr.Message
        Expect (([IO.File]::ReadAllText($StoreFile)).Contains('old text')) ''
      }

      It 'purge archives a file it cannot migrate' {
        [IO.File]::WriteAllText($StoreFile, ('CBHIST' + $RS + '0' + $RS + 't' + $US + [string]$now + $US + $US + 'old text'), $Utf8)
        $mp = Invoke-DataMigration -Purge
        $backups = @(Get-ChildItem -LiteralPath (Join-Path $unitDir 'data\backup') -Filter '*.dat' -ErrorAction SilentlyContinue)
        Expect ($mp.Changed -and $backups.Count -eq 1 -and -not (Test-Path -LiteralPath $StoreFile)) ([string]$backups.Count + ' backup(s)')
        Expect (([IO.File]::ReadAllText($backups[0].FullName)).Contains('old text')) ''
        Save-Records @()
        Expect (([IO.File]::ReadAllText($StoreFile)).StartsWith($TAG)) ''
      }

      It 'a newer file is never touched, not even by -Purge' {
        [IO.File]::WriteAllText($StoreFile, ('CBHIST' + $RS + '9' + $RS + 't' + $US + [string]$now + $US + $US + 'future'), $Utf8)
        $mn = Invoke-DataMigration -Purge
        Expect ((-not $mn.Changed) -and (([IO.File]::ReadAllText($StoreFile)).Contains('future'))) $mn.Message
        [IO.File]::WriteAllText($StoreFile, '', $Utf8)
      }
    }

    # ---- the rows themselves: order, trim, bulk update, clear, restore
    Describe 'store rows' {
      It 'the sort mark keeps a row on top after a repeat capture' {
        Save-Records $recList.ToArray()
        Add-Item 'alpha'
        $r3 = @(Get-Records)
        Expect ($r3[0].Payload -eq 'alpha') $r3[0].Payload
        [void](Set-Mark 'beta' 'p' $true)
        Add-Item 'beta'
        $stillMarked = $false
        foreach ($r in @(Get-Records)) { if ($r.Payload -ceq 'beta' -and (Test-Mark $r 'p')) { $stillMarked = $true } }
        Expect $stillMarked ''
      }

      It 'trim keeps a protected mark' {
        $saved = $script:MaxItems
        try {
          $script:MaxItems = 2
          Save-Records @()
          Add-Item 'p1'
          [void](Set-Mark 'p1' 's' $true)
          foreach ($t in @('n1', 'n2', 'n3', 'n4')) { Add-Item $t }
          $r5 = @(Get-Records)
          $hasMark = $false
          foreach ($r in $r5) { if ($r.Payload -ceq 'p1' -and (Test-Mark $r 's')) { $hasMark = $true } }
          Expect ($r5.Count -eq 2 -and $hasMark) (($r5.Count -as [string]) + ' ' + ((Payloads) -join '|'))
        } finally { $script:MaxItems = $saved }
      }

      It 'Update-Records applies one body to the whole list' {
        # a plugin that limits its own mark needs one pass over the whole list, saved in one write
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
        Expect ($cleared -eq 2) ($cleared -as [string])
        Expect (-not (@(Get-Records) | Where-Object { Test-Mark $_ 'p' })) ''
      }

      It 'clear follows the declared keeps' {
        Save-Records @()
        Add-Item 'c1'
        Add-Item 'c2'
        [void](Set-Mark 'c1' 'p' $true)
        Clear-Store (Get-ClearKeepMarks)
        $afterKeep = @(Get-Records)
        Expect ($afterKeep.Count -eq 1 -and $afterKeep[0].Payload -eq 'c1') ((Payloads) -join '|')
        Clear-Store (Get-ClearKeepMarks -All)
        Expect (@(Get-Records).Count -eq 0) ''
        $script:Plugins = @()
      }

      It 'Remove-Record and Restore-Record keep the slot' {
        Save-Records @()
        Add-Item 'u1'
        Add-Item 'u2'
        Add-Item 'u3'
        $victim = @(Get-Records)[1]
        [void](Remove-Record $victim.Payload)
        Expect (((Payloads) -join '|') -eq 'u3|u1') ((Payloads) -join '|')
        Restore-Record $victim 1
        Expect (((Payloads) -join '|') -eq 'u3|u2|u1') ((Payloads) -join '|')
        Save-Records @()
      }
    }

    # ------------------------------------------------------------ panel helpers
    Describe 'panel helpers' {
      It 'the visible row count floors and never reaches zero' {
        Expect ((Get-VisibleRowCount 340 34) -eq 10) ((Get-VisibleRowCount 340 34) -as [string])
        Expect ((Get-VisibleRowCount 100 34) -eq 2) ''
        Expect ((Get-VisibleRowCount 10 40) -eq 1) ''
      }
    }

    # ---------------------------------------------------------------- transitions
    Describe 'hover and selection animation' {
      It 'a fresh state starts at rest' {
        $st = New-AnimState
        Expect (($st.Hover -eq 0) -and ($st.HoverTarget -eq 0) -and ($st.HoverIndex -eq -1)) ''
        Set-AnimHover $st 3
        Expect (($st.HoverIndex -eq 3) -and ($st.HoverTarget -eq 1)) ''
      }

      It 'hover remembers the row it left' {
        $st = New-AnimState
        Set-AnimHover $st 3
        Set-AnimHover $st 4
        Expect (($st.HoverIndex -eq 4) -and ($st.PrevHoverIndex -eq 3)) ($st.PrevHoverIndex -as [string])
        Set-AnimHover $st 4
        Expect ($st.PrevHoverIndex -eq 3) ''
        Set-AnimHover $st -1
        Expect (($st.HoverIndex -eq -1) -and ($st.PrevHoverIndex -eq 4)) ($st.PrevHoverIndex -as [string])
      }

      It 'a frame eases, settles and snaps to the target' {
        $st = New-AnimState
        Set-AnimHover $st 3
        $mask = Invoke-AnimFrame $st 0.5
        Expect ((($mask -band 1) -ne 0) -and ($st.Hover -eq 0.5)) ($mask -as [string])
        $null = Invoke-AnimFrame $st 1.0
        Expect (($st.Hover -eq 1) -and ((Invoke-AnimFrame $st 0.5) -eq 0)) ''
        Set-AnimTarget $st 'Hover' 0.0
        $null = Invoke-AnimFrame $st 0.995
        Expect (($st.Hover -eq 0) -and ((Invoke-AnimFrame $st 0.5) -eq 0)) ($st.Hover -as [string])
      }

      It 'selection remembers the previous row' {
        $st = New-AnimState
        Set-AnimSelection $st 2
        Expect (($st.SelIndex -eq 2) -and ($st.PrevSelIndex -eq -1) -and ($st.Sel -eq 0)) ''
        Set-AnimSelection $st 5
        Expect (($st.PrevSelIndex -eq 2) -and ($st.SelIndex -eq 5) -and ($st.Sel -eq 0)) ''
        Set-AnimSelection $st 5
        Expect ($st.PrevSelIndex -eq 2) ''
      }
    }

    Describe 'row backdrop' {
      It 'Scale-Alpha scales the alpha only' {
        $ac = Scale-Alpha ([Drawing.Color]::FromArgb(200, 10, 20, 30)) 0.5
        Expect (($ac.A -eq 100) -and ($ac.R -eq 10) -and ($ac.B -eq 30)) ($ac.A -as [string])
        Expect ((Scale-Alpha ([Drawing.Color]::FromArgb(200, 10, 20, 30)) 1.0).A -eq 200) ''
        Expect ((Scale-Alpha ([Drawing.Color]::FromArgb(200, 10, 20, 30)) 0).A -eq 0) ''
      }

      It 'the backdrop draws nothing at rest, the selection and the tint' {
        $asel = [Drawing.Color]::FromArgb(60, 96, 205, 255)
        $ahov = [Drawing.Color]::FromArgb(30, 255, 255, 255)
        $abmp = New-Object Drawing.Bitmap 120, 40
        $agr = [Drawing.Graphics]::FromImage($abmp)
        try {
          Draw-RowBackdrop $agr 0 0 120 40 4 $null $asel $ahov 0.0 0.0
          Expect ($abmp.GetPixel(60, 20).A -eq 0) $abmp.GetPixel(60, 20).ToString()
          Draw-RowBackdrop $agr 0 0 120 40 4 $null $asel $ahov 1.0 0.0
          Expect (($abmp.GetPixel(60, 20).A -gt 0) -and ($abmp.GetPixel(60, 20).B -eq 255)) $abmp.GetPixel(60, 20).ToString()
        } finally {
          $agr.Dispose()
          $abmp.Dispose()
        }
        $tbmp = New-Object Drawing.Bitmap 60, 40
        $tgr = [Drawing.Graphics]::FromImage($tbmp)
        try {
          Draw-RowBackdrop $tgr 0 0 60 40 4 ([Drawing.Color]::FromArgb(255, 0, 255, 0)) $asel $ahov 0.0 0.0
          Expect (($tbmp.GetPixel(30, 20).G -eq 255) -and ($tbmp.GetPixel(30, 20).R -eq 0)) $tbmp.GetPixel(30, 20).ToString()
        } finally {
          $tgr.Dispose()
          $tbmp.Dispose()
        }
      }
    }

    Describe 'panel geometry' {
      It 'the height is the chrome plus whole rows' {
        # raising the row count can never cut a row
        Expect ((Get-PanelHeight 10 40 110) -eq 510) ((Get-PanelHeight 10 40 110) -as [string])
        Expect ((Get-PanelHeight 0 40 110) -eq 150) ''
        Expect ((Get-RowFit 510 40 110) -eq 10) ((Get-RowFit 510 40 110) -as [string])
        Expect ((Get-RowFit 100 40 110) -eq 1) ''
      }

      It 'the requested rows are capped by the screen but never below the floor' {
        Expect ((Get-RowsForScreen 50 510 40 110 3) -eq 10) ((Get-RowsForScreen 50 510 40 110 3) -as [string])
        Expect ((Get-RowsForScreen 5 510 40 110 3) -eq 5) ''
        Expect ((Get-RowsForScreen 50 200 40 110 3) -eq 3) ''
        Expect ((Get-RowsForScreen 7 0 40 110 3) -eq 7) ''
      }

      It 'the chrome is the header plus the footer' {
        Expect ((Get-PanelChrome) -eq ($script:Metric['HeadHeight'] + $script:Metric['FootHeight'] + 2)) ((Get-PanelChrome) -as [string])
      }

      It 'the row block is inset the same on both sides' {
        # the scrollbar lane shifts the block right, so the right inset is the left one doubled;
        # breaking that puts every row off centre by half the difference
        Expect ($script:Metric['RowRight'] -eq (2 * $script:Metric['RowInset'])) ('RowInset=' + $script:Metric['RowInset'] + ' RowRight=' + $script:Metric['RowRight'])
      }

      It 'each shape brings its own width, rows and chrome' {
        $full = Get-PanelPreset 'full'
        $compact = Get-PanelPreset 'compact'
        Expect (($full.Mode -eq 'full') -and ($compact.Mode -eq 'compact')) ([string]$compact.Mode)
        Expect (($full.Width -eq $script:WinWidth) -and ($full.Rows -eq $script:Rows)) (($full.Width -as [string]) + '/' + ($full.Rows -as [string]))
        Expect (($compact.Width -eq $script:CompactWidth) -and ($compact.Rows -eq $script:CompactRows)) (($compact.Width -as [string]) + '/' + ($compact.Rows -as [string]))
        # the compact header and footer are shorter than the theme's, so the panel really is small
        Expect ((Get-PresetChrome $compact) -lt (Get-PanelChrome)) ((Get-PresetChrome $compact) -as [string])
        Expect ((Get-PresetChrome $full) -eq (Get-PanelChrome)) ((Get-PresetChrome $full) -as [string])
      }

      It 'the compact shape drops the time column and the corner count' {
        $full = Get-PanelPreset 'full'
        $compact = Get-PanelPreset 'compact'
        Expect (($compact.ShowTime -eq $false) -and ($compact.ShowFootRight -eq $false)) ([string]$compact.ShowTime)
        Expect (($full.ShowTime -eq [bool]$script:ShowTime) -and ($full.ShowFootRight -eq $true)) ([string]$full.ShowTime)
      }

      It 'the compact panel always follows the caret, the full one only when asked' {
        Expect ((Get-PanelPreset 'compact').AnchorCaret -eq $true) ''
        # the full panel is the taller one: following the caret is opt-in there
        $script:PlaceAtCaret = $false
        Expect ((Get-PanelPreset 'full').AnchorCaret -eq $false) ''
        $script:PlaceAtCaret = $true
        Expect ((Get-PanelPreset 'full').AnchorCaret -eq $true) ''
        $script:PlaceAtCaret = $false
      }
    }

    Describe 'quick keys' {
      It 'the index comes from the top row and the offset' {
        Expect ((Get-QuickKeyIndex 0 5 20 10) -eq 5) ''
        Expect ((Get-QuickKeyIndex 3 7 20 10) -eq 10) ''
        Expect ((Get-QuickKeyIndex 9 15 20 10) -eq -1) ''
        Expect ((Get-QuickKeyIndex 9 0 20 8) -eq -1) ''
        Expect ((Get-QuickKeyIndex 10 0 20 10) -eq -1) ''
      }

      It 'the labels run 1-9 and then 0' {
        Expect (((0..8 | ForEach-Object { Get-QuickKeyLabel $_ }) -join '') -eq '123456789') ((0..8 | ForEach-Object { Get-QuickKeyLabel $_ }) -join '')
        Expect ((Get-QuickKeyLabel 9) -eq '0') (Get-QuickKeyLabel 9)
        Expect ((Get-QuickKeyLabel 10) -eq '') ''
      }

      It 'the digits map to the keypad row' {
        Expect (((0..9 | ForEach-Object { Get-QuickKeyOffset $_ }) -join ',') -eq '9,0,1,2,3,4,5,6,7,8') ((0..9 | ForEach-Object { Get-QuickKeyOffset $_ }) -join ',')
        Expect ((Get-QuickKeyOffset 12) -eq -1) ''
        Expect ((Get-QuickKeyIndex (Get-QuickKeyOffset 0) 0 20 10) -eq 9) ''
        Expect ((Get-QuickKeyIndex (Get-QuickKeyOffset 1) 4 20 10) -eq 4) ''
      }
    }

    Describe 'picker bounds' {
      BeforeAll {
        $script:PickerAreas = @(
          [pscustomobject]@{ Left = 0; Top = 0; Width = 1920; Height = 1080 },
          [pscustomobject]@{ Left = 1920; Top = 0; Width = 1920; Height = 1080 }
        )
        $script:PickerFallbackArea = [pscustomobject]@{ Left = 0; Top = 0; Width = 1920; Height = 1080 }
      }

      It 'a saved position is used when it is on screen' {
        $b = Get-PickerBounds 660 430 '100' '200' $script:PickerAreas $script:PickerFallbackArea
        Expect (($b.Left -eq 100) -and ($b.Top -eq 200) -and (-not $b.Fitted)) (($b.Left -as [string]) + ',' + ($b.Top -as [string]))
      }

      It 'an off-screen position falls back' {
        $b = Get-PickerBounds 660 430 '5000' '9000' $script:PickerAreas $script:PickerFallbackArea
        Expect ($b.Fitted -and ($b.Left -eq 630) -and ($b.Top -eq 217)) (($b.Left -as [string]) + ',' + ($b.Top -as [string]))
      }

      It 'a position is clamped into the screen' {
        $b = Get-PickerBounds 660 430 '1500' '100' $script:PickerAreas $script:PickerFallbackArea
        Expect ($b.Left -eq 1260) ($b.Left -as [string])
      }

      It 'an empty position is centred' {
        $b = Get-PickerBounds 660 430 '' '' $script:PickerAreas $script:PickerFallbackArea
        Expect $b.Fitted ''
      }

      It 'with no saved position the panel sits on the window it came from' {
        $prefer = [pscustomobject]@{ Left = 200; Top = 300; Width = 800; Height = 600 }
        $b = Get-PickerBounds 660 430 '' '' $script:PickerAreas $script:PickerFallbackArea $prefer
        # 200 + (800-660)/2 = 270 and 300 + (600-430)/3 = 356.67 rounded = 357
        Expect (($b.Left -eq 270) -and ($b.Top -eq 357) -and $b.Fitted) (($b.Left -as [string]) + ',' + ($b.Top -as [string]))
      }

      It 'a window on the second monitor keeps the panel there' {
        $prefer = [pscustomobject]@{ Left = 2200; Top = 100; Width = 800; Height = 600 }
        $b = Get-PickerBounds 660 430 '' '' $script:PickerAreas $script:PickerFallbackArea $prefer
        Expect ($b.Left -eq 2270) ($b.Left -as [string])
      }

      It 'a saved position still wins over the window it came from' {
        $prefer = [pscustomobject]@{ Left = 200; Top = 300; Width = 800; Height = 600 }
        $b = Get-PickerBounds 660 430 '100' '200' $script:PickerAreas $script:PickerFallbackArea $prefer
        Expect (($b.Left -eq 100) -and ($b.Top -eq 200)) (($b.Left -as [string]) + ',' + ($b.Top -as [string]))
      }

      It 'the compact panel opens right under the caret' {
        $caret = [pscustomobject]@{ Left = 400; Top = 300; Width = 2; Height = 20 }
        $b = Get-PickerBounds 520 290 '' '' $script:PickerAreas $script:PickerFallbackArea $null $caret
        # the caret line starts the panel: 300 + 20 + the 4 px gap
        Expect (($b.Left -eq 400) -and ($b.Top -eq 324) -and $b.Fitted) (($b.Left -as [string]) + ',' + ($b.Top -as [string]))
      }

      It 'with no room below it flips above the caret' {
        $caret = [pscustomobject]@{ Left = 400; Top = 1000; Width = 2; Height = 20 }
        $b = Get-PickerBounds 520 290 '' '' $script:PickerAreas $script:PickerFallbackArea $null $caret
        # 1020 + 4 + 290 runs off the bottom, so the panel sits above: 1000 - 4 - 290
        Expect ($b.Top -eq 706) ($b.Top -as [string])
      }

      It 'a caret at the right edge keeps the panel on that screen' {
        $caret = [pscustomobject]@{ Left = 1900; Top = 300; Width = 2; Height = 20 }
        $b = Get-PickerBounds 520 290 '' '' $script:PickerAreas $script:PickerFallbackArea $null $caret
        Expect ($b.Left -eq 1400) ($b.Left -as [string])
      }

      It 'a caret on the second monitor decides the screen' {
        $caret = [pscustomobject]@{ Left = 2200; Top = 300; Width = 2; Height = 20 }
        $b = Get-PickerBounds 520 290 '' '' $script:PickerAreas $script:PickerFallbackArea $null $caret
        Expect ($b.Left -eq 2200) ($b.Left -as [string])
      }

      It 'a saved position still wins over the caret' {
        $caret = [pscustomobject]@{ Left = 400; Top = 300; Width = 2; Height = 20 }
        $b = Get-PickerBounds 660 430 '100' '200' $script:PickerAreas $script:PickerFallbackArea $null $caret
        Expect (($b.Left -eq 100) -and ($b.Top -eq 200)) (($b.Left -as [string]) + ',' + ($b.Top -as [string]))
      }

      It 'a caret with no size falls through to the window' {
        $prefer = [pscustomobject]@{ Left = 200; Top = 300; Width = 800; Height = 600 }
        $empty = [pscustomobject]@{ Left = 0; Top = 0; Width = 0; Height = 0 }
        $b = Get-PickerBounds 660 430 '' '' $script:PickerAreas $script:PickerFallbackArea $prefer $empty
        Expect (($b.Left -eq 270) -and ($b.Top -eq 357)) (($b.Left -as [string]) + ',' + ($b.Top -as [string]))
      }
    }

    Describe 'preview slot' {
      BeforeAll {
        $script:PvArea = [pscustomobject]@{ Left = 0; Top = 0; Width = 1920; Height = 1080 }
      }

      It 'the card takes the side that has room' {
        $panel = [pscustomobject]@{ Left = 300; Top = 200; Width = 520; Height = 290 }
        $s = Get-PreviewSlot $panel $script:PvArea 420 10
        Expect (($s.X -eq 830) -and ($s.W -eq 420) -and (-not $s.Below)) (($s.X -as [string]) + '/' + ($s.W -as [string]))
      }

      It 'the card flips to the left when the right edge is near' {
        $panel = [pscustomobject]@{ Left = 1400; Top = 200; Width = 520; Height = 290 }
        $s = Get-PreviewSlot $panel $script:PvArea 420 10
        # 1400 - 10 - 420; right side has only 10 px
        Expect (($s.X -eq 970) -and ($s.W -eq 420) -and (-not $s.Below)) (($s.X -as [string]) + '/' + ($s.W -as [string]))
      }

      It 'a narrow gap narrows the card instead of pushing it off screen' {
        $panel = [pscustomobject]@{ Left = 200; Top = 200; Width = 1400; Height = 290 }
        $s = Get-PreviewSlot $panel $script:PvArea 420 10
        # 310 px on the right and 190 px on the left: the wider side keeps the card, narrowed
        Expect (($s.W -eq 310) -and ($s.X -eq 1610) -and (-not $s.Below)) (($s.X -as [string]) + '/' + ($s.W -as [string]))
      }

      It 'with no room beside the panel the card goes under it' {
        $tight = [pscustomobject]@{ Left = 150; Top = 100; Width = 650; Height = 900 }
        $panel = [pscustomobject]@{ Left = 200; Top = 100; Width = 520; Height = 290 }
        $s = Get-PreviewSlot $panel $tight 420 10
        Expect $s.Below (($s.X -as [string]) + '/' + ($s.Below -as [string]))
      }
    }

    Describe 'hit marks' {
      It 'the search highlight is case-insensitive' {
        $marks = Get-HitMarks 'Hello World' @('wor')
        Expect ($marks[6] -and $marks[7] -and $marks[8] -and (-not $marks[0])) ''
      }
    }

    # ------------------------------------------------------------ sticky pins
    # the rows the sticky and the search rows below share
    $stickyRows = @(
      (New-Record 'pinned one' 100 'p'),
      (New-Record 'pinned two' 99 'p'),
      (New-Record 'pinned three' 98 'p'),
      (New-Record 'alpha' 97 ''),
      (New-Record 'beta' 96 '')
    )

    Describe 'sticky pins' {
      It 'StickyRowLimit keeps one row for the results' {
        Expect ((Get-StickyRowLimit 10 3) -eq 3) ((Get-StickyRowLimit 10 3) -as [string])
        Expect ((Get-StickyRowLimit 10 0) -eq 0) ''
        Expect ((Get-StickyRowLimit 10 -1) -eq 9) ((Get-StickyRowLimit 10 -1) -as [string])
        Expect ((Get-StickyRowLimit 2 5) -eq 1) ((Get-StickyRowLimit 2 5) -as [string])
        Expect ((Get-StickyRowLimit 1 3) -eq 0) ''
      }

      It 'StickyRowCap leaves one row for the results' {
        # the same cap drives `config set`: it is what Rows leaves after one row for the results
        Expect ((Get-StickyRowCap 10) -eq 9) ((Get-StickyRowCap 10) -as [string])
        Expect ((Get-StickyRowCap 1) -eq 0) ''
      }

      It 'the search hides an unmatched pin like any other row' {
        $rows = @(Select-QueryRows $stickyRows @('alpha'))
        Expect (((@($rows) | ForEach-Object { $_.Payload }) -join '|') -eq 'alpha') ((@($rows) | ForEach-Object { $_.Payload }) -join '|')
        $rows = @(Select-QueryRows $stickyRows @())
        Expect (@($rows).Count -eq 5) (@($rows).Count -as [string])
      }
    }

    # ---- query line: the words are cut up by utils/query-words.ps1 and given meaning here
    # the rows the query rows below search
    $qRows = @(
      (New-Record 'alpha one' 100 ''),
      (New-Record 'alpha two' 90 'p'),
      (New-Record 'beta three' 80 '')
    )

    Describe 'the query line' {
      It 'the words are cut up and a field is named' {
        Expect (((Split-QueryText 'a "b c" d') -join '|') -eq 'a|b c|d') ((Split-QueryText 'a "b c" d') -join '|')
        Expect (((Split-QueryText 'a "b c') -join '|') -eq 'a|b c') ((Split-QueryText 'a "b c') -join '|')
        $qp = Get-QueryPart '-type:image'
        Expect (($qp.Negated) -and ($qp.Field -eq 'type') -and ($qp.Value -eq 'image')) ($qp.Field + '/' + $qp.Value)
        # 'https' looks like a field name to the lexer, so the compiler is what keeps a url whole
        Expect ((@(Invoke-Query @(New-Record 'see https://example.com/x now' 1 '') (New-Query -Line 'https://example.com/x')).Count) -eq 1) ''
      }

      It 'a word, a negation and a phrase narrow the list' {
        Expect ((@(Invoke-Query $qRows (New-Query -Line 'ALPHA')).Count) -eq 2) ''
        Expect ((@(Invoke-Query $qRows (New-Query -Line 'alpha -two')).Count) -eq 1) ''
        Expect ((@(Invoke-Query $qRows (New-Query -Line '"alpha t"')).Count) -eq 1) ''
      }

      It 'a field keeps what it names' {
        $fileRow = New-Record ([char]1 + 'C:\a.txt') 10 ''
        Expect ((@(Invoke-Query $qRows (New-Query -Line 'type:text')).Count) -eq 3) ''
        Expect ((@(Invoke-Query @($qRows + $fileRow) (New-Query -Line 'type:files')).Count) -eq 1) ''
        Expect ((@(Invoke-Query $qRows (New-Query -Line 'mark:p')).Count) -eq 1) ''
        Expect ((@(Invoke-Query $qRows (New-Query -Line '-mark:p')).Count) -eq 2) ''
      }

      It 'a pattern is matched and a broken one is reported' {
        Expect ((@(Invoke-Query $qRows (New-Query -Line 're:^alpha t')).Count) -eq 1) ''
        $badRegex = New-Query -Line 're:('
        Expect (($badRegex.Bad.Count -eq 1) -and (@(Invoke-Query $qRows $badRegex).Count -eq 0)) ''
      }

      It 'an unknown type is reported' {
        $badType = New-Query -Line 'type:nonsense'
        Expect ($badType.Bad.Count -eq 1) ([string]$badType.Bad[0])
      }

      It 'age and newer keep the old and the new rows' {
        $nowSec = Get-Epoch
        $ageRows = @((New-Record 'fresh row' ($nowSec - 60) ''), (New-Record 'stale row' ($nowSec - 172800) ''))
        $aged = @(Invoke-Query $ageRows (New-Query -Line 'age:1d'))
        Expect ((@($aged).Count -eq 1) -and (@($aged)[0].Payload -eq 'stale row')) ''
        $today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
        Expect ((@(Invoke-Query $ageRows (New-Query -Line ('newer:' + $today))).Count) -eq 1) ''
      }

      It 'the empty list explains itself' {
        # and a filter nobody understands says so
        $hints = @{ History = 'H'; Search = 'S' }
        $es = Get-EmptyState @() (New-Query -Line 'x') 'x' $hints
        Expect (($es.Title -eq 'Clipboard history is empty') -and ($es.Glyph -eq 'H')) $es.Title
        $es = Get-EmptyState $qRows (New-Query -Line 'zzz') 'zzz' $hints
        Expect ($es.Title -like 'No results*') $es.Title
        $es = Get-EmptyState $qRows (New-Query -Line 'type:nonsense') 'type:nonsense' $hints
        Expect ($es.Title -eq 'The search was not understood') $es.Title
      }
    }

    Describe 'typing narrows' {
      It 'every keystroke rewrites the line it started from' {
        # Typing one character at a time reuses the previous answer as the candidate set, so the
        # panel stops rescanning rows the earlier keystroke already rejected. Every step must
        # still equal a cold run of the same line on its own copy of the rows.
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
        foreach ($step in $steps) {
          $live = (@(Invoke-Query $narrowRows (New-Query -Line $step)) | ForEach-Object { [string]$_.Payload }) -join ','
          if ($live -cne (Get-ColdPayloads $narrowRows $step)) { $drift += $step }
        }
        Expect ($drift.Count -eq 0) ($drift -join ' | ')
        # the helper above ran on its own copy, so ask once more on the real array before looking
        [void](Invoke-Query $narrowRows (New-Query -Line 'alpha on'))
        Expect (([object]::ReferenceEquals($script:QueryNarrow.Array, $narrowRows)) -and ($script:QueryNarrow.Rows.Count -le 2)) ([string]$script:QueryNarrow.Rows.Count)
        # a line that does not start with the previous one is a new question, not a narrower one
        $restart = (@(Invoke-Query $narrowRows (New-Query -Line 'beta')) | ForEach-Object { [string]$_.Payload }) -join ','
        Expect ($restart -ceq (Get-ColdPayloads $narrowRows 'beta')) $restart
        # extending an exclusion widens the answer, so the old row set must not be reused
        $exclRows = @(
          (New-Record 'ab here' 100 ''),
          (New-Record 'abc here' 90 ''),
          (New-Record 'nothing' 80 '')
        )
        $narrowedAway = @(Invoke-Query $exclRows (New-Query -Line 'here -ab'))
        $widened = @(Invoke-Query $exclRows (New-Query -Line 'here -abc'))
        Expect (($narrowedAway.Count -eq 0) -and ($widened.Count -eq 1)) ([string]$narrowedAway.Count + ' -> ' + [string]$widened.Count)
      }
    }

    # ---- batch selection (lib/select.ps1): positions in the filtered list, nothing else
    Describe 'batch selection' {
      It 'a click, a shift and a ctrl build the set' {
        $sel = New-Selection
        Expect ((Get-SelectionCount $sel) -eq 0) ''
        Update-Selection $sel $null 2 $false $false
        Expect (((Get-SelectionCount $sel) -eq 1) -and (Test-RowSelected $sel 2)) ''
        Update-Selection $sel $null 5 $false $true
        Expect (((Get-SelectionCount $sel) -eq 4) -and (Test-RowSelected $sel 5)) ((Get-SelectionCount $sel) -as [string])
        Update-Selection $sel $null 3 $true $false
        Expect (-not (Test-RowSelected $sel 3)) ''
        Update-Selection $sel $null 3 $true $false
        Expect (Test-RowSelected $sel 3) ''
        Update-Selection $sel $null 9 $false $false
        Expect ((Get-SelectionCount $sel) -eq 1) ((Get-SelectionCount $sel) -as [string])
      }

      It 'a batch keeps list order, not click order' {
        $sel = New-Selection
        $pickRows = @(@{ Payload = 'a' }, @{ Payload = 'b' }, @{ Payload = 'c' })
        Update-Selection $sel $null 0 $false $false
        Update-Selection $sel $null 2 $true $false
        $pickedText = (@(@(Get-SelectedRecords $sel $pickRows) | ForEach-Object { [string]$_.Payload }) -join '')
        Expect ($pickedText -eq 'ac') $pickedText
        # a shorter list drops the stale positions
        Trim-Selection $sel 2
        Expect (((Get-SelectionCount $sel) -eq 1) -and (Test-RowSelected $sel 0)) ''
      }

      It 'select all marks every row and clearing drops the set' {
        $sel = New-Selection
        Select-AllRows $sel $null 3
        Expect ((Get-SelectionCount $sel) -eq 3) ''
        Clear-Selection $sel
        Expect (((Get-SelectionCount $sel) -eq 0) -and ($sel.Anchor -eq -1)) ''
      }

      It 'a batch with no text copies nothing' {
        # a batch of rows that carry no text has nothing to copy, and says so by returning nothing
        $mixSel = New-Selection
        Select-AllRows $mixSel $null 2
        $noText = @(@{ Payload = ([char]1 + 'C:\a.txt') }, @{ Payload = ([char]3 + 'image:x:1x1:1:PNG') })
        Expect ($null -eq (Invoke-SelectionCopy $mixSel $noText)) ''
      }

      It 'a batch delete removes the whole set in one write' {
        # the store is rewritten once, not once per row
        Save-Records @((New-Record 'batch one' $now ''), (New-Record 'batch two' $now ''))
        $batchRows = @(Get-Records)
        $delSel = New-Selection
        Select-AllRows $delSel $null $batchRows.Count
        $delNote = Invoke-SelectionDelete $delSel $batchRows
        Expect ((@(Get-Records).Count -eq 0) -and ($delNote -like 'deleted 2*')) $delNote
      }
    }
    # freezing is a scrolling behaviour: the leading run of pins is what stays put
    Describe 'sticky top' {
      It 'counts the leading run of pins' {
        Expect ((Get-StickyTopRows $stickyRows 'p' 5) -eq 3) ((Get-StickyTopRows $stickyRows 'p' 5) -as [string])
        Expect ((Get-StickyTopRows $stickyRows 'p' 2) -eq 2) ((Get-StickyTopRows $stickyRows 'p' 2) -as [string])
        Expect ((Get-StickyTopRows @($stickyRows[0], $stickyRows[3], $stickyRows[1]) 'p' 5) -eq 1) ((Get-StickyTopRows @($stickyRows[0], $stickyRows[3], $stickyRows[1]) 'p' 5) -as [string])
      }

      It 'is off without a mark or with a zero cap' {
        Expect ((Get-StickyTopRows $stickyRows '' 5) -eq 0) ''
        Expect ((Get-StickyTopRows $stickyRows 'p' 0) -eq 0) ''
      }

      It 'the pin guard reads the smaller of the sticky rows and what Rows leaves' {
        $stickyProbe = @{
          Name       = 'sticky-probe'
          Marks      = [ordered]@{ p = @{ Set = 'pin'; Unset = 'unpin'; Word = 'pinned'; Protected = $false } }
          SortMark   = 'p'
          StickyMark = 'p'
          StickyRows = 3
        }
        $script:Plugins = @($stickyProbe)
        Expect ((Get-PluginStickyCap 10) -eq 3) ([string](Get-PluginStickyCap 10))
        Expect ((Get-PluginStickyCap 2) -eq 1) ([string](Get-PluginStickyCap 2))
        $stickyProbe['StickyRows'] = -1
        Expect ((Get-PluginStickyCap 10) -eq 9) ([string](Get-PluginStickyCap 10))
        $stickyProbe['StickyRows'] = 0
        Expect ((Get-PluginStickyCap 10) -eq 0) ([string](Get-PluginStickyCap 10))
        $script:Plugins = @($markPlugin)
        $plan = Get-StickyPlan 10
        Expect (($plan.Mark -eq '') -and ($plan.Max -eq 0)) (($plan.Mark -as [string]) + '/' + ($plan.Max -as [string]))
      }
    }

    Describe 'item labels' {
      It 'collapses newlines and counts a file drop' {
        Expect ((Get-ItemLabel "a`r`nb" $false) -eq 'a b') (Get-ItemLabel "a`r`nb" $false)
        Expect ((Get-ItemLabel "a`nb" $true) -eq 'a <NL> b') (Get-ItemLabel "a`nb" $true)
        $files5 = ([string][char]1) + "C:\x\a.txt`nC:\x\b.txt`nC:\x\c.txt`nC:\x\d.txt`nC:\x\e.txt"
        Expect ((Get-ItemLabel $files5 $true) -eq '[files] a.txt, b.txt, c.txt (+2)') (Get-ItemLabel $files5 $true)
      }
    }

    # ------------------------------------------------------------ config schema
    Describe 'config values' {
      It 'a value is converted to what the schema asks for' {
        Expect ((Convert-IniValue 'ShowTime' 'on').Value -eq '1') ''
        Expect ((Convert-IniValue 'Autostart' 'off').Value -eq '0') ''
        Expect ((Convert-IniValue 'Rows' '12').Value -eq '12') ''
        Expect ((Convert-IniValue 'Theme' 'WIN11-LIGHT').Value -eq 'win11-light') ''
        Expect ((Convert-IniValue 'Plugins' 'item-marks, extra').Value -eq 'item-marks,extra') ''
        Expect ([string]$script:IniSchema['Animations'].Default -eq '1') ([string]$script:IniSchema['Animations'].Default)
      }

      It 'a value the schema cannot take is refused' {
        Expect (-not (Convert-IniValue 'ShowTime' 'maybe').Ok) ''
        Expect (-not (Convert-IniValue 'Rows' '1').Ok) ''
        Expect (-not (Convert-IniValue 'MaxItems' '999999999').Ok) ''
        Expect (-not (Convert-IniValue 'MaxItems' 'many').Ok) ''
        Expect (-not (Convert-IniValue 'Theme' 'blue').Ok) ''
        Expect (-not (Convert-IniValue 'ExcludePattern' '(').Ok) ''
        Expect (-not (Convert-IniValue 'Hotkey' 'Ctrl+Nope').Ok) ''
        Expect (-not (Convert-IniValue 'Plugins' 'a b').Ok) ''
        Expect (-not (Convert-IniValue 'Nope' '1').Ok) ''
      }
    }

    # -------------------------------------------------------------------- themes
    Describe 'themes' {
      It 'theme files are discovered and resolved by name' {
        $tn = @(Get-ThemeNames)
        Expect (($tn -contains 'win11-dark') -and ($tn -contains 'win11-light')) ($tn -join ',')
        Expect ((Resolve-ThemeName 'win11-light') -eq 'win11-light') ''
        Expect ((Resolve-ThemeName 'WIN11-DARK') -eq 'win11-dark') ''
        Expect ((Resolve-ThemeName 'nope') -eq 'win11-dark') ''
        Expect ($null -eq (Read-Theme 'nosuch')) ''
      }

      It 'the theme is an enum, so an alias is rejected' {
        Expect (-not (Convert-IniValue 'Theme' 'dark').Ok) ((Convert-IniValue 'Theme' 'dark').Error)
        Expect ((Convert-IniValue 'Theme' 'win11-light').Value -eq 'win11-light') ''
        Expect (-not (Convert-IniValue 'Theme' 'light').Ok) ((Convert-IniValue 'Theme' 'light').Error)
        Expect (-not (Convert-IniValue 'Theme' 'nosuch').Ok) ''
      }

      It 'a colour is parsed from its ini form' {
        Expect ((Convert-ThemeColor '#202020').R -eq 32) ''
        Expect ((Convert-ThemeColor '#1CFFFFFF').A -eq 28) ''
        Expect ($null -eq (Convert-ThemeColor 'red')) ''
      }

      It 'the dark palette' {
        $script:Theme = 'win11-dark'
        Apply-Theme
        $pal = Get-UiPalette
        Expect ($pal.Surface.ToArgb() -eq [Drawing.Color]::FromArgb(32, 32, 32).ToArgb()) $pal.Surface.ToString()
        Expect ($pal.Accent.ToArgb() -eq [Drawing.Color]::FromArgb(96, 205, 255).ToArgb()) $pal.Accent.ToString()
        Expect ($pal.Border.A -eq 22) ($pal.Border.A -as [string])
      }

      It 'the light palette and its fonts' {
        $script:Theme = 'win11-light'
        Apply-Theme
        $pal = Get-UiPalette
        Expect ($pal.Surface.ToArgb() -eq [Drawing.Color]::FromArgb(243, 243, 243).ToArgb()) $pal.Surface.ToString()
        Expect ($pal.Text.ToArgb() -eq [Drawing.Color]::FromArgb(26, 26, 26).ToArgb()) $pal.Text.ToString()
        Expect ($script:ThemeFonts.Count -ge 4) (($script:ThemeFonts.Keys | Sort-Object) -join ',')
        Expect ($script:Metric['RowHeight'] -eq 40) ($script:Metric['RowHeight'] -as [string])
      }

      It 'a theme can restyle row metrics without leaking them to the next' {
        # [metrics] in a theme restyles the rows; the next theme starts from the built-in table
        # again, so an override cannot leak from one theme into another
        $probeTheme = Join-Path $unitDir 'themes\probe-metrics.ini'
        [IO.File]::WriteAllLines($probeTheme, @('name = probe-metrics', '[metrics]', 'TimeWidth = 60', 'RowGap = 4'), $Utf8)
        try {
          $script:Theme = 'probe-metrics'
          Apply-Theme
          Expect (($script:Metric['TimeWidth'] -eq 60) -and ($script:Metric['RowGap'] -eq 4)) ($script:Metric['TimeWidth'] -as [string])
          $script:Theme = 'win11-light'
          Apply-Theme
          $leaked = @()
          foreach ($k in @($script:MetricDefault.Keys)) {
            if ([int]$script:Metric[$k] -ne [int]$script:MetricDefault[$k]) { $leaked += $k }
          }
          Expect ($leaked.Count -eq 0) ($leaked -join ', ')
        } finally { Remove-Item -LiteralPath $probeTheme -Force -ErrorAction SilentlyContinue }
      }

      It 'an unknown theme resolves to the default' {
        $script:Theme = 'nosuch-theme'
        Apply-Theme
        Expect (($script:Theme -eq 'win11-dark') -and ((Get-UiPalette).Surface.ToArgb() -eq [Drawing.Color]::FromArgb(32, 32, 32).ToArgb())) $script:Theme
      }
    }

    # ---- writing the settings file, and applying it
    # the rows below still write this file by hand, so the path stays at script level
    $cfg = $script:UnitCfg

    Describe 'settings writes' {
      It 'Set-IniKey replaces, appends and keeps the rest' {
        $cfg = $script:UnitCfg
        [IO.File]::WriteAllLines($cfg, @('# keep me', 'Theme=dark', 'MaxItems=7'), $Utf8)
        [void](Set-IniKey 'Theme' 'win11-light')
        [void](Set-IniKey 'ShowTime' '0')
        $iniText = [IO.File]::ReadAllText($cfg)
        Expect ($iniText -match '(?m)^Theme=win11-light\r?$') ''
        Expect ($iniText -match '(?m)^ShowTime=0\r?$') ''
        Expect ($iniText -match '# keep me') ''
        Expect ($iniText -match '(?m)^MaxItems=7\r?$') ''
        Expect ((Get-IniKey 'Theme') -eq 'win11-light') (Get-IniKey 'Theme')
      }

      It 'Apply-Config installs what the file says' {
        $cfg = $script:UnitCfg
        [IO.File]::WriteAllLines($cfg, @('Theme=win11-light', 'ShowTime=0', 'MaxItems=7'), $Utf8)
        Apply-Config
        Expect ($script:Theme -eq 'win11-light') $script:Theme
        Expect (-not $script:ShowTime) ''
        Expect ($MaxItems -eq 7) ($MaxItems -as [string])
        Expect ($script:Autostart -and $script:DesktopShortcut) ''
      }

      It 'Apply-Config refuses an out of range value and keeps the defaults' {
        $cfg = $script:UnitCfg
        [IO.File]::WriteAllLines($cfg, @('Rows=1', 'MaxItems=0', 'Highlight=abc'), $Utf8)
        Apply-Config
        Expect (($script:Rows -eq 10) -and ($MaxItems -eq 300) -and $script:HighlightOn) ('rows=' + $script:Rows + ' items=' + $MaxItems)
      }

      It 'every schema key points at a live variable holding its default' {
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
        Expect ($noRef.Count -eq 0) ($noRef -join ', ')
        Expect ($drifting.Count -eq 0) (($drifting | Select-Object -First 4) -join '; ')
      }
    }

    # ------------------------------------------------------- entry kinds / glyphs
    Describe 'entry kinds' {
      It 'the base tells a file list from text' {
        # finer typing is a plugin job
        Expect ((Get-EntryKind 'plain words') -eq 'text') ''
        Expect ((Get-EntryKind 'https://a.b/c') -eq 'text') ''
        Expect ((Get-EntryKind (([string][char]1) + 'C:\a.txt')) -eq 'files') ''
        Expect ((Get-EntryKind '') -eq 'empty') ''
      }

      It 'a file payload yields its paths' {
        # a file list carries paths, one per line
        $fpay = ([string][char]1) + 'C:\one.txt' + "`n" + 'C:\two words.txt'
        $fpaths = @(Get-FilePayloadPaths $fpay)
        Expect (($fpaths.Count -eq 2) -and ($fpaths[1] -eq 'C:\two words.txt')) ($fpaths -join '|')
        Expect (@(Get-FilePayloadPaths 'hello').Count -eq 0) ''
      }

      It 'a pasted file list also carries text unless that is switched off' {
        $fpay = ([string][char]1) + 'C:\one.txt' + "`n" + 'C:\two words.txt'
        Load-Forms
        $pasteBoth = $false
        try { [void](Set-ClipItem $fpay ''); $pasteBoth = ([Windows.Forms.Clipboard]::ContainsFileDropList()) -and ([Windows.Forms.Clipboard]::ContainsText()) } catch { }
        Expect $pasteBoth ''
        $saved = $script:PasteFilesAsText
        try {
          $script:PasteFilesAsText = $false
          $dropOnly = $false
          try { [void](Set-ClipItem $fpay ''); $dropOnly = ([Windows.Forms.Clipboard]::ContainsFileDropList()) -and (-not [Windows.Forms.Clipboard]::ContainsText()) } catch { }
          Expect $dropOnly ''
        } finally { $script:PasteFilesAsText = $saved }
      }

      It 'no plugin means no row icon' {
        # typing an entry is a plugin's job
        $script:Plugins = @()
        Expect ((Get-RowGlyph 'https://a.b/c') -eq '') (Get-RowGlyph 'https://a.b/c')
        Expect ((Get-RowGlyph (([string][char]1) + 'C:\a.txt')) -eq '') ''
      }
    }

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

    Describe 'the plugin loader' {
      It 'only the listed files load, in the listed order' {
        Expect (@(Load-Plugins $pdir @()).Count -eq 0) ''
        Expect ((@(Load-Plugins $pdir @('one') | ForEach-Object { $_.Name }) -join ',') -eq 'one') ''
        Expect (@(Load-Plugins $pdir @('ONE')).Count -eq 1) ''
        Expect ((@(Load-Plugins $pdir @('two', 'one') | ForEach-Object { $_.Name } | Sort-Object) -join ',') -eq 'one,two') ''
        Expect ((@(Load-Plugins $pdir @('two', 'one') | ForEach-Object { $_.Name }) -join ',') -eq 'two,one') (@(Load-Plugins $pdir @('two', 'one') | ForEach-Object { $_.Name }) -join ',')
      }

      It 'a nameless or broken plugin is skipped' {
        Expect (@(Load-Plugins $pdir @('nameless')).Count -eq 0) ''
        Expect (@(Load-Plugins $pdir @('boom')).Count -eq 0) ''
      }

      It 'a missing plugin is reported by name' {
        [void](Load-Plugins $pdir @('nosuch', 'one'))
        Expect ((@(Get-PluginMissingNames) -join ',') -eq 'nosuch') (@(Get-PluginMissingNames) -join ',')
        Expect ((@(Load-Plugins (Join-Path $unitDir 'nope') @('x')).Count -eq 0) -and ((@(Get-PluginMissingNames) -join ',') -eq 'x')) ''
      }
    }

    $script:Plugins = @(Load-Plugins $pdir @('one', 'two'))

    Describe 'plugin hooks' {
      It 'a command is looked up by name' {
        Expect ((Get-PluginCommand 'hi') -is [scriptblock]) ''
        Expect ($null -eq (Get-PluginCommand 'nope')) ''
      }

      It 'a context menu entry is collected and tested' {
        $acts = @(Get-PluginActions)
        Expect (($acts.Count -eq 1) -and ($acts[0].Label -eq 'Do')) ($acts.Count -as [string])
        $rec = [pscustomobject]@{ Payload = 'https://a.b/c'; Flags = 't'; Time = 0; DelIndex = 0 }
        Expect (Test-PluginAction $acts[0] $rec) ''
        # anything that is not a menu entry matches nothing
        Expect (-not (Test-PluginAction 'x' $rec)) ''
      }

      It 'a panel key is collected and needs its modifiers' {
        $keys = @(Get-PluginPanelKeys)
        Expect (($keys.Count -eq 1) -and ($keys[0].Key -eq 'O') -and $keys[0].Ctrl -and ($keys[0].Plugin -eq 'one')) ($keys.Count -as [string])
        Expect ($null -ne (Get-PluginPanelKey 'O' $true $false $false)) ''
        Expect ($null -eq (Get-PluginPanelKey 'O' $false $false $false)) ''
        Expect ($null -eq (Get-PluginPanelKey 'Q' $true $false $false)) ''
      }

      It 'the init hook runs once and only once' {
        $script:PluginInitDone = $false
        $global:cbInitRan = 0
        Invoke-PluginInit
        Expect ($global:cbInitRan -eq 1) ([string]$global:cbInitRan)
        $global:cbInitRan = 0
        Invoke-PluginInit
        Expect ($global:cbInitRan -eq 0) ([string]$global:cbInitRan)
        $global:cbInitRan = 0
      }

      It 'a plugin glyph block wins over the base' {
        Expect ((Get-EntryGlyph 'https://a.b/c') -eq 'L') (Get-EntryGlyph 'https://a.b/c')
      }
    }

    Describe 'base glyphs' {
      It 'the base never paints an icon of its own' {
        $script:Plugins = @()
        Expect ((Get-RowGlyph 'https://a.b/c') -eq '') (Get-RowGlyph 'https://a.b/c')
        Expect ((Get-RowGlyph 'function Foo { 1 }') -eq '') (Get-RowGlyph 'function Foo { 1 }')
        Expect ((Get-RowGlyph (([string][char]1) + 'C:\a.txt')) -eq '') ''
      }
    }

    # the shipped plugin is opt-in and loads by file name
    Describe 'the shipped plugin' {
      It 'is opt-in, loads by name and supplies commands, a key and an icon' {
        Expect (@(Load-Plugins (Join-Path $srcRoot 'plugins') @()).Count -eq 0) ''
        $real = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('entry-actions'))
        Expect ((@($real | ForEach-Object { $_.Name }) -join ',') -eq 'entry-actions') (@($real | ForEach-Object { $_.Name }) -join ',')
        $script:Plugins = $real
        Expect ((Get-PluginCommand 'open') -is [scriptblock]) ''
        Expect ((Get-PluginCommand 'kind') -is [scriptblock]) ''
        Expect ($null -ne (Get-PluginPanelKey 'O' $true $false $false)) ''
        Expect ((Get-RowGlyph 'https://a.b/c') -ne '') (Get-RowGlyph 'https://a.b/c')
        # a link is typed before a path
        Expect ((Get-RowGlyph 'https://a.b/c') -ne (Get-RowGlyph 'C:\temp\a.txt')) ((Get-RowGlyph 'https://a.b/c') + ' vs ' + (Get-RowGlyph 'C:\temp\a.txt'))
      }
    }

    # -------------------------------------------------- plugin settings (own keys)
    $script:Plugins = @(Load-Plugins $pdir @('one'))
    Register-PluginSettings

    Describe 'plugin settings' {
      It 'a plugin setting joins the schema and validates like a base key' {
        Expect ($script:IniSchema.Contains('one.Flag')) ''
        Expect ((Convert-IniValue 'one.Flag' 'on').Value -eq '1') ''
        Expect (-not (Convert-IniValue 'one.Flag' 'maybe').Ok) ''
      }

      It 'a plugin setting reads its ini value and falls back on a bad one' {
        [IO.File]::WriteAllLines($cfg, @('one.Flag=1'), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
        Expect ((Get-PluginSetting 'one' 'Flag') -eq '1') (Get-PluginSetting 'one' 'Flag')
        [IO.File]::WriteAllLines($cfg, @('one.Flag=maybe'), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
        Expect ((Get-PluginSetting 'one' 'Flag') -eq '0') (Get-PluginSetting 'one' 'Flag')
        Expect ((Get-PluginSetting 'one' 'Nope') -eq '') ''
      }
    }

    Describe 'the shipped plugin settings' {
      It 'declares its own keys with the shipped defaults' {
        $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('entry-actions'))
        Register-PluginSettings
        [IO.File]::WriteAllLines($cfg, @(), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
        Expect (($script:IniSchema.Contains('entry-actions.Browser')) -and ($script:IniSchema.Contains('entry-actions.Reveal'))) ''
        Expect ((Get-PluginSetting 'entry-actions' 'Reveal') -eq '1') (Get-PluginSetting 'entry-actions' 'Reveal')
        Expect ((Get-PluginSetting 'entry-actions' 'Browser') -eq '') ''
        $script:Plugins = @()
      }
    }

    # ------------------------------------------------------ plugin lifecycle hooks
    $script:Plugins = @(Load-Plugins $pdir @('one'))
    $decorRec = [pscustomobject]@{ Payload = 'x'; Time = 0; Marks = 's' }

    Describe 'plugin lifecycle hooks' {
      It 'RowDecor adds marks and colours to a row' {
        $dec = Get-PluginRowDecor $decorRec
        Expect (($dec.Marks.Count -eq 1) -and ($dec.Marks[0].Glyph -eq 'M')) ($dec.Marks.Count -as [string])
        Expect ($dec.Marks[0].Color -eq '#112233') $dec.Marks[0].Color
        Expect ($dec.TextColor -eq '#445566') $dec.TextColor
        Expect (-not $dec.ContainsKey('Emphasis')) ''
        Expect (((Get-PluginRowDecor ([pscustomobject]@{ Payload = 'x'; Marks = '' })).Marks).Count -eq 0) ''
      }

      It 'Transform and Tick hooks run' {
        Expect ((Invoke-PluginTransform 'abc') -eq 'T:abc') (Invoke-PluginTransform 'abc')
        $ticks = @(Get-PluginTicks)
        Expect (($ticks.Count -eq 1) -and ($ticks[0].Name -eq 'one') -and ($ticks[0].Seconds -eq 5)) ($ticks.Count -as [string])
        # a tick is throttled until its interval has passed
        Expect ($script:PluginTimers.Count -eq 0) ''
        Invoke-PluginTicks
        Expect ($script:PluginTimers.ContainsKey('tick:one')) ''
      }

      It 'with no plugin every hook is a no-op' {
        $script:Plugins = @()
        Expect ((Invoke-PluginTransform 'abc') -eq 'abc') ''
        Expect (((Get-PluginRowDecor $decorRec).Marks).Count -eq 0) ''
        Expect (@(Get-PluginTicks).Count -eq 0) ''
      }
    }

    # ------------------------------------------ shipped plugins share their own logic
    Describe 'plugin tick and menu shapes' {
      It 'a Tick interval may be a scriptblock' {
        # computed at runtime, so a plugin needs no timer state
        $script:Plugins = @(@{ Name = 'timed'; Tick = @{ Seconds = { 120 }; Action = { param($now) } } })
        $timed = @(Get-PluginTicks)
        Expect (($timed.Count -eq 1) -and ($timed[0].Seconds -eq 120)) ($timed[0].Seconds -as [string])
        $script:Plugins = @()
      }

      It 'a ContextMenu may be a scriptblock, and a broken one is skipped' {
        # a plugin may build its menu items at load time, so one setting can produce several
        $script:Plugins = @(@{
            Name        = 'dyn'
            ContextMenu = { @(@{ Label = 'A'; Invoke = { param($r) } }, @{ Label = 'B'; Invoke = { param($r) } }) }
          })
        $dyn = @(Get-PluginActions)
        Expect (($dyn.Count -eq 2) -and ($dyn[0]['Label'] -eq 'A') -and ($dyn[1]['Plugin'] -eq 'dyn')) ($dyn.Count -as [string])
        $script:Plugins = @(@{ Name = 'boom'; ContextMenu = { throw 'boom' } })
        Expect (@(Get-PluginActions).Count -eq 0) ''
        $script:Plugins = @()
      }
    }

    Describe 'the item-marks menu' {
      BeforeAll { $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('item-marks')) }

      It 'every entry resolves its own caption' {
        $menuActs = @(Get-PluginActions)
        $allMarks = [pscustomobject]@{ Payload = 'x'; Time = 0; Marks = 'psh' }
        $noMarks = [pscustomobject]@{ Payload = 'x'; Time = 0; Marks = '' }
        Expect ((@($menuActs | ForEach-Object { Get-ActionText $_ $allMarks }) -join '|') -eq 'Remove pin|Remove star|Clear highlight') (@($menuActs | ForEach-Object { Get-ActionText $_ $allMarks }) -join '|')
        Expect ((@($menuActs | ForEach-Object { Get-ActionText $_ $noMarks }) -join '|') -eq 'Pin to top|Star|Highlight') (@($menuActs | ForEach-Object { Get-ActionText $_ $noMarks }) -join '|')
        # a static label wins, and a missing or throwing one falls back
        Expect ((Get-ActionText @{ Label = 'Open' } $null) -eq 'Open') ''
        Expect ((Get-ActionText @{} $null) -eq 'Plugin action') ''
        Expect ((Get-ActionText @{ Label = { throw 'boom' } } $null) -eq 'Plugin action') ''
      }

      It 'the entries carry their owner' {
        $menuActs = @(Get-PluginActions)
        Expect ((@($menuActs | ForEach-Object { $_['Plugin'] } | Select-Object -Unique) -join ',') -eq 'item-marks') (@($menuActs | ForEach-Object { $_['Plugin'] } | Select-Object -Unique) -join ',')
      }
    }

    Describe 'the transform plugin' {
      BeforeAll {
        $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('transform'))
        Register-PluginSettings
      }

      It 'exposes one rewrite block and reports the configured mode' {
        [IO.File]::WriteAllLines($cfg, @('transform.Mode=snake'), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
        $apply = Get-PluginData 'transform' 'Apply'
        Expect ($apply -is [scriptblock]) ''
        Expect ((Invoke-PluginTransform 'Hello World') -eq (& $apply 'Hello World' 'snake')) (Invoke-PluginTransform 'Hello World')
        # a file list is never rewritten
        Expect ((& $apply (([string][char]1) + 'C:\a.txt') 'upper') -eq (([string][char]1) + 'C:\a.txt')) ''
        Expect ((& (Get-PluginData 'transform' 'CurrentMode')) -eq 'snake') (& (Get-PluginData 'transform' 'CurrentMode'))
      }

      It 'lists every mode by default and only for text rows' {
        [IO.File]::WriteAllLines($cfg, @('transform.Mode=snake'), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
        $tActs = @(Get-PluginActions)
        Expect (($tActs.Count -eq 7) -and ($tActs[0]['Plugin'] -eq 'transform')) ($tActs.Count -as [string])
        $tMenu = $tActs[0]
        Expect ((Get-ActionText $tMenu ([pscustomobject]@{ Payload = 'Hello World'; Marks = '' })) -eq 'Transform as plain text') (Get-ActionText $tMenu ([pscustomobject]@{ Payload = 'Hello World'; Marks = '' }))
        Expect ((Test-PluginAction $tMenu ([pscustomobject]@{ Payload = 'Hello World'; Marks = '' })) -eq $true) ''
        Expect ((Test-PluginAction $tMenu ([pscustomobject]@{ Payload = (([string][char]1) + 'C:\a.txt'); Marks = '' })) -eq $false) ''
        Expect ((Test-PluginAction $tMenu ([pscustomobject]@{ Payload = ''; Marks = '' })) -eq $false) ''
        Expect ((Test-PluginAction $tMenu $null) -eq $false) ''
      }

      It 'the Modes setting decides the entries, in the written order' {
        # and each entry rewrites with its own mode while the paste mode stays put
        $tRow = [pscustomobject]@{ Payload = 'Hello World demo'; Marks = '' }
        [IO.File]::WriteAllLines($cfg, @('transform.Mode=keep', 'transform.Modes=upper, kebab ,snake'), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
        $tActs = @(Get-PluginActions)
        Expect ($tActs.Count -eq 3) ($tActs.Count -as [string])
        Expect ((@($tActs | ForEach-Object { Get-ActionText $_ $tRow }) -join '|') -eq 'Transform as UPPER|Transform as kebab-case|Transform as snake_case') (@($tActs | ForEach-Object { Get-ActionText $_ $tRow }) -join '|')
        Expect ((Test-PluginAction $tActs[0] $tRow) -eq $true) ''
        [void](& $tActs[1]['Invoke'] $tRow)
        Expect ([string](@(Get-Records)[0].Payload) -eq 'hello-world-demo') ([string](@(Get-Records)[0].Payload))
      }

      It 'an unknown Modes value falls back to every mode and is reported' {
        [IO.File]::WriteAllLines($cfg, @('transform.Mode=snake', 'transform.Modes=foo,snake'), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
        Expect ((@(Get-PluginActions).Count -eq 7) -and (@(Get-ConfigProblems).Count -ge 1)) (@(Get-PluginActions).Count -as [string])
      }

      It 'a Modes list of only keep is reported once and keeps the default list' {
        [IO.File]::WriteAllLines($cfg, @('transform.Mode=keep', 'transform.Modes=keep'), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
        Expect (@(Get-ConfigProblems | Where-Object { $_ -match '^transform\.Modes=' }).Count -eq 1) (@(Get-ConfigProblems) -join ';')
        Expect (@(Get-PluginActions).Count -eq 7) (@(Get-PluginActions).Count -as [string])
        [IO.File]::WriteAllLines($cfg, @('transform.Mode=snake', 'transform.Modes=snake'), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
      }
    }

    # several items from one plugin stay one block: a setting changes the count, the
    # grouping follows the plugin, and the plugins follow the load order
    Describe 'the plugin menu groups by owner' {
      It 'items from one plugin stay one block' {
        # a setting changes the count, the grouping follows the plugin
        $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('item-marks', 'transform'))
        Register-PluginSettings
        [IO.File]::WriteAllLines($cfg, @('transform.Modes=upper,snake,kebab'), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
        $owners = @(Get-PluginActions | ForEach-Object { [string]$_['Plugin'] })
        Expect (($owners -join ',') -eq 'item-marks,item-marks,item-marks,transform,transform,transform') ($owners -join ',')
        Expect ((@($owners | Select-Object -Unique) -join ',') -eq 'item-marks,transform') (@($owners | Select-Object -Unique) -join ',')
      }

      It 'the load order follows the Plugins list' {
        $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('transform', 'item-marks'))
        Register-PluginSettings
        [IO.File]::WriteAllLines($cfg, @('transform.Mode=snake'), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
        $owners = @(Get-PluginActions | ForEach-Object { [string]$_['Plugin'] })
        $blocks = @()
        foreach ($o in $owners) { if ($blocks.Count -eq 0 -or $blocks[-1] -ne $o) { $blocks += $o } }
        Expect (($blocks -join ',') -eq 'transform,item-marks') ($blocks -join ',')
        $names = @($script:Plugins | ForEach-Object { [string]$_['Name'] })
        Expect (($names -join ',') -eq 'transform,item-marks') ($names -join ',')
        $script:Plugins = @()
      }
    }

    Describe 'the entry-actions plugin' {
      BeforeAll {
        $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('entry-actions'))
        Register-PluginSettings
        [IO.File]::WriteAllLines($cfg, @(), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
      }

      It 'the open rule accepts a link and a file list, never plain text' {
        $canOpen = Get-PluginData 'entry-actions' 'CanOpen'
        Expect ((& $canOpen ([pscustomobject]@{ Payload = 'https://a.b/c' })) -eq $true) ''
        Expect ((& $canOpen ([pscustomobject]@{ Payload = 'hello world' })) -eq $false) ''
        Expect ((& $canOpen ([pscustomobject]@{ Payload = (([string][char]1) + 'C:\a.txt') })) -eq $true) ''
        Expect ((& $canOpen $null) -eq $false) ''
      }

      It 'the sniffers live in one block' {
        Expect (((& (Get-PluginData 'entry-actions' 'Sniff') '{"a":1}') -join ',') -match 'json') ''
      }
    }

    # retention: protected rows survive, the sort mark can be kept too
    Describe 'the retention plugin' {
      It 'drops the unprotected old rows and keeps the protected ones' {
        $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('item-marks', 'retention'))
        Register-PluginSettings
        [IO.File]::WriteAllLines($cfg, @('retention.MaxAgeDays=1', 'retention.KeepPinned=1'), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
        $nowSec = Get-Epoch
        $old = $nowSec - (3 * 86400)
        $age = New-Object System.Collections.Generic.List[object]
        $age.Add((New-Record 'old-plain' $old ''))
        $age.Add((New-Record 'old-star' $old 's'))
        $age.Add((New-Record 'old-pin' $old 'p'))
        $age.Add((New-Record 'fresh' $nowSec ''))
        Save-Records $age.ToArray()
        $dropped = [int](& (Get-PluginData 'retention' 'Sweep'))
        $leftSet = (@((Get-Records) | ForEach-Object { $_.Payload }) | Sort-Object) -join ','
        Expect ($dropped -eq 1) ([string]$dropped)
        Expect ($leftSet -eq 'fresh,old-pin,old-star') $leftSet
        # switched off, nothing is removed
        [IO.File]::WriteAllLines($cfg, @('retention.MaxAgeDays=0'), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
        Expect ((& (Get-PluginData 'retention' 'Sweep')) -eq 0) ''
        $script:Plugins = @()
        Use-StoreLock { Save-Records @() }
      }
    }

    # ----------------------------------------------- protected marks and the store
    $script:Plugins = @($markPlugin)

    Describe 'protected marks' {
      It 'a mark can be set, survives a reload and blocks a delete' {
        Use-StoreLock { Save-Records @() }
        Add-Item 'star-me'
        $r0 = @(Get-Records)[0]
        Expect ([string]$r0.Marks -eq '') ([string]$r0.Marks)
        Expect (Set-Mark 'star-me' 's' $true) ''
        Expect (Test-Mark @(Get-Records)[0] 's') ''
        Expect (-not (Set-Mark 'star-me' 's' $true)) ''
        Expect ((Remove-Record 'star-me') -eq 'protected:s') (Remove-Record 'star-me')
        Expect ((Remove-Record 'star-me' -Force) -eq 'removed') ''
      }

      It 'trim keeps a protected row' {
        $tl = New-Object System.Collections.Generic.List[object]
        $tl.Add((New-Record 'keep-star' 1 's'))
        $tl.Add((New-Record 'drop-1' 2 ''))
        $tl.Add((New-Record 'drop-2' 3 ''))
        $saved = $script:MaxItems
        try {
          $script:MaxItems = 1
          Trim-Records $tl
        } finally { $script:MaxItems = $saved }
        Expect (($tl.Count -eq 1) -and ($tl[0].Payload -eq 'keep-star')) (($tl | ForEach-Object { $_.Payload }) -join ',')
      }

      It 'clear keeps a protected row' {
        Use-StoreLock { Save-Records @() }
        Add-Item 'keep-on-clear'
        [void](Set-Mark 'keep-on-clear' 's' $true)
        Add-Item 'drop-on-clear'
        Clear-Store (Get-ClearKeepMarks)
        Expect (((@(Get-Records) | ForEach-Object { $_.Payload }) -join ',') -eq 'keep-on-clear') (((@(Get-Records) | ForEach-Object { $_.Payload }) -join ','))
        Use-StoreLock { Save-Records @() }
      }
    }

    Describe 'an undeclared mark' {
      It 'is stored, printed and dropped like any other row' {
        # a mark nobody protects goes through the flag string and blocks nothing
        Add-Item 'mark-me'
        $h0 = @(Get-Records)[0]
        Expect (-not (Test-Mark $h0 'h')) ''
        Expect (Set-Mark 'mark-me' 'h' $true) ''
        Expect (Test-Mark @(Get-Records)[0] 'h') ''
        $rawStore = [IO.File]::ReadAllText($StoreFile)
        Expect ($rawStore.Contains([string][char]30 + 'th' + [string][char]31)) ''
        Expect (-not (Set-Mark 'mark-me' 'h' $true)) ''
        Expect ((Remove-Record 'mark-me') -eq 'removed') ''
        Add-Item 'mark-clear'
        [void](Set-Mark 'mark-clear' 'h' $true)
        Clear-Store (Get-ClearKeepMarks -All)
        Expect (@(Get-Records).Count -eq 0) ([string]@(Get-Records).Count)
        $script:Plugins = @()
        Use-StoreLock { Save-Records @() }
      }
    }

    # -------------------------------------- theme is a package, not ini colour knobs
    Describe 'a theme is a package' {
      It 'theme colours are not ini keys and the palette comes from the file' {
        [IO.File]::WriteAllLines($cfg, @('Theme.Accent=#FF6600'), $Utf8)
        $script:IniCache = $null
        $script:Theme = 'win11-dark'
        Apply-Theme
        try {
          Expect (-not $script:IniSchema.Contains('Theme.Accent')) ''
          Expect ((Get-UiPalette).Accent.ToArgb() -eq [Drawing.Color]::FromArgb(96, 205, 255).ToArgb()) (Get-UiPalette).Accent.ToString()
          Expect ((Get-UiPalette).Surface.ToArgb() -eq [Drawing.Color]::FromArgb(32, 32, 32).ToArgb()) (Get-UiPalette).Surface.ToString()
        } finally {
          [IO.File]::WriteAllLines($cfg, @(), $Utf8)
          $script:IniCache = $null
          Apply-Theme
        }
      }

      It 'the palette still switches by name' {
        $script:Theme = 'win11-light'
        Apply-Theme
        Expect ((Get-UiPalette).Surface.ToArgb() -eq [Drawing.Color]::FromArgb(243, 243, 243).ToArgb()) (Get-UiPalette).Surface.ToString()
      }
    }

    # the plugin whose colours all come from the theme
    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('item-marks'))
    Register-PluginSettings
    Register-PluginThemeSettings
    Apply-PluginSettings
    Apply-PluginTheme
    $hrec = [pscustomobject]@{ Payload = 'hi'; Time = 0; Marks = 'h' }

    Describe 'a plugin reads its colours from the theme' {
      It 'ThemeSettings restyle the plugin marks' {
        Expect ((Get-PluginTheme 'item-marks' 'StarColor') -eq '#9D5D00') (Get-PluginTheme 'item-marks' 'StarColor')
        Expect ((Get-PluginTheme 'item-marks' 'EmphasisInk') -eq '#005FB8') (Get-PluginTheme 'item-marks' 'EmphasisInk')
        $hdec = Get-PluginRowDecor $hrec
        Expect ($hdec.TextColor -eq '#005FB8') $hdec.TextColor
        Expect ($hdec.BackColor -eq '#24005FB8') $hdec.BackColor
      }

      It 'the highlight colours are theme items, not ini keys' {
        Expect (-not $script:IniSchema.Contains('item-marks.HighlightColor')) ''
        Expect (-not $script:IniSchema.Contains('item-marks.HighlightBg')) ''
        Expect (($script:PluginThemeValues.ContainsKey('item-marks.EmphasisInk')) -and ($script:PluginThemeValues.ContainsKey('item-marks.EmphasisFill'))) ''
        $hdec = Get-PluginRowDecor $hrec
        Expect ($hdec.TextColor -eq (Get-PluginTheme 'item-marks' 'EmphasisInk')) $hdec.TextColor
        Expect ($hdec.BackColor -eq (Get-PluginTheme 'item-marks' 'EmphasisFill')) $hdec.BackColor
      }

      It 'a stale ini highlight key is ignored' {
        # an ini line with the old key does not stop the theme from painting the row
        $hdec = Get-PluginRowDecor $hrec
        [IO.File]::WriteAllLines($cfg, @('item-marks.HighlightColor=#123456', 'item-marks.HighlightBg=#99123456'), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
        $idec = Get-PluginRowDecor $hrec
        try {
          Expect (($idec.TextColor -eq $hdec.TextColor) -and ($idec.BackColor -eq $hdec.BackColor)) ($idec.TextColor + ' / ' + $idec.BackColor)
        } finally {
          [IO.File]::WriteAllLines($cfg, @(), $Utf8)
          $script:IniCache = $null
          Apply-PluginSettings
        }
      }

      It 'pin and star become glyph marks, not a leading bar' {
        $prec = [pscustomobject]@{ Payload = 'hi'; Time = 0; Marks = 'ps' }
        $pdec = Get-PluginRowDecor $prec
        Expect ($pdec.Marks.Count -eq 2) ($pdec.Marks.Count -as [string])
        Expect (-not $pdec.ContainsKey('Emphasis')) ''
      }

      It 'a theme never becomes an ini key' {
        Expect (-not $script:IniSchema.Contains('item-marks.StarGlyph')) ''
        Expect (-not $script:IniSchema.Contains('item-marks.StarColor')) ''
        $script:Plugins = @()
        $script:Theme = 'win11-dark'
        Apply-Theme
      }
    }

    Describe 'ThemeSettings fall back to the plugin default' {
      It 'when the theme has no section for the plugin' {
        $script:Theme = 'win11-dark'
        Apply-Theme
        $script:ThemeOverrides = @{}
        $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('item-marks'))
        Register-PluginThemeSettings
        Apply-PluginTheme
        Expect ((Get-PluginTheme 'item-marks' 'StarGlyph') -eq [string][char]0xE735) ''
        $script:Plugins = @()
      }
    }

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

      Describe 'the drawing helpers' {
        It 'run on a plain bitmap' {
          $drawOk = $true
          $drawErr = ''
          $bmp = New-Object Drawing.Bitmap 240, 48
          $gfx = [Drawing.Graphics]::FromImage($bmp)
          try {
            Draw-KeyChips $gfx 4 18 @(@('Enter', 'Paste'), @('Esc', 'Close')) ([Drawing.Color]::Gray) ([Drawing.Color]::DimGray) 240
            Draw-Highlight $gfx 'hello world' (New-Object Drawing.RectangleF 0, 0, 120, 20) @('wor') ([Drawing.Brushes]::White) ([Drawing.Brushes]::Yellow)
          } catch {
            $drawOk = $false
            $drawErr = $_.Exception.Message
          } finally {
            $gfx.Dispose()
            $bmp.Dispose()
          }
          Expect $drawOk $drawErr
        }

        It 'a flattened single hint pair still draws a chip' {
          # one hint pair reaches the function flattened by PowerShell's list handling; it must
          # still be drawn as [Esc] Close instead of three single-character chips
          $flatOk = $true
          $flatErr = ''
          $bmp = New-Object Drawing.Bitmap 240, 48
          $gfx = [Drawing.Graphics]::FromImage($bmp)
          try {
            Draw-KeyChips $gfx 4 18 @('Esc', 'Close') ([Drawing.Color]::Gray) ([Drawing.Color]::DimGray) 240
            $col = $bmp.GetPixel(8, 18)
            if ($col.R -eq 0 -and $col.G -eq 0 -and $col.B -eq 0) { throw 'nothing was drawn' }
          } catch {
            $flatOk = $false
            $flatErr = $_.Exception.Message
          } finally {
            $gfx.Dispose()
            $bmp.Dispose()
          }
          Expect $flatOk $flatErr
        }
      }

      Describe 'the hint footer' {
        It 'a text row offers paste, copy, edit and delete' {
          $hSingle = Get-HintText (Get-PanelHints 5 0 $true 0 $false @())
          Expect ((($hSingle -match 'Enter') -and ($hSingle -match 'Paste')) -and (($hSingle -match 'F2') -and ($hSingle -match 'Edit')) -and (($hSingle -match 'Del') -and ($hSingle -match 'Delete')) -and ($hSingle -match 'Close')) $hSingle
          $hPic = Get-HintText (Get-PanelHints 5 0 $false 0 $false @())
          Expect ((-not ($hPic -match 'Edit')) -and ($hPic -match 'Paste')) $hPic
        }

        It 'only a plain text row can be edited' {
          $picRec = New-Record (New-ImagePayload $png 2 2 'PNG') 1 ''
          Expect (-not (Test-RowEditable $picRec)) (Get-RowEditBlock $picRec)
          $listRec = New-Record (([string][char]1) + 'C:\a.txt') 1 ''
          Expect (-not (Test-RowEditable $listRec)) (Get-RowEditBlock $listRec)
          $fmtRec = New-Record 'hello' 1 ''
          $fmtRec.Rich = 'H1'
          Expect (-not (Test-RowEditable $fmtRec)) (Get-RowEditBlock $fmtRec)
          Expect (Test-RowEditable (New-Record 'hello' 1 '')) ''
        }

        It 'a batch and a search trim the footer' {
          $hMulti = Get-HintText (Get-PanelHints 5 3 $true 0 $false @())
          Expect ((($hMulti -match 'Copy 3') -and ($hMulti -match 'Delete 3')) -and (-not ($hMulti -match 'Paste')) -and (-not ($hMulti -match 'Edit'))) $hMulti
          $hQuery = Get-HintText (Get-PanelHints 5 0 $true 4 $false @())
          Expect (($hQuery -match 'Clear') -and (-not ($hQuery -match 'Close'))) $hQuery
          $hEmpty = Get-HintText (Get-PanelHints 0 0 $false 0 $false @())
          Expect (($hEmpty -match 'Close') -and (-not ($hEmpty -match 'Paste'))) $hEmpty
        }

        It 'the Ctrl footer counts a batch and lists one pair per chip' {
          $hCtrl = Get-HintText (Get-PanelHints 5 3 $true 0 $true @() $false $true)
          Expect (($hCtrl -match 'Copy 3') -and ($hCtrl -match 'Undo')) $hCtrl
          # a flattened first pair drew [Ctrl+Enter Copy] as one chip
          $ctrlPairs = @(Get-PanelHints 5 3 $true 0 $true @(@{ Key = 'O'; Hint = 'Open' }) $false $true)
          $shapeOk = $ctrlPairs.Count -gt 0
          foreach ($p in $ctrlPairs) {
            if ($p -isnot [array] -or @($p).Count -ne 2) { $shapeOk = $false }
          }
          $pluginChip = @($ctrlPairs | Where-Object { @($_)[0] -eq 'Ctrl+O' })
          if ($pluginChip.Count -ne 1 -or [string](@($pluginChip[0])[1]) -ne 'Open') { $shapeOk = $false }
          Expect $shapeOk ((@($ctrlPairs | ForEach-Object { @($_).Count }) -join ','))
          $hNoUndo = Get-HintText (Get-PanelHints 5 0 $true 0 $true @() $false $false)
          Expect (-not ($hNoUndo -match 'Undo')) $hNoUndo
        }

        It 'the compact footer keeps three chips and no count row' {
          $hCompact = Get-HintText (Get-PanelHints 5 0 $true 0 $false @() $false $true $true)
          Expect ((($hCompact -match 'Paste') -and ($hCompact -match 'Copy')) -and (($hCompact -match 'Close') -and (-not ($hCompact -match 'Undo')))) $hCompact
          $pairs = @(Get-PanelHints 5 0 $true 0 $false @() $false $true $true)
          Expect ($pairs.Count -le 4) ([string]$pairs.Count)
          # Esc still clears a search before it closes the panel, in either shape
          $hQuery = Get-HintText (Get-PanelHints 5 0 $true 4 $false @() $false $true $true)
          Expect ($hQuery -match 'Clear') $hQuery
        }

        It 'an edit in progress lists only the editor keys' {
          $hEdit = Get-HintText (Get-PanelHints 5 0 $true 0 $false @() $true $true)
          Expect ((($hEdit -match 'Save') -and ($hEdit -match 'Newline')) -and (-not ($hEdit -match 'Paste'))) $hEdit
        }

        It 'the editor card draws the same chips as the footer' {
          # the card covers the footer, so it draws its own row from the same list: two copies
          # of the text is how 'Save' and 'save' ended up in the same panel
          $editPairs = @(Get-EditHints)
          $footerPairs = @(Get-PanelHints 5 0 $true 0 $false @() $true $true)
          $same = ($editPairs.Count -eq 3 -and $footerPairs.Count -eq 3)
          for ($i = 0; $same -and $i -lt $editPairs.Count; $i++) {
            if (((@($editPairs[$i]) -join '|') -cne (@($footerPairs[$i]) -join '|'))) { $same = $false }
          }
          Expect $same ((@($editPairs | ForEach-Object { @($_)[1] }) -join ','))
        }

        It 'every action label is capitalised like the panel labels' {
          # Paste, Copy, Delete, Close: an action in the footer or on the editor card starts
          # with a capital, so 'save' next to 'Save' cannot come back
          $all = New-Object System.Collections.Generic.List[object]
          $sets = @(
            (Get-PanelHints 5 0 $true 0 $false @()),
            (Get-PanelHints 5 3 $true 0 $true @()),
            (Get-PanelHints 0 0 $false 0 $false @()),
            (Get-EditHints)
          )
          foreach ($set in $sets) {
            $pairs = @($set)
            # a set with one pair arrives flat (Draw-KeyChips repairs it the same way)
            if ($pairs.Count -gt 0 -and -not ($pairs[0] -is [array])) {
              $fixed = @()
              for ($i = 0; ($i + 1) -lt $pairs.Count; $i += 2) { $fixed += ,@([string]$pairs[$i], [string]$pairs[$i + 1]) }
              $pairs = $fixed
            }
            foreach ($p in $pairs) { $all.Add(@($p)) }
          }
          $bad = @($all | Where-Object { ([string](@($_)[1])) -cnotmatch '^[A-Z]' })
          Expect ($all.Count -ge 10) ([string]$all.Count + ' label(s)')
          Expect ($bad.Count -eq 0) ((@($bad | ForEach-Object { (@($_)[0..1] -join '=') }) -join ', '))
        }
      }

      # The self-painted list freezes its first rows. 10 visible rows of 10px, 3 frozen, so
      # the scrollable window is 7 rows tall and TopIndex can never drop below 3.
      Add-PinList

      # One setter decides how typing reaches the panel; the two flags the loop and the
      # restore path read are derived from it, so they can no longer drift apart.
      Describe 'the input mode' {
        It 'derives the panel flags from the mode' {
          foreach ($case in @(
              @{ Mode = 'hook'; Hook = $true; Escalated = $false },
              @{ Mode = 'takeover'; Hook = $false; Escalated = $true },
              @{ Mode = 'none'; Hook = $false; Escalated = $false })) {
            [void](Set-InputMode $case.Mode)
            Expect ((Get-InputMode) -ceq $case.Mode) (Get-InputMode)
            Expect ($script:PickerHook -eq $case.Hook) ([string]$script:PickerHook)
            Expect ($script:PickerEscalated -eq $case.Escalated) ([string]$script:PickerEscalated)
          }
        }

        It 'refuses a mode it does not know' {
          $threw = $false
          try { [void](Set-InputMode 'bogus') } catch { $threw = $true }
          Expect $threw ''
        }
      }
      [void](Set-InputMode 'none')

      Describe 'the input-method hand-over' {
        It 'follows the ImeTakeover setting' {
          # auto: only an input method that is already composing, or a key it claimed, hands over
          Expect (-not (Test-ImeTakeover 'auto' 0x41 $false $false)) 'auto handed over without an input method'
          Expect (Test-ImeTakeover 'auto' 0x41 $true $false) 'auto refused a letter while an input method is on'
          Expect (Test-ImeTakeover 'auto' 0x41 $false $true) 'auto refused a claimed key'
          Expect (-not (Test-ImeTakeover 'auto' 0x20 $true $false)) 'auto handed over for a key the filter cannot take'
          # manual and off never hand over from a key: a click (or nothing) is the only way
          Expect (-not (Test-ImeTakeover 'manual' 0x41 $true $true)) 'manual handed over on a key'
          Expect (-not (Test-ImeTakeover 'off' 0x41 $true $true)) 'off handed over on a key'
        }
      }
      [void](Set-InputMode 'none')

      Describe 'the self-painted list' {
        It 'freezes the leading rows' {
          $pl = New-Object Cb.PinList
          try {
            $pl.ItemHeight = 10
            $pl.SetBounds(0, 0, 200, 100)
            $pl.ItemCount = 30
            $pl.PinnedCount = 3
            $pl.TopIndex = 3
            Expect ($pl.TopIndex -eq 3) ([string]$pl.TopIndex)
            $pl.ScrollBy(-5)
            Expect ($pl.TopIndex -eq 3) ([string]$pl.TopIndex)
            Expect ($pl.GetItemRectangle(0).Y -eq 0) ([string]$pl.GetItemRectangle(0).Y)
            $before = $pl.GetItemRectangle(3).Y
            $pl.ScrollBy(2)
            Expect ($pl.GetItemRectangle(3).Y -eq ($before - 20)) ([string]$pl.GetItemRectangle(3).Y)
            Expect ($pl.GetItemRectangle(0).Y -eq 0) ([string]$pl.GetItemRectangle(0).Y)
            $pl.ScrollTo(999)
            Expect (($pl.MaxTop -eq 23) -and ($pl.TopIndex -eq 23)) ([string]$pl.TopIndex + '/' + [string]$pl.MaxTop)
            # the control keeps a row count only: the labels stay with the caller
            Expect (-not ($pl.PSObject.Properties.Name -contains 'Items')) ''
          } finally { $pl.Dispose() }
        }

        It 'scrolls itself with the wheel and reports the scroll' {
          # a Control that only syncs the scrollbar leaves the wheel dead, so the list scrolls
          # itself and the panel moves its thumb from the event
          $pl = New-Object Cb.PinList
          try {
            $pl.ItemHeight = 10
            $pl.SetBounds(0, 0, 200, 100)
            $pl.ItemCount = 30
            $pl.PinnedCount = 3
            $pl.WheelRows = 2
            $pl.ScrollTo(3)
            $script:plScrolls = 0
            $pl.Add_ScrollChanged({ $script:plScrolls = $script:plScrolls + 1 })
            $wheelM = $pl.GetType().GetMethod('OnMouseWheel', [System.Reflection.BindingFlags]'Instance,NonPublic')
            $wheelArg = New-Object 'object[]' 1
            $wheelArg[0] = [Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::None, 0, 10, 10, -120)
            [void]$wheelM.Invoke($pl, $wheelArg)
            Expect ($pl.TopIndex -eq 5) ([string]$pl.TopIndex)
            Expect ($script:plScrolls -gt 0) ([string]$script:plScrolls)
            $pl.ScrollTo(999)
            [void]$wheelM.Invoke($pl, $wheelArg)
            Expect (($pl.TopIndex -eq $pl.MaxTop) -and ($pl.TopIndex + $pl.VisibleRows - $pl.PinnedCount - 1 -eq ($pl.ItemCount - 1))) ([string]$pl.TopIndex + '/' + [string]$pl.MaxTop)
          } finally { $pl.Dispose() }
        }
      }
    }

}
catch {
  # an unexpected exception used to skip every remaining group and still exit 0, which
  # reads as a green run; report it as a failure instead
  Add-TestResult 'harness' 'run finished without an exception' 'FAIL' $_.Exception.Message
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
  $seconds = ((Get-Date) - $script:unitStarted).TotalSeconds
  Write-TestPartReport 'unit\unit.ps1' $script:results $seconds $script:unitStarted
}
if ($fail -gt 0) { exit 1 }
exit 0

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
# The tooling's logger prints every step a tool runs, and its duration helper is what the rows
# below read. It is loaded here, at the top, because a hook runs in the harness scope and its
# functions would not reach the checks.
. (Join-Path $repoRoot 'tools\utils\console.ps1')
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

# A sandbox is a throw-away copy of the tool (script + lib + plugins + themes + lang): the
# settings file sits next to the script, so DataDir= and the store stay inside the sandbox.
function New-Sandbox([string]$name) {
  $dir = Join-Path $tmpRoot $name
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Copy-Item -LiteralPath $clipPs1 -Destination $dir -Force
  foreach ($sub in @('lib', 'utils', 'schema', 'plugins', 'themes', 'lang')) {
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
        $requiredLib = @('lib\base', 'lib\native', 'lib\panel\focus', 'lib\theme-stub', 'lib\settings', 'lib\marks', 'lib\ordering',
          'lib\media', 'lib\cfhtml', 'lib\clip', 'lib\blobs', 'lib\store', 'lib\migrate', 'lib\transfer', 'lib\modifiers', 'lib\apprules', 'lib\entry', 'lib\query', 'lib\select', 'lib\panel\picker-geom', 'lib\panel\picker-live', 'lib\text', 'lib\panel\anim',
          'lib\panel\picker-draw', 'lib\panel\picker-edit', 'lib\panel\media-render', 'lib\panel\pinlist', 'lib\panel\preview', 'lib\panel\picker', 'lib\panel\tray-menu', 'lib\serve', 'lib\shortcut',
          'lib\ui\layout', 'lib\ui\widgets', 'lib\ui\component', 'lib\ui\framework', 'lib\ui\views', 'lib\ui\setup', 'lib\ui\reactive',
          'lib\settings-model', 'lib\settings-types', 'lib\settings-vm', 'lib\hotkey-record', 'lib\panel\settings-draw', 'lib\panel\settings-edit', 'lib\panel\settings',
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
      It 'a duration reads in milliseconds under a second and in seconds above it' {
        # every finished step prints through this, so the boundary is what a log reader sees
        Expect ((Format-Duration 0) -eq '0 ms') (Format-Duration 0)
        Expect ((Format-Duration 999) -eq '999 ms') (Format-Duration 999)
        Expect ((Format-Duration 1000) -eq '1 s') (Format-Duration 1000)
        Expect ((Format-Duration 1234) -eq '1.23 s') (Format-Duration 1234)
        Expect ((Format-Duration -5) -eq '0 ms') (Format-Duration -5)
      }

      It 'a log level decides which lines reach the console' {
        # -Quiet keeps what went wrong and drops the steps; -Silent keeps nothing; a level
        # that was never set is info, and an unknown one cannot silence a tool by accident
        Set-LogLevel 'warn'
        Expect (-not (Test-LogEnabled 'info')) 'info printed at warn'
        Expect (Test-LogEnabled 'warn') 'warn dropped at warn'
        Expect (Test-LogEnabled 'error') 'error dropped at warn'
        Set-LogLevel 'silent'
        Expect (-not (Test-LogEnabled 'error')) 'error printed at silent'
        Set-LogLevel 'nonsense'
        Expect (-not (Test-LogEnabled 'error')) 'an unknown level changed the threshold'
        Set-LogLevel 'info'
        Expect (Test-LogEnabled 'info') 'info dropped at info'
      }
      It 'ships with the repo' {
        $tooling = @('package.ini', 'cli.ini', 'cli.ps1', 'cli.cmd', 'cli.sh',
          'tools\build.ps1', 'tools\dev.ps1', 'tools\test.ps1', 'tools\bench.ps1', 'tools\shot.ps1',
          'tools\build-client.ps1', 'tools\build-assembly.ps1',
          'tools\utils\minify.ps1', 'tools\utils\ini.ps1', 'tools\utils\globs.ps1', 'tools\utils\csc.ps1',
          'tools\utils\console.ps1', 'tools\utils\pipeline.ps1',
          'tools\bundler\bundler.ps1', 'tools\bundler\bundler.ini', 'tools\schema\bundler.ps1',
          'tools\bundler\lib\ast.ps1', 'tools\bundler\lib\graph.ps1', 'tools\bundler\lib\emit.ps1',
          'tools\bundler\plugins\10-resolve.ps1', 'tools\bundler\plugins\20-treeshake.ps1',
          'tools\bundler\plugins\30-merge.ps1', 'tools\bundler\plugins\40-render.ps1',
          'tools\bundler\plugins\90-verify.ps1',
          'src\lib\client\client.cs', 'src\lib\assembly\cb.native.cs')
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
        foreach ($cmd in @('Dev', 'Build', 'Client', 'Assembly', 'Bundle', 'Test', 'Shot')) {
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

      # the bundler merges modules by their syntax tree, so the three things a wrong merge
      # breaks first are its own checks: a module that cannot be inlined, the order the merge
      # emits, and a definition that went missing between the modules and the bundle
      if (Test-Path -LiteralPath (Join-Path $repoRoot 'tools\bundler\lib\ast.ps1')) {
        It 'the bundler refuses a module it cannot inline' {
          . (Join-Path $repoRoot 'tools\bundler\lib\ast.ps1')
          $withParam = Get-BundleParse ("param(`$x)" + "`r`n" + 'function f { }')
          $plain = Get-BundleParse 'function f { }'
          $withTrap = Get-BundleParse ('function f { }' + "`r`n" + 'trap { }')
          Expect ((Get-BundleRejectReason $withParam) -match 'param block') (Get-BundleRejectReason $withParam)
          Expect ((Get-BundleRejectReason $withParam -Entry) -eq '') 'the entry may declare parameters'
          Expect ((Get-BundleRejectReason $plain) -eq '') (Get-BundleRejectReason $plain)
          Expect ((Get-BundleRejectReason $withTrap) -match 'trap') (Get-BundleRejectReason $withTrap)
        }

        It 'the bundler emits the modules in the order the list names' {
          . (Join-Path $repoRoot 'tools\bundler\lib\ast.ps1')
          . (Join-Path $repoRoot 'tools\bundler\lib\emit.ps1')
          $first = @{ Ast = (Get-BundleParse 'function First { }').Ast; Functions = @('First'); Kept = $null }
          $second = @{ Ast = (Get-BundleParse 'function Second { }').Ast; Functions = @('Second'); Kept = $null }
          $chunk = New-BundleChunk @($first, $second)
          Expect ((@($chunk.Functions) -join ',') -eq 'First,Second') (@($chunk.Functions) -join ',')
          Expect (([string]$chunk.Text).IndexOf('Second') -gt ([string]$chunk.Text).IndexOf('First')) ([string]$chunk.Text)
        }

        It 'the bundler notices a definition missing from the bundle' {
          . (Join-Path $repoRoot 'tools\bundler\lib\ast.ps1')
          . (Join-Path $repoRoot 'tools\bundler\lib\emit.ps1')
          $expected = @{ Functions = @('First'); Commands = @(); Shapes = @('FunctionDefinitionAst') }
          $same = Get-BundleFingerprint 'function First { }'
          $missing = Get-BundleFingerprint 'function Other { }'
          Expect ((@(Compare-BundleFingerprint $expected $same)).Count -eq 0) 'an identical bundle was reported as different'
          Expect ((@(Compare-BundleFingerprint $expected $missing)).Count -gt 0) 'a missing definition was not reported'
        }

        It 'the bundler reads import and export declarations from tokens, not from text' {
          . (Join-Path $repoRoot 'tools\bundler\lib\ast.ps1')
          . (Join-Path $repoRoot 'tools\bundler\lib\surface.ps1')
          $text = ('#@use lib/ui/layout' + "`r`n" + '#@export New-UiBox, Get-UiStack' + "`r`n" +
            'function New-UiBox { }' + "`r`n" + 'Get-UiStack' + "`r`n" + '$note = "#@export NotAFunction"')
          $decl = Get-BundleDirectives (Get-BundleParse $text)
          Expect ((@($decl.Uses) -join ',') -eq 'lib/ui/layout') (@($decl.Uses) -join ',')
          Expect ((@($decl.Exports) -join ',') -eq 'New-UiBox,Get-UiStack') (@($decl.Exports) -join ',')
        }

        It 'the bundler refuses a call to a function the owner does not export' {
          . (Join-Path $repoRoot 'tools\bundler\lib\ast.ps1')
          . (Join-Path $repoRoot 'tools\bundler\lib\surface.ps1')
          $owner = @{ Id = 'a'; Ast = (Get-BundleParse 'function Helper { }').Ast; Functions = @('Helper'); Uses = @(); Exports = @() }
          $caller = @{ Id = 'b'; Ast = (Get-BundleParse 'Helper').Ast; Functions = @(); Uses = @('a'); Exports = @() }
          $open = Get-BundleSurfaceReport @($owner, $caller)
          Expect ((@($open.Problems).Count -gt 0) -eq $false) 'an undeclared module was enforced'
          $owner.Exports = @('Helper')
          $closed = Get-BundleSurfaceReport @($owner, $caller)
          Expect (@($closed.Problems).Count -eq 0) (@($closed.Problems) -join '; ')
          $owner.Exports = @('Other')
          $bad = Get-BundleSurfaceReport @($owner, $caller)
          Expect (@($bad.Problems).Count -gt 0) 'a call to an unexported function was accepted'
        }
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

    # The panel takes the foreground when it opens (lib/panel/focus.ps1), so the keyboard and the
    # focus are real: the list starts with them and the filter row gets them as soon as the user
    # types. Closing hands the foreground back where it came from.
    Describe 'panel' {
      BeforeAll {
        # the panel's behaviour is written in two files: the window itself, and the functions
        # that run while it is up (picker-live.ps1). The checks below ask what the code does,
        # not which of the two holds it.
        $script:StructPickerText = [IO.File]::ReadAllText((Join-Path $script:StructLibPath 'panel\picker.ps1')) + "`n" +
          [IO.File]::ReadAllText((Join-Path $script:StructLibPath 'panel\picker-live.ps1'))
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
        # a modal dialog would block the message loop the panel animates on, and TopMost would
        # raise the panel over windows that were opened after it
        Expect (-not ($script:StructPickerText -match '\$form\.ShowDialog\(')) 'form.ShowDialog found'
        $topHits = ([regex]::Matches($script:StructPickerText, '(?m)^\s*\$form\.TopMost\s*=')).Count
        Expect ($topHits -eq 0) ([string]$topHits + ' assignment(s)')
      }

      It 'is shown once, non-modally' {
        $showHits = ([regex]::Matches($script:StructPickerText, '(?m)^\s*\$form\.Show\(\)\s*$')).Count
        Expect ($showHits -eq 1) ([string]$showHits + ' call(s)')
      }

      It 'the panel form activates like any window' {
        # the panel sets Activates; the preview cards it raises keep the no-activate form
        Expect ($script:StructWinText -match 'public bool Activates') 'the form cannot be told whether to activate'
        Expect ($script:StructWinText -match '(?s)ShowWithoutActivation \{ get \{ return !Activates; \} \}') 'activation is not the switch'
        Expect ($script:StructWinText -match '(?s)if \(!Activates\) \{ cp\.ExStyle \|= 0x08000000; \}') 'WS_EX_NOACTIVATE is unconditional'
        Expect ($script:StructPickerText -match '\$form\.Activates = \$true') 'the panel does not ask for the foreground'
        Expect (-not ($script:StructPickerText -match 'Cb\.KeyHook|Enable-KeyHook|Set-InputMode')) 'a keyboard hook is still wired into the picker'
        Expect ($script:StructPickerText -match '(?s)\$form\.Show\(\).{0,400}Take-Foreground \$form\.Handle') 'the panel never takes the foreground'
      }

      It 'hands the foreground back when it closes' {
        Expect ($script:StructPickerText -match 'SetForegroundWindow\(\$prev\)') 'restore call missing'
        # only while the panel still holds it: a dismissal by a click elsewhere has already
        # handed the foreground over, and taking it back would pull the previous window up
        Expect ($script:StructPickerText -match '\$script:OwnFront') 'the panel does not track whether it still holds the foreground'
        Expect ($script:StructPickerText -match '(?s)\$script:OwnFront -and \$prev') 'the restore ignores who holds the foreground'
      }

      It 'the paste target is the window in front, and never one of ours' {
        # after an input-method hand-over the panel itself is in front; the daemon's console can
        # be too. Neither is somewhere to paste into, so the window the panel came from is used.
        Expect ($script:StructPickerText -match 'Get-PasteTarget') 'no Get-PasteTarget in the picker'
        Expect ($script:StructPickerText -match 'IsOwnWindow') 'the paste may be aimed at one of our own windows'
        Expect ($script:StructPickerText -match 'Format-PasteTarget') 'the paste target is not written to the log'
      }

      It 'the foreground is taken by one helper' {
        # the panel is refused the foreground while another process owns it, and the documented
        # workaround (AttachThreadInput) is worth writing once, not twice
        Expect ($script:StructPickerText -match 'Take-Foreground') 'the paste does not use Take-Foreground'
        $khText = [IO.File]::ReadAllText((Join-Path $script:StructLibPath 'panel\focus.ps1'))
        Expect ($khText -match '(?s)function Take-Foreground') 'Take-Foreground missing'
        Expect ($khText -match '(?s)function Take-Foreground[^\r\n]*\{(?:(?!function ).){0,1600}AttachThreadInput') 'Take-Foreground never attaches the queues'
      }

      It 'the foreground is checked again after the panel hides' {
        # hiding the panel can leave another window in front - the keys only mean anything while
        # the target still has it, so the check cannot be left at the moment of the hand-over
        Expect ($script:StructPickerText -match '(?s)\$form\.Hide\(\).{0,600}GetForegroundWindow') 'the foreground is not re-checked after the panel hid'
      }

      It 'a modifier still held at the timeout is released' {
        # Control.ModifierKeys reads the calling thread's key state, so waiting on it alone would
        # send Ctrl+V with Alt still down
        $modText = [IO.File]::ReadAllText((Join-Path $script:StructLibPath 'modifiers.ps1'))
        $khText = [IO.File]::ReadAllText((Join-Path $script:StructLibPath 'panel\focus.ps1'))
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
        # the width and the rows come from the preset, through the placement that decides them
        Expect ($script:StructPickerText -match 'Px \$preset\.Width') 'the width is not taken from the preset'
        Expect ($script:StructPickerText -match 'Get-PresetChrome \$preset') 'the chrome is not taken from the preset'
        Expect (-not ($script:StructPickerText -match 'Get-PanelChrome\)')) 'the theme chrome is still read by the picker'
      }

      It 'the compact shape drops the time column and the corner count' {
        Expect ($script:StructPickerText -match '\$script:PanelPreset\.ShowTime') 'the time column ignores the preset'
        Expect ($script:StructPickerText -match '\$footR\.Visible = \[bool\]\$preset\.ShowFootRight') 'the corner count ignores the preset'
        # placing the label happens before Show(), where Visible is still false: the decision
        # has to come from the preset or the count lands in the top left corner. The window is
        # the first part of the function, which now opens by binding the controls it works on.
        Expect ($script:StructPickerText -match '(?s)function Layout-Chrome\s*\{.{0,1600}if \(\$preset\.ShowFootRight\)') 'the corner count is placed from Visible instead of the preset'
      }

      It 'the width is fixed: no drag grip and no saved width' {
        Expect (-not ($script:StructPickerText -match '\$grip')) 'the drag grip is still in the picker'
        Expect (-not ($script:StructPickerText -match 'SaveWinWidth')) 'a saved width is still read by the picker'
      }

      It 'the empty-state icon is not drawn into a box that clips it' {
        # the history glyph paints above its line box; drawn into a 34 px rectangle its top was
        # cut off (277 ink pixels instead of 288), so it is measured and drawn from a point
        Expect ($script:StructDrawText -match '(?s)function Draw-EmptyGlyph.{0,700}GenericTypographic') 'the empty-state icon is drawn through a clipping box'
        Expect ($script:StructPickerText -match 'Draw-EmptyGlyph \$g \$script:EmptyGlyph') 'the empty-state icon is not drawn by that helper'
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
        # MSAA answers for older controls on Windows 10 that expose no text pattern at all
        Expect ($script:StructWinText -match 'MsaaCaret') 'the accessibility tier is missing'
        # a cloaked store application or a tool window is in front but types nothing
        Expect ($script:StructWinText -match 'IsUsableTarget') 'whatever window is in front gets anchored to'
      }

      It 'asks the input queue for the caret when rcCaret is empty' {
        # Ditto's third source (ExternalWindowTracker::FocusCaret): GetCaretPos on the attached
        # thread, which answers with a point and no height, so one line is added
        Expect ($script:StructWinText -match '(?s)public static System\.Drawing\.Rectangle AttachedCaret') 'no AttachedCaret in the assembly'
        Expect ($script:StructWinText -match '(?s)AttachedCaret.{0,1400}AttachThreadInput') 'the queues are never attached for GetCaretPos'
        # GetCaretPos answers TRUE with 0,0 when the thread has no caret (Explorer's search box),
        # which placed the panel at the window corner: hwndCaret says whether a caret exists and
        # which window owns the point, and a point outside that window is a stale one
        Expect ($script:StructWinText -match '(?s)AttachedCaret.{0,1400}hwndCaret') 'the caret point is trusted without asking whether the thread has one'
        Expect ($script:StructWinText -match '(?s)AttachedCaret.{0,1600}GetClientRect') 'the caret point is not checked against the window that owns it'
        Expect ($script:StructWinText -match 'function Get-CaretLineHeight') 'a caret point has no height to place below'
        # it belongs after rcCaret and before UI Automation: it is cheaper than a cross-process
        # accessibility call and more precise than the focused element's box
        $iCaret = $script:StructWinText.IndexOf('[Cb.Win]::CaretOfWindow($hwnd)')
        $iPos = $script:StructWinText.IndexOf('[Cb.Win]::AttachedCaret($hwnd)')
        $iUia = $script:StructWinText.IndexOf('Get-UiaCaretRect $hwnd')
        Expect ($iCaret -ge 0 -and $iPos -gt $iCaret -and $iUia -gt $iPos) ('order ' + $iCaret + '/' + $iPos + '/' + $iUia)
      }

      It 'reads the accessibility rectangle through a declared interface' {
        # accLocation hands back four numbers by reference, and a late-bound call cannot write
        # them: InvokeMember answered 0,0 0x0 for every object measured on this machine, so the
        # caret object of Chromium 76 (really at 160,61 1x18) produced no anchor at all. The
        # interface is declared and called directly instead.
        Expect ($script:StructWinText -match '(?s)interface IAccessible') 'the accessibility interface is not declared'
        Expect ($script:StructWinText -match 'accLocation\(out int left') 'the rectangle is not read through the interface'
        Expect (-not ($script:StructWinText -match 'GetType\(\)\.InvokeMember')) 'the accessibility rectangle is read by late binding'
        # a provider that keeps no caret object still says which element holds the keyboard and
        # where it is, which is the only thing left for a browser rendering its own caret
        Expect ($script:StructWinText -match 'MsaaFocusRect') 'the accessibility box tier is missing'
        Expect ($script:StructWinText -match 'get_accFocus') 'the focused element is never asked for'
        $iBox = $script:StructWinText.IndexOf('[Cb.Win]::MsaaFocusRect($hwnd)')
        $iUiaBox = $script:StructWinText.IndexOf('Convert-UiaRect (Get-UiaBoxRect $hwnd)')
        $iCtl = $script:StructWinText.IndexOf('[Cb.Win]::FocusControlBounds($hwnd)')
        # the exact caret and the UI Automation rectangle both win over a box that only says
        # where the typing goes; the focused control is still the last resort
        Expect ($iBox -gt $iUiaBox -and $iCtl -gt $iBox) ('order ' + $iUiaBox + '/' + $iBox + '/' + $iCtl)
      }

      It 'puts the caret back before the paste keys go out' {
        # The panel has to take the foreground, and some editors answer that by dropping their
        # selection: the paste then landed at the start of the field while the caret was at the
        # end (measured on a page that resets its selection on blur). The selection is cloned
        # when the panel opens and put back just before the keys.
        Expect ($script:StructWinText -match 'function Save-UiaSelection') 'the selection is never saved'
        Expect ($script:StructWinText -match 'function Restore-UiaSelection') 'the selection is never restored'
        Expect ($script:StructPickerText -match 'Save-UiaSelection \$prev') 'the picker never saves the selection'
        # a field with no text pattern at all - a Win32 edit control, which is what a chat or
        # note client puts in front - answers EM_GETSEL instead, and that is the kind the caret
        # was lost in: the paste landed at the start of the field
        Expect ($script:StructWinText -match 'IsEditControl') 'the plain edit control is never recognised'
        Expect ($script:StructWinText -match 'GetEditSelection') 'the edit control selection is never read'
        Expect ($script:StructWinText -match 'SetEditSelection') 'the edit control selection is never put back'
        Expect ($script:StructWinText -match "Kind = 'edit'") 'the saved selection has no edit control form'
        Expect ($script:StructPickerText -match 'Save-UiaSelection \$prev \$script:PrevFocus') 'the picker never hands the focus control to the save'
        $iBack = $script:StructPickerText.IndexOf('Restore-UiaSelection $script:SavedSel')
        $iKeys = $script:StructPickerText.IndexOf('SendWait($PasteKeys)')
        Expect ($iBack -ge 0 -and $iKeys -gt $iBack) ('order ' + $iBack + '/' + $iKeys)
      }

      It 'a warm-up open saves no selection of its own' {
        # the warm-up opens the same window with no target of its own: a selection saved there
        # landed in the slot of a real open right after it
        Expect ($script:StructPickerText -match 'if \(-not \$Warm\) \{') 'the warm-up saves a selection'
      }

      It 'decides to hand the foreground back before the panel hides' {
        # Hiding the panel is what takes its activation away, and the Deactivate handler reads
        # that as a dismissal and clears the flag: asking after Hide() always answered no, so
        # Esc and a repeat of the hotkey left the caret at the start of the field (measured).
        $m = [regex]::Match($script:StructPickerText, '(?s)function Close-Panel \{(.*?)\n    \}')
        Expect $m.Success 'the close helper is gone'
        $iDecide = $m.Groups[1].Value.IndexOf('$handBack = ')
        $iHide = $m.Groups[1].Value.IndexOf('$form.Hide()')
        Expect ($iDecide -ge 0 -and $iHide -gt $iDecide) ('order ' + $iDecide + '/' + $iHide)
      }

      It 'records nothing the source asked to keep out of a history' {
        # ExcludeClipboardContentFromMonitorProcessing and CanIncludeInClipboardHistory=0 are
        # what password managers publish, and what Windows' own history honours. A tool that
        # stores them anyway is the one that shows the password later.
        $clipText = [IO.File]::ReadAllText((Join-Path $script:StructLibPath 'clip.ps1'))
        $serveText = [IO.File]::ReadAllText((Join-Path $script:StructLibPath 'serve.ps1'))
        Expect ($script:StructWinText -match '(?s)ClipboardExclusion.{0,1200}CanIncludeInClipboardHistory') 'the exclusion formats are never read'
        Expect ($clipText -match 'ClipboardExclusion') 'the capture never asks whether it may record'
        Expect ($serveText -match 'capture skipped') 'a skipped capture is not written to the log'
      }

      It 'does not inject keys into an elevated window' {
        # an elevated window ignores injected keys and reports nothing back, which reads as a
        # broken panel: the footer says why instead
        $rules = [IO.File]::ReadAllText((Join-Path $script:StructLibPath 'apprules.ps1'))
        Expect ($script:StructWinText -match 'public static bool IsElevated') 'elevation is never asked about'
        Expect ($rules -match 'function Test-ElevatedTarget') 'elevation is never compared with our own token'
        Expect ($script:StructPickerText -match 'Test-ElevatedTarget \$target') 'the paste path never asks whether the target is elevated'
        # the words themselves live in lang\en.ini; what the panel must do is name that key
        Expect ($script:StructPickerText -match "Get-UiText 'panel\.foot\.copiedAdmin'") 'a blocked paste says nothing to the user'
      }

      It 'the caret is read in screen pixels' {
        # a Win32 edit control answers rcCaret inside its own client area - measured: a text box
        # at 308,231 with the caret after "hello" answers 104,1 - so the rect has to be moved to
        # the screen, or the panel anchors at the top left corner of the window it came from
        Expect ($script:StructWinText -match '(?s)CaretOfWindow.{0,2000}ClientToScreen') 'the caret rect is not moved to screen coordinates'
      }

      It 'closes the flyout that cannot be covered' {
        # a window whose process holds UIAccess sits in a band above every topmost window, so a
        # panel there would be invisible while its hook swallowed the keys meant for it. Ditto
        # closes that window and opens anyway; a window that is not the shell's own flyout is
        # left alone instead
        $rules = [IO.File]::ReadAllText((Join-Path $script:StructLibPath 'apprules.ps1'))
        Expect ($script:StructPickerText -match '(?s)Test-UncoverableWindow \$prev\).{0,700}Close-ShellFlyout') 'the picker gives up instead of closing the flyout'
        Expect ($script:StructPickerText -match '(?s)Release-HeldModifiers.{0,700}Close-ShellFlyout') 'Escape is sent with the hotkey modifiers still down'
        Expect ($script:StructPickerText -match '(?s)while \(\$tries -lt 3.{0,200}Test-ShellFlyout') 'closing search never goes on to the Start menu behind it'
        Expect ($script:StructPickerText -match '(?s)Close-ShellFlyout \$prev\).{0,300}closed the flyout') 'the flyout is closed without a word in the log'
        Expect ($script:StructPickerText -match 'not opened \(the window in front cannot be covered\)') 'a window that cannot be covered is opened over anyway'
        Expect ($script:StructPickerText -match '(?s)Test-ShellFlyout \$fgShell\).{0,200}dismissed') 'the picker stays open when Start / search comes up'
        Expect ($script:StructPickerText -match 'ShellCheckAt') 'the flyout is never polled while the panel is up'
        # the general test is the window style and the process token - the band itself cannot be
        # queried - and only a shell flyout is closed, never somebody else's window
        Expect ($script:StructWinText -match '(?s)bool IsTopmost\(IntPtr h\).{0,300}0x8') 'an active topmost window is not recognised'
        Expect ($rules -match '(?s)function Test-UncoverableWindow.{0,600}IsTopmost') 'a topmost window in front is not what decides it'
        Expect ($rules -match '(?s)function Test-UncoverableWindow.{0,900}HasUiAccess') 'UIAccess windows are not recognised'
        Expect ($rules -match '(?s)function Close-ShellFlyout.{0,400}0x1B') 'the flyout is not closed with Escape'
        Expect ($rules -match '(?s)function Close-ShellFlyout.{0,900}WindowBelow') 'a flyout that ignores Escape is never deactivated'
        Expect ($rules -match '(?s)function Close-ShellFlyout.{0,1300}Test-ShellFlyout') 'an arbitrary window would be closed'
      }

      It 'paste can type instead of injecting a paste key' {
        # PasteTyping=1 hands the text to SendInput: the paste path has to keep that branch,
        # and it must stay inside Paste-Clip so the hand-over and the settle still happen first.
        # The body is taken whole: a character window around it moved the answer every time a
        # comment was added above the branch.
        $m = [regex]::Match($script:StructPickerText, '(?s)function Paste-Clip[^\r\n]*\{(.*?)\n    \}')
        Expect $m.Success 'Paste-Clip is gone'
        Expect ($m.Groups[1].Value -match 'SendUnicode\(\$TypedText\)') 'SendUnicode branch missing in Paste-Clip'
        Expect ($script:StructPickerText -match '\$script:PasteTyping') 'PasteTyping never read'
      }

      It 'reads the list through its own members' {
        # the rows are painted by Cb.PinList, which has no Items collection: a leftover
        # $lst.Items.Count silently reads 0 and the row never repaints
        Expect (-not ($script:StructPickerText -match '\$lst\.Items\b')) '$lst.Items found'
      }

      It 'the row under the cursor is read again after the list moves' {
        # A wheel notch moves the rows, not the pointer: without reading the row again the card
        # belongs to the row that moved away, and every notch cleared the "already shown" mark
        # while leaving the rest timer alone - so a pause mid-scroll flashed a card.
        Expect ($script:StructPickerText -match '(?s)function Sync-HoverFromCursor\s*\{.{0,900}IndexFromPoint') 'the hover is not read from the cursor'
        Expect ($script:StructPickerText -match '(?s)function Sync-HoverFromCursor\s*\{.{0,1200}\$script:PvAt = Get-Date') 'the rest timer is not started over'
        Expect ($script:StructPickerText -match 'Add_ScrollChanged\(\{[^}\n]*Sync-HoverFromCursor') 'the scroll does not sync the hover'
        # a filter narrows the list under a pointer that stays put, which is the same problem
        Expect ($script:StructPickerText -match '(?s)Trim-Selection.{0,1200}Sync-HoverFromCursor') 'Update-List does not sync the hover'
      }

      It 'a scroll never leaves the selected row off screen' {
        # Enter pastes the selection: the wheel, a page key and the scrollbar move the view
        # without it, and a selection left outside the view would paste a row the user cannot
        # see. Keep-SelectionInView pulls it to the edge the view moved toward.
        Expect ($script:StructPickerText -match 'Add_ScrollChanged\(\{[^}\n]*Keep-SelectionInView') 'the scroll does not keep the selection in view'
        Expect ($script:StructPickerText -match '(?s)function Keep-SelectionInView\s*\{.{0,1400}\$lst\.SelectedIndex = \$last') 'the selection is not pulled into the view'
      }

      It 'closes the menu before it closes itself' {
        # A drop-down that outlives the panel keeps the menu filter WinForms installed for it,
        # and that filter eats every later click of the process: whichever path closes the panel
        # has to close the menu first
        Expect ($script:StructPickerText -match '(?s)Add_FormClosing\(\{.{0,600}\$cm\.Close\(\)') 'menu not closed in FormClosing'
      }

      It 'a dismissed panel closes its menu first' {
        # the menu is shown without activation, so it does not always see the click that lands
        # beside it: leaving it up keeps its filter and it eats the next click
        Expect ($script:StructPickerText -match '(?s)Add_FormClosing\(\{.{0,400}\$cm\.Close\(\)') 'menu not closed in FormClosing'
        # and a click elsewhere is the form losing the activation, which is what closes it
        Expect ($script:StructPickerText -match '(?s)Add_Deactivate\(\{.{0,900}\$form\.Close\(\)') 'the panel ignores losing the foreground'
        # the menu itself is a window of this process: opening it must not count as leaving
        Expect ($script:StructPickerText -match 'IsOwnWindow') 'a window of this process counts as somewhere else'
        Expect ($script:StructPickerText -match '(?s)Add_Deactivate\(\{.{0,400}\$cm\.Visible') 'opening the menu dismisses the panel'
        # one click beside the open menu closes the menu and the panel together
        Expect ($script:StructPickerText -match '(?s)MenuClosedAt.{0,400}\$form\.Close\(\)') 'a click beside the menu leaves the panel open'
      }

      It 'releases the handles it builds per open' {
        # per-open GDI handles: the rounded region the form paints with. The row menu's rows and
        # skin use the panel's shared fonts and are collected with the strip, so it no longer
        # creates a font of its own per open.
        Expect ($script:StructDrawText -match 'function Update-PanelRegion') 'the form region is released nowhere'
        Expect ($script:StructPickerText -match '(?s)\$cm\.Dispose\(\)') 'the row menu is not disposed'
      }

      It 'the row menu is drawn by the tray menu s own class' {
        # one skin, one row class and one separator helper for both menus: a right click beside
        # the panel must not open a window in the system colours
        Expect ($script:StructPickerText -match 'New-Object Cb\.TrayMenu') 'the row menu is a system menu'
        Expect ($script:StructPickerText -match 'New-TrayMenuSkin') 'the row menu has no skin from the tray menu'
        Expect (-not ($script:StructPickerText -match 'ToolStripProfessionalRenderer')) 'the row menu still uses the system renderer'
        # a group boundary is a separator row, not a line drawn inside the row that follows it:
        # the line has to sit in its own row or the air above and below it differs per group
        Expect ($script:StructPickerText -match 'Add-TrayMenuSeparator') 'the row menu draws its group lines inside a row'
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

      It 'the Shown handler leaves the search box unlit' {
        # the panel already owns the foreground, so the only thing the handler must not do is
        # paint the field as focused: the caret there would be a caret nobody is using
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
          if ($text -match '\$txt\.Focus\(') { $shownFocus++ }
          if ($text -match 'SearchFocus\s*=\s*\$true') { $shownPaint++ }
          if ($text -match 'function Start-Search|Start-Search$') { $shownHelper++ }
        }
        Expect ($shownBlocks.Count -eq 1) ([string]$shownBlocks.Count + ' handler(s)')
        Expect ($shownFocus -eq 0) ([string]$shownFocus + ' filter focus call(s)')
        Expect ($shownHelper -eq 0) ([string]$shownHelper + ' Start-Search call(s)')
        Expect ($shownPaint -eq 0) ([string]$shownPaint + ' search box mark(s)')
      } -Skip $script:StructMinified

      It 'starts on the list and moves the keyboard to the filter on the first character' {
        # the panel owns the foreground from Show() on, but the filter row is not where the user
        # starts: no caret is shown until something is typed, and the list navigates meanwhile
        Expect ($script:StructPickerText -match '(?s)Add_Shown\s*\(\{(?:(?!Add_).){0,400}\$lst\.Focus\(\)') 'the list does not take the keyboard on open'
        Expect (-not ($script:StructPickerText -match '(?s)Add_Shown\s*\(\{(?:(?!Add_).){0,400}\$txt\.Focus\(\)')) 'the filter row takes the keyboard on open'
        # Show() hands the focus to the first tabbable control, which would be the box: it would
        # hold the keyboard - and draw its caret - for one frame before the list takes it
        Expect ($script:StructPickerText -match '\$txt\.TabStop = \$false') 'the box is a tab stop, so Show() focuses it'
        Expect ($script:StructPickerText -match '(?s)Add_KeyPress\s*\(\{(?:(?!Add_).){0,600}Start-Search') 'a typed character never reaches the filter row'
        Expect ($script:StructPickerText -match '(?s)function Start-Search\s*\{.{0,300}\$txt\.Focus\(\)') 'Start-Search does not focus the box'
        # a click anywhere in the search area ends in the same place: the real focus
        Expect (([regex]::Matches($script:StructPickerText, '\.Add_Click\(\{ \$txt\.Focus\(\) \}\)')).Count -ge 5) 'search area handlers missing'
        Expect (-not ($script:StructPickerText -match 'Claim-Search')) 'the old click hand-over is still there'
      } -Skip $script:StructMinified

      It 'stops the tick when a handler closed the panel' {
        # Enter, Esc and the paste run from DoEvents and can dispose the form: the rest of that
        # tick would then touch disposed controls - a null handle reached the IME probe and the
        # error ended the whole panel
        Expect ($script:StructPickerText -match '(?s)DoEvents\(\).{0,300}if \(\$form\.IsDisposed\) \{ break \}') 'the loop keeps running after the panel was closed'
        Expect ($script:StructPickerText -match '(?s)ImeComposing.{0,200}catch \{ \$script:Composing = \$false \}') 'the IME probe can throw out of the loop'
      } -Skip $script:StructMinified

      It 'the search field draws the caret in the theme colour' {
        # The system caret cannot be given a colour, so the panel draws the line itself and hides
        # the real one. A control re-shows its caret after every keystroke, so the hiding has to
        # come from the loop, not once from the focus change.
        Expect ($script:StructPickerText -match '(?s)function Test-OwnCaret\s*\{.{0,400}\$script:Composing') 'the caret owner ignores an input method'
        Expect ($script:StructWinText -match 'bool ImeComposing') 'no input-method check for the drawn caret'
        # HideCaret keeps a count: the tick has to give it back while a composition runs, or the
        # caret never comes back and the candidate window has nothing to sit at
        Expect ($script:StructPickerText -match '(?s)function Show-SystemCaret\s*\{.{0,400}ShowCaret') 'the hidden count is never given back'
        Expect ($script:StructPickerText -match '(?s)else \{\s*if \(\$caret\.Visible\) \{ \$caret\.Visible = \$false \}\s*Show-SystemCaret') 'the composing case does not give the system caret back'
        # only a composition string counts: the conversion mode is on for the whole session with a
        # Chinese input method, which used to hide the drawn caret before anything was typed
        Expect (-not ($script:StructWinText -match 'ImmGetConversionStatus')) 'the conversion mode still decides instead of the composition'
        Expect ($script:StructPickerText -match 'function Get-CaretIndex') 'no caret index helper'
        # EM_POSFROMCHAR / TextWidth: the control's own metrics, never a GDI measurement of the
        # prefix (that one came out half again as wide on a scaled display)
        Expect ($script:StructPickerText -match '0x00D6') 'the caret position is not asked of the control'
        Expect ($script:StructPickerText -match '\[Cb\.Win\]::TextWidth') 'the end of the text is not measured with the control font'
        Expect (-not ($script:StructPickerText -match 'MeasureText\(\$prefix')) 'the caret is still placed from a GDI measurement'
        # the selection is the control's own now that it has the focus; only the end the keyboard
        # moved last has to be tracked, because the control does not report it
        Expect ($script:StructPickerText -match 'CaretEnd') 'the active end of a selection is not tracked'
        Expect (-not ($script:StructPickerText -match 'Step-SearchKey|Sync-SearchBand')) 'the emulated selection is still there'
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

    # The two drawn windows place their furniture by cutting boxes and filling them, and both
    # scrollbars are the same three numbers (lib\ui\layout.ps1). These are the rules the
    # settings window and the panel lean on.
    Describe 'ui boxes' {
      It 'moves the edges of a box in' {
        $box = New-UiBox 10 20 200 100
        $all = Get-UiInset $box 4
        Expect ($all.Left -eq 14 -and $all.Top -eq 24 -and $all.Width -eq 192 -and $all.Height -eq 92) 'all four edges'
        $mixed = Get-UiInset $box 4 0 0 6
        Expect ($mixed.Left -eq 14 -and $mixed.Top -eq 20 -and $mixed.Width -eq 196 -and $mixed.Height -eq 94) 'left and bottom only'
      }

      It 'lets the flexible band keep room for the bands named after it' {
        # a header, a list that takes the rest, and a footer: the -1 has to leave the footer its
        # pixels, or the footer gets nothing and the list runs to the window edge
        $bands = @(Get-UiStack (New-UiBox 0 0 300 700) @(62, -1, 56))
        Expect ($bands.Count -eq 3) 'three bands'
        Expect ($bands[0].Height -eq 62 -and $bands[2].Height -eq 56) 'the named bands keep their height'
        Expect ($bands[1].Top -eq 62 -and $bands[1].Bottom -eq 644) 'the middle one takes what is between them'
        $cols = @(Get-UiColumns (New-UiBox 0 0 300 700) @(60, -1, 40))
        Expect ($cols[1].Left -eq 60 -and $cols[1].Right -eq 260) 'and a column does the same across'
      }

      It 'sizes a thumb by the visible part and stops it at both ends of the lane' {        $top = Get-UiScrollMetrics 400 0.25 0 300 24
        Expect ($top.Len -eq 100 -and $top.Top -eq 0) 'a quarter shown at the top'
        $mid = Get-UiScrollMetrics 400 0.25 150 300 24
        Expect ($mid.Top -eq 150) 'half way down a lane with 300 px of travel'
        $end = Get-UiScrollMetrics 400 0.25 9999 300 24
        Expect ($end.Top -eq 300) 'the end of the lane, not past it'
        $thin = Get-UiScrollMetrics 400 0.01 0 300 24
        Expect ($thin.Len -eq 24) 'a thumb is never thinner than what a pointer can grab'
        Expect ($null -eq (Get-UiScrollMetrics 400 1.0 0 300 24)) 'no thumb when the content fits'
      }
    }

    Describe 'ui box model' {
      It 'puts the border and the padding inside the slot and the margin outside it' {
        $style = New-UiStyle @{ Margin = 4; Border = 1; Padding = 8 }
        $boxes = Get-UiBoxModel (New-UiBox 0 0 100 50) $style
        Expect ($boxes.Border.Left -eq 4 -and $boxes.Border.Width -eq 92) 'the margin moves the border box in'
        Expect ($boxes.Padding.Left -eq 5 -and $boxes.Padding.Height -eq 40) 'the border sits inside that'
        Expect ($boxes.Content.Left -eq 13 -and $boxes.Content.Width -eq 74 -and $boxes.Content.Height -eq 24) 'the padding sits inside the border'
      }

      It 'reads one, two and four edge numbers the way CSS does' {
        $one = Get-UiEdges 6
        Expect ($one[0] -eq 6 -and $one[1] -eq 6 -and $one[2] -eq 6 -and $one[3] -eq 6) 'one number, four edges'
        $two = Get-UiEdges @(2, 6)
        Expect ($two[0] -eq 2 -and $two[1] -eq 6 -and $two[2] -eq 2 -and $two[3] -eq 6) 'two numbers are vertical then horizontal'
        $four = Get-UiEdges @(1, 2, 3, 4)
        Expect ($four[0] -eq 1 -and $four[1] -eq 2 -and $four[2] -eq 3 -and $four[3] -eq 4) 'top, right, bottom, left'
      }

      It 'stacks a column and lets the automatic child take what is left' {
        $box = New-UiBox 0 0 200 120
        $col = New-UiStyle @{ Flow = 'column'; Gap = 6 }
        $items = @(
          (New-UiStyle @{ Height = 20 }),
          (New-UiStyle @{ }),
          (New-UiStyle @{ Height = 20 })
        )
        $laid = @(Get-UiFlow $box $col $items)
        Expect ($laid.Count -eq 3) 'three children'
        Expect ($laid[1].Top -eq 26 -and $laid[1].Height -eq 68) 'the middle one takes 120 - 40 - 12'
        Expect ($laid[2].Top -eq 100 -and $laid[2].Height -eq 20) 'the last one lands after it'
        Expect ($laid[0].Width -eq 200) 'a child with no width stretches across the column'
      }

      It 'holds a child to its min and max' {
        $box = New-UiBox 0 0 200 200
        $col = New-UiStyle @{ Flow = 'column' }
        $clamped = @(Get-UiFlow $box $col @((New-UiStyle @{ MaxHeight = 30; MinHeight = 10 })))
        Expect ($clamped[0].Height -eq 30) 'the automatic height stops at the maximum'
        $small = @(Get-UiFlow $box $col @((New-UiStyle @{ Height = 4; MinHeight = 12 })))
        Expect ($small[0].Height -eq 12) 'a fixed height is raised to the minimum'
      }

      It 'aligns across the flow and justifies along it' {
        $box = New-UiBox 0 0 200 100
        $end = New-UiStyle @{ Flow = 'column'; Align = 'end' }
        $one = @(Get-UiFlow $box $end @((New-UiStyle @{ Width = 50; Height = 10 })))
        Expect ($one[0].Left -eq 150) 'aligned to the far edge'
        $center = New-UiStyle @{ Flow = 'column'; Justify = 'center' }
        $mid = @(Get-UiFlow $box $center @((New-UiStyle @{ Height = 20 })))
        Expect ($mid[0].Top -eq 40) 'centred along the column'
        $spread = New-UiStyle @{ Flow = 'column'; Justify = 'space-between' }
        $both = @(Get-UiFlow $box $spread @((New-UiStyle @{ Height = 20 }), (New-UiStyle @{ Height = 20 })))
        Expect ($both[0].Top -eq 0 -and $both[1].Top -eq 80) 'pushed to the two ends'
      }

      It 'lays a row out left to right with a gap' {
        $box = New-UiBox 0 0 200 40
        $row = New-UiStyle @{ Flow = 'row'; Gap = 10 }
        $laid = @(Get-UiFlow $box $row @((New-UiStyle @{ Width = 60 }), (New-UiStyle @{ })))
        Expect ($laid[0].Left -eq 0 -and $laid[0].Width -eq 60) 'the fixed one'
        Expect ($laid[1].Left -eq 70 -and $laid[1].Width -eq 130) 'the automatic one takes the rest'
        Expect ($laid[1].Height -eq 40) 'a row stretches its children across the height'
      }

      It 'cuts the settings window into the boxes its painting uses' {
        $l = Get-SettingsLayout 780 700
        Expect ($l.List.Left -eq $l.ListLeft -and $l.List.Right -eq $l.ListRight) 'the rows are placed by the list box'
        Expect ($l.List.Top -eq $l.ListTop -and $l.List.Bottom -eq $l.ListBottom) 'the list runs between the header and the footer'
        Expect ($l.ListLeft -eq ($l.SideWidth + $l.Pad)) 'the rows start after the page column and its pad'
        Expect ($l.ListRight -eq ($l.Width - $l.Pad - (Px 8))) 'the rows stop short of the thumb lane'
        Expect ($l.Head.Height -eq $l.HeadHeight -and $l.Foot.Height -eq $l.FootHeight) 'the bands are the header and the footer'
        Expect ($l.SbBox.Left -eq $l.SbLeft -and $l.SbBox.Width -eq $l.SbLane) 'the lane is where the thumb is drawn'
      }
    }

    # What a change means in the settings window is decided in lib\settings-vm.ps1, without the
    # window: the staged table, the switch, the chord list and the multi-select all answer here.
    Describe 'settings changes' {
      It 'stages a value the file does not hold, and leaves nothing for the one it does' {
        $held = [string](Get-SettingRaw $script:SettingsSchema 'ShowTime')
        $staged = Get-SettingStagedValue @{} $script:SettingsSchema 'ShowTime' 'x'
        Expect ($staged.Changed -and [string]$staged.Pending['ShowTime'] -eq 'x') 'a different value is staged'
        $back = Get-SettingStagedValue $staged.Pending $script:SettingsSchema 'ShowTime' $held
        Expect (-not $back.Changed) 'going back to the held value is not a change'
        Expect (-not $back.Pending.ContainsKey('ShowTime')) 'and it leaves nothing staged'
      }

      It 'turns a switch from the value the row holds' {
        Expect ((Get-SettingFlipValue @{ Raw = '1' }) -eq '0') 'on turns off'
        Expect ((Get-SettingFlipValue @{ Raw = '0' }) -eq '1') 'off turns on'
      }

      It 'replaces a single hotkey and appends to a chain' {
        Expect ((Get-SettingRecordValue @{ Raw = 'Ctrl+Alt+V'; Chain = $false } 'Ctrl+Alt+C') -eq 'Ctrl+Alt+C') 'a single setting takes the chord'
        $chain = @{ Raw = 'Ctrl+Alt+V'; Chain = $true }
        Expect ((Get-SettingRecordValue $chain 'Ctrl+Alt+C') -eq 'Ctrl+Alt+V, Ctrl+Alt+C') 'a chain gains it at the end'
      }

      It 'takes one chord off a chain and refuses the last one' {
        $row = @{ Raw = 'Ctrl+Alt+V, Ctrl+Alt+C'; Chords = @('Ctrl+Alt+V', 'Ctrl+Alt+C') }
        $drop = Get-SettingChordDrop $row 0
        Expect ($drop.Ok -and $drop.Value -eq 'Ctrl+Alt+C' -and $drop.Removed -eq 'Ctrl+Alt+V') 'the first comes off and the rest stays'
        $one = @{ Raw = 'Ctrl+Alt+V'; Chords = @('Ctrl+Alt+V') }
        Expect (-not (Get-SettingChordDrop $one 0).Ok) 'the last one stays'
      }

      It 'ticks and unticks a name, and refuses an empty list' {
        $two = @{ Raw = 'item-marks,transform' }
        $off = Get-SettingListTick $two 'item-marks'
        Expect ($off.Ok -and $off.Value -eq 'transform' -and -not $off.Ticked) 'unticking leaves the other one'
        $on = Get-SettingListTick $two 'retention'
        Expect ($on.Ok -and $on.Ticked -and $on.Value -eq 'item-marks,transform,retention') 'ticking adds it at the end'
        Expect (-not (Get-SettingListTick @{ Raw = 'item-marks' } 'item-marks').Ok) 'the last name stays'
      }

      It 'wakes the footer actions only once something is staged' {
        $idle = Get-SettingsActionState @{}
        Expect ($idle.Defaults -and -not $idle.Save -and -not $idle.Discard) 'defaults is always there'
        $busy = Get-SettingsActionState @{ ShowTime = '1'; Rows = '12' }
        Expect ($busy.Save -and $busy.Discard -and $busy.Count -eq 2) 'save and discard follow the staged set'
      }

      It 'names what saving means for the window itself' {
        $plan = Get-SettingsSavePlan @{ Theme = 'win11-light'; Language = 'zh-CN'; Rows = '12' }
        Expect ($plan.Count -eq 3) 'three staged keys'
        Expect ($plan.Theme -and $plan.Language) 'a theme and a language are followed'
        Expect (-not $plan.HasDataDir) 'nothing moves without DataDir'
        $moved = Get-SettingsSavePlan @{ DataDir = 'D:\clip' }
        Expect ($moved.HasDataDir -and $moved.DataDir -eq 'D:\clip') 'the store folder travels with DataDir'
      }

      It 'fingerprints the staged set so a page that did not move can be reused' {
        Expect ((Get-SettingsPendingSignature @{}) -eq '') 'nothing staged is one fingerprint'
        $one = Get-SettingsPendingSignature @{ ShowTime = '1' }
        $same = Get-SettingsPendingSignature @{ ShowTime = '1'; Rows = '10' }
        Expect ($one -ne $same) 'a second key is a different set'
        $loose = Get-SettingsPendingSignature @{ Rows = '10'; ShowTime = '1' }
        Expect ($loose -eq $same) 'the order it was written in does not matter'
        Expect ((Get-SettingsPendingSignature @{ ShowTime = '0' }) -ne $one) 'a changed value is a different set'
      }
    }

    # A page is diffed against the rows it showed, so a change rebuilds its own row and leaves the
    # rest of the page alone (lib\settings-model.ps1).
    Describe 'settings rows diff' {
      It 'rebuilds only the rows whose value moved' {
        $schema = $script:SettingsSchema
        $old = @(Get-SettingsRows $schema 'Appearance')
        $page = New-SettingRowTree $old
        $same = Update-SettingRows $schema 'Appearance' $page @{}
        Expect ($same.Built -eq 0 -and $same.Reused -eq $old.Count) 'nothing moved, nothing built'
        $before = @($page.Children.ToArray() | Where-Object { [string]$_.Key -eq 'Rows' })[0].Props
        $held = [string](Get-SettingRaw $schema 'ShowTime')
        $flip = $(if ($held -eq '1') { '0' } else { '1' })
        $one = Update-SettingRows $schema 'Appearance' $page @{ ShowTime = $flip }
        Expect ($one.Rows.Count -eq $old.Count) 'the page still holds every row'
        Expect ($one.Built -eq 1) 'only the switch that changed is built'
        $row = @($one.Rows | Where-Object { [string]$_.Key -eq 'ShowTime' })[0]
        Expect ([string]$row.Raw -eq $flip -and [bool]$row.Pending) 'it shows the staged value'
        $after = @($one.Rows | Where-Object { [string]$_.Key -eq 'Rows' })[0]
        Expect ([object]::ReferenceEquals($after, $before)) 'an unchanged row is the same object, not a copy'
      }

      It 'rebuilds the row a switch owns as well' {
        $schema = $script:SettingsSchema
        $page = New-SettingRowTree @(Get-SettingsRows $schema 'Clipboard')
        $held = [string](Get-SettingRaw $schema 'CaptureImages')
        $flip = $(if ($held -eq '1') { '0' } else { '1' })
        $step = Update-SettingRows $schema 'Clipboard' $page @{ CaptureImages = $flip }
        Expect ($step.Built -eq 2) 'the switch and the row it owns'
        $owned = @($step.Rows | Where-Object { [string]$_.Key -eq 'MaxImageBytes' })[0]
        Expect ([bool]$owned.Enabled -eq ($flip -eq '1')) 'the owned row follows the switch'
      }

      It 'answers nothing for a page that states facts' {
        Expect ($null -eq (Update-SettingRows $script:SettingsSchema 'About' (New-UiComponent 'page') @{})) 'About is built, not diffed'
      }
    }


    # a revision, a cache that outlives an open, a slot whose content arrives later, and the
    # mount / update / unmount that a surface hangs its resources on.
    Describe 'ui component runtime' {
      It 'bumps the revision only when a value moves, and tells the watcher once' {
        $store = New-UiStore @{ Page = 'Clipboard' }
        $seen = New-Object System.Collections.Generic.List[string]
        Add-UiWatcher $store { param($k, $v) $seen.Add([string]$k + '=' + [string]$v) }
        $before = [int]$store.Revision
        Expect (-not (Set-UiState $store 'Page' 'Clipboard')) 'writing the value it holds is not a change'
        Expect ($store.Revision -eq $before) 'and the revision stays'
        Expect (Set-UiState $store 'Page' 'Panel') 'another value is a change'
        Expect ($store.Revision -eq ($before + 1)) 'the revision moves by one'
        Expect ($seen.Count -eq 1 -and $seen[0] -eq 'Page=Panel') 'the watcher heard it once'
      }

      It 'keeps a built answer until it goes stale' {
        $built = New-Object System.Collections.Generic.List[string]
        $released = New-Object System.Collections.Generic.List[string]
        $cache = New-UiKeepAlive 2 { param($v) $released.Add([string]$v) }
        $build = { $built.Add('x'); 'panel' + $built.Count }
        $first = Get-UiKeepAlive $cache 'panel' $build
        $again = Get-UiKeepAlive $cache 'panel' $build
        Expect ($first -eq $again -and $built.Count -eq 1) 'the second call reuses what was built'
        $rebuilt = Get-UiKeepAlive $cache 'panel' $build { param($v) $true }
        Expect ($rebuilt -eq 'panel2') 'a stale entry is built again'
        Expect ($released.Count -eq 1 -and $released[0] -eq 'panel1') 'and the old one is released first'
      }

      It 'releases the oldest entry when the cache is full' {
        $released = New-Object System.Collections.Generic.List[string]
        $cache = New-UiKeepAlive 2 { param($v) $released.Add([string]$v) }
        [void](Get-UiKeepAlive $cache 'a' { 'A' })
        [void](Get-UiKeepAlive $cache 'b' { 'B' })
        [void](Get-UiKeepAlive $cache 'c' { 'C' })
        Expect ($released.Count -eq 1 -and $released[0] -eq 'A') 'the first one went'
        Expect (-not (Test-UiKeepAliveHeld $cache 'a')) 'and it is no longer held'
        Expect ((Test-UiKeepAliveHeld $cache 'b') -and (Test-UiKeepAliveHeld $cache 'c')) 'the two newest stay'
      }

      It 'can be filled without going through the build' {        $asked = New-Object System.Collections.Generic.List[string]
        $cache = New-UiKeepAlive 2
        Set-UiKeepAliveValue $cache 'page' 'rows'
        Expect (Test-UiKeepAliveHeld $cache 'page') 'the key is held'
        $value = Get-UiKeepAlive $cache 'page' { $asked.Add('built'); 'other' }
        Expect ($value -eq 'rows' -and $asked.Count -eq 0) 'asking returns it and builds nothing'
      }

      It 'draws a slot before its content arrives' {
        $slot = New-UiAsync 'card'
        Expect (Test-UiAsyncPending $slot) 'it starts pending'
        [void](Set-UiAsyncResult $slot 'the page')
        Expect (-not (Test-UiAsyncPending $slot) -and $slot.Value -eq 'the page') 'the result lands in it'
        $bad = New-UiAsync 'card2'
        [void](Set-UiAsyncFailed $bad 'no rtf to lay out')
        Expect ($bad.Failed -and $bad.Note -eq 'no rtf to lay out') 'a failure carries its reason'
      }

      It 'mounts children first and unmounts them last in first out' {
        $order = New-Object System.Collections.Generic.List[string]
        $page = New-UiComponent 'page'
        $one = Add-UiChild $page (New-UiComponent 'row')
        $two = Add-UiChild $page (New-UiComponent 'row')
        Add-UiHook $page 'mounted' { param($c) $order.Add('page+') }
        Add-UiHook $page 'unmounted' { param($c) $order.Add('page-') }
        Add-UiHook $one 'mounted' { param($c) $order.Add('one+') }
        Add-UiHook $one 'unmounted' { param($c) $order.Add('one-') }
        Add-UiHook $two 'unmounted' { param($c) $order.Add('two-') }
        [void](Mount-UiComponent $page)
        Unmount-UiComponent $page
        Expect (($order -join ',') -eq 'one+,page+,two-,one-,page-') 'a surface is released before what it sits on'
        Expect (-not (Test-UiComponentAlive $page) -and -not (Test-UiComponentAlive $one)) 'nothing is left alive'
      }

      It 'hands a change up and ignores an event nobody listens to' {
        $got = New-Object System.Collections.Generic.List[string]
        $row = New-UiComponent 'row'
        Add-UiHandler $row 'tick' { param($p) $got.Add([string]$p) }
        Expect (Invoke-UiEmit $row 'tick' 'transform') 'a handled event answers'
        Expect ($got.Count -eq 1 -and $got[0] -eq 'transform') 'and carries what it was given'
        Expect (-not (Invoke-UiEmit $row 'save' 'x')) 'an event with no handler is not an error'
      }

      It 'counts a box that did not move as no update' {
        $hits = New-Object System.Collections.Generic.List[string]
        $c = New-UiComponent 'row'
        Add-UiHook $c 'updated' { param($x) $hits.Add('up') }
        [void](Mount-UiComponent $c (New-UiBox 0 0 10 10))
        Expect (-not (Update-UiComponent $c (New-UiBox 0 0 10 10))) 'the same box is nothing to do'
        Expect ($hits.Count -eq 0) 'and the hook does not run'
        Expect (Update-UiComponent $c (New-UiBox 0 0 20 10)) 'a wider box is an update'
        Expect ($hits.Count -eq 1) 'the hook runs once'
      }

      It 'releases what a component opened when it goes' {
        $c = New-UiComponent 'row'
        $stream = New-Object System.IO.MemoryStream
        Add-UiResource $c $stream
        [void](Mount-UiComponent $c)
        Unmount-UiComponent $c
        # a disposed stream still reports its Length; writing to it is what says it is closed
        $closed = $false
        try { $stream.WriteByte(1) } catch { $closed = $true }
        Expect $closed 'the handle is released, not left to the finalizer'
        Expect ($c.Resources.Count -eq 0) 'and the record no longer holds it'
      }

      It 'keeps the components a keyed list still needs and drops the rest' {
        $page = New-UiComponent 'page'
        $keep = New-UiComponent 'row'
        $keep.Key = 'b'
        $gone = New-UiComponent 'row'
        $gone.Key = 'a'
        [void](Add-UiChild $page $keep)
        [void](Add-UiChild $page $gone)
        [void](Mount-UiComponent $page)
        $made = New-Object System.Collections.Generic.List[string]
        $specs = @('b', 'c')
        $result = Sync-UiChildren $page $specs { param($s) $s } {
          param($s)
          $made.Add([string]$s)
          New-UiComponent 'row'
        }
        Expect ($result.Reused -eq 1 -and $result.Created -eq 1 -and $result.Unmounted -eq 1) 'one kept, one built, one taken down'
        Expect ($result.Children[0] -eq $keep) 'the kept component is the same object, not a copy'
        Expect ($result.Children[1].Key -eq 'c' -and $made.Count -eq 1) 'only the new key was built'
        Expect (-not (Test-UiComponentAlive $gone)) 'the one that left is unmounted'
        Expect ($page.Children.Count -eq 2 -and [string]$page.Children[1].Key -eq 'c') 'the record holds the new order'
      }
    }

    # A surface is a keyed tree (lib\ui\framework.ps1): the patch below is what keeps a page or a
    # list from being rebuilt to change one value, at any depth.
    Describe 'ui tree patch' {
      BeforeAll {
        $script:TreeKey = { param($s) [string]$s.Key }
        $script:TreeMake = { param($spec) New-UiComponent ([string]$spec.Type) $spec.Props }
      }

      It 'keeps a node whose values did not move and updates the one that did' {
        $page = New-UiComponent 'page'
        [void](Mount-UiComponent $page)
        $first = Sync-UiTree $page @(
          @{ Key = 'a'; Type = 'row'; Props = @{ Text = 'one' } },
          @{ Key = 'b'; Type = 'row'; Props = @{ Text = 'two' } }
        ) $script:TreeKey $script:TreeMake
        Expect ($first.Created -eq 2 -and $first.Updated -eq 0) 'both rows are built the first time'
        $rowA = $first.Children[0]
        $second = Sync-UiTree $page @(
          @{ Key = 'a'; Type = 'row'; Props = @{ Text = 'one' } },
          @{ Key = 'b'; Type = 'row'; Props = @{ Text = 'TWO' } }
        ) $script:TreeKey $script:TreeMake
        Expect ($second.Reused -eq 2 -and $second.Updated -eq 1 -and $second.Created -eq 0) 'only the changed row is touched'
        Expect ($second.Children[0] -eq $rowA) 'the untouched row is the same object'
        Expect ([string]$second.Children[1].Props.Text -eq 'TWO') 'the changed row carries the new value'
      }

      It 'patches grandchildren and takes down what left the tree' {
        $page = New-UiComponent 'page'
        [void](Mount-UiComponent $page)
        $spec = @(
          @{ Key = 'a'; Type = 'row'; Props = @{ }; Children = @(
              @{ Key = 'a1'; Type = 'cell'; Props = @{ Text = 'x' } },
              @{ Key = 'a2'; Type = 'cell'; Props = @{ Text = 'y' } }
            ) }
        )
        $first = Sync-UiTree $page $spec $script:TreeKey $script:TreeMake
        Expect ($first.Children[0].Children.Count -eq 2) 'the row holds its two cells'
        $cell = $first.Children[0].Children[0]
        $shorter = @(
          @{ Key = 'a'; Type = 'row'; Props = @{ }; Children = @(
              @{ Key = 'a1'; Type = 'cell'; Props = @{ Text = 'x' } }
            ) }
        )
        $second = Sync-UiTree $page $shorter $script:TreeKey $script:TreeMake
        Expect ($second.Unmounted -eq 1) 'the cell that left is taken down'
        Expect ($second.Children[0].Children[0] -eq $cell) 'the cell that stayed is the same object'
        Expect ($second.Children[0].Children.Count -eq 1) 'and the row no longer holds the other'
      }

      It 'hands the replaced values to the updated hook' {
        # the hook is a watch, not a notification: it runs with the new state in place and the
        # old one in its hand, which is what lets a surface react to what moved
        $page = New-UiComponent 'page'
        [void](Mount-UiComponent $page)
        [void](Sync-UiTree $page @(@{ Key = 'a'; Props = @{ Text = 'one' } }) $script:TreeKey $script:TreeMake)
        # the accumulator is script scoped, the way a surface's hook talks to its own window state
        # ($script:SetToggleTarget in the settings window): a hook runs from inside the patch, so
        # it must not lean on a local of whatever happened to call the patch
        $script:TreeSeen = New-Object System.Collections.Generic.List[string]
        Add-UiHook $page.Children[0] 'updated' { param($c, $old) $script:TreeSeen.Add([string]$old.Text + '->' + [string]$c.Props.Text) }
        [void](Sync-UiTree $page @(@{ Key = 'a'; Props = @{ Text = 'one' } }) $script:TreeKey $script:TreeMake)
        Expect ($script:TreeSeen.Count -eq 0) 'a refresh that changed nothing does not call it'
        [void](Sync-UiTree $page @(@{ Key = 'a'; Props = @{ Text = 'uno' } }) $script:TreeKey $script:TreeMake)
        Expect (($script:TreeSeen.Count -eq 1) -and ($script:TreeSeen[0] -eq 'one->uno')) ('seen ' + ($script:TreeSeen -join ';'))
      }

      It 'moves a row that changed place without building it again' {
        # a list whose order changed is not a list of new rows: the same three keys come back in
        # another order, and every node is the one that was there before
        $page = New-UiComponent 'page'
        [void](Mount-UiComponent $page)
        [void](Sync-UiTree $page @(
            @{ Key = 'a'; Props = @{ Text = 'one' } }, @{ Key = 'b'; Props = @{ Text = 'two' } }, @{ Key = 'c'; Props = @{ Text = 'three' } }
          ) $script:TreeKey $script:TreeMake)
        $before = @{}
        foreach ($n in $page.Children.ToArray()) { $before[[string]$n.Key] = $n }
        $step = Sync-UiTree $page @(
          @{ Key = 'c'; Props = @{ Text = 'three' } }, @{ Key = 'a'; Props = @{ Text = 'one' } }, @{ Key = 'b'; Props = @{ Text = 'two' } }
        ) $script:TreeKey $script:TreeMake
        Expect (($step.Reused -eq 3) -and ($step.Created -eq 0) -and ($step.Unmounted -eq 0)) 'nothing was built or dropped'
        Expect (($page.Children.ToArray() | ForEach-Object { [string]$_.Key }) -join ',' -eq 'c,a,b') 'the order is the caller''s'
        foreach ($n in $page.Children.ToArray()) { Expect ($before[[string]$n.Key] -eq $n) ('the ' + $n.Key + ' row is the same node') }
      }

      It 'takes down what the caller stopped asking for' {
        # a row the page no longer names is not left behind: "if" here is the spec being absent,
        # and the node it used to be is unmounted so what it held is released
        $page = New-UiComponent 'page'
        [void](Mount-UiComponent $page)
        $step = Sync-UiTree $page @(
            @{ Key = 'a'; Props = @{ } }, @{ Key = 'b'; Props = @{ } }
          ) $script:TreeKey $script:TreeMake
        $gone = $step.Children[1]
        $after = Sync-UiTree $page @(@{ Key = 'a'; Props = @{ } }) $script:TreeKey $script:TreeMake
        Expect ($after.Unmounted -eq 1) 'the row that is no longer wanted is taken down'
        Expect (-not (Test-UiComponentAlive $gone)) 'and it is not alive any more'
        Expect ($page.Children.Count -eq 1) 'the page holds only what was asked for'
      }

      It 'builds a second child for a key it is given twice' {
        # one key cannot name two nodes: the second one is built with no key, so the first keeps
        # the node it has instead of two children sharing one
        $page = New-UiComponent 'page'
        [void](Mount-UiComponent $page)
        $step = Sync-UiTree $page @(
            @{ Key = 'dup'; Props = @{ Text = 'one' } }, @{ Key = 'dup'; Props = @{ Text = 'two' } }
          ) $script:TreeKey $script:TreeMake
        Expect (($step.Created -eq 2) -and ($step.Reused -eq 0)) 'both are new'
        Expect ($page.Children.Count -eq 2) 'the list keeps both children'
        Expect ([string]$page.Children[0].Key -eq 'dup' -and [string]$page.Children[1].Key -eq '') 'only the first holds the key'
      }

      It 'judges staleness by the fingerprint a surface hands it' {
        # a settings row carries labels and choice lists that cannot move while the page is up:
        # the surface says which fields matter, and a row whose only new field is a label is
        # not updated, not re-copied and not re-drawn
        $stamp = { param($r) [string]$r.Raw }
        $page = New-UiComponent 'page'
        [void](Mount-UiComponent $page)
        [void](Sync-UiTree $page @(@{ Key = 'a'; Props = @{ Raw = '1'; Label = 'one' } }) $script:TreeKey $script:TreeMake $stamp)
        $step = Sync-UiTree $page @(@{ Key = 'a'; Props = @{ Raw = '1'; Label = 'uno' } }) $script:TreeKey $script:TreeMake $stamp
        Expect ($step.Reused -eq 1 -and $step.Updated -eq 0) 'the label alone does not make it stale'
        $moved = Sync-UiTree $page @(@{ Key = 'a'; Props = @{ Raw = '0'; Label = 'uno' } }) $script:TreeKey $script:TreeMake $stamp
        Expect ($moved.Updated -eq 1) 'a new value does'
        Expect ([string]$page.Children[0].Props.Label -eq 'uno') 'and the node takes the new record with it'
      }

      It 'draws a parent before its children and skips what is unmounted' {
        $seen = New-Object System.Collections.Generic.List[string]
        $page = New-UiComponent 'page'
        [void](Mount-UiComponent $page)
        [void](Sync-UiTree $page @(
          @{ Key = 'a'; Type = 'row'; Props = @{ }; Children = @(@{ Key = 'a1'; Type = 'cell'; Props = @{ } }) }
        ) $script:TreeKey $script:TreeMake)
        $n = Render-UiTree $page { param($node) $seen.Add([string]$node.Type + ':' + [string]$node.Key) }
        Expect ($n -eq 3) 'the page, the row and the cell are drawn'
        Expect (($seen -join ',') -eq 'page:,row:a,cell:a1') 'a parent is drawn before its children'
        Unmount-UiComponent $page
        $after = New-Object System.Collections.Generic.List[string]
        [void](Render-UiTree $page { param($node) $after.Add('x') })
        Expect ($after.Count -eq 0) 'a taken-down tree draws nothing'
      }
    }

    # A control as a record (lib\ui\views.ps1): the kind decides how it draws, the node holds where
    # it is and how it happens to be, and the hover is a diff that answers a rectangle - which is
    # what keeps a pointer crossing a footer button from repainting the window.
    Describe 'ui views' {
      BeforeAll {
        $script:ViewA = New-UiView 'button' 'a' @{ Label = 'one' }
        $script:ViewB = New-UiView 'button' 'b' @{ Label = 'two' }
        $script:ViewA.Box = @{ Left = 0; Top = 0; Width = 40; Height = 20 }
        $script:ViewB.Box = @{ Left = 50; Top = 0; Width = 40; Height = 20 }
      }

      It 'moves the hover to one control and answers only what changed' {
        $dirty = Update-UiViewHot @($script:ViewA, $script:ViewB) 10 10
        Expect (-not $dirty.IsEmpty) 'the control under the pointer changed'
        Expect ((Test-UiViewState $script:ViewA 'Hot') -and -not (Test-UiViewState $script:ViewB 'Hot')) 'only the one under the pointer holds it'
        Expect (($dirty.Left -eq 0) -and ($dirty.Width -eq 40)) 'the rectangle is that control, not the window'
        Expect ((Update-UiViewHot @($script:ViewA, $script:ViewB) 20 10).IsEmpty) 'staying on it repaints nothing'
        $over = Update-UiViewHot @($script:ViewA, $script:ViewB) 60 10
        Expect (($over.Left -eq 0) -and ($over.Width -eq 90)) 'crossing to the other repaints both'
        $off = Update-UiViewHot @($script:ViewA, $script:ViewB) 200 200
        Expect (($off.Left -eq 50) -and ($off.Width -eq 40)) 'leaving the last one repaints that one'
      }

      It 'picks the topmost control under a point and refuses a disabled one' {
        $top = New-UiView 'button' 'top' @{ Label = 'over' }
        $top.Box = @{ Left = 10; Top = 5; Width = 20; Height = 10 }
        $hit = Hit-UiViewList @($script:ViewA, $top) 15 8
        Expect ([string]$hit.Key -ceq 'top') 'later in the list wins, the way it is drawn'
        $off = New-UiView 'button' 'off' @{ Label = 'off'; Enabled = $false }
        $off.Box = @{ Left = 0; Top = 0; Width = 40; Height = 20 }
        Expect ($null -eq (Hit-UiViewList @($off) 10 10 $true)) 'a disabled control takes no press'
        Expect ([string](Hit-UiViewList @($off) 10 10).Key -ceq 'off') 'but it is still where it is'
      }

      It 'keeps a button across a refresh and updates the one whose state moved' {
        $bar = New-UiView 'chrome' '' @{}
        [void](Mount-UiComponent $bar)
        [void](Sync-UiViews $bar @(
            @{ Key = 'save'; Type = 'button'; Props = @{ Label = 'Save'; Primary = $true } },
            @{ Key = 'discard'; Type = 'button'; Props = @{ Label = 'Discard' } }
          ))
        $save = $bar.Children[0]
        $step = Sync-UiViews $bar @(
          @{ Key = 'save'; Type = 'button'; Props = @{ Label = 'Save'; Primary = $false } },
          @{ Key = 'discard'; Type = 'button'; Props = @{ Label = 'Discard' } }
        )
        Expect ($step.Reused -eq 2 -and $step.Updated -eq 1) 'only the button whose state moved is updated'
        Expect ($step.Children[0] -eq $save) 'the kept button is the same node, with its hover'
      }

      It 'draws the kind it was given and nothing for a kind that is not there' {        $canvas = New-Object Drawing.Bitmap 60, 30
        $gfx = [Drawing.Graphics]::FromImage($canvas)
        try {
          Register-UiView 'probe' { param($g, $pal, $node, $box) $script:ProbeDrawn = [int]$box.Width }
          $n = New-UiView 'probe' 'p' @{ }
          $n.Box = @{ Left = 0; Top = 0; Width = 33; Height = 10 }
          Expect (Draw-UiView $gfx @{} $n) 'a registered kind is drawn'
          Expect ($script:ProbeDrawn -eq 33) 'with the box it was given'
          $unknown = New-UiView 'nope' 'q' @{ }
          $unknown.Box = @{ Left = 0; Top = 0; Width = 5; Height = 5 }
          Expect (-not (Draw-UiView $gfx @{} $unknown)) 'an unknown kind draws nothing'
          Expect (-not (Draw-UiView $gfx @{} (New-UiView 'probe' 'r' @{ }))) 'a control with no box is not on screen'
        } finally { $gfx.Dispose(); $canvas.Dispose() }
      }

      It 'lights a remove cross only under the pointer' {
        # the cross is quiet at rest and turns into a warning mark over a disc when the pointer
        # is on it: the two states have to be visible, or a control nobody can see is a control
        # nobody can aim at
        $pal = @{
          HoverBg = [Drawing.Color]::FromArgb(255, 60, 60, 60)
          Dim     = [Drawing.Color]::FromArgb(255, 140, 140, 140)
          Warn    = [Drawing.Color]::FromArgb(255, 220, 80, 80)
        }
        $n = New-UiView 'row-del' 'del0' @{ }
        $n.Box = @{ Left = 2; Top = 2; Width = [int](Px 16); Height = [int](Px 16) }
        $count = {
          $canvas = New-Object Drawing.Bitmap ([int](Px 20)), ([int](Px 20))
          $gfx = [Drawing.Graphics]::FromImage($canvas)
          try {
            $gfx.Clear([Drawing.Color]::FromArgb(255, 32, 32, 32))
            [void](Draw-UiView $gfx $pal $n)
            $warn = 0
            for ($y = 0; $y -lt $canvas.Height; $y++) {
              for ($x = 0; $x -lt $canvas.Width; $x++) {
                if ($canvas.GetPixel($x, $y).ToArgb() -eq $pal['Warn'].ToArgb()) { $warn++ }
              }
            }
            return $warn
          } finally { $gfx.Dispose(); $canvas.Dispose() }
        }
        [void](Set-UiViewState $n 'Hot' $false)
        Expect ((& $count) -eq 0) 'a quiet cross is drawn in the dim ink'
        [void](Set-UiViewState $n 'Hot' $true)
        Expect ((& $count) -gt 0) 'the hovered one is drawn in the warning ink'

        # the plus is a control too, and an affordance nobody can see is a row with no way in:
        # it fills its box with the field colour and edges it, so the box is not empty afterwards
        $plusPal = @{
          Field = [Drawing.Color]::FromArgb(255, 48, 48, 48); FieldBorder = [Drawing.Color]::FromArgb(255, 80, 80, 80)
          Dim   = [Drawing.Color]::FromArgb(255, 140, 140, 140); Surface = [Drawing.Color]::FromArgb(255, 32, 32, 32)
          Border = [Drawing.Color]::FromArgb(255, 70, 70, 70); Text = [Drawing.Color]::FromArgb(255, 240, 240, 240)
          HoverBg = [Drawing.Color]::FromArgb(255, 60, 60, 60)
        }
        $plus = New-UiView 'row-add' 'add' @{ Enabled = $true }
        $plus.Box = @{ Left = 2; Top = 2; Width = [int](Px 16); Height = [int](Px 16) }
        $canvas = New-Object Drawing.Bitmap ([int](Px 20)), ([int](Px 20))
        $gfx = [Drawing.Graphics]::FromImage($canvas)
        try {
          $gfx.Clear([Drawing.Color]::FromArgb(255, 32, 32, 32))
          Expect (Draw-UiView $gfx $plusPal $plus) 'the plus is a registered kind'
          $painted = 0
          for ($y = 0; $y -lt $canvas.Height; $y++) {
            for ($x = 0; $x -lt $canvas.Width; $x++) {
              if ($canvas.GetPixel($x, $y).ToArgb() -ne [Drawing.Color]::FromArgb(255, 32, 32, 32).ToArgb()) { $painted++ }
            }
          }
          Expect ($painted -gt 50) ('the plus painted ' + $painted + ' pixels')
        } finally { $gfx.Dispose(); $canvas.Dispose() }
      }
    }

    # The data half (lib\ui\reactive.ps1 over Cb.ReactiveBag): a write queues what read it, a
    # flush runs each effect once, a derived value recomputes on access, and stopping an effect
    # gives back everything it held - which is the whole guard against a window that leaks.
    Describe 'ui reactive' {
      BeforeEach {
        Clear-UiRender
        $script:ReactRuns = New-Object System.Collections.Generic.List[string]
      }

      AfterAll { Clear-UiRender }

      It 'queues a write and runs the effect once per flush' {
        $bag = New-UiReactive @{ Pending = 0 }
        $id = Add-UiRender { $script:ReactRuns.Add('run:' + [string]$bag.Pending) }
        Expect (($script:ReactRuns.Count -eq 1) -and ($script:ReactRuns[0] -eq 'run:0')) 'it runs when it is added'
        Expect (-not (Invoke-UiFlush)) 'a read queues nothing'
        [void](Set-UiReactive $bag 'Pending' 1)
        Expect ($script:ReactRuns.Count -eq 1) 'the write does not run it where it happened'
        Expect (Test-UiFlushPending) 'the write queued it'
        Expect (Invoke-UiFlush) 'the flush has something to do'
        Expect (($script:ReactRuns.Count -eq 2) -and ($script:ReactRuns[1] -eq 'run:1')) 'once, with the new value'
        Remove-UiRender $id
      }

      It 'runs once for a batch and ignores a value nobody read' {
        $bag = New-UiReactive @{ Pending = 0; Page = 'a' }
        $id = Add-UiRender { $script:ReactRuns.Add('run'); [void]$bag.Pending }
        [void](Set-UiReactive $bag 'Pending' 1)
        [void](Set-UiReactive $bag 'Pending' 2)
        [void](Set-UiReactive $bag 'Page' 'b')
        [void](Invoke-UiFlush)
        Expect ($script:ReactRuns.Count -eq 2) 'three writes, one run beside the first'
        Expect (-not (Set-UiReactive $bag 'Pending' 2)) 'the same value is not a change'
        Expect (-not (Invoke-UiFlush)) 'and it queues nothing'
        Remove-UiRender $id
      }

      It 'recomputes a derived value on access, and only when a read moved' {
        $bag = New-UiReactive @{ Pending = 2 }
        $id = 0
        $cell = New-UiComputed { $script:ReactRuns.Add('eval'); [int]$bag.Pending * 10 }
        Expect ($cell.Value -eq 20) 'it computed once'
        Expect ($cell.Value -eq 20) 'and a second read answers from the cache'
        Expect ($script:ReactRuns.Count -eq 1) 'one evaluation, not two'
        [void](Set-UiReactive $bag 'Pending' 3)
        Expect ($cell.Dirty) 'the write marked it stale at once'
        Expect ($script:ReactRuns.Count -eq 1) 'and nothing was computed yet'
        [void](Invoke-UiFlush)
        Expect ($cell.Value -eq 30) 'the read after the change recomputes'
        Expect ($script:ReactRuns.Count -eq 2) 'one more evaluation'
        $cell.Dispose()
      }

      It 'gives back what an effect held when it is stopped' {        $bag = New-UiReactive @{ Page = 'a'; Pending = 0 }
        $ids = New-Object System.Collections.Generic.List[int]
        for ($i = 0; $i -lt 3; $i++) {
          $ids.Add((Add-UiRender { $script:ReactRuns.Add('x'); [void]$bag.Page }))
        }
        $stats = Get-UiReactiveStats
        Expect (($stats.Effects -eq 3) -and ($stats.Targets -ge 1)) ('held ' + $stats.Effects + '/' + $stats.Targets)
        foreach ($one in $ids) { Remove-UiRender $one }
        [void](Set-UiReactive $bag 'Page' 'b')
        [void](Invoke-UiFlush)
        $stats = Get-UiReactiveStats
        Expect ($stats.Effects -eq 0) 'no effect is left behind'
        Expect ($stats.Targets -eq 0) 'and the bag holds no dependency any more'
        Expect (-not (Test-UiFlushPending)) 'nothing is queued for it'
      }

      It 'owns a window: one bag, its effects, its derived values, one way out' {
        # the outermost scope: a surface hands it the signals and stops worrying about ids
        $app = New-UiApp @{ Page = 'Clipboard'; Pending = 0 }
        $id = Add-UiAppEffect $app { $script:ReactRuns.Add('render'); [void](Get-UiAppSignal $app 'Pending' 0) }
        $cell = Add-UiAppComputed $app { [int](Get-UiAppSignal $app 'Pending' 0) * 2 }
        Expect ($id -gt 0 -and $null -ne $cell) 'the app holds what it started'
        Expect ($script:ReactRuns.Count -eq 1) 'the effect ran when it was added'
        [void](Set-UiAppSignal $app 'Pending' 3)
        [void](Invoke-UiFlush)
        Expect ($script:ReactRuns.Count -eq 2) 'a write reached it through the app'
        Expect ($cell.Value -eq 6) 'and the derived value followed'
        Close-UiApp $app
        Expect (-not (Test-UiAppOpen $app)) 'it says it is closed'
        Expect ((Get-UiReactiveStats).Effects -eq 0) 'every effect it started is stopped'
        Expect (-not (Set-UiAppSignal $app 'Pending' 9)) 'and a write after closing does nothing'
        Close-UiApp $app
        Expect $true 'closing twice is not an error'
      }
    }

    # A component declared the way <script setup> declares one (lib\ui\setup.ps1): props in, a
    # setup function that answers its bindings, hooks registered while it runs, and content the
    # owner supplies through a slot.
    Describe 'ui setup' {
      It 'runs the setup with its props and keeps what it returned' {
        $made = New-UiSetupView 'chrome' @{ Density = 1 } {
          param($ctx)
          $d = Use-UiProp $ctx 'Density' 1
          $script:SetupSaw = 'd=' + [string]$d
          return @{ Density = $d }
        }
        $node = & $made @{ Key = 'x'; Props = @{ Density = 2 } }
        Expect ($script:SetupSaw -eq 'd=2') 'the caller values win over the component defaults'
        Expect (([string]$node.Key -eq 'x') -and ([string]$node.Type -eq 'chrome')) 'it is a view node under that key'
        $bindings = Get-UiSetupBindings $node
        Expect (($null -ne $bindings) -and ([int]$bindings.Density -eq 2)) 'and it keeps what setup returned'
      }

      It 'attaches the hooks setup registered and refuses a stray one' {
        $script:SetupHits = New-Object System.Collections.Generic.List[string]
        $made = New-UiSetupView 'row' @{ } {
          param($ctx)
          On-UiMounted { param($n, $a) $script:SetupHits.Add('mount:' + [string]$n.Key) }
          On-UiUnmounted { param($n, $a) $script:SetupHits.Add('gone:' + [string]$n.Key) }
          return @{ }
        }
        $node = & $made @{ Key = 'k' }
        [void](Mount-UiComponent $node)
        Unmount-UiComponent $node
        Expect (($script:SetupHits -join ',') -eq 'mount:k,gone:k') ('hits ' + ($script:SetupHits -join ','))
        Expect (-not (On-UiMounted { })) 'outside a setup there is nothing to attach it to'
      }

      It 'asks its owner for content through a scoped slot' {
        $made = New-UiSetupView 'list' @{ } {
          param($ctx)
          return @{ Slot = (Use-UiSlot $ctx 'row') }
        }
        $node = & $made @{ Key = 'l'; Slots = @{ row = { param($scope) 'row-' + [string]$scope.Index } } }
        $ctx = Get-UiSetupContextOf $node
        Expect ([string](Invoke-UiSlot $ctx 'row' @{ Index = 3 }) -eq 'row-3') 'the child passes its own scope'
        Expect ([string](Invoke-UiSlot $ctx 'missing' $null 'fallback') -eq 'fallback') 'a slot nobody supplied falls back'
      }
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
        # a punctuation key is not the character it types: the backtick is 0xC0 as a key, while
        # 0x60 - what the character's code point gives - is the numeric keypad's 0
        $tick = Parse-Hotkey 'Ctrl+Alt+`'
        Expect ($tick.Vk -eq 0xC0) ('vk=0x' + $tick.Vk.ToString('X2'))
        $named = Parse-Hotkey 'Alt+BACKTICK'
        Expect ($named.Vk -eq 0xC0 -and $named.Mods -eq 1) ('vk=0x' + $named.Vk.ToString('X2'))
        # the name and the character both read, because the window records one of them and a
        # hand-written file may hold the other
        $comma = Parse-Hotkey 'Ctrl+COMMA'
        Expect ($comma.Vk -eq 0xBC) ('vk=0x' + $comma.Vk.ToString('X2'))
      }

      It 'Parse-Hotkey leaves an unknown key empty' {
        Expect ((Parse-Hotkey 'Ctrl+Nope').Vk -eq 0) ''
      }

      It 'every key the recorder can name is one the parser reads' {
        # the two tables have to agree: a name the window writes but the schema cannot read is a
        # hotkey that looks recorded, saves, and never registers
        $table = @(
          @{ Key = 0xC0; Name = 'BACKTICK' }
          @{ Key = 0xBD; Name = 'MINUS' }
          @{ Key = 0xBB; Name = 'EQUALS' }
          @{ Key = 0xDB; Name = 'LBRACKET' }
          @{ Key = 0xDD; Name = 'RBRACKET' }
          @{ Key = 0xDC; Name = 'BACKSLASH' }
          @{ Key = 0xBA; Name = 'SEMICOLON' }
          @{ Key = 0xDE; Name = 'QUOTE' }
          @{ Key = 0xBC; Name = 'COMMA' }
          @{ Key = 0xBE; Name = 'PERIOD' }
          @{ Key = 0xBF; Name = 'SLASH' }
        )
        $bad = @()
        foreach ($r in $table) {
          $name = [string](Get-ChordKeyName $r.Key)
          if ($name -ne [string]$r.Name) { $bad += ([string]$r.Name + ' is named ' + $name); continue }
          if ((Parse-Hotkey ('Ctrl+' + $name)).Vk -ne [int]$r.Key) { $bad += ('the parser reads ' + $name + ' as another key') }
        }
        Expect ($bad.Count -eq 0) ($bad -join ', ')
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

      It 'a new flat key lands with the flat keys, not inside the last section' {
        # appending it would put it inside the last [section], where it reads as that section's
        # key: the value is written, never found again, and every save adds another copy
        [IO.File]::WriteAllLines($script:UnitCfg, @('Theme=win11-dark', '', '# plugins', '[item-marks]', 'MaxPins=50'), $Utf8)
        [void](Set-IniKey 'Language' 'zh-CN')
        $kv = Read-Ini
        Expect ($kv['Language'] -eq 'zh-CN') ('Language=' + [string]$kv['Language'])
        Expect (-not $kv.ContainsKey('item-marks.Language')) ''
        $text = [IO.File]::ReadAllText($script:UnitCfg)
        Expect ($text.IndexOf('Language=') -lt $text.IndexOf('[item-marks]')) $text.Trim()
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
        # the chain is read chord by chord: both survive, in the order the file tried them,
        # whichever separator the file used
        $chain = (@($script:HotkeyFallbacks -split '[,;]' | ForEach-Object { $_.Trim() }) -join '|')
        Expect ($chain -eq 'Alt+Q|Alt+W') ('value=' + $script:HotkeyFallbacks)
      }

      It 'an empty file leaves every key with a value of its own' {
        # The contract is that a missing ini never leaves a setting blank - not the particular
        # default: DataDir is a path (a blank would decide nothing) and the fallback chain is
        # what the resident tries after Hotkey fails.
        [IO.File]::WriteAllLines($script:UnitCfg, @(''), $Utf8)
        Apply-Config
        Expect ([string]$script:HotkeyFallbacks -ne '') ('value=' + $script:HotkeyFallbacks)
        Expect ($script:HotkeyFallbacks -eq (Get-SchemaDefault $script:SettingsSchema 'HotkeyFallbacks')) ('value=' + $script:HotkeyFallbacks)
        $dir = [string](Get-ConfigReport)['DataDir']
        Expect ([IO.Path]::IsPathRooted($dir)) ('DataDir=' + $dir)
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

      It 'recognises the shell flyouts that take the keyboard' {
        # Start and search are topmost windows of the shell: the panel closes for them, because
        # its hook would swallow the keys meant for the search box
        Expect (Test-ShellProcessName 'shellhost.exe') ''
        Expect (Test-ShellProcessName 'SearchHost.exe') ''
        # the search host was renamed twice: SearchApp on Windows 10 1903-2004, SearchUI before it
        Expect (Test-ShellProcessName 'SearchApp.exe') ''
        Expect (Test-ShellProcessName 'SearchUI.exe') ''
        Expect (Test-ShellProcessName 'startmenuexperiencehost.exe') ''
        Expect (Test-ShellProcessName 'shellexperiencehost.exe') ''
        Expect (-not (Test-ShellProcessName 'code.exe')) 'code.exe is not a shell flyout'
        Expect (-not (Test-ShellProcessName 'notepad.exe')) 'notepad.exe is not a shell flyout'
        Expect (-not (Test-ShellProcessName '')) 'an empty name is not a shell flyout'
      }

      It 'the tray a click comes from is not a window the panel gives up on' {
        # the tray icon of Windows 11 lives in this topmost island of explorer: a click on it used
        # to be refused as a window that cannot be covered, so the panel never opened
        Expect (Test-ShellWindowClass 'TopLevelWindowForOverflowXamlIsland') ''
        Expect (Test-ShellWindowClass 'Shell_TrayWnd') ''
        Expect (Test-ShellWindowClass 'Shell_SecondaryTrayWnd_1234') ''
        Expect (Test-ShellWindowClass 'NotifyIconOverflowWindow') ''
        # an explorer folder window is a normal paste target, not a shell surface
        Expect (-not (Test-ShellWindowClass 'CabinetWClass')) 'a folder window is a normal target'
        Expect (-not (Test-ShellWindowClass '')) 'an empty class is not a shell surface'
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
    # a table with columns of its own: 8640 twips is 576 px, which the card cannot hold, so the
    # layout engine squeezes the cells instead of laying the rows out the way they were written
    $tableRow = '\trowd\trgaph108\trleft-108\cellx2880\cellx5760\cellx8640'
    $tableRtf = '{\rtf1\ansi\deff0{\fonttbl{\f0\fnil Calibri;}}' + $tableRow + '\intbl 1111111\cell 1111111111111\cell 1111111\cell\row' +
      $tableRow + '\intbl 1111111111111\cell 1111111111111111111\cell 111111111111111111111111\cell\row\pard after\par}'

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

      It 'a table keeps the width it was written with' {
        # the layout engine fits the page into the room it is handed and narrows the columns to
        # do it, so the words in a cell wrap and the table comes apart - while the paste, which
        # parses the rtf itself, stays whole. The widths are in the rtf: \cellx is the right
        # edge of a cell in twips, and 15 twips make a pixel at 96 dpi.
        Expect ((Get-RtfLayoutWidth $tableRtf 380) -eq 576) ([string](Get-RtfLayoutWidth $tableRtf 380))
        # text without a table wraps at the card width: it loses nothing by wrapping
        Expect ((Get-RtfLayoutWidth '{\rtf1\ansi plain words\par}' 380) -eq 380) ''
        # a page that would shrink past the widest card keeps the card width instead
        $hugeRtf = '{\rtf1\ansi\trowd\cellx' + [string](380 * 15 * 8) + '\intbl a\cell\row}'
        Expect ((Get-RtfLayoutWidth $hugeRtf 380) -eq (380 * $script:CardRtfWideMax)) ([string](Get-RtfLayoutWidth $hugeRtf 380))
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

      It 'a wheel notch covers a quarter of the rows on screen' {
        # a short panel must not lose most of its content to one notch, a tall one must not
        # take a dozen, neither may cross a whole screen at once, and ScrollLines wins
        Expect ((Get-WheelStep 6 0) -eq 2) ((Get-WheelStep 6 0) -as [string])
        Expect ((Get-WheelStep 11 0) -eq 3) ((Get-WheelStep 11 0) -as [string])
        Expect ((Get-WheelStep 30 0) -eq 8) ((Get-WheelStep 30 0) -as [string])
        Expect ((Get-WheelStep 2 0) -eq 1) ((Get-WheelStep 2 0) -as [string])
        Expect ((Get-WheelStep 30 2) -eq 2) ((Get-WheelStep 30 2) -as [string])
      }

      It 'reads a saved selection the same however the caller wrapped it' {
        # Regression: the entries came back as one array holding the entries, so the restore
        # loop matched nothing and answered 0 for every open - the paste went to the first
        # character of a field whose element had been re-made (measured on a page that
        # re-renders on blur). Both shapes have to be read the same way.
        $one = @{ Kind = 'edit'; Hwnd = [IntPtr]::Zero; Start = 1; End = 1 }
        Expect ((@(Get-SelectionItems @($one)).Count) -eq 1) 'a plain answer is not read'
        Expect ((@(Get-SelectionItems @(, @($one))).Count) -eq 1) 'a wrapped answer is not read'
        Expect ((@(Get-SelectionItems @()).Count) -eq 0) 'an empty answer is not empty'
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

      It 'only the compact panel follows the caret' {
        # the full panel is the taller one and is a place the user returns to, so it never
        # follows the caret; the compact one is read while typing and always does
        Expect ((Get-PanelPreset 'compact').AnchorCaret -eq $true) ''
        Expect ((Get-PanelPreset 'full').AnchorCaret -eq $false) ''
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

      It 'the frozen rows keep the first digits' {
        # a pinned row never scrolls, so it holds the first numbers on screen and the scrolling
        # part carries on from there - the caps on the rows and the footer's Ctrl+1-9,0 are one
        # run, not two, and a row that scrolled out answers none
        Expect ((Get-VisibleRowOffset 0 5 3) -eq 0) ''
        Expect ((Get-VisibleRowOffset 2 5 3) -eq 2) ''
        Expect ((Get-VisibleRowOffset 3 5 3) -eq -1) ''
        Expect ((Get-VisibleRowOffset 5 5 3) -eq 3) ''
        Expect ((Get-QuickKeyIndex 0 5 20 10 3) -eq 0) ''
        Expect ((Get-QuickKeyIndex 2 5 20 10 3) -eq 2) ''
        Expect ((Get-QuickKeyIndex 3 5 20 10 3) -eq 5) ''
        Expect ((Get-QuickKeyIndex 9 5 20 10 3) -eq 11) ''
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

      It 'the screen is chosen by the point, and a panel is pushed inside it' {
        # the second screen holds this caret; a point outside every screen keeps the fallback
        Expect ((Get-AreaAt $script:PickerAreas $script:PickerFallbackArea 2200 300).Left -eq 1920) ([string](Get-AreaAt $script:PickerAreas $script:PickerFallbackArea 2200 300).Left)
        Expect ((Get-AreaAt $script:PickerAreas $script:PickerFallbackArea -50 300).Left -eq 0) ([string](Get-AreaAt $script:PickerAreas $script:PickerFallbackArea -50 300).Left)
        # 1800 + 660 runs off the right edge and 1000 + 430 off the bottom
        $c = Get-ClampedPoint $script:PickerAreas[0] 1800 1000 660 430
        Expect (($c.Left -eq 1260) -and ($c.Top -eq 650)) (($c.Left -as [string]) + ',' + ($c.Top -as [string]))
      }

      It 'the compact panel opens under the caret with the rows that fit' {
        # six 40 px rows and 92 px of chrome are 332 px: 300 + 20 + the 4 px gap
        $p = Get-CompactPlacement 6 40 92 520 $script:PickerFallbackArea 400 300 20 3
        Expect (($p.Left -eq 400) -and ($p.Top -eq 324) -and ($p.Rows -eq 6) -and ($p.Height -eq 332)) (($p.Left -as [string]) + ',' + ($p.Top -as [string]) + ' ' + ($p.Rows -as [string]) + '/' + ($p.Height -as [string]))
      }

      It 'a caret near the bottom flips the panel above and keeps every row' {
        # 1000 + 20 + 4 + 332 runs off the bottom; 1000 - 4 - 332 = 664 fits above it
        $p = Get-CompactPlacement 6 40 92 520 $script:PickerFallbackArea 400 1000 20 3
        Expect (($p.Top -eq 664) -and ($p.Rows -eq 6)) (($p.Top -as [string]) + '/' + ($p.Rows -as [string]))
      }

      It 'a caret with no room on either side gives up rows instead of overlapping it' {
        # a 400 px work area holds seven rows at most; the caret sits 60 px from its bottom,
        # so 316 px remain above and the panel shrinks to the five rows that fits there
        $short = [pscustomobject]@{ Left = 0; Top = 0; Width = 1920; Height = 400 }
        $p = Get-CompactPlacement 6 40 92 520 $short 400 320 20 3
        Expect (($p.Rows -eq 5) -and ($p.Top -eq 24) -and ($p.Height -eq 292)) (($p.Rows -as [string]) + '/' + ($p.Top -as [string]) + '/' + ($p.Height -as [string]))
      }

      It 'a whole control as the anchor keeps the rows by sliding over it' {
        # the same 400 px work area, but the anchor is a 600 px chat box rather than one line:
        # measured from the box's own edge there would be 96 px below and 176 px above, so the
        # panel would drop to three rows although the caret is one line inside the box
        $short = [pscustomobject]@{ Left = 0; Top = 0; Width = 1920; Height = 400 }
        $p = Get-CompactPlacement 6 40 92 520 $short 400 0 600 3
        Expect (($p.Rows -eq 6) -and ($p.Height -eq 332)) (($p.Rows -as [string]) + '/' + ($p.Height -as [string]))
        # and it stops where one row of that control still shows below the panel's top edge
        Expect ($p.Top -eq 44) ($p.Top -as [string])
      }

      It 'one line at the same place still gives up rows' {
        # the box height is what decides, not the position: a one-line anchor 20 px tall in the
        # same work area keeps the old answer
        $short = [pscustomobject]@{ Left = 0; Top = 0; Width = 1920; Height = 400 }
        $p = Get-CompactPlacement 6 40 92 520 $short 400 100 20 3
        Expect (($p.Rows -eq 4) -and ($p.Top -eq 124)) (($p.Rows -as [string]) + '/' + ($p.Top -as [string]))
      }

      It 'a panel that slid over a control still stays inside the work area' {
        # a 600 px control whose top has scrolled above the work area: sliding over it is the
        # only way to keep every row, and the panel may still not run off the screen
        $short = [pscustomobject]@{ Left = 0; Top = 0; Width = 1920; Height = 400 }
        $p = Get-CompactPlacement 6 40 92 520 $short 400 -300 600 3
        Expect ($p.Rows -eq 6) ($p.Rows -as [string])
        Expect (($p.Top -ge 0) -and (($p.Top + $p.Height) -le 400)) (($p.Top -as [string]) + '+' + ($p.Height -as [string]))
      }

      It 'a screen narrower than the panel narrows it' {
        $narrow = [pscustomobject]@{ Left = 0; Top = 0; Width = 400; Height = 1080 }
        $p = Get-CompactPlacement 6 40 92 520 $narrow 10 300 20 3
        Expect (($p.Width -eq 400) -and ($p.Left -eq 0)) (($p.Width -as [string]) + '/' + ($p.Left -as [string]))
      }

      It 'a caret at the right edge keeps the panel on that screen' {
        $p = Get-CompactPlacement 6 40 92 520 $script:PickerFallbackArea 1900 300 20 3
        Expect ($p.Left -eq 1400) ($p.Left -as [string])
      }

      It 'a caret on the second monitor decides the screen' {
        $area = Get-AreaAt $script:PickerAreas $script:PickerFallbackArea 2200 300
        $p = Get-CompactPlacement 6 40 92 520 $area 2200 300 20 3
        Expect ($p.Left -eq 2200) ($p.Left -as [string])
      }

      It 'a menu opens down from the pointer while it fits' {
        # the row menu measures 252 x 549 px on the machine this was taken from
        $m = Get-MenuPlacement $script:PickerFallbackArea 810 302 252 549
        Expect (($m.Left -eq 810) -and ($m.Top -eq 302)) (($m.Left -as [string]) + ',' + ($m.Top -as [string]))
      }

      It 'a menu crossing the bottom edge opens above the pointer' {
        # 622 + 549 = 1171 crosses the 1032 px work area of that machine, where the system only
        # pushed the menu up and left the pointer 140 px inside it, on the row that opened it
        $low = [pscustomobject]@{ Left = 0; Top = 0; Width = 1920; Height = 1032 }
        $m = Get-MenuPlacement $low 810 622 252 549
        Expect (($m.Left -eq 810) -and ($m.Top -eq 73) -and (($m.Top + 549) -eq 622)) (($m.Left -as [string]) + ',' + ($m.Top -as [string]))
      }

      It 'a menu crossing the right edge opens to the left of the pointer' {
        # 1800 + 252 crosses 1920, so the menu ends where the pointer is
        $m = Get-MenuPlacement $script:PickerFallbackArea 1800 300 252 549
        Expect (($m.Left -eq 1548) -and ($m.Top -eq 300)) (($m.Left -as [string]) + ',' + ($m.Top -as [string]))
      }

      It 'a menu taller than the work area keeps its top edge on screen' {
        # neither side can hold it: the flip is kept and then clamped, not run off the top
        $m = Get-MenuPlacement $script:PickerFallbackArea 400 900 252 1200
        Expect ($m.Top -eq 0) ($m.Top -as [string])
      }
    }

    Describe 'settings window model' {
      # The window draws whatever these two files hand it, so what is checked here is that every
      # setting can reach it, that a key reads as words, and that a value the schema refuses is
      # refused before anything is written.
      It 'every page carries an icon of its own' {
        # a row without one would sit out of line with the rest, and the page list is the first
        # thing the window shows: a new group has to say which glyph it wears
        $fallback = Get-SettingsGroupGlyph 'no such group'
        foreach ($name in @((Get-SettingGroupTable).Keys)) {
          Expect ((Get-SettingsGroupGlyph ([string]$name)) -ne $fallback) ([string]$name + ' has no icon of its own')
        }
      }
      It 'every setting the schema declares reaches exactly one group' {
        $seen = @{}
        $twice = @()
        foreach ($g in @(Get-SettingGroups $script:SettingsSchema)) {
          if ($g -ceq 'About') { continue }
          foreach ($row in @(Get-SettingsRows $script:SettingsSchema $g)) {
            if ($seen.ContainsKey($row.Key)) { $twice += $row.Key }
            $seen[$row.Key] = $true
          }
        }
        $props = Get-SchemaProperties $script:SettingsSchema
        Expect ($twice.Count -eq 0) ($twice -join ', ')
        Expect ($seen.Count -eq $props.Count) ([string]$seen.Count + ' of ' + [string]$props.Count)
      }

      It 'a page is marked while one of its keys is staged' {
        # the page list says where an unsaved value lives: a change made on another page has to
        # be visible from the one in front, and a key no page names belongs to Other
        $groups = @(Get-SettingGroupsWithPending $script:SettingsSchema @{ 'MaxItems' = '5' })
        Expect (($groups.Count -eq 1) -and ($groups[0] -ceq 'History')) ($groups -join ',')
        $groups = @(Get-SettingGroupsWithPending $script:SettingsSchema @{ 'nobody.ownsThis' = '1' })
        Expect (($groups.Count -eq 1) -and ($groups[0] -ceq 'Other')) ($groups -join ',')
        Expect (@(Get-SettingGroupsWithPending $script:SettingsSchema @{}).Count -eq 0) 'an empty set marked a page'
      }

      It 'a choice that names keys is read as the keys, not as their spelling' {
        # the list is where a person picks which combination to paste with: "^+{INSERT}" says
        # nothing to a reader, Ctrl, Shift and Insert say it all
        Expect ((@(Get-SettingChoiceKeys '^+{INSERT}') -join '+') -eq 'Ctrl+Shift+Insert') (@(Get-SettingChoiceKeys '^+{INSERT}') -join '+')
        Expect ((@(Get-SettingChoiceKeys '^v') -join '+') -eq 'Ctrl+V') (@(Get-SettingChoiceKeys '^v') -join '+')
        # a word choice names no keys, so the list draws the word
        Expect (@(Get-SettingChoiceKeys 'win11-dark').Count -eq 0) 'a word choice was read as keys'
      }

      It 'a key reads as its words' {
        # compared case-sensitively on purpose: -eq ignores case, so "Max text total size" would
        # pass too, and every word of a label is meant to keep the capital its key gave it
        Expect ((Get-SettingLabel 'MaxTextTotalBytes') -ceq 'Max Text Total Size') (Get-SettingLabel 'MaxTextTotalBytes')
        Expect ((Get-SettingLabel 'Rows') -ceq 'Rows') (Get-SettingLabel 'Rows')
        Expect ((Get-SettingLabel 'CompactMode') -ceq 'Compact Mode') (Get-SettingLabel 'CompactMode')
        # a format's name is written the way the format writes it, not in the key's camel case
        Expect ((Get-SettingLabel 'MaxRtfBytes') -ceq 'Max RTF Size') (Get-SettingLabel 'MaxRtfBytes')
      }

      It 'the window is a single one, and a second request rings its doorbell' {
        # the lock exists only while a window does: a request that cannot take it has to reach the
        # open window instead of opening a second copy of it. Names of its own, or the test would
        # fail whenever the window happens to be open on the machine running it.
        $name = 'Local\clipboard.test.settings.' + $PID
        $ring = $name + '.ring'
        $first = Open-SettingsLock $name
        Expect ($null -ne $first) 'the first request was refused its lock'
        try {
          Expect ($null -eq (Open-SettingsLock $name)) 'a second window would have opened'
          # the picker asks this before it opens: a second modal window on the same thread takes
          # the input away from the settings window
          Expect (Test-SettingsWindowOpen $name) 'a window was reported closed while it held the lock'
          $ask = Open-SettingsAsk $ring
          Expect ($null -ne $ask) 'the open window has no doorbell'
          try {
            Expect (-not $ask.WaitOne(0)) 'the doorbell rang on its own'
            Expect (Ring-SettingsAsk $ring) 'the ring did not reach the open window'
            Expect ($ask.WaitOne(0)) 'the signal never arrived'
          } finally { $ask.Dispose() }
        } finally { $first.Dispose() }
        # once the window is gone the lock is free again
        $again = Open-SettingsLock $name
        Expect ($null -ne $again) 'the lock outlived the window'
        if ($null -ne $again) { $again.Dispose() }
        Expect (-not (Test-SettingsWindowOpen $name)) 'a closed window was still reported open'
      }

      It 'the list scrolls by distance, so a half row is still a row under the pointer' {
        # the offset is a pixel distance: a click lands on whatever row the paint put under it,
        # and a drag can stop between two rows
        $layout = Get-SettingsLayout 780 700
        $rowH = [int]$layout.RowHeight
        $x = [int]$layout.ListLeft + (Px 10)
        $top = [int]$layout.ListTop
        Expect ((Get-SettingsRowAt $layout 20 0 $x $top) -eq 0) 'the first row is not at the top'
        # 30 px of scroll: the top of the list is the lower part of row 0
        Expect ((Get-SettingsRowAt $layout 20 30 $x $top) -eq 0) 'a half-scrolled row 0 was lost'
        Expect ((Get-SettingsRowAt $layout 20 30 $x ($top + ($rowH - 10))) -eq 1) 'the second row moved by the offset'
        # one whole row of scroll puts row 1 at the top
        Expect ((Get-SettingsRowAt $layout 20 $rowH $x $top) -eq 1) 'a whole-row offset did not advance the list'
        Expect ((Get-SettingsRowAt $layout 20 0 $x ($top - 1)) -eq -1) 'a click above the list picked a row'
      }

      It 'the thumb travels over the distance there is to scroll' {
        $layout = Get-SettingsLayout 780 700
        $vis = Get-SettingsVisibleRows $layout
        $rows = 40
        $track = [int]$layout.ListBottom - [int]$layout.ListTop
        $span = ($rows * [int]$layout.RowHeight) - $track
        $start = Get-SettingsScrollThumb $layout $rows $vis 0
        $end = Get-SettingsScrollThumb $layout $rows $vis $span
        $half = Get-SettingsScrollThumb $layout $rows $vis ([int]($span / 2))
        Expect ($null -ne $start -and $null -ne $end) 'a long list has no thumb'
        Expect ($start.Span -eq $span) ([string]$start.Span + ' of ' + [string]$span)
        Expect ($start.Top -eq [int]$layout.ListTop) ([string]$start.Top)
        Expect (($end.Top + $end.Len) -eq [int]$layout.ListBottom) ([string]($end.Top + $end.Len))
        # halfway down the content is halfway down the track, within the rounding of one pixel
        $mid = ($start.Top + $end.Top) / 2
        Expect ([Math]::Abs($half.Top - $mid) -le 1) ([string]$half.Top + ' vs ' + [string]$mid)
      }

      It 'each schema type maps onto one of the editors the window has' {
        $kinds = @{}
        foreach ($k in @((Get-SchemaProperties $script:SettingsSchema).Keys)) {
          $kind = Get-SettingKind (Get-SchemaProperty $script:SettingsSchema $k)
          $kinds[$kind] = $true
        }
        # four behaviours, not eight types: the window would have to draw eight otherwise
        $allowed = @('bool', 'number', 'text', 'hotkey', 'theme', 'choice', 'regex', 'list', 'rules')
        $unknown = @()
        foreach ($k in @($kinds.Keys)) { if ($allowed -notcontains $k) { $unknown += $k } }
        Expect ($unknown.Count -eq 0) ($unknown -join ', ')
        Expect ($kinds.ContainsKey('bool') -and $kinds.ContainsKey('number') -and $kinds.ContainsKey('theme')) ($kinds.Keys -join ',')
      }

      It 'a size is shown and typed in the unit it reads best in' {
        # the row must never ask anyone to read seven digits, and a typed number has to come back
        # as the bytes the file stores
        $mb = Get-SettingNumberView $script:SettingsSchema 'MaxImageBytes' '16777216'
        Expect (($mb.Number -eq '16') -and ($mb.Unit -eq 'MB') -and ([double]$mb.Scale -eq 1048576)) ($mb.Number + ' ' + $mb.Unit + ' ' + $mb.Scale)
        $kb = Get-SettingNumberView $script:SettingsSchema 'HighlightMaxBytes' '8192'
        Expect (($kb.Number -eq '8') -and ($kb.Unit -eq 'KB')) ($kb.Number + ' ' + $kb.Unit)
        $ms = Get-SettingNumberView $script:SettingsSchema 'ModReleaseTimeout' '1200'
        Expect (($ms.Number -eq '1200') -and ($ms.Unit -eq 'ms')) ($ms.Number + ' ' + $ms.Unit)
        $back = Convert-SettingNumberInput $script:SettingsSchema 'MaxImageBytes' '16' 1048576
        Expect (($back.Ok) -and ([string]$back.Value -eq '16777216')) ([string]$back.Value)
        $half = Convert-SettingNumberInput $script:SettingsSchema 'MaxImageBytes' '0.5' 1048576
        Expect (($half.Ok) -and ([string]$half.Value -eq '524288')) ([string]$half.Value)
      }

      It 'an empty number holds its hint and still states its unit' {
        # a position left empty follows the screen: the field has to say so rather than go blank,
        # and the unit stays because it says what that empty value would be measured in
        $auto = Format-SettingText $script:SettingsSchema 'WindowLeft' ''
        Expect ($auto -eq [string](Get-SchemaHint $script:SettingsSchema 'WindowLeft')) $auto
        $empty = Get-SettingNumberView $script:SettingsSchema 'WindowLeft' ''
        $px = [string](Get-SchemaProperty $script:SettingsSchema 'WindowLeft')['Unit']
        Expect (($empty.Number -eq '') -and ($empty.Unit -eq $px)) ($empty.Number + ' ' + $empty.Unit)
        # a size takes its unit from the magnitude, so an empty one has none to state
        Expect ((Get-SettingNumberView $script:SettingsSchema 'MaxImageBytes' '').Unit -eq '') 'a size stated a unit it could not pick'
      }

      It 'a recording asks the resident for the chord it holds' {
        # RegisterHotKey eats the chord, so the resident hands it over through two files: the
        # window writes the request, the resident answers, the window reads it back. The whole
        # handshake is file I/O, which is what makes it checkable without a desktop.
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('cb-record-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($dir)
        try {
          Expect ((Read-HotkeyRecord $dir) -eq '') 'nothing before the request'
          Expect (Start-HotkeyRecord $dir) 'the request was not written'
          Expect (Test-HotkeyRecordRequested $dir) 'the resident does not see the request'
          Expect (-not (Send-HotkeyRecord $dir '')) 'an empty chord was handed over'
          Expect (Send-HotkeyRecord $dir 'Ctrl+Alt+J') 'the chord was not handed over'
          $got = Read-HotkeyRecord $dir
          Expect ($got -eq 'Ctrl+Alt+J') $got
          Stop-HotkeyRecord $dir
          Expect ((Read-HotkeyRecord $dir) -eq '') 'the answer survived the end of the recording'
        } finally {
          Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
      }

      It 'a shortcut is drawn in the order Windows prints it' {
        # the file may spell the modifiers in any order; the caps have to read Win, Ctrl, Alt,
        # Shift, key, which is one order whatever the ini says
        $keys = (@(Get-SettingChordKeys 'Alt+Ctrl+V') -join ' ')
        Expect ($keys -eq 'Ctrl Alt V') $keys
        $again = (@(Get-SettingChordKeys 'Shift+Win+V') -join ' ')
        Expect ($again -eq 'Win Shift V') $again
        # a punctuation key is drawn as the character it types, not the name the file uses; the
        # comma is also the chain's separator, so it is the case a reader must not see as a name
        Expect ((@(Get-SettingChordKeys 'Alt+BACKTICK') -join ' ') -eq 'Alt `') (@(Get-SettingChordKeys 'Alt+BACKTICK') -join ' ')
        Expect ((@(Get-SettingChordKeys 'Ctrl+COMMA') -join ' ') -eq 'Ctrl ,') (@(Get-SettingChordKeys 'Ctrl+COMMA') -join ' ')
      }

      It 'a chain offers a plus on its next free line' {
        # the row used to have no way in: the whole value column was a recording target, so a
        # press beside the caps started one by accident. The plus sits on the line the chain can
        # still hold, in the delete column, and only while there is room - three lines are all
        # the card holds.
        $layout = @{ ListRight = [int](Px 900) }
        for ($i = 0; $i -lt 3; $i++) {
          $line = Get-SettingsChordLineRect $layout 0 $i
          $r = Get-SettingsChordAddRect $layout 0 $i
          Expect ([int]$r.Width -gt 0) ('no plus at ' + $i)
          Expect ([int]$r.Top -ge [int]$line.Top) ('the plus sits above its line at ' + $i)
          $fits = (([int]$r.Top + [int]$r.Height) -le ([int]$line.Top + [int]$line.Height))
          Expect $fits ('the plus overflows its line at ' + $i)
        }
        # The plus and the cross are controls of their own, matched by key: the same line has to
        # answer the same key on every refresh, and a press has to read back which line it hit.
        $key = New-SettingControlKey 'HotkeyFallbacks' 'del2'
        $parts = Get-SettingControlKeyParts $key
        Expect ([string]$parts.Row -ceq 'HotkeyFallbacks') ('row ' + $parts.Row)
        Expect ([int]$parts.Index -eq 2) ('index ' + $parts.Index)
        $add = Get-SettingControlKeyParts (New-SettingControlKey 'HotkeyFallbacks' 'add')
        Expect (([string]$add.What -ceq 'add') -and ([int]$add.Index -eq -1)) 'the plus is not a line'
        Expect ([string](Get-SettingControlKeyParts 'NoHash').What -eq '') 'a row key is not a control'
      }

      It 'a recorded chord is written in the spelling the parser reads' {
        $a = Format-ChordValue $false $true $true $false 'J'
        Expect ($a -eq 'Ctrl+Alt+J') $a
        $b = Format-ChordValue $true $false $false $true 'V'
        Expect ($b -eq 'Win+Shift+V') $b
        # a bare key would take that key away from every program, so only F1-F24 pass alone
        Expect (-not (Test-ChordUsable 'J')) 'J'
        Expect (Test-ChordUsable 'F9') 'F9'
        Expect (Test-ChordUsable 'Ctrl+J') 'Ctrl+J'
      }

      It 'a value the schema refuses never reaches the writer' {
        $bad = Convert-SettingInput $script:SettingsSchema 'PasteSettle' '-5'
        Expect (-not $bad.Ok) ([string]$bad.Value)
        $good = Convert-SettingInput $script:SettingsSchema 'PasteSettle' '150'
        Expect (($good.Ok) -and ([string]$good.Value -eq '150')) ([string]$good.Value)
        $switch = Convert-SettingInput $script:SettingsSchema 'CaptureImages' 'on'
        Expect (($switch.Ok) -and ([string]$switch.Value -eq '1')) ([string]$switch.Value)
      }

      It 'a chain is checked chord by chord' {
        # the chain is tried in order, so one unreadable chord is a fallback that would never
        # register; the answer has to name the chord, not just refuse the whole line
        $bad = Convert-SettingInput $script:SettingsSchema 'HotkeyFallbacks' 'Ctrl+Alt+V, Ctrl+Nonsense'
        Expect (-not $bad.Ok) 'a chord the parser cannot read was accepted'
        Expect ([string]$bad.Error -match 'Ctrl\+Nonsense') ([string]$bad.Error)
        $good = Convert-SettingInput $script:SettingsSchema 'HotkeyFallbacks' (Get-SchemaDefault $script:SettingsSchema 'HotkeyFallbacks')
        Expect ($good.Ok) ([string]$good.Error)
        # the file may separate with either mark; what is written back is one spelling
        $semi = Convert-SettingInput $script:SettingsSchema 'HotkeyFallbacks' 'Alt+Q;Alt+W'
        Expect (($semi.Ok) -and ([string]$semi.Value -eq 'Alt+Q, Alt+W')) ([string]$semi.Value)
        # the settings card holds three chord lines, so a fourth has nowhere to be shown or removed
        $many = Convert-SettingInput $script:SettingsSchema 'HotkeyFallbacks' 'Alt+Q, Alt+W, Alt+E, Alt+R'
        Expect (-not $many.Ok) ('a fourth chord was accepted: ' + [string]$many.Value)
        # the row shows one cap per chord, so a ';' file is not drawn as one cap holding both
        $caps = @(Get-SettingChordList $script:SettingsSchema 'HotkeyFallbacks' 'Alt+Q;Alt+W, Ctrl+V')
        Expect (($caps.Count -eq 3) -and ([string]$caps[2] -eq 'Ctrl+V')) ($caps -join ' | ')
      }

      It 'a chain is drawn as a list, a single hotkey as one line' {
        # both are recorded, but a chain is a list: the window draws a line per chord with its own
        # delete button, and a recorded chord joins the end instead of replacing the list
        $rows = @(Get-SettingsRows $script:SettingsSchema 'Hotkey')
        $hot = @($rows | Where-Object { $_.Key -eq 'Hotkey' })[0]
        $chain = @($rows | Where-Object { $_.Key -eq 'HotkeyFallbacks' })[0]
        Expect ([bool]$hot.Record -and (-not [bool]$hot.Chain)) 'the single hotkey'
        Expect ([bool]$chain.Record -and [bool]$chain.Chain) 'the chain'
        Expect (@($chain.Chords).Count -ge 2) ([string]@($chain.Chords).Count)
        # adding appends in the order the resident tries them, and the same chord twice is no help
        $added = Get-SettingChordAdded 'Ctrl+Alt+V, Win+V' 'Alt+Q'
        Expect ($added -eq 'Ctrl+Alt+V, Win+V, Alt+Q') $added
        $again = Get-SettingChordAdded $added 'alt+q'
        Expect ($again -eq $added) $again
        # three is the limit: a fourth would be in the file and in the order the resident tries,
        # but drawn nowhere and removable nowhere
        $full = Get-SettingChordAdded $added 'Alt+Z'
        Expect ($full -eq $added) $full
        # removing the last chord is refused: a chain with nothing in it falls back to the default
        $less = Get-SettingChordRemoved 'Ctrl+V, Alt+Q' 'Ctrl+V'
        Expect ($less -eq 'Alt+Q') $less
        Expect ($null -eq (Get-SettingChordRemoved 'Ctrl+V' 'Ctrl+V')) 'the last chord was removed'
      }

      It 'the paste keys read as the keys they send' {
        # the file spells them in SendKeys (^v); a person reads them as Ctrl and V
        Expect ((Convert-SendKeysToChord '^v') -eq 'Ctrl+V') (Convert-SendKeysToChord '^v')
        Expect ((Convert-SendKeysToChord '^+{INSERT}') -eq 'Ctrl+Shift+Insert') (Convert-SendKeysToChord '^+{INSERT}')
        Expect ((Convert-SendKeysToChord '^{INSERT}') -eq 'Ctrl+Insert') (Convert-SendKeysToChord '^{INSERT}')
        $caps = @(Get-SettingChordList $script:SettingsSchema 'PasteKeys' '^v')
        Expect (($caps.Count -eq 1) -and ([string]$caps[0] -eq 'Ctrl+V')) ($caps -join ' | ')
      }

      It 'a setting only install acts on says when it takes effect' {
        # these two keys build or remove a shortcut, which no reload can do, so a window that
        # ticked them and said nothing would look broken
        Expect (Test-SchemaInstallOnly $script:SettingsSchema 'Autostart') 'Autostart'
        Expect (Test-SchemaInstallOnly $script:SettingsSchema 'DesktopShortcut') 'DesktopShortcut'
        Expect (-not (Test-SchemaInstallOnly $script:SettingsSchema 'Hotkey')) 'Hotkey'
        $help = Get-SettingHelp $script:SettingsSchema 'DesktopShortcut'
        Expect ([string]$help -match 'next install') ([string]$help)
      }

      It 'the store location is a value the file has to hold' {
        # an empty DataDir would leave the write location undecided, so the schema refuses it
        # instead of quietly meaning the default
        $bad = Convert-SettingInput $script:SettingsSchema 'DataDir' ''
        Expect (-not $bad.Ok) 'an empty DataDir was accepted'
        Expect (Test-SchemaRequired $script:SettingsSchema 'DataDir') 'DataDir is not required'
        $good = Convert-SettingInput $script:SettingsSchema 'DataDir' (Get-SchemaDefault $script:SettingsSchema 'DataDir')
        Expect ($good.Ok) ([string]$good.Error)
        # the empty spelling is still fine where it means "not set"
        Expect (-not (Test-SchemaRequired $script:SettingsSchema 'ExcludePattern')) 'ExcludePattern'
      }

      It 'the last page states the version and the store' {
        # About is not built from schema keys, so it is the one group that exists whatever the
        # schema says, and every one of its rows is a statement rather than a control - the one
        # row that can be pressed is the link to the repository, which leaves the window instead
        # of changing anything
        $groups = @(Get-SettingGroups $script:SettingsSchema)
        Expect ($groups.Count -gt 0 -and $groups[$groups.Count - 1] -eq 'About') ($groups -join ',')
        $rows = @(Get-SettingsRows $script:SettingsSchema 'About')
        $version = @($rows | Where-Object { $_.Label -eq 'Version' })
        Expect (($version.Count -eq 1) -and ([string]$version[0].Text -match [regex]::Escape([string]$script:Version))) ([string]$version[0].Text)
        $clickable = @($rows | Where-Object { $_.Record -or $_.Pick -or (-not $_.Locked) })
        $links = @($clickable | Where-Object { $_.Kind -eq 'link' })
        Expect ($clickable.Count -eq $links.Count) (@($clickable | ForEach-Object { $_.Label }) -join ', ')
        Expect ($links.Count -eq 1) ([string]$links.Count)
        Expect ([string]$links[0].Url -eq [string]$script:ProjectUrl) ([string]$links[0].Url)
      }

      It 'a staged value is what the page shows, before anything is written' {        # the window writes nothing until Save, so the row has to draw the staged value and mark
        # itself, and a row a staged switch owns has to grey out before the file changes
        $pending = @{ 'MaxImageBytes' = '4194304'; 'CaptureImages' = '0' }
        $rows = @(Get-SettingsRows $script:SettingsSchema 'Clipboard' $pending)
        $bytes = @($rows | Where-Object { $_.Key -eq 'MaxImageBytes' })[0]
        Expect (([string]$bytes.Text -eq '4 MB') -and [bool]$bytes.Pending) ([string]$bytes.Text)
        Expect (-not [bool]$bytes.Enabled) 'the cap stayed enabled with capture off'
        $switch = @($rows | Where-Object { $_.Key -eq 'CaptureImages' })[0]
        Expect ([string]$switch.Raw -eq '0') ([string]$switch.Raw)
        # a key nobody staged keeps reporting the file
        $plain = @($rows | Where-Object { $_.Key -eq 'Interval' })[0]
        Expect (-not [bool]$plain.Pending) 'Interval was marked as staged'
      }

      It 'saving writes the staged set, and only the staged set' {
        [IO.File]::WriteAllLines($script:UnitCfg, @('Rows=10'), $Utf8)
        Apply-Config
        $r = Save-SettingsValues @{ 'Rows' = '14'; 'MaxItems' = '500' }
        Expect ($r.Ok) ([string]$r.Error)
        Expect (($script:Rows -eq 14) -and ($script:MaxItems -eq 500)) ([string]$script:Rows + '/' + [string]$script:MaxItems)
        # both reached the file, not only the running settings
        Expect ((Get-IniKey 'Rows') -eq '14') ([string](Get-IniKey 'Rows'))
        Expect ((Get-IniKey 'MaxItems') -eq '500') ([string](Get-IniKey 'MaxItems'))
      }

      It 'restore defaults stages the defaults and leaves the store location alone' {
        [IO.File]::WriteAllLines($script:UnitCfg, @('Rows=42', ('MaxItems=' + [string]([int](Get-SchemaDefault $script:SettingsSchema 'MaxItems')))), $Utf8)
        Apply-Config
        $next = Get-SettingDefaultStaging $script:SettingsSchema $null
        Expect ([string]$next['Rows'] -eq [string]([int](Get-SchemaDefault $script:SettingsSchema 'Rows'))) ([string]$next['Rows'])
        # a key already at its default is not staged, and the read-only store location is never
        # something the window decides
        Expect (-not $next.ContainsKey('MaxItems')) 'MaxItems'
        Expect (-not $next.ContainsKey('DataDir')) 'DataDir'
        # the staged value counts as what the key holds: one already staged at its default is not
        # staged again, and one staged away from it is
        $def = [string]([int](Get-SchemaDefault $script:SettingsSchema 'Rows'))
        Expect (-not (Get-SettingDefaultStaging $script:SettingsSchema @{ 'Rows' = $def }).ContainsKey('Rows')) 'Rows at its default'
        Expect ([string](Get-SettingDefaultStaging $script:SettingsSchema @{ 'Rows' = '7' })['Rows'] -eq $def) 'Rows away from it'
      }

      It 'the window edge is one opaque ring on all four sides' {
        # Two defects this guards, both seen on screen: the sides that lie exactly on the pixel
        # boundary were rasterized away, and a translucent edge painted again on every repaint
        # drifted lighter because the surface under it is clipped in that same row.
        $bg = [Drawing.Color]::FromArgb(255, 32, 32, 32)
        $edge = [Drawing.Color]::FromArgb(255, 255, 255, 255)
        $bmp = New-Object Drawing.Bitmap 200, 120
        $g = [Drawing.Graphics]::FromImage($bmp)
        try {
          $g.Clear($bg)
          Draw-PanelFrame $g 200 120 $edge 8 $bg
          $first = $bmp.GetPixel(100, 0).ToArgb()
          # a repaint starts from the same surface and must land on the same colour
          $g.Clear($bg)
          Draw-PanelFrame $g 200 120 $edge 8 $bg
          $sides = @($bmp.GetPixel(100, 0), $bmp.GetPixel(100, 119), $bmp.GetPixel(0, 60), $bmp.GetPixel(199, 60))
          $flat = ''
          $same = $true
          foreach ($p in $sides) {
            $flat += ($p.ToArgb() -as [string]) + ' '
            if ($p.ToArgb() -ne $first) { $same = $false }
          }
          Expect (($first -ne $bg.ToArgb()) -and $same) $flat
        } finally { $g.Dispose(); $bmp.Dispose() }
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

      It 'the assembly answers a plain line as the readable path does' {
        # The panel hands plain words to Cb.Search on every keystroke. A difference in either
        # direction shows up as a row that is there, or missing, only while typing - so the two
        # paths are held to the same answer, including the 4096 char head both of them read.
        $search = $null
        try { $search = [Cb.Search] } catch { $search = $null }
        if ($null -eq $search) { Skip-Test 'the assembly is not built here'; return }
        $inside = ('x' * 4090) + 'needle' + ('y' * 100)
        $past = ('x' * 5000) + 'needle'
        $rows = @($qRows) + @((New-Record $inside 5 ''), (New-Record $past 4 ''))
        $heads = New-QueryHeads $rows
        Expect ($heads.Count -eq $rows.Count) ([string]$heads.Count)
        foreach ($line in @('', 'alpha', 'ALPHA', 'alpha -two', '"alpha t"', 'beta', 'zzz', '-alpha', 'needle', 'x')) {
          $query = New-Query -Line $line
          $want = @(Invoke-Query $rows $query | ForEach-Object { [array]::IndexOf($rows, $_) })
          $got = @([Cb.Search]::Pick($rows, [Cb.Search]::Match($heads, [string[]]@($query.Terms), [string[]]@($query.Excludes))) | ForEach-Object { [array]::IndexOf($rows, $_) })
          Expect (($got -join ',') -eq ($want -join ',')) ($line + ': ' + ($got -join ',') + ' vs ' + ($want -join ','))
        }
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
      It 'the report names every key the schema has' {
        # a key missing here is invisible in `clipboard config` and reads as an empty value in
        # `config set`, which is how a saved language looked like it was never applied
        $report = Get-ConfigReport
        $missing = @()
        foreach ($k in @((Get-SchemaProperties $script:SettingsSchema).Keys)) {
          if (-not $report.Contains([string]$k)) { $missing += $k }
        }
        Expect ($missing.Count -eq 0) ($missing -join ', ')
      }

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

      It 'the plugin list is the names it gives, and an empty value is every plugin on disk' {
        # a write never leaves a symbol behind: the file names the plugins it loads
        Expect (((Resolve-PluginList 'item-marks; transform' @('a', 'b')) -join ',') -eq 'item-marks,transform') ((Resolve-PluginList 'item-marks; transform' @('a', 'b')) -join ',')
        Expect (((Resolve-PluginList '' @('a', 'b')) -join ',') -eq 'a,b') ((Resolve-PluginList '' @('a', 'b')) -join ',')
        Expect (((Resolve-PluginList '  ' @('a')) -join ',') -eq 'a') ((Resolve-PluginList '  ' @('a')) -join ',')
        # and no shorthand is accepted in place of the names
        Expect (-not (Convert-IniValue 'Plugins' '*').Ok) ((Convert-IniValue 'Plugins' '*').Error)
      }

      It 'the default of the plugin list names the plugins that are there' {
        # Restore defaults puts back the value a fresh file carries: the names, not a blank that
        # has to be resolved against the folder at read time
        $def = [string](Get-SchemaDefault $script:SettingsSchema 'Plugins')
        $onDisk = @(Get-AllPluginNames (Join-Path $Root 'plugins'))
        Expect ($def -ne '') $def
        $named = @($def -split ',')
        Expect (@($named | Where-Object { $onDisk -notcontains $_ }).Count -eq 0) $def
      }
    }

    # -------------------------------------------------------------------- text
    Describe 'language files' {
      AfterAll { [void](Initialize-Text 'en') }

      It 'a key no file carries comes back as itself' {
        # an unfinished translation has to be visible, not blank and not an exception
        Expect ((Get-UiText 'panel.noSuchKey') -eq 'panel.noSuchKey') (Get-UiText 'panel.noSuchKey')
        Expect ((Get-UiTextOr 'panel.noSuchKey' 'plain') -eq 'plain') (Get-UiTextOr 'panel.noSuchKey' 'plain')
      }

      It 'a count picks the form the language has, with the number in it' {
        # English has a separate singular; both forms carry what they were given
        $one = Get-UiTextCount 'menu.entries' 1
        $many = Get-UiTextCount 'menu.entries' 25
        Expect ($one -ne $many) ($one + ' / ' + $many)
        Expect (($one -match '1') -and ($many -match '25')) ($one + ' / ' + $many)
      }

      It 'every key of the base file is in each language' {
        # en is the base and the fallback, so it is the smaller file: a translation may carry keys
        # of its own (the settings window words), but it may not be missing one of these
        $base = Read-TextFile 'en'
        Expect ($null -ne $base) ''
        foreach ($lang in @(Get-LanguageList)) {
          if ($lang.Code -eq 'en') { continue }
          $other = Read-TextFile $lang.Code
          Expect ($null -ne $other) $lang.Code
          $missing = @(@($base.Map.Keys) | Where-Object { -not $other.Map.ContainsKey($_) })
          Expect ($missing.Count -eq 0) ($lang.Code + ': ' + ($missing -join ', '))
        }
      }

      It 'a greyed row names its reason under settings.why' {
        # The dependency table names the key that owns a row, and the window words the reason
        # under settings.why.<Key>. Written without the prefix the key never matches, and the row
        # kept drawing the table's English sentence in a Chinese window.
        $t = Read-TextFile 'zh-CN'
        Expect ($null -ne $t) 'zh-CN'
        $missing = @()
        $deps = Get-SettingEnabledBy
        foreach ($k in @($deps.Keys)) {
          $owner = $deps[$k]
          if (-not $t.Map.ContainsKey('settings.why.' + [string]$owner.Key)) { $missing += [string]$owner.Key }
        }
        Expect ($missing.Count -eq 0) (@($missing | Select-Object -Unique) -join ', ')
      }

      It 'a translation names every setting, group and unit the window draws' {
        # the window falls back to a spelling derived from the key, which is English by nature:
        # a language that means to be complete has to supply the words itself
        $schema = $script:SettingsSchema
        foreach ($lang in @(Get-LanguageList)) {
          if ($lang.Code -eq 'en') { continue }
          $t = Read-TextFile $lang.Code
          $missing = New-Object System.Collections.Generic.List[string]
          foreach ($k in @((Get-SchemaProperties $schema).Keys)) {
            foreach ($prefix in @('settings.key.', 'settings.desc.')) {
              if (-not $t.Map.ContainsKey($prefix + [string]$k)) { $missing.Add($prefix + [string]$k) }
            }
          }
          foreach ($grp in @((Get-SettingGroupTable).Keys)) {
            if (-not $t.Map.ContainsKey('settings.group.' + [string]$grp)) { $missing.Add('settings.group.' + [string]$grp) }
          }
          foreach ($k in @((Get-SchemaProperties $schema).Keys)) {
            $spec = (Get-SchemaProperties $schema)[$k]
            if ($null -eq $spec -or -not $spec.Contains('Unit')) { continue }
            $u = [string]$spec['Unit']
            if ($u -eq 'size') { continue }
            if (-not $t.Map.ContainsKey('settings.unit.' + $u)) { $missing.Add('settings.unit.' + $u) }
          }
          Expect ($missing.Count -eq 0) ($lang.Code + ': ' + (@($missing | Select-Object -Unique) -join ', '))
        }
      }

      It 'a translation keeps the placeholders of the base line' {
        # a dropped {0} loses the number, a duplicated one throws at format time
        $base = Read-TextFile 'en'
        foreach ($lang in @(Get-LanguageList)) {
          if ($lang.Code -eq 'en') { continue }
          $other = Read-TextFile $lang.Code
          foreach ($k in @($base.Map.Keys)) {
            if (-not $other.Map.ContainsKey($k)) { continue }
            $a = @([regex]::Matches([string]$base.Map[$k], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object)
            $b = @([regex]::Matches([string]$other.Map[$k], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object)
            Expect ((($a -join '') -eq ($b -join ''))) ($lang.Code + ' ' + $k + ': ' + ($a -join '') + ' vs ' + ($b -join ''))
          }
        }
      }

      It 'the language the window offers is the file on disk' {
        # the schema lists the codes; the folder is the truth, so a new file has to be added there
        $codes = @(Get-LanguageList | ForEach-Object { $_.Code })
        $offered = @((Get-SchemaProperty $script:SettingsSchema 'Language')['Enum'])
        $extra = @($codes | Where-Object { $offered -notcontains $_ })
        $gone = @($offered | Where-Object { $codes -notcontains $_ })
        Expect (($extra.Count -eq 0) -and ($gone.Count -eq 0)) (($extra -join ',') + ' / ' + ($gone -join ','))
      }

      It 'a language is offered under the name it calls itself' {        # the stored value is a code, which is also a file name: the row and its list draw the
        # name the language file gives itself, so nobody has to pick by reading a code
        $langs = @(Get-LanguageList)
        $codes = @($langs | ForEach-Object { $_.Code })
        $labels = @(Get-SettingChoiceLabels $script:SettingsSchema 'Language' $codes)
        $wanted = @($langs | ForEach-Object { $_.Name })
        Expect (($labels -join ',') -eq ($wanted -join ',')) ($labels -join ',')
      }

      It 'a translation names every theme on disk' {
        # The dropdown words a theme under settings.choice.Theme.<file name>; a theme no
        # language names keeps its file name, so only the ones this repository ships are held
        # to this - the file name stays the value either way.
        foreach ($lang in @(Get-LanguageList)) {
          if ($lang.Code -eq 'en') { continue }
          $t = Read-TextFile $lang.Code
          Expect ($null -ne $t) $lang.Code
          $missing = @(Get-ThemeNames | Where-Object { -not $t.Map.ContainsKey('settings.choice.Theme.' + [string]$_) })
          Expect ($missing.Count -eq 0) ($lang.Code + ': ' + ($missing -join ', '))
        }
      }

      It 'the words follow the file without a reload' {
        # a settings window in a process of its own writes the code; the panel and the tray read
        # it when they open, so no process has to restart for a word
        $before = ''
        if (Test-Path -LiteralPath $IniPath) { $before = [IO.File]::ReadAllText($IniPath) }
        try {
          [IO.File]::WriteAllLines($IniPath, @('Language=zh-CN'), $Utf8)
          Expect ((Sync-UiLanguage) -eq $true) 'the code in the file was not picked up'
          Expect ((Get-UiText 'menu.paste') -ne 'Paste') (Get-UiText 'menu.paste')
          [IO.File]::WriteAllLines($IniPath, @('Language=en'), $Utf8)
          Expect ((Sync-UiLanguage) -eq $true) 'the code in the file was not picked up'
          Expect ((Get-UiText 'menu.paste') -eq 'Paste') (Get-UiText 'menu.paste')
          Expect ((Sync-UiLanguage) -eq $false) 'an unchanged code reloaded the words anyway'
        } finally {
          if ($before) { [IO.File]::WriteAllText($IniPath, $before, (New-Object Text.UTF8Encoding $false)) }
          [void](Sync-UiLanguage)
        }
      }

      It 'a language names the family it needs, and the base names none' {
        [void](Initialize-Text 'zh-CN')
        Expect ((Get-UiText 'menu.paste') -ne 'menu.paste') (Get-UiText 'menu.paste')
        Expect ((Get-UiTextFont) -ne '') (Get-UiTextFont)
        [void](Initialize-Text 'en')
        Expect ((Get-UiTextFont) -eq '') (Get-UiTextFont)
        Expect ((Get-UiText 'menu.paste') -ne 'menu.paste') (Get-UiText 'menu.paste')
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

      It 'a mode goes by one word in the settings window and in the menu' {
        # The dropdown words a value under settings.choice.<Key>.<value>, the list beside it
        # borrows those words through Labels, and the context menu asks for the same entry -
        # so a language cannot name one mode twice, and the mode is never left as its code.
        [IO.File]::WriteAllLines($cfg, @('transform.Mode=keep', 'transform.Modes=text,snake'), $Utf8)
        $script:IniCache = $null
        Apply-PluginSettings
        [void](Initialize-Text 'zh-CN')
        try {
          $modes = @((Get-SchemaProperty $script:SettingsSchema 'transform.Mode')['Enum'])
          $one = @(Get-SettingChoiceLabels $script:SettingsSchema 'transform.Mode' $modes)
          for ($i = 0; $i -lt $modes.Count; $i++) {
            $m = [string]$modes[$i]
            Expect ($one[$i] -cne $m) ($m + ' is still the code')
            if ($m -eq 'keep') { continue }
            $list = @(Get-SettingChoiceLabels $script:SettingsSchema 'transform.Modes' @($m))
            Expect ($list[0] -ceq $one[$i]) ($m + ': ' + $list[0] + ' vs ' + $one[$i])
          }
          # the menu row carries that word, and a plugin is drawn under its menu caption
          $row = [pscustomobject]@{ Payload = 'Hello World demo'; Marks = '' }
          $acts = @(Get-PluginActions)
          for ($i = 0; $i -lt $acts.Count; $i++) {
            $text = [string](Get-ActionText $acts[$i] $row)
            $m = @('text', 'snake')[$i]
            Expect ($text.Contains([string]$one[[array]::IndexOf($modes, $m)])) $text
          }
          $captions = @(Get-SettingChoiceLabels $script:SettingsSchema 'Plugins' @('transform'))
          Expect ($captions[0] -ceq (Get-UiText 'plugin.caption.transform')) $captions[0]
        } finally { [void](Initialize-Text 'en') }
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

        It 'draws the frame on every side and every corner' {
          # a fill keeps only the pixels whose centre is inside the shape, so the path has to span
          # the whole pixel grid: ending it at width-1 lost the last column and the last row, and
          # the panel showed a frame along the top and the left only
          $fw = 140
          $fh = 90
          $frame = New-Object Drawing.Bitmap $fw, $fh
          $fg = [Drawing.Graphics]::FromImage($frame)
          $clip = New-RoundRegion $fw $fh (Px 8)
          try {
            $fg.Clear([Drawing.Color]::FromArgb(255, 32, 32, 32))
            $fg.SetClip($clip, [Drawing.Drawing2D.CombineMode]::Replace)
            Draw-PanelFrame $fg $fw $fh ([Drawing.Color]::FromArgb(255, 51, 51, 51)) (Px 8)
          } finally {
            $fg.Dispose()
            $clip.Dispose()
          }
          $sides = @(0, 0, 0, 0)
          for ($fx = 40; $fx -lt 100; $fx++) {
            if ($frame.GetPixel($fx, 0).R -eq 51) { $sides[0]++ }
            if ($frame.GetPixel($fx, ($fh - 1)).R -eq 51) { $sides[1]++ }
          }
          for ($fy = 30; $fy -lt 60; $fy++) {
            if ($frame.GetPixel(0, $fy).R -eq 51) { $sides[2]++ }
            if ($frame.GetPixel(($fw - 1), $fy).R -eq 51) { $sides[3]++ }
          }
          # one pixel thick: the row and the column behind each side stay surface
          $inner = 0
          for ($fx = 40; $fx -lt 100; $fx++) { if ($frame.GetPixel($fx, 1).R -ne 32) { $inner++ } }
          for ($fy = 30; $fy -lt 60; $fy++) { if ($frame.GetPixel(1, $fy).R -ne 32) { $inner++ } }
          $arc = 0
          foreach ($corner in @(@(0, 0), @(($fw - 9), 0), @(0, ($fh - 9)), @(($fw - 9), ($fh - 9)))) {
            for ($fy = 0; $fy -lt 9; $fy++) {
              for ($fx = 0; $fx -lt 9; $fx++) {
                if ($frame.GetPixel(($corner[0] + $fx), ($corner[1] + $fy)).R -eq 51) { $arc++ }
              }
            }
          }
          $frame.Dispose()
          Expect ((($sides[0] -eq 60) -and ($sides[1] -eq 60) -and ($sides[2] -eq 30) -and ($sides[3] -eq 30))) ([string]$sides[0] + '/' + [string]$sides[1] + '/' + [string]$sides[2] + '/' + [string]$sides[3])
          Expect ($inner -eq 0) ([string]$inner + ' pixels behind the frame')
          Expect ($arc -ge 20) ([string]$arc + ' pixels on the four arcs')
        }

        It 'clips the corner children away from the frame' {
          # the header and the footer reach the window edge and paint over the frame's arcs there;
          # they are clipped inside it instead, and only on the side that meets the window, so a
          # separator line inside them keeps both of its ends
          Load-Forms
          $ctl = New-Object Windows.Forms.Panel
          $ctl.Size = New-Object Drawing.Size 200, 60
          Set-FrameCornerRegion $ctl 7 'top'
          $tl = $ctl.Region.IsVisible(1, 1)
          $tr = $ctl.Region.IsVisible(198, 1)
          $bl = $ctl.Region.IsVisible(1, 58)
          $mid = $ctl.Region.IsVisible(100, 30)
          $ctl.Dispose()
          Expect ((-not $tl) -and (-not $tr) -and $bl -and $mid) ([string]$tl + '/' + [string]$tr + '/' + [string]$bl + '/' + [string]$mid)
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

      # The panel takes the foreground when it opens, so the keyboard arrives through the
      # system and there is no input mode to switch between.
      Add-PinList

      Describe 'the self-painted list' {
        It 'claims the keys it is navigated with' {
          # A plain Control reports the arrow keys as dialog keys, so the container answers them
          # to move the focus and the panel's key handler never sees them: the selection could
          # not be walked with them at all. They have to arrive as input keys.
          $pl = New-Object Cb.PinList
          try {
            $m = [Cb.PinList].GetMethod('IsInputKey', [Reflection.BindingFlags]'NonPublic,Instance')
            Expect ($null -ne $m) 'IsInputKey is not overridden'
            foreach ($k in @('Up', 'Down', 'Left', 'Right', 'Home', 'End', 'PageUp', 'PageDown')) {
              $arg = [Windows.Forms.Keys]::$k
              Expect ([bool]$m.Invoke($pl, @($arg))) ('the list gives ' + $k + ' away')
            }
            # everything else stays what it was: a letter is a key press, Enter is a dialog key
            Expect (-not [bool]$m.Invoke($pl, @([Windows.Forms.Keys]::A))) 'a letter must stay a key press'
            Expect (-not [bool]$m.Invoke($pl, @([Windows.Forms.Keys]::Enter))) 'Enter must stay a dialog key'
          } finally { $pl.Dispose() }
        }

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
            $pl.TopIndex = 999
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
            $pl.TopIndex = 3
            $script:plScrolls = 0
            $pl.Add_ScrollChanged({ $script:plScrolls = $script:plScrolls + 1 })
            $wheelM = $pl.GetType().GetMethod('OnMouseWheel', [System.Reflection.BindingFlags]'Instance,NonPublic')
            $wheelArg = New-Object 'object[]' 1
            $wheelArg[0] = [Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::None, 0, 10, 10, -120)
            [void]$wheelM.Invoke($pl, $wheelArg)
            Expect ($pl.TopIndex -eq 5) ([string]$pl.TopIndex)
            Expect ($script:plScrolls -gt 0) ([string]$script:plScrolls)
            $pl.TopIndex = 999
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

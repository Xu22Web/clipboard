#Requires -Version 5.1
<#
  Self tests for clipboard.ps1.

  No external framework: Pester 3.4 is the only one shipped with Windows and its
  syntax is legacy, while this project deliberately stays dependency free.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -Sta -File tests\run-tests.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -Sta -File tests\run-tests.ps1 -Unit
    powershell -NoProfile -ExecutionPolicy Bypass -Sta -File tests\run-tests.ps1 -Integration
    powershell -NoProfile -ExecutionPolicy Bypass -Sta -File tests\run-tests.ps1 -E2E

  -Sta is required: clipboard.ps1 uses System.Windows.Forms.
  Every group runs against a throw-away -DataDir under %TEMP%, so data\ and
  clipboard.ini in the repo are never touched. The real clipboard is saved and
  restored around the run. Exit code is 1 when any check fails.
#>
[CmdletBinding()]
param(
  [switch]$Unit,
  [switch]$Integration,
  [switch]$E2E
)

$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$clipPs1 = Join-Path $repoRoot 'clipboard.ps1'
if (-not (Test-Path -LiteralPath $clipPs1)) { Write-Error ('cannot find ' + $clipPs1); exit 2 }

if (-not ($Unit -or $Integration -or $E2E)) { $Unit = $true; $Integration = $true; $E2E = $true }

$script:results = New-Object System.Collections.Generic.List[object]

function Check([string]$group, [string]$name, [bool]$ok, [string]$detail) {
  $script:results.Add([pscustomobject]@{
      Group  = $group
      Test   = $name
      Result = $(if ($ok) { 'PASS' } else { 'FAIL' })
      Detail = $detail
    })
}

function Skip([string]$group, [string]$name, [string]$why) {
  $script:results.Add([pscustomobject]@{ Group = $group; Test = $name; Result = 'SKIP'; Detail = $why })
}

# run one CLI call in a child process against an isolated data dir
function Clip([string]$dataDir, [string[]]$cliArgs) {
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $clipPs1) + $cliArgs + @('-DataDir', $dataDir)
  return (& powershell @a 2>&1 | Out-String)
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
$unitDir = Join-Path $tmpRoot 'unit'
$intDir = Join-Path $tmpRoot 'integration'
$e2eDir = Join-Path $tmpRoot 'e2e'
foreach ($d in @($unitDir, $intDir, $e2eDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

$clipBak = ''
try { $clipBak = (Get-Clipboard -Raw -ErrorAction Stop) } catch { }

if (-not (Test-MutexFree 'Local\clipboard.daemon')) {
  Write-Warning 'a resident is running: test clipboard writes will land in its history - run "clipboard pause" first'
}

try {

  # ---------------------------------------------------------------- unit tests
  if ($Unit) {
    . $clipPs1 -Library -DataDir $unitDir
    $ErrorActionPreference = 'Continue'   # the dot-sourced script sets Stop

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

    # config file
    $cfg = Join-Path $unitDir 'clipboard.ini'
    if (Test-Path -LiteralPath $cfg) { Remove-Item -LiteralPath $cfg -Force }
    $written = Write-IniTemplate
    Check 'unit' 'Write-IniTemplate creates file' (Test-Path -LiteralPath $written) $written
    $template = [IO.File]::ReadAllText($written)
    Check 'unit' 'template has defaults' (($template -match 'Hotkey=Ctrl\+Alt\+V') -and ($template -match 'MaxItems=300')) ''

    $lines = @('# hash comment', '; semi comment', '[section]', 'Hotkey=Ctrl+Shift+F9', 'Theme = light ', 'Quoted="a b"', 'Garbage', 'MaxItems=7')
    [IO.File]::WriteAllLines($cfg, $lines, $Utf8)
    $kv = Read-Ini
    Check 'unit' 'Read-Ini skips comments' (-not $kv.ContainsKey('# hash comment')) ''
    Check 'unit' 'Read-Ini trims value' ($kv['Theme'] -eq 'light') ('Theme=' + $kv['Theme'])
    Check 'unit' 'Read-Ini strips quotes' ($kv['Quoted'] -eq 'a b') ('Quoted=' + $kv['Quoted'])
    Check 'unit' 'Read-Ini skips malformed' (-not $kv.ContainsKey('Garbage')) ''
    Check 'unit' 'Read-Ini keeps number' ($kv['MaxItems'] -eq '7') ('MaxItems=' + $kv['MaxItems'])
    Check 'unit' 'Read-Ini reads hotkey' ($kv['Hotkey'] -eq 'Ctrl+Shift+F9') ('Hotkey=' + $kv['Hotkey'])

    # Apply-Config must pick up the paste timings and the fallback list
    [IO.File]::WriteAllLines($cfg, @('ModReleaseTimeout=1500', 'PasteSettle=250', 'HotkeyFallbacks=Alt+Q;Alt+W'), $Utf8)
    Apply-Config
    Check 'unit' 'Apply-Config ModReleaseTimeout' ($script:ModReleaseTimeout -eq 1500) ('value=' + $script:ModReleaseTimeout)
    Check 'unit' 'Apply-Config PasteSettle' ($script:PasteSettle -eq 250) ('value=' + $script:PasteSettle)
    Check 'unit' 'Apply-Config HotkeyFallbacks' ($script:HotkeyFallbacks -eq 'Alt+Q;Alt+W') ('value=' + $script:HotkeyFallbacks)

    # store
    Save-Items @()
    Check 'unit' 'store empty at start' (@(Get-Items).Count -eq 0) ''

    Add-Item 'one'; Add-Item 'two'; Add-Item 'three'
    $items = @(Get-Items)
    Check 'unit' 'store newest first' ($items.Count -eq 3 -and $items[0] -eq 'three') ($items -join '|')

    Add-Item 'one'
    $items = @(Get-Items)
    Check 'unit' 'store dedupe moves to top' ($items.Count -eq 3 -and $items[0] -eq 'one') ($items -join '|')

    Add-Item 'one'
    $items = @(Get-Items)
    Check 'unit' 'store dedupe keeps count' ($items.Count -eq 3) ($items -join '|')

    $savedMax = $MaxItems
    $MaxItems = 2
    Add-Item 'four'
    $items = @(Get-Items)
    Check 'unit' 'store trims to MaxItems' ($items.Count -eq 2) ($items -join '|')
    $MaxItems = $savedMax

    $savedBytes = $MaxBytes
    $MaxBytes = 3
    $before = @(Get-Items).Count
    Add-Item 'toolong'
    Check 'unit' 'store skips oversize entry' (@(Get-Items).Count -eq $before) ''
    $MaxBytes = $savedBytes

    $before = @(Get-Items).Count
    $script:ExcludePattern = '^SECRET'
    Add-Item 'SECRET token'
    Check 'unit' 'store honours exclude pattern' (@(Get-Items).Count -eq $before) ''
    $script:ExcludePattern = ''

    $before = @(Get-Items).Count
    Add-Item '   '
    Check 'unit' 'store ignores blank input' (@(Get-Items).Count -eq $before) ''

    $items = @('alpha', 'beta')
    Save-Items $items
    Check 'unit' 'Save-Items/Get-Items roundtrip' ((@(Get-Items) -join '|') -eq 'alpha|beta') (@(Get-Items) -join '|')

    Save-Items @()
  }

  # --------------------------------------------------------- integration tests
  if ($Integration) {
    $o = Clip $intDir @('help')
    Check 'int' 'help' ($o -match 'Usage: clipboard') ''

    $o = Clip $intDir @('config')
    Check 'int' 'config shows ini path' ($o -match 'clipboard\.ini') ''

    $o = Clip $intDir @('put', 'itest-alpha')
    Check 'int' 'put' ($o -match 'clipboard set') $o.Trim()

    $o = Clip $intDir @('get')
    Check 'int' 'get' ($o -match 'itest-alpha') $o.Trim()

    $o = Clip $intDir @('list', '-Count', '5')
    Check 'int' 'list' ($o -match 'itest-alpha') ''

    $o = Clip $intDir @('pick', '1')
    Check 'int' 'pick' ($o -match 'clipboard set') $o.Trim()
    $o = Clip $intDir @('get')
    Check 'int' 'pick sets clipboard' ($o -match 'itest-alpha') ''

    $o = Clip $intDir @('del', '1')
    Check 'int' 'del' ($o -match 'deleted') $o.Trim()

    $o = Clip $intDir @('clear')
    Check 'int' 'clear' ($o -match 'history cleared') ''
    $o = Clip $intDir @('list')
    Check 'int' 'list empty after clear' ($o -match 'history is empty') ''

    $o = Clip $intDir @('put', 'stdin-like-value')
    $o = Clip $intDir @('del', '9')
    Check 'int' 'del out of range' ($o -match 'index out of range') $o.Trim()

    $o = Clip $intDir @('pick', 'x')
    Check 'int' 'pick bad arg' ($o -match 'usage: clipboard pick') $o.Trim()

    $o = Clip $intDir @('nosuchcommand')
    Check 'int' 'unknown command' ($o -match 'unknown command') ''

    $o = Clip $intDir @('pause')
    $s = Clip $intDir @('status')
    Check 'int' 'pause' (($o -match 'paused') -and ($s -match 'capture     : paused')) ''
    $o = Clip $intDir @('resume')
    $s = Clip $intDir @('status')
    Check 'int' 'resume' ($s -match 'capture     : active') ''

    $o = Clip $intDir @('status')
    Check 'int' 'status fields' (($o -match 'autostart   :') -and ($o -match 'desktop     :') -and ($o -match 'store file')) ''

    $o = Clip $intDir @('diag')
    Check 'int' 'diag roundtrip' ($o -match 'Clipboard roundtrip') ''

    # config precedence: ini MaxItems=2, then the CLI switch must win
    $cfg2 = Join-Path $intDir 'clipboard.ini'
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=2'), $Utf8)
    [void](Clip $intDir @('clear'))
    1..3 | ForEach-Object { [void](Clip $intDir @('put', ('cfg-' + $_))) }
    $o = Clip $intDir @('list')
    Check 'int' 'ini MaxItems respected' (@($o -split "`n" | Where-Object { $_ -match 'cfg-' }).Count -eq 2) $o.Trim()

    [void](Clip $intDir @('clear'))
    1..3 | ForEach-Object { [void](Clip $intDir @('put', ('ovr-' + $_), '-MaxItems', '5')) }
    $o = Clip $intDir @('list')
    Check 'int' 'CLI -MaxItems overrides ini' (@($o -split "`n" | Where-Object { $_ -match 'ovr-' }).Count -eq 3) $o.Trim()

    # -DataDir must not leak into the repo
    Check 'int' 'data dir isolate' ((Test-Path -LiteralPath (Join-Path $intDir 'history.dat')) -and -not (Test-Path -LiteralPath (Join-Path $repoRoot 'data\integration'))) ''

    # DataDir= in clipboard.ini decides the write location
    $altDir = Join-Path $tmpRoot 'alt'
    $cfgRoot = Join-Path $tmpRoot 'cfgroot'
    foreach ($d in @($altDir, $cfgRoot)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item -LiteralPath $clipPs1 -Destination (Join-Path $cfgRoot 'clipboard.ps1')
    [IO.File]::WriteAllLines((Join-Path $cfgRoot 'clipboard.ini'), @('DataDir=' + $altDir), $Utf8)
    & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File (Join-Path $cfgRoot 'clipboard.ps1') put 'ini-datadir' 2>&1 | Out-Null
    Check 'int' 'DataDir from ini' (Test-Path -LiteralPath (Join-Path $altDir 'history.dat')) $altDir
  }

  # ------------------------------------------------------------------ e2e tests
  if ($E2E) {
    if (-not (Test-MutexFree 'Local\clipboard.daemon')) {
      Skip 'e2e' 'daemon lifecycle' 'a resident is already running - stop it first'
      Skip 'e2e' 'capture pipeline' 'a resident is already running - stop it first'
    }
    else {
      $child = $null
      try {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $clipPs1, 'serve', '-DataDir', $e2eDir)
        $child = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argList -PassThru

        $up = $false
        for ($i = 0; $i -lt 30 -and -not $up; $i++) {
          Start-Sleep -Milliseconds 500
          if ((Clip $e2eDir @('status')) -match 'resident    : running') { $up = $true }
        }
        Check 'e2e' 'daemon starts' $up ''

        $s = Clip $e2eDir @('status')
        Check 'e2e' 'hotkey registered' ($s -match 'active key  : Ctrl\+Alt\+V') (@($s -split "`n" | Where-Object { $_ -match 'active key' }) -join '')
        Check 'e2e' 'store lives in -DataDir' ($s -match [regex]::Escape($e2eDir)) ''

        $marker = 'e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        [void](Set-Clip $marker)
        Start-Sleep -Milliseconds 1600
        Check 'e2e' 'capture pipeline' ((Clip $e2eDir @('list', '-Count', '5')) -match [regex]::Escape($marker)) $marker

        [void](Clip $e2eDir @('pause'))
        $marker2 = 'e2e-paused-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        [void](Set-Clip $marker2)
        Start-Sleep -Milliseconds 1600
        Check 'e2e' 'pause stops capture' (-not ((Clip $e2eDir @('list', '-Count', '5')) -match [regex]::Escape($marker2))) $marker2
        [void](Clip $e2eDir @('resume'))

        [void](Clip $e2eDir @('stop'))
        $down = $false
        for ($i = 0; $i -lt 25 -and -not $down; $i++) {
          Start-Sleep -Milliseconds 400
          if ((Clip $e2eDir @('status')) -match 'resident    : not running') { $down = $true }
        }
        Check 'e2e' 'daemon stops' $down ''

        $log = Join-Path $e2eDir 'clipboard.log'
        $logText = if (Test-Path -LiteralPath $log) { [IO.File]::ReadAllText($log) } else { '' }
        Check 'e2e' 'clean shutdown logged' (($logText -match 'serve stop \(stop\)') -and ($logText -match 'supervisor exit')) ''
        Check 'e2e' 'no restart loop' (-not ($logText -match 'serve restart #')) ''
      }
      finally {
        if ($child -and -not $child.HasExited) { try { $child.Kill() } catch { } }
      }
    }
  }
}
finally {
  if ($clipBak) { [void](Set-Clip $clipBak) }
  try { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

$script:results | Format-Table -AutoSize -Wrap | Out-String -Width 160 | Write-Output

$pass = @($script:results | Where-Object { $_.Result -eq 'PASS' }).Count
$fail = @($script:results | Where-Object { $_.Result -eq 'FAIL' }).Count
$skipped = @($script:results | Where-Object { $_.Result -eq 'SKIP' }).Count
Write-Output ('TOTAL ' + $script:results.Count + '   PASS ' + $pass + '   FAIL ' + $fail + '   SKIP ' + $skipped)
if ($fail -gt 0) { exit 1 }
exit 0

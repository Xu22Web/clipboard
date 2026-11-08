#Requires -Version 5.1
<#
  tests\run.ps1 - run the self tests, several parts at a time.

  A part is one file that owns a group of checks and runs in its own process:

      tests\cli\*.ps1      the command line: history, transfer, settings, config, marks, pins
      tests\pkg\*.ps1      packaging
      tests\unit\*.ps1     in-process unit tests (optional extra parts)

  Plus the two halves that have to run in this repository's own process, in
  tests\unit\unit.ps1: the structure guards and the unit tests.

  Why a process per part: a CLI call costs about 3.4 s, almost all of it PowerShell startup
  and parsing eleven thousand lines of modules. Parts run side by side instead, and each one
  carries its own sandbox and its own clipboard (tests\lib\fake-clip.ps1), so they cannot see
  each other and the machine clipboard is left alone.

  Lanes: the unit tests and the end-to-end run both drive the real clipboard, so they queue
  behind each other; everything else runs beside them. The cli parts share nothing, so they
  are only limited by -Workers.

      cli test                        every part
      cli test -Unit                  one part, by name
      cli test -Part cli,history      several parts, by name
      cli test -Workers 6             more at a time (cli.ini [test] Workers is the default)
      cli test -Serial                one after another
#>
[CmdletBinding()]
param(
  [switch]$Unit,
  [switch]$Integration,
  [switch]$E2E,
  [string]$Source = '',
  # part names, comma separated (empty = every part of the selected groups)
  [string]$Part = '',
  [int]$Workers = 0,
  [switch]$Serial,
  # only the parts a change since HEAD can break (a development loop, not a gate)
  [switch]$Changed,
  # print every check instead of one line per part
  [switch]$Verbose_Log
)

$ErrorActionPreference = 'Stop'
$testsRoot = $PSCommandPath | Split-Path -Parent
$repoRoot = Split-Path -Parent $testsRoot

# cli.ini is read with the parser the tool itself uses
. (Join-Path $repoRoot 'src\utils\ini.ps1')
$cfg = @{}
$iniPath = Join-Path $repoRoot 'cli.ini'
if (Test-Path -LiteralPath $iniPath) {
  $cfg = (Read-IniDoc ([IO.File]::ReadAllLines($iniPath, [Text.Encoding]::UTF8))).Map
}

function Get-Cfg([string]$key, [string]$fallback) {
  if ($cfg.ContainsKey($key) -and [string]$cfg[$key]) { return [string]$cfg[$key] }
  return $fallback
}

function Split-List([string]$value) {
  return @($value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Which parts a change can break. A heuristic for the edit-run loop: anything that is not
# obviously local to one part falls back to the whole suite, and `cli build` stays the check
# that the package itself is still right.
$script:AllParts = @('unit', 'history', 'transfer', 'settings', 'config', 'marks', 'pins', 'serve')
function Get-ChangedParts([string[]]$Given) {
  $files = New-Object System.Collections.Generic.List[string]
  if ($Given) {
    foreach ($f in $Given) { $files.Add([string]$f) }
  } else {
    # git warns about line endings on stderr, and this script stops on errors: keep the warnings
    # from turning into a failed call that silently reports "nothing changed"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      foreach ($gitArgs in @(@('diff', '--name-only', 'HEAD'), @('ls-files', '--others', '--exclude-standard'))) {
        foreach ($line in @(& git -C $repoRoot --no-pager @gitArgs 2>$null)) {
          $text = ([string]$line).Trim()
          if ($text) { $files.Add($text) }
        }
      }
    } finally {
      $ErrorActionPreference = $prev
    }
  }
  $picked = New-Object System.Collections.Generic.List[string]
  foreach ($f in $files) {
    $p = $f -replace '/', '\'
    $names = @()
    if ($p -match '^tests\\cli\\(?<part>[A-Za-z0-9_-]+)\.ps1$') { $names = @($matches['part']) }
    elseif ($p -match '^tests\\pkg\\') { $names = @('build') }
    elseif ($p -match '^tests\\unit\\') { $names = @('unit') }
    elseif ($p -match '^tests\\e2e\\(?<part>[A-Za-z0-9_-]+)\.ps1$') { $names = @($matches['part']) }
    elseif ($p -match '^tests\\') { $names = $script:AllParts }
    elseif ($p -match '\.md$' -or $p -match '^docs\\' -or $p -match '^LICENSE$') { $names = @() }
    elseif ($p -match '^src\\lib\\panel\\' -or $p -match '^src\\lib\\serve\.ps1$' -or $p -match '^src\\lib\\proxy\.ps1$') { $names = @('unit', 'serve', 'proxy') }
    elseif ($p -match '^src\\lib\\plugin\\') { $names = @('unit', 'config', 'marks', 'pins') }
    elseif ($p -match '^src\\schema\\') { $names = @('unit', 'settings', 'config') }
    elseif ($p -match '^src\\') { $names = $script:AllParts }
    elseif ($p -match '^tools\\' -or $p -match '^(cli|package)\.ini$') { $names = @('build') }
    else { $names = $script:AllParts }
    foreach ($n in $names) { if (-not $picked.Contains($n)) { $picked.Add($n) } }
  }
  return , $picked
}

if (-not ($Unit -or $Integration -or $E2E)) {
  # no switch given: cli.ini decides which groups the plain run covers
  $groups = Split-List (Get-Cfg 'test.Groups' 'unit,integration,e2e')
  $Unit = ($groups -contains 'unit')
  $Integration = ($groups -contains 'integration')
  $E2E = ($groups -contains 'e2e')
}
if (-not $Integration) { $Unit = [bool]$Unit; $E2E = [bool]$E2E }
if ($Workers -le 0) { $Workers = [int](Get-Cfg 'test.Workers' '8') }
if ($Workers -lt 1) { $Workers = 1 }
$wanted = Split-List $Part
if ($Changed) {
  $picked = Get-ChangedParts
  if ($picked.Count -eq 0) {
    Write-Host 'nothing changed since HEAD: no part to run'
    exit 0
  }
  $wanted = $picked
  # a deleted part file still shows up in the diff: keep only the names that exist now
  $existing = @()
  foreach ($g in @('cli', 'pkg', 'unit', 'e2e')) {
    $d = Join-Path $testsRoot $g
    if (Test-Path -LiteralPath $d) { $existing += @(Get-ChildItem -LiteralPath $d -Filter '*.ps1' -File | ForEach-Object { $_.BaseName }) }
  }
  $wanted = @($picked | Where-Object { $existing -contains $_ })
  if ($wanted.Count -eq 0) {
    Write-Host 'no part left for the change: nothing to run'
    exit 0
  }
  Write-Host ('changed since HEAD: ' + ($wanted -join ', '))
}

# a packaged copy has rewritten names, so a sandbox cannot carry the fake clipboard and every
# cli part ends up on the machine clipboard: those have to wait for each other
$isPackaged = $false
if ($Source) { $isPackaged = ((Resolve-Path -LiteralPath $Source).Path -ne (Join-Path $repoRoot 'src')) }

$found = New-Object System.Collections.Generic.List[object]
# every part is a file under tests\<group>\; the group decides which lane it runs in, and a
# lane is a set of parts that may share the machine at the same time
$groups = @('unit', 'cli', 'pkg', 'e2e')
foreach ($group in $groups) {
  if ($group -eq 'unit' -and -not $Unit) { continue }
  if ($group -eq 'e2e' -and -not $E2E) { continue }
  if (($group -eq 'cli' -or $group -eq 'pkg') -and -not $Integration) { continue }
  $dir = Join-Path $testsRoot $group
  if (-not (Test-Path -LiteralPath $dir)) { continue }
  # the unit tests and the end-to-end run both drive the real clipboard, so they queue behind
  # each other; the cli parts use their own clipboard and run beside everything else
  $lane = if ($group -eq 'cli') { 'cli' } elseif ($group -eq 'pkg') { 'pkg' } else { 'clip' }
  foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File | Sort-Object Name)) {
    $name = $file.BaseName
    if ($wanted.Count -gt 0 -and $wanted -notcontains $name) { continue }
    $found.Add(@{ Name = $name; File = $file.FullName; Group = $group; Lane = $lane; Size = $file.Length })
  }
}

# longest part first: a part spends its time on the command lines it runs, so starting the big
# ones early keeps the last wave short instead of ending on a single long part
$rank = @{ unit = 0; cli = 1; pkg = 2; e2e = 3 }
$jobs = New-Object System.Collections.Generic.List[object]
foreach ($job in @($found | Sort-Object @{ Expression = { $rank[$_.Group] } }, @{ Expression = { $_.Size }; Descending = $true })) {
  $jobs.Add($job)
}

# how many parts of a lane may run at once
$laneLimit = @{ clip = 1; pkg = $Workers; cli = $(if ($isPackaged) { 1 } else { $Workers }) }
# the clip lane drives the real clipboard; the cli parts need to know that before they claim
# anything about the machine clipboard
$clipShared = (@($jobs | Where-Object { $_.Lane -eq 'clip' }).Count -gt 0)
if ($Serial) {
  $laneLimit['clip'] = 1
  $laneLimit['pkg'] = 1
  $laneLimit['cli'] = 1
}

$tmpRoot = Join-Path $env:TEMP ('clipboard-run-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$results = New-Object System.Collections.Generic.List[object]
$started = Get-Date
$utf8 = New-Object System.Text.UTF8Encoding $false

function Start-Part($job) {
  $out = Join-Path $tmpRoot ($job.Name + '.json')
  $cliArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $job.File)
  if ($job.Args) { $cliArgs += $job.Args }
  if ($Source) { $cliArgs += @('-Source', $Source) }
  # a cli part runs beside the end-to-end part, which writes the real clipboard: a check that
  # claims "the machine clipboard was never touched" cannot hold there, so the part is told
  if ($job.Lane -eq 'cli' -and $clipShared) { $cliArgs += '-ClipShared' }
  $cliArgs += @('-ResultFile', $out, '-Quiet')
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $joined = ''
  foreach ($a in $cliArgs) { $joined = $joined + ' "' + [string]$a + '"' }
  $psi.Arguments = $joined
  # no redirection: a pipe nobody reads deadlocks a child that prints a lot, and -Quiet keeps
  # the child's own table out of the console anyway
  $p = [System.Diagnostics.Process]::Start($psi)
  return @{ Job = $job; Process = $p; Out = $out; Started = Get-Date }
}

function Complete-Part($run) {
  $seconds = [int]((Get-Date) - $run.Started).TotalSeconds
  $rows = @()
  if (Test-Path -LiteralPath $run.Out) {
    try {
      $doc = [IO.File]::ReadAllText($run.Out, [Text.Encoding]::UTF8) | ConvertFrom-Json
      $rows = @($doc.Results)
    } catch { $rows = @() }
  }
  if ($rows.Count -eq 0) {
    $rows = @([pscustomobject]@{
        Group  = $run.Job.Name
        Test   = '(no result file)'
        Result = 'FAIL'
        Detail = 'the part wrote no result file, so it threw before the end'
      })
  }
  $fails = @($rows | Where-Object { $_.Result -eq 'FAIL' }).Count
  $results.Add(@{ Name = $run.Job.Name; Seconds = $seconds; Rows = $rows })
  $label = '  ' + $run.Job.Name.PadRight(9) + ([string]$rows.Count).PadLeft(5) + ' checks' + ([string]$seconds).PadLeft(6) + ' s'
  if ($fails -eq 0) {
    Write-Host ('[ok] ' + $label)
  } else {
    Write-Host ('[!!] ' + $label + '   ' + $fails + ' failed')
    foreach ($r in @($rows | Where-Object { $_.Result -eq 'FAIL' })) {
      Write-Host ('       ' + $r.Test + '   ' + ([string]$r.Detail).Trim())
    }
  }
}

# one scheduler for every lane: start what fits, collect what finished. The unit tests come
# first in the list, so a broken function fails the run in its first seconds while the slower
# command line parts are still starting.
$pending = New-Object System.Collections.Generic.List[object]
foreach ($job in $jobs) { $pending.Add($job) }
$active = New-Object System.Collections.Generic.List[object]

Write-Host ('clipboard tests   ' + $jobs.Count + ' part(s), up to ' + $Workers + ' at a time')

while ($pending.Count -gt 0 -or $active.Count -gt 0) {
  $launched = $false
  foreach ($job in $pending.ToArray()) {
    $busy = @($active | Where-Object { $_.Job.Lane -eq $job.Lane }).Count
    if ($busy -ge $laneLimit[$job.Lane]) { continue }
    [void]$pending.Remove($job)
    $active.Add((Start-Part $job))
    $launched = $true
  }
  $done = $null
  foreach ($a in $active) { if ($a.Process.HasExited) { $done = $a; break } }
  if ($null -ne $done) {
    [void]$active.Remove($done)
    Complete-Part $done
  } elseif (-not $launched) {
    Start-Sleep -Milliseconds 120
  }
}

$all = New-Object System.Collections.Generic.List[object]
foreach ($r in $results) {
  foreach ($row in $r.Rows) {
    $all.Add([pscustomobject]@{ Group = [string]$row.Group; Test = [string]$row.Test; Result = [string]$row.Result; Detail = [string]$row.Detail })
  }
}
if ($Verbose_Log) { $all | Format-Table -AutoSize -Wrap | Out-String -Width 160 | Write-Output }

$pass = @($all | Where-Object { $_.Result -eq 'PASS' }).Count
$fail = @($all | Where-Object { $_.Result -eq 'FAIL' }).Count
$skipped = @($all | Where-Object { $_.Result -eq 'SKIP' }).Count
$totalSecs = [int]((Get-Date) - $started).TotalSeconds
Write-Host ''
foreach ($r in $results) {
  Write-Host ('  ' + $r.Name.PadRight(9) + ([string]$r.Rows.Count).PadLeft(5) + ' checks' + ([string]$r.Seconds).PadLeft(6) + ' s')
}
Write-Host ('TOTAL ' + $all.Count + '   PASS ' + $pass + '   FAIL ' + $fail + '   SKIP ' + $skipped + '   in ' + $totalSecs + ' s')
try { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
if ($fail -gt 0) { exit 1 }
exit 0

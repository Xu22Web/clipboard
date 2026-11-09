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

      cli test                        every part, one per logical processor
      cli test -Unit                  one part, by name
      cli test -Part cli,history      several parts, by name
      cli test -Workers 6             fewer at a time (cli.ini [test] Workers is the default,
                                      0 = one per logical processor)
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
  # default = vitest's default reporter, verbose = one row per check. Anything else is a typo,
  # not a mode nobody wrote yet.
  [string]$Reporter = '',
  # every check, the same as -Reporter verbose (kept for the runs that always passed it)
  [switch]$Verbose_Log,
  # stop starting parts after the first one with a failure
  [switch]$Bail,
  # print where the time went: the slowest command line calls and the total per part
  [switch]$Profile,
  # repaint the block of running parts while the run goes; off when nobody is watching
  [switch]$NoProgress,
  [switch]$NoColor
)

$ErrorActionPreference = 'Stop'
$testsRoot = $PSCommandPath | Split-Path -Parent
$repoRoot = Split-Path -Parent $testsRoot

# one reporter for the rows this driver prints; the parts print their own through the same
# file, so a line reads the same whichever process wrote it
. (Join-Path $testsRoot 'lib\reporter.ps1')
if (-not $Reporter) {
  if ($Verbose_Log) { $Reporter = 'verbose' } else { $Reporter = 'default' }
}
if (@('default', 'verbose') -notcontains $Reporter) {
  Write-Host ('[x] unknown reporter: ' + $Reporter + '   (default | verbose)')
  exit 2
}
Initialize-TestReporter -Mode $Reporter -NoColor:$NoColor -NoProgress:$NoProgress

# the header row names the build under test; a package carries the same number as a constant
$programVersion = ''
$versionFile = Join-Path $repoRoot 'package.ini'
if (Test-Path -LiteralPath $versionFile) {
  $vm = [regex]::Match([IO.File]::ReadAllText($versionFile), '(?mi)^\s*version\s*=\s*(\S+)\s*$')
  if ($vm.Success) { $programVersion = $vm.Groups[1].Value }
}

# cli.ini is read and checked with the tooling's own parser and schema: the driver needs
# [test] (Groups, Workers), and a file that does not match tools\schema\cli.ps1 is a broken
# file rather than something to guess a default for.
. (Join-Path $repoRoot 'tools\utils\ini.ps1')
. (Join-Path $repoRoot 'tools\utils\schema.ps1')
$iniPath = Join-Path $repoRoot 'cli.ini'
$cfg = @{}
if (Test-Path -LiteralPath $iniPath) { $cfg = Import-IniMap $iniPath }
$cfgProblems = @(Test-ToolConfigMap (Import-ToolSchema (Join-Path $repoRoot 'tools\schema\cli.ps1')) $cfg 'cli.ini' 'test')
if ($cfgProblems.Count -gt 0) {
  foreach ($p in $cfgProblems) { Write-Host ('[x] ' + $p) }
  exit 1
}

function Get-Cfg([string]$key) {
  if ($cfg.ContainsKey($key)) { return [string]$cfg[$key] }
  return ''
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
if ($Workers -le 0) { $Workers = [int](Get-Cfg 'test.Workers' '0') }
# a missing key or 0 means one worker per logical processor; the part count is the ceiling
if ($Workers -le 0) { $Workers = [Environment]::ProcessorCount }
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

# The C# types are compiled once in every process that loads the tool, and the command line
# parts start about a hundred of those. A built clipboard.dll is what keeps that compile out
# of every call; a .cs newer than the dll still falls back to the run-time compile, so a stale
# file can never win.
function Update-TestAssembly {
  if ($isPackaged) { return }
  $asmDir = Join-Path $repoRoot 'src\lib\assembly'
  if (-not (Test-Path -LiteralPath $asmDir)) { return }
  $cs = @(Get-ChildItem -LiteralPath $asmDir -Filter '*.cs' -File)
  if ($cs.Count -eq 0) { return }
  $dll = Join-Path $asmDir 'clipboard.dll'
  $stale = -not (Test-Path -LiteralPath $dll)
  if (-not $stale) {
    $dllAt = (Get-Item -LiteralPath $dll).LastWriteTimeUtc
    foreach ($f in $cs) { if ($f.LastWriteTimeUtc -gt $dllAt) { $stale = $true } }
  }
  if (-not $stale) { return }
  $builder = Join-Path $repoRoot 'tools\build-assembly.ps1'
  if (-not (Test-Path -LiteralPath $builder)) { return }
  $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder 2>&1
  if (-not (Test-Path -LiteralPath $dll)) { Write-Host '[..] no C# compiler here: the parts compile the sources at run time' }
}
Update-TestAssembly

$results = New-Object System.Collections.Generic.List[object]
$allTimings = New-Object System.Collections.Generic.List[object]
$allFails = New-Object System.Collections.Generic.List[object]
$script:Bailed = $false
$script:ProgressAt = [DateTime]::MinValue
$started = Get-Date
$utf8 = New-Object System.Text.UTF8Encoding $false

function Start-Part($job) {
  $out = Join-Path $tmpRoot ($job.Name + '.json')
  $progress = Join-Path $tmpRoot ($job.Name + '.progress')
  $cliArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $job.File)
  if ($job.Args) { $cliArgs += $job.Args }
  if ($Source) { $cliArgs += @('-Source', $Source) }
  # a cli part runs beside the end-to-end part, which writes the real clipboard: a check that
  # claims "the machine clipboard was never touched" cannot hold there, so the part is told
  if ($job.Lane -eq 'cli' -and $clipShared) { $cliArgs += '-ClipShared' }
  $cliArgs += @('-ResultFile', $out, '-ProgressFile', $progress, '-Quiet')
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $joined = ''
  foreach ($a in $cliArgs) { $joined = $joined + ' "' + [string]$a + '"' }
  $psi.Arguments = $joined
  # no redirection: a pipe nobody reads deadlocks a child that prints a lot, and -Quiet keeps
  # the child's own table out of the console anyway. ProcessStartInfo.EnvironmentVariables is
  # avoided on purpose: touching it here threw and left the child without a PATH.
  $p = [System.Diagnostics.Process]::Start($psi)
  return @{ Job = $job; Process = $p; Out = $out; Progress = $progress; Started = Get-Date }
}

function Complete-Part($run) {
  $seconds = ((Get-Date) - $run.Started).TotalSeconds
  $rows = @()
  $timings = @()
  if (Test-Path -LiteralPath $run.Out) {
    try {
      $doc = [IO.File]::ReadAllText($run.Out, [Text.Encoding]::UTF8) | ConvertFrom-Json
      $rows = @($doc.Results)
      if ($null -ne $doc.Timings) { $timings = @($doc.Timings) }
    } catch { $rows = @() }
  }
  if ($rows.Count -eq 0) {
    $code = 'unknown'
    try { if ($run.Process.HasExited) { $code = [string]$run.Process.ExitCode } } catch { }
    $rows = @([pscustomobject]@{
        Group  = $run.Job.Name
        Test   = '(no result file)'
        Result = 'FAIL'
        Detail = 'the part wrote no result file, so it threw before the end (exit code ' + $code + ')'
      })
  }
  $fails = @($rows | Where-Object { $_.Result -eq 'FAIL' })
  $skips = @($rows | Where-Object { $_.Result -eq 'SKIP' }).Count
  $results.Add(@{ Name = $run.Job.Name; Label = ($run.Job.Group + '\' + $run.Job.Name + '.ps1'); Seconds = $seconds; Rows = $rows })
  foreach ($t in $timings) {
    if ($null -eq $t) { continue }
    $allTimings.Add([pscustomobject]@{ Part = $run.Job.Name; What = [string]$t.What; Ms = [long]$t.Ms })
  }
  $label = $run.Job.Group + '\' + $run.Job.Name + '.ps1'
  # vitest prints what is inside a file only when it is the single file of a run, or when the
  # file has a failure; every other row stays one line. -Reporter verbose is the mode that lists
  # every check instead. The rows are captured first and handed to the window in one frame, so
  # the window is not repainted once per row.
  Start-TestCapture
  if ($Reporter -eq 'verbose') {
    foreach ($r in $rows) { Write-TestCheck $label ([string]$r.Group + ' > ' + [string]$r.Test) ([string]$r.Result) ([string]$r.Detail) ([int]$r.Ms) }
  } else {
    Write-TestModuleRow $label $rows.Count $fails.Count $skips $seconds
    if (($jobs.Count -le 1) -or ($fails.Count -gt 0)) { Write-TestPartTree $rows }
  }
  $message = Get-TestCaptured
  Set-TestWindow (Get-TestWindowLines)
  Write-TestWindow $message
  foreach ($r in $fails) {
    $allFails.Add(@{
      Name = ($label + ' > ' + [string]$r.Group + ' > ' + [string]$r.Test)
      Detail = ([string]$r.Detail).Trim()
    })
  }
  if ($Bail -and $fails.Count -gt 0) { $script:Bailed = $true }
}

# the lines the window shows: the parts still going, then the four rows the run ends with
function Get-TestWindowLines {
  $frame = New-Object System.Collections.Generic.List[string]
  foreach ($a in $active) {
    $label = $a.Job.Group + '\' + $a.Job.Name + '.ps1'
    $done = 0
    if (Test-Path -LiteralPath $a.Progress) {
      $bits = @()
      try { $bits = @(([IO.File]::ReadAllText($a.Progress)).Trim() -split '\s+') } catch { $bits = @() }
      if ($bits.Count -ge 3 -and $bits[0] -match '^[0-9]+$') { $done = [int]$bits[0] + [int]$bits[1] + [int]$bits[2] }
    }
    $line = ' > ' + $label
    if ($done -gt 0) { $line = $line + ' ' + [string]$done }
    $frame.Add($line)
  }
  if ($frame.Count -gt 0) { $frame.Add('') }
  $ok = 0
  $bad = 0
  $skip = 0
  foreach ($r in $results) {
    foreach ($row in $r.Rows) {
      if ($row.Result -eq 'FAIL') { $bad++ } elseif ($row.Result -eq 'SKIP') { $skip++ } else { $ok++ }
    }
  }
  $elapsed = (Get-Date) - $started
  $frame.Add((Get-TestSummaryLine 'Test Files' ([string]$results.Count + ' passed (' + [string]$jobs.Count + ')')))
  $testsText = [string]$ok + ' passed'
  if ($bad -gt 0) { $testsText = $testsText + ' | ' + [string]$bad + ' failed' }
  if ($skip -gt 0) { $testsText = $testsText + ' | ' + [string]$skip + ' skipped' }
  $frame.Add((Get-TestSummaryLine 'Tests' $testsText))
  $frame.Add((Get-TestSummaryLine 'Start at' $started.ToString('HH:mm:ss')))
  $frame.Add((Get-TestSummaryLine 'Duration' (Format-TestDuration $elapsed.TotalSeconds)))
  # the renderer clears from the cursor, so the window has to end on an empty line: the cursor
  # then sits at the start of a row and ESC[K / ESC[1A ESC[K erase whole rows
  $frame.Add('')
  return $frame
}

# The window vitest keeps on screen while tests run, repainted in place by the renderer in
# tests\lib\reporter.ps1. A finished part asks for a frame right away; otherwise four frames a
# second cover the seconds the window shows.
function Write-TestRunProgress {
  if ($NoProgress) { return }
  $now = Get-Date
  if (($now - $script:ProgressAt).TotalMilliseconds -lt 400) { return }
  $script:ProgressAt = $now
  Set-TestWindow (Get-TestWindowLines)
  Write-TestWindow ''
}

# Where the time went. The command line parts record every child process they start, so this
# answers "which call is slow", not just "which part is slow".
function Write-TestProfile {
  if ($allTimings.Count -eq 0) { Write-Host 'no command line calls recorded'; return }
  $sum = ($allTimings | Measure-Object -Property Ms -Sum).Sum
  if ($null -eq $sum) { $sum = 0 }
  Write-Host ''
  Write-Host (' slowest command line calls   ' + [string]$allTimings.Count + ' calls, ' + [string]$sum + ' ms in total')
  foreach ($t in @($allTimings | Sort-Object -Property Ms -Descending | Select-Object -First 15)) {
    Write-Host ('   ' + ([string]$t.Ms).PadLeft(7) + ' ms  ' + $t.Part.PadRight(10) + ' ' + $t.What)
  }
  Write-Host ''
  Write-Host ' command line time per part'
  foreach ($g in @($allTimings | Group-Object -Property Part | Sort-Object -Property { ($_.Group | Measure-Object -Property Ms -Sum).Sum } -Descending)) {
    $partSum = ($g.Group | Measure-Object -Property Ms -Sum).Sum
    if ($null -eq $partSum) { $partSum = 0 }
    Write-Host ('   ' + $g.Name.PadRight(10) + ([string]$g.Count).PadLeft(4) + ' calls' + ([string]$partSum).PadLeft(9) + ' ms')
  }
}

# one scheduler for every lane: start what fits, collect what finished. The unit tests come
# first in the list, so a broken function fails the run in its first seconds while the slower
# command line parts are still starting.
$pending = New-Object System.Collections.Generic.List[object]
foreach ($job in $jobs) { $pending.Add($job) }
$active = New-Object System.Collections.Generic.List[object]

Write-TestBanner $programVersion $(if ($Source) { ([string](Resolve-Path -LiteralPath $Source).Path) } else { $repoRoot })

while ($pending.Count -gt 0 -or $active.Count -gt 0) {
  $launched = $false
  if (-not $script:Bailed) {
    foreach ($job in $pending.ToArray()) {
      $busy = @($active | Where-Object { $_.Job.Lane -eq $job.Lane }).Count
      if ($busy -ge $laneLimit[$job.Lane]) { continue }
      [void]$pending.Remove($job)
      $active.Add((Start-Part $job))
      $launched = $true
    }
  }
  $done = $null
  foreach ($a in $active) { if ($a.Process.HasExited) { $done = $a; break } }
  if ($null -ne $done) {
    [void]$active.Remove($done)
    Complete-Part $done
    # -Bail: what is still queued never starts, but a part already running is left to finish
    if ($script:Bailed -and $pending.Count -gt 0) {
      Write-Host ('  -bail: ' + [string]$pending.Count + ' part(s) not started')
      $pending.Clear()
    }
  } else {
    Write-TestRunProgress
    if (-not $launched) { Start-Sleep -Milliseconds 120 }
  }
}

$all = New-Object System.Collections.Generic.List[object]
foreach ($r in $results) {
  foreach ($row in $r.Rows) {
    $all.Add([pscustomobject]@{ Group = [string]$row.Group; Test = [string]$row.Test; Result = [string]$row.Result; Detail = [string]$row.Detail })
  }
}
$pass = @($all | Where-Object { $_.Result -eq 'PASS' }).Count
$fail = @($all | Where-Object { $_.Result -eq 'FAIL' }).Count
$skipped = @($all | Where-Object { $_.Result -eq 'SKIP' }).Count
$totalSecs = (Get-Date) - $started
if ($Profile) { Write-TestProfile }

$partsFail = 0
$partsSkip = 0
$slowest = ''
$slowestSecs = 0
foreach ($r in $results) {
  $rowsFail = @($r.Rows | Where-Object { $_.Result -eq 'FAIL' }).Count
  $rowsSkip = @($r.Rows | Where-Object { $_.Result -eq 'SKIP' }).Count
  if ($rowsFail -gt 0) { $partsFail++ }
  elseif ($rowsSkip -gt 0 -and $rowsSkip -eq @($r.Rows).Count) { $partsSkip++ }
  if ($r.Seconds -gt $slowestSecs) { $slowestSecs = $r.Seconds; $slowest = $r.Label }
}
$summary = @{
  Parts = $results.Count; PartsPass = ($results.Count - $partsFail - $partsSkip); PartsFail = $partsFail; PartsSkip = $partsSkip
  Pass = $pass; Fail = $fail; Skip = $skipped; Total = $all.Count
  Seconds = $totalSecs.TotalSeconds
  StartAt = $started.ToString('HH:mm:ss')
  Slowest = $(if ($slowest) { $slowest + ' ' + (Format-TestDuration $slowestSecs) } else { '' })
}
Clear-TestWindow
Write-TestFailures $allFails
Write-TestSummary $summary
try { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
if ($fail -gt 0) { exit 1 }
exit 0

#Requires -Version 5.1
<#
  tests\run.ps1 - run the self tests, several parts at a time.

  A part is one file that owns a group of checks and runs in its own process:

      tests\cli\*.ps1      the command line: transfer, capture, config, marks
      tests\pkg\*.ps1      packaging
      tests\unit\*.ps1     in-process unit tests (optional extra parts)

  Plus the two halves that have to run in this repository's own process, in
  tests\unit\unit.ps1: the structure guards and the unit tests.

  Why a process per part: a CLI call costs about 3.4 s, almost all of it PowerShell startup
  and parsing eleven thousand lines of modules. Parts run side by side instead, and each one
  carries its own sandbox and its own clipboard (tests\lib\fake-clip.ps1), so they cannot see
  each other and the machine clipboard is left alone.

  The two parts that need the real clipboard - the unit tests (two round trips) and the
  end-to-end run (a resident, the hotkey, a real capture) - run alone at the end.

      cli test                        every part
      cli test -Unit                  one part, by name
      cli test -Part cli,transfer     several parts, by name
      cli test -Workers 6             more at a time (test.ini [run] Workers is the default)
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
  # print every check instead of one line per part
  [switch]$Verbose_Log
)

$ErrorActionPreference = 'Stop'
$testsRoot = $PSCommandPath | Split-Path -Parent
$repoRoot = Split-Path -Parent $testsRoot

# test.ini is read with the parser the tool itself uses
. (Join-Path $repoRoot 'src\utils\ini.ps1')
$cfg = @{}
$iniPath = Join-Path $repoRoot 'test.ini'
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

if (-not ($Unit -or $Integration -or $E2E)) {
  # no switch given: test.ini decides which groups the plain run covers
  $groups = Split-List (Get-Cfg 'run.Groups' 'unit,integration,e2e')
  $Unit = ($groups -contains 'unit')
  $Integration = ($groups -contains 'integration')
  $E2E = ($groups -contains 'e2e')
}
if (-not $Integration) { $Unit = [bool]$Unit; $E2E = [bool]$E2E }
if ($Workers -le 0) { $Workers = [int](Get-Cfg 'run.Workers' '4') }
if ($Workers -lt 1) { $Workers = 1 }
if ($Serial) { $Workers = 1 }
$wanted = Split-List $Part

$jobs = New-Object System.Collections.Generic.List[object]
# every part is a file under tests\<group>\; the group decides whether it can run beside others
$parallelGroups = @('cli', 'pkg')
$aloneGroups = @('unit', 'e2e')
foreach ($group in ($parallelGroups + $aloneGroups)) {
  if ($parallelGroups -contains $group -and -not $Integration) { continue }
  if ($group -eq 'unit' -and -not $Unit) { continue }
  if ($group -eq 'e2e' -and -not $E2E) { continue }
  $dir = Join-Path $testsRoot $group
  if (-not (Test-Path -LiteralPath $dir)) { continue }
  foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File | Sort-Object Name)) {
    $name = $file.BaseName
    if ($wanted.Count -gt 0 -and $wanted -notcontains $name) { continue }
    $jobs.Add(@{ Name = $name; File = $file.FullName; Alone = ($aloneGroups -contains $group) })
  }
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

# the parts that need the machine clipboard run one at a time, at the end
$parallel = @($jobs | Where-Object { -not $_.Alone })
$alone = @($jobs | Where-Object { $_.Alone })

Write-Host ('clipboard tests   ' + $jobs.Count + ' part(s), up to ' + $Workers + ' at a time')

$active = New-Object System.Collections.Generic.List[object]
foreach ($job in $parallel) {
  while ($active.Count -ge $Workers) {
    $done = $null
    foreach ($a in $active) { if ($a.Process.HasExited) { $done = $a; break } }
    if ($null -eq $done) { Start-Sleep -Milliseconds 120; continue }
    [void]$active.Remove($done)
    Complete-Part $done
  }
  $active.Add((Start-Part $job))
}
foreach ($a in $active) { $a.Process.WaitForExit(); Complete-Part $a }

foreach ($job in $alone) {
  $one = Start-Part $job
  $one.Process.WaitForExit()
  Complete-Part $one
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

#Requires -Version 5.1
<#
  tests\lib\reporter.ps1 - the one place that prints what the tests did.

  Two processes print: a part that runs checks (tests\unit\*.ps1, tests\cli\*.ps1, ...) and
  tests\run.ps1, which starts the parts. Both load this file, so a line looks the same
  wherever it comes from.

  The shapes follow the runner most people read these days - one row per part, a failure that
  shows where it happened, and one block at the end:

      ok    unit          579 tests    77.3s
      FAIL  history        22 tests    35.2s   1 failed
        FAIL  history > del 9 reports the range
              index out of range (del 9)

      Test Parts  8 passed | 1 failed | 1 skipped (10)
           Tests  733 passed | 1 failed | 1 skipped (735)
        Duration  199.5s   slowest build 181.2s

  Colour is ANSI and only when the handle is a console that takes it: a redirected run, a host
  without virtual terminal support, and NO_COLOR all get the same rows without escapes.
#>

$script:TestReport = @{
  Mode     = 'default'          # default | verbose
  Quiet    = $false
  Color    = $false
  Width    = 100
  LastMark = $null
  # ascii on purpose: the tool and its tests stay readable on a console without the glyphs,
  # and a redirected log keeps the same words
  Marks    = @{ pass = 'ok'; fail = 'FAIL'; skip = 'skip'; info = '..' }
  Ansi     = @{ pass = ''; fail = ''; skip = ''; dim = ''; reset = '' }
}

function Get-TestConsoleWidth {
  $w = 100
  try { if (-not [Console]::IsOutputRedirected) { $w = [int][Console]::WindowWidth } } catch { $w = 100 }
  if ($w -lt 40) { $w = 40 }
  return $w
}

# Windows 10 consoles only interpret the escape sequences once the mode says so, and Windows
# PowerShell 5.1 has no $PSStyle to do it: ask kernel32. Any failure is "no colour", never an
# error - the rows are readable without it.
function Test-VirtualTerminal {
  try { if ([Console]::IsOutputRedirected) { return $false } } catch { return $false }
  if ($env:NO_COLOR) { return $false }
  try {
    if ($null -ne $Host.UI.PSObject.Properties['SupportsVirtualTerminal']) {
      if ($Host.UI.SupportsVirtualTerminal) { return $true }
    }
  } catch { }
  try {
    if (-not ('CbTest.Vt' -as [type])) {
      Add-Type -Namespace CbTest -Name Vt -ErrorAction Stop -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr h, uint mode);
'@
    }
    $handle = [CbTest.Vt]::GetStdHandle(-11)
    $mode = [uint32]0
    if (-not [CbTest.Vt]::GetConsoleMode($handle, [ref]$mode)) { return $false }
    if (($mode -band 0x0004) -eq 0) { return [bool][CbTest.Vt]::SetConsoleMode($handle, ($mode -bor 0x0004)) }
    return $true
  } catch { return $false }
}

# A part starts this for itself; tests\run.ps1 starts one for the rows it prints.
function Initialize-TestReporter([string]$Mode = 'default', [switch]$Quiet, [switch]$NoColor) {
  $script:TestReport.Mode = $Mode
  $script:TestReport.Quiet = [bool]$Quiet
  $script:TestReport.Width = Get-TestConsoleWidth
  # the quiet path prints nothing, so it must not pay for the console probe (a csc run)
  $script:TestReport.Color = (-not [bool]$Quiet) -and (-not [bool]$NoColor) -and (Test-VirtualTerminal)
  if ($script:TestReport.Color) {
    $esc = [string][char]27
    $script:TestReport.Ansi = @{
      pass = $esc + '[32m'; fail = $esc + '[31m'; skip = $esc + '[33m'; dim = $esc + '[2m'; reset = $esc + '[0m'
    }
  }
  $script:TestReport.LastMark = Get-Date
}

# 0.42s / 77.3s / 1m 12s - invariant, because a comma decimal separator would read as a list
function Format-TestDuration([double]$Seconds) {
  $inv = [Globalization.CultureInfo]::InvariantCulture
  if ($Seconds -lt 10) { return [string]::Format($inv, '{0:0.00}s', $Seconds) }
  if ($Seconds -lt 60) { return [string]::Format($inv, '{0:0.0}s', $Seconds) }
  $m = [int][Math]::Floor($Seconds / 60)
  $s = [int][Math]::Round($Seconds - ($m * 60))
  return ([string]$m + 'm ' + $s.ToString('00') + 's')
}

function Get-TestMark([string]$Kind) {
  $word = [string]$script:TestReport.Marks[$Kind]
  if (-not $word) { $word = [string]$Kind }
  if (-not $script:TestReport.Color) { return $word }
  return ($script:TestReport.Ansi[$Kind] + $word + $script:TestReport.Ansi.reset)
}

# long assertion details are one sentence each; wrap them under the row instead of letting the
# console fold them wherever it likes
function Write-TestWrapped([string]$Text, [int]$Indent) {
  $pad = ' ' * $Indent
  $room = [Math]::Max(20, $script:TestReport.Width - $Indent)
  foreach ($line in @(([string]$Text) -split "`r?`n")) {
    $rest = $line
    while ($rest.Length -gt $room) {
      $cut = $rest.LastIndexOf(' ', [Math]::Min($room, $rest.Length - 1))
      if ($cut -lt $room / 2) { $cut = $room }
      Write-Host ($pad + $rest.Substring(0, $cut).TrimEnd())
      $rest = $rest.Substring($cut).TrimStart()
    }
    if ($rest.Length -gt 0) { Write-Host ($pad + $rest) }
  }
}

# one check, while the part runs (verbose, or a part run by hand)
function Write-TestCheck([string]$Group, [string]$Name, [string]$Result, [string]$Detail, [int]$Ms) {
  if ($script:TestReport.Quiet) { return }
  if ($script:TestReport.Mode -ne 'verbose' -and $Result -ne 'FAIL') { return }
  $line = (Get-TestMark $Result) + '  ' + $Group + ' > ' + $Name
  if ($Result -eq 'SKIP') { $line = $line + '   ' + $Detail }
  elseif ($Ms -gt 0) { $line = $line + '   ' + (Format-TestDuration ($Ms / 1000.0)) }
  Write-Host $line
  if ($Result -eq 'FAIL' -and $Detail) { Write-TestWrapped $Detail 6 }
}

# one part, once it is done (tests\run.ps1)
function Write-TestPartRow([string]$Part, [int]$Checks, [double]$Seconds, [int]$Failed, [int]$Skipped) {
  $kind = 'pass'
  if ($Failed -gt 0) { $kind = 'fail' } elseif ($Skipped -gt 0 -and $Checks -eq $Skipped) { $kind = 'skip' }
  $note = ''
  if ($Failed -gt 0) { $note = [string]$Failed + ' failed' }
  elseif ($Skipped -gt 0) { $note = [string]$Skipped + ' skipped' }
  $row = (Get-TestMark $kind) + '  ' + $Part.PadRight(12) + ([string]$Checks).PadLeft(4) + ' tests' + (Format-TestDuration $Seconds).PadLeft(9)
  if ($note) { $row = $row + '   ' + $note }
  Write-Host $row.TrimEnd()
}

function Write-TestFailureBlock([string]$Part, [string]$Group, [string]$Name, [string]$Detail) {
  Write-Host ('  ' + (Get-TestMark 'fail') + '  ' + $Part + ' > ' + $Group + ' > ' + $Name)
  if ($Detail) { Write-TestWrapped $Detail 8 }
}

function Write-TestRunHeader([string]$Version, [string]$PowerShell, [string]$Platform, [int]$Parts, [int]$Workers) {
  Write-Host (' clipboard ' + $Version + ' - ' + $PowerShell + ' - ' + $Platform + ' - ' + [string]$Parts + ' part(s), up to ' + [string]$Workers + ' at a time')
  Write-Host ''
}

# a single line that is overwritten while parts run; only when the output is a console
function Write-TestProgress([string]$Text) {
  if ($script:TestReport.Quiet) { return }
  if (-not [Console]::IsOutputRedirected) {
    $room = [Math]::Max(10, $script:TestReport.Width - 1)
    if ($Text.Length -gt $room) { $Text = $Text.Substring($Text.Length - $room) }
    try { Write-Host ($Text.PadRight($room) + "`r") -NoNewline } catch { }
  }
}

function Clear-TestProgress {
  if ($script:TestReport.Quiet) { return }
  if (-not [Console]::IsOutputRedirected) {
    try { Write-Host ((' ' * ([Math]::Max(10, $script:TestReport.Width - 1))) + "`r") -NoNewline } catch { }
  }
}

function Write-TestCounts([string]$Label, [int]$Pass, [int]$Fail, [int]$Skip, [int]$Total) {
  $parts = New-Object System.Collections.Generic.List[string]
  if ($Pass -gt 0) { $parts.Add([string]$Pass + ' passed') }
  if ($Fail -gt 0) { $parts.Add((Get-TestMark 'fail') + ' ' + [string]$Fail + ' failed') }
  if ($Skip -gt 0) { $parts.Add([string]$Skip + ' skipped') }
  if ($parts.Count -eq 0) { $parts.Add('0 checks') }
  Write-Host (' ' + $Label.PadLeft(10) + '  ' + ($parts -join ' | ') + ' (' + [string]$Total + ')')
}

# the block at the end of a run; tests\run.ps1 owns the numbers, this owns the shape
function Write-TestSummary($Run) {
  Write-Host ''
  Write-TestCounts 'Parts' ([int]$Run.PartsPass) ([int]$Run.PartsFail) ([int]$Run.PartsSkip) ([int]$Run.Parts)
  Write-TestCounts 'Tests' ([int]$Run.Pass) ([int]$Run.Fail) ([int]$Run.Skip) ([int]$Run.Total)
  $line = '   Duration  ' + (Format-TestDuration ([double]$Run.Seconds))
  if ($Run.Slowest) { $line = $line + '   slowest ' + $Run.Slowest }
  Write-Host $line
  if ($Run.Fails -and @($Run.Fails).Count -gt 0) {
    Write-Host ''
    foreach ($f in @($Run.Fails)) { Write-Host ('  ' + (Get-TestMark 'fail') + '  ' + [string]$f) }
  }
}

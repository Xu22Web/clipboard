#Requires -Version 5.1
<#
  tests\lib\reporter.ps1 - the one place that prints what the tests did.

  Two processes print: a part that runs checks (tests\unit\*.ps1, tests\cli\*.ps1, ...) and
  tests\run.ps1, which starts the parts. Both load this file, so a line looks the same
  wherever it comes from.

  The shapes follow the runner most people read these days - a header, one row per part with
  its count and time, a failure that shows where it happened, and one block at the end:

       RUN  clipboard 0.1.0  on powershell 5.1.26100.9836 (AMD64)
            10 files, up to 12 at a time

      v unit        (579 tests)   53.1s
      v template    (14 tests)    1m 08s
      x history     (22 tests)    1m 03s   4 failed

      Test Files  9 passed | 1 failed (10)
           Tests  733 passed | 4 failed | 1 skipped (735)
        Duration  2m 09s (slowest build 2m 09s)

  The marks are the glyphs a console draws once the rows are read as sentences (v / x / down),
  and the ascii words ok / FAIL / skip when the output is redirected or -NoColor was asked for:
  a log file stays greppable and a font-less console stays readable.

  Colour is ANSI and only when the handle is a console that takes it: a redirected run, a host
  without virtual terminal support, and NO_COLOR all get the same rows without escapes.
#>

$script:TestReport = @{
  Mode     = 'default'          # default | verbose
  Quiet    = $false
  Color    = $false
  Glyphs   = $false
  Progress = $false
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
function Initialize-TestReporter([string]$Mode = 'default', [switch]$Quiet, [switch]$NoColor, [switch]$Progress) {
  $script:TestReport.Mode = $Mode
  $script:TestReport.Quiet = [bool]$Quiet
  $script:TestReport.Width = Get-TestConsoleWidth
  # the quiet path prints nothing, so it must not pay for the console probe (a csc run)
  $redirected = $false
  try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $true }
  $script:TestReport.Color = (-not [bool]$Quiet) -and (-not [bool]$NoColor) -and (Test-VirtualTerminal)
  # a check mark says more than the word ok, but only a console draws it and only a font shows
  # it: a redirected log and -NoColor keep the ascii words, which also stay greppable
  $script:TestReport.Glyphs = (-not [bool]$Quiet) -and (-not [bool]$NoColor) -and (-not $redirected)
  # the live line is opt-in: it is the one part of the output that repaints the terminal, and
  # a run that is read after the fact is clearer without it
  $script:TestReport.Progress = [bool]$Progress
  if ($script:TestReport.Glyphs) {
    $script:TestReport.Marks = @{
      pass = [string][char]0x2713
      fail = [string][char]0x00D7
      skip = [string][char]0x2193
      info = [string][char]0x00B7
    }
  }
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

# The mark, optionally padded to a column width. The padding has to happen here: the colour
# wraps the word in escape sequences, and PadRight on the wrapped string counts them and adds
# nothing, which left the glyph rows one column short of the ascii ones.
function Get-TestMark([string]$Kind, [int]$Pad = 0) {
  $word = [string]$script:TestReport.Marks[$Kind]
  if (-not $word) { $word = [string]$Kind }
  if ($Pad -gt $word.Length) { $word = $word + (' ' * ($Pad - $word.Length)) }
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
  $line = (Get-TestMark $Result 5) + $Group + ' > ' + $Name
  if ($Result -eq 'SKIP') { $line = $line + '   ' + $Detail }
  elseif ($Ms -gt 0) { $line = $line + '   ' + (Format-TestDuration ($Ms / 1000.0)) }
  Write-Host $line
  if ($Result -eq 'FAIL' -and $Detail) { Write-TestWrapped $Detail 6 }
}

# one part, once it is done (tests\run.ps1): the mark, the name, how many checks, how long
function Write-TestPartRow([string]$Part, [int]$Checks, [double]$Seconds, [int]$Failed, [int]$Skipped) {
  $kind = 'pass'
  if ($Failed -gt 0) { $kind = 'fail' } elseif ($Skipped -gt 0 -and $Checks -eq $Skipped) { $kind = 'skip' }
  $note = ''
  if ($Failed -gt 0) { $note = '   ' + [string]$Failed + ' failed' }
  elseif ($Skipped -gt 0) { $note = '   ' + [string]$Skipped + ' skipped' }
  $what = if ($Checks -eq 1) { 'test' } else { 'tests' }
  $count = '(' + [string]$Checks + ' ' + $what + ')'
  Write-Host ((Get-TestMark $kind 5) + $Part.PadRight(10) + $count.PadRight(14) + (Format-TestDuration $Seconds) + $note)
}

function Write-TestFailureBlock([string]$Part, [string]$Group, [string]$Name, [string]$Detail) {
  Write-Host ('  ' + (Get-TestMark 'fail') + '  ' + $Part + ' > ' + $Group + ' > ' + $Name)
  if ($Detail) { Write-TestWrapped $Detail 8 }
}

function Write-TestRunHeader([string]$Version, [string]$PowerShell, [string]$Platform, [int]$Parts, [int]$Workers) {
  Write-Host (' RUN  clipboard ' + $Version + '  on ' + $PowerShell + ' (' + $Platform + ')')
  $what = if ($Parts -eq 1) { 'file' } else { 'files' }
  Write-Host ('      ' + [string]$Parts + ' ' + $what + ', up to ' + [string]$Workers + ' at a time')
  Write-Host ''
}

# a single line that is repainted while parts run; opt-in, and only when the output is a console
function Write-TestProgress([string]$Text) {
  if ($script:TestReport.Quiet) { return }
  if (-not $script:TestReport.Progress) { return }
  if ([Console]::IsOutputRedirected) { return }
  $room = [Math]::Max(10, $script:TestReport.Width - 2)
  if ($Text.Length -gt $room) { $Text = $Text.Substring($Text.Length - $room) }
  try {
    # erase to the end of the line when the console takes escapes: padding to its width breaks
    # the moment the real width is smaller than the one this process measured
    if ($script:TestReport.Color) { Write-Host ($Text + [string][char]27 + '[K') -NoNewline }
    else { Write-Host ($Text.PadRight($room)) -NoNewline }
    Write-Host "`r" -NoNewline
  } catch { }
}

function Clear-TestProgress {
  if ($script:TestReport.Quiet) { return }
  if (-not $script:TestReport.Progress) { return }
  if ([Console]::IsOutputRedirected) { return }
  try {
    if ($script:TestReport.Color) { Write-Host ([string][char]27 + '[K') -NoNewline }
    else { Write-Host (' ' * ([Math]::Max(10, $script:TestReport.Width - 2))) -NoNewline }
    Write-Host "`r" -NoNewline
  } catch { }
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
  Write-TestCounts 'Test Files' ([int]$Run.PartsPass) ([int]$Run.PartsFail) ([int]$Run.PartsSkip) ([int]$Run.Parts)
  Write-TestCounts 'Tests' ([int]$Run.Pass) ([int]$Run.Fail) ([int]$Run.Skip) ([int]$Run.Total)
  $line = '   Duration  ' + (Format-TestDuration ([double]$Run.Seconds))
  if ($Run.Slowest) { $line = $line + ' (slowest ' + $Run.Slowest + ')' }
  Write-Host $line
  if ($Run.Fails -and @($Run.Fails).Count -gt 0) {
    Write-Host ''
    foreach ($f in @($Run.Fails)) { Write-Host ('  ' + (Get-TestMark 'fail') + '  ' + [string]$f) }
  }
}

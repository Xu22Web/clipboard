#Requires -Version 5.1
<#
  tests\lib\reporter.ps1 - the one place that prints what the tests did.

  Two processes print: a part that runs checks (tests\unit\*.ps1, tests\cli\*.ps1, ...) and
  tests\run.ps1, which starts the parts. Both load this file, so a line looks the same
  wherever it comes from.

  The output is vitest's, one to one, because that is what a reader already knows:


       RUN  clipboard v0.1.0  D:\project\clipboard

       v unit\unit.ps1 (236 tests) 19.4s
       v cli\config.ps1 (23 tests) 31.2s
       x cli\history.ps1 (22 tests | 4 failed) 1m 03s
         x int > the fake clipboard reads back 12ms

      ------ Failed Tests 4 ------

       FAIL  cli\history.ps1 > int > the fake clipboard reads back
             wanted "fake-one", got nothing

      -------------------------------

       Test Files  11 passed | 1 failed (12)
            Tests  412 passed | 1 failed | 1 skipped (414)
         Start at  22:41:07
         Duration  3m 20s (slowest pkg\build.ps1 2m 43s)


  A mark is a glyph in a console and the word ok / FAIL / skip when the output is redirected or
  -NoColor was asked for: a log stays greppable and a console without the font stays readable.
  A failure is printed once, after the last part, never between the rows.

  Colour is ANSI and only when the handle is a console that takes it: a redirected run, a host
  without virtual terminal support, and NO_COLOR all get the same rows without escapes.
#>

$script:TestReport = @{
  Mode     = 'default'          # default | verbose
  Quiet    = $false
  Color    = $false
  Glyphs   = $false
  Progress = $false
  Window   = @()
  WindowHeight = 0
  FrameRows = 0                 # height the live block keeps once it is on screen
  Capture  = $null
  Width    = 100
  LastMark = $null
  # ascii on purpose: the tool and its tests stay readable on a console without the glyphs,
  # and a redirected log keeps the same words
  Marks    = @{ pass = 'ok'; fail = 'FAIL'; skip = 'skip'; info = '..' }
  Ansi     = @{ pass = ''; fail = ''; skip = ''; dim = ''; reset = '' }
}

function Get-TestConsoleWidth {
  $w = 100
  # the smaller of the two: a width larger than the real one makes a row wrap, and a wrapped row
  # takes a line the frame did not count
  try {
    if (-not [Console]::IsOutputRedirected) {
      $w = [int][Console]::WindowWidth
      try {
        $raw = [int]$Host.UI.RawUI.WindowSize.Width
        if ($raw -gt 0 -and $raw -lt $w) { $w = $raw }
      } catch { }
    }
  } catch { $w = 100 }
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
function Initialize-TestReporter([string]$Mode = 'default', [switch]$Quiet, [switch]$NoColor, [switch]$NoProgress) {
  $script:TestReport.Mode = $Mode
  $script:TestReport.Quiet = [bool]$Quiet
  $script:TestReport.Width = Get-TestConsoleWidth
  # the quiet path prints nothing, so it must not pay for the console probe (a csc run)
  $redirected = $false
  try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $true }
  $vt = $false
  if (-not [bool]$Quiet) { $vt = Test-VirtualTerminal }
  $script:TestReport.Color = $vt -and (-not [bool]$NoColor)
  # a check mark says more than the word ok, but only a console draws it and only a font shows
  # it: a redirected log and -NoColor keep the ascii words, which also stay greppable
  $script:TestReport.Glyphs = (-not [bool]$Quiet) -and (-not [bool]$NoColor) -and (-not $redirected)
  # The live block repaints lines under the finished ones, which needs a console and an escape
  # sequence the host understands. It is on by default because a run of a few minutes is not
  # readable without it, and it disappears by itself when the output is a pipe or a file.
  $script:TestReport.Progress = $vt -and (-not [bool]$NoProgress)
  $script:TestReport.Window = @()
  $script:TestReport.WindowHeight = 0
  $script:TestReport.FrameRows = 0
  $script:TestReport.Capture = $null
  if ($script:TestReport.Glyphs) {
    $script:TestReport.Marks = @{
      pass = [string][char]0x2713
      fail = [string][char]0x00D7
      skip = [string][char]0x2193
      run  = [string][char]0x276F
      info = [string][char]0x00B7
    }
  } else {
    $script:TestReport.Marks = @{
      pass = 'ok'; fail = 'FAIL'; skip = 'skip'; run = '..'; info = '..'
    }
  }
  if ($script:TestReport.Color) {
    $esc = [string][char]27
    # the palette vitest prints with: green for what passed, bold red for what failed, yellow
    # for what was skipped, dim for counts and the summary titles, gray for the total
    $script:TestReport.Ansi = @{
      pass = $esc + '[32m'; fail = $esc + '[31m'; skip = $esc + '[33m'
      green = $esc + '[32m'; red = $esc + '[31m'; yellow = $esc + '[33m'
      boldgreen = $esc + '[1;32m'; boldred = $esc + '[1;31m'; boldyellow = $esc + '[1;33m'
      bold = $esc + '[1m'; dim = $esc + '[2m'; gray = $esc + '[90m'
      reset = $esc + '[0m'
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

# the quiet part of a row: counts in brackets, a duration, the "(slowest x)" note
function Get-TestDim([string]$Text) {
  if (-not $script:TestReport.Color) { return $Text }
  return ($script:TestReport.Ansi.dim + $Text + $script:TestReport.Ansi.reset)
}

# one colour out of the palette above, by name, and unchanged when colour is off
function Get-TestColor([string]$Kind, [string]$Text) {
  if (-not $script:TestReport.Color) { return $Text }
  $code = [string]$script:TestReport.Ansi[$Kind]
  if (-not $code) { return $Text }
  return ($code + $Text + $script:TestReport.Ansi.reset)
}

# vitest dims the directory, bolds the file name and dims the extension, so the eye lands on
# the name
function Get-TestPath([string]$Path) {
  if (-not $script:TestReport.Color) { return $Path }
  $dir = ''
  $name = $Path
  $cut = $Path.LastIndexOfAny([char[]]@('\', '/'))
  if ($cut -ge 0) { $dir = $Path.Substring(0, $cut + 1); $name = $Path.Substring($cut + 1) }
  $ext = ''
  $dot = $name.LastIndexOf('.')
  if ($dot -gt 0) { $ext = $name.Substring($dot); $name = $name.Substring(0, $dot) }
  return ((Get-TestColor 'dim' $dir) + (Get-TestColor 'bold' $name) + (Get-TestColor 'dim' $ext))
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
      Write-TestLog ($pad + $rest.Substring(0, $cut).TrimEnd())
      $rest = $rest.Substring($cut).TrimStart()
    }
    if ($rest.Length -gt 0) { Write-TestLog ($pad + $rest) }
  }
}

# one check under its part: vitest prints the checks inside a file, not just the file, so this
# is what the default reporter shows. The detail is not printed here: a failure is collected
# and printed once at the end, the way vitest does it.
function Write-TestCheck([string]$Group, [string]$Name, [string]$Result, [string]$Detail, [int]$Ms) {
  if ($script:TestReport.Quiet) { return }
  $kind = 'pass'
  if ($Result -eq 'FAIL') { $kind = 'fail' } elseif ($Result -eq 'SKIP') { $kind = 'skip' }
  $row = '   ' + (Get-TestMark $kind) + ' ' + $Group + ' > ' + $Name
  if ($Result -eq 'SKIP' -and $Detail) { $row = $row + ' ' + (Get-TestDim ('[' + $Detail + ']')) }
  elseif ($Ms -gt 0) { $row = $row + ' ' + (Get-TestDim (Format-TestDuration ($Ms / 1000.0))) }
  Write-TestLog $row
}

# one part, printed the way vitest prints one file: mark, path, counts in brackets, duration
function Write-TestModuleRow([string]$Name, [int]$Checks, [int]$Failed, [int]$Skipped, [double]$Seconds) {
  $kind = 'pass'
  if ($Failed -gt 0) { $kind = 'fail' } elseif ($Checks -gt 0 -and $Checks -eq $Skipped) { $kind = 'skip' }
  $bits = New-Object System.Collections.Generic.List[string]
  $bits.Add([string]$Checks + ' ' + $(if ($Checks -eq 1) { 'test' } else { 'tests' }))
  if ($Failed -gt 0) { $bits.Add([string]$Failed + ' failed') }
  if ($Skipped -gt 0) { $bits.Add([string]$Skipped + ' skipped') }
  $row = ' ' + (Get-TestMark $kind) + ' ' + (Get-TestPath $Name) + ' ' + (Get-TestDim '(') + ($bits -join (Get-TestDim ' | ')) + (Get-TestDim ')')
  if ($Seconds -gt 0) {
    $span = Format-TestDuration $Seconds
    if ($Seconds -ge 1) { $row = $row + ' ' + (Get-TestColor 'yellow' $span) }
    else { $row = $row + ' ' + $span }
  }
  Write-TestLog $row
}

# the banner vitest opens with: an empty line, the version and the root it is about to test
function Write-TestBanner([string]$Version, [string]$Root) {
  Write-TestLog ''
  Write-TestLog (' RUN  clipboard v' + $Version + '  ' + $Root)
  Write-TestLog ''
}

# a full-width rule with a label in the middle, the shape vitest uses for its failure banner
function Get-TestRule([string]$Label = '') {
  $width = [Math]::Max(20, $script:TestReport.Width)
  $ch = if ($script:TestReport.Glyphs) { [string][char]0x23AF } else { '-' }
  if (-not $Label) { return ($ch * $width) }
  $side = [int][Math]::Floor(($width - $Label.Length) / 2)
  if ($side -lt 2) { $side = 2 }
  return (($ch * $side) + $Label + ($ch * $side))
}

# everything that failed, printed once after the last part. Each item is { Name, Detail }.
function Write-TestFailures($Items) {
  # walking the list instead of @($Items): wrapping a List[object] throws
  # "Argument types do not match" in 5.1
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($i in $Items) { if ($null -ne $i) { $list.Add($i) } }
  if ($list.Count -eq 0) { return }
  Write-TestLog ''
  Write-TestLog (Get-TestRule (' Failed Tests ' + [string]$list.Count + ' '))
  Write-TestLog ''
  foreach ($item in $list) {
    $label = ' FAIL '
    if ($script:TestReport.Color) { $label = $script:TestReport.Ansi.fail + $label + $script:TestReport.Ansi.reset }
    Write-TestLog ($label + ' ' + [string]$item.Name)
    if ($item.Detail) { Write-TestWrapped ([string]$item.Detail).Trim() 8 }
    Write-TestLog ''
  }
  Write-TestLog (Get-TestRule)
}

# failed | passed | skipped, the order vitest uses, then the total in brackets
function Get-TestState([int]$Pass, [int]$Fail, [int]$Skip, [int]$Total) {
  $bits = New-Object System.Collections.Generic.List[string]
  if ($Fail -gt 0) { $bits.Add((Get-TestColor 'boldred' ([string]$Fail + ' failed'))) }
  if ($Pass -gt 0) { $bits.Add((Get-TestColor 'boldgreen' ([string]$Pass + ' passed'))) }
  if ($Skip -gt 0) { $bits.Add((Get-TestColor 'yellow' ([string]$Skip + ' skipped'))) }
  if ($bits.Count -eq 0) { $bits.Add((Get-TestDim 'no checks')) }
  return (($bits -join (Get-TestDim ' | ')) + ' ' + (Get-TestColor 'gray' ('(' + [string]$Total + ')')))
}

function Get-TestSummaryLine([string]$Label, [string]$Value) {
  return ((Get-TestDim (' ' + $Label.PadLeft(10) + '  ')) + $Value)
}

function Write-TestSummaryLine([string]$Label, [string]$Value) {
  Write-TestLog (Get-TestSummaryLine $Label $Value)
}

# the block at the end of a run; tests\run.ps1 owns the numbers, this owns the shape
function Write-TestSummary($Run) {
  Write-TestLog ''
  Write-TestSummaryLine 'Test Files' (Get-TestState ([int]$Run.PartsPass) ([int]$Run.PartsFail) ([int]$Run.PartsSkip) ([int]$Run.Parts))
  Write-TestSummaryLine 'Tests' (Get-TestState ([int]$Run.Pass) ([int]$Run.Fail) ([int]$Run.Skip) ([int]$Run.Total))
  if ($Run.StartAt) { Write-TestSummaryLine 'Start at' ([string]$Run.StartAt) }
  $span = Format-TestDuration ([double]$Run.Seconds)
  if ($Run.Slowest) { $span = $span + ' ' + (Get-TestDim ('(slowest ' + [string]$Run.Slowest + ')')) }
  Write-TestSummaryLine 'Duration' $span
  Write-TestLog ''
}

# the tree the default reporter prints for a single file, or for a file that failed: the
# describe block with the checks it held, then the checks themselves. Indentation follows
# vitest: the file row is flush, a suite sits three columns in, a check two more.
function Write-TestPartTree($Rows) {
  if ($script:TestReport.Quiet) { return }
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($r in $Rows) { if ($null -ne $r) { $list.Add($r) } }
  $groups = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  foreach ($r in $list) {
    $name = [string]$r.Group
    if (-not $seen.ContainsKey($name)) {
      $seen[$name] = $groups.Count
      $groups.Add(@{
          Name    = $name
          Count   = 0
          Failed  = 0
          Skipped = 0
          Ms      = 0
          Rows    = (New-Object System.Collections.Generic.List[object])
        })
    }
    $g = $groups[$seen[$name]]
    $g.Count = $g.Count + 1
    if ($r.Result -eq 'FAIL') { $g.Failed = $g.Failed + 1 } elseif ($r.Result -eq 'SKIP') { $g.Skipped = $g.Skipped + 1 }
    $g.Ms = $g.Ms + [int]$r.Ms
    $g.Rows.Add($r)
  }
  foreach ($g in $groups) {
    $kind = 'pass'
    if ($g.Failed -gt 0) { $kind = 'fail' } elseif ($g.Count -eq $g.Skipped) { $kind = 'skip' }
    $bits = [string]$g.Count + ' ' + $(if ($g.Count -eq 1) { 'test' } else { 'tests' })
    if ($g.Failed -gt 0) { $bits = $bits + ' | ' + [string]$g.Failed + ' failed' }
    elseif ($g.Skipped -gt 0) { $bits = $bits + ' | ' + [string]$g.Skipped + ' skipped' }
    $row = '   ' + (Get-TestMark $kind) + ' ' + $g.Name + ' ' + (Get-TestDim ('(' + $bits + ')'))
    if ($g.Ms -gt 0) { $row = $row + ' ' + (Format-TestDuration ($g.Ms / 1000.0)) }
    Write-TestLog $row
    foreach ($r in $g.Rows) {
      $k = 'pass'
      if ($r.Result -eq 'FAIL') { $k = 'fail' } elseif ($r.Result -eq 'SKIP') { $k = 'skip' }
      $line = '     ' + (Get-TestMark $k) + ' ' + [string]$r.Test
      if ($r.Result -eq 'SKIP' -and $r.Detail) { $line = $line + ' ' + (Get-TestDim ('[' + [string]$r.Detail + ']')) }
      Write-TestLog $line
    }
  }
}

# a part run on its own is a single file run: its row, its tree, its failures, the summary
function Write-TestPartReport([string]$Name, $Rows, [double]$Seconds, [datetime]$StartAt) {
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($r in $Rows) { if ($null -ne $r) { $list.Add($r) } }
  $pass = 0
  $fail = 0
  $skipped = 0
  $items = @()
  foreach ($r in $list) {
    if ($r.Result -eq 'FAIL') {
      $fail = $fail + 1
      $items += @{ Name = ($Name + ' > ' + [string]$r.Group + ' > ' + [string]$r.Test); Detail = [string]$r.Detail }
    } elseif ($r.Result -eq 'SKIP') { $skipped = $skipped + 1 } else { $pass = $pass + 1 }
  }
  Write-TestModuleRow $Name $list.Count $fail $skipped $Seconds
  Write-TestPartTree $list
  Write-TestFailures $items
  $run = @{
    Parts = 1
    PartsPass = $(if ($fail -gt 0) { 0 } else { 1 })
    PartsFail = $(if ($fail -gt 0) { 1 } else { 0 })
    PartsSkip = 0
    Pass = $pass; Fail = $fail; Skip = $skipped; Total = $list.Count
    Seconds = $Seconds
    StartAt = $StartAt.ToString('HH:mm:ss')
    Slowest = ''
  }
  Write-TestSummary $run
}

# ---------------------------------------------------------------- terminal window
# This is vitest's WindowRenderer, ported: it keeps a window of lines at the bottom of the
# terminal and pushes everything else above it. The details are the ones that make it stop
# flickering, and none of them are optional:
#
#   - the whole frame is wrapped in ESC[?2026h / ESC[?2026l (synchronized output), so the
#     terminal commits it in one go instead of repainting row by row
#   - the window is erased with ESC[K plus ESC[1A per row, never by deleting rows: a deletion
#     reflows everything below it, and that reflow is the flicker
#   - the window text ends without a line break, so the cursor rests on its last row and the
#     next erase starts there
#   - a line printed while the window is up is written where the window began, and the window
#     is pushed back down by as many rows as it shrank, so no gap opens between them
function Write-TestOut([string]$Text) {
  if ($script:TestReport.Quiet) { return }
  if (-not $Text) { return }
  # one call for the whole string: Write-Host hands it to the host in one piece, where several
  # calls per frame let the host reorder the escape sequences
  try { Write-Host -NoNewline $Text } catch { }
}

# a line of output that belongs above the window
function Write-TestLog([string]$Text) {
  if ($script:TestReport.Quiet) { return }
  $line = ([string]$Text).TrimEnd("`r", "`n") + "`r`n"
  # while a block is being collected the line waits here, so a part's row and tree reach the
  # window in one frame instead of one repaint per line
  if ($null -ne $script:TestReport.Capture) { $script:TestReport.Capture.Add($line); return }
  if ($script:TestReport.Progress) { Write-TestWindow $line } else { Write-TestOut $line }
}

function Start-TestCapture {
  $script:TestReport.Capture = New-Object System.Collections.Generic.List[string]
}

function Get-TestCaptured {
  $text = ''
  if ($null -ne $script:TestReport.Capture) { $text = ($script:TestReport.Capture -join '') }
  $script:TestReport.Capture = $null
  return $text
}

# A row wider than the console wraps, and a wrapped row takes two lines while the frame counted
# one: the frame then clears one row too few and the window creeps down the screen. Rows are
# clipped to the console width instead; escape sequences are kept and only visible characters
# count against it.
function Get-TestClip([string]$Text, [int]$Columns) {
  if (-not $Text) { return '' }
  $esc = [string][char]27
  $limit = $Columns - 1
  $out = New-Object System.Text.StringBuilder
  $width = 0
  $i = 0
  while ($i -lt $Text.Length) {
    if ($Text[$i] -eq $esc) {
      $j = $i + 1
      if ($j -lt $Text.Length -and $Text[$j] -eq '[') {
        $j = $j + 1
        while ($j -lt $Text.Length -and -not [char]::IsLetter($Text[$j])) { $j = $j + 1 }
        if ($j -lt $Text.Length) { $j = $j + 1 }
      } elseif ($j -lt $Text.Length) {
        $j = $j + 1
      }
      [void]$out.Append($Text.Substring($i, $j - $i))
      $i = $j
      continue
    }
    if ($width -ge $limit) {
      [void]$out.Append($esc + '[0m')
      break
    }
    [void]$out.Append($Text[$i])
    $width = $width + 1
    $i = $i + 1
  }
  return $out.ToString()
}

function Set-TestWindow($Lines) {
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($line in $Lines) { $list.Add([string]$line) }
  $script:TestReport.Window = $list.ToArray()
}

function Write-TestWindow([string]$Message = '') {
  if (-not $script:TestReport.Progress) {
    if ($Message) { Write-TestOut $Message }
    return
  }
  $esc = [string][char]27
  $columns = [Math]::Max(20, $script:TestReport.Width)
  $window = New-Object System.Collections.Generic.List[string]
  foreach ($line in @($script:TestReport.Window)) { $window.Add((Get-TestClip ([string]$line) $columns)) }
  $messageText = ''
  $messageRows = 0
  if ($Message) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($part in ($Message.TrimEnd("`r", "`n") -split "`r`n|`r|`n")) { $parts.Add((Get-TestClip ([string]$part) $columns)) }
    $messageText = ($parts -join "`r`n") + "`r`n"
    $messageRows = $parts.Count
  }
  # The frame must stay inside the screen: the moment the block reaches past the last row the
  # terminal scrolls, and a scrolled block leaves a copy of itself in the scrollback that no
  # erase can reach - that is the block that repeats when you scroll up. So the frame keeps a
  # fixed height that never changes after the first one, and the block is cut to fit under the
  # rows printed above it. The frame starts eight rows short of the screen: the banner and
  # whatever the shell printed before it sit above the block.
  $screen = 0
  try { $screen = [Console]::WindowHeight } catch { $screen = 0 }
  $cap = 8
  if ($screen -gt 8) { $cap = $screen - 8 } else { $cap = [Math]::Max(1, $screen - 5) }
  $frame = [int]$script:TestReport.FrameRows
  $need = $messageRows + $window.Count
  if ($frame -le 0) {
    $frame = [Math]::Min($cap, [Math]::Max(1, $need))
  } elseif ($need -gt $frame -and $frame -lt $cap) {
    # the first frames can come before every part has started, so the frame grows to fit the
    # rest - but only up to the cap, which is what keeps its last row inside the screen
    $frame = [Math]::Min($cap, $need)
  }
  $budget = $frame - $messageRows
  if ($budget -lt 1) { $budget = 1 }
  $dropped = 0
  if ($window.Count -gt $budget) {
    $dropped = $window.Count - $budget + 1
    $kept = New-Object System.Collections.Generic.List[string]
    $kept.Add((Get-TestDim (' ... ' + [string]$dropped + ' more')))
    for ($i = $window.Count - ($budget - 1); $i -lt $window.Count; $i++) { $kept.Add($window[$i]) }
    $window = $kept
  }
  $rows = $window.Count
  $old = [int]$script:TestReport.WindowHeight
  # vitest counts the window only: the message above it is written outside the counted region,
  # so a finished row stays on screen and the window keeps ending on the same line. The padding
  # takes the message's rows, which keeps the frame's own height - and therefore its last row,
  # the one the screen would scroll - where it was.
  $padding = $frame - $messageRows - $rows
  if ($padding -lt 0) { $padding = 0 }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append($esc + '[?2026h')
  if ($old -gt 0) {
    # back to column one first: the window ends on an empty line, but a row that was written
    # without one would leave the cursor mid line and ESC[K would erase only the tail
    [void]$sb.Append("`r")
    [void]$sb.Append($esc + '[K')
    for ($i = 1; $i -lt $old; $i++) { [void]$sb.Append($esc + '[1A' + $esc + '[K') }
  } elseif ($frame -gt 1) {
    # nothing to erase yet: reserve the frame with blank lines first. A cursor that already sits
    # on the last row then scrolls blanks into the scrollback instead of a copy of the block.
    [void]$sb.Append("`r`n" * ($frame + $messageRows - 1))
    [void]$sb.Append("`r")
    for ($i = 1; $i -lt ($frame + $messageRows); $i++) { [void]$sb.Append($esc + '[1A') }
  }
  if ($messageText) { [void]$sb.Append($messageText) }
  if ($padding -gt 0) { [void]$sb.Append("`r`n" * $padding) }
  if ($rows -gt 0) { [void]$sb.Append(($window -join "`r`n")) }
  [void]$sb.Append($esc + '[?2026l')
  Write-TestOut $sb.ToString()
  if ([string]$env:CB_TEST_WINDOW_LOG) {
    try {
      $rec = 'old=' + $old + ' rows=' + $rows + ' msg=' + $messageRows + ' pad=' + $padding + ' frame=' + $frame + ' cap=' + $cap + ' drop=' + $dropped + ' cols=' + $columns + ' screen=' + $screen + "`r`n"
      [IO.File]::AppendAllText([string]$env:CB_TEST_WINDOW_LOG, $rec)
    } catch { }
  }
  $script:TestReport.FrameRows = $frame
  $script:TestReport.WindowHeight = $frame
}

function Clear-TestWindow {
  if (-not $script:TestReport.Progress) { return }
  $old = [int]$script:TestReport.WindowHeight
  $script:TestReport.Window = @()
  $script:TestReport.WindowHeight = 0
  if ($old -le 0) { return }
  $esc = [string][char]27
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append($esc + '[?2026h')
  [void]$sb.Append("`r")
  [void]$sb.Append($esc + '[K')
  for ($i = 1; $i -lt $old; $i++) { [void]$sb.Append($esc + '[1A' + $esc + '[K') }
  [void]$sb.Append($esc + '[?2026l')
  Write-TestOut $sb.ToString()
}

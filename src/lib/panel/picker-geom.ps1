# lib/panel/picker-geom.ps1 - pure geometry and text helpers of the panel: visible row count, the
# numeric quick-pick mapping, where the window goes on screen, and which characters of a
# label match the search.
#
# No control is created or touched here, so these are unit-testable on their own and the
# panel file only has to draw and dispatch.

# --- pure helpers (no UI dependency, covered by the unit tests) -------------------
function Get-VisibleRowCount([int]$listHeight, [int]$rowHeight) {
  if ($rowHeight -lt 1) { return 1 }
  $n = [int][Math]::Floor($listHeight / $rowHeight)
  if ($n -lt 1) { return 1 }
  return $n
}

# The row height and the chrome come from the same metric table a theme may restyle, so a
# theme with taller rows keeps the row count honest instead of cutting the last row off.
function Get-PanelRowHeight { return [int]$script:Metric['RowHeight'] }

# everything that is not a row: header, footer and the 1 px border on each side
function Get-PanelChrome { return ([int]$script:Metric['HeadHeight'] + [int]$script:Metric['FootHeight'] + 2) }

# Chrome of one panel shape. The preset carries the header and footer heights because the
# compact panel keeps the theme's colours but not its taller chrome.
function Get-PresetChrome($preset) {
  if ($null -eq $preset) { return (Get-PanelChrome) }
  return ([int]$preset.Head + [int]$preset.Foot + 2)
}

# The two panel shapes and what actually differs between them. This is the only place that
# decides, so the drawing, the keys and the paste stay one code path. Full keeps every column
# and the theme's chrome; compact drops the time column, the right-hand count and the version,
# uses a shorter header and footer, and always follows the caret. Width and row count come from
# the setting of each shape, so neither number means two things.
function Get-PanelPreset([string]$mode) {
  if ($mode -eq 'compact') {
    return @{
      Mode = 'compact'; Width = [int]$script:CompactWidth; Rows = [int]$script:CompactRows
      Head = 60; Foot = 32
      ShowTime = $false; ShowFootRight = $false; AnchorCaret = $true
    }
  }
  return @{
    Mode = 'full'; Width = [int]$script:WinWidth; Rows = [int]$script:Rows
    Head = [int]$script:Metric['HeadHeight']; Foot = [int]$script:Metric['FootHeight']
    ShowTime = [bool]$script:ShowTime; ShowFootRight = $true; AnchorCaret = [bool]$script:PlaceAtCaret
  }
}

# The window height is never a setting of its own: it follows from the number of rows, so
# a row is never half cut off and raising the row count cannot silently make the panel
# taller than the screen. These two are the only conversion, shared by the panel and by
# the config checks, and they take the metrics as arguments so they stay pure.
function Get-PanelHeight([int]$rows, [int]$rowHeight, [int]$chrome) {
  if ($rows -lt 1) { $rows = 1 }
  if ($rowHeight -lt 1) { return $chrome }
  return ($chrome + ($rows * $rowHeight))
}

# how many whole rows fit into a height budget (a screen work area, for example)
function Get-RowFit([int]$height, [int]$rowHeight, [int]$chrome) {
  if ($rowHeight -lt 1) { return 1 }
  $n = [int][Math]::Floor(($height - $chrome) / $rowHeight)
  if ($n -lt 1) { return 1 }
  return $n
}

# rows the screen can actually show: the configured count, capped by what fits and never
# below the minimum the panel needs to stay usable (an unknown screen keeps the request)
function Get-RowsForScreen([int]$rows, [int]$screenHeight, [int]$rowHeight, [int]$chrome, [int]$minRows) {
  if ($screenHeight -lt 1) { return $rows }
  $fit = Get-RowFit $screenHeight $rowHeight $chrome
  if ($fit -gt $rows) { $fit = $rows }
  if ($fit -lt $minRows) { $fit = $minRows }
  return $fit
}

# virtual index behind a Ctrl+<digit> press. Digits follow the visible window, not the
# absolute position in the list (uTools style), so they stay stable while scrolling.
function Get-QuickKeyIndex([int]$offset, [int]$topIndex, [int]$count, [int]$rows) {
  if ($offset -lt 0 -or $offset -gt 9) { return -1 }
  if ($rows -gt 0 -and $offset -ge $rows) { return -1 }
  $i = $topIndex + $offset
  if ($i -lt 0 -or $i -ge $count) { return -1 }
  return $i
}

# key cap caption for a visible row: the first nine rows read 1..9 and the tenth reads 0,
# so the digit under the finger is the one in the same place on a numeric keypad
function Get-QuickKeyLabel([int]$offset) {
  if ($offset -lt 0 -or $offset -gt 9) { return '' }
  if ($offset -eq 9) { return '0' }
  return [string]($offset + 1)
}

# the visible-row offset a digit means; -1 when the digit is out of range
function Get-QuickKeyOffset([int]$digit) {
  if ($digit -lt 0 -or $digit -gt 9) { return -1 }
  if ($digit -eq 0) { return 9 }
  return $digit - 1
}

# Where the panel should appear. A saved position is only honoured when the panel still
# lands on a screen; otherwise sit on the caret the user is typing at, then on the window it
# was opened from, and fall back to centring on the monitor of that window.
function Get-PickerBounds([int]$w, [int]$h, [string]$rawLeft, [string]$rawTop, $areas, $fallback, $prefer = $null, $anchor = $null, [int]$gap = 4) {
  $l = 0
  $t = 0
  $hasL = [int]::TryParse([string]$rawLeft, [ref]$l)
  $hasT = [int]::TryParse([string]$rawTop, [ref]$t)
  if ($hasL -and $hasT -and $areas) {
    foreach ($a in @($areas)) {
      $iw = [Math]::Min($l + $w, $a.Left + $a.Width) - [Math]::Max($l, $a.Left)
      $ih = [Math]::Min($t + $h, $a.Top + $a.Height) - [Math]::Max($t, $a.Top)
      if ($iw -ge 120 -and $ih -ge 60) {
        $cl = [Math]::Max($a.Left, [Math]::Min($l, $a.Left + $a.Width - $w))
        $ct = [Math]::Max($a.Top, [Math]::Min($t, $a.Top + $a.Height - $h))
        return @{ Left = [int]$cl; Top = [int]$ct; Fitted = $false }
      }
    }
  }
  # the caret is the tightest anchor: below it, and above it when the bottom of the monitor
  # comes first. The caret sits in a line of text, so the panel starts at its left edge and
  # the line stays readable; the monitor it is on decides the clamping.
  if ($null -ne $anchor -and $areas -and [int]$anchor.Width -gt 0 -and [int]$anchor.Height -gt 0) {
    $ax = [int]$anchor.Left
    $ay = [int]$anchor.Top
    $area = $null
    foreach ($a in @($areas)) {
      if ($ax -ge $a.Left -and $ax -le ($a.Left + $a.Width) -and $ay -ge $a.Top -and $ay -le ($a.Top + $a.Height)) { $area = $a; break }
    }
    if ($null -eq $area) { $area = $fallback }
    $top = $ay + [int]$anchor.Height + $gap
    if ($top + $h -gt $area.Top + $area.Height) { $top = $ay - $gap - $h }
    $left = [Math]::Max($area.Left, [Math]::Min($ax, $area.Left + $area.Width - $w))
    $top = [Math]::Max($area.Top, [Math]::Min($top, $area.Top + $area.Height - $h))
    return @{ Left = [int]$left; Top = [int]$top; Fitted = $true }
  }
  # nothing remembered: put the panel on the window the user came from (its horizontal
  # centre, a third of the way down), clamped into the monitor that window sits on
  if ($null -ne $prefer -and $areas) {
    $pw = [int]$prefer.Width
    $ph = [int]$prefer.Height
    if ($pw -ge 120 -and $ph -ge 60) {
      $pl = [int]$prefer.Left + [int](($pw - $w) / 2)
      $pt = [int]$prefer.Top + [int](($ph - $h) / 3)
      foreach ($a in @($areas)) {
        $iw = [Math]::Min([int]$prefer.Left + $pw, $a.Left + $a.Width) - [Math]::Max([int]$prefer.Left, $a.Left)
        $ih = [Math]::Min([int]$prefer.Top + $ph, $a.Top + $a.Height) - [Math]::Max([int]$prefer.Top, $a.Top)
        if ($iw -ge 120 -and $ih -ge 60) {
          $cl = [Math]::Max($a.Left, [Math]::Min($pl, $a.Left + $a.Width - $w))
          $ct = [Math]::Max($a.Top, [Math]::Min($pt, $a.Top + $a.Height - $h))
          return @{ Left = [int]$cl; Top = [int]$ct; Fitted = $true }
        }
      }
    }
  }
  $fx = [int]($fallback.Left + (($fallback.Width - $w) / 2))
  $fy = [int]($fallback.Top + (($fallback.Height - $h) / 3))
  return @{ Left = $fx; Top = $fy; Fitted = $true }
}

# which characters of one label match the search tokens (for the highlight pass)
function Get-HitMarks([string]$text, [string[]]$tokens) {
  $n = $text.Length
  $marks = New-Object 'bool[]' $n
  if ($n -eq 0) { return $marks }
  foreach ($tok in @($tokens)) {
    if (-not $tok) { continue }
    $start = 0
    while ($start -lt $n) {
      $i = $text.IndexOf($tok, $start, [StringComparison]::OrdinalIgnoreCase)
      if ($i -lt 0) { break }
      $end = $i + $tok.Length
      for ($k = $i; $k -lt $end -and $k -lt $n; $k++) { $marks[$k] = $true }
      $start = $end
    }
  }
  return $marks
}

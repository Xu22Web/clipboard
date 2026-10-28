# lib/picker-geom.ps1 - pure geometry and text helpers of the panel: visible row count, the
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
# lands on a screen; otherwise centre on the monitor of the window we came from.
function Get-PickerBounds([int]$w, [int]$h, [string]$rawLeft, [string]$rawTop, $areas, $fallback) {
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

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
# and the theme's chrome and stays where the user put it; compact drops the time column, the
# right-hand count and the version, uses a shorter header and footer, and follows the caret.
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
    ShowTime = [bool]$script:ShowTime; ShowFootRight = $true; AnchorCaret = $false
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

# --- where the panel goes ---------------------------------------------------------
# The two shapes answer different questions, so they take different paths.
#
# The compact panel is read while typing, so it belongs at the caret - Ditto's POS_AT_CARET
# and ClipAngel's "auto position" are the same idea. It opens below the line, flips above it
# when the bottom of the monitor comes first, and gives up rows rather than run off the
# screen, which is what Ditto's EnsureWindowVisible does by rewriting the rectangle from
# rcWork and returning "moved".
#
# The full panel is a place the user returns to. It never follows the caret: a remembered
# position that still lands on a screen, otherwise the centre of the screen it opens on.

# The screen a point is on, or the caller's fallback. ClipAngel picks the monitor with
# Screen.FromPoint for the same reason: the caret decides which screen, not the window.
function Get-AreaAt($areas, $fallback, [int]$x, [int]$y) {
  foreach ($a in @($areas)) {
    if ($x -ge [int]$a.Left -and $x -le ([int]$a.Left + [int]$a.Width) -and
        $y -ge [int]$a.Top -and $y -le ([int]$a.Top + [int]$a.Height)) { return $a }
  }
  return $fallback
}

# One rectangle pushed back inside one work area: the left edge wins over the right one and
# the top over the bottom, so a panel wider than the screen still starts at its left edge.
function Get-ClampedPoint($area, [int]$left, [int]$top, [int]$w, [int]$h) {
  if ($null -eq $area) { return @{ Left = $left; Top = $top } }
  $right = [int]$area.Left + [int]$area.Width
  $bottom = [int]$area.Top + [int]$area.Height
  $l = [Math]::Max([int]$area.Left, [Math]::Min($left, $right - $w))
  $t = [Math]::Max([int]$area.Top, [Math]::Min($top, $bottom - $h))
  return @{ Left = [int]$l; Top = [int]$t }
}

# Where the full panel goes. A remembered position is honoured while enough of the panel
# still shows on one screen, and clamped into that screen; otherwise the panel is centred on
# the screen it opens on, a third of the way down.
function Get-PickerBounds([int]$w, [int]$h, [string]$rawLeft, [string]$rawTop, $areas, $fallback) {
  $l = 0
  $t = 0
  $has = ([int]::TryParse([string]$rawLeft, [ref]$l)) -and ([int]::TryParse([string]$rawTop, [ref]$t))
  if ($has -and $areas) {
    foreach ($a in @($areas)) {
      $iw = [Math]::Min($l + $w, [int]$a.Left + [int]$a.Width) - [Math]::Max($l, [int]$a.Left)
      $ih = [Math]::Min($t + $h, [int]$a.Top + [int]$a.Height) - [Math]::Max($t, [int]$a.Top)
      if ($iw -ge 120 -and $ih -ge 60) {
        $p = Get-ClampedPoint $a $l $t $w $h
        return @{ Left = [int]$p.Left; Top = [int]$p.Top; Fitted = $false }
      }
    }
  }
  $area = $fallback
  if ($null -eq $area) { $area = @{ Left = 0; Top = 0; Width = $w; Height = $h } }
  $left = [int]$area.Left + [int](($area.Width - $w) / 2)
  $top = [int]$area.Top + [int](($area.Height - $h) / 3)
  $p = Get-ClampedPoint $area $left $top $w $h
  return @{ Left = [int]$p.Left; Top = [int]$p.Top; Fitted = $true }
}

# Rows, size and place of the compact panel for one caret, in screen pixels. The row count
# asked for is capped by the monitor, then by the room on the side the panel opens on: a caret
# near the bottom edge gets a shorter panel instead of one pushed over the line being read.
# A caret whose monitor is unknown keeps the requested rows and opens below it.
function Get-CompactPlacement([int]$rows, [int]$rowHeight, [int]$chrome, [int]$width, $area, [int]$anchorLeft, [int]$anchorTop, [int]$anchorHeight, [int]$minRows, [int]$gap = 4) {
  if ($rowHeight -lt 1) { $rowHeight = 1 }
  if ($minRows -lt 1) { $minRows = 1 }
  $w = [int]$width
  if ($null -eq $area) {
    $fit = Get-PanelHeight $rows $rowHeight $chrome
    return @{ Rows = [int]$rows; Width = $w; Height = $fit; Left = $anchorLeft; Top = ($anchorTop + $anchorHeight + $gap) }
  }
  if ([int]$area.Width -gt 0 -and $w -gt [int]$area.Width) { $w = [int]$area.Width }
  $roomRows = Get-RowsForScreen $rows ([int]$area.Height) $rowHeight $chrome $minRows
  $below = (([int]$area.Top + [int]$area.Height) - ($anchorTop + $anchorHeight + $gap))
  $above = (($anchorTop - $gap) - [int]$area.Top)
  $useRows = $roomRows
  $h = Get-PanelHeight $useRows $rowHeight $chrome
  if ($h -gt $below -and $h -gt $above) {
    $room = [Math]::Max($below, $above)
    $fit = Get-RowFit $room $rowHeight $chrome
    if ($fit -lt $minRows) { $fit = $minRows }
    if ($fit -lt $useRows) { $useRows = $fit }
    $h = Get-PanelHeight $useRows $rowHeight $chrome
  }
  if ($h -le $below) { $top = $anchorTop + $anchorHeight + $gap }
  elseif ($h -le $above) { $top = $anchorTop - $gap - $h }
  elseif ($below -ge $above) { $top = $anchorTop + $anchorHeight + $gap }
  else { $top = $anchorTop - $gap - $h }
  $p = Get-ClampedPoint $area $anchorLeft $top $w $h
  return @{ Rows = [int]$useRows; Width = [int]$w; Height = [int]$h; Left = [int]$p.Left; Top = [int]$p.Top }
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

# lib/ui/widgets.ps1 - the controls the drawn windows share.
#
# A widget is a rectangle plus a state, drawn by one function and hit-tested elsewhere against
# the same rectangle. The settings window and the history panel grew their own copies of these
# (a switch, a scrollbar, a row of key chips), and a copy that is fixed in one window is a bug
# that stays in the other. What is shared here is only the drawing of a control at a place on
# screen: where the place is comes from lib\ui\layout.ps1, and what the theme says comes from
# the palette the caller passes in.
#
# Every one of these takes a Graphics and leaves nothing open: brushes, pens and paths are
# disposed on the way out, which is what keeps the GDI count flat across a hundred repaints.

# A colour part way between two others, for a transition that moves rather than switches.
# Alpha is interpolated too, so a border can fade out while the fill it sits on changes.
function Get-UiBlend($from, $to, [double]$k) {
  if ($k -le 0) { return $from }
  if ($k -ge 1) { return $to }
  return [Drawing.Color]::FromArgb(
    [int][Math]::Round([double]$from.A + ([double]$to.A - [double]$from.A) * $k),
    [int][Math]::Round([double]$from.R + ([double]$to.R - [double]$from.R) * $k),
    [int][Math]::Round([double]$from.G + ([double]$to.G - [double]$from.G) * $k),
    [int][Math]::Round([double]$from.B + ([double]$to.B - [double]$from.B) * $k))
}

# A switch, at a rectangle, part way through its flip: $k is 0 for off and 1 for on, and a flip
# can be drawn on its way instead of landing in one frame. On: the accent track, the surface
# colour as the knob (bright track, dark knob in the dark theme and the other way round in the
# light one, because both tokens invert together).
function Draw-UiToggle($g, $pal, [int]$x, [int]$y, [int]$w, [int]$h, [double]$k, [bool]$enabled = $true) {
  if ($null -eq $g -or $null -eq $pal) { return }
  if ($k -lt 0) { $k = 0 }
  if ($k -gt 1) { $k = 1 }
  $track = Get-UiBlend $pal['Field'] $pal['Accent'] $k
  $knob = Get-UiBlend $pal['Text'] $pal['Surface'] $k
  if (-not $enabled) {
    # a switch that cannot take effect keeps its shape and loses its colour
    $track = $pal['Field']
    $knob = $pal['Faint']
  }
  $brush = New-Object Drawing.SolidBrush $track
  $path = New-RoundPath $x $y $w $h ([int]($h / 2))
  try { $g.FillPath($brush, $path) } finally { $path.Dispose(); $brush.Dispose() }
  if ($k -lt 0.99) {
    # the off track needs an edge: the field colour sits within a few percent of the surface
    $edgeColour = Scale-Alpha $pal['FieldBorder'] (1.0 - $k)
    if ($edgeColour.A -gt 0) {
      $pen = New-Object Drawing.Pen $edgeColour
      $edge = New-RoundPath $x $y $w $h ([int]($h / 2))
      try { $g.DrawPath($pen, $edge) } finally { $edge.Dispose(); $pen.Dispose() }
    }
  }
  # Win11 measures the thumb at 12 px inside a 20 px track, 4 px in from either end: a thumb that
  # almost fills the track reads as a different control.
  $d = [Math]::Min((Px 12), ($h - (Px 4)))
  $from = $x + (Px 4)
  $to = $x + $w - $d - (Px 4)
  $kx = [int][Math]::Round($from + (($to - $from) * $k))
  $ky = $y + [int](($h - $d) / 2)
  $kb = New-Object Drawing.SolidBrush $knob
  try { $g.FillEllipse($kb, $kx, $ky, $d, $d) } finally { $kb.Dispose() }
}

# A scrollbar thumb in its lane: no visible track, a rounded bar that widens and darkens as the
# pointer comes near. $k is the hover ramp (0 at rest, 1 under the pointer), so every window
# carrying one moves at the same speed. $lane is a box from lib\ui\layout.ps1 and $thumb is what
# Get-UiScrollMetrics answered.
function Draw-UiScrollbar($g, $pal, $lane, $thumb, [double]$k) {
  if ($null -eq $g -or $null -eq $pal -or $null -eq $lane -or $null -eq $thumb) { return }
  if ($k -lt 0) { $k = 0 }
  if ($k -gt 1) { $k = 1 }
  $w = [int][Math]::Round((Px 3) + ($k * ((Px 5) - (Px 3))))
  $alpha = [int][Math]::Round(110 + ($k * 80))
  $x = [int]$lane.Left + [int](([int]$lane.Width - $w) / 2)
  $ink = $pal['Dim']
  $brush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb($alpha, $ink.R, $ink.G, $ink.B))
  $path = New-RoundPath $x ([int]$thumb.Top) $w ([int]$thumb.Len) ([Math]::Max(1, [int]($w / 2)))
  try { $g.FillPath($brush, $path) } finally { $path.Dispose(); $brush.Dispose() }
}

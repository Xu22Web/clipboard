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

# One key cap and the action beside it: the chips the panel's footer draws, and the shape a
# settings row shows a recorded chord in. The caller passes the format set it also measures
# with - GenericTypographic leaves out the padding GDI+ adds around a drawn string, and a rect
# measured with the padded numbers is a rect that cuts the last character.

function Get-UiChipWidth($g, [string]$text, $font, [int]$padW, $formats) {
  if ($null -eq $g -or $null -eq $font -or $null -eq $formats) { return 0 }
  $big = New-Object Drawing.SizeF -ArgumentList @(1000, 100)
  return [int]([single]$g.MeasureString($text, $font, $big, $formats.None).Width + $padW)
}

function Draw-UiKeyChip($g, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text, $font, $pal, $ink, [int]$radius, $formats) {
  if ($null -eq $g -or $null -eq $pal -or $null -eq $formats -or $w -le 0 -or $h -le 0) { return }
  $path = New-RoundPath $x $y $w $h $radius
  $bg = New-Object Drawing.SolidBrush $pal.KeyCapBg
  try { $g.FillPath($bg, $path) } finally { $bg.Dispose() }
  $pen = New-Object Drawing.Pen $pal.KeyCapBorder, 1
  try { $g.DrawPath($pen, $path) } finally { $pen.Dispose() }
  $path.Dispose()
  $brush = New-Object Drawing.SolidBrush $ink
  $rect = New-Object Drawing.RectangleF -ArgumentList @([single]$x, [single]$y, [single]$w, [single]$h)
  try { $g.DrawString($text, $font, $brush, $rect, $formats.Center) } finally { $brush.Dispose() }
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

# A dialog button: a 4 px radius, the field colour and its hairline for the secondary ones, the
# accent with the surface colour as ink for the primary, and a wash under the pointer. A disabled
# button keeps its shape and loses its colour, because a filled button with grey text still reads
# as one that can be pressed. Drawn the way the edit card drew its Save / Cancel pair, which is
# what makes a footer button and a card button the same control.
function Draw-UiButton($g, $pal, $rect, [string]$label, [bool]$primary, [bool]$enabled, [bool]$hot) {
  if ($null -eq $g -or $null -eq $pal -or $null -eq $rect) { return }
  $x = [int]$rect.Left
  $y = [int]$rect.Top
  $w = [int]$rect.Width
  $h = [int]$rect.Height
  $radius = [int](Px 4)
  $fill = $pal['Field']
  $edge = $pal['FieldBorder']
  $ink = $pal['Text']
  if ($primary -and $enabled) { $fill = $pal['Accent']; $edge = $pal['Accent']; $ink = $pal['Surface'] }
  if (-not $enabled) { $fill = $pal['Surface']; $edge = $pal['Border']; $ink = $pal['Faint'] }
  $path = New-RoundPath $x $y $w $h $radius
  $brush = New-Object Drawing.SolidBrush $fill
  try { $g.FillPath($brush, $path) } finally { $path.Dispose(); $brush.Dispose() }
  if ($hot -and $enabled) {
    # the filled button takes a thin layer of the text colour, which lightens it on a dark theme
    # and deepens it on a light one; the outlined ones fade toward the tint a row hovers in
    $tint = Scale-Alpha $pal['HoverBg'] 1.0
    if ($primary) { $tint = Scale-Alpha $pal['Text'] 0.15 }
    if ($tint.A -gt 0) {
      $over = New-RoundPath $x $y $w $h $radius
      $ob = New-Object Drawing.SolidBrush $tint
      try { $g.FillPath($ob, $over) } finally { $over.Dispose(); $ob.Dispose() }
    }
  }
  $pen = New-Object Drawing.Pen $edge
  $stroke = New-RoundPath $x $y $w $h $radius
  try { $g.DrawPath($pen, $stroke) } finally { $stroke.Dispose(); $pen.Dispose() }
  $sf = New-PickerStringFormats
  $box = New-Object Drawing.RectangleF -ArgumentList @([single]$x, [single]$y, [single]$w, [single]$h)
  # the body face, not the small one: a dialog button is a label, not a caption
  $g.DrawString($label, $script:FBody, (Get-Brush $ink), $box, $sf.Center)
}

# A caption button: a glyph on its own that gains a hover fill, the way a title bar's buttons do.
# 'close' is the cross, 'min' the single rule; both are drawn with round caps so the stroke reads
# as a Fluent icon rather than as two hairlines.
function Draw-UiIconButton($g, $pal, $rect, [string]$glyph, [bool]$enabled, [bool]$hot) {  if ($null -eq $g -or $null -eq $pal -or $null -eq $rect) { return }
  $x = [int]$rect.Left
  $y = [int]$rect.Top
  $w = [int]$rect.Width
  $h = [int]$rect.Height
  $radius = [int][Math]::Max(2, (Px 4))
  if ($hot -and $enabled) {
    $brush = New-Object Drawing.SolidBrush $pal['HoverBg']
    $path = New-RoundPath $x $y $w $h $radius
    try { $g.FillPath($brush, $path) } finally { $path.Dispose(); $brush.Dispose() }
  }
  $ink = $pal['Dim']
  if ($hot -and $enabled) { $ink = $pal['Text'] }
  if (-not $enabled) { $ink = $pal['Faint'] }
  $pen = New-Object Drawing.Pen $ink
  $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
  try {
    $cx = $x + [int]($w / 2)
    $cy = $y + [int]($h / 2)
    $d = [int](Px 4)
    if ($glyph -ceq 'min') {
      $g.DrawLine($pen, ($cx - $d), $cy, ($cx + $d), $cy)
    } else {
      $g.DrawLine($pen, ($cx - $d), ($cy - $d), ($cx + $d), ($cy + $d))
      $g.DrawLine($pen, ($cx + $d), ($cy - $d), ($cx - $d), ($cy + $d))
    }
  } finally { $pen.Dispose() }
}

# A small cross on its own: the remove affordance of a line that can go, drawn with round caps so
# two hairlines read as one glyph. What lights it up - a disc behind it and a warning colour - is
# the caller's decision, because the same glyph marks a delete in one place and a close elsewhere.
function Draw-UiCross($g, $pal, [int]$cx, [int]$cy, [int]$d, $colour) {
  if ($null -eq $g -or $null -eq $pal) { return }
  $pen = New-Object Drawing.Pen $colour
  $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
  try {
    $g.DrawLine($pen, ($cx - $d), ($cy - $d), ($cx + $d), ($cy + $d))
    $g.DrawLine($pen, ($cx + $d), ($cy - $d), ($cx - $d), ($cy + $d))
  } finally { $pen.Dispose() }
}

# A plus in a small box, drawn the way the footer's secondary action is: the field colour, its
# hairline edge, a 4 px radius and the hover wash layered over it. A disabled plus keeps its
# shape and loses its colour, so a row with nothing to add still shows where the button would be.
function Draw-UiPlus($g, $pal, $rect, [bool]$enabled, [bool]$hot) {
  if ($null -eq $g -or $null -eq $pal -or $null -eq $rect) { return }
  $x = [int]$rect.Left
  $y = [int]$rect.Top
  $w = [int]$rect.Width
  $h = [int]$rect.Height
  $radius = [int](Px 4)
  $fill = $pal['Field']
  $edge = $pal['FieldBorder']
  $ink = $pal['Dim']
  if (-not $enabled) { $fill = $pal['Surface']; $edge = $pal['Border']; $ink = $pal['Faint'] }
  elseif ($hot) { $ink = $pal['Text'] }
  $path = New-RoundPath $x $y $w $h $radius
  $brush = New-Object Drawing.SolidBrush $fill
  try { $g.FillPath($brush, $path) } finally { $path.Dispose(); $brush.Dispose() }
  if ($hot -and $enabled) {
    # the same wash the outlined footer actions take: a thin layer of the hover tint
    $tint = Scale-Alpha $pal['HoverBg'] 1.0
    if ($tint.A -gt 0) {
      $over = New-RoundPath $x $y $w $h $radius
      $ob = New-Object Drawing.SolidBrush $tint
      try { $g.FillPath($ob, $over) } finally { $over.Dispose(); $ob.Dispose() }
    }
  }
  $pen = New-Object Drawing.Pen $edge
  $stroke = New-RoundPath $x $y $w $h $radius
  try { $g.DrawPath($pen, $stroke) } finally { $stroke.Dispose(); $pen.Dispose() }
  $cx = $x + [int]($w / 2)
  $cy = $y + [int]($h / 2)
  $d = [int](Px 3)
  $ipen = New-Object Drawing.Pen $ink
  $ipen.StartCap = [Drawing.Drawing2D.LineCap]::Round
  $ipen.EndCap = [Drawing.Drawing2D.LineCap]::Round
  try {
    $g.DrawLine($ipen, ($cx - $d), $cy, ($cx + $d), $cy)
    $g.DrawLine($ipen, $cx, ($cy - $d), $cx, ($cy + $d))
  } finally { $ipen.Dispose() }
}

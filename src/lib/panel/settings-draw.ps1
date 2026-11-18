# lib/panel/settings-draw.ps1 - the settings window's drawing.
#
# Every function here takes a Graphics plus plain values: no window, no list, no state. The
# pieces are the same ones the history panel uses (Draw-PanelFrame for the silhouette, the
# shared StringFormats, the brush cache, the theme palette), so the settings window cannot end
# up on a different radius, a different face or a colour the theme never declared.
#
# Fluent, Win11: a 8 px window radius, a flat surface with a 1 px separator between the two
# columns, rows that carry the label on the first line and their value or help on the second,
# and a switch drawn as a pill with a round knob rather than a check box.

# The window's own measurements, at the 96 dpi design size. Kept in one function because the
# window and the hit tests have to agree: a click that lands on the switch has to be the same
# rectangle the switch was drawn in.
function Get-SettingsLayout([int]$w, [int]$h) {
  $pad = Px 14
  $sideW = Px 196
  $headH = Px 62
  $footH = Px 44
  return @{
    Width     = $w
    Height    = $h
    Pad       = $pad
    SideWidth = $sideW
    HeadHeight = $headH
    FootHeight = $footH
    RowHeight = Px 58
    GroupHeight = Px 34
    ListLeft  = $sideW + $pad
    # the lane on the right belongs to the scrollbar: a Fluent list never draws its rows to the
    # very edge and then has nowhere to put the thumb
    ListRight = $w - $pad - (Px 8)
    ListTop   = $headH
    ListBottom = $h - $footH
    ToggleWidth = Px 40
    ToggleHeight = Px 20
    Radius    = Px 4
  }
}

# rows that fit the list area, never less than one
function Get-SettingsVisibleRows($layout) {
  $room = [int]$layout.ListBottom - [int]$layout.ListTop
  $n = [int][Math]::Floor($room / [int]$layout.RowHeight)
  if ($n -lt 1) { return 1 }
  return $n
}

# The 1 px edge of the settings windows. Draw-PanelFrame lifts a faint separator until it reads
# on a dark surface, which is right for the panel - it floats over other windows with no shadow -
# but wrong here: a settings window sits beside real Fluent windows, whose edge is the theme's own
# 8% separator, composited over the surface and nothing more. Same ring, no lift.
function Draw-SettingsFrame($g, [int]$w, [int]$h, $color, [int]$radius) {
  if ($null -eq $g -or $w -lt 6 -or $h -lt 6) { return }
  $t = [Math]::Max(1, (Px 1))
  if (($radius * 2) -gt ($w - 3) -or ($radius * 2) -gt ($h - 3)) { $radius = [int]([Math]::Min($w - 3, $h - 3) / 2) }
  $ring = New-Object Drawing.Drawing2D.GraphicsPath
  $brush = New-Object Drawing.SolidBrush $color
  $was = $g.SmoothingMode
  $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::None
  $outer = $null
  $inner = $null
  try {
    $ring.FillMode = [Drawing.Drawing2D.FillMode]::Alternate
    $outer = New-RoundPath 0 0 $w $h $radius
    $inner = New-RoundPath $t $t ($w - (2 * $t)) ($h - (2 * $t)) ([Math]::Max(1, $radius - $t))
    $ring.AddPath($outer, $true)
    $ring.AddPath($inner, $true)
    $g.FillPath($brush, $ring)
  } finally {
    $g.SmoothingMode = $was
    if ($null -ne $outer) { $outer.Dispose() }
    if ($null -ne $inner) { $inner.Dispose() }
    $ring.Dispose()
    $brush.Dispose()
  }
}

# The window: surface, frame, and the separator between the two columns. The header carries the
# title and where the user is; the footer is drawn on top of the same surface with a separator
# above it, the way the panel's own footer sits.
function Draw-SettingsChrome($g, $pal, $layout, [string]$title, [string]$subtitle) {
  if ($null -eq $g -or $null -eq $pal) { return }
  $w = [int]$layout.Width
  $h = [int]$layout.Height
  $bg = New-Object Drawing.SolidBrush $pal['Surface']
  try { $g.FillRectangle($bg, 0, 0, $w, $h) } finally { $bg.Dispose() }
  Draw-SettingsFrame $g $w $h $pal['Border'] (Get-WindowRadius)
  $sf = New-PickerStringFormats
  $pad = [int]$layout.Pad
  $titleBox = New-Object Drawing.RectangleF -ArgumentList @([single]$pad, [single](Px 12), [single]($w - (2 * $pad)), [single](Px 26))
  $g.DrawString($title, $script:FTitle, (Get-Brush $pal['Text']), $titleBox, $sf.None)
  if ($subtitle) {
    $subBox = New-Object Drawing.RectangleF -ArgumentList @([single]$pad, [single](Px 36), [single]($w - (2 * $pad)), [single](Px 18))
    $g.DrawString($subtitle, $script:FSmall, (Get-Brush $pal['Faint']), $subBox, $sf.Ellipsis)
  }
  # one hairline between the columns and one above the footer: Fluent separates by a line, not
  # by a shadow
  $pen = New-Object Drawing.Pen $pal['Border']
  try {
    $g.DrawLine($pen, [int]$layout.SideWidth, [int]$layout.HeadHeight, [int]$layout.SideWidth, [int]$layout.ListBottom)
    $g.DrawLine($pen, 0, [int]$layout.ListBottom, $w, [int]$layout.ListBottom)
  } finally { $pen.Dispose() }
}

# A colour part way between two others, for a transition that moves rather than switches.
# Alpha is interpolated too, so a border can fade out while the fill it sits on changes.
function Get-SettingsBlend($from, $to, [double]$k) {
  if ($k -le 0) { return $from }
  if ($k -ge 1) { return $to }
  return [Drawing.Color]::FromArgb(
    [int][Math]::Round([double]$from.A + ([double]$to.A - [double]$from.A) * $k),
    [int][Math]::Round([double]$from.R + ([double]$to.R - [double]$from.R) * $k),
    [int][Math]::Round([double]$from.G + ([double]$to.G - [double]$from.G) * $k),
    [int][Math]::Round([double]$from.B + ([double]$to.B - [double]$from.B) * $k))
}

# The left column: one line per group. The selected one is tinted and carries a 3 px accent
# bar, and the bar is inset by the corner radius so it never cuts a rounded corner off - the
# two shapes are drawn on the same path instead of one square bar over a round edge.
function Draw-SettingsSide($g, $pal, $layout, $groups, [int]$selected) {
  if ($null -eq $g -or $null -eq $pal -or $null -eq $groups) { return }
  $sf = New-PickerStringFormats
  $x = [int]$layout.Pad
  $w = [int]$layout.SideWidth - (2 * [int]$layout.Pad)
  $rowH = [int]$layout.GroupHeight
  $y = [int]$layout.HeadHeight
  $radius = [int]$layout.Radius
  $barW = Px $script:Metric['SelBarWidth']
  for ($i = 0; $i -lt @($groups).Count; $i++) {
    $top = $y + ($i * $rowH)
    if ($top + $rowH -gt [int]$layout.ListBottom) { break }
    $isSel = ($i -eq $selected)
    if ($isSel) {
      $brush = New-Object Drawing.SolidBrush $pal['SelBg']
      $path = New-RoundPath $x $top $w $rowH ([int]$radius)
      try { $g.FillPath($brush, $path) } finally { $path.Dispose(); $brush.Dispose() }
      $barBrush = New-Object Drawing.SolidBrush $pal['Accent']
      $bar = New-RoundPath ($x + (Px 3)) ($top + (Px 8)) $barW ($rowH - (2 * (Px 8))) ([Math]::Max(1, [int]($barW / 2)))
      try { $g.FillPath($barBrush, $bar) } finally { $bar.Dispose(); $barBrush.Dispose() }
    }
    $ink = $pal['Dim']
    if ($isSel) { $ink = $pal['Text'] }
    $box = New-Object Drawing.RectangleF -ArgumentList @(
      [single]($x + (Px 14)), [single]$top, [single]($w - (Px 20)), [single]$rowH)
    $g.DrawString([string]$groups[$i], $script:FBody, (Get-Brush $ink), $box, $sf.Ellipsis)
  }
}

# A Win11 switch: a pill track and a round knob. $k is how far the switch has travelled, so a
# flip can be drawn on its way instead of landing in one frame; 0 and 1 are the two resting
# states. On: the accent track, the surface colour as the knob (bright track, dark knob in the
# dark theme and the other way round in the light one, because both tokens invert together).
function Draw-SettingsToggle($g, $pal, [int]$x, [int]$y, [int]$w, [int]$h, [double]$k, [bool]$enabled = $true) {
  if ($null -eq $g -or $null -eq $pal) { return }
  $track = Get-SettingsBlend $pal['Field'] $pal['Accent'] $k
  $knob = Get-SettingsBlend $pal['Text'] $pal['Surface'] $k
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
  $d = $h - (Px 4)
  $from = $x + (Px 2)
  $to = $x + $w - $d - (Px 2)
  $kx = [int][Math]::Round($from + (($to - $from) * $k))
  $kb = New-Object Drawing.SolidBrush $knob
  try { $g.FillEllipse($kb, $kx, ($y + (Px 2)), $d, $d) } finally { $kb.Dispose() }
}

# One switch, calculated once: the paint, the hit test and the click all ask here, so a click
# always lands on the rectangle that was drawn.
function Get-SettingsToggleRect($layout, [int]$rowTop) {
  $w = [int]$layout.ToggleWidth
  $h = [int]$layout.ToggleHeight
  $rowH = [int]$layout.RowHeight - (Px 4)
  return @{
    Left   = [int]$layout.ListRight - (Px 12) - $w
    Top    = $rowTop + [int](($rowH - $h) / 2)
    Width  = $w
    Height = $h
  }
}

# One setting: the label and its help on the left, the control on the right, centred on the row.
# That is the Fluent settings card - a name over a description, one control per card, and the
# control holds the vertical middle of the card rather than the first line.
#
# This column is not a list: nothing marks a row as current, because every row is its own control
# and a filled or outlined row reads as "these are selected items". Hovering is the only fill. A
# row that cannot take effect is greyed and says which setting owns it.
function Draw-SettingsRow($g, $pal, $layout, $row, [int]$x, [int]$y, [int]$w, [bool]$hover, [double]$toggleK) {
  if ($null -eq $g -or $null -eq $row) { return }
  $enabled = $true
  if ($row.ContainsKey('Enabled')) { $enabled = [bool]$row.Enabled }
  $h = [int]$layout.RowHeight - (Px 4)
  $radius = [int]$layout.Radius
  if ($hover -and $enabled) {
    $brush = New-Object Drawing.SolidBrush $pal['HoverBg']
    $path = New-RoundPath $x $y $w $h $radius
    try { $g.FillPath($brush, $path) } finally { $path.Dispose(); $brush.Dispose() }
  }
  $sf = New-PickerStringFormats
  $valueRight = $w - (Px 12)
  # the control column: wide enough for a byte budget, and the text stops before it so a long
  # description never runs under the value
  $controlW = Px 170
  $textW = $valueRight - $controlW - (Px 12)
  if ($textW -lt (Px 120)) { $textW = [int](Px 120) }
  $labelInk = $pal['Text']
  $helpText = [string]$row.Help
  if (-not $enabled) {
    $labelInk = $pal['Faint']
    if ($row.ContainsKey('Why') -and $row.Why) { $helpText = 'Off because ' + [string]$row.Why }
  }
  $labelBox = New-Object Drawing.RectangleF -ArgumentList @(
    [single]($x + (Px 12)), [single]($y + (Px 7)), [single]$textW, [single](Px 22))
  $g.DrawString([string]$row.Label, $script:FBody, (Get-Brush $labelInk), $labelBox, $sf.Ellipsis)
  if ($helpText) {
    $helpBox = New-Object Drawing.RectangleF -ArgumentList @(
      [single]($x + (Px 12)), [single]($y + (Px 28)), [single]$textW, [single](Px 18))
    $g.DrawString($helpText, $script:FSmall, (Get-Brush $pal['Faint']), $helpBox, $sf.Ellipsis)
  }
  if ($row.Kind -eq 'bool') {
    $t = Get-SettingsToggleRect $layout $y
    Draw-SettingsToggle $g $pal ([int]$t.Left) ([int]$t.Top) ([int]$t.Width) ([int]$t.Height) $toggleK $enabled
    return
  }
  # the value holds the vertical middle of the whole row, the same line the switch sits on
  $choices = @()
  if ($row.ContainsKey('Choices') -and $null -ne $row.Choices) { $choices = @($row.Choices) }
  $dropW = 0
  if ($choices.Count -gt 0 -and $enabled) { $dropW = Px 16 }
  $valueBox = New-Object Drawing.RectangleF -ArgumentList @(
    [single]($x + $valueRight - $controlW), [single]($y + (Px 4)), [single]($controlW - $dropW), [single]($h - (Px 8)))
  $ink = $pal['Dim']
  if (-not $enabled) { $ink = $pal['Faint'] }
  $g.DrawString([string]$row.Text, $script:FBody, (Get-Brush $ink), $valueBox, $sf.Right)
  if ($dropW -gt 0) {
    # a chevron, the same affordance a Fluent combo box carries
    $cx = $x + $valueRight - (Px 7)
    $cy = $y + [int]($h / 2)
    $pen = New-Object Drawing.Pen $pal['Dim'], (Px 1)
    try {
      $g.DrawLine($pen, ($cx - (Px 3)), ($cy - (Px 2)), $cx, ($cy + (Px 2)))
      $g.DrawLine($pen, $cx, ($cy + (Px 2)), ($cx + (Px 3)), ($cy - (Px 2)))
    } finally { $pen.Dispose() }
  }
}

# The footer: what the keys do, or the reason the last edit was refused. An error is drawn in
# Warn, which is the token the panel already uses for something the user has to read.
function Draw-SettingsFooter($g, $pal, $layout, [string]$text, [bool]$isError) {
  if ($null -eq $g -or -not $text) { return }
  $sf = New-PickerStringFormats
  $ink = $pal['Faint']
  if ($isError) { $ink = $pal['Warn'] }
  $box = New-Object Drawing.RectangleF -ArgumentList @(
    [single]([int]$layout.Pad), [single]([int]$layout.ListBottom),
    [single]([int]$layout.Width - (2 * [int]$layout.Pad)), [single]([int]$layout.FootHeight))
  $g.DrawString($text, $script:FSmall, (Get-Brush $ink), $box, $sf.Ellipsis)
}

# The scrollbar, when the group is longer than the list area. A Fluent list carries a thin
# rounded thumb instead of a system bar: the track is barely there and the thumb is the only
# thing with any weight, so the list still reads as one surface.
function Draw-SettingsScrollbar($g, $pal, $layout, [int]$rows, [int]$visible, [int]$scroll) {
  if ($null -eq $g -or $visible -le 0 -or $rows -le $visible) { return }
  $trackW = Px 3
  $x = [int]$layout.ListRight + (Px 3)
  $top = [int]$layout.ListTop
  $h = [int]$layout.ListBottom - $top
  if ($h -lt (Px 20)) { return }
  $trackBrush = New-Object Drawing.SolidBrush $pal['HoverBg']
  $track = New-RoundPath $x $top $trackW $h ([int]($trackW / 2))
  try { $g.FillPath($trackBrush, $track) } finally { $track.Dispose(); $trackBrush.Dispose() }
  $thumbH = [int][Math]::Max((Px 24), [int]($h * ($visible / [double]$rows)))
  if ($thumbH -gt $h) { $thumbH = $h }
  $span = [Math]::Max(1, $rows - $visible)
  $offset = [int][Math]::Round(($h - $thumbH) * ($scroll / [double]$span))
  if ($offset -lt 0) { $offset = 0 }
  if ($offset -gt ($h - $thumbH)) { $offset = $h - $thumbH }
  $thumbBrush = New-Object Drawing.SolidBrush $pal['Faint']
  $thumb = New-RoundPath $x ($top + $offset) $trackW $thumbH ([int]($trackW / 2))
  try { $g.FillPath($thumbBrush, $thumb) } finally { $thumb.Dispose(); $thumbBrush.Dispose() }
}

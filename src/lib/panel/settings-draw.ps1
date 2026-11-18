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
  # a status line, not a row of key chips: this window answers no shortcut, so the footer only
  # has a message to show and the count to keep in the corner
  $footH = Px 30
  return @{
    Width     = $w
    Height    = $h
    Pad       = $pad
    SideWidth = $sideW
    HeadHeight = $headH
    FootHeight = $footH
    RowHeight = Px 58
    GroupHeight = Px 34
    CloseSize = Px 32
    ListLeft  = $sideW + $pad
    # the lane on the right belongs to the scrollbar: a Fluent list never draws its rows to the
    # very edge and then has nowhere to put the thumb
    ListRight = $w - $pad - (Px 8)
    # the lane the pointer can grab. The thumb is three pixels wide, a mouse is not, so the hit
    # area is twelve and the thumb stays centred in it - the same arrangement the panel uses.
    SbLeft    = $w - $pad - (Px 8)
    SbLane    = Px 12
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

# The settings windows draw their edge with Draw-PanelFrame, the same call the history panel
# makes: one silhouette, one weight, one lift for every custom-drawn window in the tool. The
# lifted alpha is what makes an edge read at all on a dark surface, and a settings window sits
# beside the panel often enough that two different edge weights would show.

# The window: surface, frame, and the separator between the two columns. The header carries the
# title and where the user is; the footer is the same surface with no line above it, because the
# panel's footer has none either - the chips and their baseline are what mark it off.
function Draw-SettingsChrome($g, $pal, $layout, [string]$title, [string]$subtitle) {
  if ($null -eq $g -or $null -eq $pal) { return }
  $w = [int]$layout.Width
  $h = [int]$layout.Height
  $bg = New-Object Drawing.SolidBrush $pal['Surface']
  try { $g.FillRectangle($bg, 0, 0, $w, $h) } finally { $bg.Dispose() }
  Draw-PanelFrame $g $w $h $pal['Border'] (Get-WindowRadius) $pal['Surface']
  $sf = New-PickerStringFormats
  $pad = [int]$layout.Pad
  $titleBox = New-Object Drawing.RectangleF -ArgumentList @([single]$pad, [single](Px 12), [single]($w - (2 * $pad)), [single](Px 26))
  $g.DrawString($title, $script:FTitle, (Get-Brush $pal['Text']), $titleBox, $sf.None)
  if ($subtitle) {
    $subBox = New-Object Drawing.RectangleF -ArgumentList @([single]$pad, [single](Px 36), [single]($w - (2 * $pad)), [single](Px 18))
    $g.DrawString($subtitle, $script:FSmall, (Get-Brush $pal['Faint']), $subBox, $sf.Ellipsis)
  }
  # one hairline between the columns: Fluent separates the navigation pane by a line, and the
  # line stops at the footer so the two never meet in a corner
  $pen = New-Object Drawing.Pen $pal['Border']
  try {
    $g.DrawLine($pen, [int]$layout.SideWidth, [int]$layout.HeadHeight, [int]$layout.SideWidth, [int]$layout.ListBottom)
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
function Draw-SettingsRow($g, $pal, $layout, $row, [int]$x, [int]$y, [int]$w, [bool]$hover, [double]$toggleK, [bool]$armed = $false, $preview = @()) {
  if ($null -eq $g -or $null -eq $row) { return }
  $enabled = $true
  if ($row.ContainsKey('Enabled')) { $enabled = [bool]$row.Enabled }
  $locked = $false
  if ($row.ContainsKey('Locked')) { $locked = [bool]$row.Locked }
  $h = [int]$layout.RowHeight - (Px 4)
  $radius = [int]$layout.Radius
  # a read-only row never lights up: it is not a control, and a hover fill would promise one
  if ($hover -and $enabled -and (-not $locked)) {
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
  # A shortcut is a chord, not a string: its keys are drawn as the panel's key caps, right
  # aligned so the chord ends where the value text did. While the row is being recorded the caps
  # show what is held so far, followed by a dim placeholder.
  $chords = @()
  if ($row.ContainsKey('Chords') -and $null -ne $row.Chords) { $chords = @($row.Chords) }
  if ($armed -or $chords.Count -gt 0) {
    $cy = $y + [int]($h / 2)
    $xr = $x + $valueRight - $dropW
    if ($armed) {
      # the row is waiting for a chord: what is held so far, then one accent cap for the key
      $keys = @($preview)
      $keys += [string][char]0x2026
      [void](Draw-SettingChord $g $pal $xr $cy $keys $enabled $true)
      return
    }
    # A chain of chords is longer than the value column, so the first chord is drawn and the
    # count of the rest follows it as plain text: a second row of caps would be a lie about how
    # many keys the chain holds.
    if ($chords.Count -gt 1) {
      $more = '+' + [string]($chords.Count - 1)
      $mw = [int][Math]::Ceiling($g.MeasureString($more, $script:FSmall, 1000, $sf.None).Width) + (Px 2)
      $box = New-Object Drawing.RectangleF -ArgumentList @(
        [single]($xr - $mw), [single]($cy - (Px 9)), [single]$mw, [single](Px 18))
      $g.DrawString($more, $script:FSmall, (Get-Brush $pal['Faint']), $box, $sf.Center)
      $xr = $xr - $mw - (Px 6)
    }
    [void](Draw-SettingChord $g $pal $xr $cy (Get-SettingChordKeys ([string]$chords[0])) $enabled)
    return
  }
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

# The keys of one chord as the caps the footer and the panel's hints draw: filled, stroked and
# rounded, so a shortcut reads key by key. Returns the width it took, which is what lets a chain
# of them be laid out from the right edge.
function Draw-SettingChord($g, $pal, [int]$right, [int]$cy, $keys, [bool]$enabled, [bool]$accentLast = $false) {
  if ($null -eq $g -or $null -eq $pal) { return 0 }
  $list = @($keys)
  if ($list.Count -eq 0) { return 0 }
  $font = $script:FSmall
  if (-not $font) { return 0 }
  $fmt = New-PickerStringFormats
  $chipH = Px $script:Metric['ChipHeight']
  $gap = Px 4
  $padX = Px 10
  $big = New-Object Drawing.SizeF -ArgumentList @(1000, 100)
  $widths = @()
  $total = 0
  foreach ($k in $list) {
    $w = [int]([Math]::Ceiling($g.MeasureString([string]$k, $font, $big, $fmt.None).Width) + $padX)
    $widths += $w
    $total += $w + $gap
  }
  if ($total -gt 0) { $total -= $gap }
  $x = $right - $total
  $top = $cy - [int]($chipH / 2)
  $radius = Px $script:Metric['CapRadius']
  $ink = $pal['Text']
  if (-not $enabled) { $ink = $pal['Faint'] }
  for ($i = 0; $i -lt $list.Count; $i++) {
    $w = [int]$widths[$i]
    $capInk = $ink
    $capEdge = $pal['KeyCapBorder']
    if ($accentLast -and ($i -eq ($list.Count - 1))) {
      # the one cap still waiting for its key
      $capInk = $pal['Accent']
      $capEdge = $pal['Accent']
    }
    $path = New-RoundPath $x $top $w $chipH $radius
    $fill = New-Object Drawing.SolidBrush $pal['KeyCapBg']
    $edge = New-Object Drawing.Pen $capEdge, 1
    try { $g.FillPath($fill, $path); $g.DrawPath($edge, $path) } finally { $path.Dispose(); $fill.Dispose(); $edge.Dispose() }
    $box = New-Object Drawing.RectangleF -ArgumentList @([single]$x, [single]$top, [single]$w, [single]$chipH)
    $g.DrawString([string]$list[$i], $font, (Get-Brush $capInk), $box, $fmt.Center)
    $x += $w + $gap
  }
  return $total
}

# The tick of a multi-select list: a rounded square, filled with the accent and carrying a tick
# in the surface colour when the name is on, and an empty outline when it is not. Drawn rather
# than taken from a font, because the icon font is optional and a missing glyph would leave a
# box where the state should be.
function Draw-SettingsTick($g, $pal, [int]$x, [int]$y, [int]$size, [bool]$on) {
  if ($null -eq $g -or $null -eq $pal -or $size -lt 6) { return }
  $r = [Math]::Max(1, [int](Px 3))
  if (-not $on) {
    $pen = New-Object Drawing.Pen $pal['FieldBorder']
    $path = New-RoundPath $x $y $size $size $r
    try { $g.DrawPath($pen, $path) } finally { $path.Dispose(); $pen.Dispose() }
    return
  }
  $brush = New-Object Drawing.SolidBrush $pal['Accent']
  $path = New-RoundPath $x $y $size $size $r
  try { $g.FillPath($brush, $path) } finally { $path.Dispose(); $brush.Dispose() }
  $pen = New-Object Drawing.Pen $pal['Surface'], ([Math]::Max(1, (Px 2)))
  $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
  try {
    $ax = $x + [int]($size * 0.26)
    $bx = $x + [int]($size * 0.44)
    $cx = $x + [int]($size * 0.76)
    $ay = $y + [int]($size * 0.52)
    $by = $y + [int]($size * 0.72)
    $cy = $y + [int]($size * 0.30)
    $g.DrawLine($pen, $ax, $ay, $bx, $by)
    $g.DrawLine($pen, $bx, $by, $cx, $cy)
  } finally { $pen.Dispose() }
}

# The footer is a status line: what the last write did, and the count with the version in the
# corner. There is no key to describe here - the window is driven by the pointer - and a message
# is drawn in Warn when it is a refusal, which is the token the panel uses for the same thing.
function Draw-SettingsFooter($g, $pal, $layout, [string]$rightText, [string]$msg, [bool]$isError) {
  if ($null -eq $g -or $null -eq $pal) { return }
  $sf = New-PickerStringFormats
  $left = [int]$layout.Pad
  $top = [int]$layout.ListBottom
  $limit = [int]$layout.Width - [int]$layout.Pad
  if ($rightText) {
    $rightW = Px 128
    $box = New-Object Drawing.RectangleF -ArgumentList @(
      [single]($limit - $rightW), [single]$top, [single]$rightW, [single]([int]$layout.FootHeight))
    $g.DrawString($rightText, $script:FSmall, (Get-Brush $pal['Faint']), $box, $sf.Right)
    $limit = $limit - $rightW - (Px 8)
  }
  if (-not $msg) { return }
  $ink = $pal['Dim']
  if ($isError) { $ink = $pal['Warn'] }
  $box = New-Object Drawing.RectangleF -ArgumentList @(
    [single]$left, [single]$top, [single]($limit - $left), [single]([int]$layout.FootHeight))
  $g.DrawString($msg, $script:FSmall, (Get-Brush $ink), $box, $sf.Ellipsis)
}

# Where the close button sits, as one rectangle for the paint and the hit test. A window with no
# title bar and no chrome has to put its way out somewhere, and the top right corner is where
# every Windows app puts it.
function Get-SettingsCloseRect($layout) {
  $size = [int]$layout.CloseSize
  return @{
    Left = ([int]$layout.Width - (Px 8) - $size)
    Top = (Px 8)
    Width = $size
    Height = $size
  }
}

# A caption button: a faint cross that gains a hover fill, the way the panel's own buttons do.
function Draw-SettingsClose($g, $pal, $layout, [bool]$hot) {
  if ($null -eq $g -or $null -eq $pal) { return }
  $r = Get-SettingsCloseRect $layout
  $radius = [int][Math]::Max(2, (Px 4))
  if ($hot) {
    $brush = New-Object Drawing.SolidBrush $pal['HoverBg']
    $path = New-RoundPath ([int]$r.Left) ([int]$r.Top) ([int]$r.Width) ([int]$r.Height) $radius
    try { $g.FillPath($brush, $path) } finally { $path.Dispose(); $brush.Dispose() }
  }
  $ink = $pal['Dim']
  if ($hot) { $ink = $pal['Text'] }
  $pen = New-Object Drawing.Pen $ink
  $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
  try {
    $cx = [int]$r.Left + [int]($r.Width / 2)
    $cy = [int]$r.Top + [int]($r.Height / 2)
    $d = [int](Px 4)
    $g.DrawLine($pen, ($cx - $d), ($cy - $d), ($cx + $d), ($cy + $d))
    $g.DrawLine($pen, ($cx + $d), ($cy - $d), ($cx - $d), ($cy + $d))
  } finally { $pen.Dispose() }
}

# Where the thumb sits, as one calculation shared by the paint, the hit test and the drag: a
# pointer that grabs the middle of the thumb must keep grabbing the middle of it.
function Get-SettingsScrollThumb($layout, [int]$rows, [int]$visible, [int]$scroll) {
  if ($null -eq $layout -or $visible -le 0 -or $rows -le $visible) { return $null }
  $top = [int]$layout.ListTop
  $track = [int]$layout.ListBottom - $top
  if ($track -lt (Px 24)) { return $null }
  $len = [int][Math]::Max((Px 24), [int]($track * ($visible / [double]$rows)))
  if ($len -gt $track) { $len = $track }
  $span = [Math]::Max(1, $rows - $visible)
  $room = $track - $len
  $off = [int][Math]::Round($room * ($scroll / [double]$span))
  if ($off -lt 0) { $off = 0 }
  if ($off -gt $room) { $off = $room }
  return @{ Top = ($top + $off); Len = $len; TrackTop = $top; TrackLen = $track; Span = $span }
}

# the lane a pointer may grab, which is wider than the three pixels the thumb occupies
function Get-SettingsScrollLane($layout) {
  return @{
    Left = [int]$layout.SbLeft; Width = [int]$layout.SbLane
    Top = [int]$layout.ListTop; Height = ([int]$layout.ListBottom - [int]$layout.ListTop)
  }
}

# The thumb, the way the panel draws its own: no visible track, a rounded thumb that widens and
# darkens as the pointer comes near. $k is the hover ramp, 0 at rest and 1 under the pointer, so
# the two windows move at the same speed.
function Draw-SettingsScrollbar($g, $pal, $layout, $thumb, [double]$k) {
  if ($null -eq $g -or $null -eq $pal -or $null -eq $thumb) { return }
  if ($k -lt 0) { $k = 0 }
  if ($k -gt 1) { $k = 1 }
  $w = [int][Math]::Round((Px 3) + ($k * ((Px 5) - (Px 3))))
  $alpha = [int][Math]::Round(110 + ($k * 80))
  $x = [int]$layout.SbLeft + [int](([int]$layout.SbLane - $w) / 2)
  $ink = $pal['Dim']
  $brush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb($alpha, $ink.R, $ink.G, $ink.B))
  $path = New-RoundPath $x ([int]$thumb.Top) $w ([int]$thumb.Len) ([Math]::Max(1, [int]($w / 2)))
  try { $g.FillPath($brush, $path) } finally { $path.Dispose(); $brush.Dispose() }
}

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
  # The footer carries the message on the left and the three actions on the right. Its height is
  # the button plus the same air above and below it: 32 + 12 + 12, the command bar a Fluent dialog
  # uses, so the buttons are not a strip squeezed against the window edge.
  $footH = Px 56
  # The window is cut into boxes the way CSS cuts one: a header off the top, a footer off the
  # bottom, the body between them; inside the body the page list takes the left column and the
  # rows the rest, with the thumb's lane taken off the right edge. Every number this function
  # has always answered is read back out of those boxes, so a change of window size or padding
  # moves them together instead of in five places at once.
  $win = New-UiBox 0 0 $w $h
  $bands = @(Get-UiStack $win @($headH, -1, $footH))
  $head = $bands[0]
  $body = $bands[1]
  $foot = $bands[2]
  $cols = @(Get-UiColumns (New-UiBox 0 ([int]$body.Top) $w ([int]$body.Height)) @($sideW, -1))
  $side = $cols[0]
  # the lane on the right belongs to the scrollbar: a Fluent list never draws its rows to the
  # very edge and then has nowhere to put the thumb
  $list = Get-UiInset $cols[1] $pad 0 ($pad + (Px 8)) 0
  $lane = New-UiBox ([int]$list.Right) ([int]$list.Top) (Px 12) ([int]$list.Height)
  return @{
    Width     = $w
    Height    = $h
    Pad       = $pad
    SideWidth = $sideW
    HeadHeight = $headH
    FootHeight = $footH
    # a footer button: the height Windows gives a dialog button, so the target is the same size
    # here as in the edit card and in every other dialog on the system
    ActionHeight = Px 32
    ActionGap = Px 8
    ActionPad = Px 14
    ActionMin = Px 88
    # an 18 px cap is a line of its own plus the air under it: three chord lines have to fit a
    # card with a gap between them, or the chain reads as one block of caps
    RowHeight = Px 80
    GroupHeight = Px 34
    CloseSize = Px 32
    ListLeft  = [int]$list.Left
    ListRight = [int]$list.Right
    # the lane the pointer can grab. The thumb is three pixels wide, a mouse is not, so the hit
    # area is twelve and the thumb stays centred in it - the same arrangement the panel uses.
    SbLeft    = [int]$list.Right
    SbLane    = (Px 12)
    ListTop   = [int]$list.Top
    ListBottom = [int]$list.Bottom
    ToggleWidth = Px 40
    ToggleHeight = Px 20
    Radius    = Px 4
    # the boxes the numbers come from, for anything that wants to place a child in one
    Head      = $head
    Body      = $body
    Foot      = $foot
    Side      = $side
    List      = $list
    SbBox     = $lane
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

# A colour part way between two others lives in lib\ui\widgets.ps1 (Get-UiBlend), with the
# switches and scrollbars it paints; the settings window keeps no copy of it.

# The glyph a page's row carries, from the same icon face the panel and the tray use (Segoe
# Fluent Icons, MDL2 on Win10). The mapping is by the schema's group name - the identity the
# language file uses too - and a group nobody mapped still gets a glyph, because a row without
# one would sit out of line with the rest.
function Get-SettingsGroupGlyph([string]$name) {
  $map = @{
    Clipboard  = 0xE8C8
    Paste      = 0xE77F
    Hotkey     = 0xE765
    History    = 0xE81C
    Panel      = 0xE71D
    Compact    = 0xE73F
    Appearance = 0xE790
    Startup    = 0xE7E8
    Plugins    = 0xE8F1
    Storage    = 0xE8B7
    Other      = 0xE712
    About      = 0xE946
  }
  if ($name -and $map.ContainsKey($name)) { return [string][char]$map[$name] }
  return [string][char]0xE712
}

# The left column: one line per group. The selected one is tinted and carries a 3 px accent
# bar, and the bar is inset by the corner radius so it never cuts a rounded corner off - the
# two shapes are drawn on the same path instead of one square bar over a round edge. A page with
# a staged value carries the same dot a staged row does, at the end of its line, so a change
# made on another page is visible from here.
function Draw-SettingsSide($g, $pal, $layout, $groups, [int]$selected, $pendingGroups = @()) {
  if ($null -eq $g -or $null -eq $pal -or $null -eq $groups) { return }
  $sf = New-PickerStringFormats
  $x = [int]$layout.Pad
  $w = [int]$layout.SideWidth - (2 * [int]$layout.Pad)
  $rowH = [int]$layout.GroupHeight
  $y = [int]$layout.HeadHeight
  $radius = [int]$layout.Radius
  $barW = Px $script:Metric['SelBarWidth']
  # the icon column borrows the panel row's own numbers: the same 10 px from the item edge, the
  # same 20 px slot, and the word starting where the panel starts it (38) - an icon and a word
  # spaced differently here than in the history list would read as two different controls
  $iconX = Px $script:Metric['IconX']
  $iconBox = Px $script:Metric['IconSlot']
  $textGap = Px $script:Metric['TextGap']
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
    # The glyph sits in its own square on the row's line and takes the word's ink: the accent bar
    # already says which page is current, and a second accent here (the icon) would read as two
    # markers for one state. Draw-UiGlyph carries the measured drop that puts an icon on the
    # optical centre of the words next to it, so the two line up at every DPI.
    $gx = [int]($x + $iconX)
    # The box is the text's own rectangle - same top, same height, same string format - and the
    # glyph is moved by IconDrop, the one number measured from the two fonts actually in use.
    # That is what makes the pair line up in any language: a per-font nudge here would be a
    # measurement of whichever face it was tuned on (the Latin one), and a CJK face has a taller
    # line box, so the same nudge lands wrong there.
    $gy = [int]$top
    $gb = New-Object Drawing.RectangleF -ArgumentList @([single]$gx, [single]$gy, [single]$iconBox, [single]$rowH)
    Draw-UiGlyph $g (Get-SettingsGroupGlyph ([string]$groups[$i])) $script:FIcon (Get-Brush $ink) $gb $sf.Center
    $textLeft = [int]($x + $textGap)
    $box = New-Object Drawing.RectangleF -ArgumentList @(
      [single]$textLeft, [single]$top, [single]($x + $w - (Px 20) - $textLeft), [single]$rowH)
    $groupKey = 'settings.group.' + [string]$groups[$i]
    $groupName = [string]$groups[$i]
    $groupWord = Get-UiTextOr $groupKey $groupName
    $g.DrawString($groupWord, $script:FBody, (Get-Brush $ink), $box, $sf.Ellipsis)
    if (@($pendingGroups) -contains [string]$groups[$i]) {
      $dot = [Math]::Max(4, (Px 5))
      $db = New-Object Drawing.SolidBrush $pal['Accent']
      try {
        $g.FillEllipse($db, ($x + $w - (Px 12)), ($top + [int](($rowH - $dot) / 2)), $dot, $dot)
      } finally { $db.Dispose() }
    }
  }
}

# A Win11 switch: a pill track and a round knob. $k is how far the switch has travelled, so a
# The switch itself is a shared widget (lib\ui\widgets.ps1, Draw-UiToggle), so the panel, the
# tray or a later surface can carry the same control; what stays here is where it is put.
function Draw-SettingsToggle($g, $pal, [int]$x, [int]$y, [int]$w, [int]$h, [double]$k, [bool]$enabled = $true) {
  Draw-UiToggle $g $pal $x $y $w $h $k $enabled
}

# Where a control sits vertically: on the label's line, not in the middle of the card. With two
# lines of help under the label, a control centred on the whole card floats between them and
# reads as belonging to nothing; beside the name it belongs to the name.
function Get-SettingsControlTop($layout, [int]$rowTop, [int]$h) {
  $bandH = Px 26
  return $rowTop + [int](Px 6) + [int](($bandH - $h) / 2)
}

# One switch, calculated once: the paint, the hit test and the click all ask here, so a click
# always lands on the rectangle that was drawn.
function Get-SettingsToggleRect($layout, [int]$rowTop) {
  $w = [int]$layout.ToggleWidth
  $h = [int]$layout.ToggleHeight
  return @{
    Left   = [int]$layout.ListRight - (Px 12) - $w
    Top    = (Get-SettingsControlTop $layout $rowTop $h)
    Width  = $w
    Height = $h
  }
}

# Where a number lives: one field, its value at the right edge before the unit. The editor opens
# inside this rectangle, so the number does not move when it is clicked.
function Get-SettingsNumberRect($layout, [int]$rowTop) {
  $w = Px 132
  $h = Px 28
  return @{
    Left   = [int]$layout.ListRight - (Px 12) - $w
    Top    = (Get-SettingsControlTop $layout $rowTop $h)
    Width  = $w
    Height = $h
  }
}

# How wide a string is in a given face. Measured on a scratch bitmap because the hit tests ask
# too, and they have no Graphics of their own.
function Get-SettingsTextWidth([string]$text, $font) {
  if (-not $text) { return 0 }
  if ($null -eq $font) { return (Px (8 * $text.Length)) }
  $bmp = New-Object Drawing.Bitmap 1, 1
  $g = [Drawing.Graphics]::FromImage($bmp)
  try {
    $fmt = New-PickerStringFormats
    $big = New-Object Drawing.SizeF -ArgumentList @(1000, 100)
    return [int][Math]::Ceiling($g.MeasureString($text, $font, $big, $fmt.None).Width)
  } catch {
    return (Px (8 * $text.Length))
  } finally { $g.Dispose(); $bmp.Dispose() }
}

# How much room a unit label takes, measured with the font the row draws it in, plus the gap that
# separates it from the value.
function Get-SettingsUnitWidth([string]$unit) {
  if (-not $unit) { return 0 }
  return ((Get-SettingsTextWidth $unit $script:FSmall) + (Px 14))
}

# A value field: the field colour, a hairline, the value at the right of it, then a unit in the
# quiet ink when the value measures something. $mode is 'rest', 'edit' or 'bad', so a resting
# number, an open editor and a refused value cannot drift apart - the editor draws the same box
# with no value in it and puts its text box inside. $hint draws the value in the quiet ink: an
# empty field showing (auto) is a statement about the default, not a value in the file.
function Draw-SettingsValueField($g, $pal, $rect, [string]$value, [string]$unit, [bool]$enabled, [string]$mode = 'rest', [bool]$hint = $false) {
  if ($null -eq $g -or $null -eq $pal -or $null -eq $rect) { return }
  Draw-SettingsFieldBox $g $pal $rect $mode
  $x = [int]$rect.Left
  $y = [int]$rect.Top
  $w = [int]$rect.Width
  $h = [int]$rect.Height
  $sf = New-PickerStringFormats
  $uw = Get-SettingsUnitWidth $unit
  if ($uw -gt 0) {
    $ub = New-Object Drawing.RectangleF -ArgumentList @(
      [single]($x + $w - $uw), [single]$y, [single]($uw - (Px 8)), [single]$h)
    $g.DrawString($unit, $script:FSmall, (Get-Brush $pal['Faint']), $ub, $sf.Right)
  }
  if (-not $value) { return }
  $ink = $pal['Text']
  if (-not $enabled -or $hint) { $ink = $pal['Faint'] }
  $nb = New-Object Drawing.RectangleF -ArgumentList @(
    [single]($x + (Px 8)), [single]$y, [single]($w - $uw - (Px 12)), [single]$h)
  $g.DrawString($value, $script:FBody, (Get-Brush $ink), $nb, $sf.Right)
}

# The help of a row, broken into the lines the column can hold. Broken here rather than by the
# drawing call: GDI+ wraps by its own measure and clips a line that overflows, which loses the
# middle of a sentence. Words are packed until the next one does not fit; when the text does not
# end in the last line it gets an ellipsis and words come off its end until that fits too.
# Cached per width, because a paint happens on every pointer move.
$script:HelpLineCache = @{}
$script:HelpLineWidth = 0
function Get-SettingsHelpLines($g, [string]$text, [int]$maxWidth, [int]$maxLines) {
  if (-not $text -or $maxWidth -le 0 -or $maxLines -lt 1) { return @() }
  if ($script:HelpLineWidth -ne $maxWidth) { $script:HelpLineCache = @{}; $script:HelpLineWidth = $maxWidth }
  if ($script:HelpLineCache.ContainsKey($text)) { return @($script:HelpLineCache[$text]) }
  $fmt = New-PickerStringFormats
  $measure = {
    param([string]$s)
    if (-not $s) { return 0 }
    return [double]$g.MeasureString($s, $script:FSmall, 10000, $fmt.Seg).Width
  }
  $words = @(($text -split '\s+') | Where-Object { $_ })
  $lines = New-Object System.Collections.Generic.List[string]
  $cur = ''
  $rest = $false
  foreach ($w in $words) {
    $try = $w
    if ($cur) { $try = $cur + ' ' + $w }
    if ((-not $cur) -or ((& $measure $try) -le $maxWidth)) { $cur = $try; continue }
    $lines.Add($cur)
    $cur = $w
    if ($lines.Count -ge $maxLines) { $rest = $true; break }
  }
  if (-not $rest -and $cur) { $lines.Add($cur); $cur = '' }
  if ($rest -and $lines.Count -gt 0) {
    $ell = [string][char]0x2026
    $last = [string]$lines[$lines.Count - 1]
    while ($last -and ((& $measure ($last + $ell)) -gt $maxWidth)) {
      $cut = $last.LastIndexOf(' ')
      if ($cut -lt 1) { break }
      $last = $last.Substring(0, $cut)
    }
    $lines[$lines.Count - 1] = $last + $ell
  }
  $script:HelpLineCache[$text] = $lines.ToArray()
  return $lines.ToArray()
}

# The box every value sits in: the field colour, a hairline, and an accent or warn edge for an
# open editor or a refused value. One function, so a number, a path and an editor cannot drift
# into three slightly different rectangles.
function Draw-SettingsFieldBox($g, $pal, $rect, [string]$mode = 'rest') {
  if ($null -eq $g -or $null -eq $pal -or $null -eq $rect) { return }
  $x = [int]$rect.Left
  $y = [int]$rect.Top
  $w = [int]$rect.Width
  $h = [int]$rect.Height
  $radius = [int](Px 4)
  $fill = New-Object Drawing.SolidBrush $pal['Field']
  $path = New-RoundPath $x $y $w $h $radius
  try { $g.FillPath($fill, $path) } finally { $path.Dispose(); $fill.Dispose() }
  $edge = $pal['FieldBorder']
  if ($mode -eq 'edit') { $edge = $pal['Accent'] }
  elseif ($mode -eq 'bad') { $edge = $pal['Warn'] }
  $pen = New-Object Drawing.Pen $edge
  $stroke = New-RoundPath $x $y $w $h $radius
  try { $g.DrawPath($pen, $stroke) } finally { $stroke.Dispose(); $pen.Dispose() }
}

# A path is read from its end: the folder that matters is the last one, and the drive letter is
# the part that never changes. The tail is kept and the head is replaced by an ellipsis, measured
# from the right so the text always fills the field instead of leaving a gap.
function Format-SettingsPathTail([string]$path, $font, [int]$maxWidth) {
  $text = [string]$path
  if (-not $text -or $maxWidth -le 0) { return $text }
  if ((Get-SettingsTextWidth $text $font) -le $maxWidth) { return $text }
  $lead = [string][char]0x2026
  $lo = 1
  $hi = $text.Length
  $best = $lead
  while ($lo -le $hi) {
    $mid = [int][Math]::Floor(($lo + $hi) / 2)
    $cand = $lead + $text.Substring($text.Length - $mid)
    if ((Get-SettingsTextWidth $cand $font) -le $maxWidth) { $best = $cand; $lo = $mid + 1 } else { $hi = $mid - 1 }
  }
  return $best
}

# A path row reads as a picker: a folder glyph, then the tail of the path in a field, the same
# rectangle a number lives in. The full path stays in the help line, so nothing is lost by
# shortening the value.
function Draw-SettingsPathField($g, $pal, $rect, [string]$path, [bool]$enabled) {
  if ($null -eq $g -or $null -eq $pal -or $null -eq $rect) { return }
  Draw-SettingsFieldBox $g $pal $rect 'rest'
  $x = [int]$rect.Left
  $y = [int]$rect.Top
  $w = [int]$rect.Width
  $h = [int]$rect.Height
  $ink = $pal['Dim']
  if (-not $enabled) { $ink = $pal['Faint'] }
  $glyphLeft = $x + (Px 8)
  $glyphW = (Px 16)
  # the slot is 16 px, so the icon is the 16 px face: a smaller one in a 16 px slot reads as a
  # different weight from every other icon in the window
  $font = $script:FIcon
  if ($null -ne $font) {
    $sf = New-PickerStringFormats
    $gb = New-Object Drawing.RectangleF -ArgumentList @([single]$glyphLeft, [single]$y, [single]$glyphW, [single]$h)
    Draw-UiGlyph $g ([string][char]0xE8B7) $font (Get-Brush $ink) $gb $sf.Center
  } else { $glyphW = 0 }
  $textLeft = $glyphLeft + $glyphW + (Px 6)
  $room = $x + $w - (Px 8) - $textLeft
  $tail = Format-SettingsPathTail $path $script:FSmall $room
  $sf2 = New-PickerStringFormats
  $tb = New-Object Drawing.RectangleF -ArgumentList @([single]$textLeft, [single]$y, [single][Math]::Max(0, $room), [single]$h)
  $g.DrawString($tail, $script:FSmall, (Get-Brush $ink), $tb, $sf2.Right)
}

# Where a path sits: wider than a number, because a folder name is longer than a byte count and
# the field is the affordance that says "this opens a dialog".
function Get-SettingsPathRect($layout, [int]$rowTop) {
  $w = Px 240
  $h = Px 28
  return @{
    Left   = [int]$layout.ListRight - (Px 12) - $w
    Top    = (Get-SettingsControlTop $layout $rowTop $h)
    Width  = $w
    Height = $h
  }
}

# How wide the control column is, per kind of row: a switch is narrow, a number field wider, a
# path field wider still. The paint, the editor and the hit tests all ask here, so a box always
# covers exactly the column its value was drawn in.
function Get-SettingsControlWidth($row) {
  if ($null -eq $row) { return (Px 170) }
  if ($row.Kind -eq 'bool') { return (Px 74) }
  if ($row.Kind -eq 'number') { return (Px 148) }
  $pick = ''
  if ($row.ContainsKey('Pick')) { $pick = [string]$row.Pick }
  if ($pick) { return (Px 254) }
  return (Px 170)
}

# The rectangle a row's control occupies: the switch itself, the number field, the folder field,
# or the column a dropdown, a typed value, a chord or a link sits in. The paint draws inside it
# and a press is accepted only inside it, so a click on the label or on the help line does
# nothing - the row used to be the target, and a stray click beside a switch flipped it.
function Get-SettingsControlRect($layout, $row, [int]$rowTop) {
  if ($null -eq $row -or $null -eq $layout) { return [Drawing.Rectangle]::Empty }
  if ($row.Kind -eq 'bool') {
    $t = Get-SettingsToggleRect $layout $rowTop
    return (New-Object Drawing.Rectangle -ArgumentList @([int]$t.Left, [int]$t.Top, [int]$t.Width, [int]$t.Height))
  }
  if ($row.Kind -eq 'number') {
    $f = Get-SettingsNumberRect $layout $rowTop
    return (New-Object Drawing.Rectangle -ArgumentList @([int]$f.Left, [int]$f.Top, [int]$f.Width, [int]$f.Height))
  }
  $pick = ''
  if ($row.ContainsKey('Pick')) { $pick = [string]$row.Pick }
  if ($pick) {
    $f = Get-SettingsPathRect $layout $rowTop
    return (New-Object Drawing.Rectangle -ArgumentList @([int]$f.Left, [int]$f.Top, [int]$f.Width, [int]$f.Height))
  }
  # a chain is a list of chord lines, each with its own delete button: the whole right-hand
  # column of the row is the target, because the lines and the buttons are all inside it and a
  # line is allowed to sit above the row's own band
  if ($row.ContainsKey('Chain') -and [bool]$row.Chain) {
    $line = Get-SettingsChordLineRect $layout $rowTop 0
    return (New-Object Drawing.Rectangle -ArgumentList @(
      [int]$line.Left, $rowTop, [int]($line.Right - $line.Left), [int]$layout.RowHeight))
  }
  $w = [int]$layout.ListRight - [int]$layout.ListLeft
  $controlW = Get-SettingsControlWidth $row
  return (New-Object Drawing.Rectangle -ArgumentList @(
    [int]([int]$layout.ListLeft + ($w - (Px 12)) - $controlW), [int]($rowTop + (Px 6)), [int]$controlW, [int](Px 26)))
}

# The lines a chain of chords takes in the value column: one per chord, the height of a cap, so the
# list reads as rows instead of one line with "+3" behind it. The chain holds three, which is what
# the card holds: every chord in the file is a line here, with a delete button of its own.
function Get-SettingsChordLineRect($layout, [int]$rowTop, [int]$index) {
  $lineH = Px 22
  $top = (Get-SettingsControlTop $layout $rowTop $lineH) + ($index * $lineH)
  $right = [int]$layout.ListRight - (Px 12)
  return @{ Top = $top; Height = $lineH; Right = $right; Left = $right - (Px 240) }
}

# The delete button of one chord line: a 16 px box at the end of the line, where a list row puts
# its remove affordance.
function Get-SettingsChordDeleteRect($layout, [int]$rowTop, [int]$index) {
  $line = Get-SettingsChordLineRect $layout $rowTop $index
  $size = Px 16
  return @{
    Left   = [int]$line.Right - $size
    Top    = [int]$line.Top + [int](($line.Height - $size) / 2)
    Width  = $size
    Height = $size
  }
}

# The button that adds a chord line: the next free line of the chain, in the same 16 px box the
# delete cross uses, so the two marks line up in one column. A full chain has no button - the
# three lines are all the card holds - which is why the caller only asks for it while there is room.
function Get-SettingsChordAddRect($layout, [int]$rowTop, [int]$index) {
  return (Get-SettingsChordDeleteRect $layout $rowTop $index)
}

# One setting: the label and its help on the left, the control on the right, centred on the row.
# That is the Fluent settings card - a name over a description, one control per card, and the
# control holds the vertical middle of the card rather than the first line.
#
# This column is not a list: nothing marks a row as current, because every row is its own control
# and a filled or outlined row reads as "these are selected items". Hovering is the only fill. A
# row that cannot take effect is greyed and says which setting owns it.
function Draw-SettingsRow($g, $pal, $layout, $row, [int]$x, [int]$y, [int]$w, [double]$toggleK, [bool]$armed = $false, $preview = @(), [bool]$editing = $false) {
  if ($null -eq $g -or $null -eq $row) { return }
  $enabled = $true
  if ($row.ContainsKey('Enabled')) { $enabled = [bool]$row.Enabled }
  $pick = ''
  if ($row.ContainsKey('Pick')) { $pick = [string]$row.Pick }
  $sf = New-PickerStringFormats
  $valueRight = $w - (Px 12)
  # the control column sets how much room the label and the help have: a switch is narrow, a
  # number field wider, a path field wider still. The text stops before it, so a description
  # never runs under the value.
  $controlW = Get-SettingsControlWidth $row
  $textW = $valueRight - $controlW - (Px 12)
  if ($textW -lt (Px 120)) { $textW = [int](Px 120) }
  $labelInk = $pal['Text']
  $helpText = [string]$row.Help
  if (-not $enabled) {
    $labelInk = $pal['Faint']
    if ($row.ContainsKey('Why') -and $row.Why) {
      $reason = [string]$row.Why
      $helpText = Get-UiText 'settings.help.off' @($reason)
    }
  }
  $labelBox = New-Object Drawing.RectangleF -ArgumentList @(
    [single]($x + (Px 12)), [single]($y + (Px 8)), [single]$textW, [single](Px 22))
  $g.DrawString([string]$row.Label, $script:FBody, (Get-Brush $labelInk), $labelBox, $sf.Ellipsis)
  # a staged row carries a dot in the row's left padding: nothing is written yet, and a page with
  # one changed value among thirty has to say which one. It sits outside the label so no text
  # shifts when a value becomes staged.
  if ($row.ContainsKey('Pending') -and $row.Pending) {
    $dot = [Math]::Max(3, (Px 4))
    $db = New-Object Drawing.SolidBrush $pal['Accent']
    try { $g.FillEllipse($db, ($x + (Px 5)), ($y + (Px 17)), $dot, $dot) } finally { $db.Dispose() }
  }
  # the help is drawn as the lines the column can hold: breaking it here is what keeps a
  # sentence whole instead of losing its middle to a clip
  if ($helpText) {
    $lineH = [int](Px 17)
    $lines = @(Get-SettingsHelpLines $g $helpText $textW 2)
    for ($i = 0; $i -lt $lines.Count; $i++) {
      $hb = New-Object Drawing.RectangleF -ArgumentList @(
        [single]($x + (Px 12)), [single]($y + (Px 30) + ($i * $lineH)), [single]$textW, [single]$lineH)
      $g.DrawString([string]$lines[$i], $script:FSmall, (Get-Brush $pal['Faint']), $hb, $sf.None)
    }
  }
  # A value being edited is covered by the field the editor puts there. Drawing the row's own
  # value as well leaves the hint of an empty value showing beside the box, which is what put the
  # (none) of a pattern next to its field instead of in it.
  if ($editing) { return }
  if ($row.Kind -eq 'bool') {
    $t = Get-SettingsToggleRect $layout $y
    Draw-SettingsToggle $g $pal ([int]$t.Left) ([int]$t.Top) ([int]$t.Width) ([int]$t.Height) $toggleK $enabled
    return
  }
  # a number is a field with its unit beside it, never a bare number: 16 with no unit beside it
  # says nothing about what it measures. An empty value holds its hint in the same field, so the
  # row that reads (auto) still says px
  if ($row.Kind -eq 'number') {
    $f = Get-SettingsNumberRect $layout $y
    $value = [string]$row.Number
    $isHint = $false
    if (-not $value) { $value = [string]$row.Text; $isHint = $true }
    Draw-SettingsValueField $g $pal $f $value ([string]$row.Unit) $enabled 'rest' $isHint
    return
  }
  # a path is a picker, not a value: the field says "this opens a dialog" and the folder that
  # matters - the last one - is what it shows
  if ($pick) {
    $f = Get-SettingsPathRect $layout $y
    Draw-SettingsPathField $g $pal $f ([string]$row.Raw) $enabled
    return
  }
  # A link is the one value that leaves the window. The accent is what says it can be pressed,
  # the open-in-new mark after it says it goes elsewhere, and both sit in the value column so the
  # row still reads like every other row on the page.
  if ($row.Kind -eq 'link') {
    $ctrl = Get-SettingsControlRect $layout $row $y
    $mark = Px 12
    $markGap = Px 5
    $linkBox = New-Object Drawing.RectangleF -ArgumentList @(
      [single]$ctrl.Left, [single]$ctrl.Top, [single]($ctrl.Width - $mark - $markGap), [single]$ctrl.Height)
    $g.DrawString([string]$row.Text, $script:FBody, (Get-Brush $pal['Accent']), $linkBox, $sf.Right)
    if ($script:IconFamily) {
      $markBox = New-Object Drawing.RectangleF -ArgumentList @(
        [single]($ctrl.Left + $ctrl.Width - $mark), [single]$ctrl.Top, [single]$mark, [single]$ctrl.Height)
      Draw-UiGlyph $g ([string][char]0xE8A7) $script:FIconTiny (Get-Brush $pal['Accent']) $markBox $sf.Center
    }
    return
  }
  # the value holds the vertical middle of the whole row, the same line the switch sits on
  $choices = @()
  if ($row.ContainsKey('Choices') -and $null -ne $row.Choices) { $choices = @($row.Choices) }
  $dropW = 0
  if ($choices.Count -gt 0 -and $enabled) { $dropW = Px 16 }
  $cy = $y + [int](Px 19)
  # a chevron, the same affordance a Fluent combo box carries. Drawn before the value, so a row
  # that shows key caps keeps its affordance too.
  if ($dropW -gt 0) {
    $cx = $x + $valueRight - (Px 7)
    $pen = New-Object Drawing.Pen $pal['Dim'], (Px 1)
    try {
      $g.DrawLine($pen, ($cx - (Px 3)), ($cy - (Px 2)), $cx, ($cy + (Px 2)))
      $g.DrawLine($pen, $cx, ($cy + (Px 2)), ($cx + (Px 3)), ($cy - (Px 2)))
    } finally { $pen.Dispose() }
  }
  # A shortcut is a chord, not a string: its keys are drawn as the panel's key caps, right
  # aligned so the chord ends where the value text did.
  $chords = @()
  if ($row.ContainsKey('Chords') -and $null -ne $row.Chords) { $chords = @($row.Chords) }
  # A chain is a list, and a list on one line says nothing: every chord gets its own line with a
  # delete button. The card holds three of them; a longer chain states the rest beside its help
  # (see the count above), because a badge on a chord line competes with the caps for the width.
  $chain = ($row.ContainsKey('Chain') -and [bool]$row.Chain)
  if ($chain) {
    $maxLines = 3
    $drawn = [Math]::Min($chords.Count, $maxLines)
    if ($armed -and $drawn -ge $maxLines) { $drawn = $maxLines - 1 }
    for ($i = 0; $i -lt $drawn; $i++) {
      $line = Get-SettingsChordLineRect $layout $y $i
      $del = Get-SettingsChordDeleteRect $layout $y $i
      $cy = [int]$line.Top + [int]($line.Height / 2)
      # the caps end where the delete cross begins: the cross itself is a control of its own
      [void](Draw-SettingChord $g $pal ([int]$del.Left - (Px 10)) $cy (Get-SettingChordKeys ([string]$chords[$i])) $enabled)
    }
    if ($armed) {
      # the chord being recorded goes on the next free line: the chain is being added to, not
      # replaced
      $line = Get-SettingsChordLineRect $layout $y $drawn
      $keys = @($preview)
      $keys += [string][char]0x2026
      [void](Draw-SettingChord $g $pal ([int]$line.Right) ([int]$line.Top + [int]($line.Height / 2)) $keys $enabled $true)
      return
    }
    # the plus is the row's one way into a recording: it sits on the next free line, in the same
    # 16 px box the delete cross uses, and it is gone while a recording runs, so the row never
    # offers a press that cannot do anything. It is a control of its own, drawn by the window
    # from the node list, so what lights up under the pointer is what a press acts on.
    return
  }
  if ($armed -or $chords.Count -gt 0) {
    $xr = $x + $valueRight - $dropW
    if ($armed) {
      # the row is waiting for a chord: what is held so far, then one accent cap for the key
      $keys = @($preview)
      $keys += [string][char]0x2026
      [void](Draw-SettingChord $g $pal $xr $cy $keys $enabled $true)
      return
    }
    [void](Draw-SettingChord $g $pal $xr $cy (Get-SettingChordKeys ([string]$chords[0])) $enabled)
    return
  }
  # the text sits on the control band, the same vertical centre the switch, the caps and the field
  # the editor opens on use: a value that jumped two pixels when its box appeared would read as a
  # misaligned row. The box is the control the row answers a press on, so it comes from the same
  # function the hit test asks (Get-SettingsControlRect).
  $ctrl = Get-SettingsControlRect $layout $row $y
  $valueBox = New-Object Drawing.RectangleF -ArgumentList @(
    [single]$ctrl.Left, [single]$ctrl.Top, [single]($ctrl.Width - $dropW), [single]$ctrl.Height)
  $ink = $pal['Dim']
  if (-not $enabled) { $ink = $pal['Faint'] }
  $g.DrawString([string]$row.Text, $script:FBody, (Get-Brush $ink), $valueBox, $sf.Right)
}

# The keys of one chord as the caps the footer and the panel's hints draw: filled, stroked and
# rounded, so a shortcut reads key by key. $anchor is the edge the run ends at when $align is
# 'right' and the edge it starts at when it is 'left' (a list of chords starts at its margin).
# Returns the width it took, which is what lets a chain of them be laid out beside something else.
function Draw-SettingChord($g, $pal, [int]$anchor, [int]$cy, $keys, [bool]$enabled, [bool]$accentLast = $false, [string]$align = 'right') {
  if ($null -eq $g -or $null -eq $pal) { return 0 }
  $list = @($keys)
  if ($list.Count -eq 0) { return 0 }
  $font = $script:FSmall
  if (-not $font) { return 0 }
  $fmt = New-PickerStringFormats
  $chipH = Px $script:Metric['ChipHeight']
  # the caps of one chord are held together by a plus between them, which is how the shortcut is
  # written everywhere else: a bare gap made three caps read as three separate values
  $plusW = Px 13
  $padX = Px 14
  $minW = Px 24
  $big = New-Object Drawing.SizeF -ArgumentList @(1000, 100)
  $widths = @()
  $total = 0
  for ($i = 0; $i -lt $list.Count; $i++) {
    $w = [int][Math]::Ceiling($g.MeasureString([string]$list[$i], $font, $big, $fmt.None).Width + $padX)
    if ($w -lt $minW) { $w = $minW }
    $widths += $w
    $total += $w
    if ($i -lt ($list.Count - 1)) { $total += $plusW }
  }
  $x = $anchor - $total
  if ($align -eq 'left') { $x = $anchor }
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
    $x += $w
    if ($i -lt ($list.Count - 1)) {
      # the plus takes the slot between two caps, in the quiet ink: it joins them without
      # competing with the keys themselves
      $pb = New-Object Drawing.RectangleF -ArgumentList @([single]$x, [single]$top, [single]$plusW, [single]$chipH)
      $g.DrawString('+', $font, (Get-Brush $pal['Faint']), $pb, $fmt.Center)
      $x += $plusW
    }
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

# Where the footer actions sit, right aligned and laid out from the right edge inwards so Save -
# the primary one - always ends at the padding. The width follows the label, because "Restore
# defaults" is three times "Save" and a fixed width would either clip it or leave a hole. One
# function for the paint and the hit test, so a click lands on the rectangle that was drawn.
function Get-SettingsActionRects($layout, $labels) {
  $list = @($labels)
  $h = [int]$layout.ActionHeight
  $gap = [int]$layout.ActionGap
  $pad = [int]$layout.ActionPad
  $minW = Px 88
  if ($layout.ContainsKey('ActionMin')) { $minW = [int]$layout.ActionMin }
  # the button is centred in the bar, so the air above it and below it is the same
  $top = [int]$layout.ListBottom + [int](([int]$layout.FootHeight - $h) / 2)
  $right = [int]$layout.Width - [int]$layout.Pad
  $out = New-Object System.Collections.Generic.List[object]
  # laid out from the right edge inwards, so the primary action always ends at the padding
  for ($i = $list.Count - 1; $i -ge 0; $i--) {
    $w = (Get-SettingsTextWidth ([string]$list[$i]) $script:FBody) + (2 * $pad)
    if ($w -lt $minW) { $w = $minW }
    $right = $right - $w
    $out.Insert(0, @{ Left = [int]$right; Top = [int]$top; Width = [int]$w; Height = $h })
    $right = $right - $gap
    # a wider break before the first action: resetting every value is not part of the
    # save / discard pair, and a 8 px gap would let a pointer slide from one to the other
    if ($i -eq 1) { $right = $right - (Px 16) }
  }
  return $out.ToArray()
}

# The footer is the window's own bar: what the last change did on the left and the actions on
# the right. The actions themselves are view nodes drawn by lib\ui\views.ps1 - this bar draws only
# what is not a control: the hairline that marks it off, and the message that sits beside the
# buttons. $actions is only needed for where the buttons end, which is where the message stops.
# The version and the item count are not here: they describe the program, not the page, and they
# live on the About page where they can be read in full.
function Draw-SettingsFooter($g, $pal, $layout, [string]$msg, [bool]$isError, $actions) {
  if ($null -eq $g -or $null -eq $pal) { return }
  $sf = New-PickerStringFormats
  $left = [int]$layout.Pad
  $top = [int]$layout.ListBottom
  $limit = [int]$layout.Width - [int]$layout.Pad
  # a hairline marks the bar off: the buttons make the footer a place with controls in it, and a
  # Fluent dialog separates its command bar from the page
  $pen = New-Object Drawing.Pen $pal['Border']
  try { $g.DrawLine($pen, $left, $top, $limit, $top) } finally { $pen.Dispose() }
  $specs = @($actions)
  if ($specs.Count -gt 0) {
    $rects = @(Get-SettingsActionRects $layout @($specs | ForEach-Object { [string]$_.Label }))
    if ($rects.Count -gt 0) { $limit = [int]$rects[0].Left - (Px 16) }
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

# The minimise button sits beside the close one, in the order a caption bar puts them.
function Get-SettingsMinRect($layout) {
  $size = [int]$layout.CloseSize
  $left = [int]$layout.Width - (Px 8) - $size - (Px 4) - $size
  return @{
    Left = $left
    Top = (Px 8)
    Width = $size
    Height = $size
  }
}

# Where the thumb sits, as one calculation shared by the paint, the hit test and the drag: the
# thumb covers as much of the track as the list shows of its content, and its offset is the pixel
# scroll over the pixels there are to scroll, so one pixel of drag is the matching fraction of the
# content instead of a whole row.
function Get-SettingsScrollThumb($layout, [int]$rows, [int]$visible, [int]$scroll) {
  if ($null -eq $layout -or $visible -le 0 -or $rows -le $visible) { return $null }
  $top = [int]$layout.ListTop
  $track = [int]$layout.ListBottom - $top
  if ($track -lt (Px 24)) { return $null }
  # the same three numbers every scrollbar in the tool turns into a thumb (lib\ui\layout.ps1)
  $span = [Math]::Max(1, ($rows * [int]$layout.RowHeight) - $track)
  $m = Get-UiScrollMetrics $track ($visible / [double]$rows) $scroll $span (Px 24)
  if ($null -eq $m) { return $null }
  return @{ Top = ($top + $m.Top); Len = $m.Len; TrackTop = $top; TrackLen = $track; Span = $span }
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
  $lane = New-UiBox ([int]$layout.SbLeft) ([int]$layout.ListTop) ([int]$layout.SbLane) ([int]$layout.ListBottom - [int]$layout.ListTop)
  Draw-UiScrollbar $g $pal $lane $thumb $k
}

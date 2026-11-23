# lib/panel/picker-draw.ps1 - the panel's reusable drawing pieces.
#
# Everything here takes a Graphics (or a window, for the one region helper) plus plain
# values: no list, no per-open state. That is what makes these callable from anywhere (and
# testable) instead of only from the one function that happens to own the window.
#
# Shared GDI objects live on $script:PickerSf / $script:FBody and are created once, because
# measuring every highlighted segment with a freshly built StringFormat would allocate on
# every paint.

# The panel and its header field are rounded by a window region. A replaced region has to be
# disposed by hand - WinForms does not own it - so every open and every resize would
# otherwise leak one HRGN into the resident process.
# One radius for every window the panel opens - the panel, the editor card that covers it and
# the hover card - so the three silhouettes cannot drift apart. Fluent puts its flyouts and
# cards on 8 px (inner controls, such as the search field, stay on 4); a theme may restyle the
# metric and all three follow.
function Get-WindowRadius { return [int](Px ([Math]::Max(2, [int]$script:Metric['PanelRadius']))) }

function Update-PanelRegion($form) {
  try {
    $old = $form.Region
    $form.Region = New-RoundRegion ([int]$form.ClientSize.Width) ([int]$form.ClientSize.Height) (Get-WindowRadius)
    if ($null -ne $old) { $old.Dispose() }
  } catch { }
}

# A window edge has to hold its own: there is no drop shadow behind this window, and the theme's
# separator colour is about 8% white, which reads as nothing against the surface. The frame is
# lifted to this alpha; a theme that already asks for a stronger border keeps its own value.
$script:FrameAlphaMin = 46

# The 1 px frame of a window that carries a rounded region. A stroked path is the wrong tool
# here: the region is the silhouette, so it clips whatever falls outside, and on a curve a
# 1 px stroke rarely covers a pixel whole - the straight edges stay solid while the arcs keep
# only a broken chain at about half strength, which reads as a frame that is missing exactly
# where it turns. Filling a 1 px ring instead puts whole pixels on the arcs too, so the corners
# come out at the same weight as the sides. Every custom-drawn window edge goes through here.
# The colour the frame is filled with. A theme's separator is translucent, and a translucent
# fill is not idempotent: the window region clips the outermost row and column away from the
# surface fill, so every repaint added one more pass of the same faint colour there and the edge
# drifted lighter the longer the window stayed open. Composited against the surface it sits on,
# the frame is opaque, and painting it twice paints the same pixel twice.
function Get-FrameColour($color, $behind) {
  $a = [int]$color.A
  if ($a -lt $script:FrameAlphaMin) { $a = [int]$script:FrameAlphaMin }
  if ($null -eq $behind) { return [Drawing.Color]::FromArgb($a, [int]$color.R, [int]$color.G, [int]$color.B) }
  $k = $a / 255.0
  return [Drawing.Color]::FromArgb(255,
    [int][Math]::Round(($color.R * $k) + ($behind.R * (1 - $k))),
    [int][Math]::Round(($color.G * $k) + ($behind.G * (1 - $k))),
    [int][Math]::Round(($color.B * $k) + ($behind.B * (1 - $k))))
}

function Draw-PanelFrame($g, [int]$w, [int]$h, $color, [int]$radius, $behind = $null) {
  if ($null -eq $g -or $w -lt 6 -or $h -lt 6) { return }
  $t = [Math]::Max(1, (Px 1))
  if (($radius * 2) -gt ($w - 3) -or ($radius * 2) -gt ($h - 3)) { $radius = [int]([Math]::Min($w - 3, $h - 3) / 2) }
  # a translucent separator colour is lifted, so the silhouette reads on a dark surface
  $color = Get-FrameColour $color $behind
  $outer = $null
  $inner = $null
  $ring = New-Object Drawing.Drawing2D.GraphicsPath
  $brush = New-Object Drawing.SolidBrush $color
  # No antialiasing: the point is a line made of whole pixels, and a smoothed edge would be
  # soft again - the window's own region edge is just as hard. The caller's mode is put back,
  # because the text and the pictures drawn after this want their smoothing.
  #
  # The ring is built from four rectangles for the sides and four sector pairs for the corners
  # rather than one outline minus another. Two rounded outlines spanning the same grid were
  # rasterized asymmetrically - the sides that lie exactly on the pixel boundary came out one
  # pixel short, which left the frame along the right and bottom only - while filled
  # rectangles and pies land on whole rows and columns by construction.
  $was = $g.SmoothingMode
  $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::None
  try {
    $span = $w - (2 * $t)
    $side = $h - (2 * $t)
    if ($span -gt 0) {
      $g.FillRectangle($brush, $radius, 0, $span, $t)
      $g.FillRectangle($brush, $radius, ($h - $t), $span, $t)
    }
    if ($side -gt 0) {
      $g.FillRectangle($brush, 0, $radius, $t, $side)
      $g.FillRectangle($brush, ($w - $t), $radius, $t, $side)
    }
    if ($radius -gt 0) {
      $ring.FillMode = [Drawing.Drawing2D.FillMode]::Alternate
      $d = $radius * 2
      $di = [Math]::Max(2, ($radius - $t) * 2)
      # top left, top right, bottom right, bottom left - the outer sector and the inner one in
      # one path, so the fill keeps only the band between them
      $corners = @(
        @(0, 0, 180), @(($w - $d), 0, 270), @(($w - $d), ($h - $d), 0), @(0, ($h - $d), 90)
      )
      foreach ($c in $corners) {
        $ring.AddPie([int]$c[0], [int]$c[1], $d, $d, [int]$c[2], 90)
        $ring.AddPie(([int]$c[0] + $t), ([int]$c[1] + $t), $di, $di, [int]$c[2], 90)
      }
      $g.FillPath($brush, $ring)
    }
  } finally {
    $g.SmoothingMode = $was
    if ($null -ne $outer) { $outer.Dispose() }
    if ($null -ne $inner) { $inner.Dispose() }
    $ring.Dispose()
    $brush.Dispose()
  }
}

# A docked child reaches the window corner and paints over the frame there: the border survives
# along the sides, which the child never touches, and disappears in the arcs, which it does. The
# header and the footer are clipped to a rounded shape one pixel inside the frame instead, so the
# arcs stay on screen. Only the corners that meet the window are rounded - the other side keeps
# its square edge, or a separator line inside the child would be cut short.
function Set-FrameCornerRegion($ctl, [int]$radius, [string]$corners = 'top') {
  if ($null -eq $ctl -or $ctl.Width -lt 6 -or $ctl.Height -lt 6) { return }
  try {
    $old = $ctl.Region
    $w = [int]$ctl.Width
    $h = [int]$ctl.Height
    $r = [Math]::Max(1, [Math]::Min($radius, [int]([Math]::Min($w, $h) / 2)))
    $reg = New-RoundRegion $w $h $r
    if ($corners -ceq 'bottom') { [void]$reg.Union((New-Object Drawing.Rectangle 0, 0, $w, ($h - $r))) }
    else { [void]$reg.Union((New-Object Drawing.Rectangle 0, $r, $w, ($h - $r))) }
    $ctl.Region = $reg
    if ($null -ne $old) { $old.Dispose() }
  } catch {
    Write-Log ('frame corner region failed: ' + $_.Exception.Message)
  }
}

# The keys the in-place editor answers. One list, used by the panel footer and by the editor
# card that covers it, so the two cannot spell the same action differently. The action words
# come from the language file like every other word on screen; the key names do not.
function Get-EditHints {
  $pairs = New-Object System.Collections.Generic.List[object]
  $pairs.Add(@('Enter', (Get-UiText 'panel.chip.save')))
  $pairs.Add(@('Shift+Enter', (Get-UiText 'panel.chip.newline')))
  $pairs.Add(@('Esc', (Get-UiText 'panel.chip.cancel')))
  return $pairs.ToArray()
}

# Shortcut hints as Fluent key chips: [key] action. Plain data, so the footer can be checked
# without a window and the panel only has to say what state it is in.
#
# The row is built from what is actually possible right now, not from a fixed list: a batch
# (more than one row selected) can be copied and deleted but not pasted or edited, a picture
# has no text to edit so F2 would only promise something the editor refuses, and Esc clears the
# search before it closes the panel. The footer truncates from the right, so the keys that
# change something come before the one that leaves.
function Get-PanelHints([int]$rows, [int]$selected, [bool]$editable, [int]$queryLen, [bool]$ctrlHeld, $ctrlKeys, [bool]$editing, [bool]$undoOn, [bool]$compact = $false) {
  # while the editor covers the list, only the editor's own keys work
  if ($editing) {
    return (Get-EditHints)
  }
  if ($rows -le 0) {
    # the comma keeps the pair nested: a one-element array would be unrolled by the function
    # return and each string would then be read as a list of characters
    return ,@(@('Esc', (Get-UiText 'panel.chip.close')))
  }
  if ($compact) {
    # the compact footer has no room for five pairs and no count label to share the row with:
    # pick and leave first, then the two extras that change something
    $pairs = New-Object System.Collections.Generic.List[object]
    if ($selected -gt 1) {
      $pairs.Add(@('Ctrl+Enter', (Get-UiText 'panel.chip.copyN' @($selected))))
      $pairs.Add(@('Del', (Get-UiText 'panel.chip.deleteN' @($selected))))
    } else {
      $pairs.Add(@('Enter', (Get-UiText 'panel.chip.paste')))
      $pairs.Add(@('Ctrl+Enter', (Get-UiText 'panel.chip.copy')))
      if ($editable) { $pairs.Add(@('F2', (Get-UiText 'panel.chip.edit'))) }
    }
    if ($queryLen -gt 0) { $pairs.Add(@('Esc', (Get-UiText 'panel.chip.clear'))) } else { $pairs.Add(@('Esc', (Get-UiText 'panel.chip.close'))) }
    return $pairs.ToArray()
  }
  $multi = ($selected -gt 1)
  # the count is worked out first: inside the array below, '+ [string]$selected' would be read
  # as a second pair element and the chip would come out as 'Copy' and '3' side by side
  $copyLabel = Get-UiText 'panel.chip.copy'
  $delLabel = Get-UiText 'panel.chip.delete'
  if ($multi) {
    $copyLabel = Get-UiText 'panel.chip.copyN' @($selected)
    $delLabel = Get-UiText 'panel.chip.deleteN' @($selected)
  }
  if ($ctrlHeld) {
    # Ctrl is held while these show; each chip spells the whole combination out, core ones
    # first, because the footer truncates and the plugin keys are the optional ones
    # a list, not "@(@(pair))": a one-element array of arrays is flattened by the array
    # subexpression, and the first chip then came out as two loose strings
    $pairs = New-Object System.Collections.Generic.List[object]
    $pairs.Add(@('Ctrl+1-9,0', (Get-UiText 'panel.chip.pick')))
    $pairs.Add(@('Ctrl+Enter', $copyLabel))
    # undo is only worth a chip while the setting allows it
    if ($undoOn) { $pairs.Add(@('Ctrl+Z', (Get-UiText 'panel.chip.undo'))) }
    foreach ($pk in @($ctrlKeys)) {
      # the text is built first: inside one expression the comma binds to the right of the
      # "Ctrl+" + key addition, so the pair arrived as a single string "Ctrl+O Open" and the
      # chip drew both words inside one key cap
      $label = 'Ctrl+' + [string]$pk.Key
      $hint = [string]$pk.Hint
      $pairs.Add(@($label, $hint))
    }
    return $pairs.ToArray()
  }
  $out = New-Object System.Collections.Generic.List[object]
  if ($multi) {
    $out.Add(@('Ctrl+Enter', $copyLabel))
  } else {
    $out.Add(@('Enter', (Get-UiText 'panel.chip.paste')))
    $out.Add(@('Ctrl+Enter', $copyLabel))
    # only a plain text row has anything the editor can show and write back
    if ($editable) { $out.Add(@('F2', (Get-UiText 'panel.chip.edit'))) }
  }
  $out.Add(@('Del', $delLabel))
  if ($queryLen -gt 0) { $out.Add(@('Esc', (Get-UiText 'panel.chip.clear'))) } else { $out.Add(@('Esc', (Get-UiText 'panel.chip.close'))) }
  return $out.ToArray()
}

# One brush per colour, kept for the process: the row painter runs on every scroll tick, so
# a SolidBrush per glyph would churn GDI+ handles for nothing. A palette has a few dozen
# colours at most, so this stays bounded; the brushes die with the process.
function Get-Brush($color) {
  if ($null -eq $script:UiBrushCache) { $script:UiBrushCache = @{} }
  $k = $color.ToArgb()
  $b = $script:UiBrushCache[$k]
  if ($null -eq $b) { $b = New-Object Drawing.SolidBrush $color; $script:UiBrushCache[$k] = $b }
  return $b
}

# A row thumbnail fills a square slot, keeping its aspect ratio. The bitmap belongs to the
# media cache, so it is drawn here and never disposed here.
function Draw-RowThumb($g, $bmp, [int]$x, [int]$y, [int]$side) {
  if ($null -eq $bmp -or $side -lt 8) { return $false }
  $w = $bmp.Width
  $h = $bmp.Height
  if ($w -lt 1 -or $h -lt 1) { return $false }
  $old = $g.InterpolationMode
  try {
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $scale = [Math]::Min($side / [double]$w, $side / [double]$h)
    $dw = [int][Math]::Max(1, [Math]::Round($w * $scale))
    $dh = [int][Math]::Max(1, [Math]::Round($h * $scale))
    $g.DrawImage($bmp, ($x + [int](($side - $dw) / 2)), ($y + [int](($side - $dh) / 2)), $dw, $dh)
    return $true
  } catch {
    return $false
  } finally {
    $g.InterpolationMode = $old
  }
}

# An icon glyph is one colour, so it is drawn with grayscale anti-aliasing: these surfaces
# rasterise their text with ClearType, which splits a 1 px stroke into coloured subpixels and
# leaves a 16 px icon looking heavier than the rest. The glyph keeps whatever layout box the
# caller gives it - Segoe Fluent Icons hands every glyph the same advance and line box, so
# centring the box centres every icon without a measurement of its own. The box is moved down by
# the measured difference between the two inks: a text line's ink sits below the middle of its
# box and an icon's ink sits above its own, so side by side the icon reads high.
function Draw-UiGlyph($g, [string]$glyph, $font, $brush, $rect, $fmt) {
  if ($null -eq $g -or $null -eq $font -or -not $glyph) { return }
  $dy = [int]$script:IconDrop
  if ($dy -ne 0) {
    $rect = New-Object Drawing.RectangleF -ArgumentList @([single]$rect.X, [single]($rect.Y + $dy), [single]$rect.Width, [single]$rect.Height)
  }
  $was = $g.TextRenderingHint
  $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  try { $g.DrawString($glyph, $font, $brush, $rect, $fmt) }
  finally { $g.TextRenderingHint = $was }
}

# Where ink sits inside the box it was drawn in. Used twice: to find the difference between the
# two fonts, and never to move one glyph on its own.
function Get-InkCentre($bmp, [int]$x0, [int]$x1, [int]$y0, [int]$y1) {
  $lo = -1; $hi = -1
  for ($y = $y0; $y -le $y1; $y++) {
    $hit = $false
    for ($x = $x0; $x -le $x1; $x++) {
      $p = $bmp.GetPixel($x, $y)
      if (($p.R + $p.G + $p.B) -gt 60) { $hit = $true; break }
    }
    if ($hit) { if ($lo -lt 0) { $lo = $y }; $hi = $y }
  }
  if ($lo -lt 0) { return (($y0 + $y1 + 1) / 2) }
  return (($lo + $hi + 1) / 2)
}

# How far an icon has to move down to sit on the optical centre of the words beside it: both are
# centred in the same box by the layout, so what is left is a property of the two fonts. Measured
# once on a throw-away bitmap, against a sample of the words this language actually writes - a
# Latin sample leaves a CJK face a pixel or two off, because its glyphs fill their line box
# differently, and guessing which face is which would be the wrong kind of special case.
function Get-IconInkDrop($body, $icon, [string]$sample = '') {
  if ($null -eq $body -or $null -eq $icon) { return 0 }
  $text = [string]$sample
  if (-not $text) { $text = 'H' }
  $h = 40
  $bmp = New-Object Drawing.Bitmap 120, $h
  $g = [Drawing.Graphics]::FromImage($bmp)
  $sf = New-PickerStringFormats
  $white = New-Object Drawing.SolidBrush ([Drawing.Color]::White)
  try {
    $g.Clear([Drawing.Color]::Black)
    $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.DrawString($text, $body, $white, (New-Object Drawing.RectangleF 0, 0, 80, $h), $sf.Ellipsis)
    $textCentre = Get-InkCentre $bmp 0 79 0 ($h - 1)
    $g.Clear([Drawing.Color]::Black)
    $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.DrawString([string][char]0xE721, $icon, $white, (New-Object Drawing.RectangleF 80, 0, 20, $h), $sf.Center)
    $iconCentre = Get-InkCentre $bmp 80 99 0 ($h - 1)
    return ($textCentre - $iconCentre)
  } catch { return 0 } finally {
    $white.Dispose()
    $g.Dispose()
    $bmp.Dispose()
  }
}

# The icon of the empty state, centred on the given width. A glyph may paint outside its line
# box - the history arrow reaches above it - and DrawString into a rectangle clips whatever
# leaves the rectangle, which cut the top off that icon (measured: 277 ink pixels instead of
# 288). Measured and drawn from a point instead, so nothing is clipped. Returns the height the
# next line starts after.
function Draw-EmptyGlyph($g, [string]$glyph, $font, $brush, [int]$width, [int]$top, [int]$gap) {
  if (-not $glyph) { return 0 }
  $fmt = [Drawing.StringFormat]::GenericTypographic
  $sz = $g.MeasureString($glyph, $font, [int]::MaxValue, $fmt)
  $x = [int](($width - $sz.Width) / 2)
  if ($x -lt 0) { $x = 0 }
  $was = $g.TextRenderingHint
  $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  try { $g.DrawString($glyph, $font, $brush, (New-Object Drawing.PointF -ArgumentList @([single]$x, [single]$top)), $fmt) }
  finally { $g.TextRenderingHint = $was }
  return ([int][Math]::Ceiling($sz.Height) + $gap)
}

# The words an empty list shows: why it is empty and what the user can do about it. Plain
# text only, so the panel keeps the drawing and this stays measurable without a window.
function Get-EmptyState($entries, $query, [string]$q, $glyphs) {
  $s = @{ Glyph = ''; Title = ''; Sub = '' }
  if (@($entries).Count -eq 0) {
    $s.Glyph = [string]$glyphs.History
    $s.Title = (Get-UiText 'panel.empty.title.empty')
    $s.Sub = (Get-UiText 'panel.empty.sub.empty')
    return $s
  }
  if ($null -eq $query -or $query.Count -eq 0) { return $s }
  $s.Glyph = [string]$glyphs.Search
  if ($query.Bad.Count -gt 0) {
    $s.Title = (Get-UiText 'panel.empty.title.bad')
    $s.Sub = [string]$query.Bad[0]
    return $s
  }
  $s.Title = (Get-UiText 'panel.empty.title.noResults' @(([string]$q).Trim()))
  $s.Sub = (Get-UiText 'panel.empty.sub.noResults')
  return $s
}

function New-PickerStringFormats {  if ($script:PickerSf) { return $script:PickerSf }
  $none = New-Object Drawing.StringFormat
  $none.Trimming = [Drawing.StringTrimming]::None
  $none.FormatFlags = [Drawing.StringFormatFlags]::NoWrap
  $none.HotkeyPrefix = [Drawing.Text.HotkeyPrefix]::None
  $none.LineAlignment = [Drawing.StringAlignment]::Center

  $right = $none.Clone()
  $right.Alignment = [Drawing.StringAlignment]::Far

  $center = $none.Clone()
  $center.Alignment = [Drawing.StringAlignment]::Center

  $ell = New-Object Drawing.StringFormat
  $ell.Trimming = [Drawing.StringTrimming]::EllipsisCharacter
  $ell.FormatFlags = [Drawing.StringFormatFlags]::NoWrap
  $ell.HotkeyPrefix = [Drawing.Text.HotkeyPrefix]::None
  $ell.LineAlignment = [Drawing.StringAlignment]::Center

  $seg = [Drawing.StringFormat]::GenericTypographic.Clone()
  $seg.FormatFlags = [Drawing.StringFormatFlags]::NoWrap -bor [Drawing.StringFormatFlags]::MeasureTrailingSpaces
  $seg.HotkeyPrefix = [Drawing.Text.HotkeyPrefix]::None
  $seg.LineAlignment = [Drawing.StringAlignment]::Center

  $script:PickerSf = @{
    None     = $none
    Right    = $right
    Center   = $center
    Ellipsis = $ell
    Seg      = $seg
  }
  return $script:PickerSf
}

# key caps: rounded chip with a 1 px stroke, action text beside it (Win11 hint style).
# $limit is where the row has to stop, so the caller keeps control of the layout and this
# function never needs to know about the footer panels.
function Draw-KeyChips($g, [int]$x, [int]$cy, $pairs, $keyColor, $actionColor, [int]$limit) {
  $formats = New-PickerStringFormats
  $font = $script:FSmall
  if (-not $font) { return }
  if ($limit -lt (Px 60)) { return }
  $ui = Get-UiPalette
  $chipH = Px $script:Metric['ChipHeight']
  $big = New-Object Drawing.SizeF -ArgumentList @(1000, 100)
  # a caller that returns one pair from a function gets it flattened by PowerShell's list
  # handling, so ['Esc','Close'] arrives instead of [['Esc','Close']]. Re-pair flat strings,
  # and only when every entry is a string: a list that already holds pairs must be left alone.
  $list = @($pairs)
  $flat = ($list.Count -gt 0)
  foreach ($entry in $list) { if ($entry -isnot [string]) { $flat = $false; break } }
  if ($flat) {
    $repaired = @()
    for ($i = 0; ($i + 1) -lt $list.Count; $i += 2) { $repaired += ,@([string]$list[$i], [string]$list[$i + 1]) }
    $list = $repaired
  }
  foreach ($p in $list) {
    $key = [string]$p[0]
    $act = [string]$p[1]
    # measured with the format the text is drawn with: GenericTypographic leaves out the
    # padding GDI+ adds around a drawn string, and a rect that narrow cuts the last character
    $kw = [single]$g.MeasureString($key, $font, $big, $formats.None).Width
    $aw = [single]$g.MeasureString($act, $font, $big, $formats.None).Width
    $chipW = [int]($kw + (Px 14))
    if (($x + $chipW + (Px 6) + $aw) -gt $limit) { return }
    $chipY = $cy - [int]($chipH / 2)
    $kp = New-RoundPath $x $chipY $chipW $chipH (Px $script:Metric['CapRadius'])
    $kb = New-Object Drawing.SolidBrush $ui.KeyCapBg
    $g.FillPath($kb, $kp)
    $kb.Dispose()
    $kpen = New-Object Drawing.Pen $ui.KeyCapBorder, 1
    $g.DrawPath($kpen, $kp)
    $kpen.Dispose()
    $kp.Dispose()
    $kbr = New-Object Drawing.SolidBrush $keyColor
    $kr = New-Object Drawing.RectangleF -ArgumentList @([single]$x, [single]$chipY, [single]$chipW, [single]$chipH)
    $g.DrawString($key, $font, $kbr, $kr, $formats.Center)
    $kbr.Dispose()
    $x = $x + $chipW + (Px 6)
    $ar = New-Object Drawing.RectangleF -ArgumentList @([single]$x, [single]$chipY, [single]$aw, [single]$chipH)
    $abr = New-Object Drawing.SolidBrush $actionColor
    $g.DrawString($act, $font, $abr, $ar, $formats.None)
    $abr.Dispose()
    $x = $x + [int]$aw + (Px 16)
  }
}

# draw one label in pieces so the matched tokens can be tinted; the tail is trimmed with an
# ellipsis once the available width is exhausted.
function Draw-Highlight($g, [string]$text, $rect, [string[]]$tokens, $normal, $hit) {
  $formats = New-PickerStringFormats
  $font = $script:FBody
  if (-not $font) { return }
  $marks = Get-HitMarks $text $tokens
  $x = [single]$rect.X
  $limit = [single]$rect.Right
  $i = 0
  $n = $text.Length
  $big = New-Object Drawing.SizeF -ArgumentList @(100000, 100)
  while ($i -lt $n) {
    $isHit = $marks[$i]
    $j = $i
    while ($j -lt $n -and $marks[$j] -eq $isHit) { $j++ }
    $seg = $text.Substring($i, $j - $i)
    $size = $g.MeasureString($seg, $font, $big, $formats.Seg)
    $w = [single]$size.Width
    $brush = if ($isHit) { $hit } else { $normal }
    if (($x + $w) -gt $limit) {
      $rem = $limit - $x
      if ($rem -gt (Px 6)) {
        $r2 = New-Object Drawing.RectangleF -ArgumentList @($x, [single]$rect.Y, [single]$rem, [single]$rect.Height)
        $g.DrawString($seg, $font, $brush, $r2, $formats.Ellipsis)
      }
      return
    }
    $r2 = New-Object Drawing.RectangleF -ArgumentList @($x, [single]$rect.Y, [single]($w + (Px 2)), [single]$rect.Height)
    $g.DrawString($seg, $font, $brush, $r2, $formats.Seg)
    $x = $x + $w
    $i = $j
  }
}

# The backdrop of one row: the plugin's own tint first, then the hover / selection overlay
# as an eased alpha ramp. Keeping it here means the panel never has to know how a
# transition is painted, and the ramp stays a pure function of the two alphas.
function Draw-RowBackdrop($g, [int]$x, [int]$y, [int]$w, [int]$h, [int]$radius, $tint, $selBg, $hoverBg, [double]$selK, [double]$hoverK) {
  if ($null -ne $tint) {
    $brush = New-Object Drawing.SolidBrush $tint
    $path = New-RoundPath $x $y $w $h $radius
    $g.FillPath($brush, $path)
    $path.Dispose()
    $brush.Dispose()
  }
  $k = [Math]::Max($selK, $hoverK)
  if ($k -le 0.01) { return }
  $colour = $hoverBg
  if ($selK -ge $hoverK) { $colour = $selBg }
  $brush = New-Object Drawing.SolidBrush (Scale-Alpha $colour $k)
  $path = New-RoundPath $x $y $w $h $radius
  $g.FillPath($brush, $path)
  $path.Dispose()
  $brush.Dispose()
}

# The type ramp and the two font families, resolved once per process. Both windows the tool
# owns - the history panel and the settings window - draw with these, so the two cannot end up
# on different faces or sizes, and a second window costs no second font build.
#
# The family comes from the theme, then from what Windows ships: Segoe UI Variable Text is the
# Win11 face, Segoe UI the Win10 one, and the icon font follows the same rule (Fluent Icons on
# Win11, MDL2 on Win10). A theme that names a family the machine does not have falls through
# instead of drawing with a substituted face.
function Initialize-PanelFonts {
  if ($null -ne $script:FBody) { return $true }
  try { Use-Drawing } catch { }
  if (-not $script:UiFamily) {
    $script:UiFamily = 'Tahoma'
    $wantFace = [string]$script:ThemeFace.Font
    # a language may name the family it needs (a CJK language cannot use the Segoe faces); an
    # explicit face in the theme still wins, because that is the user speaking
    if (-not $wantFace -and (Get-Command Get-UiTextFont -ErrorAction SilentlyContinue)) { $wantFace = [string](Get-UiTextFont) }
    if ($wantFace -and (Test-Font $wantFace)) { $script:UiFamily = $wantFace }
    elseif (Test-Font 'Segoe UI Variable Text') { $script:UiFamily = 'Segoe UI Variable Text' }
    elseif (Test-Font 'Segoe UI') { $script:UiFamily = 'Segoe UI' }
    $wantIcon = [string]$script:ThemeFace.Icon
    $script:IconFamily = ''
    if ($wantIcon -and (Test-Font $wantIcon)) { $script:IconFamily = $wantIcon }
    elseif (Test-Font 'Segoe Fluent Icons') { $script:IconFamily = 'Segoe Fluent Icons' }
    elseif (Test-Font 'Segoe MDL2 Assets') { $script:IconFamily = 'Segoe MDL2 Assets' }
  }
  # Win11 type ramp by default; a theme may override any of the sizes through Fonts.
  $tf = $script:ThemeFonts
  $szBody = 10.5; $szSmall = 9.0; $szTiny = 9.0; $szTitle = 13.0
  $szIcon = 12.0; $szIconSmall = 10.0; $szIconBig = 24.0; $szIconTiny = 9.0
  if ($null -ne $tf) {
    if ($tf.ContainsKey('Body')) { $szBody = [double]$tf['Body'] }
    if ($tf.ContainsKey('Small')) { $szSmall = [double]$tf['Small'] }
    if ($tf.ContainsKey('Tiny')) { $szTiny = [double]$tf['Tiny'] }
    if ($tf.ContainsKey('Title')) { $szTitle = [double]$tf['Title'] }
    if ($tf.ContainsKey('Icon')) { $szIcon = [double]$tf['Icon'] }
    if ($tf.ContainsKey('IconSmall')) { $szIconSmall = [double]$tf['IconSmall'] }
    if ($tf.ContainsKey('IconBig')) { $szIconBig = [double]$tf['IconBig'] }
    if ($tf.ContainsKey('IconTiny')) { $szIconTiny = [double]$tf['IconTiny'] }
  }
  $script:FBody = New-Object Drawing.Font($script:UiFamily, [single]$szBody)
  $script:FSmall = New-Object Drawing.Font($script:UiFamily, [single]$szSmall)
  $script:FTiny = New-Object Drawing.Font($script:UiFamily, [single]$szTiny)
  $script:FTitle = New-Object Drawing.Font($script:UiFamily, [single]$szTitle, [Drawing.FontStyle]::Bold)
  if ($script:IconFamily) {
    # 12 pt renders a 16 px glyph, 10 pt a 13 px one, 9 pt the 12 px clear button a fluent
    # text field carries, 24 pt the empty-state art
    $script:FIcon = New-Object Drawing.Font($script:IconFamily, [single]$szIcon)
    $script:FIconSmall = New-Object Drawing.Font($script:IconFamily, [single]$szIconSmall)
    $script:FIconBig = New-Object Drawing.Font($script:IconFamily, [single]$szIconBig)
    $script:FIconTiny = New-Object Drawing.Font($script:IconFamily, [single]$szIconTiny)
  } else {
    $script:FIcon = $script:FBody
    $script:FIconSmall = $script:FSmall
    $script:FIconBig = $script:FTitle
    $script:FIconTiny = $script:FSmall
  }
  # one number for every icon in every surface: the distance between the ink of a line of body
  # text and the ink of an icon in the same box. The sample is the name the language file gives
  # itself, so the measurement is made against the script this window really draws - a Latin
  # sample would leave a CJK face a pixel or two off.
  $sample = ''
  if (Get-Command Get-UiTextName -ErrorAction SilentlyContinue) { $sample = [string](Get-UiTextName) }
  $script:IconDrop = [int][Math]::Round((Get-IconInkDrop $script:FBody $script:FIcon $sample))
  return $true
}

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
function Update-PanelRegion($form) {
  try {
    $old = $form.Region
    $form.Region = New-RoundRegion ([int]$form.ClientSize.Width) ([int]$form.ClientSize.Height) (Px $script:Metric['PanelRadius'])
    if ($null -ne $old) { $old.Dispose() }
  } catch { }
}

# The keys the in-place editor answers. One list, used by the panel footer and by the editor
# card that covers it, so the two cannot spell the same action differently - and every action
# is capitalised like the panel's own labels (Paste, Copy, Delete, Close).
function Get-EditHints {
  $pairs = New-Object System.Collections.Generic.List[object]
  $pairs.Add(@('Enter', 'Save'))
  $pairs.Add(@('Shift+Enter', 'Newline'))
  $pairs.Add(@('Esc', 'Cancel'))
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
    return ,@(@('Esc', 'Close'))
  }
  if ($compact) {
    # the compact footer has no room for five pairs and no count label to share the row with:
    # pick and leave first, then the two extras that change something
    $pairs = New-Object System.Collections.Generic.List[object]
    if ($selected -gt 1) {
      $pairs.Add(@('Ctrl+Enter', ('Copy ' + $selected.ToString())))
      $pairs.Add(@('Del', ('Delete ' + $selected.ToString())))
    } else {
      $pairs.Add(@('Enter', 'Paste'))
      $pairs.Add(@('Ctrl+Enter', 'Copy'))
      if ($editable) { $pairs.Add(@('F2', 'Edit')) }
    }
    if ($queryLen -gt 0) { $pairs.Add(@('Esc', 'Clear')) } else { $pairs.Add(@('Esc', 'Close')) }
    return $pairs.ToArray()
  }
  $multi = ($selected -gt 1)
  # the count is worked out first: inside the array below, '+ [string]$selected' would be read
  # as a second pair element and the chip would come out as 'Copy' and '3' side by side
  $copyLabel = 'Copy'
  $delLabel = 'Delete'
  if ($multi) {
    $copyLabel = 'Copy ' + $selected.ToString()
    $delLabel = 'Delete ' + $selected.ToString()
  }
  if ($ctrlHeld) {
    # Ctrl is held while these show; each chip spells the whole combination out, core ones
    # first, because the footer truncates and the plugin keys are the optional ones
    # a list, not "@(@(pair))": a one-element array of arrays is flattened by the array
    # subexpression, and the first chip then came out as two loose strings
    $pairs = New-Object System.Collections.Generic.List[object]
    $pairs.Add(@('Ctrl+1-9,0', 'Pick'))
    $pairs.Add(@('Ctrl+Enter', $copyLabel))
    # undo is only worth a chip while the setting allows it
    if ($undoOn) { $pairs.Add(@('Ctrl+Z', 'Undo')) }
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
    $out.Add(@('Enter', 'Paste'))
    $out.Add(@('Ctrl+Enter', $copyLabel))
    # only a plain text row has anything the editor can show and write back
    if ($editable) { $out.Add(@('F2', 'Edit')) }
  }
  $out.Add(@('Del', $delLabel))
  if ($queryLen -gt 0) { $out.Add(@('Esc', 'Clear')) } else { $out.Add(@('Esc', 'Close')) }
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

# The words an empty list shows: why it is empty and what the user can do about it. Plain
# text only, so the panel keeps the drawing and this stays measurable without a window.
function Get-EmptyState($entries, $query, [string]$q, $glyphs) {
  $s = @{ Glyph = ''; Title = ''; Sub = '' }
  if (@($entries).Count -eq 0) {
    $s.Glyph = [string]$glyphs.History
    $s.Title = 'Clipboard history is empty'
    $s.Sub = 'Copy something and it will appear here'
    return $s
  }
  if ($null -eq $query -or $query.Count -eq 0) { return $s }
  $s.Glyph = [string]$glyphs.Search
  if ($query.Bad.Count -gt 0) {
    $s.Title = 'The search was not understood'
    $s.Sub = [string]$query.Bad[0]
    return $s
  }
  $s.Title = 'No results for "' + ([string]$q).Trim() + '"'
  $s.Sub = 'Try another keyword, or press Esc to clear the search'
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

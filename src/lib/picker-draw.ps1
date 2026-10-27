# lib/picker-draw.ps1 - the panel's reusable drawing pieces.
#
# Everything here takes a Graphics plus plain values: no form, no list, no per-open state.
# That is what makes these callable from anywhere (and testable) instead of only from the
# one function that happens to own the window.
#
# Shared GDI objects live on $script:PickerSf / $script:FBody and are created once, because
# measuring every highlighted segment with a freshly built StringFormat would allocate on
# every paint.

# One StringFormat set for the whole process. Idempotent: Show-Picker calls it every time
# the panel opens and gets the same objects back.
function New-PickerStringFormats {
  if ($script:PickerSf) { return $script:PickerSf }
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
  $chipH = Px 18
  $big = New-Object Drawing.SizeF -ArgumentList @(1000, 100)
  foreach ($p in @($pairs)) {
    $key = [string]$p[0]
    $act = [string]$p[1]
    $kw = [single]$g.MeasureString($key, $font, $big, $formats.Seg).Width
    $aw = [single]$g.MeasureString($act, $font, $big, $formats.Seg).Width
    $chipW = [int]($kw + (Px 14))
    if (($x + $chipW + (Px 6) + $aw) -gt $limit) { return }
    $chipY = $cy - [int]($chipH / 2)
    $kp = New-RoundPath $x $chipY $chipW $chipH (Px 4)
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

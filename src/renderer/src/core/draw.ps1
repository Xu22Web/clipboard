Export-Function Get-Brush, New-PickerStringFormats, Scale-Alpha
# renderer\src\core\draw.ps1 - the three things every painted surface needs to start from.
#
# They lived in the panel because that is where they were first written: a brush cache, the
# string formats a measured label is drawn with, and a colour at a fraction of its own alpha.
# None of them knows what a panel is, and core\widgets.ps1 needs all three, which made the
# framework depend on the window that used it - the one edge that pointed the wrong way.
#
# What stays here is what a Graphics and a colour can answer on their own: no layout, no theme
# lookup, no window state.

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

# the same colour at a fraction of its own alpha: a transition fades, it never recolours
function Scale-Alpha($color, [double]$k) {
  if ($null -eq $color) { return [Drawing.Color]::FromArgb(0, 0, 0, 0) }
  if ($k -le 0) { return [Drawing.Color]::FromArgb(0, $color.R, $color.G, $color.B) }
  if ($k -ge 1) { return $color }
  return [Drawing.Color]::FromArgb([int][Math]::Round([double]$color.A * $k), $color.R, $color.G, $color.B)
}

# The format set every measured label is drawn with, built once and kept: GenericTypographic
# leaves out the padding GDI+ adds around a string, so a width taken here is the width of the
# words. The name still says Picker because every call site and every test uses it; renaming it
# would be a change with no behaviour behind it.
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

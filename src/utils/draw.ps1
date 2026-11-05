# utils/draw.ps1 - pixel and shape helpers: one design value scaled to the current DPI, one
# rounded rectangle as a path or as a region.
#
# No panel state is read here: the DPI factor comes from $script:UiScale, which
# Initialize-Dpi (utils/native.ps1) sets once per process, and everything else is arithmetic
# plus a GraphicsPath the caller owns and disposes.

# scale one design pixel value (96 dpi baseline) to the current DPI
function Px([double]$v) {
  if ($v -eq 0) { return 0 }
  $n = [int][Math]::Round($v * [double]$script:UiScale)
  if ($n -lt 1) { return 1 }
  return $n
}

function New-RoundPath([int]$x, [int]$y, [int]$w, [int]$h, [int]$r) {
  if ($w -lt 2) { $w = 2 }
  if ($h -lt 2) { $h = 2 }
  if (($r * 2) -gt $h) { $r = [int]($h / 2) }
  if (($r * 2) -gt $w) { $r = [int]($w / 2) }
  $d = [Math]::Max(1, $r * 2)
  $p = New-Object Drawing.Drawing2D.GraphicsPath
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

function New-RoundRegion([int]$w, [int]$h, [int]$r) {
  $p = New-RoundPath 0 0 $w $h $r
  $reg = New-Object Drawing.Region -ArgumentList $p
  $p.Dispose()
  return $reg
}

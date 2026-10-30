# lib/preview.ps1 - the hover preview: a card beside the panel that shows the head of the
# entry under the cursor.
#
# Hover changes many times a second while the mouse sweeps the list, so nothing here may run
# per mouse move: the picker asks once per tick and only after the cursor has rested, the
# card is one reusable window that is hidden instead of disposed, and the text of a record is
# prepared once and kept. A payload is clamped to PreviewChars *before* it is split, so a
# 200 KB entry costs exactly what a 200 character one costs.
#
# The card never activates (Cb.FluentForm is WS_EX_NOACTIVATE) and is raised with a
# no-activate SetWindowPos, or it would steal the foreground from the window the user is
# working in - the same rule the panel itself follows.

# One panel's preview: the window plus what it is showing. Held by the picker, given back to
# every call here, so no state lives in this file.
function New-PreviewState {
  return @{ Win = $null; Key = -1; Lines = @(); Head = ''; Cfg = $null }
}

# The lines the card shows, already cut to what fits. Pure: no window, no measuring, so it
# can be unit tested and its cost is bounded by PreviewChars alone.
function Get-PreviewLines([string]$payload, [int]$cols, [int]$maxLines) {
  $out = New-Object System.Collections.Generic.List[string]
  if ([string]::IsNullOrEmpty($payload) -or $cols -lt 12 -or $maxLines -lt 1) { return , $out }
  $text = $payload
  # a file list is stored as one path per line behind a marker; the card names the files
  if ($text[0] -eq [char]1) {
    $names = @($text.Substring(1) -split "`n" | Where-Object { $_ } | ForEach-Object { Split-Path -Leaf $_ })
    $text = '[files] ' + ($names -join '  ')
  }
  $more = ($text.Length -gt $script:PreviewChars)
  if ($more) { $text = $text.Substring(0, $script:PreviewChars) }
  $text = $text -replace "`r`n", "`n"
  $text = $text -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ' '
  $text = $text -replace "`t", '    '
  $cutLine = $false
  foreach ($line in ($text -split "`n")) {
    if ($out.Count -ge $maxLines) { $more = $true; break }
    # a line that does not fit ends in '...' itself, which needs no extra marker line below
    if ($line.Length -gt $cols) { $out.Add($line.Substring(0, $cols - 3) + '...'); $cutLine = $true }
    else { $out.Add($line); $cutLine = $false }
  }
  if ($more -and -not $cutLine) {
    if ($out.Count -lt $maxLines) { $out.Add('...') } elseif ($out.Count -gt 0) { $out[$out.Count - 1] = '...' }
  }
  return , $out
}

# the one-line caption above the text: what it is and how big it is, counted on the clamped
# head only so the caption costs nothing on a large entry
function Get-PreviewInfo([string]$payload) {
  if ([string]::IsNullOrEmpty($payload)) { return '' }
  $text = $payload
  if ($text.Length -gt $script:PreviewChars) { $text = $text.Substring(0, $script:PreviewChars) }
  $kind = 'text'
  if ($payload[0] -eq [char]1) { $kind = 'files' }
  $lines = 1
  $at = $text.IndexOf("`n")
  while ($at -ge 0) { $lines++; $at = $text.IndexOf("`n", $at + 1) }
  $chars = if ($payload.Length -gt $script:PreviewChars) { $script:PreviewChars.ToString() + '+' } else { $payload.Length.ToString() }
  $word = if ($lines -eq 1) { ' line' } else { ' lines' }
  return ($kind + ' - ' + $chars + ' chars - ' + $lines + $word)
}

# Everything the card draws with, built once per panel: the geometry from the caller's
# scale, the two brushes, and how many characters fit the card width.
function New-PreviewConfig($ui, $sf, $font, $smallFont) {
  $cfg = @{ W = (Px 420); Pad = (Px 12); LineH = (Px 18); Gap = (Px 10); Cols = 56; MaxLines = 12; Sf = $sf
    Bg = $ui.Surface; Border = $ui.Border; Font = $font; Small = $smallFont }
  $cfg.InkBrush = New-Object Drawing.SolidBrush $ui.Text
  $cfg.DimBrush = New-Object Drawing.SolidBrush $ui.Dim
  # how many characters fit: measured once with the same GDI+ text path the card draws with,
  # because TextRenderer would be a different font metric and cut the lines short
  $bmp = New-Object Drawing.Bitmap 1, 1
  try {
    $mg = [Drawing.Graphics]::FromImage($bmp)
    $charW = [single]($mg.MeasureString('0000000000', $font).Width / 10)
    $mg.Dispose()
  } catch { $charW = 8 } finally { $bmp.Dispose() }
  if ($charW -gt 1) { $cfg.Cols = [Math]::Max(12, [int](($cfg.W - 2 * $cfg.Pad) / $charW)) }
  $roomH = [Math]::Min((Px 460), [int]([Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea.Height * 0.55))
  $cfg.MaxLines = [Math]::Max(2, [int](($roomH - 2 * $cfg.Pad - $cfg.LineH) / $cfg.LineH))
  return $cfg
}

function Invoke-PreviewPaint($win, $e) {
  $ps = $win.Tag
  if ($null -eq $ps -or $null -eq $ps.Cfg) { return }
  $c = $ps.Cfg
  $g = $e.Graphics
  $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  # Fill through Clear: the window carries the same rounded region as the panel, so this
  # covers the whole silhouette without leaving a rim of the form colour in any corner.
  $g.Clear($c.Bg)
  $path = New-RoundPath 0 0 ($win.ClientSize.Width - 1) ($win.ClientSize.Height - 1) (Px 8)
  $pen = New-Object Drawing.Pen $c.Border, 1
  try {
    $g.DrawPath($pen, $path)
  } finally {
    $pen.Dispose()
    $path.Dispose()
  }
  $y = $c.Pad
  $caption = New-Object Drawing.RectangleF -ArgumentList @([single]$c.Pad, [single]$y, [single]($c.W - 2 * $c.Pad), [single]$c.LineH)
  $g.DrawString($ps.Head, $c.Small, $c.DimBrush, $caption, $c.Sf)
  $y += $c.LineH
  foreach ($line in $ps.Lines) {
    $rect = New-Object Drawing.RectangleF -ArgumentList @([single]$c.Pad, [single]$y, [single]($c.W - 2 * $c.Pad), [single]$c.LineH)
    $g.DrawString($line, $c.Font, $c.InkBrush, $rect, $c.Sf)
    $y += $c.LineH
  }
}

# the card is created once per panel and then only hidden: making a window per hover would
# cost more than everything else here put together
function New-PreviewWindow($ps) {
  $w = New-Object Cb.FluentForm
  $w.FormBorderStyle = 'None'
  $w.StartPosition = 'Manual'
  $w.ShowInTaskbar = $false
  $w.Text = 'clipboard preview'
  $w.AccessibleName = 'clipboard preview'
  $w.Tag = $ps
  $w.Add_Paint({ param($s, $e) Invoke-PreviewPaint $s $e })
  $ps.Win = $w
  return $w
}

function Place-Preview($x, $y, $w, $h, $area) {
  if ($x + $w -gt $area.Right) { $x = $area.Right - $w }
  if ($x -lt $area.Left) { $x = $area.Left }
  if ($y + $h -gt $area.Bottom) { $y = $area.Bottom - $h }
  if ($y -lt $area.Top) { $y = $area.Top }
  return @{ X = $x; Y = $y }
}

# Show the card for one record, or do nothing when it already shows it. Everything expensive
# happens on a record change and nowhere else.
function Update-Preview($ps, $record, $anchorTop, $cfg, $panel) {
  if ($null -eq $ps -or $null -eq $record -or $null -eq $cfg) { return }
  $key = [int]$record.Key
  if ($key -eq $ps.Key) { return }
  $ps.Key = $key
  $ps.Lines = Get-PreviewLines ([string]$record.Payload) $cfg.Cols $cfg.MaxLines
  $ps.Head = Get-PreviewInfo ([string]$record.Payload)
  if ($ps.Lines.Count -eq 0) { Hide-Preview $ps; return }
  $ps.Cfg = $cfg
  $h = $cfg.Pad * 2 + $cfg.LineH * (1 + $ps.Lines.Count)
  $w = $cfg.W
  # beside the panel, on the side that has room; never under the cursor, so the row keeps
  # its hover while the card is up
  $x = $panel.Right + $cfg.Gap
  if ($x + $w -gt $cfg.Area.Right) { $x = $panel.Left - $cfg.Gap - $w }
  $at = Place-Preview $x ($anchorTop - (Px 4)) $w $h $cfg.Area
  $win = $ps.Win
  if ($null -eq $win -or $win.IsDisposed) { $win = New-PreviewWindow $ps }
  if ($win.BackColor -ne $cfg.Bg) { $win.BackColor = $cfg.Bg }
  $win.SetBounds($at.X, $at.Y, $w, $h)
  Set-CardRegion $win (Px 8)
  if (-not $win.Visible) { $win.Show() }
  [void][Cb.Win]::SetWindowPos($win.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13)
  $win.Invalidate()
}

# The card needs the panel's silhouette: a borderless form is a square window, so without a
# region the light form colour shows in the four corners and the drawn border is clipped. The
# region is replaced on every resize, and the old handle goes with it (WinForms keeps none).
function Set-CardRegion($win, [int]$r) {
  try {
    $old = $win.Region
    $win.Region = New-RoundRegion $win.Width $win.Height $r
    if ($null -ne $old) { $old.Dispose() }
  } catch { }
}

function Hide-Preview($ps) {
  if ($null -eq $ps) { return }
  $ps.Key = -1
  $win = $ps.Win
  try { if ($null -ne $win -and -not $win.IsDisposed -and $win.Visible) { $win.Hide() } } catch { }
}

function Close-Preview($ps) {
  if ($null -eq $ps) { return }
  $win = $ps.Win
  $ps.Win = $null
  $ps.Key = -1
  $ps.Lines = @()
  $ps.Cfg = $null
  # the rounded region is ours: WinForms keeps the handle after Dispose, so drop it here
  try {
    if ($null -ne $win -and -not $win.IsDisposed) {
      $rgn = $win.Region
      $win.Dispose()
      if ($null -ne $rgn) { $rgn.Dispose() }
    }
  } catch { }
}

# lib/panel/preview.ps1 - the hover preview: a card beside the panel that shows the head of the
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
  return @{ Win = $null; Key = -1; Lines = @(); Head = ''; Cfg = $null; Kind = 'text'; Ref = ''; Bmp = $null
    Panel = $null; Anchor = 0; Pending = $false; JobPath = ''; JobKey = -1; Handle = $null; RS = $null; Shell = $null
    FadeAt = $null; FadeBmp = $null }
}

# Whether the card may stand a picture in for a formatted entry. Only an entry with no rtf
# at all does: a document that has one - even one too big to lay out - keeps its words on the
# card, so a formatted entry never reads as a picture.
function Test-RichPictureStandIn([string]$mode) {
  return ($mode -ceq 'none')
}

# What the card shows for one record: its kind, the caption, the text lines and the media
# reference a bitmap is loaded from. Images and formatted text are recognised here so the
# paint path only has to know "bitmap or lines".
function Get-PreviewContent($record, [int]$cols, [int]$maxLines) {
  $out = @{ Kind = 'text'; Head = ''; Lines = @(); Ref = '' }
  if ($null -eq $record) { return $out }
  $payload = [string]$record.Payload
  $img = $null
  if (Get-Command Get-ImageRef -ErrorAction SilentlyContinue) { $img = Get-ImageRef $payload }
  if ($null -ne $img) {
    $out.Kind = 'image'
    $out.Ref = [string]$img.Sha1
    $out.Head = 'image - ' + [string]$img.W + 'x' + [string]$img.H + ' - ' + [string]$img.Fmt + ' - ' + (Format-Size $img.Bytes)
    return $out
  }
  $out.Lines = Get-PreviewLines $payload $cols $maxLines
  $out.Head = Get-PreviewInfo $payload
  $rich = ''
  if ($null -ne $record.PSObject.Properties['Rich']) { $rich = [string]$record.Rich }
  if ($rich) {
    $out.Kind = 'rich'
    $out.Ref = $rich
    $out.Head = 'formatted - ' + $out.Head
  }
  return $out
}

# The lines the card shows, already cut to what fits. Pure: no window, no measuring, so it
# can be unit tested and its cost is bounded by PreviewChars alone.
function Get-PreviewLines([string]$payload, [int]$cols, [int]$maxLines) {
  $out = New-Object System.Collections.Generic.List[string]
  if ([string]::IsNullOrEmpty($payload) -or $cols -lt 12 -or $maxLines -lt 1) { return , $out }
  $text = $payload
  # a file list is stored as one path per line behind a marker; the card names the files
  if (Test-FilePayload $text) {
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
  if (Test-FilePayload $payload) { $kind = 'files' }
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
  $cfg = @{ W = (Px 420); Pad = (Px 12); LineH = (Px 20); Gap = (Px 10); Cols = 56; MaxLines = 12; Sf = $sf
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
  # the area a picture or a rendered page may take: the same room the text lines use
  $cfg.ImgH = [Math]::Max((Px 120), [Math]::Min((Px 340), $roomH - 2 * $cfg.Pad - $cfg.LineH))
  # a document keeps its own ink colours, so its page stays light on any theme
  $cfg.Paper = [Drawing.Color]::White
  # once per panel, not once per hover: the card cache is derived data with a budget
  Clear-OldPreviewCache
  return $cfg
}

# A Win11 flyout fades in over about this long. The card cannot use the window opacity for
# it - that turns the window layered and breaks the no-activate model - so the content is
# drawn into a bitmap and blitted with a colour matrix instead.
$script:PreviewFade = 140

function Get-PreviewAlpha($ps) {
  if ($null -eq $ps -or $null -eq $ps.FadeAt) { return 255 }
  $ms = ((Get-Date) - $ps.FadeAt).TotalMilliseconds
  if ($ms -ge $script:PreviewFade) { return 255 }
  if ($ms -le 0) { return 0 }
  return [int](255 * ($ms / $script:PreviewFade))
}

function Invoke-PreviewPaint($win, $e) {
  $ps = $win.Tag
  if ($null -eq $ps -or $null -eq $ps.Cfg) { return }
  $c = $ps.Cfg
  $g = $e.Graphics
  $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $alpha = Get-PreviewAlpha $ps
  if ($alpha -ge 255) {
    Draw-CardContent $g $win $ps $c
    return
  }
  # the card surface is opaque from the first frame and only what sits on it fades in, so
  # the desktop never shows through the window and nothing has to be layered
  $g.Clear($c.Bg)
  $w = $win.ClientSize.Width
  $h = $win.ClientSize.Height
  if ($w -lt 2 -or $h -lt 2) { return }
  $buf = $ps.FadeBmp
  if ($null -eq $buf -or $buf.Width -ne $w -or $buf.Height -ne $h) {
    if ($null -ne $buf) { try { $buf.Dispose() } catch { } }
    $buf = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $ps.FadeBmp = $buf
  }
  $bg = $null
  $ia = $null
  try {
    $bg = [Drawing.Graphics]::FromImage($buf)
    $bg.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $bg.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    Draw-CardContent $bg $win $ps $c
    $cm = New-Object Drawing.Imaging.ColorMatrix
    $cm.Matrix33 = [single]($alpha / 255.0)
    $ia = New-Object Drawing.Imaging.ImageAttributes
    $ia.SetColorMatrix($cm)
    $dest = New-Object Drawing.Rectangle 0, 0, $w, $h
    $g.DrawImage($buf, $dest, 0, 0, $w, $h, [Drawing.GraphicsUnit]::Pixel, $ia)
  } catch {
  } finally {
    if ($null -ne $ia) { try { $ia.Dispose() } catch { } }
    if ($null -ne $bg) { $bg.Dispose() }
  }
}

# everything the card shows, on a surface that is already there: the rounded outline, the
# caption and the page or the text lines
function Draw-CardContent($g, $win, $ps, $c) {
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
  # the caption line is the card's own chrome, so the wait belongs there: a line inside the
  # body would look like content the entry does not have
  $head = [string]$ps.Head
  if ($ps.Pending) { $head = $head + '  - rendering the preview...' }
  $g.DrawString($head, $c.Small, $c.DimBrush, $caption, $c.Sf)
  $y += $c.LineH
  $bmp = $ps.Bmp
  if ($null -ne $bmp) {
    # already scaled to the card width by lib/media.ps1: painting it is a blit, not a resize.
    # A 4 px round plus the card's own 1 px stroke keeps a document page a content block
    # instead of a white slab glued to the surface.
    $px = [int]$c.Pad
    $py = [int]$y
    if ($bmp.Width -lt 8 -or $bmp.Height -lt 8) {
      try { $g.DrawImageUnscaled($bmp, $px, $py) } catch { }
      return
    }
    $frame = New-RoundPath $px $py ($bmp.Width - 1) ($bmp.Height - 1) (Px 4)
    $edge = $null
    try {
      $g.SetClip($frame)
      try { $g.DrawImageUnscaled($bmp, $px, $py) } catch { }
      $g.ResetClip()
      $edge = New-Object Drawing.Pen $c.Border, 1
      $g.DrawPath($edge, $frame)
    } catch {
    } finally {
      if ($null -ne $edge) { try { $edge.Dispose() } catch { } }
      $frame.Dispose()
    }
    return
  }
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
  $c = Get-PreviewContent $record $cfg.Cols $cfg.MaxLines
  $ps.Kind = [string]$c.Kind
  $ps.Ref = [string]$c.Ref
  $ps.Lines = $c.Lines
  $ps.Head = [string]$c.Head
  $ps.Bmp = $null
  if ($ps.Kind -ne 'text') {
    $maxW = $cfg.W - 2 * $cfg.Pad
    $maxH = $cfg.ImgH
    $bmp = $null
    if ($ps.Kind -eq 'image') { $bmp = Get-ImagePreviewBitmap $ps.Ref $maxW $maxH }
    else {
      # Three cards by size: laid out with its pictures, laid out with a marker where each
      # picture was, or the words alone when there is no rtf to lay out. The page is built in
      # a runspace of its own and kept on disk, so the panel never lays one out itself.
      $mode = Get-RichPreviewMode (Get-RichRtfSize $ps.Ref)
      if ($mode -ceq 'full' -or $mode -ceq 'plain') {
        $path = Get-PreviewCachePath $ps.Ref $maxW $maxH $mode
        $bmp = Read-PreviewCache $path
        if ($null -eq $bmp -and (Start-CardJob $ps $ps.Ref $maxW $maxH $cfg $mode)) {
          $ps.Pending = $true
          $ps.JobPath = $path
          $ps.JobKey = $key
        }
      }
      # A formatted entry is never shown as a picture: with an rtf in it the card shows the
      # page, or its words while the page is on its way - not one of the blocks it carries.
      # Only an entry with no rtf at all has nothing else to show (an Excel copy brings html
      # and a metafile, never rtf).
      if ($null -eq $bmp -and (Test-RichPictureStandIn $mode)) { $bmp = Get-RichImageBitmap $ps.Ref $maxW $maxH }
      # the first picture stands in for the document, so the card hugs it like an image card
      if ($null -ne $bmp) { $ps.Kind = 'image' }
    }
    if ($null -ne $bmp) {
      $ps.Bmp = $bmp
    } else {
      # the file is gone, or the format cannot be laid out: show the words we already have
      $ps.Kind = 'text'
      if ($ps.Lines.Count -eq 0) {
        $list = New-Object System.Collections.Generic.List[string]
        $list.Add('the preview is not available')
        $ps.Lines = $list
      }
    }
  }
  if ($null -eq $ps.Bmp -and $ps.Lines.Count -eq 0) { Hide-Preview $ps; return }
  $ps.Cfg = $cfg
  $ps.Panel = $panel
  $ps.Anchor = $anchorTop
  Show-PreviewCard $ps $cfg $panel $anchorTop
}

# Place the card beside the panel and draw it. Separate from Update-Preview because a
# background render finishes later and only has to repaint, not recompute the content.
function Show-PreviewCard($ps, $cfg, $panel, $anchorTop) {
  if ($null -ne $ps.Bmp) {
    # an image card hugs the picture; a rendered page uses the full card width
    $w = $cfg.W
    if ($ps.Kind -eq 'image') { $w = [Math]::Max((Px 220), [Math]::Min($cfg.W, $ps.Bmp.Width + 2 * $cfg.Pad)) }
    $h = $cfg.Pad * 2 + $cfg.LineH + $ps.Bmp.Height
  } else {
    $w = $cfg.W
    $h = $cfg.Pad * 2 + $cfg.LineH * (1 + $ps.Lines.Count)
  }
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
  # a flyout fades in; with animations off the card is simply there
  $ps.FadeAt = $(if ($script:Animations) { Get-Date } else { $null })
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
  $ps.FadeAt = $null
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
  $ps.Pending = $false
  $ps.Handle = $null
  $ps.FadeAt = $null
  if ($null -ne $ps.FadeBmp) { try { $ps.FadeBmp.Dispose() } catch { } }
  $ps.FadeBmp = $null
  try { if ($null -ne $ps.RS) { $ps.RS.Dispose() } } catch { }
  $ps.RS = $null
  $ps.Shell = $null
  # the rounded region is ours: WinForms keeps the handle after Dispose, so drop it here
  try {
    if ($null -ne $win -and -not $win.IsDisposed) {
      $rgn = $win.Region
      $win.Dispose()
      if ($null -ne $rgn) { $rgn.Dispose() }
    }
  } catch { }
  # the card is the only consumer of a decoded image or a rendered page
  if (Get-Command Clear-MediaCache -ErrorAction SilentlyContinue) {
    try { Clear-MediaCache } catch { }
  }
}

# ---- a card that is too slow to build inside the tick loop -------------------
# A page of screenshots needs the pictures re-spelled as bitmaps before the layout engine
# will draw them, and that is a second or more of pure PowerShell - on the UI thread it
# froze the panel while the user was only passing over the row. So the work runs in a
# runspace of its own, the card shows its words with a "rendering" line meanwhile, and the
# result lands on disk: the next hover - in this session or after a restart - is a file read.
#
# The folder is %TEMP%\clipboard-preview. It is derived data - nothing about the history
# depends on it - so it belongs beside the paste folder and not in data\media, which is
# reclaimed by reference. A missing file is not a problem: the card simply renders the page
# again, which is exactly the first-hover path.
function Get-PreviewCacheDir {
  $base = ''
  try { $base = [IO.Path]::GetTempPath() } catch { $base = '' }
  # no temp folder at all (locked-down profile): the data folder is the only writable one
  if (-not $base) { $base = $StoreDir }
  $dir = Join-Path $base 'clipboard-preview'
  if (-not (Test-Path -LiteralPath $dir)) {
    try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
  }
  return $dir
}

# the tag is part of the key: when the card is drawn differently, the old pictures are
# ignored instead of being shown with the previous look
$script:PreviewCacheTag = 'v1'

function Get-PreviewCachePath([string]$ref, [int]$w, [int]$h, [string]$mode = 'full') {
  # the store path is in the key too: two copies of the tool share one temp folder, and a
  # sandbox or a test run must not read pictures of the real history
  $seed = $script:PreviewCacheTag + '|' + $mode + '|' + $StoreDir + '|' + $ref + '|' + [string]$w + 'x' + [string]$h
  $sha = Get-MediaSha1 $Utf8.GetBytes($seed) $null
  return (Join-Path (Get-PreviewCacheDir) ($sha + '.png'))
}

# a rendered card that was built before, detached from the file so the cache entry can be
# pruned or replaced while the bitmap is on screen
function Read-PreviewCache([string]$path) {
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
  $img = $null
  try {
    $img = [Drawing.Image]::FromFile($path)
    return (New-Object Drawing.Bitmap $img)
  } catch {
    return $null
  } finally {
    if ($null -ne $img) { try { $img.Dispose() } catch { } }
  }
}

# A rendered card is derived data, so it is kept within a budget rather than forever: a week
# without a look, or the folder growing past these numbers, and the oldest files go. Two
# hundred cards is a few screens of history, and a card is tens of KB unless it is a page.
$script:PreviewCacheMaxFiles = 200
$script:PreviewCacheMaxBytes = 33554432

function Clear-OldPreviewCache {
  try {
    $dir = Get-PreviewCacheDir
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $cut = [DateTime]::UtcNow.AddDays(-7)
    $keep = New-Object System.Collections.Generic.List[object]
    $bytes = [long]0
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.png' -ErrorAction SilentlyContinue)) {
      if ($f.LastWriteTimeUtc -lt $cut) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue } catch { }
      } else {
        $keep.Add($f)
        $bytes += [long]$f.Length
      }
    }
    if ($keep.Count -le $script:PreviewCacheMaxFiles -and $bytes -le $script:PreviewCacheMaxBytes) { return }
    # over the budget: oldest first, because that is the one least likely to come back
    foreach ($f in @($keep | Sort-Object LastWriteTimeUtc)) {
      if ($keep.Count -le $script:PreviewCacheMaxFiles -and $bytes -le $script:PreviewCacheMaxBytes) { break }
      try {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        $bytes -= [long]$f.Length
        [void]$keep.Remove($f)
      } catch { }
    }
  } catch { }
}

# The job body. A runspace of its own, so the parse of the library (about a second) and the
# layout both happen off the panel thread; the result is handed back as a Bitmap, which needs
# no serialisation because both runspaces live in one process. The C# layer is already
# compiled in this process, so the copy compiles nothing.
$script:CardJobScript = @'
param($lib, $ref, $w, $h, $fontName, $fontSize, $paperArgb, $mode)
if (-not $script:CardJobReady) {
  . $lib -Library
  $script:NativeReady = $true
  Load-Forms
  $script:CardJobReady = $true
}
$font = $null
if ($fontName) { $font = New-Object Drawing.Font $fontName, ([single]$fontSize) }
return (Get-RichPreviewBitmap $ref $w $h $font ([Drawing.Color]::FromArgb($paperArgb)) $mode)
'@

function Start-CardJob($ps, [string]$ref, [int]$w, [int]$h, $cfg, [string]$mode = 'full') {
  try {
    # one pipeline per runspace: a job that is still running keeps the row on its text card,
    # and a finished one is collected first (Sync drops it unless the card is still that row)
    if ($null -ne $ps.Handle) {
      if (-not $ps.Handle.IsCompleted) { return $false }
      [void](Step-PreviewCard $ps)
    }
    if ($null -eq $ps.RS) {
      $rs = [runspacefactory]::CreateRunspace()
      $rs.ApartmentState = [Threading.ApartmentState]::STA
      $rs.ThreadOptions = 'ReuseThread'
      $rs.Open()
      $ps.RS = $rs
      $shell = [powershell]::Create()
      $shell.Runspace = $rs
      $ps.Shell = $shell
    }
    $shell = $ps.Shell
    $name = ''
    $size = 9
    if ($null -ne $cfg.Font) { $name = [string]$cfg.Font.Name; $size = $cfg.Font.Size }
    $paper = $cfg.Paper
    if ($null -eq $paper) { $paper = [Drawing.Color]::White }
    $shell.Commands.Clear()
    [void]$shell.AddScript($script:CardJobScript)
    [void]$shell.AddArgument((Join-Path $Root 'clipboard.ps1'))
    [void]$shell.AddArgument($ref)
    [void]$shell.AddArgument($w)
    [void]$shell.AddArgument($h)
    [void]$shell.AddArgument($name)
    [void]$shell.AddArgument($size)
    [void]$shell.AddArgument([int]$paper.ToArgb())
    [void]$shell.AddArgument($mode)
    $ps.Handle = $shell.BeginInvoke()
    return $true
  } catch {
    Write-Log ('card job failed to start: ' + $_.Exception.Message)
    return $false
  }
}

# Called from the panel's tick. Two jobs: it keeps the fade moving (a repaint per tick for
# the 140 ms it lasts) and it turns the card into the page when the background render is
# done, or leaves its words alone when there is no page to draw.
function Step-PreviewCard($ps) {
  if ($null -eq $ps) { return $false }
  $moved = $false
  if ($null -ne $ps.FadeAt) {
    $win = $ps.Win
    if ($null -ne $win -and -not $win.IsDisposed -and $win.Visible) {
      if (((Get-Date) - $ps.FadeAt).TotalMilliseconds -ge $script:PreviewFade) { $ps.FadeAt = $null }
      try { $win.Invalidate() } catch { }
      $moved = $true
    } else {
      $ps.FadeAt = $null
    }
  }
  if ($null -eq $ps.Handle) { return $moved }
  if (-not $ps.Handle.IsCompleted) { return $moved }
  $bmp = $null
  try {
    $res = $ps.Shell.EndInvoke($ps.Handle)
    if ($null -ne $res -and $res.Count -gt 0) {
      $last = $res[$res.Count - 1]
      if ($null -ne $last) { $bmp = $last.PSObject.BaseObject }
    }
  } catch {
    Write-Log ('card job failed: ' + $_.Exception.Message)
  }
  $ps.Handle = $null
  $ps.Pending = $false
  if ($null -eq $bmp -or -not ($bmp -is [Drawing.Bitmap])) { return $moved }
  # the picture is worth keeping even when the card has moved on to another row
  if ([string]$ps.JobPath) {
    try { $bmp.Save($ps.JobPath, [Drawing.Imaging.ImageFormat]::Png); Clear-OldPreviewCache } catch { }
  }
  if ([int]$ps.JobKey -ne [int]$ps.Key) {
    try { $bmp.Dispose() } catch { }
    return $moved
  }
  $ps.Bmp = $bmp
  $ps.Kind = 'image'
  if ($null -ne $ps.Cfg -and $null -ne $ps.Panel) { Show-PreviewCard $ps $ps.Cfg $ps.Panel $ps.Anchor }
  return $true
}

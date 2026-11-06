# lib/media-render.ps1 - turning stored media into bitmaps: the hover card's picture, the
# small copy a row shows in its icon slot, and the thumb file both of them decode from.
#
# lib/media.ps1 owns the files and knows nothing about drawing; this module reads them and
# only the panel (`lib/picker.ps1`) and the card (`lib/preview.ps1`) call it. Keeping the two
# apart means the capture path never loads GDI+ code it does not use.
#
# Everything returned here belongs to a cache: a caller draws the bitmap and never disposes it.

# A few recently rendered bitmaps stay cached, so sweeping the mouse back over the same
# rows does not decode the same screenshot twice. Four entries is about 2 MB at the card
# size, and the panel clears the cache when it closes.
$script:MediaMaxCache = 4
$script:MediaCache = @{ Order = (New-Object System.Collections.Generic.List[string]); Map = @{} }

function Clear-MediaCache {
  $c = $script:MediaCache
  if ($null -eq $c) { return }
  foreach ($k in @($c.Map.Keys)) {
    $v = $c.Map[$k]
    if ($null -ne $v) { try { $v.Dispose() } catch { } }
  }
  $c.Map.Clear()
  $c.Order.Clear()
}

function Get-MediaCache([string]$key) {
  $c = $script:MediaCache
  if ($null -ne $c -and $c.Map.ContainsKey($key)) { return $c.Map[$key] }
  return $null
}

function Set-MediaCache([string]$key, $bmp) {
  $c = $script:MediaCache
  if ($null -eq $c) {
    $c = @{ Order = (New-Object System.Collections.Generic.List[string]); Map = @{} }
    $script:MediaCache = $c
  }
  if ($c.Map.ContainsKey($key)) {
    $old = $c.Map[$key]
    if ($null -ne $old) { try { $old.Dispose() } catch { } }
    [void]$c.Order.Remove($key)
  }
  $c.Map[$key] = $bmp
  $c.Order.Add($key)
  while ($c.Order.Count -gt $script:MediaMaxCache) {
    $first = [string]$c.Order[0]
    $c.Order.RemoveAt(0)
    $gone = $c.Map[$first]
    $c.Map.Remove($first)
    if ($null -ne $gone) { try { $gone.Dispose() } catch { } }
  }
  return $bmp
}

# Decoding a 4K png costs ~180 ms and the card never shows more than ~400 px wide, so the
# first hover writes a small copy beside the original: later hovers - in this session or the
# next one - start from that instead. It is derived data, so a failure here is only logged.
function Get-ImageThumbPath([string]$sha1) {
  return (Join-Path (Get-MediaDir) ($sha1 + '.thumb.png'))
}

function Write-ImageThumb([string]$sha1, $src) {
  if ($null -eq $src -or $src.Width -lt 1 -or $src.Height -lt 1) { return }
  $box = 512
  $t = $null
  $tg = $null
  try {
    if ($src.Width -le $box -and $src.Height -le $box) { return }
    $scale = [Math]::Min([double]$box / [double]$src.Width, [double]$box / [double]$src.Height)
    $w = [Math]::Max(1, [int][Math]::Floor([double]$src.Width * $scale))
    $h = [Math]::Max(1, [int][Math]::Floor([double]$src.Height * $scale))
    $t = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $tg = [Drawing.Graphics]::FromImage($t)
    $tg.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $tg.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $tg.DrawImage($src, (New-Object Drawing.Rectangle 0, 0, $w, $h))
    $tg.Dispose()
    $tg = $null
    [void](Ensure-MediaDir)
    $t.Save((Get-ImageThumbPath $sha1), [Drawing.Imaging.ImageFormat]::Png)
  } catch {
    Write-Log ('image thumb failed: ' + $_.Exception.Message)
  } finally {
    if ($null -ne $tg) { $tg.Dispose() }
    if ($null -ne $t) { $t.Dispose() }
  }
}

# ---- row thumbnails ---------------------------------------------------------
# A picture row shows a small copy of itself in the icon slot. This keeps its own cache: the
# hover card holds four big bitmaps, while row paint sweeps dozens of tiny ones and would
# evict the card on every scroll. Entries survive the panel on purpose - a reopen is instant.
$script:RowThumbMax = 64
$script:RowThumbCache = @{ Order = (New-Object System.Collections.Generic.List[string]); Map = @{} }

function Clear-RowThumbCache {
  $c = $script:RowThumbCache
  if ($null -eq $c) { return }
  foreach ($k in @($c.Map.Keys)) {
    $v = $c.Map[$k]
    if ($null -ne $v) { try { $v.Dispose() } catch { } }
  }
  $c.Map.Clear()
  $c.Order.Clear()
}

# The bitmap belongs to this cache, so a caller draws it and never disposes it.
function Get-RowThumbBitmap($record, [int]$side) {
  if ($null -eq $record -or $side -lt 8) { return $null }
  $payload = [string]$record.Payload
  if (-not (Test-ImagePayload $payload)) { return $null }
  $ref = Get-ImageRef $payload
  if ($null -eq $ref) { return $null }
  $c = $script:RowThumbCache
  $key = $ref.Sha1 + ':' + [string]$side
  if ($c.Map.ContainsKey($key)) { return $c.Map[$key] }
  Load-Forms
  # the small copy the card already writes is what a row wants: a 512 px decode instead of 4K
  $bytes = $null
  try {
    $thumbPath = Get-ImageThumbPath $ref.Sha1
    if (Test-Path -LiteralPath $thumbPath) { $bytes = [IO.File]::ReadAllBytes($thumbPath) }
  } catch { $bytes = $null }
  if ($null -eq $bytes) { $bytes = Read-ImageBytes $ref.Sha1 }
  if ($null -eq $bytes) { return $null }
  $src = $null
  $out = $null
  try {
    $ms = New-Object IO.MemoryStream
    $ms.Write($bytes, 0, $bytes.Length)
    $ms.Position = 0
    $src = [Drawing.Image]::FromStream($ms)
    $out = New-MediaScaledBitmap $src $side $side
  } catch {
    if ($null -ne $out) { try { $out.Dispose() } catch { } }
    $out = $null
  } finally {
    if ($null -ne $src) { $src.Dispose() }
  }
  if ($null -eq $out) { return $null }
  $c.Map[$key] = $out
  $c.Order.Add($key)
  while ($c.Order.Count -gt $script:RowThumbMax) {
    $first = [string]$c.Order[0]
    $c.Order.RemoveAt(0)
    $gone = $c.Map[$first]
    $c.Map.Remove($first)
    if ($null -ne $gone) { try { $gone.Dispose() } catch { } }
  }
  return $out
}

# ---- sizing and measuring ---------------------------------------------------
# 1 + the last row that differs from the paper colour: how much of the page the document
# used. Reading the pixels through LockBits keeps this at a few milliseconds.
function Get-InkBottom($bmp, $paper) {
  if ($null -eq $bmp -or $bmp.Width -lt 1 -or $bmp.Height -lt 1) { return 0 }
  $pb = 255
  $pg = 255
  $pr = 255
  if ($null -ne $paper) { $pb = [int]$paper.B; $pg = [int]$paper.G; $pr = [int]$paper.R }
  $rect = New-Object Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
  $data = $null
  try {
    $data = $bmp.LockBits($rect, [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppRgb)
    $stride = [int]$data.Stride
    $buf = New-Object byte[] ($stride * $bmp.Height)
    [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
  } catch { return 0 } finally { if ($null -ne $data) { try { $bmp.UnlockBits($data) } catch { } } }
  $w4 = $bmp.Width * 4
  for ($y = $bmp.Height - 1; $y -ge 0; $y--) {
    $row = $y * $stride
    for ($x = 0; $x -lt $w4; $x += 4) {
      if (([Math]::Abs([int]$buf[$row + $x] - $pb) -gt 8) -or
          ([Math]::Abs([int]$buf[$row + $x + 1] - $pg) -gt 8) -or
          ([Math]::Abs([int]$buf[$row + $x + 2] - $pr) -gt 8)) { return ($y + 1) }
    }
  }
  return 0
}

# one decode, scaled down and never up: a 4K screenshot costs one decode and a few MB, not a
# temporary full size copy on the window. Shared by the picture entry and the formatted entry.
function New-MediaScaledBitmap($src, [int]$maxW, [int]$maxH) {
  if ($null -eq $src -or $maxW -lt 16 -or $maxH -lt 16) { return $null }
  $g = $null
  $out = $null
  try {
    if ($src.Width -lt 1 -or $src.Height -lt 1) { return $null }
    $scale = [Math]::Min([double]$maxW / [double]$src.Width, [double]$maxH / [double]$src.Height)
    if ($scale -gt 1.0) { $scale = 1.0 }
    $w = [Math]::Max(1, [int][Math]::Floor([double]$src.Width * $scale))
    $h = [Math]::Max(1, [int][Math]::Floor([double]$src.Height * $scale))
    $out = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $g = [Drawing.Graphics]::FromImage($out)
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.DrawImage($src, (New-Object Drawing.Rectangle 0, 0, $w, $h))
    return $out
  } catch {
    Write-Log ('media scale failed: ' + $_.Exception.Message)
    if ($null -ne $out) { try { $out.Dispose() } catch { } }
    return $null
  } finally {
    if ($null -ne $g) { $g.Dispose() }
  }
}

# ---- the three bitmaps the panel asks for -----------------------------------
# the card's picture for a formatted entry: the first block that decodes wins, so a png is
# preferred over a bitmap and a bitmap over a metafile
function Get-RichImageBitmap([string]$ref, [int]$maxW, [int]$maxH) {
  $r = Get-RichRef $ref
  if ($null -eq $r -or $maxW -lt 16 -or $maxH -lt 16) { return $null }
  Load-Forms
  foreach ($tag in @('P', 'D', 'E')) {
    foreach ($b in $r.Blocks) {
      if ($b.Tag -cne $tag) { continue }
      $key = 'r:' + $b.Sha1 + ':' + [string]$maxW + 'x' + [string]$maxH
      $hit = Get-MediaCache $key
      if ($null -ne $hit) { return $hit }
      $bytes = $null
      try { $bytes = [IO.File]::ReadAllBytes((Get-MediaPath $b.Sha1 $b.Ext)) } catch { $bytes = $null }
      if ($null -eq $bytes) { continue }
      $src = ConvertFrom-MediaBytes $bytes $tag
      if ($null -eq $src) { continue }
      $bmp = $null
      try { $bmp = New-MediaScaledBitmap $src $maxW $maxH } finally { $src.Dispose() }
      if ($null -eq $bmp) { continue }
      return (Set-MediaCache $key $bmp)
    }
  }
  return $null
}

function Get-ImagePreviewBitmap([string]$sha1, [int]$maxW, [int]$maxH) {
  if (-not $sha1 -or $maxW -lt 16 -or $maxH -lt 16) { return $null }
  $key = 'i:' + $sha1 + ':' + [string]$maxW + 'x' + [string]$maxH
  $hit = Get-MediaCache $key
  if ($null -ne $hit) { return $hit }
  # the small copy first: it turns a 4K decode into a 512 px one
  $bytes = $null
  $fromThumb = $false
  try {
    $thumbPath = Get-ImageThumbPath $sha1
    if (Test-Path -LiteralPath $thumbPath) {
      $bytes = [IO.File]::ReadAllBytes($thumbPath)
      $fromThumb = $true
    }
  } catch { $bytes = $null }
  if ($null -eq $bytes) { $bytes = Read-ImageBytes $sha1 }
  if ($null -eq $bytes) { return $null }
  Load-Forms
  $src = $null
  $out = $null
  try {
    $ms = New-Object IO.MemoryStream
    $ms.Write($bytes, 0, $bytes.Length)
    $ms.Position = 0
    $src = [Drawing.Image]::FromStream($ms)
    $out = New-MediaScaledBitmap $src $maxW $maxH
  } catch {
    Write-Log ('image preview failed: ' + $_.Exception.Message)
    if ($null -ne $out) { try { $out.Dispose() } catch { } }
    $out = $null
  } finally {
    if ($null -eq $out -and $null -ne $src) { $src.Dispose() }
  }
  if ($null -eq $out) { return $null }
  if (-not $fromThumb) { Write-ImageThumb $sha1 $src }
  if ($null -ne $src) { $src.Dispose() }
  return (Set-MediaCache $key $out)
}

# ---- what the card's layout engine can actually draw -------------------------
# The off-screen RichTextBox lays RTF out through EM_FORMATRANGE, and that engine silently
# drops the \pngblip spelling - which is exactly what Word and Excel write when a picture is
# copied. The words arrived on the card and every picture was missing, while the paste itself
# was fine (a target application parses the RTF itself). So the pictures are re-spelled as
# \dibitmap for the layout only; the entry and the clipboard bytes are untouched.
#
# A bitmap is much bigger than the png it came from, so both sides are capped: a card must not
# be able to stall the panel on a page full of screenshots.
$script:CardRtfMaxPng = 4194304
$script:CardRtfMaxDib = 25165824

function ConvertTo-CardRtf([string]$rtf) {
  if ([string]::IsNullOrEmpty($rtf) -or $rtf.Length -lt 16) { return $rtf }
  if ($rtf.IndexOf('\pngblip', [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $rtf }
  $hits = @([regex]::Matches($rtf, '(?s)\{\\pict\\pngblip([^{}]*)\}'))
  if ($hits.Count -eq 0) { return $rtf }
  $sb = New-Object Text.StringBuilder $rtf
  $total = 0
  $placed = 0
  # A picture the layout will not take - too big on its own, over the running bitmap budget,
  # or an encoding that does not decode - is still part of the entry and still pastes back.
  # Leaving it as \pngblip would draw nothing at all, so the block becomes a short marker:
  # the card then shows that a picture belongs there instead of an unexplained blank strip.
  $note = '{\fs16 [image]}'
  # back to front: a replacement changes the length, and every later index would move
  for ($i = $hits.Count - 1; $i -ge 0; $i--) {
    $hit = $hits[$i]
    $replacement = $note
    $src = $null
    try {
      # the block is control words and one hex run; c, d, e, f are hex digits too, so the
      # control words have to go first or '\picw' would be read as data
      $inner = [regex]::Replace($hit.Groups[1].Value, '\\[a-zA-Z]+-?\d*\s?', '')
      $hex = ($inner -replace '[^0-9a-fA-F]', '')
      if ($hex.Length -ge 32 -and ($hex.Length % 2) -eq 0) {
        $png = $null
        try { $png = [System.Runtime.Remoting.Metadata.W3cXsd2001.SoapHexBinary]::Parse($hex).Value } catch { $png = $null }
        if ($null -ne $png -and $png.Length -ge 8 -and $png.Length -le $script:CardRtfMaxPng) {
          $ms = New-Object IO.MemoryStream (,$png)
          $src = [Drawing.Image]::FromStream($ms)
          $bmpMs = New-Object IO.MemoryStream
          $src.Save($bmpMs, [Drawing.Imaging.ImageFormat]::Bmp)
          $all = $bmpMs.ToArray()
          $bmpMs.Dispose()
          # a .bmp file is a 14 byte file header in front of the DIB the clipboard and RTF both want
          if ($all.Length -gt 14 + 40) {
            $dibLen = $all.Length - 14
            if (($total + $dibLen) -le $script:CardRtfMaxDib) {
              $dib = New-Object byte[] $dibLen
              [Array]::Copy($all, 14, $dib, 0, $dibLen)
              $total = $total + $dibLen
              $newHex = ([System.Runtime.Remoting.Metadata.W3cXsd2001.SoapHexBinary]::new($dib)).ToString()
              $replacement = '{\pict\dibitmap0 ' + $newHex + '}'
            }
          }
        }
      }
    } catch {
      Write-Log ('card picture skipped: ' + $_.Exception.Message)
    } finally {
      if ($null -ne $src) { try { $src.Dispose() } catch { } }
    }
    if ($replacement -eq $note) { $placed++ }
    [void]$sb.Remove($hit.Index, $hit.Length)
    [void]$sb.Insert($hit.Index, $replacement)
  }
  if ($placed -gt 0) { Write-Log ('card pictures drawn as a placeholder: ' + [string]$placed) }
  $newText = $sb.ToString()
  if ($newText -ceq $rtf) { return $rtf }
  return $newText
}

# RTF is the only rich format Windows can lay out without a browser engine, so the card
# renders it with an off-screen RichTextBox and keeps the bitmap. A document keeps its own
# colours, so the paper stays light whatever the panel theme is.
function Get-RichPreviewBitmap([string]$ref, [int]$maxW, [int]$maxH, $font, $paper) {
  if (-not $ref -or $maxW -lt 16 -or $maxH -lt 16) { return $null }
  $key = 'r:' + $ref + ':' + [string]$maxW + 'x' + [string]$maxH
  $hit = Get-MediaCache $key
  if ($null -ne $hit) { return $hit }
  $rtf = Read-RichRtf $ref
  if (-not $rtf) { return $null }
  # the layout engine cannot draw a png picture: re-spell it as a bitmap first
  $rtf = ConvertTo-CardRtf $rtf
  Load-Forms
  Add-Native
  if ($null -eq $paper) { $paper = [Drawing.Color]::White }
  $box = New-Object Windows.Forms.RichTextBox
  $full = $null
  $g = $null
  $out = $null
  try {
    $box.BorderStyle = 'None'
    $box.DetectUrls = $false
    $box.WordWrap = $true
    $box.Size = New-Object Drawing.Size $maxW, $maxH
    $box.BackColor = $paper
    if ($null -ne $font) { $box.Font = $font }
    # a handle is all the layout needs: the control never has to be on screen
    [void]$box.Handle
    try { $box.Rtf = $rtf } catch { return $null }
    $full = New-Object Drawing.Bitmap $maxW, $maxH, ([Drawing.Imaging.PixelFormat]::Format32bppRgb)
    $g = [Drawing.Graphics]::FromImage($full)
    $g.Clear($paper)
    [void][Cb.Rich]::RenderTo($box, $g, $maxW, $maxH)
    $g.Dispose()
    $g = $null
    # a two line note must not get a full page: crop to the rows that carry ink
    $used = Get-InkBottom $full $paper
    $minH = 16
    try { $minH = [Math]::Max(16, [int]$box.Font.Height + 4) } catch { }
    if ($used -lt $minH) { $used = $minH }
    if ($used -gt $maxH) { $used = $maxH }
    if ($used -eq $maxH) {
      $out = $full
      $full = $null
    } else {
      $out = $full.Clone((New-Object Drawing.Rectangle 0, 0, $maxW, $used), [Drawing.Imaging.PixelFormat]::Format32bppRgb)
    }
  } catch {
    Write-Log ('rich preview failed: ' + $_.Exception.Message)
    $out = $null
  } finally {
    if ($null -ne $g) { $g.Dispose() }
    if ($null -ne $full) { $full.Dispose() }
    try { $box.Dispose() } catch { }
  }
  if ($null -eq $out) {
    try { if ([Cb.Rich]::LastError) { Write-Log ('rich layout: ' + [Cb.Rich]::LastError) } } catch { }
    return $null
  }
  return (Set-MediaCache $key $out)
}

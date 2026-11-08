# lib/panel/media-render.ps1 - turning stored media into bitmaps: the hover card's picture, the
# small copy a row shows in its icon slot, and the thumb file both of them decode from.
#
# lib/media.ps1 owns the files and knows nothing about drawing; this module reads them and
# only the panel (`lib/panel/picker.ps1`) and the card (`lib/panel/preview.ps1`) call it. Keeping the two
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
# be able to stall the panel on a page full of screenshots. A document past
# RtfImagesUpToBytes keeps its layout but loses its pictures to a marker here.
$script:CardRtfMaxPng = 4194304
$script:CardRtfMaxDib = 25165824
# The marker a picture becomes when the layout will not draw it. The full card keeps one fixed
# block - 180 px wide, six text lines tall - because it would have to decode a picture before it
# could know its size. The plain card asks Cb.Rtf.PadPictures for the size each \pict states and
# reserves exactly that room, so every block lands on empty space instead of on the words.
# The marker a picture becomes when the layout will not draw it. Both cards size the block from
# the picture itself - the plain card reads what each \pict states, the full card reads the
# pixels it decoded or the png header when the picture was too big to decode - and reserve
# exactly that room, so a block lands on empty space instead of on the words. The width is
# capped and the fixed block stays the answer when nothing says how big the picture is.
$script:CardPicToken = '@cbimg@'
$script:CardPicWidth = 180
$script:CardPicRows = 6
# The fallback for a picture that never says its size: one marker paragraph followed by the
# empty ones the painted block covers.
$script:CardPicCell = "\par" + $script:CardPicToken + ("\par" * $script:CardPicRows)

# The pixel size a png states in its own header, or $null when the bytes are not a png. A
# picture past the bitmap budget is never decoded, so its header is the only thing that can tell
# the card what shape the picture has.
function Get-PngPixelSize($bytes) {
  if ($null -eq $bytes -or $bytes.Length -lt 24) { return $null }
  if ($bytes[0] -ne 137 -or $bytes[1] -ne 80 -or $bytes[2] -ne 78 -or $bytes[3] -ne 71) { return $null }
  $w = ([long]$bytes[16] * 16777216) + ([long]$bytes[17] * 65536) + ([long]$bytes[18] * 256) + [long]$bytes[19]
  $h = ([long]$bytes[20] * 16777216) + ([long]$bytes[21] * 65536) + ([long]$bytes[22] * 256) + [long]$bytes[23]
  if ($w -lt 1 -or $h -lt 1) { return $null }
  return @([int]$w, [int]$h)
}

# A block shaped like the picture: as wide as it may be, as many text lines tall as that width
# needs. Counted in the card's own line height, so the marker paragraph that reserves the room
# and the rectangle painted over it cannot drift apart.
function New-CardBlock([int]$picW, [int]$picH, [int]$lineHeight, [int]$maxWidth, [int]$minWidth, [int]$defaultRows, [string]$token) {
  $w = $maxWidth
  $rows = $defaultRows
  if ($picW -gt 0 -and $picH -gt 0 -and $lineHeight -gt 0) {
    if ($picW -lt $w) { $w = $picW }
    if ($w -lt $minWidth) { $w = $minWidth }
    $rows = [int][Math]::Ceiling((([double]$picH * $w) / $picW) / $lineHeight)
    if ($rows -lt 1) { $rows = 1 }
    if ($rows -gt 24) { $rows = 24 }
  }
  if ($w -lt $minWidth) { $w = $minWidth }
  return @{ Text = ("\par" + $token + ("\par" * $rows)); Width = $w; Rows = $rows }
}

function ConvertTo-CardRtf([string]$rtf, [string]$token = '', [int]$lineHeight = 0, [int]$maxWidth = 0, [int]$minWidth = 60, [int]$defaultRows = 6, $boxes = $null) {
  if ([string]::IsNullOrEmpty($rtf) -or $rtf.Length -lt 16) { return $rtf }
  if ($rtf.IndexOf('\pngblip', [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $rtf }
  $hits = @([regex]::Matches($rtf, '(?s)\{\\pict\\pngblip([^{}]*)\}'))
  if ($hits.Count -eq 0) { return $rtf }
  $sb = New-Object Text.StringBuilder $rtf
  $total = 0
  $placed = 0
  # the caller knows the card's font, so a block can keep the shape of its picture; without
  # those numbers the fixed block is still a correct answer and the callers that only want the
  # text pass none.
  $sized = ($lineHeight -gt 0 -and $maxWidth -gt 0)
  if (-not $token) { $token = $script:CardPicToken }
  $found = New-Object System.Collections.Generic.List[int]
  # A picture the layout will not take - too big on its own, over the running bitmap budget,
  # or an encoding that does not decode - is still part of the entry and still pastes back.
  # Leaving it as \pngblip would draw nothing at all, so the block becomes a short marker:
  # the card then shows that a picture belongs there instead of an unexplained blank strip.
  $note = $script:CardPicCell
  # back to front: a replacement changes the length, and every later index would move
  for ($i = $hits.Count - 1; $i -ge 0; $i--) {
    $hit = $hits[$i]
    $replacement = $note
    $src = $null
    $markW = 0
    $markH = 0
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
          $markW = $src.Width
          $markH = $src.Height
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
        } elseif ($null -ne $png) {
          # too big to decode, so the header answers instead: the block still knows the shape
          $sz = Get-PngPixelSize $png
          if ($null -ne $sz) { $markW = $sz[0]; $markH = $sz[1] }
        }
      }
    } catch {
      Write-Log ('card picture skipped: ' + $_.Exception.Message)
    } finally {
      if ($null -ne $src) { try { $src.Dispose() } catch { } }
    }
    if ($replacement -eq $note) {
      if ($sized) {
        $block = New-CardBlock $markW $markH $lineHeight $maxWidth $minWidth $defaultRows $token
        $replacement = $block.Text
        $found.Insert(0, $block.Rows)
        $found.Insert(0, $block.Width)
      }
      $placed++
    }
    [void]$sb.Remove($hit.Index, $hit.Length)
    [void]$sb.Insert($hit.Index, $replacement)
  }
  if ($placed -gt 0) { Write-Log ('card pictures drawn as a placeholder: ' + [string]$placed) }
  if ($null -ne $boxes) { $boxes.Value = $found.ToArray() }
  $newText = $sb.ToString()
  if ($newText -ceq $rtf) { return $rtf }
  return $newText
}

# RTF is the only rich format Windows can lay out without a browser engine, so the card
# renders it with an off-screen RichTextBox and keeps the bitmap. A document keeps its own
# colours, so the paper stays light whatever the panel theme is.
# the size of the rtf a reference names, 0 when it carries none. The number sits in the
# reference itself, so this costs a parse and no disk read.
function Get-RichRtfSize([string]$ref) {
  $r = Get-RichRef $ref
  if ($null -eq $r) { return [long]0 }
  foreach ($b in @($r.Blocks)) { if ([string]$b.Tag -ceq 'T') { return [long]$b.Bytes } }
  return [long]0
}

# Three sizes, three cards: a document that fits is laid out with its pictures, a bigger
# one is laid out with a marker where each picture was, and a document whose rtf was not
# kept at all has nothing to lay out (the card shows its words).
function Get-RichPreviewMode([long]$size) {
  if ($size -le 0) { return 'none' }
  if ($script:MaxRtfBytes -gt 0 -and $size -gt $script:MaxRtfBytes) { return 'text' }
  if ($script:RtfImagesUpToBytes -gt 0 -and $size -gt $script:RtfImagesUpToBytes) { return 'plain' }
  return 'full'
}

# The marker wants the quiet grey the panel uses for secondary text, and an rtf only knows the
# colours in its own table. Appending one entry leaves every existing \cfN index where it is,
# so a document that already has a table keeps all of its own colours.
function Add-RtfGrayColor([string]$rtf) {
  if ([string]::IsNullOrEmpty($rtf)) { return @{ Text = $rtf; Index = 0 } }
  $gray = '\red140\green140\blue140;'
  $m = [regex]::Match($rtf, '\{\\colortbl[^}]*\}')
  if ($m.Success) {
    $body = $m.Value.Substring(0, $m.Value.Length - 1)
    $count = ([regex]::Matches($body, ';')).Count
    $new = $body + $gray + '}'
    $text = $rtf.Substring(0, $m.Index) + $new + $rtf.Substring($m.Index + $m.Length)
    return @{ Text = $text; Index = $count + 1 }
  }
  $head = [regex]::Match($rtf, '^\{\\rtf1[^\\]*')
  if (-not $head.Success) { return @{ Text = $rtf; Index = 0 } }
  $at = $head.Index + $head.Length
  # a leading ';' is the automatic colour (index 1), so the grey is index 2
  $text = $rtf.Substring(0, $at) + '{\colortbl ;' + $gray + '}' + $rtf.Substring($at)
  return @{ Text = $text; Index = 2 }
}

# one step away from the paper colour, clamped: a block has to read as a surface on the card,
# not as a second colour
function New-TonedColor($c, [int]$delta) {
  $r = [Math]::Min(255, [Math]::Max(0, [int]$c.R + $delta))
  $g2 = [Math]::Min(255, [Math]::Max(0, [int]$c.G + $delta))
  $b = [Math]::Min(255, [Math]::Max(0, [int]$c.B + $delta))
  return [Drawing.Color]::FromArgb(255, $r, $g2, $b)
}

# A picture the layout refuses to draw keeps its place as a block of the size it asked for,
# painted over the marker that stands in for it. Fluent's own media placeholder is the model:
# 6 px corners, a fill one step off the paper, a hairline stroke and one quiet word.
function Draw-CardImagePlaceholders($g, $box, [int]$maxW, $paper, [string]$token, $boxes = $null, [int]$maxH = 0) {
  if ($null -eq $g -or $null -eq $box -or -not $token) { return }
  $text = [string]$box.Text
  if (-not $text -or $text.IndexOf($token, [StringComparison]::Ordinal) -lt 0) { return }
  $luma = (([int]$paper.R + [int]$paper.G + [int]$paper.B) / 3)
  $step = $(if ($luma -lt 128) { 14 } else { -10 })
  $fill = New-TonedColor $paper $step
  $edge = New-TonedColor $paper ($step * 2)
  $ink = New-TonedColor $paper $(if ($luma -lt 128) { 96 } else { -84 })
  $pad = [int](Px 10)
  $avail = $maxW - ($pad * 2)
  if ($avail -lt 40) { $avail = $maxW }
  $font = $null
  try { $font = New-Object Drawing.Font($box.Font.FontFamily, [Math]::Max(7, [single]$box.Font.Size - 1)) } catch { $font = $null }
  $brush = New-Object Drawing.SolidBrush $fill
  $inkBrush = New-Object Drawing.SolidBrush $ink
  $pen = New-Object Drawing.Pen $edge, 1
  $fmt = New-Object Drawing.StringFormat
  $fmt.Alignment = [Drawing.StringAlignment]::Center
  $fmt.LineAlignment = [Drawing.StringAlignment]::Center
  $fmt.FormatFlags = [Drawing.StringFormatFlags]::NoWrap
  try {
    $start = 0
    $k = 0
    while ($true) {
      $at = $text.IndexOf($token, $start, [StringComparison]::Ordinal)
      if ($at -lt 0) { break }
      $pt = $box.GetPositionFromCharIndex($at)
      # asking the layout where a marker sits is the expensive half of this loop - it walks the
      # document from the top every time - and a block below the card can never be seen
      if ($maxH -gt 0 -and $pt.Y -ge $maxH) { break }
      # a block the rtf sized for us: the width it asked for and the lines it reserved, so the
      # rectangle lands exactly on the empty room instead of being an approximation
      $w = $script:CardPicWidth
      $rows = $script:CardPicRows
      if ($null -ne $boxes -and ($k * 2) + 1 -lt $boxes.Length) {
        if ([int]$boxes[$k * 2] -gt 0) { $w = [int]$boxes[$k * 2] }
        if ([int]$boxes[($k * 2) + 1] -gt 0) { $rows = [int]$boxes[($k * 2) + 1] }
      }
      $w = [Math]::Min($w, $avail)
      # the block is exactly the room the marker reserved, measured in the font the document
      # is laid out with: a fixed pixel height would either cover the next paragraph or leave
      # a band of nothing depending on the document's own font size
      $h = [int]$box.Font.Height * $rows
      if ($h -gt 320) { $h = 320 }
      if ($w -lt 60) { $w = 60 }
      if ($h -lt 34) { $h = 34 }
      $path = New-RoundPath ([int]$pt.X) ([int]$pt.Y) $w $h (Px 6)
      $g.FillPath($brush, $path)
      $g.DrawPath($pen, $path)
      $path.Dispose()
      if ($null -ne $font) {
        $rect = New-Object Drawing.RectangleF -ArgumentList @([single]$pt.X, [single]$pt.Y, [single]$w, [single]$h)
        $g.DrawString('image', $font, $inkBrush, $rect, $fmt)
      }
      $start = $at + $token.Length
      $k++
    }
  } finally {
    $brush.Dispose()
    $inkBrush.Dispose()
    $pen.Dispose()
    $fmt.Dispose()
    if ($null -ne $font) { $font.Dispose() }
  }
}

function Get-RichPreviewBitmap([string]$ref, [int]$maxW, [int]$maxH, $font, $paper, [string]$mode = 'full') {
  if (-not $ref -or $maxW -lt 16 -or $maxH -lt 16) { return $null }
  if ($mode -ceq 'none' -or $mode -ceq 'text') { return $null }
  $key = 'r:' + $mode + ':' + $ref + ':' + [string]$maxW + 'x' + [string]$maxH
  $hit = Get-MediaCache $key
  if ($null -ne $hit) { return $hit }
  $rtf = Read-RichRtf $ref
  if (-not $rtf) { return $null }
  # both cards end up with the same marker token; each mode decides separately what the marker
  # paragraph reserves, once the card's own line height is known
  $token = $script:CardPicToken
  Load-Forms
  Add-Native
  if ($null -eq $paper) { $paper = [Drawing.Color]::White }
  $box = New-Object Windows.Forms.RichTextBox
  $full = $null
  $g = $null
  $out = $null
  # each mode fills this with a width,rows pair per block, in document order, so the rectangle
  # painted afterwards is exactly the room the marker paragraph reserved
  $boxes = @()
  try {
    $box.BorderStyle = 'None'
    $box.DetectUrls = $false
    $box.WordWrap = $true
    $box.Size = New-Object Drawing.Size $maxW, $maxH
    $box.BackColor = $paper
    if ($null -ne $font) { $box.Font = $font }
    # a handle is all the layout needs: the control never has to be on screen
    [void]$box.Handle
    if ($mode -ceq 'plain') {
      # a picture keeps its proportions: the block is as wide and as many text lines tall as
      # the rtf asked for, and the marker paragraph reserves exactly that room, so the words
      # around a picture stay where the layout put them.
      try {
        $gap = [int](Px 10)
        $avail0 = $maxW - ($gap * 2)
        if ($avail0 -lt 40) { $avail0 = $maxW }
        $band = [Math]::Min($script:CardPicWidth, $avail0)
        $rtf = [Cb.Rtf]::PadPictures($rtf, $token, [int]$box.Font.Height, $band, 60, $script:CardPicRows, [ref]$boxes)
        $gray = Add-RtfGrayColor $rtf
        $mark = '{\fs18\i ' + $token + '}'
        if ($gray.Index -gt 0) { $mark = '{\fs18\i\cf' + [string]$gray.Index + ' ' + $token + '}' }
        $rtf = $gray.Text.Replace($token, $mark)
      } catch {
        Write-Log ('card placeholder failed: ' + $_.Exception.Message)
      }
    } else {
      # the layout engine cannot draw a png picture: re-spell it as a bitmap, and a picture past
      # the bitmap budget becomes the same block the plain card uses. Its shape comes from the
      # pixels that were already decoded, or from the png header when it was too big to decode.
      try {
        $gap = [int](Px 10)
        $avail0 = $maxW - ($gap * 2)
        if ($avail0 -lt 40) { $avail0 = $maxW }
        $band = [Math]::Min($script:CardPicWidth, $avail0)
        $rtf = ConvertTo-CardRtf $rtf $token ([int]$box.Font.Height) $band 60 $script:CardPicRows ([ref]$boxes)
      } catch {
        Write-Log ('card block failed: ' + $_.Exception.Message)
      }
    }
    try { $box.Rtf = $rtf } catch { return $null }
    $full = New-Object Drawing.Bitmap $maxW, $maxH, ([Drawing.Imaging.PixelFormat]::Format32bppRgb)
    $g = [Drawing.Graphics]::FromImage($full)
    $g.Clear($paper)
    [void][Cb.Rich]::RenderTo($box, $g, $maxW, $maxH)
    # before the crop: a placeholder taller than the words has to count as ink
    if ($token) {
      try { Draw-CardImagePlaceholders $g $box $maxW $paper $token $boxes $maxH }
      catch { Write-Log ('card placeholder failed: ' + $_.Exception.Message) }
    }
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

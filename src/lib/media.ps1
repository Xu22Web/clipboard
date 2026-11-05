# lib/media.ps1 - the files a record can own besides its text: images and the formatted
# version of a text entry.
#
# An entry stays a string. An image entry carries a short descriptor instead of pixels
#   char 3 + 'image:' + sha1 + ':' + WxH + ':' + bytes + ':' + fmt
# and the pixels live in data\media\<sha1>.png; a formatted text entry keeps its plain text
# as the payload and names its sidecars with a reference on the record
#   'R:' + sha1 + ':' + bytes
# The sha1 is the content hash, so copying the same picture twice reuses one file and the
# payload comparison the store already does for text keeps working for images.
#
# Everything here is storage plus decode. Nothing in this file draws: the preview card
# (lib/preview.ps1) asks for a bitmap of a bounded size and paints it.

function Get-MediaDir { return (Join-Path $StoreDir 'media') }

function Get-MediaPath([string]$sha1, [string]$ext) {
  return (Join-Path (Get-MediaDir) ($sha1 + '.' + $ext))
}

function Ensure-MediaDir {
  $dir = Get-MediaDir
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return $dir
}

# sha1 over one part, or over two parts separated by RS so the pair stays unambiguous
function Get-MediaSha1([byte[]]$first, [byte[]]$second) {
  $sha = [Security.Cryptography.SHA1]::Create()
  try {
    $data = $first
    if ($null -ne $second) {
      $data = New-Object byte[] ($first.Length + 1 + $second.Length)
      [Array]::Copy($first, 0, $data, 0, $first.Length)
      $data[$first.Length] = 30
      [Array]::Copy($second, 0, $data, $first.Length + 1, $second.Length)
    }
    if ($null -eq $data) { $data = New-Object byte[] 0 }
    return (([BitConverter]::ToString($sha.ComputeHash($data)) -replace '-', '').ToLowerInvariant())
  } finally { $sha.Dispose() }
}

# ---- images -----------------------------------------------------------------
# The descriptor is what the store keeps and what the panel searches; it is derived from the
# bytes alone, so the same picture always produces the same payload.
function New-ImagePayload([byte[]]$png, [int]$w, [int]$h, [string]$fmt = 'PNG') {
  if ($null -eq $png -or $png.Length -eq 0 -or $w -le 0 -or $h -le 0) { return '' }
  if (-not $fmt) { $fmt = 'PNG' }
  $sha = Get-MediaSha1 $png $null
  return ([string]$IMGSIG + 'image:' + $sha + ':' + [string]$w + 'x' + [string]$h + ':' + [string]$png.Length + ':' + $fmt)
}

function Get-ImageRef([string]$payload) {
  if ([string]::IsNullOrEmpty($payload) -or $payload[0] -ne [char]3) { return $null }
  $p = $payload.Substring(1) -split ':'
  if ($p.Count -lt 5 -or $p[0] -cne 'image') { return $null }
  if ($p[1].Length -ne 40) { return $null }
  $dim = $p[2] -split 'x'
  if ($dim.Count -ne 2) { return $null }
  $w = 0
  $h = 0
  $bytes = [long]0
  if (-not [int]::TryParse($dim[0], [ref]$w)) { return $null }
  if (-not [int]::TryParse($dim[1], [ref]$h)) { return $null }
  if (-not [long]::TryParse($p[3], [ref]$bytes)) { return $null }
  return @{ Sha1 = $p[1]; W = $w; H = $h; Bytes = $bytes; Fmt = $p[4] }
}

function Test-ImagePayload([string]$payload) {
  return ($null -ne $payload -and $payload.Length -gt 0 -and $payload[0] -eq [char]3)
}

function Write-ImageMedia([string]$payload, [byte[]]$png) {
  $ref = Get-ImageRef $payload
  if ($null -eq $ref -or $null -eq $png -or $png.Length -eq 0) { return $false }
  $path = Get-MediaPath $ref.Sha1 'png'
  if (Test-Path -LiteralPath $path) { return $true }
  try {
    [void](Ensure-MediaDir)
    [IO.File]::WriteAllBytes($path, $png)
    return $true
  } catch {
    Write-Log ('image write failed: ' + $_.Exception.Message)
    return $false
  }
}

function Read-ImageBytes([string]$sha1) {
  if (-not $sha1) { return $null }
  try { return [IO.File]::ReadAllBytes((Get-MediaPath $sha1 'png')) } catch { return $null }
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

# ---- formatted text ---------------------------------------------------------
# ---- formatted text ---------------------------------------------------------
# A formatted entry owns one file per block, each named by the hash of its own bytes:
#
#   'H:<sha1>:<bytes>|T:<sha1>:<bytes>|P:<sha1>:<bytes>'
#
# H = CF_HTML, T = RTF, P = PNG, D = CF_DIB, E = CF_ENHMETAFILE. The record keeps only this
# reference, so an entry still adds a few hundred bytes to the history file and two entries
# that share a block share the file. Every block is stored byte for byte: CF_HTML carries
# byte offsets into its own buffer and RTF is an 8-bit format, so a decode / re-encode step
# would break the paste (lib/clip.ps1 reads them raw for the same reason).
$script:RichTags = [ordered]@{ H = 'html'; T = 'rtf'; P = 'png'; D = 'dib'; E = 'emf' }

function ConvertTo-RtfBytes($rtf) {
  if ($null -eq $rtf) { return (New-Object byte[] 0) }
  if ($rtf -is [byte[]]) { return $rtf }
  $s = [string]$rtf
  if (-not $s) { return (New-Object byte[] 0) }
  return [Text.Encoding]::Default.GetBytes($s)
}

# the bytes one block gets from a capture: html and rtf sit under their own keys, the picture
# blocks in a list, so a caller builds a capture without knowing the reference grammar
function Get-RichBlockData($rich, [string]$tag) {
  $empty = New-Object byte[] 0
  if ($null -eq $rich) { return $empty }
  if ($tag -ceq 'H') {
    if ($null -ne $rich.Html) { return $rich.Html }
    return $empty
  }
  if ($tag -ceq 'T') { return (ConvertTo-RtfBytes $rich.Rtf) }
  foreach ($b in @($rich.Blocks)) {
    if ($null -eq $b -or [string]$b.Tag -cne $tag) { continue }
    if ($null -ne $b.Data) { return $b.Data }
  }
  return $empty
}

function New-RichRef($rich) {
  if ($null -eq $rich) { return '' }
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($tag in @($script:RichTags.Keys)) {
    $data = Get-RichBlockData $rich $tag
    if ($null -eq $data -or $data.Length -eq 0) { continue }
    $parts.Add($tag + ':' + (Get-MediaSha1 $data $null) + ':' + [string]$data.Length)
  }
  if ($parts.Count -eq 0) { return '' }
  return ($parts -join '|')
}

# the blocks a reference names; $null when the string is not a reference, which is how the
# store tells a formatted entry from a plain one
function Get-RichRef([string]$ref) {
  if ([string]::IsNullOrEmpty($ref)) { return $null }
  $blocks = New-Object System.Collections.Generic.List[object]
  $total = [long]0
  foreach ($item in ($ref -split '\|')) {
    $p = $item -split ':'
    if ($p.Count -ne 3) { return $null }
    $tag = $p[0]
    if (-not $script:RichTags.Contains($tag)) { return $null }
    if ($p[1].Length -ne 40) { return $null }
    $bytes = [long]0
    if (-not [long]::TryParse($p[2], [ref]$bytes)) { return $null }
    $blocks.Add(@{ Tag = $tag; Ext = [string]$script:RichTags[$tag]; Sha1 = $p[1]; Bytes = $bytes })
    $total += $bytes
  }
  if ($blocks.Count -eq 0) { return $null }
  return @{ Blocks = $blocks.ToArray(); Bytes = $total }
}

function Write-RichMedia([string]$ref, $rich) {
  $r = Get-RichRef $ref
  if ($null -eq $r -or $null -eq $rich) { return $false }
  try {
    [void](Ensure-MediaDir)
    foreach ($b in $r.Blocks) {
      $path = Get-MediaPath $b.Sha1 $b.Ext
      if (Test-Path -LiteralPath $path) { continue }
      $data = Get-RichBlockData $rich $b.Tag
      if ($null -eq $data -or $data.Length -eq 0) { continue }
      [IO.File]::WriteAllBytes($path, $data)
    }
    return $true
  } catch {
    Write-Log ('rich media write failed: ' + $_.Exception.Message)
    return $false
  }
}

# one block back; Read-RichHtml / Read-RichRtfBytes are the two the rest of the tool asks
# for, a picture block is only read on the way back to the clipboard
function Read-RichBlock([string]$ref, [string]$tag) {
  $r = Get-RichRef $ref
  if ($null -eq $r) { return $null }
  foreach ($b in $r.Blocks) {
    if ($b.Tag -cne $tag) { continue }
    try { return [IO.File]::ReadAllBytes((Get-MediaPath $b.Sha1 $b.Ext)) } catch { return $null }
  }
  return $null
}

function Read-RichHtml([string]$ref) { return (Read-RichBlock $ref 'H') }

# the bytes are what the clipboard gets back; the string form is only for the preview card,
# which hands the RTF to a RichTextBox
function Read-RichRtfBytes([string]$ref) {
  $bytes = Read-RichBlock $ref 'T'
  if ($null -eq $bytes) { return (New-Object byte[] 0) }
  return $bytes
}

function Read-RichRtf([string]$ref) {
  $bytes = Read-RichRtfBytes $ref
  if ($null -eq $bytes -or $bytes.Length -eq 0) { return '' }
  return [Text.Encoding]::Default.GetString($bytes)
}

# does the record still have something to paste? (a missing file must not become plain text
# silently when the user asked for a formatted paste)
function Test-RichMedia([string]$ref) {
  $r = Get-RichRef $ref
  if ($null -eq $r) { return $false }
  foreach ($b in $r.Blocks) {
    if (Test-Path -LiteralPath (Get-MediaPath $b.Sha1 $b.Ext)) { return $true }
  }
  return $false
}

# the first picture an entry carries, or $null. The card falls back to it when there is html
# but no layout to render: an Excel copy brings a metafile or a bitmap and never RTF.
function Get-RichPictureBlock([string]$ref) {
  $r = Get-RichRef $ref
  if ($null -eq $r) { return $null }
  foreach ($tag in @('P', 'D', 'E')) {
    foreach ($b in $r.Blocks) {
      if ($b.Tag -cne $tag) { continue }
      return $b
    }
  }
  return $null
}

# ---- inlining the pictures an html block points at --------------------------
# Word, Excel and browsers leave the copied pictures in a temp folder and reference them by
# path ('file:///.../msohtmlclip1/01/clip_image001.png'). That folder does not outlive the
# copy, so the entry would paste back with empty frames. Each referenced picture is read once
# and put into the buffer itself as a data: uri; the four header offsets are then recomputed,
# because they are byte positions in this very buffer.
#
# Only raster formats are inlined (a data: uri carrying a metafile is not something targets
# understand), and a buffer that is not valid UTF-8 is left alone: rewriting it would have to
# guess its code page.
$script:RichImageMime = @{
  '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'
  '.gif' = 'image/gif'; '.bmp' = 'image/bmp'
}

function Get-CfHtmlInlined([byte[]]$html, [int]$maxImageBytes, [int]$maxTotalBytes) {
  if ($null -eq $html -or $html.Length -lt 32 -or $maxImageBytes -le 0) { return $html }
  $strict = New-Object Text.UTF8Encoding $false, $true
  $text = ''
  try { $text = $strict.GetString($html) } catch { return $html }
  $headAt = Get-CfHtmlHeadLength $text
  if ($headAt -le 0) { return $html }
  $body = $text.Substring($headAt)
  $inlined = 0
  foreach ($hit in [regex]::Matches($body, 'src\s*=\s*["'']?(file:[^"''\s>]+)')) {
    $url = $hit.Groups[1].Value
    $path = ''
    try { $path = ([uri]$url).LocalPath } catch { $path = '' }
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
    $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
    if (-not $script:RichImageMime.ContainsKey($ext)) { continue }
    $size = [long]0
    try { $size = (Get-Item -LiteralPath $path).Length } catch { continue }
    if ($size -le 0 -or $size -gt $maxImageBytes) {
      Write-Log ('html image not inlined: ' + (Format-Size $size) + ' ' + (Split-Path -Leaf $path))
      continue
    }
    $data = ''
    try { $data = [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) } catch { continue }
    $body = $body.Replace($url, ('data:' + [string]$script:RichImageMime[$ext] + ';base64,' + $data))
    $inlined++
  }
  if ($inlined -eq 0) { return $html }
  $bytes = $strict.GetBytes($text.Substring(0, $headAt) + $body)
  if ($maxTotalBytes -gt 0 -and $bytes.Length -gt $maxTotalBytes) {
    Write-Log ('html inlining skipped: ' + [string]$bytes.Length + ' bytes over MaxRichBytes')
    return $html
  }
  return (Set-CfHtmlOffsets $bytes)
}

# the byte position where the html starts, taken from the header the block carries
function Get-CfHtmlHeadLength([string]$text) {
  $m = [regex]::Match($text, 'StartHTML:\s*(\d+)')
  if (-not $m.Success) { return 0 }
  $at = 0
  if (-not [int]::TryParse($m.Groups[1].Value, [ref]$at)) { return 0 }
  if ($at -le 0 -or $at -ge $text.Length) { return 0 }
  return $at
}

# the four offsets in the CF_HTML header are byte positions in the buffer itself, so they are
# recomputed after the buffer changed. The fragment is delimited by the marker comments the
# spec defines; without them the whole document is the fragment.
function Set-CfHtmlOffsets([byte[]]$bytes) {
  $strict = New-Object Text.UTF8Encoding $false, $true
  $text = ''
  try { $text = $strict.GetString($bytes) } catch { return $bytes }
  $headAt = Get-CfHtmlHeadLength $text
  if ($headAt -le 0) { return $bytes }
  $body = $text.Substring($headAt)
  # every offset is written with ten digits, so the header keeps its length whatever the
  # values are and can be measured once
  $head = $text.Substring(0, $headAt)
  $head = $head -replace 'StartHTML:\s*\d+', 'StartHTML:0000000000'
  $head = $head -replace 'EndHTML:\s*\d+', 'EndHTML:0000000000'
  $head = $head -replace 'StartFragment:\s*\d+', 'StartFragment:0000000000'
  $head = $head -replace 'EndFragment:\s*\d+', 'EndFragment:0000000000'
  $startHtml = $strict.GetByteCount($head)
  $startFrag = $startHtml
  $endFrag = $startHtml + $strict.GetByteCount($body)
  $sm = [regex]::Match($body, '<!--\s*StartFragment\s*-->')
  if ($sm.Success) {
    $after = $sm.Index + $sm.Length
    $startFrag = $startHtml + $strict.GetByteCount($body.Substring(0, $after))
    $em = [regex]::Match($body.Substring($after), '<!--\s*EndFragment\s*-->')
    if ($em.Success) { $endFrag = $startFrag + $strict.GetByteCount($body.Substring($after, $em.Index)) }
  }
  $endHtml = $startHtml + $strict.GetByteCount($body)
  $head = $head.Replace('StartHTML:0000000000', ('StartHTML:' + $startHtml.ToString('0000000000')))
  $head = $head.Replace('EndHTML:0000000000', ('EndHTML:' + $endHtml.ToString('0000000000')))
  $head = $head.Replace('StartFragment:0000000000', ('StartFragment:' + $startFrag.ToString('0000000000')))
  $head = $head.Replace('EndFragment:0000000000', ('EndFragment:' + $endFrag.ToString('0000000000')))
  return $strict.GetBytes($head + $body)
}

# ---- media accounting -------------------------------------------------------
# Sizes are carried in the payload / reference, so trimming never stats the disk.
function Get-RecordMediaBytes($record) {
  if ($null -eq $record) { return [long]0 }
  $img = Get-ImageRef ([string]$record.Payload)
  if ($null -ne $img) { return [long]$img.Bytes }
  $r = Get-RichRef ([string]$record.Rich)
  if ($null -ne $r) { return [long]$r.Bytes }
  return [long]0
}

# drop every media file no record points at any more (a delete, a trim, a clear)
function Remove-OrphanMedia($records) {
  $dir = Get-MediaDir
  if (-not (Test-Path -LiteralPath $dir)) { return }
  $keep = @{}
  foreach ($r in @($records)) {
    $img = Get-ImageRef ([string]$r.Payload)
    if ($null -ne $img) { $keep[$img.Sha1] = 1 }
    $rich = Get-RichRef ([string]$r.Rich)
    if ($null -ne $rich) { foreach ($b in $rich.Blocks) { $keep[$b.Sha1] = 1 } }
  }
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
    # <sha1>.thumb is derived from <sha1>.png and travels with it
    $key = [string]$f.BaseName
    if ($key.EndsWith('.thumb')) { $key = $key.Substring(0, $key.Length - 6) }
    if (-not $keep.ContainsKey($key)) {
      try { Remove-Item -LiteralPath $f.FullName -Force } catch { }
    }
  }
}

# ---- reading the HTML back as text -----------------------------------------
# Used only when a formatted entry has no RTF: the card then shows the words with the
# tags removed instead of a rendered page.
function Get-HtmlText([byte[]]$bytes) {
  if ($null -eq $bytes -or $bytes.Length -eq 0) { return '' }
  $start = 0
  $len = $bytes.Length
  try {
    $s = [Text.Encoding]::UTF8.GetString($bytes)
    $m = [regex]::Match($s, 'StartFragment:\s*(\d+)')
    if ($m.Success) {
      $e = [regex]::Match($s, 'EndFragment:\s*(\d+)')
      $a = [int]$m.Groups[1].Value
      $b = if ($e.Success) { [int]$e.Groups[1].Value } else { $bytes.Length }
      if ($a -ge 0 -and $b -gt $a -and $b -le $bytes.Length) { $start = $a; $len = $b - $a }
    }
  } catch { $start = 0; $len = $bytes.Length }
  $frag = [Text.Encoding]::UTF8.GetString($bytes, $start, $len)
  $frag = [regex]::Replace($frag, '(?is)<(script|style)[^>]*>.*?</\1>', ' ')
  $frag = [regex]::Replace($frag, '(?i)<br\s*/?>', "`n")
  $frag = [regex]::Replace($frag, '(?i)</(p|div|tr|li|h[1-6]|table)\s*>', "`n")
  $frag = [regex]::Replace($frag, '(?s)<[^>]+>', '')
  $frag = $frag.Replace('&nbsp;', ' ').Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&amp;', '&')
  try {
    $frag = [regex]::Replace($frag, '&#(\d+);', [System.Text.RegularExpressions.MatchEvaluator] { param($m) [string][char][int]$m.Groups[1].Value })
  } catch { }
  $frag = $frag -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ' '
  $frag = $frag -replace "[ \t]+", ' '
  $frag = ($frag -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join "`n"
  return $frag.Trim()
}

# ---- preview bitmaps --------------------------------------------------------
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

# bytes -> something drawable: a png goes straight in, a CF_DIB block needs the file header the
# clipboard leaves out, a metafile is rebuilt from its bits
function ConvertFrom-MediaBytes([byte[]]$bytes, [string]$tag) {
  if ($null -eq $bytes -or $bytes.Length -eq 0) { return $null }
  $ms = New-Object IO.MemoryStream
  try {
    if ($tag -ceq 'E') {
      $ms.Write($bytes, 0, $bytes.Length)
      $ms.Position = 0
      return (New-Object Drawing.Imaging.Metafile $ms)
    }
    $all = $bytes
    if ($tag -ceq 'D') { $all = Get-BmpBytes $bytes }
    if ($null -eq $all) { return $null }
    $ms.Write($all, 0, $all.Length)
    $ms.Position = 0
    return [Drawing.Image]::FromStream($ms)
  } catch {
    Write-Log ('media block decode failed (' + $tag + '): ' + $_.Exception.Message)
    return $null
  }
}

# a CF_DIB block is the bitmap info header plus the pixels, without the 14 byte file header a
# decoder expects in front of it
function Get-BmpBytes([byte[]]$dib) {
  if ($null -eq $dib -or $dib.Length -lt 40) { return $null }
  $header = [long][BitConverter]::ToUInt32($dib, 0)
  if ($header -lt 12 -or $header -gt $dib.Length) { return $null }
  $bits = [int][BitConverter]::ToUInt16($dib, 14)
  $comp = [int][BitConverter]::ToUInt32($dib, 16)
  $used = [long][BitConverter]::ToUInt32($dib, 32)
  $extra = 0
  if ($comp -eq 3 -or $comp -eq 6) { $extra = 12 }
  $palette = [long]0
  if ($used -gt 0) { $palette = $used * 4 }
  elseif ($bits -gt 0 -and $bits -le 8) { $palette = [long](1 -shl $bits) * 4 }
  $offset = [int](14 + $header + $extra + $palette)
  $out = New-Object byte[] (14 + $dib.Length)
  $out[0] = 0x42
  $out[1] = 0x4D
  [Array]::Copy([BitConverter]::GetBytes([int]$out.Length), 0, $out, 2, 4)
  [Array]::Copy([BitConverter]::GetBytes($offset), 0, $out, 10, 4)
  [Array]::Copy($dib, 0, $out, 14, $dib.Length)
  return $out
}

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

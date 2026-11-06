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
# Everything here is storage plus decode. Nothing in this file draws, and nothing touches a
# Graphics or a bitmap: the thumb file, the two bitmap caches and the three preview pictures
# live in lib/panel/media-render.ps1, which only the panel and the card load. The CF_HTML buffer
# itself - inlining the pictures a copy points at, and writing them back out for a paste - is
# lib/cfhtml.ps1: this file owns the files, that one owns the clipboard format.

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

# ---- the bitmaps drawn on screen -------------------------------------------
# Get-ImageThumbPath, Write-ImageThumb, the two bitmap caches, scaling and the three preview
# pictures live in lib/panel/media-render.ps1: only the panel and the card call them, and the
# capture path never needs GDI+.

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


# utils/image.ps1 - the bytes of a picture, read as a format rather than decoded.
#
# Both helpers exist because a picture is not always decoded: the preview card wants the shape
# of a png it never loads, and the clipboard hands a bitmap without the 14 byte file header a
# decoder expects in front of it. Nothing here opens a file, draws, or logs.

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

# a CF_DIB block is the bitmap info header plus the pixels, without the 14 byte file header a
# decoder expects in front of it
function ConvertTo-BmpBytes([byte[]]$dib) {
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

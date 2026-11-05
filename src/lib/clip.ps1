# lib/clip.ps1 - the only place that talks to the Windows clipboard.
#
# Everything above this layer works with strings: text, a file-list payload (leading char 1)
# or an image descriptor (leading char 3) that names a file under data\media. Keeping the
# WinForms / CF_HDROP / CF_HTML / CF_DIB details here is what makes the store and the picker
# easy to test, and keeps clipboard-ownership bugs in one file.

function Get-Text {
  Load-Forms
  for ($i = 0; $i -lt 10; $i++) {
    try {
      if (-not [Windows.Forms.Clipboard]::ContainsText()) { return '' }
      return [Windows.Forms.Clipboard]::GetText([Windows.Forms.TextDataFormat]::UnicodeText)
    } catch { Start-Sleep -Milliseconds 50 }
  }
  return $null
}

function Set-Text([string]$t) {
  Load-Forms
  for ($i = 0; $i -lt 10; $i++) {
    try {
      [Windows.Forms.Clipboard]::SetText($t, [Windows.Forms.TextDataFormat]::UnicodeText)
      return $true
    } catch { Start-Sleep -Milliseconds 50 }
  }
  return $false
}

# One clipboard snapshot in one clipboard-open window:
#   Text  - the payload the store keeps ('' when this snapshot has no payload of its own)
#   Rich  - @{ Html = [byte[]]; Rtf = [string] } or $null
#   Image - @{ Png = [byte[]]; W; H; Fmt } or $null
# Text wins over a bitmap on purpose: Word puts a picture of the selection on the clipboard
# together with every copy, and the formatting is what the user wants back - not an image of
# the paragraph. A screenshot or a browser "copy image" carries no text, so it still lands in
# the image branch.
function Get-ClipCapture {
  Load-Forms
  for ($i = 0; $i -lt 10; $i++) {
    try {
      if ([Windows.Forms.Clipboard]::ContainsFileDropList()) {
        $col = [Windows.Forms.Clipboard]::GetFileDropList()
        if ($null -ne $col -and $col.Count -gt 0) {
          $parts = New-Object System.Collections.Generic.List[string]
          foreach ($p in $col) { $parts.Add($p) }
          return @{ Text = ($FILESIG + ($parts -join "`n")); Rich = $null; Image = $null }
        }
      }
      if ([Windows.Forms.Clipboard]::ContainsText()) {
        $t = [Windows.Forms.Clipboard]::GetText([Windows.Forms.TextDataFormat]::UnicodeText)
        $rich = $null
        if ($script:CaptureRich) {
          try { $rich = Get-RichCapture } catch { $rich = $null }
        }
        return @{ Text = $t; Rich = $rich; Image = $null }
      }
      if (-not $script:CaptureImages) { return @{ Text = ''; Rich = $null; Image = $null } }
      $img = Get-ImageCapture
      if ($null -ne $img) { return @{ Text = ''; Rich = $null; Image = $img } }
      return @{ Text = ''; Rich = $null; Image = $null }
    } catch { Start-Sleep -Milliseconds 50 }
  }
  return $null
}

# The CF_HTML blob keeps the byte offsets of its own header, so it is stored and written back
# verbatim; the RTF is a .NET string either way. Anything over MaxRichBytes is skipped: the
# plain text is still captured by the caller.
function Get-RichCapture {
  $do = [Windows.Forms.Clipboard]::GetDataObject()
  if ($null -eq $do) { return $null }
  $html = $null
  $rtf = ''
  try {
    if ($do.GetDataPresent([Windows.Forms.DataFormats]::Html)) {
      $obj = $do.GetData([Windows.Forms.DataFormats]::Html)
      if ($obj -is [IO.Stream]) {
        $obj.Position = 0
        $ms = New-Object IO.MemoryStream
        $obj.CopyTo($ms)
        $html = $ms.ToArray()
      } elseif ($obj -is [byte[]]) {
        $html = $obj
      } elseif ($obj -is [string]) {
        $html = $Utf8.GetBytes([string]$obj)
      }
    }
  } catch { $html = $null }
  try {
    if ($do.GetDataPresent([Windows.Forms.DataFormats]::Rtf)) {
      $r = $do.GetData([Windows.Forms.DataFormats]::Rtf)
      if ($r -is [string]) { $rtf = [string]$r }
    }
  } catch { $rtf = '' }
  if ($null -eq $html -and -not $rtf) { return $null }
  $bytes = 0
  if ($null -ne $html) { $bytes += $html.Length }
  if ($rtf) { $bytes += $Utf8.GetByteCount($rtf) }
  if ($bytes -gt $script:MaxRichBytes) {
    Write-Log ('formatted text skipped: ' + [string]$bytes + ' bytes')
    return $null
  }
  return @{ Html = $html; Rtf = $rtf }
}

function New-ImageCaptureResult([byte[]]$png, [int]$w, [int]$h) {
  if ($null -eq $png -or $png.Length -eq 0) { return $null }
  if ($w -le 0 -or $h -le 0) { return $null }
  if ($png.Length -gt $script:MaxImageBytes) {
    Write-Log ('image skipped: ' + (Format-Size ([long]$png.Length)) + ' over MaxImageBytes')
    return $null
  }
  return @{ Png = $png; W = $w; H = $h; Fmt = 'PNG' }
}

function Get-ImageCapture {
  # the raw PNG wins: it is what the source app already encoded, and re-encoding a DIB costs
  # time without adding anything
  $do = $null
  try { $do = [Windows.Forms.Clipboard]::GetDataObject() } catch { $do = $null }
  if ($null -ne $do) {
    foreach ($name in @('PNG', 'image/png')) {
      try {
        if (-not $do.GetDataPresent($name)) { continue }
        $obj = $do.GetData($name)
        $bytes = $null
        if ($obj -is [IO.Stream]) {
          $obj.Position = 0
          $ms = New-Object IO.MemoryStream
          $obj.CopyTo($ms)
          $bytes = $ms.ToArray()
        } elseif ($obj -is [byte[]]) { $bytes = $obj }
        if ($null -eq $bytes -or $bytes.Length -lt 8) { continue }
        $w = 0
        $h = 0
        $probe = $null
        try {
          $ms = New-Object IO.MemoryStream
          $ms.Write($bytes, 0, $bytes.Length)
          $ms.Position = 0
          $probe = [Drawing.Image]::FromStream($ms)
          $w = [int]$probe.Width
          $h = [int]$probe.Height
        } catch { $w = 0 } finally { if ($null -ne $probe) { $probe.Dispose() } }
        $cap = New-ImageCaptureResult $bytes $w $h
        if ($null -ne $cap) { return $cap }
      } catch { }
    }
  }
  try { if (-not [Windows.Forms.Clipboard]::ContainsImage()) { return $null } } catch { return $null }
  # no PNG on offer: encode the DIB once, because the media file has to be a real image
  $src = $null
  try {
    $src = [Windows.Forms.Clipboard]::GetImage()
    if ($null -eq $src) { return $null }
    $w = [int]$src.Width
    $h = [int]$src.Height
    if (([long]$w * [long]$h) -gt 40000000) {
      Write-Log ('image skipped: ' + [string]$w + 'x' + [string]$h + ' is too large')
      return $null
    }
    $ms = New-Object IO.MemoryStream
    $src.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    return (New-ImageCaptureResult $ms.ToArray() $w $h)
  } catch {
    Write-Log ('image read failed: ' + $_.Exception.Message)
    return $null
  } finally {
    if ($null -ne $src) { $src.Dispose() }
  }
}

# one clipboard item as a payload string: text, FILESIG + paths, or an image descriptor
function Get-ClipItem {
  $cap = Get-ClipCapture
  if ($null -eq $cap) { return $null }
  if ($null -ne $cap.Image) { return (New-ImagePayload $cap.Image.Png $cap.Image.W $cap.Image.H $cap.Image.Fmt) }
  return [string]$cap.Text
}

function Set-ItemDataObject($do) {
  for ($i = 0; $i -lt 10; $i++) {
    try {
      [Windows.Forms.Clipboard]::SetDataObject($do, $true)
      return $true
    } catch { Start-Sleep -Milliseconds 50 }
  }
  return $false
}

# An image goes back as the PNG the store holds plus a DIB rendering: modern targets read
# the PNG, older ones only understand the bitmap.
function Set-ImageItem([string]$payload) {
  $ref = Get-ImageRef $payload
  if ($null -eq $ref) { return $false }
  $bytes = Read-ImageBytes $ref.Sha1
  if ($null -eq $bytes) { Write-Log 'image file is missing'; return $false }
  $img = $null
  try {
    $ms = New-Object IO.MemoryStream
    $ms.Write($bytes, 0, $bytes.Length)
    $ms.Position = 0
    $img = [Drawing.Image]::FromStream($ms)
    $do = New-Object Windows.Forms.DataObject
    $do.SetImage($img)
    $png = New-Object IO.MemoryStream
    $png.Write($bytes, 0, $bytes.Length)
    $png.Position = 0
    $do.SetData('PNG', $png)
    return (Set-ItemDataObject $do)
  } catch {
    Write-Log ('set image failed: ' + $_.Exception.Message)
    return $false
  } finally {
    if ($null -ne $img) { $img.Dispose() }
  }
}

# Formatted paste: the plain text is always there for targets that understand nothing else,
# and the original HTML / RTF ride along so Word, WordPad and mail clients keep the layout.
function Set-RichItem([string]$text, [string]$rich) {
  try {
    $do = New-Object Windows.Forms.DataObject
    $do.SetData([Windows.Forms.DataFormats]::UnicodeText, [string]$text)
    $html = Read-RichHtml $rich
    if ($null -ne $html -and $html.Length -gt 0) {
      $ms = New-Object IO.MemoryStream
      $ms.Write($html, 0, $html.Length)
      $ms.Position = 0
      $do.SetData([Windows.Forms.DataFormats]::Html, $ms)
    }
    $rtf = Read-RichRtf $rich
    if ($rtf) { $do.SetData([Windows.Forms.DataFormats]::Rtf, $rtf) }
    return (Set-ItemDataObject $do)
  } catch {
    Write-Log ('set formatted text failed: ' + $_.Exception.Message)
    return $false
  }
}

function Set-ClipItem([string]$entry, [string]$rich = '') {
  if (Test-FilePayload $entry) {
    Load-Forms
    $sc = New-Object System.Collections.Specialized.StringCollection
    foreach ($p in @($entry.Substring(1) -split "`n" | Where-Object { $_ })) { [void]$sc.Add($p) }
    for ($i = 0; $i -lt 10; $i++) {
      try { [Windows.Forms.Clipboard]::SetFileDropList($sc); return $true } catch { Start-Sleep -Milliseconds 50 }
    }
    return $false
  }
  Load-Forms
  if (Test-ImagePayload $entry) { return (Set-ImageItem $entry) }
  if ($rich -and $script:PasteRich) {
    if (Set-RichItem $entry $rich) { return $true }
  }
  return (Set-Text $entry)
}

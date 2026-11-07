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

# A write made from inside this process (the panel pasting an entry, or `pick` under a running
# daemon) must not come back as a brand new capture: remember the sequence number that came
# with it. The capture loop in lib/serve.ps1 owns the state and compares against it; the
# payload itself is deliberately not remembered - a text that is copied again has to be
# captured again, even when this process put it on the clipboard a moment before.
function Set-LastCapture([string]$payload) {
  try { $script:LastSeq = [Cb.Win]::GetClipboardSequenceNumber() } catch { }
  # A paste is also "this one again": the row moves to the top of the history so the next
  # panel shows it first. Touch-Record keeps its marks, its rich sidecar and its blob.
  if (Get-Command Touch-Record -ErrorAction SilentlyContinue) { [void](Touch-Record ([string]$payload)) }
}

# One clipboard snapshot in one clipboard-open window:
#   Text  - the payload the store keeps ('' when this snapshot has no payload of its own)
#   Rich  - @{ Html = [byte[]]; Rtf = [byte[]]; Blocks = @(@{ Tag; Data }) } or $null
#           Tag is P (png) / D (bitmap) / E (metafile): the picture flavors a target may
#           pick instead of the html, an Excel chart or a Word shape being the two cases
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

# One line per capture, for the log: what came off the clipboard, not what was stored - a
# picture is a descriptor and a formatted copy is a block list, and the two are what a report
# about "the paste had no picture" needs to show.
function Format-Capture([string]$text, $cap) {
  if ($null -eq $cap) { return 'nothing' }
  if ($null -ne $cap.Image) {
    return ('image ' + [string]$cap.Image.W + 'x' + [string]$cap.Image.H + ' ' + (Format-Size ([long]$cap.Image.Png.Length)))
  }
  $what = 'text ' + [string]$text.Length + ' chars'
  if ($null -ne $cap.Rich) {
    $parts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $cap.Rich.Html) { $parts.Add('html ' + (Format-Size ([long]$cap.Rich.Html.Length))) }
    if ($null -ne $cap.Rich.Rtf) { $parts.Add('rtf ' + (Format-Size ([long]$cap.Rich.Rtf.Length))) }
    foreach ($b in @($cap.Rich.Blocks)) {
      if ($null -eq $b -or $null -eq $b.Data) { continue }
      $parts.Add('block ' + [string]$b.Tag + ' ' + (Format-Size ([long]$b.Data.Length)))
    }
    if ($parts.Count -gt 0) { $what = $what + ' + ' + ($parts -join ', ') }
  }
  return $what
}

# The whole formatted snapshot: the html, the rtf and the picture blocks a target may prefer.
# CF_HTML keeps byte offsets into its own buffer and RTF is an 8-bit format, so every block is
# read raw and stored byte for byte - a .NET string decodes with the ANSI code page (UTF-8 html
# becomes mojibake and the offsets stop pointing at the tags), which is what made Word and
# Excel paste garbage. The html gets its temp-file pictures inlined first (see
# Get-CfHtmlInlined). Each part has its own cap, so an oversized rtf no longer costs the html;
# an rtf over MaxRtfBytes is dropped and the entry pastes as text.
function Get-RichCapture {
  $html = $null
  $rtf = $null
  $png = $null
  $dib = $null
  $emf = $null
  try {
    Load-Forms
    Add-Native
    [Cb.Win]::ReadRichFormats([ref]$html, [ref]$rtf, [ref]$png, [ref]$dib, [ref]$emf)
  } catch {
    $html = $null
    $rtf = $null
  }
  if ($null -eq $html -and $null -eq $rtf) {
    # no native layer (or no such format): fall back to the data object, where a stream is
    # still exact and a string has to be turned back into the ANSI bytes it came from
    try {
      $do = [Windows.Forms.Clipboard]::GetDataObject()
      if ($null -ne $do -and $do.GetDataPresent([Windows.Forms.DataFormats]::Html)) {
        $obj = $do.GetData([Windows.Forms.DataFormats]::Html)
        if ($obj -is [IO.Stream]) {
          $obj.Position = 0
          $ms = New-Object IO.MemoryStream
          $obj.CopyTo($ms)
          $html = $ms.ToArray()
        } elseif ($obj -is [byte[]]) {
          $html = $obj
        } elseif ($obj -is [string]) {
          $html = [Text.Encoding]::Default.GetBytes([string]$obj)
        }
      }
      if ($null -ne $do -and $do.GetDataPresent([Windows.Forms.DataFormats]::Rtf)) {
        $obj2 = $do.GetData([Windows.Forms.DataFormats]::Rtf)
        if ($obj2 -is [byte[]]) { $rtf = $obj2 }
        elseif ($obj2 -is [string]) { $rtf = [Text.Encoding]::Default.GetBytes([string]$obj2) }
      }
    } catch { }
  }
  # The part has its own cap, so a large rtf cannot cost the html. Over MaxRtfBytes the rtf is
  # not kept at all and the entry pastes as text; nothing is stripped here - the card decides
  # what it is willing to lay out (see ConvertTo-CardRtf).
  if ($null -ne $rtf -and $rtf.Length -eq 0) { $rtf = $null }
  if ($null -ne $rtf -and $rtf.Length -gt $script:MaxRtfBytes) {
    Write-Log ('formatted text rtf skipped: ' + [string]$rtf.Length + ' bytes')
    $rtf = $null
  }
  if ($null -ne $html -and $html.Length -gt 0) {
    $html = Get-CfHtmlInlined $html $script:InlineImageUpToBytes $script:MaxHtmlBytes
    if ($html.Length -gt $script:MaxHtmlBytes) {
      Write-Log ('formatted text html skipped: ' + [string]$html.Length + ' bytes')
      $html = $null
    }
  } else { $html = $null }
  $blocks = New-Object System.Collections.Generic.List[object]
  foreach ($one in @(@{ Tag = 'P'; Data = $png }, @{ Tag = 'D'; Data = $dib }, @{ Tag = 'E'; Data = $emf })) {
    if ($null -eq $one.Data -or $one.Data.Length -lt 8) { continue }
    if ($one.Data.Length -gt $script:MaxImageBytes) {
      Write-Log ('formatted text block skipped: ' + (Format-Size ([long]$one.Data.Length)))
      continue
    }
    $blocks.Add($one)
  }
  if ($null -eq $html -and $null -eq $rtf -and $blocks.Count -eq 0) { return $null }
  return @{ Html = $html; Rtf = $rtf; Blocks = $blocks.ToArray() }
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
    # every block goes back as the exact bytes it was captured as: a string would be encoded
    # again on the way out, and CF_HTML's own byte offsets would stop matching
    Set-RichBlockData $do $rich 'H' ([Windows.Forms.DataFormats]::Html)
    Set-RichBlockData $do $rich 'T' ([Windows.Forms.DataFormats]::Rtf)
    Set-RichBlockData $do $rich 'P' 'PNG'
    Set-RichBlockData $do $rich 'D' ([Windows.Forms.DataFormats]::Dib)
    Set-RichBlockData $do $rich 'E' ([Windows.Forms.DataFormats]::EnhancedMetafile)
    # what actually went on the clipboard: a paste that arrives without its pictures is a
    # question about this line, and the answer is the block list it names
    $r = Get-RichRef $rich
    if ($null -ne $r) {
      $parts = New-Object System.Collections.Generic.List[string]
      foreach ($b in $r.Blocks) { $parts.Add([string]$b.Tag + ' ' + (Format-Size ([long]$b.Bytes))) }
      Write-Log ('clipboard: text ' + [string]$text.Length + ' chars + ' + ($parts -join ', '))
    }
    return (Set-ItemDataObject $do)
  } catch {
    Write-Log ('set formatted text failed: ' + $_.Exception.Message)
    return $false
  }
}

# one block onto the data object. A png and a bitmap are byte buffers; a metafile has to be
# rebuilt as an object first. A block that cannot be restored is logged and skipped, so the
# text and the other blocks still go back.
function Set-RichBlockData($do, [string]$rich, [string]$tag, [string]$format) {
  $bytes = Read-RichBlock $rich $tag
  if ($null -eq $bytes -or $bytes.Length -eq 0) { return }
  # Word and friends resolve <img> through a file the buffer names, never through a data: uri,
  # so the pictures inlined at capture time have to exist as files again for this paste
  if ($tag -ceq 'H') { $bytes = Get-CfHtmlOnDisk $bytes }
  if ($tag -ceq 'E') {
    $mf = ConvertFrom-MediaBytes $bytes 'E'
    if ($null -eq $mf) { Write-Log 'emf block skipped: it does not decode'; return }
    try { $do.SetData($format, $mf) } catch { Write-Log ('emf block skipped: ' + $_.Exception.Message) }
    return
  }
  $ms = New-Object IO.MemoryStream
  $ms.Write($bytes, 0, $bytes.Length)
  $ms.Position = 0
  $do.SetData($format, $ms)
}

function Set-ClipItem([string]$entry, [string]$rich = '') {
  if (Test-FilePayload $entry) {
    Load-Forms
    $paths = @(Get-FilePayloadPaths $entry)
    $sc = New-Object System.Collections.Specialized.StringCollection
    foreach ($p in $paths) { [void]$sc.Add($p) }
    # A file list alone is useless in a text box: Explorer's address bar, a terminal and an
    # editor all paste nothing. The text rides along unless PasteFilesAsText=0, while
    # Explorer itself still prefers the CF_HDROP the drop list puts there.
    $do = New-Object Windows.Forms.DataObject
    $do.SetFileDropList($sc)
    if ($script:PasteFilesAsText -and $paths.Count -gt 0) {
      $do.SetData([Windows.Forms.DataFormats]::UnicodeText, ($paths -join [Environment]::NewLine))
    }
    return (Set-ItemDataObject $do)
  }
  Load-Forms
  if (Test-ImagePayload $entry) { return (Set-ImageItem $entry) }
  if ($rich -and $script:PasteRich) {
    if (Set-RichItem $entry $rich) { return $true }
  }
  return (Set-Text $entry)
}

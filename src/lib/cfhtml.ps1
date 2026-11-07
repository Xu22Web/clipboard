# lib/cfhtml.ps1 - the CF_HTML buffer, read and rewritten: what a formatted copy carries
# besides its text.
#
# The format is a header of byte offsets followed by the document, and the pictures a copy
# refers to are files in a temp folder the source application owns. Both directions of that
# interchange live here, because both are the same problem - the buffer points somewhere else:
#
#   capture  the referenced pictures are read once and put into the buffer as data: uris, so
#            the entry still pastes after the source folder is gone (Get-CfHtmlInlined)
#   paste    the pictures become files again next to the buffer, because Word, Excel and
#            PowerPoint resolve <img> through a path and ignore a data: uri; a picture that is
#            gone leaves a placeholder frame instead of an empty one (Get-CfHtmlOnDisk)
#
# Either rewrite changes the buffer length, so the four offsets are recomputed from the text
# itself (Set-CfHtmlOffsets). Nothing here touches a record, the store or the disk layout of an
# entry: lib/media.ps1 owns the files, this file owns the clipboard format, and only the paste
# path (lib/clip.ps1) and the tests load it.

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
    Write-Log ('html inlining skipped: ' + [string]$bytes.Length + ' bytes over MaxHtmlBytes')
    return $html
  }
  return (Set-CfHtmlOffsets $bytes)
}

# the byte position where the html starts, taken from the header the block carries
function Get-CfHtmlHeadLength([string]$text) {
  $at = 0
  $m = [regex]::Match($text, 'StartHTML:\s*(\d+)')
  if ($m.Success) { [void][int]::TryParse($m.Groups[1].Value, [ref]$at) }
  if ($at -gt 0 -and $at -lt $text.Length) { return $at }
  # A buffer whose StartHTML is zero or points outside itself: rather than give up on the
  # formatting, take the header to be everything before the first tag, since CF_HTML always
  # closes its last header line with a break and no header line contains '<'.
  $tag = $text.IndexOf('<')
  if ($tag -gt 0) {
    $nl = $text.LastIndexOf("`n", $tag - 1)
    if ($nl -ge 0) { return ($nl + 1) }
  }
  return 0
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

# ---- putting the inlined pictures back on disk ------------------------------
# Word, Excel and PowerPoint do not read a data: uri inside CF_HTML: they resolve every <img>
# through a file the buffer points at, which is exactly how they write their own copy
# ('file:///.../msohtmlclip1/01/clip_image001.png'). An entry is stored with its pictures
# inlined so it survives the source folder disappearing, so the paste has to write them out
# again - otherwise the text arrives and every picture is an empty frame.
#
# The folder is content addressed: the same picture is written once, whichever entry and
# whichever paste it comes from.
$script:PasteImageDir = ''

function Get-PasteImageDir {
  if ($script:PasteImageDir) { return $script:PasteImageDir }
  $dir = Join-Path ([IO.Path]::GetTempPath()) 'clipboard-paste'
  try {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  } catch { Write-Log ('paste folder failed: ' + $_.Exception.Message) }
  # a day is long enough for the target application to have read the pictures; after that the
  # files are only leftovers of a paste nobody is going to finish
  try {
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
      if (([DateTime]::UtcNow - $f.LastWriteTimeUtc).TotalHours -gt 24) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
      }
    }
  } catch { }
  $script:PasteImageDir = $dir
  return $dir
}

# the extension a data: uri mime type names, '' when it is not a raster format we can hand on
function Get-PasteImageExt([string]$mime) {
  switch (([string]$mime).ToLowerInvariant()) {
    'png' { return '.png' }
    'jpeg' { return '.jpg' }
    'jpg' { return '.jpg' }
    'gif' { return '.gif' }
    'bmp' { return '.bmp' }
  }
  return ''
}

# the src a tag names, quoted or bare, '' when it names none
function Get-CfHtmlImgSrc([string]$tag) {
  $m = [regex]::Match($tag, '(?is)\bsrc\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s>]+))')
  if (-not $m.Success) { return '' }
  if ($m.Groups[1].Success) { return [string]$m.Groups[1].Value }
  if ($m.Groups[2].Success) { return [string]$m.Groups[2].Value }
  return [string]$m.Groups[3].Value
}

# What a picture that is not there any more leaves behind. A picture over
# InlineImageUpToBytes is not inlined, and an html block stored with file: paths points at the
# temp folder the source app owned - both are gone by paste time, and the target would draw an
# empty frame, which reads as a broken paste. A dashed frame of the picture's footprint says
# what happened instead, so the sentence around it still makes sense and the reader knows
# something was cut.
function Get-CfHtmlPlaceholder([string]$tag) {
  $w = 0
  $h = 0
  $m = [regex]::Match($tag, '(?i)\bwidth\s*[=:]\s*["'']?(\d+)')
  if ($m.Success) { [void][int]::TryParse($m.Groups[1].Value, [ref]$w) }
  $m = [regex]::Match($tag, '(?i)\bheight\s*[=:]\s*["'']?(\d+)')
  if ($m.Success) { [void][int]::TryParse($m.Groups[1].Value, [ref]$h) }
  # keep the footprint, but never let one missing picture own the page
  if ($w -le 0) { $w = 160 }
  if ($h -le 0) { $h = [int][Math]::Round($w * 9 / 16) }
  if ($w -lt 96) { $h = [int][Math]::Round($h * 96 / $w); $w = 96 }
  if ($w -gt 360) { $h = [int][Math]::Round($h * 360 / $w); $w = 360 }
  if ($h -lt 32) { $h = 32 }
  if ($h -gt 240) { $h = 240 }
  $style = 'display:inline-block;width:' + [string]$w + 'px;height:' + [string]$h + 'px;' +
    'border:1px dashed #a6a6a6;border-radius:6px;color:#8c8c8c;' +
    'font-size:12px;line-height:' + [string]$h + 'px;text-align:center;vertical-align:middle;overflow:hidden'
  return ('<span style="' + $style + '">[ image not saved ]</span>')
}

# every picture in the buffer becomes a file next to the entry, and the four offsets are
# recomputed because the buffer changed length. Two kinds come through here: the data: uris the
# entry kept, and the file: paths it had to leave alone - a file that still exists is copied out
# of the temp folder, one that does not becomes a placeholder frame (Get-CfHtmlPlaceholder).
# A buffer with no <img> at all comes back as it was: this runs on the paste path, so plain
# formatted text must not pay for it.
function Get-CfHtmlOnDisk([byte[]]$html) {
  if ($null -eq $html -or $html.Length -lt 32) { return $html }
  $strict = New-Object Text.UTF8Encoding $false, $true
  $text = ''
  try { $text = $strict.GetString($html) } catch { return $html }
  if ($text.IndexOf('<img', [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $html }
  $headAt = Get-CfHtmlHeadLength $text
  if ($headAt -le 0) { return $html }
  $head = $text.Substring(0, $headAt)
  $body = $text.Substring($headAt)
  $dir = Get-PasteImageDir
  $sb = New-Object Text.StringBuilder $body
  # inlined pictures first, because that rewrite changes the length the tags are measured against
  $hits = @([regex]::Matches($body, 'data:image/([a-zA-Z+]+);base64,([A-Za-z0-9+/=]+)'))
  # back to front: an earlier replacement would move every later index
  for ($i = $hits.Count - 1; $i -ge 0; $i--) {
    $hit = $hits[$i]
    $ext = Get-PasteImageExt $hit.Groups[1].Value
    if (-not $ext) { continue }
    $bytes = $null
    try { $bytes = [Convert]::FromBase64String($hit.Groups[2].Value) } catch { continue }
    if ($null -eq $bytes -or $bytes.Length -eq 0) { continue }
    try {
      $path = Join-Path $dir ((Get-MediaSha1 $bytes $null) + $ext)
      if (-not (Test-Path -LiteralPath $path)) { [IO.File]::WriteAllBytes($path, $bytes) }
      [void]$sb.Remove($hit.Index, $hit.Length)
      [void]$sb.Insert($hit.Index, ([uri]$path).AbsoluteUri)
    } catch {
      Write-Log ('paste picture not written: ' + $_.Exception.Message)
    }
  }
  $newBody = $sb.ToString()
  $tags = @([regex]::Matches($newBody, '(?is)<img\b[^>]*>'))
  $frame = New-Object Text.StringBuilder $newBody
  for ($i = $tags.Count - 1; $i -ge 0; $i--) {
    $tag = $tags[$i]
    $src = Get-CfHtmlImgSrc $tag.Value
    # a uri the target can fetch on its own, and a picture already written out above
    if ($src -match '^(?i)(data:|https?:|cid:)') { continue }
    $done = $false
    if ($src -match '^(?i)file:') {
      $path = ''
      try { $path = ([uri]$src).LocalPath } catch { $path = '' }
      if ($path -and (Test-Path -LiteralPath $path)) {
        try {
          $bytes = [IO.File]::ReadAllBytes($path)
          $copy = Join-Path $dir ((Get-MediaSha1 $bytes $null) + [IO.Path]::GetExtension($path).ToLowerInvariant())
          if (-not (Test-Path -LiteralPath $copy)) { [IO.File]::WriteAllBytes($copy, $bytes) }
          [void]$frame.Remove($tag.Index, $tag.Length)
          [void]$frame.Insert($tag.Index, $tag.Value.Replace($src, ([uri]$copy).AbsoluteUri))
          $done = $true
        } catch {
          Write-Log ('paste picture not copied: ' + $_.Exception.Message)
        }
      }
    }
    if ($done) { continue }
    [void]$frame.Remove($tag.Index, $tag.Length)
    [void]$frame.Insert($tag.Index, (Get-CfHtmlPlaceholder $tag.Value))
  }
  $finalBody = $frame.ToString()
  if ($finalBody -ceq $body) { return $html }
  return (Set-CfHtmlOffsets ($strict.GetBytes($head + $finalBody)))
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

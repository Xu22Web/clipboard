# utils/cfhtml.ps1 - the CF_HTML header and the tags inside it, as text.
#
# A formatted copy on the clipboard is a CF_HTML buffer: a header of byte offsets followed by
# the document. Every rewrite of that buffer changes its length, so the four offsets have to be
# recomputed from the text itself - that and the tag reading below are pure string work, which
# is why they live here.
#
# lib/cfhtml.ps1 keeps the two directions of the interchange, because both touch the disk: the
# pictures a capture points at are read and inlined (so the entry still pastes after the temp
# folder is gone), and the pictures a paste needs are written out again (because Word, Excel and
# PowerPoint resolve <img> through a path and ignore a data: uri).

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
  # A soft chip rather than a dashed frame: the same quiet grey the panel uses for secondary
  # text, a hairline border and a barely tinted fill. It reads as "not part of the document"
  # in Word and in a browser alike, and it does not compete with the words around it.
  $style = 'display:inline-block;width:' + [string]$w + 'px;height:' + [string]$h + 'px;' +
    'border:1px solid #e3e3e3;border-radius:6px;background:#fafafa;color:#8c8c8c;' +
    "font-family:'Segoe UI',Segoe UI,sans-serif;font-size:11px;line-height:" + [string]$h + 'px;' +
    'text-align:center;vertical-align:middle;overflow:hidden'
  return ('<span style="' + $style + '">image not saved</span>')
}

# the HTML back as text: used only when a formatted entry has no RTF, so the card shows the
# words with the tags removed instead of a rendered page
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

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
# itself (utils/cfhtml.ps1 owns that and the tag reading; this file owns the files). Nothing
# here touches a record, the store or the disk layout of an entry: lib/media.ps1 owns the files,
# this file owns the clipboard format, and only the paste path (lib/clip.ps1) and the tests
# load it.

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

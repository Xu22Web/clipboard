# utils/storefile.ps1 - one file on disk, handled as a file: stamp it, read it, append to it,
# replace it. Nothing here knows what a record is.
#
# lib/store.ps1 owns the format (the RS / US delimiters, the flags byte, blobs, de-duplication,
# the order rows come back in); this file only moves text in and out of one path. That is the
# seam where a different container - a second file, a compressed one, a database - could be
# swapped in without touching the record logic, and it is what lets the file layer be tested on
# its own: a missing file, a half written line, a read-only folder.
#
# Every call takes the path and keeps no state, so two stores open at once (the sandbox copy
# the tests use, the real one the panel uses) cannot reach each other through this file.

# UTF-8 without a BOM: the store is parsed by splitting on a delimiter, and a BOM would land
# inside the first field and make the whole file unreadable.
function Get-StoreFileEncoding {
  return (New-Object Text.UTF8Encoding $false)
}

# size + write time: the identity of the file for one process, used to invalidate the read
# cache and to tell "nothing changed" from "somebody wrote"
function Get-StoreFileStamp([string]$path) {
  try {
    $fi = Get-Item -LiteralPath $path -ErrorAction Stop
    return ([string]$fi.Length + ':' + [string]$fi.LastWriteTimeUtc.Ticks)
  } catch { return 'none' }
}

function Test-StoreFilePath([string]$path) {
  try { return [bool](Test-Path -LiteralPath $path) } catch { return $false }
}

# -1 means "no such file"; 0 means an existing but empty one, which a writer may fill in
function Get-StoreFileSize([string]$path) {
  try { return [long](Get-Item -LiteralPath $path -ErrorAction Stop).Length } catch { return [long]-1 }
}

# the whole file, '' when it is missing or unreadable
function Read-StoreFileText([string]$path) {
  try { return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) } catch { return '' }
}

# the first $count bytes as text: the header lives there, and the store can be megabytes
function Read-StoreFileHead([string]$path, [int]$count) {
  $head = ''
  try {
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
      $buf = New-Object byte[] $count
      $n = 0
      # a single Read may come back short, and half a tag would read as a foreign layout
      while ($n -lt $count) {
        $got = $fs.Read($buf, $n, $count - $n)
        if ($got -le 0) { break }
        $n += $got
      }
      if ($n -gt 0) { $head = [Text.Encoding]::UTF8.GetString($buf, 0, $n) }
    } finally { $fs.Dispose() }
  } catch { }
  return $head
}

# One line at the end of the file, creating it when it is missing or empty. $head is what a
# fresh file starts with. Returns $true when the text is on disk; a caller that gets $false
# falls back to a full rewrite.
function Append-StoreFileText([string]$path, [string]$text, [string]$head) {
  try {
    $size = Get-StoreFileSize $path
    if ($size -le 0) { [IO.File]::WriteAllText($path, ($head + $text), (Get-StoreFileEncoding)) }
    else { [IO.File]::AppendAllText($path, $text, (Get-StoreFileEncoding)) }
    return $true
  } catch { return $false }
}

# Replace the whole file. It is written beside it and moved over the original, so a crash
# leaves either the old content or the new one - never half a history.
function Write-StoreFileText([string]$path, [string]$text) {
  $tmp = $path + '.tmp'
  try {
    [IO.File]::WriteAllText($tmp, $text, (Get-StoreFileEncoding))
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $true
  } catch {
    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
    return $false
  }
}

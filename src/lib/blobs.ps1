# lib/blobs.ps1 - a payload too big for the history file, kept as its own file.
#
# A store line is a few KB at most: anything past BlobChars is written to data\blobs\<sha1>.txt
# and the line carries a reference instead. The name is the content hash, so the same 200 KB
# text captured twice costs one file, and a blob nobody points at any more is reclaimed in the
# same pass that trims the store.
#
# Nothing here parses a record: it takes text and a reference string, and the caller decides
# what a reference looks like (base.ps1 owns $script:BlobMark).

function Get-BlobDir { return (Join-Path $StoreDir 'blobs') }

function Save-Blob([string]$text) {
  $hex = Get-TextSha1Hex $text
  $dir = Get-BlobDir
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $path = Join-Path $dir ($hex + '.txt')
  if (-not (Test-Path -LiteralPath $path)) { [IO.File]::WriteAllText($path, $text, $Utf8) }
  return $hex
}

function Read-Blob([string]$ref) {
  $hex = $ref.Substring(([string]$script:BlobMark).Length)
  try { return [IO.File]::ReadAllText((Join-Path (Get-BlobDir) ($hex + '.txt')), [Text.Encoding]::UTF8) } catch { return $null }
}

# drop the blobs no record points at any more (a delete, a trim, a clear)
function Remove-OrphanBlobs($records) {
  $dir = Get-BlobDir
  if (-not (Test-Path -LiteralPath $dir)) { return }
  $keep = @{}
  foreach ($r in @($records)) { if ([string]$r.Blob) { $keep[[string]$r.Blob] = 1 } }
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.txt' -ErrorAction SilentlyContinue)) {
    if (-not $keep.ContainsKey([string]$f.BaseName)) { try { Remove-Item -LiteralPath $f.FullName -Force } catch { } }
  }
}

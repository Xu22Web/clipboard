# utils/hash.ps1 - the hash a file is named after.
#
# A blob, an image and a rich-text block are all stored under the hash of their content, so the
# same 200 KB text or the same picture captured twice costs one file. SHA1, lower case hex, no
# separators: that is the name. Nothing here opens a file.

# the hex of the SHA1 over the bytes; $null counts as no bytes at all
function Get-Sha1Hex([byte[]]$bytes) {
  if ($null -eq $bytes) { $bytes = New-Object byte[] 0 }
  $sha = [Security.Cryptography.SHA1]::Create()
  try {
    return (([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant())
  } finally { $sha.Dispose() }
}

# the hex of the SHA1 over a string, taken as UTF-8
function Get-TextSha1Hex([string]$text) {
  $bytes = New-Object byte[] 0
  if ($null -ne $text) { $bytes = [Text.Encoding]::UTF8.GetBytes($text) }
  return (Get-Sha1Hex $bytes)
}

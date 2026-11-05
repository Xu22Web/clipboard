# utils/pinyin.ps1 - the first letter of a hanzi, without a 7000 entry table.
#
# The level-1 block of GB2312 (0xB0A1..0xD7F9) is ordered by pinyin, so the initial of a
# character is a range lookup on its GB2312 code. Level-2 is ordered by radical and has no
# pinyin order at all, so those characters answer '' - they are simply not matched by an
# initial. Encoding 936 ships with Windows, so nothing has to be installed or embedded.

# The first GB2312 code of each initial, in table order.
function Get-PinyinBounds {
  if ($null -ne $script:PinyinBounds) { return $script:PinyinBounds }
  $script:PinyinBounds = @(
    @('A', 0xB0A1), @('B', 0xB0C5), @('C', 0xB2C1), @('D', 0xB4EE), @('E', 0xB6EA),
    @('F', 0xB7A2), @('G', 0xB8C1), @('H', 0xB9FE), @('J', 0xBBF7), @('K', 0xBFA6),
    @('L', 0xC0AC), @('M', 0xC2E8), @('N', 0xC4C3), @('O', 0xC5B6), @('P', 0xC5BE),
    @('Q', 0xC6DA), @('R', 0xC8BB), @('S', 0xC8F6), @('T', 0xCBFA), @('W', 0xCDDA),
    @('X', 0xCEF4), @('Y', 0xD1B9), @('Z', 0xD4D1)
  )
  return $script:PinyinBounds
}

function Get-PinyinEncoding {
  if ($null -ne $script:PinyinCodePage) { return $script:PinyinCodePage }
  try { $script:PinyinCodePage = [Text.Encoding]::GetEncoding(936) } catch { $script:PinyinCodePage = $false }
  return $script:PinyinCodePage
}

# '' for anything that is not a level-1 hanzi (latin letters are handled by the caller)
function Get-PinyinInitial([char]$ch) {
  $code = [int]$ch
  if ($code -lt 0x4E00 -or $code -gt 0x9FA5) { return '' }
  $enc = Get-PinyinEncoding
  if (-not $enc) { return '' }
  $bytes = $null
  try { $bytes = $enc.GetBytes([string]$ch) } catch { return '' }
  if ($null -eq $bytes -or $bytes.Length -ne 2) { return '' }
  $hi = [int]$bytes[0]
  $lo = [int]$bytes[1]
  if ($hi -lt 0xB0 -or $hi -gt 0xD7) { return '' }
  # the table holds the first code of each initial, so the answer is the last bound reached
  $letter = ''
  foreach ($row in @(Get-PinyinBounds)) {
    $bound = [int]$row[1]
    $bh = ($bound -shr 8) -band 0xFF
    $bl = $bound -band 0xFF
    if (($hi -gt $bh) -or (($hi -eq $bh) -and ($lo -ge $bl))) { $letter = [string]$row[0] } else { break }
  }
  return $letter
}

# The initials of a text: latin letters and digits pass through lower cased, a hanzi gives its
# initial, everything else is skipped. Only the head of the text is read - an initial query is
# typed against what the user can see, and walking a 200 KB payload on every keystroke would
# cost more than the answer is worth.
function Get-PinyinInitials([string]$text, [int]$chars = 128) {
  if ([string]::IsNullOrEmpty($text)) { return '' }
  $n = $text.Length
  if ($n -gt $chars) { $n = $chars }
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt $n; $i++) {
    $ch = $text[$i]
    if (($ch -ge 'a' -and $ch -le 'z') -or ($ch -ge 'A' -and $ch -le 'Z') -or ($ch -ge '0' -and $ch -le '9')) {
      [void]$sb.Append([char]::ToLowerInvariant($ch))
      continue
    }
    $initial = Get-PinyinInitial $ch
    if ($initial) { [void]$sb.Append($initial.ToLowerInvariant()) }
  }
  return $sb.ToString()
}

# Does the text carry the given initials in order? 'zg' matches the two hanzi that start
# with z and g, spaces and punctuation in between included.
function Test-PinyinHit([string]$text, [string]$token) {
  if (-not $token -or $token -notmatch '^[A-Za-z]+$') { return $false }
  $initials = Get-PinyinInitials $text
  if (-not $initials) { return $false }
  return ($initials.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

# utils/time.ps1 - the clock helpers: the current epoch, the compact age a row shows, and the
# two ways a user spells a time.
#
# Times travel through the store as epoch seconds, so everything here is integer arithmetic on
# [long]: no culture, no formatting surprises, no allocation per row.

function Get-Epoch {
  return [long]([DateTime]::UtcNow - [DateTime]'1970-01-01T00:00:00Z').TotalSeconds
}

# compact relative time for the picker rows: now / 5m / 3h / 2d / 10-24
function Get-RelTime([long]$t) {
  if ($t -le 0) { return '' }
  $d = (Get-Epoch) - $t
  if ($d -lt 0) { $d = 0 }
  if ($d -lt 60) { return 'now' }
  if ($d -lt 3600) { return ([string][int]($d / 60)) + 'm' }
  if ($d -lt 86400) { return ([string][int]($d / 3600)) + 'h' }
  if ($d -lt 518400) { return ([string][int]($d / 86400)) + 'd' }
  try { return ([DateTime]'1970-01-01T00:00:00Z').ToLocalTime().AddSeconds($t).ToString('MM-dd') } catch { return '' }
}

# '7d' / '12h' / '30m' / '90s' / '3' -> seconds, -1 when the text is not a span. A bare number
# counts as days, which is how the search box has always read it.
function ConvertTo-TimeSpan([string]$spec) {
  $s = ([string]$spec).Trim().ToLowerInvariant()
  if (-not $s) { return -1 }
  $m = [regex]::Match($s, '^(\d+)([dhms])?$')
  if (-not $m.Success) { return -1 }
  $n = [long]$m.Groups[1].Value
  $unit = [string]$m.Groups[2].Value
  switch ($unit) {
    's' { return $n }
    'm' { return ($n * 60) }
    'h' { return ($n * 3600) }
    'd' { return ($n * 86400) }
    default { return ($n * 86400) }
  }
}

# a date the user typed -> epoch seconds, -1 when it is not a date. The invariant culture is
# tried first so 2026-11-01 reads the same everywhere, then whatever this machine uses.
function ConvertTo-TimeEpoch([string]$spec) {
  $s = ([string]$spec).Trim()
  if (-not $s) { return [long]-1 }
  $d = [DateTime]::MinValue
  $ok = [DateTime]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)
  if (-not $ok) { $ok = [DateTime]::TryParse($s, [ref]$d) }
  if (-not $ok) { return [long]-1 }
  return ([long](([DateTimeOffset]$d.ToUniversalTime()).ToUnixTimeSeconds()))
}

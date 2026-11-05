# utils/time.ps1 - the two clock helpers: the current epoch, and the compact age a row shows.
#
# Times travel through the store as epoch seconds, so everything here is integer arithmetic
# on [long]: no culture, no formatting surprises, no allocation per row.

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

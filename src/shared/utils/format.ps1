# utils/format.ps1 - byte counts for humans.
#
# Row labels and preview captions both print a payload size, so the rule lives in one place:
# bytes below 1 KB stay exact, everything above is rounded and keeps one decimal.

# short size for row labels and preview captions: 812 B / 12 KB / 2.3 MB / 1.2 GB
function Format-Size([long]$bytes) {
  if ($bytes -lt 0) { return '' }
  if ($bytes -lt 1024) { return ([string]$bytes + ' B') }
  if ($bytes -lt 1048576) { return ([string][int][Math]::Round($bytes / 1024.0) + ' KB') }
  if ($bytes -lt 1073741824) {
    return ([Math]::Round($bytes / 1048576.0, 1).ToString([Globalization.CultureInfo]::InvariantCulture) + ' MB')
  }
  return ([Math]::Round($bytes / 1073741824.0, 1).ToString([Globalization.CultureInfo]::InvariantCulture) + ' GB')
}

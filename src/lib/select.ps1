# lib/select.ps1 - the rows the user has marked for a batch action.
#
# A selection is a set of positions in the filtered list plus the row an extended selection
# grows from. It holds numbers only: which record sits at a position is the caller's
# business, so this file needs no window to be tested. The list control gets a copy of the
# set so it can paint the marked rows; the rules live here.

function New-Selection {
  return @{ Rows = (New-Object System.Collections.Generic.HashSet[int]); Anchor = -1 }
}

function Clear-Selection($sel) {
  if ($null -eq $sel) { return }
  $sel.Rows.Clear()
  $sel.Anchor = -1
}

function Get-SelectionCount($sel) {
  if ($null -eq $sel) { return 0 }
  return $sel.Rows.Count
}

function Test-RowSelected($sel, [int]$index) {
  if ($null -eq $sel -or $index -lt 0) { return $false }
  return $sel.Rows.Contains($index)
}

# Ctrl toggles one row, Shift takes the run between the anchor and the row, a plain click
# starts over. The anchor follows the row the user touched, so a second Shift-click grows
# from there the way it does in every list.
function Update-Selection($sel, $list, [int]$index, [bool]$ctrl, [bool]$shift) {
  if ($null -eq $sel -or $index -lt 0) { return }
  if ($shift -and $sel.Anchor -ge 0) {
    $from = [Math]::Min($sel.Anchor, $index)
    $to = [Math]::Max($sel.Anchor, $index)
    for ($i = $from; $i -le $to; $i++) { [void]$sel.Rows.Add($i) }
  } elseif ($ctrl) {
    if (-not $sel.Rows.Add($index)) { [void]$sel.Rows.Remove($index) }
    $sel.Anchor = $index
  } else {
    $sel.Rows.Clear()
    [void]$sel.Rows.Add($index)
    $sel.Anchor = $index
  }
  Sync-Selection $sel $list
}

function Select-AllRows($sel, $list, [int]$count) {
  if ($null -eq $sel) { return }
  $sel.Rows.Clear()
  for ($i = 0; $i -lt $count; $i++) { [void]$sel.Rows.Add($i) }
  $sel.Anchor = $(if ($count -gt 0) { 0 } else { -1 })
  Sync-Selection $sel $list
}

# push the set into the control, which paints the marked rows and nothing else
function Sync-Selection($sel, $list) {
  if ($null -ne $list -and $null -ne $list.MultiSelect) {
    $list.MultiSelect.Clear()
    foreach ($i in @($sel.Rows)) { [void]$list.MultiSelect.Add([int]$i) }
    $list.AnchorIndex = [int]$sel.Anchor
    $list.Invalidate()
  }
}

# Drop the positions the list no longer has: after a filter or a refresh a stale number would
# act on whatever moved into its place.
function Trim-Selection($sel, [int]$count) {
  if ($null -eq $sel) { return }
  $gone = New-Object System.Collections.Generic.List[int]
  foreach ($i in @($sel.Rows)) { if ($i -ge $count) { $gone.Add([int]$i) } }
  foreach ($i in $gone) { [void]$sel.Rows.Remove($i) }
  if ($sel.Anchor -ge $count) { $sel.Anchor = -1 }
}

# The records a batch acts on, in list order (the frozen pins first), so a paste lands in the
# order the user sees rather than the order they clicked.
function Get-SelectedRecords($sel, $rows) {
  $out = New-Object System.Collections.Generic.List[object]
  $all = @($rows)
  if ($null -eq $sel -or $sel.Rows.Count -eq 0) { return $out.ToArray() }
  for ($i = 0; $i -lt $all.Count; $i++) {
    if ($sel.Rows.Contains($i)) { $out.Add($all[$i]) }
  }
  return $out.ToArray()
}

# Batch copy: the texts join with a line break, in list order. A picture or a file list has
# no text to contribute, so it is counted instead of being silently dropped.
function Invoke-SelectionCopy($sel, $rows) {
  $records = @(Get-SelectedRecords $sel $rows)
  $parts = New-Object System.Collections.Generic.List[string]
  $skipped = 0
  foreach ($rec in $records) {
    $payload = [string]$rec.Payload
    if ((Test-FilePayload $payload) -or (Test-ImagePayload $payload)) { $skipped++; continue }
    $parts.Add($payload)
  }
  if ($parts.Count -eq 0) { return $null }
  if (-not (Set-Text ($parts -join [Environment]::NewLine))) { return $null }
  $note = 'copied ' + $parts.Count + ' rows'
  if ($skipped -gt 0) { $note = $note + ', ' + $skipped + ' without text' }
  return @{ Note = $note; Count = $parts.Count }
}

# Batch delete: one store write for the whole set, protected rows reported together.
function Invoke-SelectionDelete($sel, $rows) {
  $records = @(Get-SelectedRecords $sel $rows)
  if ($records.Count -eq 0) { return '' }
  $payloads = @()
  foreach ($rec in $records) { $payloads += [string]$rec.Payload }
  $r = Remove-Records $payloads
  Clear-Selection $sel
  if ([int]$r.Removed -le 0) {
    $words = @()
    foreach ($m in @($r.Blocked)) { $words += (Get-MarkWord $m) }
    if ($words.Count -gt 0) { return ('kept, ' + ($words -join ', ') + ' protected') }
    return ''
  }
  if ([int]$r.Removed -lt $records.Count) { return ('deleted ' + $r.Removed + ' of ' + $records.Count) }
  return ('deleted ' + $r.Removed + ' rows')
}

# lib/settings-vm.ps1 - what a change does to the settings window's state.
#
# The window is drawn by hand, so there are no controls to bind: a change is a value in a table
# of staged values, and the switches, the page marks and the footer are all drawn from that
# table. The rules about what a change means live here, with no form, no timer and no language
# file in sight, so they can be checked without opening a window. The window keeps what only it
# can do: repaint, word a message, follow a theme.
#
# Every function is a question about plain tables, in and out; none of them touches $script:
# state of the window, and none of them writes a file.

function Copy-SettingTable($table) {
  $next = @{}
  if ($null -ne $table) {
    foreach ($k in @($table.Keys)) { $next[[string]$k] = $table[$k] }
  }
  return $next
}

# One value staged. A value the file already holds is not a change, so the key leaves the table:
# flipping a switch back, or picking what is already set, leaves nothing staged and no dot on
# the page. The answer carries the table to keep, whether anything changed, and what the file
# holds, because the caller words the message.
function Get-SettingStagedValue($pending, $schema, [string]$key, [string]$value) {
  $next = Copy-SettingTable $pending
  $held = ''
  if ($key) { $held = [string](Get-SettingRaw $schema $key) }
  if (-not $key) { return @{ Pending = $next; Changed = $false; Held = $held } }
  if ($value -ceq $held) {
    if ($next.ContainsKey($key)) { [void]$next.Remove($key) }
    return @{ Pending = $next; Changed = $false; Held = $held }
  }
  $next[$key] = [string]$value
  return @{ Pending = $next; Changed = $true; Held = $held }
}

# The value behind a flip: a switch is a one-character setting, so it is turned, not typed.
function Get-SettingFlipValue($row) {
  if ($null -eq $row) { return '' }
  if ([string]$row.Raw -eq '1') { return '0' }
  return '1'
}

# What a recorded chord produces: a single hotkey replaces what it holds, a chain gains the
# chord at the end, which is where the resident tries it last.
function Get-SettingRecordValue($row, [string]$chord) {
  if (-not $chord) { return '' }
  if ($null -eq $row) { return $chord }
  if ($row.ContainsKey('Chain') -and [bool]$row.Chain) { return (Get-SettingChordAdded ([string]$row.Raw) $chord) }
  return $chord
}

# One chord off a chain. The last one stays: a chain with nothing in it falls back to the
# default list, so removing it is refused instead of written.
function Get-SettingChordDrop($row, [int]$index) {
  $answer = @{ Ok = $false; Value = ''; Removed = '' }
  if ($null -eq $row) { return $answer }
  $chords = @($row.Chords)
  if ($index -lt 0 -or $index -ge $chords.Count) { return $answer }
  $next = Get-SettingChordRemoved ([string]$row.Raw) ([string]$chords[$index])
  if ($null -eq $next) { return $answer }
  return @{ Ok = $true; Value = [string]$next; Removed = [string]$chords[$index] }
}

# One name ticked or unticked in a multi-select. A list left empty is refused: an empty
# Plugins= means every plugin on disk, so unticking the last one would read as "all of them"
# the moment the window redrew.
function Get-SettingListTick($row, [string]$name) {
  $answer = @{ Ok = $false; Value = ''; Ticked = $false }
  if ($null -eq $row -or -not $name) { return $answer }
  $raw = [string]$row.Raw
  $next = Get-SettingListToggled $raw $name
  if (-not $next) { return $answer }
  return @{ Ok = $true; Value = [string]$next; Ticked = (-not (Get-SettingListOn $raw $name)) }
}

# Which footer actions apply right now: restoring the defaults always does, the other two only
# once something is staged, because saving or discarding nothing would do nothing.
function Get-SettingsActionState($pending) {
  $n = 0
  if ($null -ne $pending) { $n = @($pending.Keys).Count }
  return @{ Save = ($n -gt 0); Discard = ($n -gt 0); Defaults = $true; Count = $n }
}

# What saving the staged set means for the window itself: the folder it writes to moves with
# DataDir, a new theme has to reach the palette before the next paint, and a language may name
# its own font family, so the faces are built again.
function Get-SettingsSavePlan($pending) {
  $plan = @{ Count = 0; HasDataDir = $false; DataDir = ''; Theme = $false; Language = $false }
  if ($null -eq $pending) { return $plan }
  $plan.Count = @($pending.Keys).Count
  if ($pending.Contains('DataDir')) {
    $plan.HasDataDir = $true
    $plan.DataDir = [string]$pending['DataDir']
  }
  $plan.Theme = $pending.Contains('Theme')
  $plan.Language = $pending.Contains('Language')
  return $plan
}

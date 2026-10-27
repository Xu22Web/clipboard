# lib/entry.ps1 - the base view of an entry: text, file list or empty, and which glyph the
# row gets.
#
# Deliberately small: richer typing, opening and per-kind icons belong to the entry-actions
# plugin. The base only needs enough to store, label and paste a payload.

# The base only needs to tell a file list from text: that is all storage, the row glyph and
# the clipboard round trip care about. Richer typing lives in the entry-actions plugin.
function Get-EntryKind([string]$payload) {
  if ([string]::IsNullOrEmpty($payload)) { return 'empty' }
  if ($payload[0] -eq [char]1) { return 'files' }
  return 'text'
}

# a glyph from the icon font when this machine has one, else a plain-text fallback.
# Plugins call this instead of inspecting IconFamily themselves.
function Get-IconGlyph([int]$code, [string]$fallback = '*') {
  if ($script:IconFamily) { return [string][char]$code }
  return $fallback
}

# Row icon: whatever a plugin asks for, and nothing otherwise. Typing an entry is a
# plugin's job (entry-actions), so the base never paints an icon of its own.
function Get-RowGlyph([string]$payload) {
  if (Get-Command Get-EntryGlyph -ErrorAction SilentlyContinue) {
    try {
      $g = Get-EntryGlyph $payload
      if ($g) { return [string]$g }
    } catch { }
  }
  return ''
}


# one context-menu action's caption for a row: a scriptblock label is evaluated, a plain
# string is used as is, and anything else falls back to a neutral caption
function Get-ActionText($action, $record) {
  $label = $null
  if ($action -is [hashtable] -and $action.ContainsKey('Label')) { $label = $action['Label'] }
  if ($label -is [scriptblock]) {
    try {
      $text = [string](& $label $record)
      if ($text) { return $text }
    } catch { }
    return 'Plugin action'
  }
  if ($label) { return [string]$label }
  return 'Plugin action'
}


# single-line display text for one payload (picker rows and CLI listings)
function Get-ItemLabel([string]$t, [bool]$nlMarker = $true) {
  $one = $t
  if ($one.Length -gt 0 -and $one[0] -eq [char]1) {
    $names = @($one.Substring(1) -split "`n" | Where-Object { $_ } | ForEach-Object { Split-Path -Leaf $_ })
    if ($names.Count -gt 3) { $one = '[files] ' + (($names[0..2]) -join ', ') + ' (+' + ($names.Count - 3) + ')' }
    else { $one = '[files] ' + ($names -join ', ') }
  } else {
    # only the head of a large payload is ever shown, so skip the cleanup work on the
    # rest of a 200 KB entry on every keystroke
    if ($one.Length -gt 4000) { $one = $one.Substring(0, 4000) }
    $one = $one -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ' '
    if ($nlMarker) { $one = $one -replace '\r?\n', ' <NL> ' } else { $one = $one -replace '\r?\n', ' ' }
    $one = $one -replace '\t', ' '
    $one = $one -replace ' {2,}', ' '
    $one = $one.Trim()
  }
  if ($one.Length -gt 2000) { $one = $one.Substring(0, 2000) }
  return $one
}


function Format-Item([string]$t, [int]$max) {
  $one = Get-ItemLabel $t $true
  if ($one.Length -gt $max) { $one = $one.Substring(0, $max) + '...' }
  return $one
}

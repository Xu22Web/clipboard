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

# lib/entry.ps1 - the base view of an entry: text, file list, image or empty, and which
# glyph the row gets.
#
# Deliberately small: richer typing, opening and per-kind icons belong to the entry-actions
# plugin. The base only needs enough to store, label and paste a payload.

# Payload kinds: a file list starts with char 1, an image with char 3 (its descriptor names
# a file in data\media), everything else is text. Callers ask these two instead of comparing
# the leading character, so a new kind is one edit here and one in media.ps1.
function Test-FilePayload([string]$payload) {
  return ($null -ne $payload -and $payload.Length -gt 0 -and $payload[0] -eq [char]1)
}

# The paths a file list carries, one per line after the marker. A path may itself contain a
# newline only in theory, so the split is enough here.
function Get-FilePayloadPaths([string]$payload) {
  $out = New-Object System.Collections.Generic.List[string]
  if (-not (Test-FilePayload $payload)) { return $out.ToArray() }
  foreach ($p in @($payload.Substring(1) -split "`n")) {
    $one = $p.Trim()
    if ($one) { $out.Add($one) }
  }
  return $out.ToArray()
}

# The base only needs to tell a file list, an image descriptor and text apart: that is all
# storage, the row glyph and the clipboard round trip care about. Richer typing lives in the
# entry-actions plugin.
function Get-EntryKind([string]$payload) {
  if ([string]::IsNullOrEmpty($payload)) { return 'empty' }
  if (Test-FilePayload $payload) { return 'files' }
  if (Test-ImagePayload $payload) { return 'image' }
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
  if (Test-FilePayload $one) {
    $names = @($one.Substring(1) -split "`n" | Where-Object { $_ } | ForEach-Object { Split-Path -Leaf $_ })
    if ($names.Count -gt 3) { $one = '[files] ' + (($names[0..2]) -join ', ') + ' (+' + ($names.Count - 3) + ')' }
    else { $one = '[files] ' + ($names -join ', ') }
  } elseif (Test-ImagePayload $one) {
    # an image entry is a descriptor, not pixels: name the size, the format and the weight
    $ref = Get-ImageRef $one
    if ($null -ne $ref) {
      $one = '[image] ' + [string]$ref.W + 'x' + [string]$ref.H + ' - ' + [string]$ref.Fmt + ' - ' + (Format-Size $ref.Bytes)
    } else {
      $one = '[image]'
    }
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

# The label of a record rather than of a payload: an entry that kept its formatting says so,
# because the row text alone cannot show it (the payload is the plain text either way).
function Get-RecordLabel($record, [bool]$nlMarker = $true) {
  if ($null -eq $record) { return '' }
  $one = Get-ItemLabel ([string]$record.Payload) $nlMarker
  if ([string]$record.Rich) { return ('[rich] ' + $one) }
  return $one
}

function Format-Record($record, [int]$max) {
  $one = Get-RecordLabel $record $true
  if ($one.Length -gt $max) { $one = $one.Substring(0, $max) + '...' }
  return $one
}

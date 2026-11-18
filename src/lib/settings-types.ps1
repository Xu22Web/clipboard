# lib/settings-types.ps1 - what a value means when it is edited, per kind of setting.
#
# The window knows four behaviours (bool, number, text and a value picked from a list) and the
# schema knows eight types. This file is the only place that maps one to the other, so the
# window never has to ask "is this a theme or a plain string".
#
# Nothing here draws. Every answer is a value, a normalised file spelling, or a sentence the
# footer can show, which is what makes these testable without a window.

# The value one Enter or one Space produces. A boolean flips; everything else keeps its value
# and is left to the text editor.
function Get-SettingToggle($schema, [string]$key) {
  $spec = Get-SchemaProperty $schema $key
  if ($null -eq $spec) { return $null }
  if ((Get-SettingKind $spec) -ne 'bool') { return $null }
  $raw = Get-SettingRaw $schema $key
  if ([string]$raw -eq '1') { return '0' }
  return '1'
}

# One step of a number, sized to the range it lives in: one thousandth of the span, rounded down
# to a power of ten. A millisecond delay over 0-10000 moves by 10, a byte budget by 100000, and
# a row count by 1 - so one arrow key is one sensible notch whatever the key measures.
function Get-SettingStep($spec, [string]$raw = '') {
  if ($null -eq $spec) { return 1 }
  $lo = 0
  $hi = 0
  if ($spec.Contains('Minimum')) { $lo = [int]$spec['Minimum'] }
  if ($spec.Contains('Maximum')) { $hi = [int]$spec['Maximum'] }
  $span = [Math]::Abs($hi - $lo)
  if ($span -lt 1) { return 1 }
  $unit = [Math]::Max(1, $span / 1000)
  $step = [int][Math]::Pow(10, [Math]::Floor([Math]::Log10($unit)))
  if ($step -lt 1) { return 1 }
  return $step
}

# A number moved by one step, kept inside the schema range. Returns the file spelling the
# writer expects, or $null when the value already sits on the end it was pushed against.
function Get-SettingStepped($schema, [string]$key, [int]$dir) {
  $spec = Get-SchemaProperty $schema $key
  if ($null -eq $spec) { return $null }
  if ((Get-SettingKind $spec) -ne 'number') { return $null }
  $raw = Get-SettingRaw $schema $key
  $n = 0
  if (-not [int]::TryParse([string]$raw, [ref]$n)) { $n = 0 }
  $step = Get-SettingStep $spec $raw
  $next = $n + ($step * $dir)
  if ($spec.Contains('Minimum') -and $next -lt [int]$spec['Minimum']) { $next = [int]$spec['Minimum'] }
  if ($spec.Contains('Maximum') -and $next -gt [int]$spec['Maximum']) { $next = [int]$spec['Maximum'] }
  if ([string]$next -eq [string]$n) { return $null }
  return [string]$next
}

# The values a setting offers as a list, or an empty array when it is typed. A list is only
# for a value whose whole domain is small and known at run time: the themes on disk, and the
# three paste chords that cover every target anyone meets. Everything else is free text.
function Get-SettingChoices($schema, [string]$key) {
  $spec = Get-SchemaProperty $schema $key
  if ($null -eq $spec) { return @() }
  $kind = Get-SettingKind $spec
  if ($kind -eq 'theme') {
    $names = @()
    if (Get-Command Get-ThemeNames -ErrorAction SilentlyContinue) {
      try { $names = @(Get-ThemeNames) } catch { $names = @() }
    }
    return $names
  }
  if ($kind -eq 'text' -and $key -ceq 'PasteKeys') {
    # the three chords that between them cover every target: the default, the terminal-style
    # shift-insert, and the same without shift for programs that map Ctrl+Insert
    return @('^v', '^+{INSERT}', '^{INSERT}')
  }
  return @()
}

# The value a list-type setting moves to: the next or previous name on disk, wrapping at the
# ends. The list is read from disk, so a theme dropped into themes\ is selectable without the
# window knowing anything about it.
function Get-SettingCycled($schema, [string]$key, [int]$dir) {
  $spec = Get-SchemaProperty $schema $key
  if ($null -eq $spec) { return $null }
  if ((Get-SettingKind $spec) -ne 'theme') { return $null }
  $names = @()
  if (Get-Command Get-ThemeNames -ErrorAction SilentlyContinue) {
    try { $names = @(Get-ThemeNames) } catch { $names = @() }
  }
  if ($names.Count -eq 0) { return $null }
  $cur = Get-SettingRaw $schema $key
  $at = -1
  for ($i = 0; $i -lt $names.Count; $i++) { if ([string]$names[$i] -ieq [string]$cur) { $at = $i } }
  if ($at -lt 0) { return [string]$names[0] }
  $n = $names.Count
  $to = (($at + $dir) % $n + $n) % $n
  if ($to -eq $at) { return $null }
  return [string]$names[$to]
}

# One text answer from the editor, validated by the schema itself: the window never restates
# a range that lives in schema\clipboard.ps1.
function Convert-SettingInput($schema, [string]$key, [string]$text) {
  if ($null -eq (Get-SchemaProperty $schema $key)) { return @{ Ok = $false; Value = ''; Error = 'unknown key' } }
  return (Convert-SchemaValue $schema $key $text)
}

# How a kind is labelled in the footer, so the same word is used everywhere.
function Get-SettingKindName([string]$kind) {
  switch ($kind) {
    'bool' { return 'switch' }
    'number' { return 'number' }
    'theme' { return 'theme' }
    'hotkey' { return 'hotkey' }
    'regex' { return 'pattern' }
    'list' { return 'list' }
    'rules' { return 'rules' }
    default { return 'text' }
  }
}

# The value shown while it is being edited: a boolean opens the editor on its file spelling,
# because that is what the writer takes back.
function Get-SettingEditText($schema, [string]$key) {
  return (Get-SettingRaw $schema $key)
}

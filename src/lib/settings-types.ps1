# lib/settings-types.ps1 - what a value means when it is edited, per kind of setting.
#
# The window knows four behaviours (bool, number, text and a value picked from a list) and the
# schema knows eight types. This file is the only place that maps one to the other, so the
# window never has to ask "is this a theme or a plain string".
#
# Nothing here draws. Every answer is a value, a normalised file spelling, or a sentence the
# footer can show, which is what makes these testable without a window.

# The chords a row shows as key caps: one for a hotkey, one per entry for the chain, one for the
# SendKeys spelling the paste keys are written in, none for anything else. A shortcut is read key
# by key, so the row needs the parts and not one string.
function Get-SettingChordList($schema, [string]$key, [string]$raw) {
  $spec = Get-SchemaProperty $schema $key
  if ($null -eq $spec) { return @() }
  # the paste keys are SendKeys, not a chord in the file, but they are still keys to a person:
  # "^v" is Ctrl and V, and the row says so the same way the hotkey row does
  if ($key -ceq 'PasteKeys') {
    $one = Convert-SendKeysToChord $raw
    if ($one) { return @($one) }
    return @()
  }
  if ((Get-SettingKind $spec) -ne 'hotkey') { return @() }
  # the same separators the resident splits a chain on, so a file written by hand with ';' still
  # shows one cap per chord instead of one cap holding both
  $out = @()
  foreach ($c in @(([string]$raw) -split '[,;]')) {
    $t = ([string]$c).Trim()
    if ($t) { $out += $t }
  }
  return $out
}

# The keys a choice stands for, or nothing when the choice is a word. A paste-keys choice is a
# SendKeys spelling ("^v") and a hotkey choice is a chord: both are drawn as caps in the list,
# because picking one is picking a key combination, and "^+{INSERT}" says nothing to a reader.
function Get-SettingChoiceKeys([string]$text) {
  $t = ([string]$text).Trim()
  if (-not $t) { return @() }
  if ($t -notmatch '[\^\{\+]') { return @() }
  $chord = Convert-SendKeysToChord $t
  if ($chord) { return @(Get-SettingChordKeys $chord) }
  return @(Get-SettingChordKeys $t)
}

function Format-SendKeyName([string]$name) {
  $t = ([string]$name).Trim()
  if (-not $t) { return '' }
  $u = $t.ToUpperInvariant()
  switch ($u) {
    'INSERT' { return 'Insert' }
    'DEL' { return 'Delete' }
    'DELETE' { return 'Delete' }
    'HOME' { return 'Home' }
    'END' { return 'End' }
    'PGUP' { return 'PageUp' }
    'PGDN' { return 'PageDown' }
    'TAB' { return 'Tab' }
    'ESC' { return 'Esc' }
    'ENTER' { return 'Enter' }
    'RETURN' { return 'Enter' }
    'BACKSPACE' { return 'Backspace' }
    'BS' { return 'Backspace' }
    'SPACE' { return 'Space' }
    'UP' { return 'Up' }
    'DOWN' { return 'Down' }
    'LEFT' { return 'Left' }
    'RIGHT' { return 'Right' }
    'ADD' { return '+' }
    'SUBTRACT' { return '-' }
    'MULTIPLY' { return '*' }
    'DIVIDE' { return '/' }
  }
  if ($u -match '^F([1-9]|1[0-9]|2[0-4])$') { return $u }
  return $t
}

# A SendKeys spelling as one chord, in the order the caps are drawn: modifiers first, then the
# keys. Anything this does not understand becomes a key of its own, so nothing is silently lost.
function Convert-SendKeysToChord([string]$keys) {
  $t = [string]$keys
  if (-not $t) { return '' }
  $mods = @()
  $names = @()
  $i = 0
  while ($i -lt $t.Length) {
    $c = $t[$i]
    if ($c -eq '^') { if ($mods -notcontains 'Ctrl') { $mods += 'Ctrl' }; $i++; continue }
    if ($c -eq '+') { if ($mods -notcontains 'Shift') { $mods += 'Shift' }; $i++; continue }
    if ($c -eq '%') { if ($mods -notcontains 'Alt') { $mods += 'Alt' }; $i++; continue }
    if ($c -eq '~') { $names += 'Enter'; $i++; continue }
    if ($c -eq '{') {
      $end = $t.IndexOf('}', $i)
      if ($end -lt 0) { $names += $t.Substring($i); break }
      $names += (Format-SendKeyName $t.Substring($i + 1, $end - $i - 1))
      $i = $end + 1
      continue
    }
    if ($c -eq '(' -or $c -eq ')') { $i++; continue }
    $names += ([string]$c).ToUpperInvariant()
    $i++
  }
  $parts = @()
  foreach ($m in @('Win', 'Ctrl', 'Alt', 'Shift')) { if ($mods -contains $m) { $parts += $m } }
  foreach ($n in $names) { if ($n) { $parts += [string]$n } }
  return ($parts -join '+')
}

# The chain a chord is added to: the order is the order the resident tries them, so a new chord
# goes last, and the same chord twice would only be tried twice. Three is the limit, because three
# chord lines are what the card holds - the schema refuses a longer chain for the same reason.
function Get-SettingChordAdded([string]$raw, [string]$chord) {
  $t = ([string]$chord).Trim()
  if (-not $t) { return $raw }
  $cur = @(Split-SettingList $raw)
  foreach ($c in $cur) { if ([string]$c -ieq $t) { return ($cur -join ', ') } }
  if ($cur.Count -ge 3) { return ($cur -join ', ') }
  $cur += $t
  return ($cur -join ', ')
}

# The chain without one chord, or $null when that would leave none: a chain with no chord falls
# back to the default, so removing the last one has to be refused the way an empty list is.
function Get-SettingChordRemoved([string]$raw, [string]$chord) {
  $t = ([string]$chord).Trim()
  $out = @()
  foreach ($c in @(Split-SettingList $raw)) { if ([string]$c -ine $t) { $out += [string]$c } }
  if ($out.Count -eq 0) { return $null }
  return ($out -join ', ')
}

# The keys of one chord, in the order Windows prints them - Win, Ctrl, Alt, Shift, then the key -
# whatever order the file spells them in. "+" as the key itself is the one case the split cannot
# see, so a trailing plus is taken before the parts are split. The key is the one a cap shows,
# which is the character for a punctuation key (see Format-ChordKeyCap).
function Get-SettingChordKeys([string]$chord) {
  $t = ([string]$chord).Trim()
  if (-not $t) { return @() }
  $key = ''
  $head = $t
  if ($t.EndsWith('+')) {
    $key = '+'
    $head = $t.Substring(0, $t.Length - 1)
  }
  $mods = @()
  foreach ($p in @($head -split '\+')) {
    $m = ([string]$p).Trim()
    if ($m) { $mods += $m }
  }
  if ($key -eq '') {
    if ($mods.Count -eq 0) { return @() }
    $key = [string]$mods[$mods.Count - 1]
    if ($mods.Count -gt 1) { $mods = @($mods[0..($mods.Count - 2)]) } else { $mods = @() }
  }
  $out = @()
  foreach ($want in @('Win', 'Ctrl', 'Alt', 'Shift')) {
    foreach ($m in $mods) { if ($m -ieq $want) { $out += $want } }
  }
  $out += (Format-ChordKeyCap $key)
  return $out
}

# How one key is printed on a cap: a punctuation key shows the character it types, which is what
# a reader recognises, while the file keeps the name the parser reads. A comma and a semicolon
# are the chain's own separators in the file, so they are printed here and never written back.
function Format-ChordKeyCap([string]$name) {
  switch (([string]$name).ToUpperInvariant()) {
    'BACKTICK' { return '`' }
    'MINUS' { return '-' }
    'EQUALS' { return '=' }
    'LBRACKET' { return '[' }
    'RBRACKET' { return ']' }
    'BACKSLASH' { return '\' }
    'SEMICOLON' { return ';' }
    'QUOTE' { return "'" }
    'COMMA' { return ',' }
    'PERIOD' { return '.' }
    'SLASH' { return '/' }
  }
  return [string]$name
}

# The chord a recorded key makes, in the spelling the file uses: modifiers in the order the parser
# reads them, then the key. An empty answer means there is nothing to write yet.
function Format-ChordValue([bool]$win, [bool]$ctrl, [bool]$alt, [bool]$shift, [string]$keyName) {
  if (-not $keyName) { return '' }
  $parts = @()
  if ($win) { $parts += 'Win' }
  if ($ctrl) { $parts += 'Ctrl' }
  if ($alt) { $parts += 'Alt' }
  if ($shift) { $parts += 'Shift' }
  $parts += $keyName
  return ($parts -join '+')
}

# Whether a recorded chord is usable as a hotkey: a global key with no modifier would swallow
# that key everywhere in every program, so a bare key is only accepted as one of F1-F24.
function Test-ChordUsable([string]$chord) {
  $keys = @(Get-SettingChordKeys $chord)
  if ($keys.Count -lt 2) {
    if ($keys.Count -eq 1 -and ([string]$keys[0]) -match '^F([1-9]|1[0-9]|2[0-4])$') { return $true }
    return $false
  }
  return $true
}

# How a number is shown: the value in the unit it reads best in, that unit, and what one unit is
# worth. A byte count is shown in B, KB or MB by its own size, so the field never asks anyone to
# read seven digits; a duration keeps its milliseconds, which is the unit the file uses.
function Get-SettingNumberView($schema, [string]$key, [string]$raw) {
  $spec = Get-SchemaProperty $schema $key
  $unit = ''
  if ($null -ne $spec -and $spec.Contains('Unit')) { $unit = [string]$spec['Unit'] }
  $view = @{ Number = [string]$raw; Unit = ''; Scale = 1 }
  if ([string]$raw -eq '') {
    # an empty field still says what it measures: (auto) with px beside it reads as a position.
    # A size is the one unit left out, because there the magnitude picks between B, KB and MB.
    if ($unit -and $unit -ne 'size') { $view.Unit = $unit }
    return $view
  }
  $n = 0.0
  if (-not [double]::TryParse([string]$raw, [ref]$n)) { return $view }
  if ($unit -eq 'size') {
    # the largest unit the value fills, so 204800 000 reads as 200 KB and not 204800 B
    if ([Math]::Abs($n) -ge 1048576) { $view.Unit = 'MB'; $view.Scale = 1048576 }
    elseif ([Math]::Abs($n) -ge 1024) { $view.Unit = 'KB'; $view.Scale = 1024 }
    else { $view.Unit = 'B'; $view.Scale = 1 }
  } elseif ($unit) {
    $view.Unit = $unit
  }
  # the words beside a number are part of the language, the size abbreviations (B / KB / MB) are not
  if ([string]$view.Unit -and $unit -ne 'size') {
    $unitKey = 'settings.unit.' + [string]$view.Unit
    $unitWord = [string]$view.Unit
    $view.Unit = Get-UiTextOr $unitKey $unitWord
  }
  $shown = $n / [double]$view.Scale
  $text = ([Math]::Round($shown, 3)).ToString([Globalization.CultureInfo]::InvariantCulture)
  if ($text.Contains('.')) { $text = $text.TrimEnd('0').TrimEnd('.') }
  $view.Number = $text
  return $view
}

# The stored value a typed number means: what the field shows times the unit it shows it in. The
# schema still validates the result, so a range stays stated once, in the file's own unit.
function Convert-SettingNumberInput($schema, [string]$key, [string]$text, [double]$scale = 1) {
  $t = ([string]$text).Trim()
  if ($t -eq '') { return (Convert-SettingInput $schema $key '') }
  if ($scale -lt 1) { $scale = 1 }
  $d = 0.0
  if (-not [double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
    return @{ Ok = $false; Value = ''; Error = 'expected a number' }
  }
  $v = [long][Math]::Round($d * $scale)
  return (Convert-SettingInput $schema $key ([string]$v))
}

# The values a setting offers as a list, or an empty array when it is typed. A list is only
# for a value whose whole domain is small and known at run time: the themes on disk, the three
# paste chords that cover every target anyone meets, and the plugin files on disk. Everything
# else is free text.
function Get-SettingChoices($schema, [string]$key) {
  $spec = Get-SchemaProperty $schema $key
  if ($null -eq $spec) { return @() }
  # the schema's own list of acceptable values comes first: a key that declares Enum needs no
  # second copy of that list in the window
  if ($spec.Contains('Enum')) { return @($spec['Enum']) }
  # Suggest is the free-form case: the window offers these, the reader accepts anything
  if ($spec.Contains('Suggest')) { return @($spec['Suggest']) }
  $kind = Get-SettingKind $spec
  if ($kind -eq 'theme') {
    $names = @()
    if (Get-Command Get-ThemeNames -ErrorAction SilentlyContinue) {
      try { $names = @(Get-ThemeNames) } catch { $names = @() }
    }
    return $names
  }
  if ($kind -eq 'list' -and $key -ceq 'Plugins') { return @(Get-SettingPluginNames) }
  return @()
}

# every plugin file on disk, read from the folder rather than from what is loaded: a plugin
# switched off in Plugins= is exactly the one the list has to offer back
function Get-SettingPluginNames {
  $names = @()
  if (Get-Command Get-AllPluginNames -ErrorAction SilentlyContinue) {
    try {
      $dir = ''
      if ($script:Root) { $dir = Join-Path $script:Root 'plugins' }
      if ($dir) { $names = @(Get-AllPluginNames $dir) }
    } catch { $names = @() }
  }
  if (@($names).Count -eq 0) { $names = @($script:PluginList) }
  return $names
}

# The names a list setting holds, in the order the file spells them: that order is the plugin
# load order, so a name already listed keeps its place when another one is ticked.
function Split-SettingList([string]$raw) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($n in @(([string]$raw) -split '[,;]')) {
    $t = ([string]$n).Trim()
    if ($t) { $out.Add($t) }
  }
  return $out.ToArray()
}

function Get-SettingListOn([string]$raw, [string]$name) {
  foreach ($n in @(Split-SettingList $raw)) { if ([string]$n -ieq $name) { return $true } }
  return $false
}

# Tick or untick one name, keeping the rest in place. Returns the new comma list, or $null when
# the change would leave the list empty: an empty Plugins= means every plugin on disk, so an
# empty result would read as "all of them" right after unticking the last one.
function Get-SettingListToggled([string]$raw, [string]$name) {
  $cur = @(Split-SettingList $raw)
  $was = Get-SettingListOn $raw $name
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($n in $cur) { if (-not ([string]$n -ieq $name)) { $out.Add([string]$n) } }
  if (-not $was) { $out.Add($name) }
  if ($out.Count -eq 0) { return $null }
  return ($out -join ',')
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

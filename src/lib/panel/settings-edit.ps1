# lib/panel/settings-edit.ps1 - editing one setting in place.
#
# A value is edited in a real TextBox laid over the row, not by drawing a caret: the same
# reason the panel's row editor uses one - an input method needs a real control to compose
# into, and text selection, Ctrl+A and the clipboard come for free. Everything else about the
# window stays custom drawn.
#
# Writing goes through Set-IniKey and Apply-Config, which is exactly what `config set` does,
# so a value saved here and a value typed on the command line cannot end up in different
# places. The difference is when: the window stages every change and writes the whole set when
# Save is pressed, while a command restarts the resident on the spot. Nothing here writes a
# value the schema has not already accepted.

# The staged set, written in one pass: every key first, one Apply-Config after them, so the file
# and the running settings agree whether one value or twenty were staged. An install-only key
# still needs no reload, so on its own it does not ask the window for one on close.
function Save-SettingsValues($pending) {
  if ($null -eq $pending -or $pending.Count -eq 0) { return @{ Ok = $true; Error = ''; Count = 0 } }
  if (-not (Get-Command Set-IniKey -ErrorAction SilentlyContinue)) { return @{ Ok = $false; Error = 'the settings file is not loaded'; Count = 0 } }
  $written = 0
  $reload = $false
  foreach ($k in @($pending.Keys)) {
    $key = [string]$k
    if (-not (Set-IniKey $key ([string]$pending[$k]))) {
      return @{ Ok = $false; Error = 'could not write ' + $key + ' to clipboard.ini'; Count = $written }
    }
    $written++
    if (-not (Test-SchemaInstallOnly $script:SettingsSchema $key)) { $reload = $true }
  }
  try { Apply-Config } catch { return @{ Ok = $false; Error = [string]$_.Exception.Message; Count = $written } }
  if ($reload) { $script:SettingsDirty = $true }
  return @{ Ok = $true; Error = ''; Count = $written }
}

# The staged set Restore defaults produces: every key whose declared default differs from what it
# holds, the staged value counted as what it holds. A read-only key is left out - DataDir's
# default is a location, and the window has no business moving the store.
function Get-SettingDefaultStaging($schema, $pending = $null) {
  $out = @{}
  $props = Get-SchemaProperties $schema
  if ($null -eq $props) { return $out }
  foreach ($k in @($props.Keys)) {
    $key = [string]$k
    $spec = $props[$k]
    if ($spec -isnot [System.Collections.IDictionary]) { continue }
    if ($spec.Contains('ReadOnly')) { continue }
    $raw = Get-SettingRaw $schema $key
    if ($null -ne $pending -and $pending.Contains($key)) { $raw = [string]$pending[$key] }
    $r = Convert-SettingInput $schema $key (Get-SchemaDefault $schema $key)
    if (-not $r.Ok) { continue }
    $want = [string]$r.Value
    if ($want -eq [string]$raw) { continue }
    $out[$key] = $want
  }
  return $out
}

# The text a row opens its editor with, seeded from the value the row is showing - which is the
# staged one while changes are waiting. A number opens in the unit the row shows, because that is
# what the user just read; a value that is currently empty opens with its default spelled out,
# because an empty box says nothing about what is allowed.
function Get-SettingEditSeed($schema, [string]$key, [string]$raw = '') {
  $spec = Get-SchemaProperty $schema $key
  if ($null -ne $spec -and (Get-SettingKind $spec) -eq 'number') {
    $view = Get-SettingNumberView $schema $key $raw
    if ([string]$view.Number -ne '') { return [string]$view.Number }
    $def = [string](Get-SchemaDefault $schema $key)
    if ($def -ne '') { return [string](Get-SettingNumberView $schema $key $def).Number }
    return ''
  }
  if ([string]$raw -ne '') { return [string]$raw }
  return [string](Get-SchemaDefault $schema $key)
}

# The key part of a chord, from a key that was pressed. Only the names the tool's own parser
# understands are accepted, so a recorded chord is one the resident can actually register; $null
# means this key cannot be part of a hotkey.
function Get-ChordKeyName($keyCode) {
  $k = [Windows.Forms.Keys]$keyCode
  if (($k -ge [Windows.Forms.Keys]::A) -and ($k -le [Windows.Forms.Keys]::Z)) { return [string][char][int]$k }
  if (($k -ge [Windows.Forms.Keys]::D0) -and ($k -le [Windows.Forms.Keys]::D9)) { return [string][char][int]$k }
  if (($k -ge [Windows.Forms.Keys]::F1) -and ($k -le [Windows.Forms.Keys]::F24)) {
    return 'F' + [string]([int]$k - [int][Windows.Forms.Keys]::F1 + 1)
  }
  switch ($k) {
    ([Windows.Forms.Keys]::Space) { return 'SPACE' }
    ([Windows.Forms.Keys]::Insert) { return 'INSERT' }
    ([Windows.Forms.Keys]::Delete) { return 'DELETE' }
    ([Windows.Forms.Keys]::Home) { return 'HOME' }
    ([Windows.Forms.Keys]::End) { return 'END' }
    ([Windows.Forms.Keys]::PageUp) { return 'PGUP' }
    ([Windows.Forms.Keys]::PageDown) { return 'PGDN' }
    # Punctuation has a name of its own because the character is not the key: ',' is 0x2C while
    # the key that types it is VK_OEM_COMMA (0xBC), and the same holds for . / - = ; ' \ and the
    # bracket pair - and a comma in the file would also split the chain in two.
    ([Windows.Forms.Keys]::Oemtilde) { return 'BACKTICK' }
    ([Windows.Forms.Keys]::OemMinus) { return 'MINUS' }
    ([Windows.Forms.Keys]::Oemplus) { return 'EQUALS' }
    ([Windows.Forms.Keys]::OemOpenBrackets) { return 'LBRACKET' }
    ([Windows.Forms.Keys]::OemCloseBrackets) { return 'RBRACKET' }
    ([Windows.Forms.Keys]::OemPipe) { return 'BACKSLASH' }
    ([Windows.Forms.Keys]::OemSemicolon) { return 'SEMICOLON' }
    ([Windows.Forms.Keys]::OemQuotes) { return 'QUOTE' }
    ([Windows.Forms.Keys]::OemComma) { return 'COMMA' }
    ([Windows.Forms.Keys]::OemPeriod) { return 'PERIOD' }
    ([Windows.Forms.Keys]::OemQuestion) { return 'SLASH' }
  }
  return $null
}

# The Win key is not part of WinForms' ModifierKeys and never arrives as a key of its own, so the
# only way to see it held while a chord is being recorded is the real keyboard state.
function Test-ChordWinHeld {
  try {
    if ((([Cb.Win]::GetAsyncKeyState(0x5B) -band 0x8000) -ne 0) -or (([Cb.Win]::GetAsyncKeyState(0x5C) -band 0x8000) -ne 0)) { return $true }
  } catch { }
  return $false
}

# The editor itself: a TextBox that covers the row's value area, styled from the theme so it
# reads as part of the surface rather than as a system control dropped on top. A number's editor
# is placed by Fit-EditorBox once it holds the value, so $alignRight only reserves the room it
# needs; the text itself is never right-aligned by the control.
function New-SettingEditor($form, $pal, [int]$x, [int]$y, [int]$w, [int]$h, [bool]$alignRight = $false) {
  $box = New-Object Windows.Forms.TextBox
  $box.BorderStyle = 'None'
  $box.Font = $script:FBody
  $box.BackColor = $pal['Field']
  $box.ForeColor = $pal['Text']
  $box.Left = $x
  $box.Top = $y
  $box.Width = $w
  $box.Height = $h
  # The number field right-aligns by geometry rather than by ES_RIGHT: see Fit-EditorBox.
  $form.Controls.Add($box)
  $box.BringToFront()
  return $box
}

# A number reads from the right in its field, and the field does that by geometry: the box is as
# wide as the text and its right edge stays where the field's text area ends. ES_RIGHT was the
# obvious way and the wrong one - an edit control that right-aligns its text puts the caret in
# the same column as the last digit (measured: "321" laid out 68..92 in an 89 px client, so the
# 1 was clipped and the bar sat on it). Sized to the text, the caret has the box's own padding
# to sit in and the value still hugs the right edge as it is typed.
function Fit-EditorBox($box, [int]$right, [int]$minW, [int]$maxW) {
  if ($null -eq $box -or $box.IsDisposed) { return }
  $tw = 0
  try {
    $g = $box.CreateGraphics()
    try { $tw = [int][Math]::Ceiling($g.MeasureString([string]$box.Text, $box.Font).Width) } finally { $g.Dispose() }
  } catch { $tw = 0 }
  $w = $tw + [int](Px 10)
  if ($w -gt $maxW) { $w = $maxW }
  if ($w -lt $minW) { $w = $minW }
  $box.Width = $w
  $box.Left = $right - $w
}

# Where the choice list opens: under the control it belongs to, in the control column, and above
# it when the list would run past the bottom of the window.
function Get-SettingDropRect($layout, [int]$rowTop, [int]$count) {
  $right = [int]$layout.ListRight - (Px 6)
  $w = (Px 170) + (Px 16)
  $itemH = Px 30
  $h = [int](Px 8) + ($count * $itemH)
  # the list opens under the control, not under the row: a row is two lines tall now, and a popup
  # that starts below it would sit a third of a card away from the box it belongs to
  $fieldH = Px 28
  $top = (Get-SettingsControlTop $layout $rowTop $fieldH) + $fieldH + (Px 6)
  $limit = [int]$layout.ListBottom - [int](Px 8)
  if (($top + $h) -gt $limit) { $top = [Math]::Max([int]$layout.ListTop, $rowTop - $h - (Px 4)) }
  return @{ Left = ($right - $w); Top = $top; Width = $w; Height = $h }
}

# The row a click lands on: -1 when the click is outside the list, so a click on the header or
# the footer neither selects nor edits anything. $scroll is a pixel offset, the same distance the
# paint moved the rows by, so a list scrolled to a half row still answers with the row under the
# pointer.
function Get-SettingsRowAt($layout, [int]$rows, [int]$scroll, [int]$px, [int]$py) {
  if ($py -lt [int]$layout.ListTop -or $py -ge [int]$layout.ListBottom) { return -1 }
  if ($px -lt [int]$layout.ListLeft -or $px -gt [int]$layout.ListRight) { return -1 }
  $i = [int][Math]::Floor(($py - [int]$layout.ListTop + $scroll) / [double]$layout.RowHeight)
  if ($i -lt 0 -or $i -ge $rows) { return -1 }
  return $i
}

# Whether a click landed on the switch of a boolean row rather than somewhere else in the row.
# The switch is the only part of a row that acts on a single click; the rest of the row selects.
function Test-SettingsToggleHit($layout, [int]$px, [int]$py, [int]$rowTop) {
  $t = Get-SettingsToggleRect $layout $rowTop
  return ($px -ge [int]$t.Left -and $px -le ([int]$t.Left + [int]$t.Width) -and
    $py -ge [int]$t.Top -and $py -le ([int]$t.Top + [int]$t.Height))
}

# Where the editor sits for a row: over the control column, holding the same vertical middle the
# value does, so the text does not jump when the box appears.
function Get-SettingEditRect($layout, [int]$rowTop, [int]$width = 0) {
  $h = Px 28
  # the control column, so the box covers the value and not the description beside it
  if ($width -le 0) { $width = Px 170 }
  $right = [int]$layout.ListRight - (Px 12)
  $left = $right - $width
  if ($left -lt ([int]$layout.ListLeft + (Px 120))) { $left = [int]$layout.ListLeft + (Px 120) }
  return @{ Left = $left; Top = (Get-SettingsControlTop $layout $rowTop $h); Width = ($right - $left); Height = $h }
}

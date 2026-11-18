# lib/settings-model.ps1 - the rows a settings window shows.
#
# The settings live in schema\clipboard.ps1, which knows a type, a range, a default and a
# sentence of help for every key. What it does not know is how to present them: which keys
# belong together, and what to call a key to a person. Both are decided here, so the window
# draws rows and nothing else.
#
# Nothing in this file draws or writes: a row is a hashtable, and every function here is a
# pure function of the schema plus the current settings, which is what makes the grouping
# and the display text testable without a window.

# Groups in the order the left column lists them, with the keys that belong to each. A key
# that no group names still shows up under Other, so adding a setting to the schema can never
# make it unreachable in the window.
function Get-SettingGroupTable {
  return [ordered]@{
    'Clipboard' = @('CaptureImages', 'MaxImageBytes', 'CaptureRich', 'MaxHtmlBytes', 'MaxRtfBytes',
      'RtfImagesUpToBytes', 'InlineImageUpToBytes', 'ExcludePattern', 'Interval', 'BlobChars')
    'Paste' = @('PasteKeys', 'PasteSettle', 'ModReleaseTimeout', 'PasteRich', 'PasteFilesAsText',
      'PasteTyping', 'NoPaste', 'AppRules')
    'Hotkey' = @('Hotkey', 'HotkeyFallbacks')
    'History' = @('MaxItems', 'MaxTextBytes', 'MaxTextTotalBytes', 'MaxMediaTotalBytes')
    'Panel' = @('WindowWidth', 'SaveWindowPos', 'WindowLeft', 'WindowTop', 'ShowTime', 'ShowTypeIcon',
      'ShowThumbnails', 'Highlight', 'HighlightMaxBytes', 'ShowNewlineMarker', 'PreviewHover',
      'PreviewDelay', 'PreviewChars', 'Undo', 'ScrollLines', 'Animations', 'DpiAware')
    'Compact' = @('CompactMode', 'CompactWidth', 'CompactRows')
    'Appearance' = @('Theme')
    'Startup' = @('Autostart', 'DesktopShortcut', 'Balloon')
    'Plugins' = @('Plugins')
    'Storage' = @('DataDir')
  }
}

# "MaxTextTotalBytes" reads as "Max text total bytes". The key stays the identity - it is what
# the ini holds and what `config set` types - so a label is never stored anywhere.
function Get-SettingLabel([string]$key) {
  if (-not $key) { return '' }
  $t = ([string]$key).Trim()
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt $t.Length; $i++) {
    $c = $t[$i]
    if ($i -gt 0 -and [char]::IsUpper($c)) {
      $prev = $t[$i - 1]
      $nextLower = ($i + 1 -lt $t.Length) -and [char]::IsLower($t[$i + 1])
      if ([char]::IsLower($prev) -or [char]::IsDigit($prev) -or $nextLower) { [void]$sb.Append(' ') }
    }
    [void]$sb.Append($c)
  }
  $s = $sb.ToString()
  if ($s.Length -eq 0) { return '' }
  return ([string]$s[0]).ToUpperInvariant() + $s.Substring(1)
}

# What kind of editor a value needs. The schema types that need the same editor collapse into
# one kind, so the window has four behaviours to draw instead of eight.
function Get-SettingKind($spec) {
  $t = ''
  if ($null -ne $spec -and $spec.Contains('Type')) { $t = [string]$spec['Type'] }
  switch ($t.ToLowerInvariant()) {
    'bool' { return 'bool' }
    'int' { return 'number' }
    'hotkey' { return 'hotkey' }
    'theme' { return 'theme' }
    'regex' { return 'regex' }
    'list' { return 'list' }
    'apprule' { return 'rules' }
    default { return 'text' }
  }
}

# the value the settings file holds right now: the schema points at the variable that drives
# the behaviour, so reading it here cannot disagree with what the program does. A variable is
# a real boolean while the file spells it 1 / 0, and every reader here - the switch, the help
# text, the writer - speaks the file spelling, so a boolean is normalised on the way out.
function Get-SettingRaw($schema, [string]$key) {
  $spec = Get-SchemaProperty $schema $key
  if ($null -eq $spec) { return '' }
  $raw = $null
  if ($spec.Contains('Ref') -and $null -ne $spec['Ref']) {
    try { $raw = [string]$spec['Ref'].Value } catch { $raw = $null }
  }
  if ($null -eq $raw -and (Get-Command Get-ConfigReport -ErrorAction SilentlyContinue)) {
    try {
      $vals = Get-ConfigReport
      if ($null -ne $vals -and $vals.Contains($key)) { $raw = [string]$vals[$key] }
    } catch { }
  }
  if ($null -eq $raw) { $raw = [string](Get-SchemaDefault $schema $key) }
  $type = ''
  if ($spec.Contains('Type')) { $type = [string]$spec['Type'] }
  if ($type -eq 'bool') {
    $l = $raw.Trim().ToLowerInvariant()
    if (@('1', 'true', 'on', 'yes') -contains $l) { return '1' }
    if (@('0', 'false', 'off', 'no') -contains $l) { return '0' }
  }
  return $raw
}

# The text a row shows next to its label. A boolean is never a bare 0/1 here: the panel speaks
# in On and Off, and both are the words the footer uses for a toggle. An empty value falls
# back to the schema hint, so "(no rules)" says more than a blank line.
function Format-SettingText($schema, [string]$key, [string]$raw) {
  $spec = Get-SchemaProperty $schema $key
  $kind = Get-SettingKind $spec
  if ($kind -eq 'bool') {
    if ([string]$raw -eq '1') { return 'On' }
    return 'Off'
  }
  if ([string]$raw -eq '') {
    $hint = ''
    if ($null -ne $spec) { $hint = [string](Get-SchemaHint $schema $key) }
    if ($hint) { return $hint }
    return '(empty)'
  }
  return [string]$raw
}

# The sentence under the value: the schema's own Description, plus the range an integer
# accepts. The description is the documentation of the setting, so quoting it here keeps the
# window and the README from inventing two different stories about one key.
function Get-SettingHelp($schema, [string]$key) {
  $spec = Get-SchemaProperty $schema $key
  if ($null -eq $spec) { return '' }
  $d = ''
  if ($spec.Contains('Description')) { $d = [string]$spec['Description'] }
  if ((Get-SettingKind $spec) -eq 'number') {
    $lo = $null
    $hi = $null
    if ($spec.Contains('Minimum')) { $lo = $spec['Minimum'] }
    if ($spec.Contains('Maximum')) { $hi = $spec['Maximum'] }
    # the range comes first: a description is ellipsized when it does not fit, and the numbers
    # are the part that has to survive the cut
    if ($null -ne $lo -and $null -ne $hi) { $d = '(' + [string]$lo + '-' + [string]$hi + ') ' + $d }
  }
  return $d
}

# Settings that only take effect while another one says so. Editing them while the switch that
# owns them is off would look like it worked and change nothing, which is the confusing half of
# a settings page: the row is shown, greyed, with the reason it does nothing.
#
# Value is the file spelling the owner has to hold; Why is what the footer says.
function Get-SettingEnabledBy {
  return @{
    'WindowLeft'           = @{ Key = 'SaveWindowPos'; Value = '1'; Why = 'Save window position is off' }
    'WindowTop'            = @{ Key = 'SaveWindowPos'; Value = '1'; Why = 'Save window position is off' }
    'MaxImageBytes'        = @{ Key = 'CaptureImages'; Value = '1'; Why = 'Capture pictures is off' }
    'MaxHtmlBytes'         = @{ Key = 'CaptureRich'; Value = '1'; Why = 'Capture formatted text is off' }
    'MaxRtfBytes'          = @{ Key = 'CaptureRich'; Value = '1'; Why = 'Capture formatted text is off' }
    'RtfImagesUpToBytes'   = @{ Key = 'CaptureRich'; Value = '1'; Why = 'Capture formatted text is off' }
    'InlineImageUpToBytes' = @{ Key = 'CaptureRich'; Value = '1'; Why = 'Capture formatted text is off' }
    'HighlightMaxBytes'    = @{ Key = 'Highlight'; Value = '1'; Why = 'Highlight matches is off' }
    'PreviewDelay'         = @{ Key = 'PreviewHover'; Value = '1'; Why = 'The hover preview is off' }
    'PreviewChars'         = @{ Key = 'PreviewHover'; Value = '1'; Why = 'The hover preview is off' }
    'CompactWidth'         = @{ Key = 'CompactMode'; Value = '1'; Why = 'The compact panel is off' }
    'CompactRows'          = @{ Key = 'CompactMode'; Value = '1'; Why = 'The compact panel is off' }
    'PasteKeys'            = @{ Key = 'NoPaste'; Value = '0'; Why = 'Pasting is turned off' }
    'PasteSettle'          = @{ Key = 'NoPaste'; Value = '0'; Why = 'Pasting is turned off' }
    'ModReleaseTimeout'    = @{ Key = 'NoPaste'; Value = '0'; Why = 'Pasting is turned off' }
    'PasteRich'            = @{ Key = 'NoPaste'; Value = '0'; Why = 'Pasting is turned off' }
    'PasteFilesAsText'     = @{ Key = 'NoPaste'; Value = '0'; Why = 'Pasting is turned off' }
    'PasteTyping'          = @{ Key = 'NoPaste'; Value = '0'; Why = 'Pasting is turned off' }
    'AppRules'             = @{ Key = 'NoPaste'; Value = '0'; Why = 'Pasting is turned off' }
  }
}

# One row per key of one group, in the order the group names them. Keys a group names but the
# schema no longer has are skipped instead of drawing an editor that cannot write anything.
function Get-SettingsRows($schema, [string]$group) {
  $rows = New-Object System.Collections.Generic.List[object]
  $table = Get-SettingGroupTable
  $keys = @()
  if ($table.Contains($group)) {
    $keys = @($table[$group])
  } elseif ($group -ceq 'Other') {
    $named = @{}
    foreach ($g in @($table.Keys)) { foreach ($key in @($table[$g])) { $named[[string]$key] = $true } }
    $props = Get-SchemaProperties $schema
    if ($null -ne $props) {
      foreach ($key in @($props.Keys)) { if (-not $named.ContainsKey([string]$key)) { $keys += [string]$key } }
    }
  }
  foreach ($key in $keys) {
    $spec = Get-SchemaProperty $schema $key
    if ($null -eq $spec) { continue }
    $raw = Get-SettingRaw $schema $key
    $enabled = $true
    $why = ''
    $dep = Get-SettingEnabledBy
    if ($dep.ContainsKey($key)) {
      $owner = $dep[$key]
      if ((Get-SettingRaw $schema ([string]$owner.Key)) -ne [string]$owner.Value) {
        $enabled = $false
        $why = [string]$owner.Why
      }
    }
    $rows.Add(@{
      Key     = $key
      Group   = $group
      Label   = Get-SettingLabel $key
      Kind    = Get-SettingKind $spec
      Raw     = $raw
      Text    = Format-SettingText $schema $key $raw
      Help    = Get-SettingHelp $schema $key
      Choices = @(Get-SettingChoices $schema $key)
      Enabled = $enabled
      Why     = $why
    })
  }
  return $rows.ToArray()
}

# The groups that actually have rows, in table order. A group whose keys all disappeared from
# the schema is not offered, so the left column never lists an empty page.
function Get-SettingGroups($schema) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($g in @((Get-SettingGroupTable).Keys)) {
    $rows = @(Get-SettingsRows $schema $g)
    if ($rows.Count -gt 0) { $out.Add([string]$g) }
  }
  # anything the table does not name is still reachable
  $named = @{}
  foreach ($k in @((Get-SettingGroupTable).Keys)) {
    foreach ($key in @((Get-SettingGroupTable)[$k])) { $named[[string]$key] = $true }
  }
  $loose = 0
  $props = Get-SchemaProperties $schema
  if ($null -ne $props) {
    foreach ($key in @($props.Keys)) { if (-not $named.ContainsKey([string]$key)) { $loose++ } }
  }
  if ($loose -gt 0) { $out.Add('Other') }
  return $out.ToArray()
}

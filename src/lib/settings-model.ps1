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
    'Panel' = @('WindowWidth', 'Rows', 'SaveWindowPos', 'WindowLeft', 'WindowTop', 'ScrollLines', 'Undo')
    'Compact' = @('CompactMode', 'CompactWidth', 'CompactRows')
    # theme plus everything that only changes how the panel looks or animates; the keys that
    # move or size the window stay on Panel
    'Appearance' = @('Theme', 'Language', 'ShowTime', 'ShowTypeIcon', 'ShowThumbnails', 'Highlight', 'HighlightMaxBytes',
      'ShowNewlineMarker', 'PreviewHover', 'PreviewDelay', 'PreviewChars', 'Animations', 'DpiAware')
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
  # "bytes" is the file's unit, not what the user sets: the row shows the size in B, KB or MB.
  # The replacement keeps the capital the key gave the word - every other word in the label
  # keeps its own, so a lowercase "size" would be the one word out of step.
  $s = ($s -replace ' bytes$', ' Size')
  # A key spells an acronym in camel case (MaxRtfBytes); a label that said "Rtf" would be the one
  # place in the window where it is not written the way the format itself is.
  foreach ($pair in @(@('Html', 'HTML'), @('Rtf', 'RTF'), @('Dpi', 'DPI'), @('Url', 'URL'))) {
    $s = $s -creplace ('\b' + $pair[0] + '\b'), $pair[1]
  }
  $derived = ([string]$s[0]).ToUpperInvariant() + $s.Substring(1)
  $labelKey = 'settings.key.' + $key
  return (Get-UiTextOr $labelKey $derived)
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
    # a chain of chords is drawn the way one chord is - key caps - so it is the same kind; what
    # it does not share is the recorder, which is a row flag (Record) and not a kind
    'hotkeys' { return 'hotkey' }
    'theme' { return 'theme' }
    'enum' { return 'choice' }
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
    if ([string]$raw -eq '1') { return (Get-UiText 'settings.value.on') }
    return (Get-UiText 'settings.value.off')
  }
  # A list holds several names and the value column is one line wide, so it states the count
  # instead: which names are ticked is what opening the list shows.
  if ($kind -eq 'list') { return (Format-SettingListText $raw (Get-SettingChoices $schema $key)) }
  if ($kind -eq 'number') {
    # one string for anything that wants the whole value in a word: "16 MB", not 16777216
    $view = Get-SettingNumberView $schema $key $raw
    if ([string]$view.Number -eq '') {
      # an empty field holds its hint, the same word every other kind shows: (auto) says the
      # position follows the screen rather than being zero
      $hint = ''
      if ($null -ne $spec) {
        $hintKey = 'settings.hint.' + $key
        $hintRaw = [string](Get-SchemaHint $schema $key)
        $hint = Get-UiTextOr $hintKey $hintRaw
      }
      if ($hint) { return $hint }
      return '(empty)'
    }
    if ([string]$view.Unit) { return ([string]$view.Number + ' ' + [string]$view.Unit) }
    return [string]$view.Number
  }
  if ([string]$raw -eq '') {
    $hint = ''
    if ($null -ne $spec) {
      $hintKey = 'settings.hint.' + $key
      $hintRaw = [string](Get-SchemaHint $schema $key)
      $hint = Get-UiTextOr $hintKey $hintRaw
    }
    if ($hint) { return $hint }
    return (Get-UiText 'settings.value.empty')
  }
  return [string]$raw
}

# The count a list setting shows: All, or how many of the names on offer are ticked.
function Format-SettingListText([string]$raw, $choices) {
  $all = @($choices)
  $on = @(Split-SettingList $raw)
  if ($all.Count -eq 0) { return (Get-UiText 'settings.value.selected' @($on.Count)) }
  $hit = 0
  foreach ($n in $on) {
    foreach ($c in $all) { if ([string]$c -ieq [string]$n) { $hit++; break } }
  }
  if ($hit -ge $all.Count) { return (Get-UiText 'settings.value.all') }
  return (Get-UiText 'settings.value.of' @($hit, $all.Count))
}

# The sentence under the value: the schema's own Description, plus the range an integer
# accepts. The description is the documentation of the setting, so quoting it here keeps the
# window and the README from inventing two different stories about one key.
function Get-SettingHelp($schema, [string]$key) {
  $spec = Get-SchemaProperty $schema $key
  if ($null -eq $spec) { return '' }
  # a read-only value is never typed here, so the line that would have described it says why
  if ($spec.Contains('ReadOnly')) {
    # the reason is a sentence of the window like any other: the language file words it under
    # settings.why.<Key>, and a language with none keeps the schema's own words
    $reason = Get-UiTextOr ('settings.why.' + $key) ([string]$spec['ReadOnly'])
    # a row that opens a dialog is not read-only in the same sense: it is changed by picking, so
    # the line says what picking does instead of forbidding it
    if ($spec.Contains('Pick')) { return (Get-UiText 'settings.help.pick' @($reason)) }
    return (Get-UiText 'settings.help.readonly' @($reason))
  }
  $d = ''
  if ($spec.Contains('Description')) { $d = [string]$spec['Description'] }
  # the window quotes the language file; the schema line stays as it is, because it is also the
  # comment `config init` writes into clipboard.ini and that file is English
  $d = Get-UiTextOr ('settings.desc.' + $key) $d
  # A value only install acts on cannot be made to take effect by any reload: the shortcut it
  # controls is created or removed by `install`. The line says that first, because "why did the
  # tick do nothing" is the question a settings page has to answer.
  if (Test-SchemaInstallOnly $schema $key) { $d = (Get-UiText 'settings.help.install' @($d)) }
  if ((Get-SettingKind $spec) -eq 'number') {
    $lo = $null
    $hi = $null
    if ($spec.Contains('Minimum')) { $lo = $spec['Minimum'] }
    if ($spec.Contains('Maximum')) { $hi = $spec['Maximum'] }
    # the range comes first: a description is ellipsized when it does not fit, and the numbers
    # are the part that has to survive the cut. A range is read in the same unit as the field
    # above it - "1 KB-100 MB", never 1024-104857600 beside a box that says MB.
    if ($null -ne $lo -and $null -ne $hi) {
      $loText = [string]$lo
      $hiText = [string]$hi
      if ($spec.Contains('Unit')) {
        $a = Get-SettingNumberView $schema $key ([string]$lo)
        $b = Get-SettingNumberView $schema $key ([string]$hi)
        if ([string]$a.Unit -and [string]$a.Unit -eq [string]$b.Unit) {
          # one unit for both ends is written once: 50-60000 ms, not 50 ms-60000 ms
          $loText = [string]$a.Number
          $hiText = [string]$b.Number + ' ' + [string]$b.Unit
        } else {
          if ([string]$a.Unit) { $loText = ([string]$a.Number + ' ' + [string]$a.Unit) }
          if ([string]$b.Unit) { $hiText = ([string]$b.Number + ' ' + [string]$b.Unit) }
        }
      }
      $d = '(' + $loText + '-' + $hiText + ') ' + $d
    }
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

# The keys a page names, in drawing order. Everything not named by the table belongs to Other,
# and About has no keys at all because it states things instead of setting them.
function Get-SettingGroupKeys($schema, [string]$group) {
  $keys = @()
  if ($group -ceq 'About') { return $keys }
  $table = Get-SettingGroupTable
  if ($table.Contains($group)) { return @($table[$group]) }
  if ($group -cne 'Other') { return $keys }
  $named = @{}
  foreach ($g in @($table.Keys)) { foreach ($key in @($table[$g])) { $named[[string]$key] = $true } }
  $props = Get-SchemaProperties $schema
  if ($null -ne $props) {
    foreach ($key in @($props.Keys)) { if (-not $named.ContainsKey([string]$key)) { $keys += [string]$key } }
  }
  return $keys
}

# One row per key of one group, in the order the group names them. Keys a group names but the
# schema no longer has are skipped instead of drawing an editor that cannot write anything.
#
# $pending is the staged set the window holds before Save: a key in it is drawn with the value
# waiting to be written, so the page previews the change. A value that owns another row is read
# from the same overlay, which is why unticking Capture pictures greys MaxImageBytes before
# anything reaches the file.
#
# $only limits the build to a set of keys (key -> true), which is what lets one changed value
# rebuild its own row and leave the rest of the page alone (Update-SettingRows).
function Get-SettingsRows($schema, [string]$group, $pending = $null, $only = $null) {
  # About is not built from keys: it states what the program is, so it has rows of its own
  if ($group -ceq 'About') { return (Get-SettingAboutRows) }
  $rows = New-Object System.Collections.Generic.List[object]
  $keys = @(Get-SettingGroupKeys $schema $group)
  # one read of one key, from the staged value when it has one
  $rawOf = {
    param([string]$k)
    if ($null -ne $pending -and $pending.Contains($k)) { return [string]$pending[$k] }
    return (Get-SettingRaw $schema $k)
  }
  foreach ($key in $keys) {
    if ($null -ne $only -and -not $only.Contains([string]$key)) { continue }
    $spec = Get-SchemaProperty $schema $key
    if ($null -eq $spec) { continue }
    $raw = & $rawOf $key
    $staged = ($null -ne $pending -and $pending.Contains($key))
    $kind = Get-SettingKind $spec
    # a number is shown in its own unit and typed in that unit, so the row carries the three
    # pieces the paint and the editor need: what to show, the label beside it, and the factor
    # that turns it back into the value the file holds
    $view = @{ Number = [string]$raw; Unit = ''; Scale = 1 }
    if ($kind -eq 'number') { $view = Get-SettingNumberView $schema $key $raw }
    $enabled = $true
    $why = ''
    $dep = Get-SettingEnabledBy
    if ($dep.ContainsKey($key)) {
      $owner = $dep[$key]
      if ((& $rawOf ([string]$owner.Key)) -ne [string]$owner.Value) {
        $enabled = $false
        # the reason is a sentence of the window, so the language file may word it - the identity
        # is the key that owns the row - and a language with none keeps the table's own words
        $why = Get-UiTextOr ('settings.why.' + [string]$owner.Key) ([string]$owner.Why)
      }
    }
    $choices = @(Get-SettingChoices $schema $key)
    $choicesShown = @(Get-SettingChoiceLabels $schema $key $choices)
    $text = Format-SettingText $schema $key $raw
    # a value drawn with a word of its own (a language) shows that word here as well, so the row
    # and the list it opens never disagree about what is selected
    if ($choicesShown.Count -eq $choices.Count -and $choices.Count -gt 0) {
      for ($ci = 0; $ci -lt $choices.Count; $ci++) {
        if ([string]$choices[$ci] -ieq [string]$raw) { $text = [string]$choicesShown[$ci] }
      }
    }
    $rows.Add(@{
      Key     = $key
      Group   = $group
      Label   = Get-SettingLabel $key
      Kind    = Get-SettingKind $spec
      # a list setting is a multi-select: several names, ticked in place, instead of one value
      Multi   = ((Get-SettingKind $spec) -eq 'list')
      # a value the schema marks read-only is shown and refused, with the reason in its help
      Locked  = $spec.Contains('ReadOnly')
      # a shortcut row waits for a chord from the keyboard; a chain of them is also recorded, and
      # the chord joins the end of the list instead of replacing it
      Record  = ((Get-SettingKind $spec) -eq 'hotkey')
      # a chain is drawn as one line per chord, each with its own delete button: a list on one
      # line with "+3" behind it says nothing about which chords are in it
      Chain   = ([string]$spec['Type'] -ceq 'hotkeys')
      # a path is chosen in a dialog, not typed: Pick names the dialog the row opens
      Pick    = $(if ($spec.Contains('Pick')) { [string]$spec['Pick'] } else { '' })
      Raw     = $raw
      # the row holds a value that is not in the file yet: the paint marks it, Save writes it
      Pending = $staged
      Number  = [string]$view.Number
      Unit    = [string]$view.Unit
      Scale   = [double]$view.Scale
      Text    = $text
      Help    = Get-SettingHelp $schema $key
      Choices = @($choices)
      # the words the open list draws, same order as Choices
      ChoiceLabels = @($choicesShown)
      # a shortcut row draws its value as key caps instead of a string
      Chords  = @(Get-SettingChordList $schema $key $raw)
      Enabled = $enabled
      Why     = $why
    })
  }
  return $rows.ToArray()
}

# The rows of a page against the rows it showed a moment ago: the ones whose value did not move
# are carried over as they are, and only the rest is built. One flipped switch rebuilds one row
# instead of the thirteen a page may hold - and a row that names a switch as its owner is
# rebuilt too, because whether it is greyed or lit is decided by a value that just changed.
#
# Nothing is answered for About: its rows state facts rather than values, so there is nothing to
# compare and the caller builds them.
#
# A page is a node tree (lib\ui\framework.ps1): one child per row, keyed by the setting key, with
# the row as the child's values. Which row actually changes is then the tree patch's question,
# the same one every other surface asks, and this file only says which keys it wants and which
# of them it had to build.

# Read once at load, not per call: PowerShell 5.1 compiles a ScriptBlock on its first call, and a
# page refresh must not pay for that at every value change.
$script:SettingRowKeyOf = { param($spec) [string]$spec['Key'] }
$script:SettingRowMake = { param($spec) New-UiComponent 'row' $spec['Props'] }
# What makes a row draw differently: its value, whether that value is staged, and whether the row
# is lit. Comparing the whole record would also hash its labels, help lines and choice lists on
# every refresh, and none of those can move while a page is up.
$script:SettingRowStamp = { param($r) ([string]$r.Raw + '|' + [string]$r.Pending + '|' + [string]$r.Enabled) }

# A page's rows as a fresh tree, for a page that was just built or came out of the row cache.
function New-SettingRowTree($rows) {
  $page = New-UiComponent 'page'
  [void](Mount-UiComponent $page $null)
  $specs = New-Object System.Collections.Generic.List[object]
  foreach ($r in @($rows)) {
    if ($null -eq $r) { continue }
    $specs.Add(@{ Key = ([string]$r.Key); Props = $r })
  }
  [void](Sync-UiTree $page $specs.ToArray() $script:SettingRowKeyOf $script:SettingRowMake $script:SettingRowStamp)
  return $page
}

function Update-SettingRows($schema, [string]$group, $page, $pending = $null) {
  if ($null -eq $schema -or $group -ceq 'About') { return $null }
  if ($null -eq $page) { return $null }
  $keys = @(Get-SettingGroupKeys $schema $group)
  if ($keys.Count -eq 0) { return $null }
  $held = @{}
  foreach ($c in $page.Children.ToArray()) {
    $k = [string]$c.Key
    if ($k -and $null -ne $c.Props) { $held[$k] = $c.Props }
  }
  if ($held.Count -eq 0) { return $null }
  $deps = Get-SettingEnabledBy
  $build = @{}
  foreach ($one in $keys) {
    $key = [string]$one
    $raw = [string](Get-SettingRaw $schema $key)
    $staged = $false
    if ($null -ne $pending -and $pending.Contains($key)) { $raw = [string]$pending[$key]; $staged = $true }
    $enabled = $true
    if ($deps.ContainsKey($key)) {
      $owner = $deps[$key]
      $ownerKey = [string]$owner.Key
      $ownerRaw = [string](Get-SettingRaw $schema $ownerKey)
      if ($null -ne $pending -and $pending.Contains($ownerKey)) { $ownerRaw = [string]$pending[$ownerKey] }
      $enabled = ($ownerRaw -ceq [string]$owner.Value)
    }
    $keep = $false
    if ($held.ContainsKey($key)) {
      $old = $held[$key]
      $keep = ([string]$old.Raw -ceq $raw) -and ([bool]$old.Pending -eq $staged) -and ([bool]$old.Enabled -eq $enabled)
    }
    if (-not $keep) { $build[$key] = $true }
  }
  $fresh = @{}
  if ($build.Count -gt 0) {
    foreach ($r in @(Get-SettingsRows $schema $group $pending $build)) { $fresh[[string]$r.Key] = $r }
  }
  # The spec of a row is the row itself: a row that did not move carries the same record, so its
  # fingerprint matches what the page already holds and the patch leaves the node alone.
  $specs = New-Object System.Collections.Generic.List[object]
  foreach ($one in $keys) {
    $key = [string]$one
    $r = $null
    if ($fresh.ContainsKey($key)) { $r = $fresh[$key] } elseif ($held.ContainsKey($key)) { $r = $held[$key] }
    if ($null -eq $r) { continue }
    $specs.Add(@{ Key = $key; Props = $r })
  }
  $patch = Sync-UiTree $page $specs.ToArray() $script:SettingRowKeyOf $script:SettingRowMake $script:SettingRowStamp
  return @{ Rows = (Get-UiNodeValues $page); Built = ([int]$patch.Created + [int]$patch.Updated); Reused = [int]$patch.Reused }
}

# The groups that actually have rows, in table order. A group whose keys all disappeared from
# the schema is not offered, so the left column never lists an empty page.
#
# This used to build every page's rows and keep the ones that came back non-empty, which cost
# about 230 ms at every open of the window - ten pages of labels, help lines and choices, built
# to answer a question about presence, and then built again for the page actually shown. All it
# needs is whether a key of the group is still in the schema.
function Get-SettingGroups($schema) {
  $out = New-Object System.Collections.Generic.List[string]
  $table = Get-SettingGroupTable
  $named = @{}
  foreach ($g in @($table.Keys)) {
    $has = $false
    foreach ($one in @($table[$g])) {
      # the argument is a plain variable: a cast written straight into a call is read as a
      # second argument, and the lookup silently answers nothing
      $key = [string]$one
      $named[$key] = $true
      if (-not $has -and $null -ne (Get-SchemaProperty $schema $key)) { $has = $true }
    }
    if ($has) { $out.Add([string]$g) }
  }
  # anything the table does not name is still reachable
  $loose = 0
  $props = Get-SchemaProperties $schema
  if ($null -ne $props) {
    foreach ($key in @($props.Keys)) { if (-not $named.ContainsKey([string]$key)) { $loose++ } }
  }
  if ($loose -gt 0) { $out.Add('Other') }
  # About is always there: it is not a page of settings, it is where the version, the store and
  # the loaded plugins are stated, and a window with no such page has nowhere to put them
  $out.Add('About')
  return $out.ToArray()
}

# Which pages hold a value that is staged but not saved. The page list marks them, because a
# change made three pages ago is invisible from here and Save would otherwise look idle.
function Get-SettingGroupsWithPending($schema, $pending) {
  $out = New-Object System.Collections.Generic.List[string]
  if ($null -eq $pending -or @($pending.Keys).Count -eq 0) { return $out.ToArray() }
  $table = Get-SettingGroupTable
  $named = @{}
  foreach ($g in @($table.Keys)) {
    foreach ($key in @($table[$g])) { $named[[string]$key] = [string]$g }
  }
  foreach ($key in @($pending.Keys)) {
    $where = ''
    if ($named.ContainsKey([string]$key)) { $where = [string]$named[[string]$key] } else { $where = 'Other' }
    if ($where -and -not $out.Contains($where)) { $out.Add($where) }
  }
  return $out.ToArray()
}

# One row that states something instead of setting it: no editor, no staged value, no switch.
# It is marked locked so the row never lights up under the pointer - there is nothing to click.
function New-SettingInfoRow([string]$key, [string]$label, [string]$text, [string]$help) {
  return @{
    Key = $key; Group = 'About'; Label = $label; Kind = 'info'
    Multi = $false; Locked = $true; Record = $false; Chain = $false; Pick = ''
    Raw = ''; Pending = $false; Number = ''; Unit = ''; Scale = 1
    Text = $text; Help = $help; Choices = @(); Chords = @()
    Enabled = $true; Why = ''
  }
}

# The facts the About page states, read from the same variables and the same reader the rest of
# the tool uses, so the page cannot claim a version the program does not have. Anything whose
# module is not loaded in this command is left out instead of guessed.
function Get-SettingAboutFacts {
  $f = [ordered]@{}
  $f['Version'] = [string]$script:Version
  if (Get-Command Get-StoreVersion -ErrorAction SilentlyContinue) {
    try {
      $sv = Get-StoreVersion
      $code = [string]$sv.Code
      $label = [string]$sv.Label
      # A state the window words for itself: a missing, empty or unreadable file has no
      # technical name, and an old or newer header means nothing without this build to compare
      # it to, so each one says it in words instead of resting on the bare code. A template
      # carries the header token ({0} = CBHIST vN); an entry with no placeholder is a word.
      $tpl = Get-UiTextOr ('settings.about.format.' + $code) ''
      if ($tpl) { $label = ($tpl -f $label) }
      $f['Data Format'] = $label
    } catch { }
    if (Get-Command Get-Records -ErrorAction SilentlyContinue) {
      try {
        $n = [string]@(Get-Records).Count
        # the row states a count and the label says what is counted; a language file may put a
        # unit word around the number
        $line = $n
        $tpl = Get-UiTextOr 'settings.about.entriesLine' ''
        if ($tpl) { $line = ($tpl -f $n) }
        $f['Entries'] = $line
      } catch { }
    }
  }
  $f['Store Folder'] = [string]$script:StoreDir
  $f['Settings File'] = [string]$script:IniPath
  return $f
}

# The last segment of a path, which is the part a row can show: the rest is in the help line.
function Get-SettingLeaf([string]$path) {
  $t = ([string]$path).TrimEnd('\', '/')
  if (-not $t) { return [string]$path }
  $i = $t.LastIndexOfAny([char[]]@('\', '/'))
  if ($i -lt 0) { return $t }
  if ($i -eq 0) { return $t }
  return $t.Substring($i + 1)
}

# The About page: one row per fact, in a fixed order, each with the sentence that says what it
# is. A path is shown by its last segment and stated in full in the help line, the same way the
# Storage page shows the store folder.
function Get-SettingAboutRows {
  $facts = Get-SettingAboutFacts
  $rows = New-Object System.Collections.Generic.List[object]
  $help = @{
    'Version'       = 'clipboard, the clipboard history for Windows'
    'Data Format'   = 'the header history.dat is written with; clipboard migrate upgrades an older file'
    'Entries'       = 'rows in history.dat; Max Items caps them, a mark can protect a row'
    'Store Folder'  = 'history.dat, the media files and the log live here'
    'Settings File' = 'every value in this window is written here'
    'Plugins'       = 'loaded in this order; Plugins= picks them, an empty value means all of them'
  }
  foreach ($k in @($facts.Keys)) {
    # the fact name stays the identity - it is the row key and the word the schema knows - and
    # only what the row says is translated
    $name = [string]$k
    $labelKey = 'settings.about.label.' + $name
    $label = Get-UiTextOr $labelKey $name
    $text = [string]$facts[$k]
    $why = ''
    if ($help.ContainsKey($name)) { $why = [string]$help[$name] }
    $why = Get-UiTextOr ('settings.about.' + $name) $why
    if ($name -ceq 'Version') { $text = (Get-UiText 'settings.about.versionLine' @($text)) }
    if ($name -ceq 'Store Folder' -or $name -ceq 'Settings File') {
      # the full path is the fact; the row shows the segment that names it
      if ($why) { $why = $text + '  -  ' + $why } else { $why = $text }
      $text = Get-SettingLeaf $text
    }
    $rows.Add((New-SettingInfoRow ('About.' + $name) $label $text $why))
  }
  # the plugins are a list, and a list in the value column is cut at its head: the count is what
  # fits there, the names go in the sentence under it
  $names = @($script:PluginList)
  $pText = (Get-UiText 'settings.about.none')
  $pWhy = Get-UiTextOr 'settings.about.Plugins' ([string]$help['Plugins'])
  if ($names.Count -eq 1) { $pText = (Get-UiText 'settings.about.loadedOne' @(1)) } elseif ($names.Count -gt 1) { $pText = (Get-UiText 'settings.about.loadedMany' @($names.Count)) }
  if ($names.Count -gt 0) {
    # the sentence names each plugin the way the window and the right-click menu do: the file
    # name is the identity, not a second name for the same plugin
    $shown = @($names | ForEach-Object { Get-PluginCaption ([string]$_) })
    $pWhy = ($shown -join ', ') + '  -  ' + $pWhy
  }
  $rows.Add((New-SettingInfoRow 'About.Plugins' (Get-UiText 'settings.about.label.Plugins') $pText $pWhy))
  # the one row on this page that leaves the window: the repository. It is a link, not a fact -
  # the value column carries the owner/name pair in the accent colour and the address in full is
  # the sentence under it, because a URL in the value column would be cut at its head.
  $url = [string]$script:ProjectUrl
  if ($url) {
    $short = ($url.TrimEnd('/') -replace '^(?i)https?://[^/]+/', '')
    if (-not $short) { $short = $url }
    $link = New-SettingInfoRow 'About.Repository' (Get-UiText 'settings.about.label.Repository') $short (Get-UiText 'settings.about.repository' @($url))
    $link.Kind = 'link'
    $link.Locked = $false
    $link.Url = $url
    $rows.Add($link)
  }
  return $rows.ToArray()
}

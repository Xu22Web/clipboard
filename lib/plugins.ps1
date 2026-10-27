# lib/plugins.ps1 - optional extension layer for clipboard.
#
# A plugin is one .ps1 file inside <root>\plugins that returns a hashtable:
#
#   @{
#     Name        = 'my-thing'                # required, must match the file name
#     Description = 'what it adds'             # shown in `clipboard config`
#     Commands    = @{ 'open' = { param($value) ... } }       # `clipboard open 3`
#     CommandHelp = @{ 'open' = 'what it does' }              # one line per command
#     CommandOrder = @('open', 'kind')                        # optional print order
#     ContextMenu = @( @{ Label = 'Open'; Test = { param($rec) ... }
#                         Invoke = { param($rec) ... } } )     # right-click items
#     PanelKeys   = @( @{ Key = 'O'; Ctrl = $true; Label = 'open'; Hint = 'Open'
#                          Test = { param($rec) ... }; Invoke = { param($rec) ... } } )
#     TypeGlyph   = { param($payload) [string][char]0xE71B }  # row icon, first plugin wins
#     Settings    = [ordered]@{ Browser = @{ Kind = 'string'; Default = ''; Desc = '...' } }
#     ThemeSettings = [ordered]@{ StarColor = @{ Kind = 'color'; Default = '#FFC86E' } }
#     Tick        = @{ Seconds = 60; Action = { param($now) ... } }           # resident loop
#     Transform   = { param($payload) ... }       # rewrite what gets pasted
#     RowDecor    = { param($record) @{ Marks = @( @{ Glyph = '..'; Color = '#..' } ) } }
#     Marks       = [ordered]@{ x = @{ Set = 'on'; Unset = 'off'; Word = 'marked'
#                                      Hint = 'Ctrl+X'; Protected = $false } }
#     SortMark    = 'x'                          # rows with this mark float to the top
#     ClearKeeps  = @('x')                       # marks `clear` keeps (array or scriptblock)
#     Init        = { ... }                       # once per process, after settings are read
#   }
#
# The base never learns what a mark means: it stores one character per mark in the record
# flags and asks this layer for the rules (protected / sorts first / kept on clear) and
# for the word to print. That is why adding a mark needs no change in clipboard.ps1.
#
# Two kinds of knobs, deliberately kept apart:
#   Settings      -> clipboard.ini keys named <plugin>.<Key>, the user's switches
#   ThemeSettings -> NOT ini keys at all: look-and-feel defaults a theme may restyle through
#                    a section named after the plugin in themes\*.ini (e.g. [item-marks])
# Read them with Get-PluginSetting (user) and Get-PluginTheme (theme-aware).
#
# SETTINGS: a plugin may declare zero or more keys. They join the same schema as the base
# keys, namespaced <plugin>.<Key> (e.g. my-thing.Browser), so `clipboard config`,
# `config get`, `config set` and `config init` handle them with no extra plumbing.
# Read one from inside a plugin with:
#
#   Get-PluginSetting 'my-thing' 'Browser'
#
# Kind / Min / Max / Options / Default follow the base schema (bool, int, enum, regex,
# hotkey, list, string). A duplicate key is ignored and logged.
#
# OPT-IN: nothing here runs unless clipboard.ini names the plugin, e.g.
#
#   Plugins=my-thing
#
# Plugins= lists file names without the .ps1 extension, separated by , or ; and matched
# case-insensitively. An empty list (the default) means "base tool only": no plugin file
# is even executed. A name that matches no file is reported as missing.
#
# Scriptblocks must be SELF-CONTAINED. They may call base commands (Get-Records,
# Get-EntryKind, Write-Log, Format-Item ...) but must not read variables created in the
# plugin file's own scope: that scope is gone by the time the block runs, so a captured
# variable is $null and the call fails. Share a helper by giving it its own key and
# fetching it with Get-PluginData '<plugin>' '<key>'.
#
# TypeGlyph is a scriptblock, not a table: only the plugin knows how it types an entry.
#
# The base tool works with an empty or missing plugins folder: every helper below
# degrades to the built-in behaviour.
$script:PluginMissing = @()
$script:PluginSettings = @{}     # plugin name -> ordered { '<plugin>.<Key>' -> schema spec }
$script:PluginValues = @{}       # '<plugin>.<Key>' -> effective value
$script:PluginThemeSpec = @{}    # plugin name -> ordered { Key -> spec }  (theme restyleable)
$script:PluginThemeValues = @{}  # '<plugin>.<Key>' -> effective value
$script:PluginTimers = @{}       # 'tick:<plugin>' -> last run (epoch seconds)
$script:PluginInitDone = $false

# Only = the allow-list from Plugins=. Nothing is executed for files that are not listed.
function Load-Plugins([string]$Dir, [string[]]$Only) {
  $out = New-Object System.Collections.Generic.List[object]
  $script:PluginMissing = @()
  $want = @(@($Only) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
  if ($want.Count -eq 0) { return $out.ToArray() }
  if (-not $Dir) { $script:PluginMissing = $want; return $out.ToArray() }
  try { if (-not (Test-Path -LiteralPath $Dir)) { $script:PluginMissing = $want; return $out.ToArray() } } catch { return $out.ToArray() }
  $files = @()
  try {
    $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.ps1' -File -ErrorAction Stop | Sort-Object Name)
  } catch {
    Write-Log ('plugins folder not readable: ' + $_.Exception.Message)
    return $out.ToArray()
  }
  $present = @{}
  foreach ($f in $files) { $present[$f.BaseName.ToLower()] = $f }
  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($w in $want) { if (-not $present.ContainsKey($w.ToLower())) { $missing.Add($w) } }
  $script:PluginMissing = $missing.ToArray()
  # load order follows the Plugins= list, not the file name: it decides which plugin wins
  # a shared hook (TypeGlyph / Transform) and in which order the menu groups appear
  $done = @{}
  foreach ($w in $want) {
    $key = $w.ToLower()
    if ($done.ContainsKey($key)) { continue }
    $done[$key] = $true
    if (-not $present.ContainsKey($key)) { continue }
    $f = $present[$key]
    try {
      $p = & $f.FullName
      if ($p -is [hashtable] -and $p.ContainsKey('Name')) {
        if (-not [string]::Equals([string]$p['Name'], $f.BaseName, [StringComparison]::OrdinalIgnoreCase)) {
          Write-Log ('plugin name mismatch: ' + $f.Name + ' declares Name=' + [string]$p['Name'])
        }
        $out.Add($p)
        Write-Log ('plugin loaded: ' + [string]$p['Name'])
      } else {
        Write-Log ('plugin ignored (no Name hashtable): ' + $f.Name)
      }
    } catch {
      Write-Log ('plugin failed: ' + $f.Name + ' - ' + $_.Exception.Message)
    }
  }
  return $out.ToArray()
}

# names requested in Plugins= that matched no file (empty when nothing was requested)
function Get-PluginMissingNames {
  return @($script:PluginMissing)
}

function Get-PluginNames {
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($p in @($script:Plugins)) {
    if ($p.ContainsKey('Name')) { $names.Add([string]$p['Name']) }
  }
  return $names.ToArray()
}

# Merge every loaded plugin's Settings block into the shared schema as <plugin>.<Key>.
# Called once after Load-Plugins; a duplicate key never overwrites a base key.
function Register-PluginSettings {
  $map = @{}
  if ($null -eq $script:IniSchema) { $script:PluginSettings = $map; return }
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('Settings')) { continue }
    $spec = $p['Settings']
    if ($spec -isnot [System.Collections.IDictionary]) {
      Write-Log ('plugin settings ignored (not a dictionary): ' + [string]$p['Name'])
      continue
    }
    $name = [string]$p['Name']
    $own = [ordered]@{}
    foreach ($k in @($spec.Keys)) {
      $full = $name + '.' + [string]$k
      $s = $spec[$k]
      if ($s -isnot [System.Collections.IDictionary] -or -not $s.Contains('Kind')) {
        Write-Log ('plugin setting ignored (needs Kind): ' + $full)
        continue
      }
      if ($script:IniSchema.Contains($full)) {
        Write-Log ('plugin setting ignored (duplicate key): ' + $full)
        continue
      }
      $script:IniSchema[$full] = $s
      $own[$full] = $s
    }
    if ($own.Count -gt 0) { $map[$name] = $own }
  }
  $script:PluginSettings = $map
}

# Resolve plugin settings once, after the config file has been read: ini value when valid,
# otherwise the declared default. Rejects are logged so a typo is not silent.
function Apply-PluginSettings {
  $vals = @{}
  $cache = $script:IniCache
  if ($null -eq $cache) { $cache = Read-Ini; $script:IniCache = $cache }
  foreach ($name in @($script:PluginSettings.Keys)) {
    foreach ($full in @($script:PluginSettings[$name].Keys)) {
      $spec = $script:PluginSettings[$name][$full]
      $val = $null
      if ($cache.ContainsKey($full) -and [string]$cache[$full] -ne '') {
        $r = Convert-IniValue $full ([string]$cache[$full])
        if ($r.Ok) { $val = [string]$r.Value }
        else { Write-Log ('plugin setting rejected: ' + $full + ' (' + [string]$cache[$full] + ') ' + $r.Error) }
      }
      if ($null -eq $val -and $spec.Contains('Default')) { $val = [string]$spec['Default'] }
      $vals[$full] = [string]$val
    }
  }
  $script:PluginValues = $vals
}

# Effective value of one plugin setting (clipboard.ini). Safe to call from anywhere.
function Get-PluginSetting([string]$Plugin, [string]$Key) {
  $full = ([string]$Plugin) + '.' + ([string]$Key)
  if ($script:PluginValues -and $script:PluginValues.ContainsKey($full)) { return [string]$script:PluginValues[$full] }
  if ($script:IniSchema -and $script:IniSchema.Contains($full)) {
    try {
      $v = Get-CfgValue $full
      if ($null -ne $v) { return [string]$v }
    } catch { }
    $spec = $script:IniSchema[$full]
    if ($spec.Contains('Default')) { return [string]$spec['Default'] }
  }
  return ''
}

# ------------------------------------------------------- theme restyleable values
# ThemeSettings are NOT ini keys of clipboard.ini. They are look-and-feel defaults that a
# theme may restyle through a section named after the plugin in themes\*.ini:
#
#   [item-marks]
#   StarColor=#FFD700
#
# Validation reuses the same Kind vocabulary (color / int / bool / enum / string).
function Convert-ThemeSettingValue($spec, [string]$raw) {
  $v = ([string]$raw).Trim()
  $kind = 'string'
  if ($spec.Contains('Kind')) { $kind = [string]$spec['Kind'] }
  if ($kind -eq 'color') {
    if (Get-Command Convert-ThemeColor -ErrorAction SilentlyContinue) {
      if ($null -eq (Convert-ThemeColor $v)) { return $null }
    }
    return $v
  }
  if ($kind -eq 'int') {
    $n = 0
    if (-not [int]::TryParse($v, [ref]$n)) { return $null }
    if ($spec.Contains('Min') -and $n -lt [int]$spec['Min']) { return $null }
    if ($spec.Contains('Max') -and $n -gt [int]$spec['Max']) { return $null }
    return [string]$n
  }
  if ($kind -eq 'bool') {
    $l = $v.ToLowerInvariant()
    if (@('1', 'true', 'on', 'yes') -contains $l) { return '1' }
    if (@('0', 'false', 'off', 'no') -contains $l) { return '0' }
    return $null
  }
  if ($kind -eq 'enum') {
    foreach ($o in @($spec['Options'])) { if ([string]$o -eq $v) { return [string]$o } }
    return $null
  }
  return $v
}

# Collect the ThemeSettings blocks of the loaded plugins.
function Register-PluginThemeSettings {
  $map = @{}
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('ThemeSettings')) { continue }
    $spec = $p['ThemeSettings']
    if ($spec -isnot [System.Collections.IDictionary]) {
      Write-Log ('plugin ThemeSettings ignored (not a dictionary): ' + [string]$p['Name'])
      continue
    }
    $name = [string]$p['Name']
    $own = [ordered]@{}
    foreach ($k in @($spec.Keys)) {
      $s = $spec[$k]
      if ($s -isnot [System.Collections.IDictionary] -or -not $s.Contains('Kind')) {
        Write-Log ('plugin ThemeSettings ignored (needs Kind): ' + $name + '.' + $k)
        continue
      }
      $own[[string]$k] = $s
    }
    if ($own.Count -gt 0) { $map[$name] = $own }
  }
  $script:PluginThemeSpec = $map
}

# Effective theme value: the active theme's section wins, then the plugin default.
function Apply-PluginTheme {
  $vals = @{}
  foreach ($name in @($script:PluginThemeSpec.Keys)) {
    foreach ($k in @($script:PluginThemeSpec[$name].Keys)) {
      $key = [string]$k
      $full = $name + '.' + $key
      $spec = $script:PluginThemeSpec[$name][$key]
      $val = $null
      if ($script:ThemeOverrides -and $script:ThemeOverrides.ContainsKey($full)) {
        $val = Convert-ThemeSettingValue $spec ([string]$script:ThemeOverrides[$full])
        if ($null -eq $val) { Write-Log ('theme value ignored: ' + $full + '=' + [string]$script:ThemeOverrides[$full]) }
      }
      if ($null -eq $val) {
        if ($spec.Contains('Default')) { $val = [string]$spec['Default'] } else { $val = '' }
      }
      $vals[$full] = [string]$val
    }
  }
  $script:PluginThemeValues = $vals
}

# Theme-aware value of one plugin look-and-feel key.
function Get-PluginTheme([string]$Plugin, [string]$Key) {
  $full = ([string]$Plugin) + '.' + ([string]$Key)
  if ($script:PluginThemeValues -and $script:PluginThemeValues.ContainsKey($full)) { return [string]$script:PluginThemeValues[$full] }
  if ($script:PluginThemeSpec -and $script:PluginThemeSpec.ContainsKey([string]$Plugin)) {
    $own = $script:PluginThemeSpec[[string]$Plugin]
    if ($own.Contains([string]$Key)) {
      $spec = $own[[string]$Key]
      if ($spec.Contains('Default')) { return [string]$spec['Default'] }
    }
  }
  return ''
}

# first plugin that declares a command wins; $null means "not a plugin command"
function Get-PluginCommand([string]$Name) {
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('Commands')) { continue }
    $cmds = $p['Commands']
    if ($cmds -is [hashtable] -and $cmds.ContainsKey($Name)) { return $cmds[$Name] }
  }
  return $null
}

# Commands grouped per plugin, with the optional `CommandHelp` summary for the help screen:
#   CommandHelp = @{ 'open' = 'open entry N (link, path or file list)' }
# `CommandOrder` (optional) fixes the printed order; the rest follows alphabetically.
function Get-PluginCommandList {
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('Commands')) { continue }
    $cmds = $p['Commands']
    if ($cmds -isnot [hashtable]) { continue }
    $help = @{}
    if ($p.ContainsKey('CommandHelp') -and $p['CommandHelp'] -is [System.Collections.IDictionary]) { $help = $p['CommandHelp'] }
    $names = New-Object System.Collections.Generic.List[string]
    if ($p.ContainsKey('CommandOrder')) {
      foreach ($k in @($p['CommandOrder'])) {
        $k = [string]$k
        if ($cmds.ContainsKey($k) -and -not $names.Contains($k)) { $names.Add($k) }
      }
    }
    foreach ($k in @($cmds.Keys | Sort-Object)) {
      $k = [string]$k
      if (-not $names.Contains($k)) { $names.Add($k) }
    }
    foreach ($k in $names) {
      $sum = ''
      if ($help.Contains($k)) { $sum = [string]$help[$k] }
      $out.Add([pscustomobject]@{ Plugin = [string]$p['Name']; Name = $k; Summary = $sum })
    }
  }
  return $out.ToArray()
}

# ------------------------------------------------------------------ panel keys
# Keys the picker answers to while it has focus: Key is the WinForms Keys name, modifiers
# default to false, Test (optional) hides the key for records it does not apply to. The first
# match wins and a plugin key never shadows a built-in panel key.
function Get-PluginPanelKeys {
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('PanelKeys')) { continue }
    foreach ($k in @($p['PanelKeys'])) {
      if ($k -isnot [hashtable] -or -not $k.Contains('Key') -or -not $k.Contains('Invoke')) { continue }
      $ctrl = $false; $alt = $false; $shift = $false
      if ($k.Contains('Ctrl')) { $ctrl = [bool]$k['Ctrl'] }
      if ($k.Contains('Alt')) { $alt = [bool]$k['Alt'] }
      if ($k.Contains('Shift')) { $shift = [bool]$k['Shift'] }
      $label = ''
      if ($k.Contains('Label')) { $label = [string]$k['Label'] }
      $hint = $label
      if ($k.Contains('Hint')) { $hint = [string]$k['Hint'] }
      $test = $null
      if ($k.Contains('Test')) { $test = $k['Test'] }
      $out.Add([pscustomobject]@{
          Plugin = [string]$p['Name']
          Key    = ([string]$k['Key']).ToUpperInvariant()
          Ctrl   = $ctrl
          Alt    = $alt
          Shift  = $shift
          Label  = $label
          Hint   = $hint
          Invoke = $k['Invoke']
          Test   = $test
        })
    }
  }
  return $out.ToArray()
}

# the panel key that matches one key press, $null when no plugin claims it
function Get-PluginPanelKey([string]$keyName, [bool]$ctrl, [bool]$alt, [bool]$shift) {
  $name = ([string]$keyName).ToUpperInvariant()
  foreach ($k in @(Get-PluginPanelKeys)) {
    if ($k.Key -ne $name) { continue }
    if ([bool]$k.Ctrl -ne $ctrl) { continue }
    if ([bool]$k.Alt -ne $alt) { continue }
    if ([bool]$k.Shift -ne $shift) { continue }
    return $k
  }
  return $null
}

# optional one-time setup, run once per process after settings and theme settings are
# resolved: create a cache folder, warm a lookup, open a log. Never runs twice.
function Invoke-PluginInit {
  if ($script:PluginInitDone) { return }
  $script:PluginInitDone = $true
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('Init')) { continue }
    try { & $p['Init'] } catch { Write-Log ('plugin init failed: ' + [string]$p['Name'] + ' - ' + $_.Exception.Message) }
  }
}

# A plugin may share a helper between its own scriptblocks: the value is looked up by plugin
# name, because scriptblocks cannot see the hashtable they came from.
function Get-PluginData([string]$Plugin, [string]$Key) {
  foreach ($p in @($script:Plugins)) {
    if (-not [string]::Equals([string]$p['Name'], $Plugin, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if ($p.ContainsKey($Key)) { return $p[$Key] }
  }
  return $null
}

# Mark registry. A mark is one character in the record flags; the plugin that declares it
# owns its meaning, so the base can store, sort, protect and describe marks it has never
# heard of. Declaration shape inside a plugin hash table:
#
#   Marks = [ordered]@{
#     p = @{ Set = 'pin'; Unset = 'unpin'; Word = 'pinned'; Hint = 'Ctrl+P'; Protected = $false }
#   }
#   SortMark   = 'p'                 # rows with this mark float to the top
#   ClearKeeps = @('p')              # marks `clear` keeps by default (array or scriptblock)
#
# $true Protected means the base refuses to trim, clear or delete such a row: only the
# verb named in Unset may remove the mark first.

# mark -> @{ Mark; Set; Unset; Word; Hint; Protected; Plugin }; the first declaration wins
function Get-PluginMarks {
  $out = [ordered]@{}
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('Marks')) { continue }
    $decl = $p['Marks']
    if ($decl -isnot [System.Collections.IDictionary]) { continue }
    foreach ($k in @($decl.Keys)) {
      $m = [string]$k
      if ($m.Length -ne 1 -or $out.Contains($m)) { continue }
      $spec = $decl[$k]
      if ($spec -isnot [System.Collections.IDictionary]) { continue }
      $out[$m] = @{
        Mark      = $m
        Set       = [string]$spec['Set']
        Unset     = [string]$spec['Unset']
        Word      = [string]$spec['Word']
        Hint      = [string]$spec['Hint']
        Protected = [bool]$spec['Protected']
        Plugin    = [string]$p['Name']
      }
    }
  }
  return $out
}

function Get-PluginMarkNames {
  $all = Get-PluginMarks
  return @($all.Keys)
}

function Get-PluginMarkInfo([string]$mark) {
  if (-not $mark) { return $null }
  $all = Get-PluginMarks
  if ($all.Contains($mark)) { return $all[$mark] }
  return $null
}

function Get-PluginProtectedMarks {
  $all = Get-PluginMarks
  $out = @()
  foreach ($k in @($all.Keys)) { if ($all[$k].Protected) { $out += [string]$k } }
  return $out
}

# the mark whose rows sort first; ignored when the mark is not declared
function Get-PluginSortMark {
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('SortMark')) { continue }
    $m = [string]$p['SortMark']
    if ($m -and (Get-PluginMarkInfo $m)) { return $m }
  }
  return ''
}

# marks `clear` keeps without -All
function Get-PluginClearKeeps {
  $out = @()
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('ClearKeeps')) { continue }
    $v = $p['ClearKeeps']
    try { if ($v -is [scriptblock]) { $v = & $v } } catch {
      Write-Log ('plugin clear policy failed (' + [string]$p['Name'] + '): ' + $_.Exception.Message)
      continue
    }
    foreach ($m in @($v)) {
      $s = [string]$m
      if ($s -and ($out -notcontains $s)) { $out += $s }
    }
  }
  return $out
}

# flattened context menu actions contributed by every plugin, in load order
# Each entry carries the owning plugin name, so the menu can keep one plugin's items
# together and draw a separator between groups instead of one flat list.
function Get-PluginActions {
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('ContextMenu')) { continue }
    foreach ($a in @($p['ContextMenu'])) {
      if ($a -isnot [hashtable] -or -not $a.ContainsKey('Label') -or -not $a.ContainsKey('Invoke')) { continue }
      $copy = @{}
      foreach ($k in @($a.Keys)) { $copy[$k] = $a[$k] }
      if (-not $copy.ContainsKey('Plugin')) { $copy['Plugin'] = [string]$p['Name'] }
      $out.Add($copy)
    }
  }
  return $out.ToArray()
}

# Row icon: only a plugin paints one. TypeGlyph receives the payload and returns a glyph
# (or nothing), so the typing rule stays inside the plugin that owns it.
function Get-EntryGlyph([string]$payload) {
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('TypeGlyph')) { continue }
    try {
      $g = & $p['TypeGlyph'] $payload
      if ($g) { return [string]$g }
    } catch { }
  }
  return ''
}

function Test-PluginAction($action, $record) {
  if ($action -isnot [hashtable]) { return $false }
  if (-not $action.ContainsKey('Test')) { return $true }
  try { return [bool](& $action['Test'] $record) } catch { return $false }
}

# ---------------------------------------------------------------- lifecycle hooks
# Tick: a plugin may ask to be called while the resident runs. Seconds is the minimum gap
# and may be a scriptblock, so a plugin can derive it from its own setting without keeping
# state; the base timer checks every poll and remembers the last run per plugin.
function Get-PluginTicks {
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('Tick')) { continue }
    $t = $p['Tick']
    if ($t -isnot [hashtable] -or -not $t.ContainsKey('Action')) { continue }
    $sec = 60
    if ($t.ContainsKey('Seconds')) {
      $v = $t['Seconds']
      if ($v -is [scriptblock]) { try { $v = & $v } catch { $v = 60 } }
      $sec = 0
      if (-not [int]::TryParse([string]$v, [ref]$sec)) { $sec = 60 }
    }
    if ($sec -lt 1) { $sec = 1 }
    $out.Add(@{ Name = [string]$p['Name']; Seconds = $sec; Action = $t['Action'] })
  }
  return $out.ToArray()
}

# Called from the resident timer. Never throws: a failing plugin is logged and throttled.
function Invoke-PluginTicks {
  foreach ($t in @(Get-PluginTicks)) {
    $key = 'tick:' + [string]$t['Name']
    $last = 0L
    if ($script:PluginTimers.ContainsKey($key)) { $last = [long]$script:PluginTimers[$key] }
    $now = [DateTime]::UtcNow.Ticks / 10000000
    if (($now - $last) -lt [int]$t['Seconds']) { continue }
    $script:PluginTimers[$key] = $now
    try { & $t['Action'] $now } catch {
      Write-Log ('plugin tick failed (' + [string]$t['Name'] + '): ' + $_.Exception.Message)
    }
  }
}

# Transform: first plugin that declares one decides how the payload is pasted.
# $null or an empty string means "leave it alone".
function Invoke-PluginTransform([string]$payload) {
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('Transform')) { continue }
    try {
      $v = & $p['Transform'] $payload
      if ($null -ne $v -and [string]$v -ne '') { return [string]$v }
      return $payload
    } catch {
      Write-Log ('plugin transform failed (' + [string]$p['Name'] + '): ' + $_.Exception.Message)
      return $payload
    }
  }
  return $payload
}

# Row decor: everything a plugin wants painted on a row. The base only knows slots and
# colours, so a plugin styles rows without the base knowing why.
# Returns @{ Glyph; GlyphColor; Marks = @(@{ Glyph; Color }, ...); TextColor; BackColor }.
function Get-PluginRowDecor($record) {
  $d = @{ Glyph = ''; GlyphColor = ''; Marks = @(); TextColor = ''; BackColor = '' }
  if ($null -eq $record) { return $d }
  $marks = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('RowDecor')) { continue }
    try {
      $r = & $p['RowDecor'] $record
      if ($r -isnot [hashtable]) { continue }
      foreach ($k in @('Glyph', 'GlyphColor', 'TextColor', 'BackColor')) {
        if ($r.ContainsKey($k) -and $r[$k] -and -not $d[$k]) { $d[$k] = [string]$r[$k] }
      }
      foreach ($mk in @($r['Marks'])) {
        if ($mk -isnot [hashtable]) { continue }
        $g = [string]$mk['Glyph']
        if (-not $g) { continue }
        $marks.Add(@{ Glyph = $g; Color = [string]$mk['Color'] })
      }
    } catch {
      Write-Log ('plugin row decor failed (' + [string]$p['Name'] + '): ' + $_.Exception.Message)
    }
  }
  $d.Marks = $marks.ToArray()
  return $d
}


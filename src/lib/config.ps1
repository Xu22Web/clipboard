# lib/config.ps1 - the settings surface: apply clipboard.ini to the defaults, print the
# effective values, validate and write one key at a time.
#
# The keys are described by schema/clipboard.ps1, and three layers under it do the work:
# utils/ini.ps1 parses text into a document, utils/import.ps1 reads a file once per change
# and rewrites a single line, utils/schema.ps1 validates a value against the schema. Nothing
# here invents a key: a key the schema does not describe is reported as unknown, which is
# what keeps `config`, `config get` and `config set` consistent with each other.

$script:SettingsSchema = Import-Schema (Join-Path $Root 'schema\clipboard.ps1')
$script:IniSchema = Get-SchemaProperties $script:SettingsSchema
if ($null -eq $script:IniSchema) { $script:IniSchema = [ordered]@{} }


# clipboard.ini, the settings file beside the entry point: one document per file version,
# imported once and re-read only when the file changes on disk
function Read-Ini {
  return (Import-Ini $IniPath).Map
}

# the raw value of one key, "" when the file does not set it
function Get-IniKey([string]$key) {
  return (Import-IniValue $IniPath $key)
}

# validate one raw value against the settings schema
function Convert-IniValue([string]$key, [string]$raw) {
  return (Convert-SchemaValue $script:SettingsSchema $key $raw)
}

# effective value of one key coming from clipboard.ini (null when unset or invalid)
function Get-CfgValue([string]$key) {
  $c = Read-Ini
  if (-not $c.ContainsKey($key)) { return $null }
  $raw = [string]$c[$key]
  if ($raw -eq '') { return $null }
  $r = Convert-IniValue $key $raw
  if (-not $r.Ok) { Write-Log ('config ignored: ' + $key + '=' + $raw + ' (' + $r.Error + ')'); return $null }
  return [string]$r.Value
}

# write exactly one key: the importer keeps the comments and every other line, and drops
# its cached parse so the next read sees the new text
function Set-IniKey([string]$key, [string]$value) {
  try {
    [void](Export-IniValue $IniPath $key $value)
    return $true
  } catch {
    Write-Log ('ini write failed: ' + $_.Exception.Message)
    return $false
  }
}

function Apply-Config {
  param([switch]$NoColors)
  # One pass over the schema: reset every variable it points at to the declared default, then
  # let clipboard.ini override it. Settings never come from the command line, and a reload
  # therefore starts from the same numbers the file is documented with.
  #
  # The file is imported once for the whole pass: every key is read from that map instead of
  # running its own cache check, which is what kept this loop from being one page fault per
  # setting.
  $map = Read-Ini
  foreach ($key in @($script:IniSchema.Keys)) {
    $spec = $script:IniSchema[$key]
    if (-not $spec.Contains('Ref')) { continue }
    $slot = $spec['Ref']
    $type = [string]$spec['Type']
    # the schema keeps defaults in their file spelling (1/0, plain numbers); the variables
    # hold the type the code expects
    $def = $spec['Default']
    if ($type -eq 'bool') { $def = ([int]$def -ne 0) }
    elseif ($type -eq 'int' -and [string]$def -ne '') { $def = [int]$def }
    $slot.Value = $def
    $raw = ''
    if ($map.ContainsKey($key)) { $raw = ([string]$map[$key]).Trim() }
    if ($raw -eq '') { continue }
    $r = Convert-IniValue $key $raw
    if (-not $r.Ok) {
      Write-Log ('config ignored: ' + $key + '=' + $raw + ' (' + $r.Error + ')')
      continue
    }
    if ($type -eq 'bool') { $slot.Value = ($r.Value -eq '1') }
    elseif ($type -eq 'int') { $slot.Value = [int]$r.Value }
    else { $slot.Value = $r.Value }
  }
  # Plugins= is a list with a fallback: an empty value means every plugin on disk
  $v = Get-CfgValue 'Plugins'
  $script:PluginList = @()
  if ($null -ne $v -and ([string]$v).Trim() -ne '') {
    $script:PluginList = @($v -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  } elseif (Get-Command Get-AllPluginNames -ErrorAction SilentlyContinue) {
    # No Plugins= in the file yet: start from every plugin on disk, spelled out by name.
    # A store without a plugins folder simply loads nothing.
    try { $script:PluginList = @(Get-AllPluginNames (Join-Path $Root 'plugins')) } catch { $script:PluginList = @() }
  }
  # plugin settings are read from the same file, so they follow every reload
  if ($script:PluginSettings -and $script:PluginSettings.Count -gt 0 -and (Get-Command Apply-PluginSettings -ErrorAction SilentlyContinue)) {
    Apply-PluginSettings
  }
  if ($script:PluginThemeSpec -and $script:PluginThemeSpec.Count -gt 0 -and (Get-Command Apply-PluginTheme -ErrorAction SilentlyContinue)) {
    Apply-PluginTheme
  }
  # resolves the palette / fonts / metric overrides for the selected theme
  Apply-Theme -SkipColors:$NoColors
}

# effective values of every key, in schema order
function Get-ConfigReport {
  $r = [ordered]@{
    DataDir           = $(if ($dataRoot) { [string]$dataRoot } else { '' })
    Hotkey            = [string]$script:Hotkey
    HotkeyFallbacks   = [string]$script:HotkeyFallbacks
    PasteKeys         = [string]$script:PasteKeys
    ModReleaseTimeout = [string]$script:ModReleaseTimeout
    PasteSettle       = [string]$script:PasteSettle
    MaxItems          = [string]$MaxItems
    MaxBytes          = [string]$MaxBytes
    MaxTotal          = [string]$MaxTotal
    MaxMediaTotal     = [string]$script:MaxMediaTotal
    CaptureImages     = [string][int][bool]$script:CaptureImages
    MaxImageBytes     = [string]$script:MaxImageBytes
    CaptureRich       = [string][int][bool]$script:CaptureRich
    MaxRichBytes      = [string]$script:MaxRichBytes
    PasteRich         = [string][int][bool]$script:PasteRich
    Interval          = [string]$Interval
    NoPaste           = [string][int][bool]$script:NoPaste
    Balloon           = [string][int][bool]$script:ShowBalloon
    Theme             = [string]$script:Theme
    ExcludePattern    = [string]$script:ExcludePattern
    WindowWidth       = [string]$script:WinWidth
    Rows              = [string]$script:Rows
    WindowLeft        = [string]$script:WinLeft
    WindowTop         = [string]$script:WinTop
    SaveWindowWidth   = [string][int][bool]$script:SaveWinWidth
    SaveWindowPos     = [string][int][bool]$script:SaveWinPos
    ShowTime          = [string][int][bool]$script:ShowTime
    ShowTypeIcon      = [string][int][bool]$script:ShowTypeIcon
    Highlight         = [string][int][bool]$script:HighlightOn
    HighlightMaxBytes = [string]$script:HighlightMax
    ShowNewlineMarker = [string][int][bool]$script:ShowNewlineMarker
    PreviewHover      = [string][int][bool]$script:PreviewHover
    PreviewDelay      = [string]$script:PreviewDelay
    PreviewChars      = [string]$script:PreviewChars
    BlobThreshold     = [string]$script:BlobChars
    Undo              = [string][int][bool]$script:UndoOn
    DpiAware          = [string][int][bool]$script:DpiAware
    ScrollLines       = [string]$script:ScrollLines
    Animations        = [string][int][bool]$script:Animations
    Autostart         = [string][int][bool]$script:Autostart
    DesktopShortcut   = [string][int][bool]$script:DesktopShortcut
    Plugins           = (@($script:PluginList) -join ',')
  }
  # Plugin settings are not in the fixed table above: they exist only while the plugin is
  # loaded, so they are appended from the live registry.
  if ($script:PluginSettings -and (Get-Command Get-PluginSetting -ErrorAction SilentlyContinue)) {
    foreach ($name in @($script:PluginSettings.Keys)) {
      foreach ($full in @($script:PluginSettings[$name].Keys)) {
        $r[$full] = [string](Get-PluginSetting $name $full.Substring($name.Length + 1))
      }
    }
  }
  # theme-declared knobs are deliberately NOT exposed as ini keys: the settings file only
  # picks a theme by name, a theme is a package rather than a pile of colour knobs
  return $r
}

# Every value that came out of clipboard.ini, checked against the schema. The loaders fall
# back to a default when a value is unusable, which keeps the panel and the CLI working but
# makes a typo invisible - this is the one place that says so. It runs after the settings and
# the plugins have registered their keys (see lib/dispatch.ps1), so a plugin key is not
# mistaken for an unknown one, and it covers the three fixed value sets: the base keys, the
# theme name and the values a list setting allows.
function Get-ConfigProblems {
  $cache = Import-Ini $IniPath
  # the schema checks every key and value it knows; the theme name is the one cross-file
  # rule it cannot know about, so it stays here
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($p in @(Test-SchemaDoc $script:SettingsSchema $cache)) { $out.Add($p) }
  $raw = Get-IniDocValue $cache 'Theme'
  if ($raw -ne '' -and (Get-Command Get-ThemeNames -ErrorAction SilentlyContinue)) {
    $themes = @()
    try { $themes = @(Get-ThemeNames) } catch { }
    if ($themes.Count -gt 0 -and ($themes -notcontains $raw)) {
      $out.Add('Theme=' + $raw + '  (no such theme file; have: ' + ($themes -join ', ') + ')')
    }
  }
  return $out.ToArray()
}

function Show-Config {
  # read only: this never creates or rewrites clipboard.ini
  $exists = Test-Path -LiteralPath $IniPath
  Write-Host ('config file : ' + $IniPath + $(if ($exists) { '' } else { '   (missing, built-in defaults apply)' }))
  if (@($script:ConfigProblems).Count -gt 0) {
    Write-Host ''
    Write-Host ('[!] ' + @($script:ConfigProblems).Count + ' value(s) in this file need attention:')
    foreach ($p in @($script:ConfigProblems)) { Write-Host ('    ' + $p) }
    Write-Host ''
  }
  Write-Host ('data dir    : ' + $StoreDir + $(if ($dataRoot) { '   (from clipboard.ini)' } else { '   (default)' }))
  Write-Host ''
  $ini = Read-Ini
  $vals = Get-ConfigReport

  # split the report into the base keys and the per-plugin settings, so each plugin's
  # registered keys are printed as their own group instead of a flat tail
  $baseKeys = New-Object System.Collections.Generic.List[string]
  $groups = @{}
  $order = New-Object System.Collections.Generic.List[string]
  foreach ($k in @($vals.Keys)) {
    if ($k -match '^([A-Za-z0-9_-]+)\.[A-Za-z0-9_.-]+$') {
      $pname = $Matches[1]
      if (-not $groups.ContainsKey($pname)) {
        $groups[$pname] = New-Object System.Collections.Generic.List[string]
        $order.Add($pname)
      }
      $groups[$pname].Add([string]$k)
    } else {
      $baseKeys.Add([string]$k)
    }
  }

  $srcOf = {
    param([string]$key)
    if ($ini.ContainsKey($key) -and $ini[$key] -ne '') { return '   <- ini' }
    return '   <- default'
  }

  Write-Host '  [base]'
  foreach ($k in $baseKeys) {
    $name = $k
    while ($name.Length -lt 20) { $name = $name + ' ' }
    $show = [string]$vals[$k]
    if ($k -eq 'DataDir' -and $show -eq '') { $show = '(script dir)\data' }
    if ($k -eq 'HotkeyFallbacks' -and $show -eq '') { $show = '(built-in chain)' }
    if ($k -eq 'ExcludePattern' -and $show -eq '') { $show = '(none)' }
    if ($k -eq 'Plugins' -and $show -eq '') { $show = '(none)' }
    Write-Host ('    ' + $name + ' = ' + $show + (& $srcOf $k))
  }

  $loaded = @()
  if (Get-Command Get-PluginNames -ErrorAction SilentlyContinue) { $loaded = @(Get-PluginNames) }
  foreach ($pname in $loaded) {
    Write-Host ''
    Write-Host ('  [plugin: ' + $pname + ']')
    $keys = $null
    if ($groups.ContainsKey($pname)) { $keys = $groups[$pname] }
    if ($null -eq $keys -or $keys.Count -eq 0) { Write-Host '    (no settings)'; continue }
    foreach ($k in $keys) {
      $name = $k.Substring($pname.Length + 1)
      while ($name.Length -lt 20) { $name = $name + ' ' }
      Write-Host ('    ' + $name + ' = ' + [string]$vals[$k] + (& $srcOf $k))
    }
  }
  foreach ($n in @($script:PluginList)) {
    if ($loaded -notcontains $n) {
      Write-Host ''
      Write-Host ('  [plugin: ' + $n + ']')
      Write-Host '    [!] not found (see README.md)'
    }
  }

  Write-Host ''
  if ($script:Plugins.Count -gt 0) {
    Write-Host ('plugins     : loaded ' + (@($script:Plugins | ForEach-Object { $_['Name'] }) -join ', '))
  } elseif (@($script:PluginList).Count -gt 0) {
    Write-Host ('plugins     : [!] not found: ' + (@($script:PluginList) -join ',') + '   (see README.md)')
  } else {
    Write-Host 'plugins     : none (no plugin file found in plugins\)'
  }
  Write-Host ''
  Write-Host 'clipboard config get <key>            one value (effective + raw ini value)'
  Write-Host 'clipboard config set <key> <value>    validate and write one key'
  Write-Host 'clipboard config edit                 open clipboard.ini in notepad'
  Write-Host 'clipboard config init                 write a full template with all defaults'
}

# `config get <key>`
function Show-ConfigKey([string]$key) {
  if (-not $script:IniSchema.Contains($key)) {
    Write-Host ('unknown key: ' + $key)
    if ($key -match '^([^.]+)\.') { Write-Host ('   if this is a plugin setting, list the plugin first: Plugins=' + $Matches[1]) }
    Write-Host ('known keys: ' + (@($script:IniSchema.Keys) -join ', '))
    return $false
  }
  $vals = Get-ConfigReport
  $raw = Get-IniKey $key
  Write-Host ($key + ' = ' + [string]$vals[$key] + $(if ($raw -ne '') { '   (ini: ' + $raw + ')' } else { '   (ini: not set)' }))
  return $true
}

# `config set <key> <value>`
function Set-ConfigKey([string]$key, [string]$value) {
  if (-not $script:IniSchema.Contains($key)) {
    Write-Host ('[x] unknown key: ' + $key)
    if ($key -match '^([^.]+)\.') { Write-Host ('    if this is a plugin setting, list the plugin first: Plugins=' + $Matches[1]) }
    Write-Host ('    known keys: ' + (@($script:IniSchema.Keys) -join ', '))
    return $false
  }
  if ($key -eq 'DataDir') {
    Write-Host '[x] DataDir cannot be changed here: it decides where the history lives.'
    Write-Host '    edit clipboard.ini directly and move data\history.dat yourself.'
    return $false
  }
  $r = Convert-IniValue $key $value
  if (-not $r.Ok) {
    Write-Host ('[x] ' + $key + '=' + $value + ': ' + $r.Error)
    return $false
  }
  # One cross-key rule, checked here because this is the only writer: the sticky pins may
  # never take the whole visible area, or a search would show pins and nothing else. Asking
  # for more than Rows leaves is refused, and shrinking Rows pulls an existing cap down
  # instead of leaving a value behind that could never take effect.
  $stickyKey = 'item-marks.StickyRows'
  if ($script:IniSchema.Contains($stickyKey)) {
    if ($key -eq $stickyKey -and [int]$r.Value -gt 0) {
      $cap = Get-StickyRowCap ([int](Get-ConfigReport)['Rows'])
      if ([int]$r.Value -gt $cap) {
        Write-Host ('[x] ' + $key + '=' + $value + ': at most ' + $cap + ', because Rows leaves one row for the results')
        Write-Host '    raise Rows first, or use 0 for "as many as fit"'
        return $false
      }
    }
    if ($key -eq 'Rows') {
      $cap = Get-StickyRowCap ([int]$r.Value)
      $sticky = 0
      if (Get-Command Get-PluginSetting -ErrorAction SilentlyContinue) {
        $sticky = [int](Get-PluginSetting 'item-marks' 'StickyRows')
      }
      if ($sticky -gt 0 -and $sticky -gt $cap) {
        if (Set-IniKey $stickyKey ([string]$cap)) {
          Write-Host ('[i] ' + $stickyKey + ' lowered to ' + $cap + ' so a row stays for the results')
        }
      }
    }
  }
  $vals = Get-ConfigReport
  $old = [string]$vals[$key]
  if (-not (Set-IniKey $key ([string]$r.Value))) {
    Write-Host ('[x] could not write ' + $IniPath)
    return $false
  }
  Apply-Config
  $vals = Get-ConfigReport
  Write-Host ('[ok] ' + $key + ': ' + $old + ' -> ' + [string]$vals[$key])
  Write-Host ('     ' + $IniPath)
  return $true
}
# restart the resident so new settings take effect without a manual stop/start
function Restart-ResidentIfRunning {
  $alive = $false
  try {
    $m = New-Object System.Threading.Mutex($false, $MutexName)
    if ($m.WaitOne(0)) { $m.ReleaseMutex() } else { $alive = $true }
    $m.Dispose()
  } catch { }
  if (-not $alive) { Write-Host '     resident is not running, nothing to reload'; return }
  try {
    $se = [System.Threading.EventWaitHandle]::OpenExisting($StopName)
    [void]$se.Set()
  } catch { }
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 150
    $free = $true
    try {
      $m = New-Object System.Threading.Mutex($false, $MutexName)
      if ($m.WaitOne(0)) { $m.ReleaseMutex() } else { $free = $false }
      $m.Dispose()
    } catch { }
    if ($free) { break }
  }
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', (Join-Path $Root 'clipboard.ps1'), 'serve')
  Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argList
  Write-Host '     resident restarted to pick up the new settings'
}


# every line of a fresh clipboard.ini, comments included. Shared by `config init` (which
# only fills gaps) and `config reset` (which replaces the file), so the two can never drift.
function Get-IniTemplateLines {
  $t = @(
    '# clipboard.ini - key=value lines, and one [section] per plugin.',
    '# Restart the daemon after editing (clipboard stop, clipboard serve), or use config set.',
    '# Every key below can also be written with:',
    '#   clipboard config set <key> <value>        (plugin keys: config set <plugin>.<Key> <value>)',
    '# write location, empty = <script dir>\data. relative paths resolve against the script dir.',
    'DataDir=',
    '# Hotkey: key may be A-Z 0-9 F1-F24 Insert Delete Home End PgUp PgDn Space.',
    '# Default is Ctrl+Alt+V. Win+V would be nicer but Windows reserves it on most builds',
    '# (RegisterHotKey fails); the tool then falls back to Alt+` / Win+Shift+V by itself.',
    'Hotkey=Ctrl+Alt+V',
    '# comma separated list tried in order when Hotkey is taken. empty = built-in chain:',
    '# Ctrl+Alt+V, Win+V, Alt+`, Win+Shift+V',
    'HotkeyFallbacks=',
    '# ^v = Ctrl+V | ^+v = Ctrl+Shift+V (terminal) | +{INS} = Shift+Insert (mintty)',
    'PasteKeys=^v',
    '# ms to wait for the modifiers to be released before injecting the paste',
    'ModReleaseTimeout=1200',
    '# ms to wait after focusing the previous window before sending PasteKeys',
    'PasteSettle=80',
    '# entry cap; pinned entries are never trimmed away',
    'MaxItems=300',
    'MaxBytes=204800',
    '# total store size cap in bytes; oldest entries are dropped beyond it',
    'MaxTotal=4194304',
    '# size budget for images and the html / rtf sidecars, in bytes (0 = unlimited).',
    '# it is counted apart from MaxTotal, so a screenshot cannot evict every text row',
    'MaxMediaTotal=67108864',
    '# 1 = capture pictures (a Word selection carries text, so it stays a formatted entry)',
    'CaptureImages=1',
    '# per image cap in bytes; larger pictures are logged and skipped',
    'MaxImageBytes=8388608',
    '# 1 = remember the html / rtf of formatted text so it can be pasted back',
    'CaptureRich=1',
    '# html + rtf cap; larger formatted text is kept as plain text only',
    'MaxRichBytes=524288',
    '# 1 = paste the formatting back, 0 = always paste plain text',
    'PasteRich=1',
    '# payloads above this many characters are kept in data\blobs instead of this file,',
    '# 0 = always inline (one self-contained history.dat)',
    'BlobThreshold=32768',
    '# clipboard poll interval in ms',
    'Interval=300',
    '# 1 = clipboard only, never inject a paste',
    'NoPaste=0',
    '# 1 = tray balloon on startup',
    'Balloon=1',
    '# the theme is a file name in themes\ (win11-dark.ini, win11-light.ini, ...)',
    '# win11-dark is the default; an unknown name falls back to it',
    'Theme=win11-dark',
    '# regex: matching clipboard text is never saved',
    'ExcludePattern=',
    '',
    '# ---- panel geometry (96 dpi baseline, scaled by the system DPI) ----',
    '# width only: the height is derived from Rows and is never set directly',
    'WindowWidth=700',
    '# visible rows; the panel is Rows x 40 + 110 tall and always shows whole rows',
    'Rows=10',
    '# empty = centre the panel on the monitor of the window you came from',
    'WindowLeft=',
    'WindowTop=',
    '# 1 = remember the width you dragged / the position you moved it to',
    'SaveWindowWidth=0',
    'SaveWindowPos=0',
    '',
    '# ---- panel behaviour ----',
    '# 1 = relative time column (now / 5m / 3h / 2d / 10-24)',
    'ShowTime=1',
    '# 1 = show the row icon a plugin provides (there is none without one)',
    'ShowTypeIcon=1',
    '# 1 = highlight the search matches',
    'Highlight=1',
    '# skip the highlight above this payload size in bytes, 0 = always highlight',
    'HighlightMaxBytes=8192',
    '# 1 = show <NL> for line breaks, 0 = collapse them into a single space',
    'ShowNewlineMarker=1',
    '# 1 = hover a row to preview its text beside the panel, 0 = no card at all',
    'PreviewHover=1',
    '# ms the cursor has to rest on a row before the card appears',
    'PreviewDelay=350',
    '# characters of an entry the card reads and shows (the rest is elided)',
    'PreviewChars=6000',
    '# wheel step in rows, 0 = follow the system setting',
    'ScrollLines=0',
    '# 1 = fade / grow transitions on hover, selection, scrollbar and search field, 0 = instant',
    'Animations=1',
    '# 1 = per-monitor DPI aware rendering, 0 = legacy rendering',
    'DpiAware=1',
    '',
    '# ---- history ----',
    '# entry cap, 0 = unlimited',
    'MaxItems=300',
    '# 1 = Ctrl+Z in the panel restores the last deleted entry',
    'Undo=1',
    '',
    '# ---- install ----',
    '# 1 = install creates the logon shortcut that runs serve',
    'Autostart=1',
    '# 1 = install creates the desktop shortcut that runs ui',
    'DesktopShortcut=1',
    '',
    '# ---- plugins (see README.md) ----',
    '# names to load, in load order; the default lists every plugin on disk',
    '# e.g. Plugins=item-marks,entry-actions',
    # the whole expression needs its own parentheses: inside an array literal a bare
    # `-join ','` turns the comma into an element separator and the line comes out empty
    ('Plugins=' + (@($script:PluginList) -join ','))
  )
  # Settings declared by every plugin file on disk, loaded or not: the template documents
  # what exists, while help / the plugin commands / the panel follow the resolved Plugins=.
  # A plugin's keys are written as a section of its own - [item-marks] + MaxPins=50 - which
  # is the same key as item-marks.MaxPins=50 for every reader.
  $pset = $null
  if (Get-Command Get-AllPluginSettings -ErrorAction SilentlyContinue) {
    $pset = Get-AllPluginSettings (Join-Path $Root 'schema\plugins')
  }
  if ($null -eq $pset -or $pset.Count -eq 0) { $pset = $script:PluginSettings }
  if ($null -eq $pset) { $pset = @{} }
  $extra = New-Object System.Collections.Generic.List[string]
  foreach ($pname in @($pset.Keys)) {
    $extra.Add('')
    $extra.Add('# ---- plugin: ' + $pname + ' (used when listed in Plugins=) ----')
    $extra.Add('[' + $pname + ']')
    foreach ($full in @($pset[$pname].Keys)) {
      $spec = $pset[$pname][$full]
      $desc = ''
      if ($spec.Contains('Description')) { $desc = [string]$spec['Description'] }
      if ($desc) { $extra.Add('# ' + $desc) }
      $dv = ''
      if ($spec.Contains('Default')) { $dv = [string]$spec['Default'] }
      $leaf = [string]$full
      if ($leaf.StartsWith($pname + '.')) { $leaf = $leaf.Substring($pname.Length + 1) }
      $extra.Add($leaf + '=' + $dv)
    }
  }
  $all = New-Object System.Collections.Generic.List[string]
  foreach ($l in $t) { $all.Add($l) }
  foreach ($l in $extra) { $all.Add($l) }
  # one line per item: the caller wraps this in @() and gets a flat string array
  return $all.ToArray()
}


# `config init`: bring the file in line with this version - add the keys that appeared,
# comment out the ones that no longer exist, and leave every value alone. A value the user
# set - a plugin setting in particular - is never replaced by its default. Returns the two
# counts so the caller can say what happened.
function Merge-IniDefaults {
  Ensure-Dir
  $tpl = @(Get-IniTemplateLines)
  # everything the program can write is "known"; anything else is left over from an older
  # version or a plugin that is gone. A key inside a template section counts under the
  # section name, so "[item-marks]" + "MaxPins=50" is the key item-marks.MaxPins.
  $known = @{}
  $tplSection = ''
  foreach ($t in $tpl) {
    if ($t -match '^\s*\[(.+)\]\s*$') { $tplSection = $Matches[1].Trim(); continue }
    if ($t -match '^\s*([A-Za-z0-9_.-]+)\s*=') {
      $name = $Matches[1]
      if ($tplSection) { $name = $tplSection + '.' + $name }
      $known[$name.ToLowerInvariant()] = $true
    }
  }
  $lines = New-Object System.Collections.Generic.List[string]
  $have = @{}
  $haveSections = @{}
  $sectionEnd = @{}
  $pruned = 0
  if (Test-Path -LiteralPath $IniPath) {
    # a key may be written flat or as a leaf inside [section]; both count as that key, and
    # the extent of every section is remembered so a late key can join it in place
    $section = ''
    foreach ($l in [IO.File]::ReadAllLines($IniPath, [Text.Encoding]::UTF8)) {
      if ($l -match '^\s*\[(.+)\]\s*$') {
        $section = $Matches[1].Trim()
        $lines.Add($l)
        $haveSections[$section.ToLowerInvariant()] = $true
        $sectionEnd[$section.ToLowerInvariant()] = $lines.Count - 1
        continue
      }
      if ($l -match '^\s*([A-Za-z0-9_.-]+)\s*=') {
        $name = $Matches[1]
        if ($section) { $name = $section + '.' + $name }
        $name = $name.ToLowerInvariant()
        if (-not $known.ContainsKey($name)) {
          # keep the value readable, but out of the way: a removed '#' brings it back
          $lines.Add('# [unknown] ' + $l.Trim())
          $pruned++
          continue
        }
        $lines.Add($l)
        $have[$name] = $true
        if ($section) { $sectionEnd[$section.ToLowerInvariant()] = $lines.Count - 1 }
        continue
      }
      $lines.Add($l)
      if ($section -and $l.Trim()) { $sectionEnd[$section.ToLowerInvariant()] = $lines.Count - 1 }
    }
  }
  # comments are buffered so an added key keeps the explanation that introduces it; a
  # section header is buffered with them, so a gap is filled inside its own [section].
  # A section the file already has gets no second header - the key joins the block it has.
  $pending = New-Object System.Collections.Generic.List[string]
  $tplSectionName = ''
  $added = 0
  foreach ($raw in $tpl) {
    $s = [string]$raw
    $tl = $s.Trim()
    if ($tl -eq '' -or $tl.StartsWith('#')) { $pending.Add($s); continue }
    if ($tl -match '^\[(.+)\]$') {
      $tplSectionName = $Matches[1].Trim().ToLowerInvariant()
      if ($haveSections.ContainsKey($tplSectionName)) { $pending.Clear(); continue }
      $pending.Add($s)
      continue
    }
    if ($tl -notmatch '^\s*([A-Za-z0-9_.-]+)\s*=') { $pending.Clear(); continue }
    $k = $Matches[1].ToLowerInvariant()
    if ($tplSectionName) { $k = $tplSectionName + '.' + $k }
    if ($have.ContainsKey($k)) { $pending.Clear(); continue }
    if ($tplSectionName -and $haveSections.ContainsKey($tplSectionName)) {
      # the section is already in the file: insert after its last line and keep the indices
      $at = [int]$sectionEnd[$tplSectionName] + 1
      $lines.Insert($at, $s)
      foreach ($sec in @($sectionEnd.Keys)) {
        if ([int]$sectionEnd[$sec] -ge $at) { $sectionEnd[$sec] = [int]$sectionEnd[$sec] + 1 }
      }
      $sectionEnd[$tplSectionName] = $at
      $pending.Clear()
      $have[$k] = $true
      $added++
      continue
    }
    if ($lines.Count -gt 0 -and $pending.Count -gt 0) { $lines.Add('') }
    foreach ($p in $pending) { $lines.Add($p) }
    $lines.Add($s)
    $pending.Clear()
    $have[$k] = $true
    $added++
  }
  if ($added -gt 0 -or $pruned -gt 0 -or -not (Test-Path -LiteralPath $IniPath)) {
    [IO.File]::WriteAllText($IniPath, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), $Utf8)
  }
  return @{ Added = $added; Pruned = $pruned }
}


# `config reset`: replace the file with a fresh template. This is the only path that throws
# values away, and it is never reached by accident.
function Write-IniTemplate([switch]$Force) {
  if ((Test-Path -LiteralPath $IniPath) -and (-not $Force)) { return $IniPath }
  Ensure-Dir
  $all = @(Get-IniTemplateLines)
  [IO.File]::WriteAllText($IniPath, (($all -join [Environment]::NewLine) + [Environment]::NewLine), $Utf8)
  return $IniPath
}

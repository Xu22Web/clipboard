# lib/config.ps1 - the settings surface: apply clipboard.ini to the defaults, print the
# effective values, validate and write one key at a time.
#
# The schema lives in lib/ini.ps1 and no key is invented here: anything not in that table
# is reported as unknown, which is what keeps `config`, `config get` and `config set`
# consistent with each other.

function Apply-Config {
  param([switch]$NoColors)
  $script:IniCache = $null
  $script:ExcludePattern = ''
  $script:ShowBalloon = $true
  $script:Theme = 'win11-dark'
  $script:WinWidth = 700
  $script:Rows = 10
  $script:WinLeft = ''
  $script:WinTop = ''
  $script:SaveWinWidth = $false
  $script:SaveWinPos = $false
  $script:ShowTime = $true
  $script:ShowTypeIcon = $true
  $script:HighlightOn = $true
  $script:HighlightMax = 8192
  $script:ShowNewlineMarker = $true
  $script:UndoOn = $true
  $script:DpiAware = $true
  $script:ScrollLines = 0
  $script:Animations = $true
  $script:Autostart = $true
  $script:DesktopShortcut = $true
  $script:PluginList = @()
  # settings never come from the command line, so a reload starts from the defaults again
  $script:Hotkey = 'Ctrl+Alt+V'
  $script:PasteKeys = '^v'
  $script:HotkeyFallbacks = ''
  $script:ModReleaseTimeout = 1200
  $script:PasteSettle = 80
  $script:MaxItems = 300
  $script:MaxBytes = 204800
  $script:MaxTotal = 4194304
  $script:Interval = 300
  $script:NoPaste = $false

  $v = Get-CfgValue 'Hotkey';            if ($null -ne $v) { $script:Hotkey = $v }
  $v = Get-CfgValue 'PasteKeys';         if ($null -ne $v) { $script:PasteKeys = $v }
  $v = Get-CfgValue 'HotkeyFallbacks';   if ($null -ne $v) { $script:HotkeyFallbacks = $v }
  $v = Get-CfgValue 'ModReleaseTimeout'; if ($null -ne $v) { $script:ModReleaseTimeout = [int]$v }
  $v = Get-CfgValue 'PasteSettle';       if ($null -ne $v) { $script:PasteSettle = [int]$v }
  $v = Get-CfgValue 'MaxItems';          if ($null -ne $v) { $script:MaxItems = [int]$v }
  $v = Get-CfgValue 'MaxBytes';          if ($null -ne $v) { $script:MaxBytes = [int]$v }
  $v = Get-CfgValue 'MaxTotal';          if ($null -ne $v) { $script:MaxTotal = [int]$v }
  $v = Get-CfgValue 'Interval';          if ($null -ne $v) { $script:Interval = [int]$v }
  $v = Get-CfgValue 'NoPaste';           if ($v -eq '1') { $script:NoPaste = $true }
  $v = Get-CfgValue 'Balloon';           if ($v -eq '0') { $script:ShowBalloon = $false }
  $v = Get-CfgValue 'Theme';             if ($null -ne $v) { $script:Theme = $v }
  $v = Get-CfgValue 'ExcludePattern';    if ($null -ne $v) { $script:ExcludePattern = $v }
  $v = Get-CfgValue 'WindowWidth';       if ($null -ne $v) { $script:WinWidth = [int]$v }
  $v = Get-CfgValue 'Rows';              if ($null -ne $v) { $script:Rows = [int]$v }
  $v = Get-CfgValue 'WindowLeft';        if ($null -ne $v) { $script:WinLeft = $v }
  $v = Get-CfgValue 'WindowTop';         if ($null -ne $v) { $script:WinTop = $v }
  $v = Get-CfgValue 'SaveWindowWidth';   if ($v -eq '1') { $script:SaveWinWidth = $true }
  $v = Get-CfgValue 'SaveWindowPos';     if ($v -eq '1') { $script:SaveWinPos = $true }
  $v = Get-CfgValue 'ShowTime';          if ($v -eq '0') { $script:ShowTime = $false }
  $v = Get-CfgValue 'ShowTypeIcon';      if ($v -eq '0') { $script:ShowTypeIcon = $false }
  $v = Get-CfgValue 'Highlight';         if ($v -eq '0') { $script:HighlightOn = $false }
  $v = Get-CfgValue 'HighlightMaxBytes'; if ($null -ne $v) { $script:HighlightMax = [int]$v }
  $v = Get-CfgValue 'ShowNewlineMarker'; if ($v -eq '0') { $script:ShowNewlineMarker = $false }
  $v = Get-CfgValue 'Undo';              if ($v -eq '0') { $script:UndoOn = $false }
  $v = Get-CfgValue 'Autostart';         if ($v -eq '0') { $script:Autostart = $false }
  $v = Get-CfgValue 'DesktopShortcut';   if ($v -eq '0') { $script:DesktopShortcut = $false }
  $v = Get-CfgValue 'DpiAware';          if ($v -eq '0') { $script:DpiAware = $false }
  $v = Get-CfgValue 'ScrollLines';       if ($null -ne $v) { $script:ScrollLines = [int]$v }
  $v = Get-CfgValue 'Animations';        if ($v -eq '0') { $script:Animations = $false }
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
  $out = New-Object System.Collections.Generic.List[string]
  $cache = $script:IniCache
  if ($null -eq $cache) { $cache = Read-Ini; $script:IniCache = $cache }
  $themes = @()
  if (Get-Command Get-ThemeNames -ErrorAction SilentlyContinue) { try { $themes = @(Get-ThemeNames) } catch { } }
  foreach ($k in @($cache.Keys)) {
    $key = [string]$k
    $raw = [string]$cache[$k]
    if (-not $script:IniSchema.Contains($key)) { $out.Add('unknown key: ' + $key); continue }
    if ($raw -eq '') { continue }
    $r = Convert-IniValue $key $raw
    if (-not $r.Ok) { $out.Add($key + '=' + $raw + '  (' + $r.Error + ')'); continue }
    if ($key -eq 'Theme' -and $themes.Count -gt 0 -and ($themes -notcontains [string]$r.Value)) {
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
  $ini = $script:IniCache
  if ($null -eq $ini) { $ini = Read-Ini }
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
    '# clipboard.ini - flat key=value list. Restart the daemon after editing (clipboard stop, clipboard serve).',
    '# CLI switches win over this file. Every key below can also be written with:',
    '#   clipboard config set <key> <value>',
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
  $pset = $null
  if (Get-Command Get-AllPluginSettings -ErrorAction SilentlyContinue) {
    $pset = Get-AllPluginSettings (Join-Path $Root 'plugins')
  }
  if ($null -eq $pset -or $pset.Count -eq 0) { $pset = $script:PluginSettings }
  if ($null -eq $pset) { $pset = @{} }
  $extra = New-Object System.Collections.Generic.List[string]
  foreach ($pname in @($pset.Keys)) {
    $extra.Add('')
    $extra.Add('# ---- plugin: ' + $pname + ' (used when listed in Plugins=) ----')
    foreach ($full in @($pset[$pname].Keys)) {
      $spec = $pset[$pname][$full]
      $desc = ''
      if ($spec.Contains('Desc')) { $desc = [string]$spec['Desc'] }
      if ($desc) { $extra.Add('# ' + $desc) }
      $dv = ''
      if ($spec.Contains('Default')) { $dv = [string]$spec['Default'] }
      $extra.Add($full + '=' + $dv)
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
  # version or a plugin that is gone
  $known = @{}
  foreach ($t in $tpl) {
    if ($t -match '^\s*([A-Za-z0-9_.-]+)\s*=') { $known[$Matches[1].ToLowerInvariant()] = $true }
  }
  $lines = New-Object System.Collections.Generic.List[string]
  $have = @{}
  $pruned = 0
  if (Test-Path -LiteralPath $IniPath) {
    foreach ($l in [IO.File]::ReadAllLines($IniPath, [Text.Encoding]::UTF8)) {
      if ($l -match '^\s*([A-Za-z0-9_.-]+)\s*=' -and -not $known.ContainsKey($Matches[1].ToLowerInvariant())) {
        # keep the value readable, but out of the way: a removed '#' brings it back
        $lines.Add('# [unknown] ' + $l.Trim())
        $pruned++
        continue
      }
      $lines.Add($l)
      if ($l -match '^\s*([A-Za-z0-9_.-]+)\s*=') { $have[$Matches[1].ToLowerInvariant()] = $true }
    }
  }
  # comments are buffered so an added key keeps the explanation that introduces it
  $pending = New-Object System.Collections.Generic.List[string]
  $added = 0
  foreach ($raw in $tpl) {
    $s = [string]$raw
    $tl = $s.Trim()
    if ($tl -eq '' -or $tl.StartsWith('#')) { $pending.Add($s); continue }
    if ($tl -notmatch '^\s*([A-Za-z0-9_.-]+)\s*=') { $pending.Clear(); continue }
    $k = $Matches[1].ToLowerInvariant()
    if ($have.ContainsKey($k)) { $pending.Clear(); continue }
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

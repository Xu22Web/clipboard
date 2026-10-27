# lib/config.ps1 - the settings surface: apply clipboard.ini to the defaults, print the
# effective values, validate and write one key at a time.
#
# The schema lives in lib/ini.ps1 and no key is invented here: anything not in that table
# is reported as unknown, which is what keeps `config`, `config get` and `config set`
# consistent with each other.

function Apply-Config {
  $script:IniCache = $null
  $script:ExcludePattern = ''
  $script:ShowBalloon = $true
  $script:Theme = 'win11-dark'
  $script:WinWidth = 700
  $script:WinHeight = 510
  $script:WinLeft = ''
  $script:WinTop = ''
  $script:SaveWinSize = $false
  $script:SaveWinPos = $false
  $script:ShowTime = $true
  $script:ShowTypeIcon = $true
  $script:HighlightOn = $true
  $script:HighlightMax = 8192
  $script:ShowNewlineMarker = $true
  $script:UndoOn = $true
  $script:DpiAware = $true
  $script:ScrollLines = 0
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
  $v = Get-CfgValue 'WindowHeight';      if ($null -ne $v) { $script:WinHeight = [int]$v }
  $v = Get-CfgValue 'WindowLeft';        if ($null -ne $v) { $script:WinLeft = $v }
  $v = Get-CfgValue 'WindowTop';         if ($null -ne $v) { $script:WinTop = $v }
  $v = Get-CfgValue 'SaveWindowSize';    if ($v -eq '1') { $script:SaveWinSize = $true }
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
  $v = Get-CfgValue 'Plugins'
  if ($null -ne $v) {
    $script:PluginList = @($v -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  }
  # plugin settings are read from the same file, so they follow every reload
  if ($script:PluginSettings -and $script:PluginSettings.Count -gt 0 -and (Get-Command Apply-PluginSettings -ErrorAction SilentlyContinue)) {
    Apply-PluginSettings
  }
  if ($script:PluginThemeSpec -and $script:PluginThemeSpec.Count -gt 0 -and (Get-Command Apply-PluginTheme -ErrorAction SilentlyContinue)) {
    Apply-PluginTheme
  }
  # resolves the palette / fonts / metric overrides for the selected theme
  Apply-Theme
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
    WindowHeight      = [string]$script:WinHeight
    WindowLeft        = [string]$script:WinLeft
    WindowTop         = [string]$script:WinTop
    SaveWindowSize    = [string][int][bool]$script:SaveWinSize
    SaveWindowPos     = [string][int][bool]$script:SaveWinPos
    ShowTime          = [string][int][bool]$script:ShowTime
    ShowTypeIcon      = [string][int][bool]$script:ShowTypeIcon
    Highlight         = [string][int][bool]$script:HighlightOn
    HighlightMaxBytes = [string]$script:HighlightMax
    ShowNewlineMarker = [string][int][bool]$script:ShowNewlineMarker
    Undo              = [string][int][bool]$script:UndoOn
    DpiAware          = [string][int][bool]$script:DpiAware
    ScrollLines       = [string]$script:ScrollLines
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

function Show-Config {
  # read only: this never creates or rewrites clipboard.ini
  $exists = Test-Path -LiteralPath $IniPath
  Write-Host ('config file : ' + $IniPath + $(if ($exists) { '' } else { '   (missing, built-in defaults apply)' }))
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
    if ($k -eq 'Plugins' -and $show -eq '') { $show = '(none, base tool only)' }
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
    Write-Host 'plugins     : none (base tool only, set Plugins= to opt in)'
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

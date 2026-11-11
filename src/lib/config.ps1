# lib/config.ps1 - the `config` command surface: apply clipboard.ini to the defaults, print
# the effective values, validate and write one key at a time, keep the template in sync.
#
# The keys are described by schema/clipboard.ps1, and three layers under it do the work:
# utils/ini.ps1 parses text into a document, utils/inifile.ps1 reads a file once per change
# and rewrites a single line, utils/schema.ps1 validates a value against the schema. The
# schema itself, and reading or writing one key, belong to lib/settings.ps1 - plugin settings
# use the same entry points, so neither file has to call the other. Nothing here invents a
# key: a key the schema does not describe is reported as unknown, which is what keeps
# `config`, `config get` and `config set` consistent with each other.

function Apply-Config {
  param([switch]$NoColors, [switch]$SkipTheme)
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
  # resolves the palette / fonts / metric overrides for the selected theme. A command that
  # never draws keeps the theme name the ini set and pays nothing: reading the theme file,
  # resolving its name and loading System.Drawing is about a third of the start-up.
  if (-not $SkipTheme) { Apply-Theme -SkipColors:$NoColors }
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
    MaxTextBytes      = [string]$script:MaxTextBytes
    MaxTextTotalBytes = [string]$script:MaxTextTotalBytes
    MaxMediaTotalBytes= [string]$script:MaxMediaTotalBytes
    CaptureImages     = [string][int][bool]$script:CaptureImages
    MaxImageBytes     = [string]$script:MaxImageBytes
    CaptureRich       = [string][int][bool]$script:CaptureRich
    MaxHtmlBytes      = [string]$script:MaxHtmlBytes
    MaxRtfBytes       = [string]$script:MaxRtfBytes
    RtfImagesUpToBytes= [string]$script:RtfImagesUpToBytes
    InlineImageUpToBytes = [string]$script:InlineImageUpToBytes
    PasteRich         = [string][int][bool]$script:PasteRich
    PasteFilesAsText  = [string][int][bool]$script:PasteFilesAsText
    PasteTyping       = [string][int][bool]$script:PasteTyping
    AppRules          = [string]$script:AppRules
    Interval          = [string]$Interval
    NoPaste           = [string][int][bool]$script:NoPaste
    Balloon           = [string][int][bool]$script:ShowBalloon
    Theme             = [string]$script:Theme
    ExcludePattern    = [string]$script:ExcludePattern
    WindowWidth       = [string]$script:WinWidth
    Rows              = [string]$script:Rows
    CompactMode       = [string][int][bool]$script:CompactMode
    CompactWidth      = [string]$script:CompactWidth
    CompactRows       = [string]$script:CompactRows
    WindowLeft        = [string]$script:WinLeft
    WindowTop         = [string]$script:WinTop
    SaveWindowPos     = [string][int][bool]$script:SaveWinPos
    PlaceNearForeground = [string][int][bool]$script:PlaceNearForeground
    PlaceAtCaret      = [string][int][bool]$script:PlaceAtCaret
    ImeTakeover       = [string]$script:ImeTakeover
    ShowTime          = [string][int][bool]$script:ShowTime
    ShowTypeIcon      = [string][int][bool]$script:ShowTypeIcon
    ShowThumbnails    = [string][int][bool]$script:ShowThumbnails
    Highlight         = [string][int][bool]$script:HighlightOn
    HighlightMaxBytes = [string]$script:HighlightMaxBytes
    ShowNewlineMarker = [string][int][bool]$script:ShowNewlineMarker
    PreviewHover      = [string][int][bool]$script:PreviewHover
    PreviewDelay      = [string]$script:PreviewDelay
    PreviewChars      = [string]$script:PreviewChars
    BlobChars         = [string]$script:BlobChars
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
    if ($k -eq 'AppRules' -and $show -eq '') { $show = '(every program alike)' }
    Write-Host ('    ' + $name + ' = ' + $show + (& $srcOf $k))
  }

  $loaded = @()
  if (Get-Command Get-PluginNames -ErrorAction SilentlyContinue) { $loaded = @(Get-PluginNames) }
  foreach ($pname in $loaded) {
    Write-Host ''
    Write-Host ('  [plugin: ' + $pname + ']')
    # the one line the plugin file gives about itself, so a group of keys is never anonymous
    $descr = ''
    foreach ($p in @($script:Plugins)) {
      if ($null -eq $p -or $p -isnot [System.Collections.IDictionary]) { continue }
      if ([string]$p['Name'] -ne $pname) { continue }
      if ($p.Contains('Description')) { $descr = [string]$p['Description'] }
      break
    }
    if ($descr) { Write-Host ('    ' + $descr) }
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
  Write-Host 'clipboard config init                 add missing keys, comment out retired ones'
  Write-Host 'clipboard config reset                rewrite the file from the defaults (loses values)'
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
# restart the resident so new settings take effect without a manual stop/start. Only the
# resident that serves this data folder: another install (or a test sandbox) holding the
# machine-wide mutex must not be stopped by a `config set` here.
function Restart-ResidentIfRunning {
  if (-not (Test-ResidentOwnsStore)) { Write-Host '     resident is not running, nothing to reload'; return }
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


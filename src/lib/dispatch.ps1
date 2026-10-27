# lib/dispatch.ps1 - one entry point for the whole CLI: apply the settings, load the plugins
# named in Plugins=, then run exactly one command.
#
# The switches arrive as parameters instead of being read from the caller's scope, so this
# module can be reasoned about (and tested) on its own. Apply-Config runs first: a command
# must see the values from clipboard.ini, and a plugin must see its own settings resolved.

function Invoke-Main {
  param(
    [string]$Command = '',
    [string]$Value,
    [string]$Sub,
    [string]$Arg,
    [int]$Count = 0,
    [switch]$Purge,
    [switch]$All
  )
Apply-Config
# Plugins are opt-in: only the names listed in Plugins= are loaded, in that order.
# An empty list (the default) keeps the base tool running on its own.
if (@($script:PluginList).Count -gt 0 -and (Get-Command Load-Plugins -ErrorAction SilentlyContinue)) {
  $script:Plugins = @(Load-Plugins (Join-Path $Root 'plugins') @($script:PluginList))
  # Plugin settings join the shared schema as <plugin>.<Key>, then get resolved so
  # `config`, `config get/set/init` and Get-PluginSetting all see the same values.
  if (Get-Command Register-PluginSettings -ErrorAction SilentlyContinue) {
    Register-PluginSettings
    Apply-PluginSettings
  }
  # plugin look-and-feel: NOT ini keys, restyled by a [<plugin>] section in themes\<name>.ini
  if (Get-Command Register-PluginThemeSettings -ErrorAction SilentlyContinue) {
    Register-PluginThemeSettings
    Apply-PluginTheme
  }
  # one-time plugin setup, after every setting is resolved (create folders, warm caches)
  if (Get-Command Invoke-PluginInit -ErrorAction SilentlyContinue) { Invoke-PluginInit }
  # Data commands (get/list/put) must stay clean, so a typo is logged here and shown by
  # status / config / help instead of being printed before every command.
  $missing = @()
  if (Get-Command Get-PluginMissingNames -ErrorAction SilentlyContinue) { $missing = @(Get-PluginMissingNames) }
  if ($missing.Count -gt 0) { Write-Log ('plugin not found: ' + ($missing -join ', ')) }
}
if ($Command -eq '' -or @('help', '-h', '--help') -contains $Command.ToLower()) { Show-Usage; return }

switch ($Command.ToLower()) {
  'serve' { Start-Serve }
  'ui' {
    $sent = $false
    try { $e = [System.Threading.EventWaitHandle]::OpenExisting($EventName); [void]$e.Set(); $sent = $true } catch { }
    if (-not $sent) {
      Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', (Join-Path $Root 'clipboard.ps1'), 'serve'
      )
      for ($i = 0; $i -lt 12 -and -not $sent; $i++) {
        Start-Sleep -Milliseconds 400
        try { $e = [System.Threading.EventWaitHandle]::OpenExisting($EventName); [void]$e.Set(); $sent = $true } catch { }
      }
      if (-not $sent) { Write-Host 'could not reach the resident process, run: clipboard serve' }
    }
  }
  'list' {
    $recs = @(Get-Records)
    if ($recs.Count -eq 0) { Write-Host '(history is empty)'; break }
    $n = if ($Count -gt 0) { [Math]::Min($Count, $recs.Count) } else { $recs.Count }
    $sortMark = Get-SortMark
    for ($i = 0; $i -lt $n; $i++) {
      $rt = Get-RelTime $recs[$i].Time
      if (-not $rt) { $rt = '-' }
      $head = ' '
      if ($sortMark -and (Test-Mark $recs[$i] $sortMark)) { $head = '*' }
      Write-Host ('{0,3}  {1,-5} {2} {3}' -f ($i + 1), $rt, $head, (Format-Item $recs[$i].Payload 100))
    }
  }
  'put' {
    $t = $Value
    if ([string]::IsNullOrEmpty($t)) {
      $t = [Console]::In.ReadToEnd()
      $t = $t -replace '(\r\n|\n|\r)$', ''
    }
    if ($null -eq $t) { $t = '' }
    [void](Set-Text $t)
    Add-Item $t
    Write-Host ('clipboard set: ' + $t.Length + ' chars')
  }
  'get' {
    $t = Get-Text
    if ($null -ne $t) { [Console]::Out.Write($t) }
  }
  'pick' {
    $i = 0
    if (-not [int]::TryParse($Value, [ref]$i)) { Write-Host 'usage: clipboard pick 3'; break }
    $recs = @(Get-Records)
    if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; break }
    [void](Set-ClipItem $recs[$i - 1].Payload)
    Add-Item $recs[$i - 1].Payload
    Write-Host ('clipboard set: ' + (Format-Item $recs[$i - 1].Payload 100))
  }
  'del' {
    $i = 0
    if (-not [int]::TryParse($Value, [ref]$i)) { Write-Host 'usage: clipboard del 3'; break }
    $recs = @(Get-Records)
    if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; break }
    $victim = $recs[$i - 1]
    $res = Remove-Record $victim.Payload
    if ($res -like 'protected:*') {
      # the verb that removes the mark belongs to the plugin that declared it
      $pm = $res.Substring(10)
      $info = Get-MarkInfo $pm
      $word = Get-MarkWord $pm
      if ($info -and $info.Unset) { Write-Host ('[!] ' + $word + ' entry, ' + $info.Unset + ' it first: clipboard ' + $info.Unset + ' ' + $i) }
      else { Write-Host ('[!] entry is protected by the ' + $pm + ' mark; load the plugin that owns it') }
      break
    }
    if ($res -eq 'removed') { Write-Host ('deleted: ' + (Format-Item $victim.Payload 60) + '   left ' + @(Get-Records).Count) }
    else { Write-Host 'index out of range' }
  }
  'clear' {
    $keep = @(Get-ClearKeepMarks -All:$All.IsPresent)
    Clear-Store $keep
    $left = @(Get-Records)
    # report what survived, and for every protected mark say which verb removes it
    $parts = @()
    foreach ($pm in @(Get-ProtectedMarks)) {
      $c = 0
      foreach ($r in $left) { if (Test-Mark $r $pm) { $c++ } }
      if ($c -le 0) { continue }
      $info = Get-MarkInfo $pm
      if ($info -and $info.Unset) { $parts += ($c.ToString() + ' ' + (Get-MarkWord $pm) + ' kept (' + $info.Unset + ' to remove them)') }
      else { $parts += ($c.ToString() + ' ' + (Get-MarkWord $pm) + ' kept') }
    }
    if ($parts.Count -gt 0) { Write-Host ('[ok] history cleared, ' + ($parts -join ', ')) }
    elseif ($left.Count -gt 0) { Write-Host ('[ok] history cleared, ' + $left.Count + ' kept by marks (clear -All drops them)') }
    else { Write-Host '[ok] history cleared' }
  }
  'pause' { Ensure-Dir; New-Item -ItemType File -Path $Paused -Force | Out-Null; Write-Host '[ok] capture paused' }
  'stop' {
    try { $se = [System.Threading.EventWaitHandle]::OpenExisting($StopName); [void]$se.Set(); Write-Log 'stop requested'; Write-Host '[ok] stop requested' }
    catch { Write-Host 'resident is not running' }
  }
  'resume' { if (Test-Path -LiteralPath $Paused) { Remove-Item -LiteralPath $Paused -Force }; Write-Host '[ok] capture resumed' }
  'status' {
    $alive = $false
    try {
      $m = New-Object System.Threading.Mutex($false, $MutexName)
      if ($m.WaitOne(0)) { $m.ReleaseMutex() } else { $alive = $true }
      $m.Dispose()
    } catch { }
    Write-Host ('resident    : ' + $(if ($alive) { 'running' } else { 'not running' }))
    $recs = @(Get-Records)
    $markWords = @(Get-MarkCountWords $recs)
    $line = 'entries     : ' + $recs.Count + ' / ' + $MaxItems
    if ($markWords.Count -gt 0) { $line = $line + '   ' + ($markWords -join '   ') }
    Write-Host $line
    Write-Host ('capture     : ' + $(if (Test-Path -LiteralPath $Paused) { 'paused' } else { 'active' }))
    Write-Host ('autostart   : ' + $(if (Test-Path -LiteralPath (Get-AutostartPath)) { 'installed' } else { 'not installed' }))
    Write-Host ('desktop     : ' + $(if (Test-Path -LiteralPath (Get-DesktopPath)) { 'installed' } else { 'not installed' }))
    Write-Host ('store file  : ' + $StoreFile + '   (v2)')
    Write-Host ('panel       : ' + $script:WinWidth + 'x' + $script:WinHeight + '  theme=' + $script:Theme + '  dpi=' + $script:UiScale)
    $hkFile = Join-Path $StoreDir 'hotkey.txt'
    $eff = '(daemon never started)'
    if (Test-Path -LiteralPath $hkFile) { $eff = ([IO.File]::ReadAllText($hkFile, [Text.Encoding]::UTF8)).Trim() }
    Write-Host ('active key  : ' + $eff + '   (requested: ' + $Hotkey + ')')
    Write-Host ('config file : ' + $IniPath + $(if (Test-Path -LiteralPath $IniPath) { '' } else { '   (missing, defaults in effect)' }))
    $pnames = @()
    if (Get-Command Get-PluginNames -ErrorAction SilentlyContinue) { $pnames = @(Get-PluginNames) }
    if ($pnames.Count -gt 0) { Write-Host ('plugins     : ' + ($pnames -join ', ')) }
    elseif (@($script:PluginList).Count -gt 0) { Write-Host ('plugins     : [!] not found: ' + (@($script:PluginList) -join ',')) }
    else { Write-Host 'plugins     : none (base tool only)' }
  }
  'config' {
    $act = ''
    if ($Value) { $act = $Value.ToLower() }
    if ($act -eq 'init') { Write-Host ('[ok] template written: ' + (Write-IniTemplate -Force)) }
    elseif ($act -eq 'edit') {
      $p = Write-IniTemplate
      Write-Host ('editing: ' + $p)
      Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $p + '"')
    }
    elseif ($act -eq 'get') {
      if (-not $Sub) { Write-Host 'usage: clipboard config get <key>' }
      else { [void](Show-ConfigKey $Sub) }
    }
    elseif ($act -eq 'set') {
      if (-not $Sub -or -not $script:BoundParams.ContainsKey('Arg')) {
        Write-Host 'usage: clipboard config set <key> <value>'
      } else {
        if (Set-ConfigKey $Sub $Arg) {
          # the two install keys only matter to `install`, so nothing has to reload
          $installOnly = @('autostart', 'desktopshortcut') -contains ([string]$Sub).ToLower()
          if (-not $installOnly) { Restart-ResidentIfRunning }
        }
      }
    }
    else { Show-Config }
  }
  'diag' { Invoke-Diag }
  'themes' {
    $names = @(Get-ThemeNames)
    if ($names.Count -eq 0) {
      Write-Host ('no themes found in ' + (Get-ThemeDir) + '   (built-in palette in use)')
      break
    }
    Write-Host ('themes in ' + (Get-ThemeDir) + ':')
    foreach ($n in $names) {
      $mark = ' '
      if ($n -ieq $script:Theme) { $mark = '*' }
      $desc = ''
      $t = Read-Theme $n
      if ($t -is [hashtable] -and $t.ContainsKey('Description')) { $desc = [string]$t['Description'] }
      Write-Host ('{0} {1,-14} {2}' -f $mark, $n, $desc)
    }
    Write-Host ''
    Write-Host ('active: ' + $script:Theme + '   change with: clipboard config set Theme <name>')
  }
  'restore' { Invoke-Restore }
  'install' {
    $pol = 'RemoteSigned'
    if ($Value -and $Value.ToLower() -eq 'bypass') { $pol = 'Bypass' }
    Install-Autostart -Policy $pol
  }
  'uninstall' {
    $doPurge = $Purge.IsPresent -or ($Value -and $Value.ToLower() -eq 'purge')
    Remove-Autostart -Purge:$doPurge
  }
  default {
    $pluginCmd = $null
    try { if (Get-Command Get-PluginCommand -ErrorAction SilentlyContinue) { $pluginCmd = Get-PluginCommand $Command.ToLower() } } catch { }
    if ($pluginCmd) {
      & $pluginCmd $Value
      break
    }
    Write-Host ('unknown command: ' + $Command)
    Write-Host ''
    Show-Usage
  }
}
}

# lib/dispatch.ps1 - one entry point for the whole CLI: apply the settings, load the plugins
# named in Plugins=, then run exactly one command.
#
# The switches arrive as parameters instead of being read from the caller's scope, so this
# module can be reasoned about (and tested) on its own. Apply-Config runs first: a command
# must see the values from clipboard.ini, and a plugin must see its own settings resolved.
#
# The work is split in two on purpose. Initialize-Main is the assembly - settings, plugins,
# plugin settings - and it runs once per process. Invoke-Dispatch is the command itself, and
# it is what the resident runs again for every request it answers over the proxy pipe
# (lib/proxy.ps1): the assembly is already done there, and only the command has to repeat.

function Initialize-Main($Call) {
  $Command = [string]$Call.Command
# Only the two that put a panel on screen need the palette. Everything else - put, get,
# list, del, status, config, help - would pay ~250 ms to load System.Drawing for colours it
# never draws, and another ~300 ms to read the theme file, so it skips the theme altogether.
$needColors = ($Command -eq '' -or $Command -eq 'ui' -or $Command -eq 'serve')
Apply-Config -NoColors:(-not $needColors) -SkipTheme:(-not $needColors)
# Plugins are loaded by default: clipboard.ini lists them by name, in load order. A file
# that is not listed is never executed, so the list is the whole surface.
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
}

# One command, with everything it needs already in place. $Call carries the four positional
# values, the count, the four switches and the names that were actually bound - `config set
# key ""` and `config set key` are different commands, and the second one must not be turned
# into the first by a round trip through a pipe.
function Invoke-Dispatch($Call) {
  $Command = [string]$Call.Command
  $Value = $Call.Value
  $Sub = $Call.Sub
  $Arg = $Call.Arg
  $Count = 0
  if ($null -ne $Call.Count) { $Count = [int]$Call.Count }
  $Purge = [bool]$Call.Purge
  $All = [bool]$Call.All
  $Media = [bool]$Call.Media
  $Replace = [bool]$Call.Replace
  $bound = @{}
  foreach ($n in @($Call.Bound)) { if ($n) { $bound[[string]$n] = $true } }
  $script:BoundParams = $bound
  $script:AnsweringAsResident = [bool]$Call.Resident
# One pass over clipboard.ini now that every key is registered: an unknown key, a value the
# schema rejects and a theme name that has no file are collected instead of only logged by
# whichever loader happened to trip over them. `status` shows the count, `config` shows the
# detail.
$script:ConfigProblems = @()
# Only the commands that report settings print them: `status` counts, `config` lists. Walking
# every key against the schema on a capture path (put, get, list, pick, del) would pay for a
# validation pass nobody reads.
$showProblems = ($Command -eq '' -or @('status', 'config', 'help', '-h', '--help') -contains $Command.ToLower())
if ($showProblems -and (Get-Command Get-ConfigProblems -ErrorAction SilentlyContinue)) {
  try { $script:ConfigProblems = @(Get-ConfigProblems) } catch { $script:ConfigProblems = @() }
  $stamp = ($script:ConfigProblems -join '|')
  if ($stamp -ne $script:ConfigProblemStamp) {
    $script:ConfigProblemStamp = $stamp
    foreach ($p in $script:ConfigProblems) { Write-Log ('config: ' + $p) }
  }
}
if ($Command -eq '' -or @('help', '-h', '--help') -contains $Command.ToLower()) { Show-Usage; return }

switch ($Command.ToLower()) {
  'version' {
    Write-Host ('clipboard ' + $script:Version + '   data v' + $script:DataVersion)
  }
  'migrate' {
    $r = Invoke-DataMigration -Purge:$Purge
    $line = [string]$r.Message
    if (-not $line.StartsWith('[!]')) { $line = '[ok] ' + $line }
    Write-Host $line
    if ($r.Changed) { Restart-ResidentIfRunning }
  }
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
      Write-Host ('{0,3}  {1,-5} {2} {3}' -f ($i + 1), $rt, $head, (Format-Record $recs[$i] 100))
    }
  }
  'put' {
    $t = $Value
    # The resident answers over the pipe, and the client read stdin before it asked: an empty
    # value there is an empty entry, not an invitation to read this process's own stdin.
    if ([string]::IsNullOrEmpty($t) -and -not $script:AnsweringAsResident) {
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
    [void](Set-ClipItem $recs[$i - 1].Payload ([string]$recs[$i - 1].Rich))
    [void](Touch-Record ([string]$recs[$i - 1].Payload))
    Write-Host ('clipboard set: ' + (Format-Record $recs[$i - 1] 100))
  }
  'edit' {
    $i = 0
    if (-not [int]::TryParse($Value, [ref]$i)) { Write-Host 'usage: clipboard edit 3'; break }
    $recs = @(Get-Records)
    if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; break }
    $rec = $recs[$i - 1]
    $file = Join-Path ([IO.Path]::GetTempPath()) ('clipboard-edit-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    try {
      [IO.File]::WriteAllText($file, [string]$rec.Payload, $Utf8)
      [void](Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $file + '"') -PassThru -Wait)
      $new = ''
      try { $new = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) } catch { }
      # an editor ends the file with a line break the entry did not have
      if ($new.EndsWith("`r`n")) { $new = $new.Substring(0, $new.Length - 2) }
      elseif ($new.EndsWith("`n")) { $new = $new.Substring(0, $new.Length - 1) }
      $res = Update-RecordText ([string]$rec.Payload) $new
      if ($res.Ok) { Write-Host ('clipboard edit: ' + (Format-Record $rec 100)) }
      else { Write-Host ('not saved: ' + [string]$res.Error) }
    } finally {
      Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
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
    if ($res -eq 'removed') { Write-Host ('deleted: ' + (Format-Record $victim 60) + '   left ' + @(Get-Records).Count) }
    else { Write-Host 'index out of range' }
  }
  'clear' {
    $keep = @(Get-ClearKeepMarks -All:$All)
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
    $alive = [bool]$script:AnsweringAsResident
    if (-not $alive) { $alive = Test-ResidentOwnsStore }
    Write-Host ('version     : ' + $script:Version)
    Write-Host ('resident    : ' + $(if ($alive) { 'running' } else { 'not running' }))
    $recs = @(Get-Records)
    $markWords = @(Get-MarkCountWords $recs)
    $line = 'entries     : ' + $recs.Count + ' / ' + $MaxItems
    if ($markWords.Count -gt 0) { $line = $line + '   ' + ($markWords -join '   ') }
    Write-Host $line
    Write-Host ('capture     : ' + $(if (Test-Path -LiteralPath $Paused) { 'paused' } else { 'active' }))
    Write-Host ('autostart   : ' + $(if (Test-Path -LiteralPath (Get-AutostartPath)) { 'installed' } else { 'not installed' }))
    Write-Host ('desktop     : ' + $(if (Test-Path -LiteralPath (Get-DesktopPath)) { 'installed' } else { 'not installed' }))
    Write-Host ('store file  : ' + $StoreFile)
    $sv = Get-StoreVersion
    Write-Host ('data        : v' + $script:DataVersion + '   (file: ' + $sv.Label + ')')
    if (@('old', 'newer', 'unknown') -contains $sv.Kind) { Write-Host ('migration   : [!] ' + (Get-StoreAdvice $sv)) }
    Write-Host ('panel       : ' + $script:WinWidth + 'x' + (Get-PanelHeight $script:Rows (Get-PanelRowHeight) (Get-PanelChrome)) + '  rows=' + $script:Rows + '  theme=' + $script:Theme + '  dpi=' + $script:UiScale)
    Write-Host ('compact     : ' + $(if ($script:CompactMode) { 'on   ' + $script:CompactWidth + 'x' + $script:CompactRows + ' rows' } else { 'off' }))
    $hkFile = Join-Path $StoreDir 'hotkey.txt'
    $eff = '(daemon never started)'
    if (Test-Path -LiteralPath $hkFile) { $eff = ([IO.File]::ReadAllText($hkFile, [Text.Encoding]::UTF8)).Trim() }
    Write-Host ('active key  : ' + $eff + '   (requested: ' + $Hotkey + ')')
    # the shell has its own history behind Win+V; when it is off there is no command to fix
    # it from here, so the state is stated once instead of being probed on request
    $winv = ''
    if (Get-Command Get-WinVState -ErrorAction SilentlyContinue) { $winv = Get-WinVState }
    if ($winv) { Write-Host ('win+v       : [!] ' + $winv) }
    Write-Host ('config file : ' + $IniPath + $(if (Test-Path -LiteralPath $IniPath) { '' } else { '   (missing, defaults in effect)' }))
    if (@($script:ConfigProblems).Count -gt 0) {
      Write-Host ('config      : [!] ' + @($script:ConfigProblems).Count + ' value(s) need attention   (clipboard config shows them)')
    }
    $pnames = @()
    if (Get-Command Get-PluginNames -ErrorAction SilentlyContinue) { $pnames = @(Get-PluginNames) }
    if ($pnames.Count -gt 0) { Write-Host ('plugins     : ' + ($pnames -join ', ')) }
    elseif (@($script:PluginList).Count -gt 0) { Write-Host ('plugins     : [!] not found: ' + (@($script:PluginList) -join ',')) }
    else { Write-Host 'plugins     : none (no plugin file found)' }
  }
  'config' {
    $act = ''
    if ($Value) { $act = $Value.ToLower() }
    if ($act -eq 'init') {
      $r = Merge-IniDefaults
      Write-Host ('[ok] ' + $r.Added + ' key(s) added, ' + $r.Pruned + ' unknown key(s) commented out: ' + $IniPath)
      Write-Host '     existing values were kept, plugin settings included (config reset rewrites the file)'
    }
    elseif ($act -eq 'reset') {
      Write-Host ('[ok] template rewritten: ' + (Write-IniTemplate -Force))
      Write-Host '     every value is back to its default'
      Restart-ResidentIfRunning
    }
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
  'export' {
    $r = Invoke-Export $Value -Media:$Media
    if ($r.Ok) { Write-Host ('[ok] ' + $r.Message) } else { Write-Host ('[!] ' + $r.Message) }
  }
  'import' {
    $r = Invoke-Import $Value -Replace:$Replace
    if ($r.Ok) { Write-Host ('[ok] ' + $r.Message) } else { Write-Host ('[!] ' + $r.Message) }
  }
  'backup' {
    $r = Save-Snapshot $Value
    if ($r.Ok) { Write-Host ('[ok] ' + $r.Message) } else { Write-Host ('[!] ' + $r.Message) }
  }
  'restore' {
    $r = Invoke-Restore $Value
    if ($r.Ok) { Write-Host ('[ok] ' + $r.Message) } else { Write-Host ('[!] ' + $r.Message) }
  }
  'install' {
    $pol = 'RemoteSigned'
    if ($Value -and $Value.ToLower() -eq 'bypass') { $pol = 'Bypass' }
    Install-Autostart -Policy $pol
  }
  'uninstall' {
    $doPurge = $Purge -or ($Value -and $Value.ToLower() -eq 'purge')
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

# The one-shot path: assemble, then run. The entry calls this; the resident calls the two
# halves separately, because it assembled once when it started.
function Invoke-Main {
  param(
    [string]$Command = '',
    [string]$Value,
    [string]$Sub,
    [string]$Arg,
    [int]$Count = 0,
    [switch]$Purge,
    [switch]$All,
    [switch]$Media,
    [switch]$Replace
  )
  $Call = @{
    Command = $Command
    Value   = $Value
    Sub     = $Sub
    Arg     = $Arg
    Count   = $Count
    Purge   = [bool]$Purge
    All     = [bool]$All
    Media   = [bool]$Media
    Replace = [bool]$Replace
    Bound   = @($PSBoundParameters.Keys)
  }
  Initialize-Main $Call
  Invoke-Dispatch $Call
}

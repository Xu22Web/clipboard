# lib/usage.ps1 - `clipboard help`: base commands grouped by area, then one group per
# loaded plugin. Plugin commands only ever appear inside their own group.

function Show-Usage {
  # Commands are printed as groups with a sub-list, the same shape `config` uses:
  # base categories first, then one group per loaded plugin. Everything a plugin owns
  # (pin, star, highlight, open, ...) only ever appears in that plugin's group.
  $groups = [ordered]@{
    'daemon'  = @(
      @('serve', 'run the resident daemon (capture + hotkey + tray)'),
      @('stop', 'stop the resident daemon'),
      @('ui', 'open the history picker (starts the daemon if needed)'),
      @('status', 'show daemon state and settings'),
      @('pause', 'pause capture'),
      @('resume', 'resume capture')
    )
    'history' = @(
      @('list [-Count N]', 'list entries, newest first (time + * = pinned)'),
      @('get', 'print the clipboard text'),
      @('put "text"', 'set the clipboard (reads stdin when text is omitted)'),
      @('pick N', 'put entry N back on the clipboard'),
      @('del N', 'delete entry N (a row a mark protects must be unprotected first)'),
      @('clear [-All]', 'delete entries (protected rows always stay, marks may keep more)')
    )
    'config'  = @(
      @('config', 'show every key grouped by base / plugin'),
      @('config get KEY', 'show one key (effective + raw value from clipboard.ini)'),
      @('config set KEY VAL', 'validate and write one key, then reload the resident'),
      @('config edit', 'open clipboard.ini in notepad'),
      @('config init', 'write a full template with all defaults'),
      @('themes', 'list the themes in themes\ and the active one')
    )
    'setup'   = @(
      @('diag', 'probe the environment (run this first)'),
      @('restore', 'try to restore the native Win+V history'),
      @('install [bypass]', 'create the shortcuts (bypass = -ExecutionPolicy Bypass; Autostart / DesktopShortcut pick which)'),
      @('uninstall [purge]', 'remove the shortcuts (purge also deletes data and config)'),
      @('help', 'show this help')
    )
  }

  Write-Host 'clipboard - lightweight clipboard history for Windows 10 / 11'
  Write-Host ''
  Write-Host 'Usage: clipboard <command> [args] [options]'
  foreach ($g in $groups.Keys) {
    Write-Host ''
    Write-Host ('  [' + $g + ']')
    foreach ($row in $groups[$g]) {
      $n = [string]$row[0]
      while ($n.Length -lt 24) { $n = $n + ' ' }
      Write-Host ('    ' + $n + ' ' + [string]$row[1])
    }
  }

  # one group per loaded plugin (description comes from the plugin's CommandHelp)
  $pcmds = @()
  if (Get-Command Get-PluginCommandList -ErrorAction SilentlyContinue) { $pcmds = @(Get-PluginCommandList) }
  $names = @()
  if ($pcmds.Count -gt 0) { $names = @($pcmds | ForEach-Object { $_.Plugin } | Select-Object -Unique) }
  foreach ($pn in $names) {
    Write-Host ''
    Write-Host ('  [plugin: ' + $pn + ']')
    foreach ($c in @($pcmds | Where-Object { $_.Plugin -eq $pn })) {
      $n = [string]$c.Name
      while ($n.Length -lt 24) { $n = $n + ' ' }
      Write-Host ('    ' + $n + ' ' + [string]$c.Summary)
    }
  }

  Write-Host ''
  Write-Host 'Panel keys:'
  Write-Host '  [list]'
  Write-Host '    Enter                paste the selected entry'
  Write-Host '    Ctrl+Enter           copy only, do not inject a paste'
  Write-Host '    Ctrl+1-9 / Ctrl+0    pick one of the visible rows'
  Write-Host '    Del                  delete'
  Write-Host '    Ctrl+Z               undo the last delete'
  Write-Host '    Esc                  clear the search, a second Esc closes'
  $pkeys = @()
  if (Get-Command Get-PluginPanelKeys -ErrorAction SilentlyContinue) { $pkeys = @(Get-PluginPanelKeys) }
  foreach ($pk in $pkeys) {
    $combo = ''
    if ($pk.Shift) { $combo = 'Shift+' }
    if ($pk.Ctrl) { $combo = $combo + 'Ctrl+' }
    if ($pk.Alt) { $combo = $combo + 'Alt+' }
    $combo = $combo + $pk.Key
    $label = $pk.Label
    if (-not $label) { $label = 'plugin action' }
    Write-Host ('    ' + $combo.PadRight(21) + $label + '   (' + $pk.Plugin + ')')
  }
  Write-Host '  [scroll]'
  Write-Host '    PgUp / PgDn          page by one screen'
  Write-Host '    wheel                follow the system setting or ScrollLines='

  Write-Host ''
  Write-Host 'Settings (clipboard.ini only - there are no setting switches):'
  Write-Host '    clipboard config            every key, grouped by base / plugin'
  Write-Host '    clipboard config set K V    validate, write one line, reload the resident'

  Write-Host ''
  Write-Host 'Examples:'
  Write-Host '  clipboard put "hello there"    echo hi | clipboard put    clipboard list -Count 5'
  Write-Host '  clipboard config set Theme win11-light    clipboard config set MaxItems 200'
  Write-Host '  clipboard serve                clipboard ui               clipboard config edit'

  $missing = @()
  if (Get-Command Get-PluginMissingNames -ErrorAction SilentlyContinue) { $missing = @(Get-PluginMissingNames) }
  if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host ('[!] plugin not found: ' + ($missing -join ', ') + '   (check Plugins= and README.md)')
  }
}

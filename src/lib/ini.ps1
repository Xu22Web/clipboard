# lib/ini.ps1 - reading clipboard.ini and the schema every key is validated against.
#
# Read-only by design: this module never creates or rewrites the settings file. Writing
# happens only through `config init` / `config set` (lib/config.ps1) and through
# SaveWindowWidth / SaveWindowPos when the user turns them on.
#
# The schema table is a load-time assignment, so this module is dot-sourced after base.ps1
# and before anything that calls Get-CfgValue / Apply-Config.

# Flat key=value; '#' or ';' comments and [section] lines are ignored. This region only
# reads. Writing happens exclusively through `config init` / `config set`, and through
# SaveWindowWidth / SaveWindowPos when the user explicitly turns them on.
function Read-Ini {
  $h = @{}
  if (-not (Test-Path -LiteralPath $IniPath)) { return $h }
  try {
    foreach ($line in [IO.File]::ReadAllLines($IniPath, [Text.Encoding]::UTF8)) {
      $l = $line.Trim()
      if ($l.Length -eq 0) { continue }
      if ($l.StartsWith('#') -or $l.StartsWith(';') -or $l.StartsWith('[')) { continue }
      $i = $l.IndexOf('=')
      if ($i -lt 1) { continue }
      $k = $l.Substring(0, $i).Trim()
      $v = $l.Substring($i + 1).Trim()
      if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2) }
      $h[$k] = $v
    }
  } catch {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log ('config read failed: ' + $_.Exception.Message) }
  }
  return $h
}

# Every recognised key with its type and accepted range. Apply-Config, Show-Config and
# `config set` all validate through this table so the rules cannot drift apart.
$script:IniSchema = [ordered]@{
  DataDir           = @{ Kind = 'string'; Default = '';            Desc = 'write location, empty = <script dir>\data' }
  Hotkey            = @{ Kind = 'hotkey'; Default = 'Ctrl+Alt+V';  Desc = 'global hotkey' }
  HotkeyFallbacks   = @{ Kind = 'string'; Default = '';            Desc = 'comma separated fallback chain' }
  PasteKeys         = @{ Kind = 'string'; Default = '^v';          Desc = 'SendKeys sent after picking' }
  ModReleaseTimeout = @{ Kind = 'int'; Min = 0; Max = 60000; Default = 1200; Desc = 'ms to wait for the modifiers to be released' }
  PasteSettle       = @{ Kind = 'int'; Min = 0; Max = 10000; Default = 80;   Desc = 'ms to wait before sending PasteKeys' }
  MaxItems          = @{ Kind = 'int'; Min = 1; Max = 100000; Default = 300; Desc = 'entry cap (rows a mark protects are exempt)' }
  MaxBytes          = @{ Kind = 'int'; Min = 1; Max = 104857600; Default = 204800; Desc = 'per entry size cap' }
  MaxTotal          = @{ Kind = 'int'; Min = 1024; Max = 1073741824; Default = 4194304; Desc = 'total store size cap in bytes' }
  Interval          = @{ Kind = 'int'; Min = 50; Max = 60000; Default = 300; Desc = 'clipboard poll interval in ms' }
  NoPaste           = @{ Kind = 'bool'; Default = 0;              Desc = '1 = clipboard only, never inject a paste' }
  Balloon           = @{ Kind = 'bool'; Default = 1;              Desc = '1 = tray balloon on startup' }
  Theme             = @{ Kind = 'theme'; Default = 'win11-dark'; Desc = 'theme name from themes\ (win11-dark / win11-light ...)' }
  ExcludePattern    = @{ Kind = 'regex'; Default = '';            Desc = 'matching text is never saved' }
  WindowWidth       = @{ Kind = 'int'; Min = 460; Max = 4000; Default = 700; Desc = 'panel width (96 dpi baseline)' }
  Rows              = @{ Kind = 'int'; Min = 3; Max = 50; Default = 10; Desc = 'visible rows; the height follows from it (rows x 40 + 110)' }
  WindowLeft        = @{ Kind = 'int'; Min = -32768; Max = 32767; Default = ''; Desc = 'panel left, empty = centred' }
  WindowTop         = @{ Kind = 'int'; Min = -32768; Max = 32767; Default = ''; Desc = 'panel top, empty = centred' }
  SaveWindowWidth   = @{ Kind = 'bool'; Default = 0;              Desc = '1 = write the width you dragged back to this file' }
  SaveWindowPos     = @{ Kind = 'bool'; Default = 0;              Desc = '1 = write the moved panel back to this file' }
  ShowTime          = @{ Kind = 'bool'; Default = 1;              Desc = '1 = relative time column' }
  ShowTypeIcon      = @{ Kind = 'bool'; Default = 1;              Desc = '1 = show the row icon a plugin provides (none without one)' }
  Highlight         = @{ Kind = 'bool'; Default = 1;              Desc = '1 = highlight search matches' }
  HighlightMaxBytes = @{ Kind = 'int'; Min = 0; Max = 1048576; Default = 8192; Desc = 'skip highlight above this size (0 = always)' }
  ShowNewlineMarker = @{ Kind = 'bool'; Default = 1;              Desc = '1 = show <NL> for line breaks, 0 = collapse to a space' }
  Undo              = @{ Kind = 'bool'; Default = 1;              Desc = '1 = Ctrl+Z undoes the last delete' }
  DpiAware          = @{ Kind = 'bool'; Default = 1;              Desc = '1 = per-monitor DPI aware rendering' }
  ScrollLines       = @{ Kind = 'int'; Min = -1; Max = 50; Default = 0; Desc = 'wheel step in rows (0 = follow the system)' }
  Autostart         = @{ Kind = 'bool'; Default = 1;              Desc = '1 = install creates the logon shortcut (serve)' }
  DesktopShortcut   = @{ Kind = 'bool'; Default = 1;              Desc = '1 = install creates the desktop shortcut (ui)' }
  Plugins           = @{ Kind = 'list'; Default = '';             Desc = 'comma separated plugin names to load (empty = base tool only)' }
}

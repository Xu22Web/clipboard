# lib/ini.ps1 - reading clipboard.ini and the schema every key is validated against.
#
# Read-only by design: this module never creates or rewrites the settings file. Writing
# happens only through `config init` / `config set` (lib/config.ps1) and through
# SaveWindowSize / SaveWindowPos when the user turns them on.
#
# The schema table is a load-time assignment, so this module is dot-sourced after base.ps1
# and before anything that calls Get-CfgValue / Apply-Config.

# Flat key=value; '#' or ';' comments and [section] lines are ignored. This region only
# reads. Writing happens exclusively through `config init` / `config set`, and through
# SaveWindowSize / SaveWindowPos when the user explicitly turns them on.
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
  WindowHeight      = @{ Kind = 'int'; Min = 240; Max = 2000; Default = 510; Desc = 'panel height (96 dpi baseline)' }
  WindowLeft        = @{ Kind = 'int'; Min = -32768; Max = 32767; Default = ''; Desc = 'panel left, empty = centred' }
  WindowTop         = @{ Kind = 'int'; Min = -32768; Max = 32767; Default = ''; Desc = 'panel top, empty = centred' }
  SaveWindowSize    = @{ Kind = 'bool'; Default = 0;              Desc = '1 = write the resized panel back to this file' }
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

function Get-IniKey([string]$key) {
  if ($null -eq $script:IniCache) { $script:IniCache = Read-Ini }
  if ($script:IniCache.ContainsKey($key)) { return [string]$script:IniCache[$key] }
  return ''
}

# validate + normalise one raw value; never throws
function Convert-IniValue([string]$key, [string]$raw) {
  if (-not $script:IniSchema.Contains($key)) { return @{ Ok = $false; Value = ''; Error = 'unknown key' } }
  $spec = $script:IniSchema[$key]
  $v = ([string]$raw).Trim()
  if ($spec.Kind -eq 'bool') {
    $l = $v.ToLower()
    if (@('1', 'true', 'on', 'yes') -contains $l) { return @{ Ok = $true; Value = '1'; Error = '' } }
    if (@('0', 'false', 'off', 'no') -contains $l) { return @{ Ok = $true; Value = '0'; Error = '' } }
    return @{ Ok = $false; Value = ''; Error = 'expected 0 or 1' }
  }
  if ($spec.Kind -eq 'int') {
    $n = 0
    if (-not [int]::TryParse($v, [ref]$n)) { return @{ Ok = $false; Value = ''; Error = 'expected an integer' } }
    if ($null -ne $spec.Min -and $n -lt [int]$spec.Min) { return @{ Ok = $false; Value = ''; Error = 'must be >= ' + $spec.Min } }
    if ($null -ne $spec.Max -and $n -gt [int]$spec.Max) { return @{ Ok = $false; Value = ''; Error = 'must be <= ' + $spec.Max } }
    return @{ Ok = $true; Value = [string]$n; Error = '' }
  }
  if ($spec.Kind -eq 'enum') {
    foreach ($o in @($spec.Options)) { if ($o -eq $v.ToLower()) { return @{ Ok = $true; Value = $o; Error = '' } } }
    return @{ Ok = $false; Value = ''; Error = 'expected one of: ' + (@($spec.Options) -join ', ') }
  }
  if ($spec.Kind -eq 'regex') {
    if ($v -eq '') { return @{ Ok = $true; Value = ''; Error = '' } }
    try { [void](New-Object System.Text.RegularExpressions.Regex $v); return @{ Ok = $true; Value = $v; Error = '' } }
    catch { return @{ Ok = $false; Value = ''; Error = 'invalid regular expression' } }
  }
  if ($spec.Kind -eq 'list') {
    $tokens = @($v -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($t in $tokens) {
      if ($t -notmatch '^[A-Za-z0-9_.-]+$') { return @{ Ok = $false; Value = ''; Error = 'plugin names may only use letters, digits, _ . -' } }
    }
    return @{ Ok = $true; Value = ($tokens -join ','); Error = '' }
  }
  if ($spec.Kind -eq 'theme') {
    if ($v -eq '') { return @{ Ok = $true; Value = [string]$spec.Default; Error = '' } }
    $want = if ($v -ieq 'dark') { 'win11-dark' } elseif ($v -ieq 'light') { 'win11-light' } else { $v }
    foreach ($n in @(Get-ThemeNames)) { if ($n -ieq $want) { return @{ Ok = $true; Value = $n; Error = '' } } }
    $have = @(Get-ThemeNames)
    if ($have.Count -eq 0) { return @{ Ok = $true; Value = 'win11-dark'; Error = '' } }
    return @{ Ok = $false; Value = ''; Error = 'unknown theme, available: ' + ($have -join ', ') }
  }
  if ($spec.Kind -eq 'color') {
    if ($v -eq '') { return @{ Ok = $true; Value = ''; Error = '' } }
    if (Get-Command Convert-ThemeColor -ErrorAction SilentlyContinue) {
      if ($null -eq (Convert-ThemeColor $v)) { return @{ Ok = $false; Value = ''; Error = 'expected #RRGGBB or #AARRGGBB' } }
      return @{ Ok = $true; Value = $v.ToUpper(); Error = '' }
    }
    return @{ Ok = $true; Value = $v; Error = '' }
  }
  if ($spec.Kind -eq 'hotkey') {
    if ((Parse-Hotkey $v).Vk -eq 0) { return @{ Ok = $false; Value = ''; Error = 'unknown key name' } }
    return @{ Ok = $true; Value = $v; Error = '' }
  }
  return @{ Ok = $true; Value = $v; Error = '' }
}

# effective value of one key coming from clipboard.ini (null when unset, CLI wins, or invalid)
function Get-CfgValue([string]$key) {
  if ($null -eq $script:IniCache) { $script:IniCache = Read-Ini }
  $c = $script:IniCache
  if (-not $c.ContainsKey($key)) { return $null }
  $raw = [string]$c[$key]
  if ($raw -eq '') { return $null }
  $r = Convert-IniValue $key $raw
  if (-not $r.Ok) { Write-Log ('config ignored: ' + $key + '=' + $raw + ' (' + $r.Error + ')'); return $null }
  return [string]$r.Value
}

# rewrite exactly one key, keeping comments and the rest of the file untouched
function Set-IniKey([string]$key, [string]$value) {
  try {
    $pd = Split-Path -Parent $IniPath
    if ($pd -and -not (Test-Path -LiteralPath $pd)) { New-Item -ItemType Directory -Path $pd -Force | Out-Null }
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $IniPath) {
      foreach ($l in [IO.File]::ReadAllLines($IniPath, [Text.Encoding]::UTF8)) { $lines.Add($l) }
    }
    $done = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match ('^\s*' + [regex]::Escape($key) + '\s*=')) {
        $lines[$i] = $key + '=' + $value
        $done = $true
      }
    }
    if (-not $done) { $lines.Add($key + '=' + $value) }
    $tmp = $IniPath + '.tmp'
    [IO.File]::WriteAllText($tmp, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), $Utf8)
    Move-Item -LiteralPath $tmp -Destination $IniPath -Force
    $script:IniCache = $null
    return $true
  } catch {
    Write-Log ('ini write failed: ' + $_.Exception.Message)
    return $false
  }
}

function Write-IniTemplate([switch]$Force) {
  if ((Test-Path -LiteralPath $IniPath) -and (-not $Force)) { return $IniPath }
  Ensure-Dir
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
    '# dark | light; a theme lives in themes\<name>.ps1 (win11-dark is the default)',
    'Theme=win11-dark',
    '# regex: matching clipboard text is never saved',
    'ExcludePattern=',
    '',
    '# ---- panel geometry (96 dpi baseline, scaled by the system DPI) ----',
    'WindowWidth=700',
    'WindowHeight=510',
    '# empty = centre the panel on the monitor of the window you came from',
    'WindowLeft=',
    'WindowTop=',
    '# 1 = remember the size / position after the panel is closed',
    'SaveWindowSize=0',
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
    '# ---- plugins (optional, see README.md) ----',
    '# comma separated plugin names to load, empty = base tool only (default)',
    '# e.g. Plugins=item-marks,entry-actions',
    # the whole expression needs its own parentheses: inside an array literal a bare
    # `-join ','` turns the comma into an element separator and the line comes out empty
    ('Plugins=' + (@($script:PluginList) -join ','))
  )
  # Settings declared by the loaded plugins, as <plugin>.<Key>. $t is a fixed array, so
  # the extra lines are collected separately and joined at the end.
  $pset = $script:PluginSettings
  if ($null -eq $pset) { $pset = @{} }
  $extra = New-Object System.Collections.Generic.List[string]
  foreach ($pname in @($pset.Keys)) {
    $extra.Add('')
    $extra.Add('# ---- plugin: ' + $pname + ' (only used when listed in Plugins=) ----')
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
  [IO.File]::WriteAllText($IniPath, (($all -join [Environment]::NewLine) + [Environment]::NewLine), $Utf8)
  return $IniPath
}

#Requires -Version 5.1
<#
  clipboard.ps1 - lightweight clipboard history for Windows 10 / 11 (a Win+V replacement).
  Single file, zero dependencies, PowerShell 5.1 + .NET Framework only.

  clipboard diag | restore | serve | ui | config [edit|init] | install | uninstall
  clipboard list [-Count N] | put "text" | get | pick N | del N | clear | pause | resume | status | stop
  Files copied in Explorer are captured too (CF_HDROP) and can be pasted back.

  Settings are not command line switches: every value, including where the history is
  written, lives in clipboard.ini and is changed with `clipboard config set <key> <value>`.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = '',
  [Parameter(Position = 1)][string]$Value,
  [Parameter(Position = 2)][string]$Sub,
  [Parameter(Position = 3)][string]$Arg,
  [int]$Count = 0,
  [switch]$Purge,
  [switch]$All,
  [switch]$Library
)

$ErrorActionPreference = 'Stop'

#region constants
# --- record format: CBHIST2 + RS-separated records: flags US epoch US payload ----
$RS      = [string][char]30
$US      = [string][char]31
$FILESIG = [string][char]1
$V2TAG   = 'CBHIST2'

# --- runtime identities (stable: shortcuts and a second instance rely on them) ----
$MutexName = 'Local\clipboard.daemon'
$EventName = 'Local\clipboard.show'
$StopName  = 'Local\clipboard.stop'
$StoreLock = 'Local\clipboard.store'

# --- UI metrics: 96 dpi design values, every one of them goes through Px() --------
$script:Metric = @{
  RowHeight = 40; HeadHeight = 68; FootHeight = 40
  MinWidth = 520; MinHeight = 320
  Margin = 14; FieldHeight = 40
  RowInset = 6; RowRadius = 4; PanelRadius = 8
  IconSlot = 20; TextGap = 38
  PinSlot = 16; TimeWidth = 52
  CapWidth = 22; CapHeight = 18; BadgeGap = 12
  ScrollIdle = 3; ScrollHot = 6
  ChipHeight = 18
}

# --- glyphs: present in both Segoe Fluent Icons (Win11) and MDL2 (Win10) ----------
$script:Glyphs = @{
  Search  = [string][char]0xE721
  Clear   = [string][char]0xE8BB
  Text    = [string][char]0xE8A5
  Files   = [string][char]0xE8B7
  Pin     = [string][char]0xE718
  History = [string][char]0xE81C
}

# --- timings (ms) ------------------------------------------------------------------
$script:Timing = @{
  Debounce = 150; FootMessage = 3200; Confirm = 5000
  CloseOnBlur = 450; HotkeyPoll = 30; Tooltip = 700
}

$Root = Split-Path -Parent $PSCommandPath
$script:UiScale = 1.0
#endregion

#region defaults
# A missing or partial clipboard.ini is fine: these values apply until the file
# overrides them. Nothing in this region creates or rewrites the settings file.
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
# `install` creates both shortcuts unless one of these is 0
$script:Autostart = $true
$script:DesktopShortcut = $true
# Themes live in themes\<name>.ps1 and are picked by name; win11-dark is the default.
$script:Theme = 'win11-dark'
$script:ThemePalette = $null      # resolved Drawing.Color table, $null = built-in fallback
$script:ThemeFonts = @{}          # Body / Small / Tiny / Title / Icon / IconSmall / IconBig
$script:ThemeFace = @{ Font = ''; Icon = '' }   # optional family overrides from the theme
$script:ThemeOverrides = @{}      # '<plugin>.<Key>' -> default supplied by the theme
$script:ExcludePattern = ''
$script:ShowBalloon = $true
# Runtime knobs: these are settings, and settings only ever come from clipboard.ini
# (`clipboard config set`). A value on the command line is rejected by the param block.
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
# Plugins are opt-in: the list names what to load, and an empty list means "base tool only".
$script:PluginList = @()
$script:Plugins = @()
$script:PluginSettings = @{}
$script:PluginValues = @{}
$script:PluginThemeSpec = @{}
$script:PluginThemeValues = @{}
$script:RecCache = $null
$script:IniCache = $null
#endregion

#region settings file (read only)
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

# Write location: DataDir= in clipboard.ini, else <script dir>\data. Nothing is written
# outside those two folders (no %LOCALAPPDATA% fallback).
$IniPath = Join-Path $Root 'clipboard.ini'
$script:IniCache = Read-Ini
$dataRoot = ''
if ($script:IniCache.ContainsKey('DataDir')) { $dataRoot = [string]$script:IniCache['DataDir'] }
if ($dataRoot) {
  if (-not [IO.Path]::IsPathRooted($dataRoot)) { $dataRoot = Join-Path $Root $dataRoot }
  try {
    $dataRoot = [IO.Path]::GetFullPath($dataRoot).TrimEnd([char]92, [char]47)
    if ($dataRoot -match '^[A-Za-z]:$') { $dataRoot += '\' }
  } catch {
    if ($Library) { return }
    Write-Host ('[x] invalid DataDir: ' + $dataRoot)
    exit 1
  }
}
$StoreDir = if ($dataRoot) { $dataRoot } else { Join-Path $Root 'data' }
# Only the data folder has to be writable; the settings file may live anywhere and is
# never created just because the tool started.
try {
  if (-not (Test-Path -LiteralPath $StoreDir)) { New-Item -ItemType Directory -Path $StoreDir -Force | Out-Null }
  $probe = Join-Path $StoreDir 'p.probe'
  [IO.File]::WriteAllText($probe, 'x')
  Remove-Item -LiteralPath $probe -Force
} catch {
  if ($Library) { return }
  Write-Host ('[x] not writable: ' + $StoreDir)
  Write-Host '    set DataDir=<path> in clipboard.ini to move the write location.'
  Write-Host '    nothing is written to %LOCALAPPDATA% or any other user folder.'
  exit 1
}
$StoreFile = Join-Path $StoreDir 'history.dat'
$Paused    = Join-Path $StoreDir 'paused.flag'
$LogFile   = Join-Path $StoreDir 'clipboard.log'
$Utf8      = New-Object System.Text.UTF8Encoding $false
# which positional arguments were actually passed (an explicit empty value is valid)
$script:BoundParams = $PSBoundParameters
#endregion

try { [Console]::OutputEncoding = $Utf8 } catch { }

#region helpers
function Ensure-Dir {
  if (-not (Test-Path -LiteralPath $StoreDir)) { New-Item -ItemType Directory -Path $StoreDir -Force | Out-Null }
}

function Write-Log([string]$msg) {
  try {
    Ensure-Dir
    if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 65536) {
      Remove-Item -LiteralPath $LogFile -Force
    }
    [IO.File]::AppendAllText($LogFile, ((Get-Date -Format 'MM-dd HH:mm:ss') + ' ' + $msg + [Environment]::NewLine), $Utf8)
  } catch { }
}

function Add-Native {
  if ($script:NativeReady) { return }
  $cs = @'
using System;
using System.Runtime.InteropServices;
namespace Cb {
  public static class Win {
    [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
  }
  public class HotWindow : System.Windows.Forms.NativeWindow {
    public event EventHandler Hot;
    public HotWindow() {
      var cp = new System.Windows.Forms.CreateParams();
      cp.ClassName = "STATIC";
      cp.Caption = "clipboard-hot";
      CreateHandle(cp);
    }
    protected override void WndProc(ref System.Windows.Forms.Message m) {
      if (m.Msg == 0x0312) { var h = Hot; if (h != null) h(this, EventArgs.Empty); return; }
      base.WndProc(ref m);
    }
  }
  public class FluentForm : System.Windows.Forms.Form {
    public FluentForm() { DoubleBuffered = true; }
    protected override System.Windows.Forms.CreateParams CreateParams {
      get { var cp = base.CreateParams; cp.ClassStyle |= 0x00020000; return cp; }
    }
  }
  public class FluentList : System.Windows.Forms.ListBox {
    public FluentList() { DoubleBuffered = true; }
  }
}
'@
  Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms -ErrorAction Stop
  $script:NativeReady = $true
}

function Load-Forms {
  if ($script:FormsReady) { return }
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
  $script:FormsReady = $true
}

function Test-Font([string]$name) {
  try {
    foreach ($f in (New-Object Drawing.Text.InstalledFontCollection).Families) { if ($f.Name -eq $name) { return $true } }
  } catch { }
  return $false
}

# ---------------------------------------------------------------------------- themes
# Theme discovery / validation / loading lives in lib\themes.ps1 (dot-sourced by the
# dispatch region). What stays here: the theme folder, the System.Drawing bootstrap, the
# built-in palette and no-op stubs, so the panel and the CLI still work when that file is
# missing - the tool then simply runs on the built-in palette.
function Get-ThemeDir { return (Join-Path $Root 'themes') }

# Themes are resolved from CLI commands too (config / themes), which never call Load-Forms,
# so System.Drawing has to be available independently of the panel.
function Use-Drawing {
  if ($script:DrawingReady) { return }
  try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch { Write-Log ('System.Drawing unavailable: ' + $_.Exception.Message) }
  $script:DrawingReady = $true
}

# stubs replaced by lib\themes.ps1
function Get-ThemeNames { return @() }
function Resolve-ThemeName([string]$name) {
  if ($name -ieq 'light') { return 'win11-light' }
  return 'win11-dark'
}
function Read-Theme([string]$name) { return $null }
function Apply-Theme { }

# built-in palette = the last known-good Win11 dark look, used when no theme file exists
function Get-BasePalette {
  Use-Drawing
  return @{
    Surface      = [Drawing.Color]::FromArgb(32, 32, 32)
    Field        = [Drawing.Color]::FromArgb(45, 45, 45)
    FieldBorder  = [Drawing.Color]::FromArgb(24, 255, 255, 255)
    Text         = [Drawing.Color]::FromArgb(255, 255, 255)
    Dim          = [Drawing.Color]::FromArgb(170, 170, 170)
    Faint        = [Drawing.Color]::FromArgb(138, 138, 138)
    Accent       = [Drawing.Color]::FromArgb(96, 205, 255)
    AccentSoft   = [Drawing.Color]::FromArgb(30, 96, 205, 255)
    Border       = [Drawing.Color]::FromArgb(22, 255, 255, 255)
    SelBg        = [Drawing.Color]::FromArgb(26, 255, 255, 255)
    HoverBg      = [Drawing.Color]::FromArgb(18, 255, 255, 255)
    BadgeBg      = [Drawing.Color]::FromArgb(16, 255, 255, 255)
    BadgeText    = [Drawing.Color]::FromArgb(200, 200, 200)
    KeyCapBg     = [Drawing.Color]::FromArgb(12, 255, 255, 255)
    KeyCapBorder = [Drawing.Color]::FromArgb(28, 255, 255, 255)
    Pin          = [Drawing.Color]::FromArgb(255, 200, 110)
    Warn         = [Drawing.Color]::FromArgb(255, 153, 164)
  }
}

# the palette the panel draws with
function Get-UiPalette {
  if ($null -ne $script:ThemePalette) { return $script:ThemePalette }
  return (Get-BasePalette)
}

# Opt into system DPI awareness before any window exists, then derive one scale factor
# that every pixel constant in the picker is multiplied by.
function Initialize-Dpi {
  if ($script:DpiReady) { return }
  $script:DpiReady = $true
  $script:UiScale = 1.0
  try {
    if (-not $script:DpiAware) { return }
    Add-Native
    [void][Cb.Win]::SetProcessDPIAware()
    try {
      $d = [int][Cb.Win]::GetDpiForSystem()
      if ($d -ge 96 -and $d -le 480) { $script:UiScale = [double]$d / 96.0 }
    } catch { }
  } catch { $script:UiScale = 1.0 }
}

# scale one design pixel value (96 dpi baseline) to the current DPI
function Px([double]$v) {
  if ($v -eq 0) { return 0 }
  $n = [int][Math]::Round($v * [double]$script:UiScale)
  if ($n -lt 1) { return 1 }
  return $n
}

function Get-Epoch {
  return [long]([DateTime]::UtcNow - [DateTime]'1970-01-01T00:00:00Z').TotalSeconds
}

# compact relative time for the picker rows: now / 5m / 3h / 2d / 10-24
function Get-RelTime([long]$t) {
  if ($t -le 0) { return '' }
  $d = (Get-Epoch) - $t
  if ($d -lt 0) { $d = 0 }
  if ($d -lt 60) { return 'now' }
  if ($d -lt 3600) { return ([string][int]($d / 60)) + 'm' }
  if ($d -lt 86400) { return ([string][int]($d / 3600)) + 'h' }
  if ($d -lt 518400) { return ([string][int]($d / 86400)) + 'd' }
  try { return ([DateTime]'1970-01-01T00:00:00Z').ToLocalTime().AddSeconds($t).ToString('MM-dd') } catch { return '' }
}

function New-RoundPath([int]$x, [int]$y, [int]$w, [int]$h, [int]$r) {
  if ($w -lt 2) { $w = 2 }
  if ($h -lt 2) { $h = 2 }
  if (($r * 2) -gt $h) { $r = [int]($h / 2) }
  if (($r * 2) -gt $w) { $r = [int]($w / 2) }
  $d = [Math]::Max(1, $r * 2)
  $p = New-Object Drawing.Drawing2D.GraphicsPath
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

function New-RoundRegion([int]$w, [int]$h, [int]$r) {
  $p = New-RoundPath 0 0 $w $h $r
  $reg = New-Object Drawing.Region -ArgumentList $p
  $p.Dispose()
  return $reg
}
#endregion

#region clipboard
function Get-Text {
  Load-Forms
  for ($i = 0; $i -lt 10; $i++) {
    try {
      if (-not [Windows.Forms.Clipboard]::ContainsText()) { return '' }
      return [Windows.Forms.Clipboard]::GetText([Windows.Forms.TextDataFormat]::UnicodeText)
    } catch { Start-Sleep -Milliseconds 50 }
  }
  return $null
}

function Set-Text([string]$t) {
  Load-Forms
  for ($i = 0; $i -lt 10; $i++) {
    try {
      [Windows.Forms.Clipboard]::SetText($t, [Windows.Forms.TextDataFormat]::UnicodeText)
      return $true
    } catch { Start-Sleep -Milliseconds 50 }
  }
  return $false
}

# one clipboard item: plain text, or FILESIG + newline-joined paths (CF_HDROP)
function Get-ClipItem {
  Load-Forms
  for ($i = 0; $i -lt 10; $i++) {
    try {
      if ([Windows.Forms.Clipboard]::ContainsFileDropList()) {
        $col = [Windows.Forms.Clipboard]::GetFileDropList()
        if ($null -ne $col -and $col.Count -gt 0) {
          $parts = New-Object System.Collections.Generic.List[string]
          foreach ($p in $col) { $parts.Add($p) }
          return ($FILESIG + ($parts -join "`n"))
        }
      }
      if (-not [Windows.Forms.Clipboard]::ContainsText()) { return '' }
      return [Windows.Forms.Clipboard]::GetText([Windows.Forms.TextDataFormat]::UnicodeText)
    } catch { Start-Sleep -Milliseconds 50 }
  }
  return $null
}

function Set-ClipItem([string]$entry) {
  if ($entry.Length -gt 0 -and $entry[0] -eq [char]1) {
    Load-Forms
    $sc = New-Object System.Collections.Specialized.StringCollection
    foreach ($p in @($entry.Substring(1) -split "`n" | Where-Object { $_ })) { [void]$sc.Add($p) }
    for ($i = 0; $i -lt 10; $i++) {
      try { [Windows.Forms.Clipboard]::SetFileDropList($sc); return $true } catch { Start-Sleep -Milliseconds 50 }
    }
    return $false
  }
  return (Set-Text $entry)
}
#endregion

#region storage (plain text: CBHIST2 + RS-separated records, no JSON)
# One record: <flags> US <epoch seconds> US <payload>
#   flags = 't' (text) or 'f' (file list), plus optional 'p' (pinned) and 's' (starred)
# Starred = favourited: never trimmed, never cleared, delete needs an explicit unstar.
# Only this format is read. A file without the CBHIST2 tag is ignored as unknown.
function New-Record([string]$payload, [long]$time, [bool]$pinned, [bool]$starred = $false) {
  return [pscustomobject]@{ Payload = $payload; Time = $time; Pinned = $pinned; Starred = $starred }
}

function Get-Records {
  # Parsing the whole store is the hottest path (panel open, filter, delete, undo all
  # need it), so the result is cached against the file stamp. Any writer - this process
  # or another one - changes length or last-write time and invalidates it.
  $fi = $null
  try { $fi = Get-Item -LiteralPath $StoreFile -ErrorAction Stop } catch { $script:RecCache = $null; return @() }
  $stamp = [string]$fi.Length + ':' + [string]$fi.LastWriteTimeUtc.Ticks
  if ($null -ne $script:RecCache -and $script:RecCache.Stamp -eq $stamp) { return $script:RecCache.Records }
  $raw = $null
  try { $raw = [IO.File]::ReadAllText($StoreFile, [Text.Encoding]::UTF8) } catch { return @() }
  if ([string]::IsNullOrEmpty($raw)) { $script:RecCache = @{ Stamp = $stamp; Records = @() }; return @() }
  $out = New-Object System.Collections.Generic.List[object]
  try {
    $chunks = @($raw -split [regex]::Escape($RS))
    if ($chunks.Count -eq 0 -or $chunks[0] -cne $V2TAG) {
      if (-not $script:StoreFormatWarned) {
        $script:StoreFormatWarned = $true
        Write-Log ('store ignored: unknown format, only ' + $V2TAG + ' is supported')
      }
      $script:RecCache = @{ Stamp = $stamp; Records = @() }
      return @()
    }
    for ($i = 1; $i -lt $chunks.Count; $i++) {
      $rec = $chunks[$i]
      if ($rec.Length -eq 0) { continue }
      $a = $rec.IndexOf($US)
      if ($a -lt 1) { continue }
      $b = $rec.IndexOf($US, $a + 1)
      if ($b -lt 0) { continue }
      $flags = $rec.Substring(0, $a)
      $tick = [long]0
      [void][long]::TryParse($rec.Substring($a + 1, $b - $a - 1), [ref]$tick)
      $payload = $rec.Substring($b + 1)
      if ($payload.Length -eq 0) { continue }
      $out.Add((New-Record $payload $tick ($flags.IndexOf('p') -ge 0) ($flags.IndexOf('s') -ge 0)))
    }
  } catch { return @() }
  $script:RecCache = @{ Stamp = $stamp; Records = $out.ToArray() }
  return $script:RecCache.Records
}

function Save-Records($records) {
  Ensure-Dir
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append($V2TAG)
  if ($records) {
    foreach ($r in $records) {
      $flags = 't'
      if ($r.Payload.Length -gt 0 -and $r.Payload[0] -eq [char]1) { $flags = 'f' }
      if ($r.Pinned) { $flags = $flags + 'p' }
      if ($r.Starred) { $flags = $flags + 's' }
      [void]$sb.Append($RS).Append($flags).Append($US).Append([string][long]$r.Time).Append($US).Append($r.Payload)
    }
  }
  $tmp = $StoreFile + '.tmp'
  [IO.File]::WriteAllText($tmp, $sb.ToString(), $Utf8)
  Move-Item -LiteralPath $tmp -Destination $StoreFile -Force
  $script:RecCache = $null
}

function Use-StoreLock([scriptblock]$body) {
  $m = New-Object System.Threading.Mutex($false, $StoreLock)
  $held = $false
  try {
    try { $held = $m.WaitOne(3000) } catch { $held = $true }
    & $body
  } finally {
    if ($held) { try { $m.ReleaseMutex() } catch { } }
    $m.Dispose()
  }
}

# pinned entries always sit at the top, each block keeps its own order
function Sort-PinnedFirst($list) {
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($r in $list) { if ($r.Pinned) { $out.Add($r) } }
  foreach ($r in $list) { if (-not $r.Pinned) { $out.Add($r) } }
  return ,$out
}

# enforce MaxItems / MaxTotal in place; pinned and starred entries are never dropped
function Trim-Records($list) {
  if ($list.Count -gt $MaxItems) {
    $over = $list.Count - $MaxItems
    $drop = New-Object System.Collections.Generic.List[object]
    for ($i = $list.Count - 1; $i -ge 0 -and $drop.Count -lt $over; $i--) {
      if (-not $list[$i].Pinned -and -not $list[$i].Starred) { $drop.Add($list[$i]) }
    }
    foreach ($d in $drop) { [void]$list.Remove($d) }
  }
  $total = 0
  $cut = $false
  $keep = New-Object System.Collections.Generic.List[object]
  foreach ($r in $list) {
    if ($cut) { if ($r.Pinned -or $r.Starred) { $keep.Add($r) }; continue }
    $total += $Utf8.GetByteCount($r.Payload)
    if ($total -gt $MaxTotal -and -not $r.Pinned -and -not $r.Starred) { $cut = $true; continue }
    $keep.Add($r)
  }
  $list.Clear()
  foreach ($r in $keep) { $list.Add($r) }
}

function Add-Item([string]$text) {
  if ([string]::IsNullOrWhiteSpace($text)) { return }
  if ($script:ExcludePattern) {
    try { if ($text -match $script:ExcludePattern) { Write-Log 'skip (exclude pattern)'; return } } catch { }
  }
  if ($Utf8.GetByteCount($text) -gt $MaxBytes) { Write-Log ('skip oversize ' + $text.Length); return }
  # RS / US are the record delimiters: a payload carrying them would corrupt the store
  if (($text.IndexOf([char]30) -ge 0) -or ($text.IndexOf([char]31) -ge 0)) {
    $text = $text.Replace([char]30, ' ').Replace([char]31, ' ')
    Write-Log 'sanitized record separators in captured text'
  }
  Use-StoreLock {
    $recs = @(Get-Records)
    if ($recs.Count -gt 0 -and $recs[0].Payload -ceq $text) { return }
    $wasPinned = $false
    $wasStarred = $false
    foreach ($r in $recs) {
      if ($r.Payload -ceq $text) { $wasPinned = [bool]$r.Pinned; $wasStarred = [bool]$r.Starred; break }
    }
    $list = New-Object System.Collections.Generic.List[object]
    $list.Add((New-Record $text (Get-Epoch) $wasPinned $wasStarred))
    foreach ($r in $recs) { if ($r.Payload -cne $text) { $list.Add($r) } }
    $list = Sort-PinnedFirst $list
    Trim-Records $list
    Save-Records $list.ToArray()
  }
}

# Starred entries are protected: Remove-Record refuses unless -Force is given.
function Remove-Record([string]$payload, [switch]$Force) {
  $r = Use-StoreLock {
    $keep = New-Object System.Collections.Generic.List[object]
    $removed = $false
    $blocked = $false
    foreach ($rec in @(Get-Records)) {
      if (-not $removed -and $rec.Payload -ceq $payload) {
        if ($rec.Starred -and -not $Force.IsPresent) { $blocked = $true; $keep.Add($rec); continue }
        $removed = $true
        continue
      }
      $keep.Add($rec)
    }
    if ($removed) { Save-Records $keep.ToArray() }
    if ($blocked) { return 'starred' }
    if ($removed) { return 'removed' }
    return 'missing'
  }
  return [string]$r
}

function Restore-Record($record, [int]$index) {
  Use-StoreLock {
    $recs = New-Object System.Collections.Generic.List[object]
    foreach ($r in @(Get-Records)) {
      if ($r.Payload -ceq $record.Payload) { return }
      $recs.Add($r)
    }
    if ($index -lt 0) { $index = 0 }
    if ($index -gt $recs.Count) { $index = $recs.Count }
    $recs.Insert($index, $record)
    $recs = Sort-PinnedFirst $recs
    Save-Records $recs.ToArray()
  }
}

function Set-Pin([string]$payload, [bool]$on, [int]$maxPins = 0) {
  $r = Use-StoreLock {
    $recs = @(Get-Records)
    $target = $null
    foreach ($rec in $recs) { if ($rec.Payload -ceq $payload) { $target = $rec; break } }
    if ($null -eq $target) { return $false }
    if ([bool]$target.Pinned -eq $on) { return $false }
    $target.Pinned = $on
    if ($on -and $maxPins -gt 0) {
      $pinnedCount = 0
      foreach ($rec in $recs) { if ($rec.Pinned) { $pinnedCount++ } }
      while ($pinnedCount -gt $maxPins) {
        for ($i = $recs.Count - 1; $i -ge 0; $i--) {
          if ($recs[$i].Pinned -and -not [object]::ReferenceEquals($recs[$i], $target)) {
            $recs[$i].Pinned = $false
            $pinnedCount--
            Write-Log ('unpinned oldest entry, pin cap=' + $maxPins)
            break
          }
        }
      }
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($rec in $recs) { $list.Add($rec) }
    $list = Sort-PinnedFirst $list
    Save-Records $list.ToArray()
    return $true
  }
  return [bool]$r
}

# Does `clear` keep pinned rows? A plugin owns that rule (the pin feature does); with no
# plugin loaded nothing can be pinned, so keeping them is the safe default.
function Get-KeepPinnedOnClear {
  if (Get-Command Get-PluginClearKeepsPinned -ErrorAction SilentlyContinue) {
    try {
      $v = Get-PluginClearKeepsPinned
      if ($null -ne $v) { return [bool]$v }
    } catch { }
  }
  return $true
}

function Clear-Store([bool]$keepPinned) {
  Use-StoreLock {
    # starred entries are favourites: clear never removes them, that is the whole point of
    # the flag. Unstar first when they really have to go.
    $keep = New-Object System.Collections.Generic.List[object]
    foreach ($rec in @(Get-Records)) {
      if ($rec.Starred) { $keep.Add($rec); continue }
      if ($keepPinned -and $rec.Pinned) { $keep.Add($rec) }
    }
    Save-Records $keep.ToArray()
  }
}

# favourite toggle: starred entries survive trimming and clearing
function Set-Star([string]$payload, [bool]$on) {
  $r = Use-StoreLock {
    $recs = @(Get-Records)
    $target = $null
    foreach ($rec in $recs) { if ($rec.Payload -ceq $payload) { $target = $rec; break } }
    if ($null -eq $target) { return $false }
    if ([bool]$target.Starred -eq $on) { return $false }
    $target.Starred = $on
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($rec in $recs) { $list.Add($rec) }
    Save-Records $list.ToArray()
    return $true
  }
  return [bool]$r
}

# The base stores the p/s flag and enforces the data protection rules; the verbs, keys and
# menu items come from plugins (PanelKeys / ContextMenu).

# single-line display text for one payload (picker rows and CLI listings)
function Get-ItemLabel([string]$t, [bool]$nlMarker = $true) {
  $one = $t
  if ($one.Length -gt 0 -and $one[0] -eq [char]1) {
    $names = @($one.Substring(1) -split "`n" | Where-Object { $_ } | ForEach-Object { Split-Path -Leaf $_ })
    if ($names.Count -gt 3) { $one = '[files] ' + (($names[0..2]) -join ', ') + ' (+' + ($names.Count - 3) + ')' }
    else { $one = '[files] ' + ($names -join ', ') }
  } else {
    # only the head of a large payload is ever shown, so skip the cleanup work on the
    # rest of a 200 KB entry on every keystroke
    if ($one.Length -gt 4000) { $one = $one.Substring(0, 4000) }
    $one = $one -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ' '
    if ($nlMarker) { $one = $one -replace '\r?\n', ' <NL> ' } else { $one = $one -replace '\r?\n', ' ' }
    $one = $one -replace '\t', ' '
    $one = $one -replace ' {2,}', ' '
    $one = $one.Trim()
  }
  if ($one.Length -gt 2000) { $one = $one.Substring(0, 2000) }
  return $one
}

function Format-Item([string]$t, [int]$max) {
  $one = Get-ItemLabel $t $true
  if ($one.Length -gt $max) { $one = $one.Substring(0, $max) + '...' }
  return $one
}
#endregion

#region hotkey
function Parse-Hotkey([string]$spec) {
  $mods = 0
  $parts = @($spec -split '\+')
  for ($i = 0; $i -lt $parts.Count - 1; $i++) {
    switch ($parts[$i].Trim().ToLower()) {
      'win'   { $mods = $mods -bor 0x0008 }
      'ctrl'  { $mods = $mods -bor 0x0002 }
      'alt'   { $mods = $mods -bor 0x0001 }
      'shift' { $mods = $mods -bor 0x0004 }
    }
  }
  $k = $parts[$parts.Count - 1].Trim().ToUpper()
  $vk = 0
  if ($k.Length -eq 1) { $vk = [int][char]$k }
  elseif ($k -match '^F([1-9]|1[0-9]|2[0-4])$') { $vk = 0x70 + [int]$k.Substring(1) - 1 }
  elseif ($k -eq 'INSERT') { $vk = 0x2D }
  elseif ($k -eq 'DELETE') { $vk = 0x2E }
  elseif ($k -eq 'HOME') { $vk = 0x24 }
  elseif ($k -eq 'END') { $vk = 0x23 }
  elseif ($k -eq 'PGUP') { $vk = 0x21 }
  elseif ($k -eq 'PGDN') { $vk = 0x22 }
  elseif ($k -eq 'SPACE') { $vk = 0x20 }
  return @{ Mods = $mods; Vk = $vk }
}

function Test-Modifiers-Up {
  $m = [int][Windows.Forms.Control]::ModifierKeys
  $win = (([Cb.Win]::GetAsyncKeyState(0x5B) -band 0x8000) -ne 0) -or (([Cb.Win]::GetAsyncKeyState(0x5C) -band 0x8000) -ne 0)
  return (($m -eq 0) -and (-not $win))
}
#endregion

#region picker
# --- pure helpers (no UI dependency, covered by the unit tests) -------------------
function Get-VisibleRowCount([int]$listHeight, [int]$rowHeight) {
  if ($rowHeight -lt 1) { return 1 }
  $n = [int][Math]::Floor($listHeight / $rowHeight)
  if ($n -lt 1) { return 1 }
  return $n
}

# virtual index behind a Ctrl+<digit> press. Digits follow the visible window, not the
# absolute position in the list (uTools style), so they stay stable while scrolling.
function Get-QuickKeyIndex([int]$offset, [int]$topIndex, [int]$count, [int]$rows) {
  if ($offset -lt 0 -or $offset -gt 9) { return -1 }
  if ($rows -gt 0 -and $offset -ge $rows) { return -1 }
  $i = $topIndex + $offset
  if ($i -lt 0 -or $i -ge $count) { return -1 }
  return $i
}

# Where the panel should appear. A saved position is only honoured when the panel still
# lands on a screen; otherwise centre on the monitor of the window we came from.
function Get-PickerBounds([int]$w, [int]$h, [string]$rawLeft, [string]$rawTop, $areas, $fallback) {
  $l = 0
  $t = 0
  $hasL = [int]::TryParse([string]$rawLeft, [ref]$l)
  $hasT = [int]::TryParse([string]$rawTop, [ref]$t)
  if ($hasL -and $hasT -and $areas) {
    foreach ($a in @($areas)) {
      $iw = [Math]::Min($l + $w, $a.Left + $a.Width) - [Math]::Max($l, $a.Left)
      $ih = [Math]::Min($t + $h, $a.Top + $a.Height) - [Math]::Max($t, $a.Top)
      if ($iw -ge 120 -and $ih -ge 60) {
        $cl = [Math]::Max($a.Left, [Math]::Min($l, $a.Left + $a.Width - $w))
        $ct = [Math]::Max($a.Top, [Math]::Min($t, $a.Top + $a.Height - $h))
        return @{ Left = [int]$cl; Top = [int]$ct; Fitted = $false }
      }
    }
  }
  $fx = [int]($fallback.Left + (($fallback.Width - $w) / 2))
  $fy = [int]($fallback.Top + (($fallback.Height - $h) / 3))
  return @{ Left = $fx; Top = $fy; Fitted = $true }
}

# which characters of one label match the search tokens (for the highlight pass)
function Get-HitMarks([string]$text, [string[]]$tokens) {
  $n = $text.Length
  $marks = New-Object 'bool[]' $n
  if ($n -eq 0) { return $marks }
  foreach ($tok in @($tokens)) {
    if (-not $tok) { continue }
    $start = 0
    while ($start -lt $n) {
      $i = $text.IndexOf($tok, $start, [StringComparison]::OrdinalIgnoreCase)
      if ($i -lt 0) { break }
      $end = $i + $tok.Length
      for ($k = $i; $k -lt $end -and $k -lt $n; $k++) { $marks[$k] = $true }
      $start = $end
    }
  }
  return $marks
}

# The base only needs to tell a file list from text: that is all storage, the row glyph and
# the clipboard round trip care about. Richer typing lives in the entry-actions plugin.
function Get-EntryKind([string]$payload) {
  if ([string]::IsNullOrEmpty($payload)) { return 'empty' }
  if ($payload[0] -eq [char]1) { return 'files' }
  return 'text'
}

function Get-TypeGlyph([string]$payload) {
  if ((Get-EntryKind $payload) -eq 'files') { return $script:Glyphs.Files }
  return $script:Glyphs.Text
}

# Row icon: a plugin may answer first, the built-in mapping is always the fallback,
# so the panel keeps working with an empty (or missing) plugins folder.
function Get-RowGlyph([string]$payload) {
  if (Get-Command Get-EntryGlyph -ErrorAction SilentlyContinue) {
    try {
      $g = Get-EntryGlyph $payload
      if ($g) { return [string]$g }
    } catch { }
  }
  return (Get-TypeGlyph $payload)
}

function Show-Picker {
  if ($script:PickerOpen) { return }
  $script:PickerOpen = $true
  try {
    Load-Forms
    Add-Native
    Initialize-Dpi
    if (-not $script:UiFamily) {
      $script:UiFamily = 'Tahoma'
      $wantFace = [string]$script:ThemeFace.Font
      if ($wantFace -and (Test-Font $wantFace)) { $script:UiFamily = $wantFace }
      elseif (Test-Font 'Segoe UI Variable Text') { $script:UiFamily = 'Segoe UI Variable Text' }
      elseif (Test-Font 'Segoe UI') { $script:UiFamily = 'Segoe UI' }
      # Win11 ships Segoe Fluent Icons; Win10 only has Segoe MDL2 Assets
      $wantIcon = [string]$script:ThemeFace.Icon
      $script:IconFamily = ''
      if ($wantIcon -and (Test-Font $wantIcon)) { $script:IconFamily = $wantIcon }
      elseif (Test-Font 'Segoe Fluent Icons') { $script:IconFamily = 'Segoe Fluent Icons' }
      elseif (Test-Font 'Segoe MDL2 Assets') { $script:IconFamily = 'Segoe MDL2 Assets' }
      $script:HasMdl2 = [bool]$script:IconFamily
    }
    $prev = [Cb.Win]::GetForegroundWindow()
    $script:Entries = @(Get-Records)
    if ($script:Entries.Count -eq 0) { Write-Log 'picker: empty (showing hint)' }

    $ui = Get-UiPalette
    if (-not $script:FBody) {
      # Win11 type ramp by default; a theme may override any of the sizes through Fonts.
      $tf = $script:ThemeFonts
      $szBody = 10.5; $szSmall = 9.0; $szTiny = 9.0; $szTitle = 13.0
      $szIcon = 12.0; $szIconSmall = 10.0; $szIconBig = 24.0
      if ($tf.ContainsKey('Body')) { $szBody = [double]$tf['Body'] }
      if ($tf.ContainsKey('Small')) { $szSmall = [double]$tf['Small'] }
      if ($tf.ContainsKey('Tiny')) { $szTiny = [double]$tf['Tiny'] }
      if ($tf.ContainsKey('Title')) { $szTitle = [double]$tf['Title'] }
      if ($tf.ContainsKey('Icon')) { $szIcon = [double]$tf['Icon'] }
      if ($tf.ContainsKey('IconSmall')) { $szIconSmall = [double]$tf['IconSmall'] }
      if ($tf.ContainsKey('IconBig')) { $szIconBig = [double]$tf['IconBig'] }
      $script:FBody = New-Object Drawing.Font($script:UiFamily, [single]$szBody)
      $script:FSmall = New-Object Drawing.Font($script:UiFamily, [single]$szSmall)
      $script:FTiny = New-Object Drawing.Font($script:UiFamily, [single]$szTiny)
      $script:FTitle = New-Object Drawing.Font($script:UiFamily, [single]$szTitle, [Drawing.FontStyle]::Bold)
      if ($script:IconFamily) {
        # 12 pt renders a 16 px glyph, 10 pt a 13 px one, 24 pt the empty-state art
        $script:FIcon = New-Object Drawing.Font($script:IconFamily, [single]$szIcon)
        $script:FIconSmall = New-Object Drawing.Font($script:IconFamily, [single]$szIconSmall)
        $script:FIconBig = New-Object Drawing.Font($script:IconFamily, [single]$szIconBig)
      } else {
        $script:FIcon = $script:FBody
        $script:FIconSmall = $script:FSmall
        $script:FIconBig = $script:FTitle
      }
    }
    $fBody = $script:FBody; $fSmall = $script:FSmall; $fTiny = $script:FTiny
    $fTitle = $script:FTitle; $fIcon = $script:FIcon; $fIconSmall = $script:FIconSmall; $fIconBig = $script:FIconBig
    $script:Hover = -1
    $script:Confirm = $false
    $script:CtrlHeld = $false
    $script:SearchFocus = $false
    $script:FootMode = 'hints'
    $script:FootMsg = ''
    $script:CapturePaused = (Test-Path -LiteralPath $Paused)
    $script:UndoRec = $null
    $script:UndoIdx = 0
    $script:Filtered = @()
    $script:Labels = @()
    $script:Tokens = @()
    # Plugin keys and per-row decoration are resolved once per entry, not per key press / paint.
    $panelKeys = @()
    if (Get-Command Get-PluginPanelKeys -ErrorAction SilentlyContinue) { $panelKeys = @(Get-PluginPanelKeys) }
    $ctrlHints = @($panelKeys | Where-Object { $_.Ctrl -and -not $_.Alt -and -not $_.Shift -and ([string]$_.Key).Length -eq 1 })
    $rowCache = @{}
    function Find-PanelKey([string]$keyName, [bool]$ctrl, [bool]$alt, [bool]$shift) {
      $name = ([string]$keyName).ToUpperInvariant()
      foreach ($k in $panelKeys) {
        if ($k.Key -ne $name) { continue }
        if ([bool]$k.Ctrl -ne $ctrl) { continue }
        if ([bool]$k.Alt -ne $alt) { continue }
        if ([bool]$k.Shift -ne $shift) { continue }
        return $k
      }
      return $null
    }

    $form = New-Object Cb.FluentForm
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'Manual'
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.Text = 'Clipboard history'
    $form.AccessibleName = 'Clipboard history'
    $form.Width = Px $script:WinWidth
    $form.Height = Px $script:WinHeight
    $form.MinimumSize = New-Object Drawing.Size -ArgumentList @((Px 520), (Px 320))
    $form.BackColor = $ui.Surface
    $form.Padding = New-Object Windows.Forms.Padding(1)

    $lst = New-Object Cb.FluentList
    $lst.Dock = 'None'
    $lst.BorderStyle = 'None'
    $lst.IntegralHeight = $false
    $lst.DrawMode = 'OwnerDrawFixed'
    # Win11 list items are 40 px tall
    $lst.ItemHeight = Px 40
    $lst.BackColor = $ui.Surface
    $lst.ForeColor = $ui.Text
    $lst.Font = $fBody
    $lst.HorizontalScrollbar = $false
    $lst.ScrollAlwaysVisible = $false
    $lst.AccessibleName = 'Clipboard entries'

    # The native Win32 scrollbar cannot be themed and ListBox has no property to hide it.
    # So the list lives in a clipping host and is made wider than the host: the scrollbar
    # ends up outside the visible area, while TopIndex scrolling keeps working.
    $listHost = New-Object Windows.Forms.Panel
    $listHost.Dock = 'Fill'
    $listHost.BackColor = $ui.Surface
    $lst.SetBounds(0, 0, 100, 100)
    $listHost.Controls.Add($lst)

    # empty state: a centered Fluent block (glyph + title + hint) drawn over the list
    $script:EmptyGlyph = [string][char]0xE721
    $script:EmptyTitle = ''
    $script:EmptySub = ''
    $empty = New-Object Windows.Forms.Panel
    $empty.Dock = 'Fill'
    $empty.BackColor = $ui.Surface
    $empty.Visible = $false
    $empty.Add_Paint({
        param($s, $e)
        try {
          $g = $e.Graphics
          $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
          $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
          $w = $empty.ClientSize.Width
          $cy = [int]($empty.ClientSize.Height / 2) - (Px 56)
          if ($script:IconFamily) {
            $gb = New-Object Drawing.SolidBrush $ui.Faint
            $gr = New-Object Drawing.RectangleF -ArgumentList @(0, [single]$cy, [single]$w, [single](Px 34))
            $g.DrawString($script:EmptyGlyph, $fIconBig, $gb, $gr, $sfCenter)
            $gb.Dispose()
            $cy = $cy + (Px 36)
          }
          if ($script:EmptyTitle) {
            $tb = New-Object Drawing.SolidBrush $ui.Dim
            $tr = New-Object Drawing.RectangleF -ArgumentList @(0, [single]$cy, [single]$w, [single](Px 26))
            $g.DrawString($script:EmptyTitle, $fTitle, $tb, $tr, $sfCenter)
            $tb.Dispose()
            $cy = $cy + (Px 28)
          }
          if ($script:EmptySub) {
            $sb = New-Object Drawing.SolidBrush $ui.Faint
            $sr = New-Object Drawing.RectangleF -ArgumentList @(0, [single]$cy, [single]$w, [single](Px 22))
            $g.DrawString($script:EmptySub, $fSmall, $sb, $sr, $sfCenter)
            $sb.Dispose()
          }
        } catch { }
      })
    $listHost.Controls.Add($empty)
    $empty.Add_Click({ $txt.Focus() })

    # A thin rounded thumb is painted instead, brightening on hover.
    $sbar = New-Object Windows.Forms.Panel
    $sbar.Dock = 'Right'
    $sbar.Width = Px 10
    $sbar.BackColor = $ui.Surface
    $script:SbTop = 0
    $script:SbLen = 0
    $script:SbDrag = -1
    $script:SbHot = $false

    $foot = New-Object Windows.Forms.Panel
    $foot.Dock = 'Bottom'
    $foot.Height = Px 40
    $foot.BackColor = $ui.Surface

    $footR = New-Object Windows.Forms.Label
    $footR.Dock = 'None'
    $footR.TextAlign = 'MiddleRight'
    $footR.Font = $fSmall
    $footR.ForeColor = $ui.Faint
    $footR.BackColor = $ui.Surface
    $footR.AutoEllipsis = $true
    $footR.Text = ''

    $footL = New-Object Windows.Forms.Panel
    $footL.Dock = 'Fill'
    $footL.BackColor = $ui.Surface

    $foot.Controls.Add($footR)
    $foot.Controls.Add($footL)

    $head = New-Object Windows.Forms.Panel
    $head.Dock = 'Top'
    $head.Height = Px 68
    $head.BackColor = $ui.Surface

    $box = New-Object Windows.Forms.Panel
    $box.SetBounds((Px 14), (Px 14), ($form.ClientSize.Width - (Px 30)), (Px 40))
    $box.BackColor = $ui.Field
    $box.Add_Paint({
        param($s, $e)
        try {
          $g = $e.Graphics
          $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
          $w = $box.ClientSize.Width
          $h = $box.ClientSize.Height
          # 1 px resting border; 2 px accent underline while the field has focus
          $pen = New-Object Drawing.Pen $ui.FieldBorder, 1
          $path = New-RoundPath 0 0 ($w - 1) ($h - 1) (Px 4)
          $g.DrawPath($pen, $path)
          $path.Dispose()
          $pen.Dispose()
          if ($script:SearchFocus) {
            $accentPen = New-Object Drawing.Pen $ui.Accent, (Px 2)
            $g.DrawLine($accentPen, (Px 4), ($h - (Px 2)), ($w - (Px 4)), ($h - (Px 2)))
            $accentPen.Dispose()
          }
        } catch { }
      })

    $icon = New-Object Windows.Forms.Label
    $icon.SetBounds((Px 12), (Px 10), (Px 20), (Px 20))
    $icon.Text = $(if ($script:IconFamily) { [string][char]0xE721 } else { '' })
    $icon.Font = $fIcon
    $icon.ForeColor = $ui.Faint
    $icon.BackColor = $ui.Field
    $icon.TextAlign = 'MiddleCenter'
    $icon.Cursor = 'IBeam'
    $icon.Add_Click({ $txt.Focus() })

    $txt = New-Object Windows.Forms.TextBox
    $txt.BorderStyle = 'None'
    $txt.SetBounds((Px 38), (Px 10), ($box.Width - (Px 80)), (Px 22))
    $txt.BackColor = $ui.Field
    $txt.ForeColor = $ui.Text
    $txt.Font = $fBody
    $txt.AccessibleName = 'Search clipboard history'

    $ph = New-Object Windows.Forms.Label
    $ph.SetBounds((Px 40), (Px 10), ($box.Width - (Px 106)), (Px 22))
    $ph.Text = 'Search clipboard history'
    $ph.Font = $fBody
    $ph.ForeColor = $ui.Faint
    $ph.BackColor = $ui.Field
    $ph.TextAlign = 'MiddleLeft'
    $ph.Cursor = 'IBeam'

    $clr = New-Object Windows.Forms.Label
    $clr.SetBounds(($box.Width - (Px 30)), (Px 10), (Px 20), (Px 22))
    $clr.Text = $(if ($script:IconFamily) { [string][char]0xE8BB } else { 'x' })
    $clr.Font = $fSmall
    $clr.ForeColor = $ui.Dim
    $clr.BackColor = $ui.Field
    $clr.TextAlign = 'MiddleCenter'
    $clr.Cursor = 'Hand'
    $clr.Visible = $false
    $clr.AccessibleName = 'Clear search'
    $clr.Add_MouseEnter({ $clr.ForeColor = $ui.Text })
    $clr.Add_MouseLeave({ $clr.ForeColor = $ui.Dim })

    $line = New-Object Windows.Forms.Panel
    $line.Dock = 'Bottom'
    $line.Height = 1
    $line.BackColor = $ui.Border

    $box.Controls.Add($icon)
    $box.Controls.Add($txt)
    $box.Controls.Add($clr)
    $box.Controls.Add($ph)
    $ph.BringToFront()
    $head.Controls.Add($box)
    $head.Controls.Add($line)

    # drag grip for resizing the borderless panel from the bottom-right corner
    $grip = New-Object Windows.Forms.Panel
    $grip.Size = New-Object Drawing.Size -ArgumentList @((Px 16), (Px 16))
    $grip.BackColor = $ui.Surface
    $grip.Cursor = 'SizeNWSE'

    $form.Controls.Add($listHost)
    $form.Controls.Add($sbar)
    $form.Controls.Add($foot)
    $form.Controls.Add($head)
    $form.Controls.Add($grip)

    # A remembered position wins only when the panel still lands on a screen.
    $areas = @()
    try { foreach ($sc in [Windows.Forms.Screen]::AllScreens) { $areas += $sc.WorkingArea } } catch { }
    $fallback = $null
    try { $fallback = [Windows.Forms.Screen]::FromHandle($prev).WorkingArea } catch { }
    if (-not $fallback) { try { $fallback = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea } catch { } }
    if (-not $fallback) { $fallback = New-Object Drawing.Rectangle -ArgumentList @(0, 0, $form.Width, $form.Height) }
    $pb = Get-PickerBounds $form.Width $form.Height ([string]$script:WinLeft) ([string]$script:WinTop) $areas $fallback
    $form.Left = [int]$pb.Left
    $form.Top = [int]$pb.Top

    function Layout-Chrome {
      try {
        $cw = $form.ClientSize.Width
        $box.SetBounds((Px 14), (Px 14), ($cw - (Px 30)), (Px 40))
        $txt.SetBounds((Px 38), (Px 10), ($box.Width - (Px 80)), (Px 22))
        $ph.SetBounds((Px 40), (Px 10), ($box.Width - (Px 106)), (Px 22))
        $clr.SetBounds(($box.Width - (Px 30)), (Px 10), (Px 20), (Px 22))
        $box.Region = New-RoundRegion $box.Width $box.Height (Px 4)
      } catch { }
      try {
        $grip.SetBounds(($form.ClientSize.Width - (Px 18)), ($form.ClientSize.Height - (Px 18)), (Px 16), (Px 16))
        $grip.BringToFront()
      } catch { }
      try {
        $footR.SetBounds(($foot.ClientSize.Width - (Px 176)), 0, (Px 162), $foot.ClientSize.Height)
      } catch { }
      $footL.Invalidate()
    }

    # shortcut hints as Fluent key chips: [key] action
    function Get-FootHints {
      if ($script:Filtered.Count -eq 0) {
        return @(@('Esc', 'Close'))
      }
      if ($script:CtrlHeld) {
        # 0-9 first, then whatever single-letter keys the plugins claimed (Ctrl+P pin ...)
        $pairs = @(@('0-9', 'Pick'))
        foreach ($pk in @($ctrlHints)) { $pairs += ,@([string]$pk.Key, [string]$pk.Hint) }
        $pairs += ,@('Enter', 'Copy only')
        $pairs += ,@('Z', 'Undo')
        return $pairs
      }
      return @(@('Enter', 'Paste'), @('Ctrl+Enter', 'Copy only'), @('Del', 'Delete'), @('Esc', 'Close'))
    }

    # key caps: rounded chip with a 1 px stroke, action text beside it (Win11 hint style)
    function Draw-KeyChips($g, [int]$x, [int]$cy, $pairs, $keyColor, $actionColor) {
      $chipH = Px 18
      $limit = $footR.Left - (Px 8)
      if ($limit -lt (Px 60)) { $limit = $footL.ClientSize.Width - (Px 8) }
      $big = New-Object Drawing.SizeF -ArgumentList @(1000, 100)
      foreach ($p in @($pairs)) {
        $key = [string]$p[0]
        $act = [string]$p[1]
        $kw = [single]$g.MeasureString($key, $fSmall, $big, $sfSeg).Width
        $aw = [single]$g.MeasureString($act, $fSmall, $big, $sfSeg).Width
        $chipW = [int]($kw + (Px 14))
        if (($x + $chipW + (Px 6) + $aw) -gt $limit) { return }
        $chipY = $cy - [int]($chipH / 2)
        $kp = New-RoundPath $x $chipY $chipW $chipH (Px 4)
        $kb = New-Object Drawing.SolidBrush $ui.KeyCapBg
        $g.FillPath($kb, $kp)
        $kb.Dispose()
        $kpen = New-Object Drawing.Pen $ui.KeyCapBorder, 1
        $g.DrawPath($kpen, $kp)
        $kpen.Dispose()
        $kp.Dispose()
        $kbr = New-Object Drawing.SolidBrush $keyColor
        $kr = New-Object Drawing.RectangleF -ArgumentList @([single]$x, [single]$chipY, [single]$chipW, [single]$chipH)
        $g.DrawString($key, $fSmall, $kbr, $kr, $sfCenter)
        $kbr.Dispose()
        $x = $x + $chipW + (Px 6)
        $ar = New-Object Drawing.RectangleF -ArgumentList @([single]$x, [single]$chipY, [single]$aw, [single]$chipH)
        $abr = New-Object Drawing.SolidBrush $actionColor
        $g.DrawString($act, $fSmall, $abr, $ar, $sfNone)
        $abr.Dispose()
        $x = $x + [int]$aw + (Px 16)
      }
    }

    $footL.Add_Paint({
        param($s, $e)
        try {
          $g = $e.Graphics
          $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
          $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
          $cy = [int]($footL.ClientSize.Height / 2)
          if ($script:FootMode -eq 'confirm') {
            $wb = New-Object Drawing.SolidBrush $ui.Warn
            $wr = New-Object Drawing.RectangleF -ArgumentList @([single](Px 14), 0, [single]($footL.ClientSize.Width - (Px 20)), [single]$footL.ClientSize.Height)
            $g.DrawString($script:FootMsg, $fSmall, $wb, $wr, $sfNone)
            $wb.Dispose()
            return
          }
          if ($script:FootMode -eq 'message') {
            $mb = New-Object Drawing.SolidBrush $ui.Dim
            $mr = New-Object Drawing.RectangleF -ArgumentList @([single](Px 14), 0, [single]($footL.ClientSize.Width - (Px 20)), [single]$footL.ClientSize.Height)
            $g.DrawString($script:FootMsg, $fSmall, $mb, $mr, $sfNone)
            $mb.Dispose()
            return
          }
          Draw-KeyChips $g (Px 14) $cy (Get-FootHints) $ui.Dim $ui.Faint
        } catch { }
      })

    function Restore-Foot {
      try {
        if ($script:Confirm) { return }
        $script:FootMode = 'hints'
        $script:FootMsg = ''
        $footL.Invalidate()
        $count = ([string]$script:Filtered.Count) + ' of ' + ([string]$script:Entries.Count)
        if ($script:CapturePaused) { $count = 'Paused: ' + $count }
        $footR.Text = $count
      } catch { }
    }

    function Set-Foot([string]$msg, [int]$ms) {
      if ($script:Confirm) { return }
      $script:FootMode = 'message'
      $script:FootMsg = $msg
      $footL.Invalidate()
      try {
        $footTimer.Stop()
        if ($ms -gt 0) { $footTimer.Interval = $ms; $footTimer.Start() }
      } catch { }
    }

    function Sync-Placeholder {
      $ph.Visible = ($txt.Text.Length -eq 0)
      $clr.Visible = ($txt.Text.Length -gt 0)
    }

    function Get-Rows {
      return (Get-VisibleRowCount $lst.ClientSize.Height $lst.ItemHeight)
    }

    # one Graphics for text measurement, reused for the lifetime of the panel
    $script:MeasureG = $null
    function Get-MeasureGraphics {
      if ($null -eq $script:MeasureG -or $script:MeasureG.IsDisposed) { $script:MeasureG = $lst.CreateGraphics() }
      return $script:MeasureG
    }

    # ListBox has no VerticalScrollbar property, so the scrollbar is kept just outside the
    # visible area by the clipping host instead.
    function Size-List {
      $w = $listHost.ClientSize.Width
      $h = $listHost.ClientSize.Height
      if ($w -gt 0 -and $h -gt 0) { $lst.SetBounds(0, 0, $w + (Px 40), $h) }
    }

    # recompute thumb geometry from the current TopIndex
    function Sync-Sb {
      $n = $lst.Items.Count
      $vis = Get-Rows
      $h = $sbar.ClientSize.Height
      if ($n -le $vis -or $h -le (Px 12)) { $script:SbLen = 0; $sbar.Invalidate(); return }
      $track = $h - (Px 6)
      $script:SbLen = [Math]::Max((Px 28), [int]($track * $vis / $n))
      $span = $track - $script:SbLen
      $maxTop = $n - $vis
      $t = 0
      if ($maxTop -gt 0 -and $span -gt 0) { $t = [int]($span * $lst.TopIndex / $maxTop) }
      $script:SbTop = (Px 3) + $t
      $sbar.Invalidate()
    }

    # keep the selection inside the visible window so Enter never pastes a row that is
    # scrolled out of sight
    function Keep-SelectionVisible {
      if ($lst.Items.Count -eq 0) { return }
      $vis = Get-Rows
      $top = $lst.TopIndex
      $sel = $lst.SelectedIndex
      if ($sel -lt $top -or $sel -ge ($top + $vis)) {
        $lst.SelectedIndex = [Math]::Min($top, $lst.Items.Count - 1)
      }
    }

    # move the list so the thumb lands at $thumbTop
    function Sb-ScrollTo([int]$thumbTop) {
      if ($script:SbLen -le 0) { return }
      $vis = Get-Rows
      $maxTop = $lst.Items.Count - $vis
      $span = ($sbar.ClientSize.Height - (Px 6)) - $script:SbLen
      if ($maxTop -le 0 -or $span -le 0) { return }
      $i = [int][Math]::Round(($thumbTop - (Px 3)) * $maxTop / $span)
      if ($i -lt 0) { $i = 0 }
      if ($i -gt $maxTop) { $i = $maxTop }
      if ($i -ne $lst.TopIndex) { $lst.TopIndex = $i }
      Keep-SelectionVisible
      Sync-Sb
      $lst.Invalidate()
    }

    function Scroll-By([int]$rows) {
      $maxTop = $lst.Items.Count - (Get-Rows)
      if ($maxTop -le 0) { return }
      $i = $lst.TopIndex + $rows
      if ($i -lt 0) { $i = 0 }
      if ($i -gt $maxTop) { $i = $maxTop }
      if ($i -ne $lst.TopIndex) { $lst.TopIndex = $i }
      Keep-SelectionVisible
      Sync-Sb
      $lst.Invalidate()
    }

    # focus stays in the search box, so wheel events bubble up here instead of the list
    $form.Add_MouseWheel({
        param($s, $e)
        $lines = 0
        try { $lines = [Windows.Forms.SystemInformation]::MouseWheelScrollLines } catch { }
        if ($script:ScrollLines -gt 0) { $step = [int]$script:ScrollLines }
        elseif ($lines -lt 1) { $step = (Get-Rows) }
        else { $step = [int]$lines }
        if ($e.Delta -gt 0) { Scroll-By (-$step) } else { Scroll-By $step }
      })

    $head.Add_MouseDown({
        param($s, $e)
        if ($e.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
        [void][Cb.Win]::ReleaseCapture()
        [void][Cb.Win]::SendMessage($form.Handle, 0xA1, [IntPtr]2, [IntPtr]::Zero)
      })
    $grip.Add_Paint({
        param($s, $e)
        if (-not $script:GripHot) { return }
        try {
          $e.Graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
          $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(120, $ui.Dim)), 1
          $cw = $grip.ClientSize.Width
          $e.Graphics.DrawLine($pen, ($cw - (Px 4)), ($cw - (Px 9)), ($cw - (Px 9)), ($cw - (Px 4)))
          $e.Graphics.DrawLine($pen, ($cw - (Px 4)), ($cw - (Px 13)), ($cw - (Px 13)), ($cw - (Px 4)))
          $pen.Dispose()
        } catch { }
      })
    $grip.Add_MouseEnter({ $script:GripHot = $true; $grip.Invalidate() })
    $grip.Add_MouseLeave({ $script:GripHot = $false; $grip.Invalidate() })
    $grip.Add_MouseDown({
        [void][Cb.Win]::ReleaseCapture()
        [void][Cb.Win]::SendMessage($form.Handle, 0xA1, [IntPtr]0x11, [IntPtr]::Zero)
      })

    $sbar.Add_Paint({
        param($s, $e)
        if ($script:SbLen -le 0) { return }
        $e.Graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $hot = ($script:SbHot -or $script:SbDrag -ge 0)
        $w = Px 3
        $alpha = 110
        if ($hot) { $w = Px 6; $alpha = 190 }
        $x = [int](($sbar.ClientSize.Width - $w) / 2)
        $br = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb($alpha, $ui.Dim))
        $gp = New-RoundPath $x $script:SbTop $w $script:SbLen ([Math]::Max(1, [int]($w / 2)))
        $e.Graphics.FillPath($br, $gp)
        $gp.Dispose()
        $br.Dispose()
      })
    $sbar.Add_MouseEnter({ $script:SbHot = $true; $sbar.Invalidate() })
    $sbar.Add_MouseLeave({ $script:SbHot = $false; $sbar.Invalidate() })
    $sbar.Add_MouseDown({
        param($s, $e)
        if ($script:SbLen -le 0) { return }
        if ($e.Y -ge $script:SbTop -and $e.Y -le ($script:SbTop + $script:SbLen)) {
          $script:SbDrag = $e.Y - $script:SbTop
        } else {
          $script:SbDrag = [int]($script:SbLen / 2)
          Sb-ScrollTo ($e.Y - $script:SbDrag)
        }
        $sbar.Capture = $true
        $sbar.Invalidate()
      })
    $sbar.Add_MouseMove({
        param($s, $e)
        if ($script:SbDrag -lt 0) { return }
        Sb-ScrollTo ($e.Y - $script:SbDrag)
      })
    $sbar.Add_MouseUp({
        $script:SbDrag = -1
        $sbar.Capture = $false
        $sbar.Invalidate()
      })
    $form.Add_Resize({
        if ($form.WindowState -ne [Windows.Forms.FormWindowState]::Normal) { return }
        try { $form.Region = New-RoundRegion $form.ClientSize.Width $form.ClientSize.Height (Px 8) } catch { }
        Layout-Chrome
        Size-List
        Sync-Sb
        $lst.Invalidate()
      })
    $sbar.Add_SizeChanged({ Sync-Sb })
    $listHost.Add_Resize({ Size-List; Sync-Sb })

    function Update-List([string]$q) {
      $lst.BeginUpdate()
      $lst.Items.Clear()
      # entries and their flags may have changed, so the per-row cache starts over
      $rowCache.Clear()
      $tokens = @($q -split '\s+' | Where-Object { $_ })
      $script:Tokens = $tokens
      $res = New-Object System.Collections.Generic.List[object]
      $labs = New-Object System.Collections.Generic.List[string]
      foreach ($rec in $script:Entries) {
        $ok = $true
        if ($tokens.Count -gt 0) {
          foreach ($t in $tokens) {
            if ($rec.Payload.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $ok = $false; break }
          }
        }
        if (-not $ok) { continue }
        $res.Add($rec)
        $labs.Add((Get-ItemLabel $rec.Payload $script:ShowNewlineMarker))
      }
      $script:Filtered = $res.ToArray()
      $script:Labels = $labs.ToArray()
      for ($i = 0; $i -lt $script:Labels.Count; $i++) { [void]$lst.Items.Add($script:Labels[$i]) }
      if ($script:Labels.Count -gt 0) { $lst.SelectedIndex = 0 } else { $lst.SelectedIndex = -1 }
      $lst.TopIndex = 0
      $lst.EndUpdate()
      if ($script:Labels.Count -eq 0) {
        if ($script:Entries.Count -eq 0) {
          $script:EmptyGlyph = $script:Glyphs.History
          $script:EmptyTitle = 'Clipboard history is empty'
          $script:EmptySub = 'Copy something and it will appear here'
        } elseif ($tokens.Count -gt 0) {
          $script:EmptyGlyph = $script:Glyphs.Search
          $script:EmptyTitle = 'No results for "' + $q.Trim() + '"'
          $script:EmptySub = 'Try another keyword, or press Esc to clear the search'
        } else {
          $script:EmptyTitle = ''
          $script:EmptySub = ''
        }
        $empty.Visible = $true
        $empty.BringToFront()
        $empty.Invalidate()
      } else {
        $empty.Visible = $false
      }
      Sync-Placeholder
      $lst.Invalidate()
      Sync-Sb
      Restore-Foot
    }

    function Use-Index([int]$idx, [switch]$NoInject) {
      if ($idx -lt 0 -or $idx -ge $script:Filtered.Count) { return }
      $payload = $script:Filtered[$idx].Payload
      # a plugin may rewrite what gets pasted (text only, upper case, snake case ...)
      if (Get-Command Invoke-PluginTransform -ErrorAction SilentlyContinue) {
        try {
          $t = Invoke-PluginTransform $payload
          if ($null -ne $t -and [string]$t -ne '' -and [string]$t -cne $payload) {
            $payload = [string]$t
            Write-Log ('pasted via transform (' + $payload.Length + ' chars)')
          }
        } catch { Write-Log ('transform skipped: ' + $_.Exception.Message) }
      }
      $form.Hide()
      if ($script:NoPaste -or $NoInject.IsPresent) { [void](Set-ClipItem $payload); $form.Close(); return }
      if (-not (Set-ClipItem $payload)) { Write-Log 'set clipboard failed'; $form.Close(); return }
      $sw = [Diagnostics.Stopwatch]::StartNew()
      while ($sw.ElapsedMilliseconds -lt $script:ModReleaseTimeout) {
        if (Test-Modifiers-Up) { break }
        Start-Sleep -Milliseconds 30
      }
      [void][Cb.Win]::SetForegroundWindow($prev)
      Start-Sleep -Milliseconds $script:PasteSettle
      try { [Windows.Forms.SendKeys]::SendWait($PasteKeys) } catch { Write-Log ('sendkeys fail: ' + $_.Exception.Message) }
      $form.Close()
    }

    function Del-Index([int]$idx) {
      if ($idx -lt 0 -or $idx -ge $script:Filtered.Count) { return }
      $victim = $script:Filtered[$idx]
      $removed = Remove-Record $victim.Payload
      if ($removed -eq 'starred') {
        # the unstar verb belongs to the star plugin, so say what is actually available
        $hasUnstar = $false
        try { if (Get-Command Get-PluginCommand -ErrorAction SilentlyContinue) { $hasUnstar = [bool](Get-PluginCommand 'unstar') } } catch { }
        if ($hasUnstar) { Set-Foot 'Starred entry. Press Ctrl+S to unstar it first' 2600 }
        else { Set-Foot 'Starred entry. Enable the star plugin to unstar it' 2600 }
        return
      }
      if ($removed -eq 'removed') {
        if ($script:UndoOn) { $script:UndoRec = $victim; $script:UndoIdx = $idx }
      }
      $script:Entries = @(Get-Records)
      if ($removed -eq 'removed') { Write-Log ('deleted entry (' + $victim.Payload.Length + ' chars), left ' + $script:Entries.Count) }
      Update-List $txt.Text
      if ($script:Filtered.Count -gt 0) { $lst.SelectedIndex = [Math]::Min($idx, $script:Filtered.Count - 1) }
      if ($script:UndoOn -and $removed -eq 'removed') { Set-Foot 'Deleted. Press Ctrl+Z to undo' 4000 }
    }

    function Undo-Delete {
      if (-not $script:UndoOn) { Set-Foot 'Undo is off. Set Undo=1 in clipboard.ini to enable it' 2200; return }
      if ($null -eq $script:UndoRec) { Set-Foot 'Nothing to undo' 1500; return }
      $rec = $script:UndoRec
      $at = $script:UndoIdx
      $script:UndoRec = $null
      Restore-Record $rec $at
      $script:Entries = @(Get-Records)
      Update-List $txt.Text
      Set-Foot 'Restored to its original position' 2000
    }

    function Cancel-Confirm {
      $confirmTimer.Stop()
      if (-not $script:Confirm) { return }
      $script:Confirm = $false
      Restore-Foot
    }

    function Request-Clear {
      if ($script:Entries.Count -eq 0) { Set-Foot 'Nothing to clear' 1500; return }
      $script:Confirm = $true
      $footTimer.Stop()
      $script:FootMode = 'confirm'
      if (Get-KeepPinnedOnClear) { $script:FootMsg = 'Delete all unpinned entries?   Enter to confirm, Esc to cancel' }
      else { $script:FootMsg = 'Delete the entire history?   Enter to confirm, Esc to cancel' }
      $footL.Invalidate()
      $confirmTimer.Stop()
      $confirmTimer.Start()
    }

    function Clear-All {
      $script:Confirm = $false
      $confirmTimer.Stop()
      Clear-Store (Get-KeepPinnedOnClear)
      $script:Entries = @(Get-Records)
      Update-List $txt.Text
      $starred = 0
      foreach ($r in $script:Entries) { if ($r.Starred) { $starred++ } }
      if ($starred -gt 0) { Set-Foot ('History cleared, ' + $starred + ' starred kept') 2600 }
      else { Set-Foot 'History cleared' 2000 }
    }

    $cm = New-Object Windows.Forms.ContextMenuStrip
    $cm.Font = $fBody
    $cm.ShowImageMargin = $false
    $m1 = $cm.Items.Add('Paste'); $m1.ShortcutKeyDisplayString = 'Enter'
    $m1.Add_Click({ Use-Index $lst.SelectedIndex })
    $m2 = $cm.Items.Add('Copy only'); $m2.ShortcutKeyDisplayString = 'Ctrl+Enter'
    $m2.Add_Click({ Use-Index $lst.SelectedIndex -NoInject })
    $m5 = $cm.Items.Add('Delete'); $m5.ShortcutKeyDisplayString = 'Del'
    $m5.Add_Click({ try { Del-Index $lst.SelectedIndex } catch { } })
    [void]$cm.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $m6 = $cm.Items.Add('Clear history')
    $m6.Add_Click({ Request-Clear })

    # plugin actions: appended after the built-in ones, hidden unless their Test passes
    $pluginItems = New-Object System.Collections.Generic.List[object]
    try {
      if (Get-Command Get-PluginActions -ErrorAction SilentlyContinue) {
        $actions = @(Get-PluginActions)
        if ($actions.Count -gt 0) {
          [void]$cm.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
          foreach ($act in $actions) {
            $lb = $act['Label']
            $text = 'Plugin action'
            if ($lb -isnot [scriptblock] -and $lb) { $text = [string]$lb }
            $item = $cm.Items.Add($text)
            if ($act.ContainsKey('Key')) { $item.ShortcutKeyDisplayString = [string]$act['Key'] }
            $item.Tag = $act
            $item.Add_Click([System.EventHandler]{
                param($sn, $ev)
                try {
                  $a = $sn.Tag
                  if ($null -eq $a -or $lst.SelectedIndex -lt 0) { return }
                  if ($lst.SelectedIndex -ge $script:Filtered.Count) { return }
                  & $a['Invoke'] $script:Filtered[$lst.SelectedIndex]
                  $script:Entries = @(Get-Records)
                  Update-List $txt.Text
                } catch { Write-Log ('plugin action failed: ' + $_.Exception.Message) }
              })
            $pluginItems.Add($item)
          }
        }
      }
    } catch { Write-Log ('plugin menu failed: ' + $_.Exception.Message) }

    # right click acts on the row under the cursor, never on a stale selection
    $cm.Add_Opening({
        try {
          $pt = $lst.PointToClient([Windows.Forms.Cursor]::Position)
          $i = $lst.IndexFromPoint($pt)
          if ($i -ge 0 -and $i -lt $script:Filtered.Count) { $lst.SelectedIndex = $i } else { $lst.SelectedIndex = -1 }
          $has = ($lst.SelectedIndex -ge 0 -and $lst.SelectedIndex -lt $script:Filtered.Count)
          $m1.Enabled = $has
          $m2.Enabled = $has
          $m5.Enabled = $has
          $m6.Enabled = ($script:Entries.Count -gt 0)
          $cur = $null
          if ($has) { $cur = $script:Filtered[$lst.SelectedIndex] }
          foreach ($it in $pluginItems) {
            $show = $false
            if ($null -ne $cur -and (Get-Command Test-PluginAction -ErrorAction SilentlyContinue)) {
              $show = Test-PluginAction $it.Tag $cur
            }
            $it.Visible = $show
            $it.Enabled = $show
            if ($show) {
              # a plugin may compute its label per row: 'Pin to top' / 'Remove pin'
              $lb = $it.Tag['Label']
              if ($lb -is [scriptblock]) { try { $it.Text = [string](& $lb $cur) } catch { } }
            }
          }
        } catch { }
      })
    $lst.ContextMenuStrip = $cm

    $sfEll = New-Object Drawing.StringFormat
    $sfEll.Trimming = [Drawing.StringTrimming]::EllipsisCharacter
    $sfEll.FormatFlags = [Drawing.StringFormatFlags]::NoWrap
    $sfEll.HotkeyPrefix = [Drawing.Text.HotkeyPrefix]::None
    $sfEll.LineAlignment = [Drawing.StringAlignment]::Center

    $sfNone = New-Object Drawing.StringFormat
    $sfNone.Trimming = [Drawing.StringTrimming]::None
    $sfNone.FormatFlags = [Drawing.StringFormatFlags]::NoWrap
    $sfNone.HotkeyPrefix = [Drawing.Text.HotkeyPrefix]::None
    $sfNone.LineAlignment = [Drawing.StringAlignment]::Center

    $sfRight = $sfNone.Clone()
    $sfRight.Alignment = [Drawing.StringAlignment]::Far
    $sfCenter = $sfNone.Clone()
    $sfCenter.Alignment = [Drawing.StringAlignment]::Center

    $sfSeg = [Drawing.StringFormat]::GenericTypographic.Clone()
    $sfSeg.FormatFlags = [Drawing.StringFormatFlags]::NoWrap -bor [Drawing.StringFormatFlags]::MeasureTrailingSpaces
    $sfSeg.HotkeyPrefix = [Drawing.Text.HotkeyPrefix]::None
    $sfSeg.LineAlignment = [Drawing.StringAlignment]::Center

    # draw one label in pieces so the matched tokens can be tinted; the tail is trimmed
    # with an ellipsis once the available width is exhausted
    function Draw-Highlight($g, [string]$text, $rect, [string[]]$tokens, $normal, $hit) {
      $marks = Get-HitMarks $text $tokens
      $x = [single]$rect.X
      $limit = [single]$rect.Right
      $i = 0
      $n = $text.Length
      $big = New-Object Drawing.SizeF -ArgumentList @(100000, 100)
      while ($i -lt $n) {
        $isHit = $marks[$i]
        $j = $i
        while ($j -lt $n -and $marks[$j] -eq $isHit) { $j++ }
        $seg = $text.Substring($i, $j - $i)
        $size = $g.MeasureString($seg, $fBody, $big, $sfSeg)
        $w = [single]$size.Width
        $brush = if ($isHit) { $hit } else { $normal }
        if (($x + $w) -gt $limit) {
          $rem = $limit - $x
          if ($rem -gt (Px 6)) {
            $r2 = New-Object Drawing.RectangleF -ArgumentList @($x, [single]$rect.Y, [single]$rem, [single]$rect.Height)
            $g.DrawString($seg, $fBody, $brush, $r2, $sfEll)
          }
          return
        }
        $r2 = New-Object Drawing.RectangleF -ArgumentList @($x, [single]$rect.Y, [single]($w + (Px 2)), [single]$rect.Height)
        $g.DrawString($seg, $fBody, $brush, $r2, $sfSeg)
        $x = $x + $w
        $i = $j
      }
    }

    $lst.Add_DrawItem({
        param($s, $e)
        if ($lst.IsDisposed) { return }
        if ($e.Index -lt 0) { return }
        $g = $e.Graphics
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $b = $e.Bounds
        $rowW = [Math]::Min($b.Width, $listHost.ClientSize.Width) - (Px 12)
        if ($rowW -lt (Px 60)) { $rowW = Px 60 }
        $r = New-Object Drawing.Rectangle -ArgumentList @(($b.X + (Px 6)), ($b.Y + (Px 2)), $rowW, ($b.Height - (Px 4)))
        $sel = (($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0)
        $isData = ($e.Index -lt $script:Filtered.Count)
        $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        # Fluent rows stay flat at rest; hover / selection are translucent overlays
        if ($sel -or $e.Index -eq $script:Hover) {
          if ($sel) { $fill = $ui.SelBg } else { $fill = $ui.HoverBg }
          $br = New-Object Drawing.SolidBrush $fill
          $gp = New-RoundPath $r.X $r.Y $r.Width $r.Height (Px 4)
          $g.FillPath($br, $gp)
          $gp.Dispose()
          $br.Dispose()
        }
        $label = [string]$lst.Items[$e.Index]
        if (-not $isData) {
          $db = New-Object Drawing.SolidBrush $ui.Faint
          $rr = New-Object Drawing.RectangleF -ArgumentList @([single]($r.X + (Px 10)), [single]$r.Y, [single]($r.Width - (Px 20)), [single]$r.Height)
          $g.DrawString($label, $fBody, $db, $rr, $sfEll)
          $db.Dispose()
          return
        }
        $rec = $script:Filtered[$e.Index]
        # decoration / glyph / byte size are cached per entry: DrawItem runs on every hover
        $row = $rowCache[$rec.Payload]
        if ($null -eq $row) {
          $dec = $null
          if (Get-Command Get-PluginRowDecor -ErrorAction SilentlyContinue) {
            try { $dec = Get-PluginRowDecor $rec } catch { $dec = $null }
          }
          $glyph = ''
          if ($dec -and $dec.Glyph) { $glyph = [string]$dec.Glyph } else { $glyph = Get-RowGlyph $rec.Payload }
          $bytes = 0
          try { $bytes = $Utf8.GetByteCount($rec.Payload) } catch { }
          $row = @{ Decor = $dec; Glyph = $glyph; Bytes = $bytes }
          $rowCache[$rec.Payload] = $row
        }
        $decor = $row.Decor

        # Trailing meta column, fixed for every row so nothing shifts around:
        #   [mark 14] [2] [pin 14] [6] [time 52] [12] [key cap 22] [10]
        $capW = Px 22
        $capH = Px 18
        $capX = $r.Right - (Px 10) - $capW
        $capY = $r.Y + [int](($r.Height - $capH) / 2)
        $timeW = Px 52
        $timeX = $capX - (Px 12) - $timeW
        $pinX = $timeX - (Px 6) - (Px 14)
        $markX = $pinX - (Px 2) - (Px 14)
        $offset = $e.Index - $lst.TopIndex
        $showCap = ($offset -ge 0 -and $offset -le 9 -and $offset -lt (Get-Rows) -and -not $script:Confirm)

        if ($script:ShowTime) {
          $timeBrush = New-Object Drawing.SolidBrush $ui.Faint
          $timeRect = New-Object Drawing.RectangleF -ArgumentList @([single]$timeX, [single]$r.Y, [single]$timeW, [single]$r.Height)
          $g.DrawString((Get-RelTime $rec.Time), $fSmall, $timeBrush, $timeRect, $sfRight)
          $timeBrush.Dispose()
        }
        if ($rec.Pinned) {
          $pinColor = $ui.Pin
          if ($decor -and $decor.PinColor -and (Get-Command Convert-ThemeColor -ErrorAction SilentlyContinue)) {
            $pcc = Convert-ThemeColor $decor.PinColor
            if ($null -ne $pcc) { $pinColor = $pcc }
          }
          $pinBrush = New-Object Drawing.SolidBrush $pinColor
          $pinRect = New-Object Drawing.RectangleF -ArgumentList @([single]$pinX, [single]$r.Y, [single](Px 14), [single]$r.Height)
          $g.DrawString($(if ($script:IconFamily) { [string][char]0xE718 } else { '*' }), $fIconSmall, $pinBrush, $pinRect, $sfCenter)
          $pinBrush.Dispose()
        }
        if ($decor -and $decor.Mark) {
          $markColor = $ui.Pin
          if ($decor.MarkColor -and (Get-Command Convert-ThemeColor -ErrorAction SilentlyContinue)) {
            $mc = Convert-ThemeColor $decor.MarkColor
            if ($null -ne $mc) { $markColor = $mc }
          }
          $markBrush = New-Object Drawing.SolidBrush $markColor
          $markRect = New-Object Drawing.RectangleF -ArgumentList @([single]$markX, [single]$r.Y, [single](Px 14), [single]$r.Height)
          $g.DrawString([string]$decor.Mark, $fIconSmall, $markBrush, $markRect, $sfCenter)
          $markBrush.Dispose()
        }

        if ($decor -and $decor.Emphasis -and -not $sel) {
          $emColor = $ui.Accent
          if ($decor.EmphasisColor -and (Get-Command Convert-ThemeColor -ErrorAction SilentlyContinue)) {
            $ec = Convert-ThemeColor $decor.EmphasisColor
            if ($null -ne $ec) { $emColor = $ec }
          }
          $emBrush = New-Object Drawing.SolidBrush $emColor
          $emPath = New-RoundPath ($r.X + (Px 3)) ($r.Y + (Px 11)) (Px 3) ($r.Height - (Px 22)) (Px 1)
          $g.FillPath($emBrush, $emPath)
          $emPath.Dispose()
          $emBrush.Dispose()
        }

        $textX = $r.X + (Px 12)
        if ($script:ShowTypeIcon -and $script:IconFamily) {
          $glyphColor = $(if ($sel) { $ui.Text } else { $ui.Dim })
          if ($decor -and $decor.GlyphColor -and (Get-Command Convert-ThemeColor -ErrorAction SilentlyContinue)) {
            $gcc = Convert-ThemeColor $decor.GlyphColor
            if ($null -ne $gcc) { $glyphColor = $gcc }
          }
          $glyphBrush = New-Object Drawing.SolidBrush $glyphColor
          $glyphRect = New-Object Drawing.RectangleF -ArgumentList @([single]($r.X + (Px 10)), [single]$r.Y, [single](Px 20), [single]$r.Height)
          $rowGlyph = [string]$row.Glyph
          $g.DrawString($rowGlyph, $fIcon, $glyphBrush, $glyphRect, $sfCenter)
          $glyphBrush.Dispose()
          $textX = $r.X + (Px 38)
        }

        $textW = $markX - (Px 8) - $textX
        if ($textW -lt (Px 20)) { $textW = Px 20 }
        $tr = New-Object Drawing.RectangleF -ArgumentList @([single]$textX, [single]$r.Y, [single]$textW, [single]$r.Height)

        if ($sel) {
          # Win11 selection indicator: short accent pill on the leading edge
          $barBrush = New-Object Drawing.SolidBrush $ui.Accent
          $barPath = New-RoundPath ($r.X + (Px 3)) ($r.Y + (Px 11)) (Px 3) ($r.Height - (Px 22)) (Px 1)
          $g.FillPath($barBrush, $barPath)
          $barPath.Dispose()
          $barBrush.Dispose()
        }

        $tb = New-Object Drawing.SolidBrush $ui.Text
        $hb = New-Object Drawing.SolidBrush $ui.Accent
        $hi = $script:HighlightOn -and $script:Tokens.Count -gt 0 -and ($label.Length -le 400)
        if ($hi -and $script:HighlightMax -gt 0) {
          if ([int]$row.Bytes -gt $script:HighlightMax) { $hi = $false }
        }
        if ($hi) { Draw-Highlight $g $label $tr $script:Tokens $tb $hb }
        else { $g.DrawString($label, $fBody, $tb, $tr, $sfEll) }
        $tb.Dispose()
        $hb.Dispose()

        if ($showCap) {
          # a key cap, not a data badge: neutral by default, accent while Ctrl is held
          $capFill = $ui.KeyCapBg
          $capStroke = $ui.KeyCapBorder
          $capInk = $ui.BadgeText
          if ($script:CtrlHeld) { $capFill = $ui.AccentSoft; $capStroke = $ui.Accent; $capInk = $ui.Accent }
          $capPath = New-RoundPath $capX $capY $capW $capH (Px 4)
          $capBrush = New-Object Drawing.SolidBrush $capFill
          $g.FillPath($capBrush, $capPath)
          $capBrush.Dispose()
          $capPen = New-Object Drawing.Pen $capStroke, 1
          $g.DrawPath($capPen, $capPath)
          $capPen.Dispose()
          $capPath.Dispose()
          $capRect = New-Object Drawing.RectangleF -ArgumentList @([single]$capX, [single]$capY, [single]$capW, [single]$capH)
          $inkBrush = New-Object Drawing.SolidBrush $capInk
          $g.DrawString([string]$offset, $fSmall, $inkBrush, $capRect, $sfCenter)
          $inkBrush.Dispose()
        }
      })
    $tip = New-Object Windows.Forms.ToolTip
    $tip.InitialDelay = 700
    $tip.ReshowDelay = 100
    $tip.AutoPopDelay = 30000
    $lst.Add_SelectedIndexChanged({ if (-not $lst.IsDisposed) { $lst.Invalidate() } })
    $lst.Add_MouseMove({
        param($s, $e)
        if ($lst.IsDisposed) { return }
        $i = $lst.IndexFromPoint($e.Location)
        if ($i -ne $script:Hover) {
          $old = $script:Hover
          $script:Hover = $i
          foreach ($k in @($old, $i)) {
            if ($k -ge 0 -and $k -lt $lst.Items.Count) { $lst.Invalidate($lst.GetItemRectangle($k)) }
          }
          # Win11 shows a tooltip when a row is truncated
          try {
            if ($i -ge 0 -and $i -lt $script:Filtered.Count) {
              $full = [string]$script:Labels[$i]
              $mw = [single](Get-MeasureGraphics).MeasureString($full, $fBody, 100000, $sfSeg).Width
              $avail = [single]($listHost.ClientSize.Width - (Px 168))
              if ($mw -gt $avail -and $full.Length -gt 0) {
                if ($full.Length -gt 800) { $full = $full.Substring(0, 800) + '...' }
                $tip.SetToolTip($lst, $full)
              } else {
                $tip.SetToolTip($lst, '')
              }
            } else {
              $tip.SetToolTip($lst, '')
            }
          } catch { }
        }
      })
    $lst.Add_MouseLeave({
        try { $tip.SetToolTip($lst, '') } catch { }
        if ($lst.IsDisposed) { $script:Hover = -1; return }
        if ($script:Hover -ge 0 -and $script:Hover -lt $lst.Items.Count) { $lst.Invalidate($lst.GetItemRectangle($script:Hover)) }
        $script:Hover = -1
      })
    $lst.Add_DoubleClick({ if ($lst.SelectedIndex -ge 0) { Use-Index $lst.SelectedIndex } })
    $lst.Add_MouseUp({ param($s, $e) if ($e.Button -eq 'Left') { Sync-Sb; $txt.Focus() } })
    # the list can also scroll itself when it owns the focus: keep the painted thumb and
    # the selection in sync when that happens
    $lst.Add_MouseWheel({ Keep-SelectionVisible; Sync-Sb; $lst.Invalidate() })

    $footTimer = New-Object Windows.Forms.Timer
    $footTimer.Interval = 3200
    $footTimer.Add_Tick({ $footTimer.Stop(); Restore-Foot })

    $confirmTimer = New-Object Windows.Forms.Timer
    $confirmTimer.Interval = 5000
    $confirmTimer.Add_Tick({ $confirmTimer.Stop(); $script:Confirm = $false; Restore-Foot })

    $deb = New-Object Windows.Forms.Timer
    $deb.Interval = 150
    $deb.Add_Tick({ $deb.Stop(); Update-List $txt.Text })
    function Flush-List { if ($deb.Enabled) { $deb.Stop(); Update-List $txt.Text } }
    $txt.Add_TextChanged({ Sync-Placeholder; $deb.Stop(); $deb.Start() })
    $txt.Add_GotFocus({ $script:SearchFocus = $true; $box.Invalidate() })
    $txt.Add_LostFocus({ $script:SearchFocus = $false; $box.Invalidate() })
    $clr.Add_Click({ $txt.Text = ''; $txt.Focus() })
    $form.Add_KeyDown({
        param($s, $e)
        $code = [int]$e.KeyCode
        if ($e.Control -and -not $script:CtrlHeld) {
          $script:CtrlHeld = $true
          $lst.Invalidate()
          $footL.Invalidate()
        }
        if ($script:Confirm) {
          if ($e.KeyCode -eq 'Enter') { Clear-All } else { Cancel-Confirm }
          $e.Handled = $true; $e.SuppressKeyPress = $true
          return
        }
        if ($e.Control -and $e.KeyCode -eq 'Enter') {
          Flush-List
          if ($lst.SelectedIndex -ge 0) { Use-Index $lst.SelectedIndex -NoInject } else { Set-Foot 'Nothing to copy' 1500 }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.Control -and (($code -ge 48 -and $code -le 57) -or ($code -ge 96 -and $code -le 105))) {
          $n = $code
          if ($n -ge 96) { $n = $n - 96 } else { $n = $n - 48 }
          Flush-List
          $idx = Get-QuickKeyIndex $n $lst.TopIndex $script:Filtered.Count (Get-Rows)
          if ($idx -ge 0) { Use-Index $idx } else { Set-Foot 'No entry at that number' 1200 }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.Control -and $e.KeyCode -eq 'Z') {
          try { Undo-Delete } catch { Write-Log ('undo failed: ' + $_.Exception.Message) }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($pluginKey = Find-PanelKey ([string]$e.KeyCode) $e.Control $e.Alt $e.Shift) {
          # a key a plugin claimed (PanelKeys): run it on the selected record, then refresh
          Flush-List
          $idx = $lst.SelectedIndex
          if ($idx -ge 0 -and $idx -lt $script:Filtered.Count) {
            $rec = $script:Filtered[$idx]
            $go = $true
            if ($pluginKey.Test) { try { $go = [bool](& $pluginKey.Test $rec) } catch { $go = $false } }
            if ($go) {
              try { & $pluginKey.Invoke $rec } catch { Write-Log ('plugin key failed: ' + $pluginKey.Plugin + ' - ' + $_.Exception.Message) }
              $script:Entries = @(Get-Records)
              Update-List $txt.Text
            }
          }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Home') {
          if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = 0 }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'End') {
          if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = $lst.Items.Count - 1 }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'PageDown') {
          Scroll-By (Get-Rows)
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'PageUp') {
          Scroll-By (-(Get-Rows))
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Up') {
          if ($lst.SelectedIndex -gt 0) { $lst.SelectedIndex-- }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Down') {
          if ($lst.SelectedIndex -lt $lst.Items.Count - 1) { $lst.SelectedIndex++ }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Enter') {
          Flush-List
          if ($lst.SelectedIndex -ge 0) { Use-Index $lst.SelectedIndex } else { Set-Foot 'Nothing to paste' 1500 }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Escape') {
          if ($txt.Text.Length -gt 0) {
            $txt.Text = ''
            Flush-List
          } else {
            $form.Close()
          }
        } elseif ($e.KeyCode -eq 'Delete') {
          Flush-List
          try { Del-Index $lst.SelectedIndex } catch { Write-Log ('delete failed: ' + $_.Exception.Message) }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        }
      })
    $form.Add_KeyUp({
        param($s, $e)
        $held = [bool]$e.Control
        if ($e.KeyCode -eq [Windows.Forms.Keys]::ControlKey -or $e.KeyCode -eq [Windows.Forms.Keys]::RControlKey) { $held = $false }
        if ($held -ne $script:CtrlHeld) {
          $script:CtrlHeld = $held
          $lst.Invalidate()
          $footL.Invalidate()
        }
      })
    $ph.Add_Click({ $txt.Focus() })

    $form.Add_Paint({
        param($s, $e)
        $e.Graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pen = New-Object Drawing.Pen $ui.Border
        $gp = New-RoundPath 0 0 ($form.ClientSize.Width - 1) ($form.ClientSize.Height - 1) (Px 8)
        $e.Graphics.DrawPath($pen, $gp)
        $gp.Dispose()
        $pen.Dispose()
      })
    $form.Add_Shown({
        try { $form.Region = New-RoundRegion $form.ClientSize.Width $form.ClientSize.Height (Px 8) } catch { }
        Layout-Chrome
        Size-List
        Sync-Sb
        Update-List ''
        $form.Activate()
        $txt.Focus()
        Write-Log ('picker: shown ' + $script:Theme + '/' + $script:UiFamily + ' items=' + $script:Entries.Count + ' scale=' + $script:UiScale + ' size=' + $form.Width + 'x' + $form.Height + ' at ' + $form.Left + ',' + $form.Top)
      })

    $script:ShownAt = Get-Date
    $form.Add_Deactivate({
        $script:CtrlHeld = $false
        if (((Get-Date) - $script:ShownAt).TotalMilliseconds -gt 450) { $form.Close() }
      })

    [void]$form.ShowDialog()

    if ($script:SaveWinSize -or $script:SaveWinPos) {
      try {
        if ($script:SaveWinSize) {
          [void](Set-IniKey 'WindowWidth' ([string][int]($form.Width / [double]$script:UiScale)))
          [void](Set-IniKey 'WindowHeight' ([string][int]($form.Height / [double]$script:UiScale)))
        }
        if ($script:SaveWinPos) {
          [void](Set-IniKey 'WindowLeft' ([string]$form.Left))
          [void](Set-IniKey 'WindowTop' ([string]$form.Top))
        }
      } catch { Write-Log ('save window state failed: ' + $_.Exception.Message) }
    }

    $deb.Dispose()
    $footTimer.Dispose()
    $confirmTimer.Dispose()
    $tip.Dispose()
    try { if ($script:MeasureG) { $script:MeasureG.Dispose() } } catch { }
    $script:MeasureG = $null
    $cm.Dispose()
    $form.Dispose()
  } catch {
    Write-Log ('picker error: ' + $_.Exception.Message)
    try {
      $pos = [string]$_.InvocationInfo.PositionMessage
      $pos = ($pos -replace '\s+', ' ').Trim()
      if ($pos.Length -gt 200) { $pos = $pos.Substring(0, 200) }
      Write-Log ('picker at: ' + $pos)
    } catch { }
  } finally {
    $script:PickerOpen = $false
  }
}
#endregion

#region resident daemon
function Start-Serve {
  $created = $false
  $mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$created)
  if (-not $created) {
    try {
      $e = [System.Threading.EventWaitHandle]::OpenExisting($EventName)
      [void]$e.Set()
      Write-Host 'clipboard already running -> asked the running instance to show the picker'
    } catch { Write-Host 'clipboard already running (could not signal it, try: clipboard ui)' }
    return
  }

  $script:StopEvt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $StopName)
  $script:ExitKind = ''
  try {
    Load-Forms
    Add-Native
    try { [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { }
    [Windows.Forms.Application]::add_ThreadException({ param($s, $e) Write-Log ('ui error (ignored): ' + $e.Exception.Message) })

    # supervisor: keep the daemon alive across crashes, back off when it keeps dying
    $round = 0
    $delay = 1000
    while ($true) {
      if ($script:StopEvt.WaitOne(0)) { break }
      $script:ExitKind = ''
      $started = Get-Date
      try { Invoke-ServeOnce } catch { Write-Log ('serve crash: ' + $_.Exception.Message) }
      if ($script:ExitKind) { Write-Log ('serve stop (' + $script:ExitKind + ')'); break }
      if (((Get-Date) - $started).TotalSeconds -gt 60) { $round = 0; $delay = 1000 }
      $round++
      Write-Log ('serve restart #' + $round + ' in ' + $delay + 'ms')
      if ($script:StopEvt.WaitOne($delay)) { break }
      $delay = [Math]::Min($delay * 2, 30000)
    }
  } finally {
    try { if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() } } catch { }
    $script:Tray = $null
    try { [IO.File]::WriteAllText((Join-Path $StoreDir 'hotkey.txt'), '(stopped)', $Utf8) } catch { }
    Write-Log 'supervisor exit'
    try { $script:StopEvt.Dispose() } catch { }
    try { $mutex.ReleaseMutex() } catch { }
    try { $mutex.Dispose() } catch { }
  }
}

function Invoke-ServeOnce {
  $script:PickerOpen = $false
  $evt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $EventName)

  $stored = @(Get-Records)
  if ($MaxItems -ge 1 -and $stored.Count -gt $MaxItems) {
    Use-StoreLock {
      $list = New-Object System.Collections.Generic.List[object]
      foreach ($r in @(Get-Records)) { $list.Add($r) }
      Trim-Records $list
      Save-Records $list.ToArray()
    }
    Write-Log ('trimmed store to ' + $MaxItems + ' (was ' + $stored.Count + ')')
  }

  $hw = New-Object Cb.HotWindow
  $fb = @($script:HotkeyFallbacks -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if ($fb.Count -eq 0) { $fb = @('Ctrl+Alt+V', 'Win+V', 'Alt+`', 'Win+Shift+V') }
  $cands = @(@($Hotkey) + $fb | Select-Object -Unique)
  $script:Hot = ''
  $reg = $false
  foreach ($c in $cands) {
    $p = Parse-Hotkey $c
    if ($p.Vk -eq 0) { continue }
    if ([Cb.Win]::RegisterHotKey($hw.Handle, 1, ($p.Mods -bor 0x4000), $p.Vk)) {
      $script:Hot = $c; $reg = $true; break
    }
    Write-Log ('hotkey registration failed: ' + $c)
  }
  $script:UsePoll = -not $reg
  $script:PrevHotKey = $false
  if (-not $reg) { Write-Log 'all hotkeys rejected, falling back to GetAsyncKeyState polling' }

  # record the hotkey that actually took effect, then surface it in the tray
  $eff = if ($reg) { $script:Hot } else { 'poll:' + $Hotkey }
  try { Ensure-Dir; [IO.File]::WriteAllText((Join-Path $StoreDir 'hotkey.txt'), $eff, $Utf8) } catch { }
  try {
    $script:Tray = New-Object Windows.Forms.NotifyIcon
    $script:Tray.Icon = [Drawing.SystemIcons]::Information
    $script:Tray.Text = 'clipboard - ' + $eff
    $script:Tray.Add_DoubleClick({ try { Show-Picker } catch { } })
    $dm = New-Object Windows.Forms.ContextMenuStrip
    $i1 = $dm.Items.Add('Show history'); $i1.Add_Click({ try { Show-Picker } catch { } })
    $i2 = $dm.Items.Add('Pause capture'); $i2.Add_Click({ Ensure-Dir; New-Item -ItemType File -Path $Paused -Force | Out-Null })
    $i3 = $dm.Items.Add('Resume capture'); $i3.Add_Click({ if (Test-Path -LiteralPath $Paused) { Remove-Item -LiteralPath $Paused -Force } })
    $i4 = $dm.Items.Add('Clear history'); $i4.Add_Click({ Clear-Store (Get-KeepPinnedOnClear) })
    $i5 = $dm.Items.Add('Exit'); $i5.Add_Click({ $script:ExitKind = 'user'; [Windows.Forms.Application]::ExitThread() })
    $script:Tray.ContextMenuStrip = $dm
    $script:Tray.Visible = $true
    if ($script:ShowBalloon) {
      $script:Tray.ShowBalloonTip(5000, 'clipboard is running', ('Hotkey: ' + $eff + '  |  double-click the tray icon for history'), [Windows.Forms.ToolTipIcon]::Info)
    }
  } catch { Write-Log ('tray failed: ' + $_.Exception.Message) }

  $hw.add_Hot({ try { Show-Picker } catch { Write-Log ('hotkey handler: ' + $_.Exception.Message) } })

  $script:LastSeq = [Cb.Win]::GetClipboardSequenceNumber()
  $script:LastText = Get-ClipItem

  $timer = New-Object Windows.Forms.Timer
  $timer.Interval = $Interval
  $timer.Add_Tick({
      if ($script:StopEvt.WaitOne(0)) { $script:ExitKind = 'stop'; [Windows.Forms.Application]::ExitThread(); return }
      if ($evt.WaitOne(0)) { Show-Picker; return }

      # plugin background work (expiry sweeps and the like); throttled inside
      if (Get-Command Invoke-PluginTicks -ErrorAction SilentlyContinue) {
        try { Invoke-PluginTicks } catch { }
      }

      if ($script:UsePoll) {
        $pk = Parse-Hotkey $script:Hot
        $down = (([Cb.Win]::GetAsyncKeyState([int]$pk.Vk) -band 0x8000) -ne 0)
        if ($down -and -not $script:PrevHotKey) { $script:PrevHotKey = $true; Show-Picker; return }
        if (-not $down) { $script:PrevHotKey = $false }
      }

      $seq = [Cb.Win]::GetClipboardSequenceNumber()
      if ($seq -ne 0 -and $seq -eq $script:LastSeq) { return }
      if (Test-Path -LiteralPath $Paused) { return }
      $t = Get-ClipItem
      if ($null -eq $t) { return }
      if ($t -cne $script:LastText) { $script:LastText = $t; Add-Item $t }
      $script:LastSeq = [Cb.Win]::GetClipboardSequenceNumber()
    })
  $timer.Start()

  $shown = if ($reg) { $script:Hot } else { '(not registered, polling ' + $Hotkey + ')' }
  Write-Host ('clipboard resident   hotkey=' + $shown + '   store=' + $StoreFile)
  Write-Log ('serve start hotkey=' + $script:Hot + ' reg=' + $reg)
  try { [Windows.Forms.Application]::Run() }
  catch { Write-Log ('run error: ' + $_.Exception.Message) }
  finally {
    Write-Log 'serve exit'
    try { $timer.Stop() } catch { }
    try { $timer.Dispose() } catch { }
    try { if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() } } catch { }
    $script:Tray = $null
    try { if ($reg) { [void][Cb.Win]::UnregisterHotKey($hw.Handle, 1) } } catch { }
    try { $hw.DestroyHandle() } catch { }
    try { $evt.Dispose() } catch { }
  }
}
#endregion

#region diagnostics / repair
function Invoke-Diag {
  $o = New-Object System.Collections.Generic.List[object]
  function Row([string]$n, $v, [string]$h) { $o.Add([pscustomobject]@{ Check = $n; Result = $v; Hint = $h }) }
  $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
  $svc = @(Get-Service -Name 'cbdhsvc*' -ErrorAction SilentlyContinue)
  $grp = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SVCHOST' -ErrorAction SilentlyContinue).ClipboardSvcGroup
  $cbs = @(Get-ChildItem "$env:SystemRoot\SystemApps" -Filter '*Client.CBS*' -ErrorAction SilentlyContinue)
  Row 'OS' ($cv.ProductName + ' ' + $cv.DisplayVersion + ' build ' + $cv.CurrentBuild) ''
  Row 'PowerShell' $PSVersionTable.PSVersion.ToString() ''
  Row 'Apartment' ([Threading.Thread]::CurrentThread.GetApartmentState()) 'STA required; start via clipboard.cmd'
  try { Load-Forms; Add-Native; Row 'WinForms/Add-Type' 'OK' '' } catch { Row 'WinForms/Add-Type' ('FAIL: ' + $_.Exception.Message) 'picker off, CLI only' }
  Row 'clip.exe' (Test-Path "$env:SystemRoot\System32\clip.exe") 'not needed: clipboard put / Set-Clipboard'
  Row 'Set-Clipboard' ([bool](Get-Command Set-Clipboard -ErrorAction SilentlyContinue)) ''
  Row 'cbdhsvc instance' ($(if ($svc) { ($svc | ForEach-Object { $_.Name + ':' + $_.Status }) -join ',' } else { 'absent' })) 'absent -> clipboard restore'
  Row 'cbdhsvc template' (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\cbdhsvc') 'absent -> component restore'
  Row 'ClipboardSvcGroup' ($(if ($grp) { $grp -join ',' } else { 'absent' })) ''
  Row 'EnableClipboardHistory' (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Clipboard' -Name EnableClipboardHistory -ErrorAction SilentlyContinue).EnableClipboardHistory 'must be 1'
  Row 'Policy AllowClipboardHistory' (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name AllowClipboardHistory -ErrorAction SilentlyContinue).AllowClipboardHistory '0 disables history'
  Row 'SystemApps Client.CBS' ($(if ($cbs) { $cbs[0].Name } else { 'absent' })) 'Win+V panel host'
  Row 'TextInputHost.exe' ([bool](Get-ChildItem "$env:SystemRoot\SystemApps" -Recurse -Filter 'TextInputHost.exe' -ErrorAction SilentlyContinue)) ''
  Row 'Clipboard data dir' (Test-Path "$env:LOCALAPPDATA\Microsoft\Windows\Clipboard") ''
  if ($script:FormsReady) {
    # Never clobber the clipboard just to prove a point: skip when a resident would record
    # the probe text into history, or when the clipboard holds no text to restore.
    $bak = Get-Text
    $residentUp = $false
    try {
      $hm = New-Object System.Threading.Mutex($false, $MutexName)
      if ($hm.WaitOne(0)) { $hm.ReleaseMutex() } else { $residentUp = $true }
      $hm.Dispose()
    } catch { }
    if ($residentUp) {
      Row 'Clipboard write' 'skipped' 'resident is running - the probe would land in the history'
      Row 'Clipboard roundtrip' 'skipped' ''
    } elseif ([string]::IsNullOrEmpty($bak)) {
      Row 'Clipboard write' 'skipped' 'clipboard holds no text - the probe would clobber it'
      Row 'Clipboard roundtrip' 'skipped' ''
    } else {
      $wr = $false; $rt = $false
      try { $wr = Set-Text 'cb-selftest' } catch { }
      if ($wr) { try { $rt = ((Get-Text) -ceq 'cb-selftest') } catch { } }
      try { [void](Set-Text $bak) } catch { }
      Row 'Clipboard write' $wr 'False -> Win32 clipboard gone'
      Row 'Clipboard roundtrip' $rt ''
    }
  }
  foreach ($x in $o) { Write-Host ('[ ] ' + $x.Check + ' = ' + [string]$x.Result + $(if ($x.Hint) { '   <- ' + $x.Hint } else { '' })) }
  Write-Host ''
  Write-Host 'Next: switches missing -> clipboard restore | files missing -> DISM from same-build ISO | else: clipboard install && clipboard serve'
}

function Invoke-Restore {
  $hk = 'HKCU:\SOFTWARE\Microsoft\Clipboard'
  if (-not (Test-Path $hk)) { New-Item -Path $hk -Force | Out-Null }
  New-ItemProperty -Path $hk -Name 'EnableClipboardHistory' -Value 1 -PropertyType DWord -Force | Out-Null
  Write-Host '[ok] EnableClipboardHistory = 1'
  $pp = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
  if (Test-Path $pp) {
    $v = (Get-ItemProperty $pp -Name AllowClipboardHistory -ErrorAction SilentlyContinue).AllowClipboardHistory
    if ($null -ne $v -and $v -eq 0) {
      try { Remove-ItemProperty $pp -Name AllowClipboardHistory -Force -ErrorAction Stop; Write-Host '[ok] policy removed' }
      catch { Write-Host '[!] policy=0 needs admin to remove' }
    }
  }
  $svc = @(Get-Service -Name 'cbdhsvc*' -ErrorAction SilentlyContinue)
  if ($svc) {
    foreach ($s in $svc) {
      try { Set-Service -Name $s.Name -StartupType Manual -ErrorAction Stop; Start-Service -Name $s.Name -ErrorAction Stop; Write-Host ('[ok] ' + $s.Name + ' started') }
      catch { Write-Host ('[!] ' + $s.Name + ': ' + $_.Exception.Message) }
    }
  } else {
    Write-Host ('[x] no cbdhsvc_* instance; template present=' + (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\cbdhsvc'))
  }
  Write-Host 'Now press Win+V; if nothing happens run: clipboard diag'
}
#endregion

#region shortcuts
function Get-AutostartPath {
  return (Join-Path ([Environment]::GetFolderPath('Startup')) 'clipboard.lnk')
}

function Get-DesktopPath {
  return (Join-Path ([Environment]::GetFolderPath('Desktop')) 'clipboard.lnk')
}

function New-ClipLnk([string]$lnk, [string]$verb, [string]$policy) {
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

  # A plain powershell.exe target without a proxy process keeps the shortcut out of the
  # heuristics that flag "shortcut + conhost/rundll32" as Trojan/LNK.Runner.
  # -ExecutionPolicy is required: machines whose effective policy is Restricted or
  # AllSigned would refuse to run the script. RemoteSigned is enough for a local unsigned
  # file and is the Windows default value, so it scores lower than Bypass.
  $ws = New-Object -ComObject WScript.Shell
  $s = $ws.CreateShortcut($lnk)
  $s.TargetPath = $ps
  $s.Arguments = '-NoProfile -ExecutionPolicy ' + $policy + ' -Sta -WindowStyle Hidden -File "' + (Join-Path $Root 'clipboard.ps1') + '" ' + $verb
  $s.WorkingDirectory = $Root
  $s.WindowStyle = 7
  $s.Description = 'clipboard history'
  $s.Save()
  return $lnk
}

function Install-Autostart([string]$Policy = 'RemoteSigned') {
  if (-not $Policy) { $Policy = 'RemoteSigned' }
  if ($script:Autostart) {
    try {
      Write-Host ('[ok] startup : ' + (New-ClipLnk (Get-AutostartPath) 'serve' $Policy) + '   (silent daemon at logon)')
    } catch { Write-Host ('[!] startup shortcut failed: ' + $_.Exception.Message) }
  } else { Write-Host '[i] startup : skipped (Autostart=0)' }

  if ($script:DesktopShortcut) {
    try {
      Write-Host ('[ok] desktop : ' + (New-ClipLnk (Get-DesktopPath) 'ui' $Policy) + '   (double-click = history)')
    } catch { Write-Host ('[!] desktop shortcut failed: ' + $_.Exception.Message) }
  } else { Write-Host '[i] desktop : skipped (DesktopShortcut=0)' }

  if (-not ($script:Autostart -or $script:DesktopShortcut)) {
    Write-Host '     both shortcuts are off; set Autostart=1 / DesktopShortcut=1 to create them'
    return
  }
  Write-Host ('     policy  : -ExecutionPolicy ' + $Policy)
  if ($Policy -ne 'Bypass') {
    Write-Host '     if the shortcut still reports "running scripts is disabled", run:'
    Write-Host '       clipboard install bypass'
    Write-Host '     (or unblock the file first: Unblock-File .\clipboard.ps1)'
  }

  $eff = [string](Get-ExecutionPolicy)
  if (@('Restricted', 'AllSigned') -contains $eff) {
    Write-Host ('     note    : this machine evaluates scripts as ' + $eff + '; the shortcut overrides it with -ExecutionPolicy ' + $Policy)
  }
  $gpo = @('MachinePolicy', 'UserPolicy') | Where-Object { [string](Get-ExecutionPolicy -Scope $_) -ne 'Undefined' }
  if ($gpo) {
    Write-Host ('[!] group policy defines the execution policy (' + ($gpo -join ', ') + '); the -ExecutionPolicy switch is ignored there')
  }
  Write-Host ('tip: add ' + $Root + ' to PATH to call clipboard directly')
}

function Remove-Autostart([switch]$Purge) {
  $removed = 0
  foreach ($t in @((Get-AutostartPath), (Get-DesktopPath))) {
    if (Test-Path -LiteralPath $t) {
      try { Remove-Item -LiteralPath $t -Force; Write-Host ('[ok] removed ' + $t); $removed++ }
      catch { Write-Host ('[!] could not remove ' + $t + ': ' + $_.Exception.Message) }
    }
  }
  if ($removed -eq 0) { Write-Host 'no shortcut found (startup / desktop)' }

  if ($Purge) {
    if (Test-Path -LiteralPath $IniPath) {
      try { Remove-Item -LiteralPath $IniPath -Force; Write-Host ('[ok] removed ' + $IniPath) } catch { Write-Host ('[!] could not remove ' + $IniPath) }
    }
    if ((Test-Path -LiteralPath $StoreDir) -and ($StoreDir -ne $Root)) {
      try { Remove-Item -LiteralPath $StoreDir -Recurse -Force; Write-Host ('[ok] removed ' + $StoreDir) } catch { Write-Host ('[!] could not remove ' + $StoreDir) }
    }
    Write-Host '[ok] history, config and logs deleted'
  } else {
    Write-Host ('kept: ' + $StoreDir + '   ' + $IniPath)
    Write-Host 'run: clipboard uninstall purge   to delete history, config and logs too'
  }

  $alive = $false
  try {
    $m = New-Object System.Threading.Mutex($false, $MutexName)
    if ($m.WaitOne(0)) { $m.ReleaseMutex() } else { $alive = $true }
    $m.Dispose()
  } catch { }
  if ($alive) { Write-Host 'note: the resident is still running - clipboard stop' }
}
#endregion

#region config file
# Every recognised key with its type and accepted range. Apply-Config, Show-Config and
# `config set` all validate through this table so the rules cannot drift apart.
$script:IniSchema = [ordered]@{
  DataDir           = @{ Kind = 'string'; Default = '';            Desc = 'write location, empty = <script dir>\data' }
  Hotkey            = @{ Kind = 'hotkey'; Default = 'Ctrl+Alt+V';  Desc = 'global hotkey' }
  HotkeyFallbacks   = @{ Kind = 'string'; Default = '';            Desc = 'comma separated fallback chain' }
  PasteKeys         = @{ Kind = 'string'; Default = '^v';          Desc = 'SendKeys sent after picking' }
  ModReleaseTimeout = @{ Kind = 'int'; Min = 0; Max = 60000; Default = 1200; Desc = 'ms to wait for the modifiers to be released' }
  PasteSettle       = @{ Kind = 'int'; Min = 0; Max = 10000; Default = 80;   Desc = 'ms to wait before sending PasteKeys' }
  MaxItems          = @{ Kind = 'int'; Min = 1; Max = 100000; Default = 300; Desc = 'entry cap (pinned entries are exempt)' }
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
  ShowTypeIcon      = @{ Kind = 'bool'; Default = 1;              Desc = '1 = per entry type icon' }
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
    '# 1 = per entry type icon (file / link / code / multiline)',
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

function Show-Usage {
  # Commands are printed as groups with a sub-list, the same shape `config` uses:
  # base categories first, then one group per loaded plugin. Pin / star are a plugin
  # feature (item-marks), so they only ever appear in that plugin's group.
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
      @('del N', 'delete entry N (a starred row must be unstarred first)'),
      @('clear [-All]', 'delete entries (pinned survive unless -All, starred always stay)')
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
  Write-Host '    Ctrl+0..9            pick one of the visible rows'
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
#endregion

#region dispatch
# The plugin runtime and the theme loader are optional: a missing lib\plugins.ps1 or
# lib\themes.ps1 must never stop the base tool from running (built-in palette + base only).
$themeModule = Join-Path $Root 'lib\themes.ps1'
if (Test-Path -LiteralPath $themeModule) { . $themeModule }
$pluginModule = Join-Path $Root 'lib\plugins.ps1'
if (Test-Path -LiteralPath $pluginModule) { . $pluginModule }
if ($Library) { return }   # dot-source mode: expose the functions only, run nothing
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
    for ($i = 0; $i -lt $n; $i++) {
      $rt = Get-RelTime $recs[$i].Time
      if (-not $rt) { $rt = '-' }
      $pin = ' '
      if ($recs[$i].Pinned) { $pin = '*' }
      Write-Host ('{0,3}  {1,-5} {2} {3}' -f ($i + 1), $rt, $pin, (Format-Item $recs[$i].Payload 100))
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
    if ($res -eq 'starred') {
      # the unstar verb belongs to the item-marks plugin, so say what is actually available
      if (Get-PluginCommand 'unstar') { Write-Host ('[!] starred entry, unstar it first: clipboard unstar ' + $i) }
      else { Write-Host '[!] starred entry, enable the star plugin to unstar it' }
      break
    }
    if ($res -eq 'removed') { Write-Host ('deleted: ' + (Format-Item $victim.Payload 60) + '   left ' + @(Get-Records).Count) }
    else { Write-Host 'index out of range' }
  }
  'clear' {
    $keep = Get-KeepPinnedOnClear
    if ($All.IsPresent) { $keep = $false }
    Clear-Store $keep
    $left = @(Get-Records)
    $starred = 0
    foreach ($r in $left) { if ($r.Starred) { $starred++ } }
    if ($starred -gt 0) { Write-Host ('[ok] history cleared, ' + $starred + ' starred kept (unstar to remove them)') }
    elseif ($keep -and $left.Count -gt 0) { Write-Host ('[ok] history cleared, ' + $left.Count + ' pinned kept (clear -All removes them)') }
    elseif ($keep) { Write-Host '[ok] history cleared' }
    else { Write-Host '[ok] history cleared, pinned included' }
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
    $pinCount = 0
    $starCount = 0
    foreach ($r in $recs) {
      if ($r.Pinned) { $pinCount++ }
      if ($r.Starred) { $starCount++ }
    }
    Write-Host ('entries     : ' + $recs.Count + ' / ' + $MaxItems + '   pinned ' + $pinCount + '   starred ' + $starCount)
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
#endregion

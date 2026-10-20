#Requires -Version 5.1
<#
  clipboard.ps1 - lightweight clipboard history for trimmed/offline Windows 10 (Win+V replacement).
  Single file, zero dependencies, PowerShell 5.1 + .NET Framework only.

  clipboard diag | restore | serve | ui | config [edit|init] | install | uninstall
  clipboard list [-Count N] | put "text" | get | pick N | del N | clear | pause | resume | status | stop
  Files copied in Explorer are captured too (CF_HDROP) and can be pasted back.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = '',
  [Parameter(Position = 1)][string]$Value,
  [int]$Count = 0,
  [string]$Hotkey = 'Ctrl+Alt+V',
  [string]$PasteKeys = '^v',
  [int]$MaxItems = 300,
  [int]$MaxBytes = 204800,
  [int]$MaxTotal = 4194304,
  [int]$Interval = 300,
  [string]$HotkeyFallbacks = '',
  [int]$ModReleaseTimeout = 1200,
  [int]$PasteSettle = 80,
  [switch]$NoPaste,
  [switch]$Purge,
  [string]$DataDir,
  [switch]$Library
)

$ErrorActionPreference = 'Stop'
$RS        = [string][char]30
$FILESIG   = [string][char]1
$Root      = Split-Path -Parent $PSCommandPath

# Write location, highest priority first:
#   1. -DataDir <path>      CLI switch
#   2. DataDir=<path>       in clipboard.ini next to the script
#   3. <script dir>\data    default
# Nothing is ever written outside these folders (no %LOCALAPPDATA% fallback).
$IniPath = if ($DataDir) { Join-Path ([IO.Path]::GetFullPath($DataDir)) 'clipboard.ini' } else { Join-Path $Root 'clipboard.ini' }
if (-not $DataDir -and (Test-Path -LiteralPath $IniPath)) {
  try {
    foreach ($line in [IO.File]::ReadAllLines($IniPath, [Text.Encoding]::UTF8)) {
      if ($line -match '^\s*DataDir\s*=\s*(.*)$') {
        $v = $Matches[1].Trim().Trim('"')
        if ($v) { $DataDir = $v }
        break
      }
    }
  } catch { }
}
if ($DataDir) {
  if (-not [IO.Path]::IsPathRooted($DataDir)) { $DataDir = Join-Path $Root $DataDir }
  try {
    $DataDir = [IO.Path]::GetFullPath($DataDir).TrimEnd([char]92, [char]47)
    if ($DataDir -match '^[A-Za-z]:$') { $DataDir += '\' }
  } catch {
    if ($Library) { return }
    Write-Host ('[x] invalid DataDir: ' + $DataDir)
    exit 1
  }
}
$StoreDir = if ($DataDir) { $DataDir } else { Join-Path $Root 'data' }
try {
  foreach ($d in (@($StoreDir, (Split-Path -Parent $IniPath)) | Select-Object -Unique)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $probe = Join-Path $d 'p.probe'
    [IO.File]::WriteAllText($probe, 'x')
    Remove-Item -LiteralPath $probe -Force
  }
} catch {
  if ($Library) { return }
  Write-Host ('[x] not writable: ' + $StoreDir)
  Write-Host '    set DataDir=<path> in clipboard.ini, or pass -DataDir <path>, to move the write location.'
  Write-Host '    nothing is written to %LOCALAPPDATA% or any other user folder.'
  exit 1
}
$StoreFile = Join-Path $StoreDir 'history.dat'
$Paused    = Join-Path $StoreDir 'paused.flag'
$LogFile   = Join-Path $StoreDir 'clipboard.log'
$MutexName = 'Local\clipboard.daemon'
$EventName = 'Local\clipboard.show'
$Utf8      = New-Object System.Text.UTF8Encoding $false
$script:CliParams = $PSBoundParameters

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

function Get-UiPalette {
  if ($script:Theme -eq 'light') {
    return @{
      Surface = [Drawing.Color]::FromArgb(249, 249, 249); Field = [Drawing.Color]::White
      Text    = [Drawing.Color]::FromArgb(26, 26, 26);    Dim   = [Drawing.Color]::FromArgb(96, 96, 96)
      Accent  = [Drawing.Color]::FromArgb(0, 95, 184);    Border = [Drawing.Color]::FromArgb(222, 222, 222)
      SelBg   = [Drawing.Color]::FromArgb(228, 240, 252); HoverBg = [Drawing.Color]::FromArgb(240, 240, 240)
    }
  }
  return @{
    Surface = [Drawing.Color]::FromArgb(32, 32, 36);    Field = [Drawing.Color]::FromArgb(46, 46, 52)
    Text    = [Drawing.Color]::FromArgb(240, 240, 243); Dim   = [Drawing.Color]::FromArgb(150, 150, 158)
    Accent  = [Drawing.Color]::FromArgb(96, 205, 255);  Border = [Drawing.Color]::FromArgb(58, 58, 64)
    SelBg   = [Drawing.Color]::FromArgb(42, 58, 72);    HoverBg = [Drawing.Color]::FromArgb(42, 42, 48)
  }
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

#region storage (RS-separated plain text, no JSON)
function Get-Items {
  if (-not (Test-Path -LiteralPath $StoreFile)) { return @() }
  try {
    $raw = [IO.File]::ReadAllText($StoreFile, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrEmpty($raw)) { return @() }
    return @($raw -split [regex]::Escape($RS) | Where-Object { $_.Length -gt 0 })
  } catch { return @() }
}

function Save-Items([string[]]$items) {
  Ensure-Dir
  $tmp = $StoreFile + '.tmp'
  [IO.File]::WriteAllText($tmp, ($items -join $RS), $Utf8)
  Move-Item -LiteralPath $tmp -Destination $StoreFile -Force
}

function Use-StoreLock([scriptblock]$body) {
  $m = New-Object System.Threading.Mutex($false, 'Local\clipboard.store')
  $held = $false
  try {
    try { $held = $m.WaitOne(3000) } catch { $held = $true }
    & $body
  } finally {
    if ($held) { try { $m.ReleaseMutex() } catch { } }
    $m.Dispose()
  }
}

function Add-Item([string]$text) {
  if ([string]::IsNullOrWhiteSpace($text)) { return }
  if ($script:ExcludePattern) {
    try { if ($text -match $script:ExcludePattern) { Write-Log 'skip (exclude pattern)'; return } } catch { }
  }
  if ($Utf8.GetByteCount($text) -gt $MaxBytes) { Write-Log ('skip oversize ' + $text.Length); return }
  Use-StoreLock {
    $items = @(Get-Items)
    if ($items.Count -gt 0 -and $items[0] -ceq $text) { return }
    $list = New-Object System.Collections.Generic.List[string]
    $list.Add($text)
    foreach ($it in $items) { if ($it -cne $text) { $list.Add($it) } }
    while ($list.Count -gt $MaxItems) { $list.RemoveAt($list.Count - 1) }
    $total = 0
    for ($i = 0; $i -lt $list.Count; $i++) {
      $total += $Utf8.GetByteCount($list[$i])
      if ($total -gt $MaxTotal) { $list.RemoveRange($i, $list.Count - $i); break }
    }
    Save-Items $list.ToArray()
  }
}

function Format-Item([string]$t, [int]$max) {
  if ($t.Length -gt 0 -and $t[0] -eq [char]1) {
    $names = @($t.Substring(1) -split "`n" | Where-Object { $_ } | ForEach-Object { Split-Path -Leaf $_ })
    $one = '[files] ' + ($names -join ', ')
  } else {
    $one = $t -replace '\r?\n', ' <NL> '
  }
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
function Show-Picker {
  if ($script:PickerOpen) { return }
  $script:PickerOpen = $true
  try {
    Load-Forms
    Add-Native
    if (-not $script:UiFamily) {
      $script:UiFamily = 'Tahoma'
      if (Test-Font 'Segoe UI Variable Text') { $script:UiFamily = 'Segoe UI Variable Text' }
      elseif (Test-Font 'Segoe UI') { $script:UiFamily = 'Segoe UI' }
      $script:HasMdl2 = Test-Font 'Segoe MDL2 Assets'
    }
    $prev = [Cb.Win]::GetForegroundWindow()
    $script:All = @(Get-Items)
    if ($script:All.Count -eq 0) { Write-Log 'picker: empty (showing hint)' }

    $ui = Get-UiPalette
    if (-not $script:FBody) {
      $script:FBody = New-Object Drawing.Font($script:UiFamily, 10)
      $script:FSmall = New-Object Drawing.Font($script:UiFamily, 8.5)
      $script:FIcon = if ($script:HasMdl2) { New-Object Drawing.Font('Segoe MDL2 Assets', 10) } else { $script:FBody }
    }
    $fBody = $script:FBody; $fSmall = $script:FSmall; $fIcon = $script:FIcon
    $script:Hover = -1

    $form = New-Object Cb.FluentForm
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'Manual'
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.Width = 660
    $form.Height = 430
    $form.BackColor = $ui.Surface
    $form.Padding = New-Object Windows.Forms.Padding(1)

    $lst = New-Object Cb.FluentList
    $lst.Dock = 'None'
    $lst.BorderStyle = 'None'
    $lst.IntegralHeight = $false
    $lst.DrawMode = 'OwnerDrawFixed'
    $lst.ItemHeight = 40
    $lst.BackColor = $ui.Surface
    $lst.ForeColor = $ui.Text
    $lst.Font = $fBody
    $lst.HorizontalScrollbar = $false
    $lst.ScrollAlwaysVisible = $false

    # The native Win32 scrollbar cannot be themed and ListBox has no property to hide it.
    # So the list lives in a clipping host and is made wider than the host: the scrollbar
    # ends up outside the visible area, while TopIndex scrolling keeps working.
    $listHost = New-Object Windows.Forms.Panel
    $listHost.Dock = 'Fill'
    $listHost.BackColor = $ui.Surface
    $lst.SetBounds(0, 0, 100, 100)
    $listHost.Controls.Add($lst)

    # A thin rounded thumb is painted instead, brightening on hover.
    $sbar = New-Object Windows.Forms.Panel
    $sbar.Dock = 'Right'
    $sbar.Width = 10
    $sbar.BackColor = $ui.Surface
    $script:SbTop = 0
    $script:SbLen = 0
    $script:SbDrag = -1
    $script:SbHot = $false

    $foot = New-Object Windows.Forms.Label
    $foot.Dock = 'Bottom'
    $foot.Height = 30
    $foot.TextAlign = 'MiddleLeft'
    $foot.Padding = New-Object Windows.Forms.Padding(14, 0, 0, 0)
    $foot.Font = $fSmall
    $foot.ForeColor = $ui.Dim
    $foot.BackColor = $ui.Surface
    $foot.Text = 'Enter  paste        Esc  close        Ctrl+1..9  quick pick        Del  remove'

    $head = New-Object Windows.Forms.Panel
    $head.Dock = 'Top'
    $head.Height = 58
    $head.BackColor = $ui.Surface

    $box = New-Object Windows.Forms.Panel
    $box.SetBounds(12, 11, 634, 36)
    $box.BackColor = $ui.Field
    $box.Region = New-RoundRegion 634 36 6

    $icon = New-Object Windows.Forms.Label
    $icon.SetBounds(10, 8, 20, 20)
    $icon.Text = $(if ($script:HasMdl2) { [string][char]0xE721 } else { '' })
    $icon.Font = $fIcon
    $icon.ForeColor = $ui.Dim
    $icon.BackColor = $ui.Field
    $icon.TextAlign = 'MiddleCenter'

    $txt = New-Object Windows.Forms.TextBox
    $txt.BorderStyle = 'None'
    $txt.SetBounds(34, 9, 588, 20)
    $txt.BackColor = $ui.Field
    $txt.ForeColor = $ui.Text
    $txt.Font = $fBody

    $ph = New-Object Windows.Forms.Label
    $ph.SetBounds(36, 9, 400, 20)
    $ph.Text = 'Search history...'
    $ph.Font = $fBody
    $ph.ForeColor = $ui.Dim
    $ph.BackColor = $ui.Field
    $ph.TextAlign = 'MiddleLeft'
    $ph.Cursor = 'IBeam'

    $line = New-Object Windows.Forms.Panel
    $line.Dock = 'Bottom'
    $line.Height = 1
    $line.BackColor = $ui.Border

    $box.Controls.Add($icon)
    $box.Controls.Add($txt)
    $box.Controls.Add($ph)
    $ph.BringToFront()
    $head.Controls.Add($box)
    $head.Controls.Add($line)

    $form.Controls.Add($listHost)
    $form.Controls.Add($sbar)
    $form.Controls.Add($foot)
    $form.Controls.Add($head)

    $scr = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $form.Left = $scr.Left + [int](($scr.Width - $form.Width) / 2)
    $form.Top = $scr.Top + [int](($scr.Height - $form.Height) / 3)
    $script:Filtered = @()

    function Sync-Placeholder {
      if ($txt.Text.Length -eq 0) { $ph.Visible = $true } else { $ph.Visible = $false }
    }

    function Get-Rows {
      return [Math]::Max(1, [int][Math]::Floor($lst.ClientSize.Height / $lst.ItemHeight))
    }

    # ListBox has no VerticalScrollbar property, so the scrollbar is kept just outside the
    # visible area by the clipping host instead.
    function Size-List {
      $w = $listHost.ClientSize.Width
      $h = $listHost.ClientSize.Height
      if ($w -gt 0 -and $h -gt 0) { $lst.SetBounds(0, 0, $w + 40, $h) }
    }

    # recompute thumb geometry from the current TopIndex
    function Sync-Sb {
      $n = $lst.Items.Count
      $vis = Get-Rows
      $h = $sbar.ClientSize.Height
      if ($n -le $vis -or $h -le 12) { $script:SbLen = 0; $sbar.Invalidate(); return }
      $track = $h - 6
      $script:SbLen = [Math]::Max(28, [int]($track * $vis / $n))
      $span = $track - $script:SbLen
      $maxTop = $n - $vis
      $t = 0
      if ($maxTop -gt 0 -and $span -gt 0) { $t = [int]($span * $lst.TopIndex / $maxTop) }
      $script:SbTop = 3 + $t
      $sbar.Invalidate()
    }

    # move the list so the thumb lands at $thumbTop
    function Sb-ScrollTo([int]$thumbTop) {
      if ($script:SbLen -le 0) { return }
      $vis = Get-Rows
      $maxTop = $lst.Items.Count - $vis
      $span = ($sbar.ClientSize.Height - 6) - $script:SbLen
      if ($maxTop -le 0 -or $span -le 0) { return }
      $i = [int][Math]::Round(($thumbTop - 3) * $maxTop / $span)
      if ($i -lt 0) { $i = 0 }
      if ($i -gt $maxTop) { $i = $maxTop }
      if ($i -ne $lst.TopIndex) { $lst.TopIndex = $i; $lst.Invalidate() }
      Sync-Sb
    }

    function Scroll-By([int]$rows) {
      $maxTop = $lst.Items.Count - (Get-Rows)
      if ($maxTop -le 0) { return }
      $i = $lst.TopIndex + $rows
      if ($i -lt 0) { $i = 0 }
      if ($i -gt $maxTop) { $i = $maxTop }
      if ($i -ne $lst.TopIndex) { $lst.TopIndex = $i; $lst.Invalidate() }
      Sync-Sb
    }

    # focus stays in the search box, so wheel events bubble up here instead of the list
    $form.Add_MouseWheel({ param($s, $e) if ($e.Delta -gt 0) { Scroll-By (-3) } else { Scroll-By 3 } })

    $sbar.Add_Paint({
        param($s, $e)
        if ($script:SbLen -le 0) { return }
        $e.Graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $alpha = if ($script:SbHot -or $script:SbDrag -ge 0) { 190 } else { 110 }
        $br = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb($alpha, $ui.Dim))
        $gp = New-RoundPath 3 $script:SbTop 4 $script:SbLen 2
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
    $form.Add_Resize({ Size-List; Sync-Sb })
    $sbar.Add_SizeChanged({ Sync-Sb })
    $listHost.Add_Resize({ Size-List; Sync-Sb })

    function Update-List([string]$q) {
      $lst.BeginUpdate()
      $lst.Items.Clear()
      $tokens = @($q -split '\s+' | Where-Object { $_ })
      $res = New-Object System.Collections.Generic.List[string]
      foreach ($it in $script:All) {
        $ok = $true
        foreach ($t in $tokens) {
          if ($it.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $ok = $false; break }
        }
        if (-not $ok) { continue }
        $res.Add($it)
        [void]$lst.Items.Add((Format-Item $it 96))
      }
      $script:Filtered = $res.ToArray()
      if ($res.Count -eq 0) {
        if ($script:All.Count -eq 0) { [void]$lst.Items.Add('history is empty - copy some text, then open again') }
        elseif ($tokens.Count -gt 0) { [void]$lst.Items.Add('no match') }
        $lst.SelectedIndex = -1
      } else {
        $lst.SelectedIndex = 0
      }
      $lst.EndUpdate()
      Sync-Placeholder
      Sync-Sb
    }

    function Use-Index([int]$idx) {
      if ($idx -lt 0 -or $idx -ge $script:Filtered.Count) { return }
      $text = $script:Filtered[$idx]
      $form.Hide()
      if ($NoPaste) { [void](Set-ClipItem $text); $form.Close(); return }
      if (-not (Set-ClipItem $text)) { Write-Log 'set clipboard failed'; $form.Close(); return }
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
      Use-StoreLock {
        $keep = New-Object System.Collections.Generic.List[string]
        foreach ($it in @(Get-Items)) { if ($it -cne $victim) { $keep.Add($it) } }
        Save-Items $keep.ToArray()
      }
      $script:All = @(Get-Items)
      Write-Log ('deleted entry ' + ($idx + 1) + ', left ' + $script:All.Count)
      Update-List $txt.Text
      if ($script:Filtered.Count -gt 0) { $lst.SelectedIndex = [Math]::Min($idx, $script:Filtered.Count - 1) }
    }

    $cm = New-Object Windows.Forms.ContextMenuStrip
    $m1 = $cm.Items.Add('Delete entry'); $m1.Add_Click({ try { Del-Index $lst.SelectedIndex } catch { } })
    $m2 = $cm.Items.Add('Paste'); $m2.Add_Click({ Use-Index $lst.SelectedIndex })
    $m3 = $cm.Items.Add('Clear all'); $m3.Add_Click({ Use-StoreLock { Save-Items @() }; $script:All = @(); Update-List $txt.Text })
    $lst.ContextMenuStrip = $cm

    $lst.Add_DrawItem({
        param($s, $e)
        if ($lst.IsDisposed) { return }
        if ($e.Index -lt 0) { return }
        $g = $e.Graphics
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $b = $e.Bounds
        $rowW = [Math]::Min($b.Width, $listHost.ClientSize.Width) - 14
        if ($rowW -lt 10) { $rowW = 10 }
        $r = New-Object Drawing.Rectangle -ArgumentList @(($b.X + 6), ($b.Y + 2), $rowW, ($b.Height - 4))
        $sel = (($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0)
        if ($sel) { $fill = $ui.SelBg } elseif ($e.Index -eq $script:Hover) { $fill = $ui.HoverBg } else { $fill = $ui.Surface }
        $br = New-Object Drawing.SolidBrush $fill
        $gp = New-RoundPath $r.X $r.Y $r.Width $r.Height 4
        $g.FillPath($br, $gp)
        $gp.Dispose()
        $br.Dispose()
        $label = $lst.Items[$e.Index].ToString()
        if ($e.Index -lt $script:Filtered.Count) {
          $nb = New-Object Drawing.SolidBrush ($(if ($sel) { $ui.Accent } else { $ui.Dim }))
          $g.DrawString([string]($e.Index + 1), $fSmall, $nb, [single]($r.X + 10), [single]($r.Y + 12))
          $nb.Dispose()
          $tb = New-Object Drawing.SolidBrush $ui.Text
          $g.DrawString($label, $fBody, $tb, [single]($r.X + 34), [single]($r.Y + 9))
          $tb.Dispose()
        } else {
          $db = New-Object Drawing.SolidBrush $ui.Dim
          $g.DrawString($label, $fBody, $db, [single]($r.X + 34), [single]($r.Y + 9))
          $db.Dispose()
        }
      })
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
        }
      })
    $lst.Add_MouseLeave({
        if ($lst.IsDisposed) { $script:Hover = -1; return }
        if ($script:Hover -ge 0 -and $script:Hover -lt $lst.Items.Count) { $lst.Invalidate($lst.GetItemRectangle($script:Hover)) }
        $script:Hover = -1
      })
    $lst.Add_DoubleClick({ if ($lst.SelectedIndex -ge 0) { Use-Index $lst.SelectedIndex } })
    $lst.Add_MouseUp({ param($s, $e) if ($e.Button -eq 'Left') { $txt.Focus() } })

    $deb = New-Object Windows.Forms.Timer
    $deb.Interval = 150
    $deb.Add_Tick({ $deb.Stop(); Update-List $txt.Text })
    function Flush-List { if ($deb.Enabled) { $deb.Stop(); Update-List $txt.Text } }
    $txt.Add_TextChanged({ Sync-Placeholder; $deb.Stop(); $deb.Start() })
    $form.Add_KeyDown({
        param($s, $e)
        $code = [int]$e.KeyCode
        if ($e.KeyCode -eq 'PageDown') {
          Scroll-By 8
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'PageUp') {
          Scroll-By (-8)
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Up') {
          if ($lst.SelectedIndex -gt 0) { $lst.SelectedIndex-- }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Down') {
          if ($lst.SelectedIndex -lt $lst.Items.Count - 1) { $lst.SelectedIndex++ }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Enter') {
          Flush-List
          Use-Index $lst.SelectedIndex
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Escape') {
          $form.Close()
        } elseif ($e.KeyCode -eq 'Delete') {
          Flush-List
          try { Del-Index $lst.SelectedIndex } catch { Write-Log ('delete failed: ' + $_.Exception.Message) }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.Control -and $code -ge 49 -and $code -le 57) {
          Use-Index ($code - 49)
          $e.Handled = $true; $e.SuppressKeyPress = $true
        }
      })
    $ph.Add_Click({ $txt.Focus() })

    $form.Add_Paint({
        param($s, $e)
        $e.Graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pen = New-Object Drawing.Pen $ui.Border
        $gp = New-RoundPath 0 0 ($form.Width - 1) ($form.Height - 1) 8
        $e.Graphics.DrawPath($pen, $gp)
        $gp.Dispose()
        $pen.Dispose()
      })
    $form.Add_Shown({
        $form.Region = New-RoundRegion $form.Width $form.Height 8
        $form.Activate()
        $txt.Focus()
        Size-List
        Sync-Sb
        Write-Log ('picker: shown ' + $script:Theme + '/' + $script:UiFamily + ' items=' + $script:All.Count)
      })

    $script:ShownAt = Get-Date
    $form.Add_Deactivate({
        if (((Get-Date) - $script:ShownAt).TotalMilliseconds -gt 450) { $form.Close() }
      })

    Update-List ''
    [void]$form.ShowDialog()
    $deb.Dispose()
    $cm.Dispose()
    $form.Dispose()
  } catch {
    Write-Log ('picker error: ' + $_.Exception.Message)
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

  $script:StopEvt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\clipboard.stop')
  $script:ExitKind = ''
  try {
    Load-Forms
    Add-Native
    try { [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { }
    [Windows.Forms.Application]::add_ThreadException({ param($s, $e) Write-Log ('ui error (ignored): ' + $e.Exception.Message) })
    [void](Write-IniTemplate)

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

  $stored = @(Get-Items)
  if ($MaxItems -ge 1 -and $stored.Count -gt $MaxItems) {
    Use-StoreLock {
      $keep = @(Get-Items)
      if ($keep.Count -gt $MaxItems) { Save-Items ($keep[0..($MaxItems - 1)]) }
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
    $i4 = $dm.Items.Add('Clear history'); $i4.Add_Click({ Save-Items @() })
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

function New-ClipLnk([string]$lnk, [string]$verb) {
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

  # Keep the shortcut as plain as possible: point straight at powershell.exe and do NOT
  # pass -ExecutionPolicy Bypass. Client Windows defaults to RemoteSigned, which already
  # allows this local unsigned script. A conhost/rundll32 style wrapper or a Bypass flag
  # makes AV heuristics flag the .lnk as Trojan/LNK.Runner.
  $ws = New-Object -ComObject WScript.Shell
  $s = $ws.CreateShortcut($lnk)
  $s.TargetPath = $ps
  $s.Arguments = '-NoProfile -Sta -WindowStyle Hidden -File "' + (Join-Path $Root 'clipboard.ps1') + '" ' + $verb
  $s.WorkingDirectory = $Root
  $s.WindowStyle = 7
  $s.Description = 'clipboard history'
  $s.Save()
  return $lnk
}

function Install-Autostart {
  try {
    Write-Host ('[ok] startup : ' + (New-ClipLnk (Get-AutostartPath) 'serve') + '   (silent daemon at logon)')
  } catch { Write-Host ('[!] startup shortcut failed: ' + $_.Exception.Message) }

  try {
    Write-Host ('[ok] desktop : ' + (New-ClipLnk (Get-DesktopPath) 'ui') + '   (double-click = history)')
  } catch { Write-Host ('[!] desktop shortcut failed: ' + $_.Exception.Message) }

  $policy = [string](Get-ExecutionPolicy)
  if (@('Restricted', 'AllSigned') -contains $policy) {
    Write-Host ('[!] execution policy is ' + $policy + ' - the shortcut will refuse to run the script')
    Write-Host '    fix once with: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
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
  } catch { Write-Log ('config read failed: ' + $_.Exception.Message) }
  return $h
}

function Write-IniTemplate([switch]$Force) {
  if ((Test-Path -LiteralPath $IniPath) -and (-not $Force)) { return $IniPath }
  Ensure-Dir
  $t = @(
    '# clipboard.ini - flat key=value list. Restart the daemon after editing (clipboard stop, clipboard serve).',
    '# CLI switches win over this file.',
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
    '# dark | light',
    'Theme=dark',
    '# regex: matching clipboard text is never saved',
    'ExcludePattern='
  )
  [IO.File]::WriteAllText($IniPath, (($t -join [Environment]::NewLine) + [Environment]::NewLine), $Utf8)
  return $IniPath
}

function Apply-Config {
  $script:ExcludePattern = ''
  $script:ShowBalloon = $true
  $script:Theme = 'dark'
  $c = Read-Ini
  $cli = $script:CliParams
  if ((-not $cli.ContainsKey('Hotkey')) -and $c.ContainsKey('Hotkey') -and $c['Hotkey']) { $script:Hotkey = $c['Hotkey'] }
  if ((-not $cli.ContainsKey('PasteKeys')) -and $c.ContainsKey('PasteKeys') -and $c['PasteKeys']) { $script:PasteKeys = $c['PasteKeys'] }
  if ((-not $cli.ContainsKey('HotkeyFallbacks')) -and $c.ContainsKey('HotkeyFallbacks')) { $script:HotkeyFallbacks = [string]$c['HotkeyFallbacks'] }
  $n = 0
  if ((-not $cli.ContainsKey('ModReleaseTimeout')) -and $c.ContainsKey('ModReleaseTimeout') -and [int]::TryParse($c['ModReleaseTimeout'], [ref]$n) -and $n -ge 0) { $script:ModReleaseTimeout = $n }
  if ((-not $cli.ContainsKey('PasteSettle')) -and $c.ContainsKey('PasteSettle') -and [int]::TryParse($c['PasteSettle'], [ref]$n) -and $n -ge 0) { $script:PasteSettle = $n }
  if ((-not $cli.ContainsKey('MaxItems')) -and $c.ContainsKey('MaxItems') -and [int]::TryParse($c['MaxItems'], [ref]$n) -and $n -gt 0) { $script:MaxItems = $n }
  if ((-not $cli.ContainsKey('MaxBytes')) -and $c.ContainsKey('MaxBytes') -and [int]::TryParse($c['MaxBytes'], [ref]$n) -and $n -gt 0) { $script:MaxBytes = $n }
  if ((-not $cli.ContainsKey('MaxTotal')) -and $c.ContainsKey('MaxTotal') -and [int]::TryParse($c['MaxTotal'], [ref]$n) -and $n -gt 0) { $script:MaxTotal = $n }
  if ((-not $cli.ContainsKey('Interval')) -and $c.ContainsKey('Interval') -and [int]::TryParse($c['Interval'], [ref]$n) -and $n -ge 50) { $script:Interval = $n }
  if ((-not $cli.ContainsKey('NoPaste')) -and $c.ContainsKey('NoPaste') -and $c['NoPaste'] -eq '1') { $script:NoPaste = $true }
  if ($c.ContainsKey('ExcludePattern') -and $c['ExcludePattern']) { $script:ExcludePattern = $c['ExcludePattern'] }
  if ($c.ContainsKey('Balloon') -and $c['Balloon'] -eq '0') { $script:ShowBalloon = $false }
  if ($c.ContainsKey('Theme') -and $c['Theme']) { $script:Theme = $c['Theme'].Trim().ToLower() }
}

function Show-Config {
  [void](Write-IniTemplate)
  Write-Host ('config file : ' + $IniPath)
  Write-Host ('data dir    : ' + $StoreDir + $(if ($script:CliParams.ContainsKey('DataDir')) { '   (from -DataDir)' } elseif ($DataDir) { '   (from clipboard.ini)' } else { '   (default)' }))
  Write-Host ''
  Write-Host ('Hotkey            = ' + $Hotkey)
  Write-Host ('HotkeyFallbacks   = ' + $(if ($script:HotkeyFallbacks) { $script:HotkeyFallbacks } else { '(built-in chain)' }))
  Write-Host ('ModReleaseTimeout = ' + $script:ModReleaseTimeout + ' ms')
  Write-Host ('PasteSettle       = ' + $script:PasteSettle + ' ms')
  Write-Host ('PasteKeys         = ' + $PasteKeys)
  Write-Host ('MaxItems          = ' + $MaxItems)
  Write-Host ('MaxBytes          = ' + $MaxBytes)
  Write-Host ('MaxTotal          = ' + $MaxTotal + ' bytes')
  Write-Host ('Interval          = ' + $Interval + ' ms')
  Write-Host ('NoPaste           = ' + [int][bool]$NoPaste)
  Write-Host ('Balloon           = ' + [int][bool]$script:ShowBalloon)
  Write-Host ('Theme             = ' + $script:Theme)
  Write-Host ('ExcludePattern    = ' + $(if ($script:ExcludePattern) { $script:ExcludePattern } else { '(none)' }))
  Write-Host ''
  Write-Host 'clipboard config edit   open clipboard.ini in notepad'
  Write-Host 'clipboard config init   rewrite the template with defaults'
}
function Show-Usage {
  @(
    'clipboard - lightweight clipboard history for trimmed/offline Windows 10',
    '',
    'Usage: clipboard <command> [args] [options]',
    '',
    '  diag                probe the environment (run this first)',
    '  restore             try to restore the native Win+V history',
    '  serve               run the resident daemon (capture + hotkey + tray)',
    '  stop                stop the resident daemon',
    '  ui                  open the history picker (starts the daemon if needed)',
    '  list [-Count N]     list entries, newest first',
    '  put "text"          set the clipboard (reads stdin when text is omitted)',
    '  get                 print the clipboard text',
    '  pick N              put entry N back on the clipboard',
    '  del N               delete entry N',
    '  clear               delete all entries',
    '  pause | resume      pause / resume capture',
    '  status              show daemon state and settings',
    '  config [edit|init]  show settings / edit clipboard.ini / rewrite the template',
    '  install             create the startup + desktop shortcuts',
    '  uninstall [purge]   remove the shortcuts (purge also deletes data and config)',
    '  help                show this help',
    '',
    'Options (override clipboard.ini):',
    '  -Hotkey Ctrl+Alt+V   -PasteKeys ^v    -MaxItems 300',
    '  -MaxBytes 204800     -Interval 300    -NoPaste',
    '  -HotkeyFallbacks a,b -ModReleaseTimeout 1200   -PasteSettle 80',
    '  -DataDir <path>      write location (overrides DataDir= in clipboard.ini)',
    '',
    'Examples:',
    '  clipboard put "hello there"    echo hi | clipboard put    clipboard list -Count 5',
    '  clipboard serve                clipboard ui               clipboard config edit'
  ) | ForEach-Object { Write-Host $_ }
}
#endregion

#region dispatch
if ($Library) { return }   # dot-source mode: expose the functions only, run nothing
Apply-Config
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
    $items = @(Get-Items)
    if ($items.Count -eq 0) { Write-Host '(history is empty)'; break }
    $n = if ($Count -gt 0) { [Math]::Min($Count, $items.Count) } else { $items.Count }
    for ($i = 0; $i -lt $n; $i++) { Write-Host ('{0,3}  {1}' -f ($i + 1), (Format-Item $items[$i] 100)) }
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
    $items = @(Get-Items)
    if ($i -lt 1 -or $i -gt $items.Count) { Write-Host 'index out of range'; break }
    [void](Set-ClipItem $items[$i - 1])
    Add-Item $items[$i - 1]
    Write-Host ('clipboard set: ' + (Format-Item $items[$i - 1] 100))
  }
  'del' {
    $i = 0
    if (-not [int]::TryParse($Value, [ref]$i)) { Write-Host 'usage: clipboard del 3'; break }
    $items = @(Get-Items)
    if ($i -lt 1 -or $i -gt $items.Count) { Write-Host 'index out of range'; break }
    $victim = $items[$i - 1]
    Use-StoreLock {
      $keep = New-Object System.Collections.Generic.List[string]
      foreach ($it in @(Get-Items)) { if ($it -cne $victim) { $keep.Add($it) } }
      Save-Items $keep.ToArray()
    }
    Write-Host ('deleted: ' + (Format-Item $victim 60) + '   left ' + @(Get-Items).Count)
  }
  'clear' {
    Use-StoreLock { Save-Items @() }
    Write-Host '[ok] history cleared'
  }
  'pause' { Ensure-Dir; New-Item -ItemType File -Path $Paused -Force | Out-Null; Write-Host '[ok] capture paused' }
  'stop' {
    try { $se = [System.Threading.EventWaitHandle]::OpenExisting('Local\clipboard.stop'); [void]$se.Set(); Write-Log 'stop requested'; Write-Host '[ok] stop requested' }
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
    Write-Host ('entries     : ' + @(Get-Items).Count + ' / ' + $MaxItems)
    Write-Host ('capture     : ' + $(if (Test-Path -LiteralPath $Paused) { 'paused' } else { 'active' }))
    Write-Host ('autostart   : ' + $(if (Test-Path -LiteralPath (Get-AutostartPath)) { 'installed' } else { 'not installed' }))
    Write-Host ('desktop     : ' + $(if (Test-Path -LiteralPath (Get-DesktopPath)) { 'installed' } else { 'not installed' }))
    Write-Host ('store file  : ' + $StoreFile)
    $hkFile = Join-Path $StoreDir 'hotkey.txt'
    $eff = '(daemon never started)'
    if (Test-Path -LiteralPath $hkFile) { $eff = ([IO.File]::ReadAllText($hkFile, [Text.Encoding]::UTF8)).Trim() }
    Write-Host ('active key  : ' + $eff + '   (requested: ' + $Hotkey + ')')
    Write-Host ('config file : ' + $IniPath + $(if (Test-Path -LiteralPath $IniPath) { '' } else { '   (not created yet)' }))
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
    else { Show-Config }
  }
  'diag' { Invoke-Diag }
  'restore' { Invoke-Restore }
  'install' { Install-Autostart }
  'uninstall' {
    $doPurge = $Purge.IsPresent -or ($Value -and $Value.ToLower() -eq 'purge')
    Remove-Autostart -Purge:$doPurge
  }
  default {
    Write-Host ('unknown command: ' + $Command)
    Write-Host ''
    Show-Usage
  }
}
#endregion

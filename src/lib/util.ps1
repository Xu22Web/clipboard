# lib/util.ps1 - process-wide plumbing: logging, assemblies, DPI, pixels, time and rounded
# paths. No clipboard, no settings, no panel state: safe to call from a command, from the
# picker and from the resident loop alike.

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
    [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint idThread);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
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
    // The panel never activates on its own: a low-level keyboard hook (lib/keyhook.ps1) feeds
    // the controls instead, so the window the user was typing in keeps the foreground, the
    // focus and the caret. When the hook is unavailable, or an IME needs a real focus, the
    // picker escalates to a normal activating panel.
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override System.Windows.Forms.CreateParams CreateParams {
      get {
        var cp = base.CreateParams;
        cp.ExStyle |= 0x08000000;   // WS_EX_NOACTIVATE
        cp.ClassStyle |= 0x00020000;
        return cp;
      }
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

function Use-Drawing {
  if ($script:DrawingReady) { return }
  try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch { Write-Log ('System.Drawing unavailable: ' + $_.Exception.Message) }
  $script:DrawingReady = $true
}

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

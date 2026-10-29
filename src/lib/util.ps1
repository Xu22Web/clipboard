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
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool on);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int index);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int index, int value);
    // an input method needs an ordinary, focusable window: while it composes the panel hands
    // its WS_EX_NOACTIVATE back, and takes it again if the hand-over is refused
    public static void SetNoActivate(IntPtr h, bool on) {
      int ex = GetWindowLong(h, -20);
      SetWindowLong(h, -20, on ? (ex | 0x08000000) : (ex & ~0x08000000));
    }
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
        // A panel that never activates is also never asked to redraw by the shell, so its
        // controls can sit half-painted until something else forces a frame. Compositing
        // makes the DWM assemble each frame off-screen. It is not what fixes the row
        // flicker (Cb.PinList buffers its own paint, lib/pinlist.ps1), but the panel needs
        // it for its child controls.
        cp.ExStyle |= 0x02000000;   // WS_EX_COMPOSITED
        cp.ClassStyle |= 0x00020000;
        return cp;
      }
    }
  }
  public class FluentList : System.Windows.Forms.ListBox {
    public FluentList() { DoubleBuffered = true; }
  }

  // ---- the row surface (see lib/pinlist.ps1 for why it exists) -------------------
  public class PinDrawEventArgs : EventArgs {
    public int Index;
    public System.Drawing.Rectangle Bounds;
    public System.Drawing.Graphics Graphics;
    public System.Windows.Forms.DrawItemState State;
  }

  public class PinList : System.Windows.Forms.Control {
    // The label text lives with the caller and is pulled by index while painting: the
    // control only needs to know how many rows exist, so a refresh never copies strings.
    public int ItemCount = 0;
    public int ItemHeight = 40;
    // rows at the very top that never scroll: the pinned block
    public int PinnedCount = 0;
    public System.Drawing.Color SeparatorColor = System.Drawing.Color.Empty;
    // rows one wheel notch scrolls; 0 means the usual three
    public int WheelRows = 0;

    private int topIndex = 0;
    private int selected = -1;
    private int updates = 0;

    public event EventHandler DrawItem;
    public event EventHandler SelectedIndexChanged;
    // raised whenever the top row moves, so the host can move its scrollbar thumb too
    public event EventHandler ScrollChanged;

    public PinList() {
      SetStyle(System.Windows.Forms.ControlStyles.UserPaint |
               System.Windows.Forms.ControlStyles.AllPaintingInWmPaint |
               System.Windows.Forms.ControlStyles.OptimizedDoubleBuffer |
               System.Windows.Forms.ControlStyles.ResizeRedraw, true);
      TabStop = false;
    }

    // first scrollable row on screen; never points into the frozen block
    public int TopIndex { get { return topIndex; } set { SetTop(value); } }

    public int VisibleRows {
      get { if (ItemHeight <= 0) return 0; int n = ClientSize.Height / ItemHeight; return n < 0 ? 0 : n; }
    }

    // the largest legal TopIndex, so the last row can still reach the bottom edge
    public int MaxTop {
      get {
        int vis = VisibleRows - PinnedCount;
        if (vis < 1) vis = 1;
        int max = ItemCount - vis;
        if (max < PinnedCount) max = PinnedCount;
        return max;
      }
    }

    public int SelectedIndex {
      get { return selected; }
      set {
        int v = value;
        if (v < -1) v = -1;
        if (v >= ItemCount) v = ItemCount - 1;
        if (v == selected) return;
        selected = v;
        EnsureVisible(selected);
        Invalidate();
        EventHandler h = SelectedIndexChanged;
        if (h != null) h(this, EventArgs.Empty);
      }
    }

    public void ScrollBy(int rows) { SetTop(topIndex + rows); }
    public void ScrollTo(int index) { SetTop(index); }

    // scroll just enough to show one row; a frozen row is always visible already
    public void EnsureVisible(int index) {
      if (index < 0 || index < PinnedCount) return;
      int vis = VisibleRows - PinnedCount;
      if (vis < 1) return;
      if (index < topIndex) SetTop(index);
      else if (index >= topIndex + vis) SetTop(index - vis + 1);
    }

    private void SetTop(int value) {
      int max = MaxTop;
      if (value < PinnedCount) value = PinnedCount;
      if (value > max) value = max;
      if (value == topIndex) return;
      topIndex = value;
      Invalidate();
      EventHandler h = ScrollChanged;
      if (h != null) h(this, EventArgs.Empty);
    }

    public void BeginUpdate() { updates++; }
    public void EndUpdate() {
      if (updates > 0) updates--;
      if (updates > 0) return;
      if (selected >= ItemCount) selected = ItemCount - 1;
      SetTop(topIndex);
      Invalidate();
    }

    public System.Drawing.Rectangle GetItemRectangle(int index) {
      if (index < 0) return System.Drawing.Rectangle.Empty;
      int y;
      if (index < PinnedCount) y = index * ItemHeight;
      else y = (PinnedCount + index - topIndex) * ItemHeight;
      return new System.Drawing.Rectangle(0, y, ClientSize.Width, ItemHeight);
    }

    public int IndexFromPoint(System.Drawing.Point pt) {
      if (ItemHeight <= 0 || ItemCount == 0) return -1;
      int slot = pt.Y / ItemHeight;
      if (slot < 0) return -1;
      int i;
      if (slot < PinnedCount) i = slot;
      else i = topIndex + slot - PinnedCount;
      return (i >= 0 && i < ItemCount) ? i : -1;
    }

    // Clicking a row selects it. A plain Control has no built-in hit testing the way a
    // ListBox does, so the host would otherwise have to wire this per panel.
    protected override void OnMouseDown(System.Windows.Forms.MouseEventArgs e) {
      if (e.Button == System.Windows.Forms.MouseButtons.Left) {
        int i = IndexFromPoint(e.Location);
        if (i >= 0) SelectedIndex = i;
      }
      base.OnMouseDown(e);
    }

    // A ListBox scrolls itself on the wheel; this one has to do it too, or the event would
    // just bubble to the parent and nothing would move.
    protected override void OnMouseWheel(System.Windows.Forms.MouseEventArgs e) {
      int step = WheelRows > 0 ? WheelRows : 3;
      if (e.Delta > 0) ScrollBy(-step); else ScrollBy(step);
      System.Windows.Forms.HandledMouseEventArgs h = e as System.Windows.Forms.HandledMouseEventArgs;
      if (h != null) h.Handled = true;
      base.OnMouseWheel(e);
    }

    protected override void OnPaint(System.Windows.Forms.PaintEventArgs e) {
      System.Drawing.Graphics g = e.Graphics;
      using (System.Drawing.SolidBrush back = new System.Drawing.SolidBrush(BackColor)) { g.FillRectangle(back, ClientRectangle); }
      if (updates > 0 || ItemHeight <= 0) return;
      int pinned = Math.Min(PinnedCount, ItemCount);
      for (int i = 0; i < pinned; i++) { PaintRow(g, i, i * ItemHeight); }
      if (pinned > 0 && SeparatorColor != System.Drawing.Color.Empty) {
        using (System.Drawing.Pen pen = new System.Drawing.Pen(SeparatorColor)) {
          g.DrawLine(pen, 0, pinned * ItemHeight - 1, ClientSize.Width, pinned * ItemHeight - 1);
        }
      }
      int y = pinned * ItemHeight;
      int k = topIndex;
      while (k < ItemCount && y < ClientSize.Height) {
        PaintRow(g, k, y);
        y += ItemHeight;
        k++;
      }
    }

    private void PaintRow(System.Drawing.Graphics g, int index, int y) {
      EventHandler h = DrawItem;
      if (h == null) return;
      PinDrawEventArgs a = new PinDrawEventArgs();
      a.Index = index;
      a.Bounds = new System.Drawing.Rectangle(0, y, ClientSize.Width, ItemHeight);
      a.Graphics = g;
      a.State = (index == selected) ? System.Windows.Forms.DrawItemState.Selected : System.Windows.Forms.DrawItemState.None;
      h(this, a);
    }
  }
}
'@
  Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
  $script:NativeReady = $true
}

function Load-Forms {
  if ($script:FormsReady) { return }
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
  $script:FormsReady = $true
}

function Test-Font([string]$name) {
  # Enumerating the installed families costs ~50 ms and the picker asks three to six times
  # on every show, so the list is read once per process and kept as a set.
  if ($null -eq $script:FontNames) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try {
      foreach ($f in (New-Object Drawing.Text.InstalledFontCollection).Families) { [void]$set.Add($f.Name) }
    } catch { }
    $script:FontNames = $set
  }
  return $script:FontNames.Contains($name)
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

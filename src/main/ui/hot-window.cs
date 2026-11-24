// src/main/ui/hot-window.cs - the message-only window that receives the global hotkey (see
// lib/hotkey.ps1 and main/utils/native.ps1).
//
// RegisterHotKey delivers WM_HOTKEY to a window, so the resident owns a hidden STATIC window and
// raises an event when 0x0312 arrives; the PowerShell side only has to subscribe.
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged.
using System;

namespace Cb {
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
}

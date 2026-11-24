// src/main/ui/shell.cs - the process's own identity on the taskbar (see main/utils/native.ps1's
// Set-AppId).
//
// The taskbar groups windows by the process's AppUserModelID and takes the button's icon from
// the group, not from the window: a script host keeps the AUMID of its own executable, so a
// window that sets its icon still shows the host's mark on the bar and in Alt-Tab. Declaring an
// ID of our own before the first window exists puts the window in a group of ours, and the group
// has no icon of its own, so the bar falls back to the window's (measured: the window icon alone
// left the PowerShell mark, the ID plus the icon shows the tool's drawing).
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged.
using System;
using System.Runtime.InteropServices;

namespace Cb {
  public static class Shell {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=true)]
    static extern int SetCurrentProcessExplicitAppUserModelID(string id);
    public static bool SetAppId(string id) {
      if (String.IsNullOrEmpty(id)) { return false; }
      return SetCurrentProcessExplicitAppUserModelID(id) == 0;
    }
  }
}

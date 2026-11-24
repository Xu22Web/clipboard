// src\main\ui\win.cs - the win32 surface: the entry points, the interfaces reached through it,
// and the caret and target helpers built on both (see main/utils/native.ps1).
//
// Everything the platform layer needs from the OS is declared here once, so a PowerShell caller
// reaches a real signature instead of a late-bound name: the handles are IntPtr, the strings are
// UTF-16 the way the API takes them, and a call that answers by reference writes its numbers
// back. The accessibility interface is declared rather than reached through IDispatch for
// exactly that reason (measured on Chromium: accLocation through InvokeMember read 0,0 0x0).
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace Cb {
  // IAccessible declared here instead of being reached through late binding, because
  // accLocation answers its four numbers by reference: InvokeMember cannot write them back and
  // read 0,0 0x0 for every object on this machine (measured on Chromium 76, where the same call
  // through this interface answers 160,61 1x18). The vtable order is IDispatch first, then the
  // IAccessible members in the order oleacc declares them, because IAccessible is a dual
  // interface and the runtime sees one flat pointer.
  [ComImport, Guid("618736E0-3C3D-11CF-810C-00AA00389B71"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  internal interface IAccessible {
    [PreserveSig] int GetTypeInfoCount(out int count);
    [PreserveSig] int GetTypeInfo(int index, int lcid, out IntPtr info);
    [PreserveSig] int GetIDsOfNames(ref Guid iid, [MarshalAs(UnmanagedType.LPArray)] string[] names, int count, int lcid, [MarshalAs(UnmanagedType.LPArray)] int[] ids);
    [PreserveSig] int Invoke(int id, ref Guid iid, int lcid, int flags, IntPtr args, IntPtr result, IntPtr except, IntPtr argErr);
    [PreserveSig] int get_accParent(out object parent);
    [PreserveSig] int get_accChildCount(out int count);
    [PreserveSig] int get_accChild([In, MarshalAs(UnmanagedType.Struct)] object child, out object result);
    [PreserveSig] int get_accName([In, MarshalAs(UnmanagedType.Struct)] object child, [MarshalAs(UnmanagedType.BStr)] out string name);
    [PreserveSig] int get_accValue([In, MarshalAs(UnmanagedType.Struct)] object child, [MarshalAs(UnmanagedType.BStr)] out string value);
    [PreserveSig] int get_accDescription([In, MarshalAs(UnmanagedType.Struct)] object child, [MarshalAs(UnmanagedType.BStr)] out string description);
    [PreserveSig] int get_accRole([In, MarshalAs(UnmanagedType.Struct)] object child, out object role);
    [PreserveSig] int get_accState([In, MarshalAs(UnmanagedType.Struct)] object child, out object state);
    [PreserveSig] int get_accHelp([In, MarshalAs(UnmanagedType.Struct)] object child, [MarshalAs(UnmanagedType.BStr)] out string help);
    [PreserveSig] int get_accHelpTopic([MarshalAs(UnmanagedType.BStr)] out string file, [In, MarshalAs(UnmanagedType.Struct)] object child, out int topic);
    [PreserveSig] int get_accKeyboardShortcut([In, MarshalAs(UnmanagedType.Struct)] object child, [MarshalAs(UnmanagedType.BStr)] out string shortcut);
    [PreserveSig] int get_accFocus(out object child);
    [PreserveSig] int get_accSelection(out object child);
    [PreserveSig] int get_accDefaultAction([In, MarshalAs(UnmanagedType.Struct)] object child, [MarshalAs(UnmanagedType.BStr)] out string action);
    [PreserveSig] int accSelect(int flags, [In, MarshalAs(UnmanagedType.Struct)] object child);
    [PreserveSig] int accLocation(out int left, out int top, out int width, out int height, [In, MarshalAs(UnmanagedType.Struct)] object child);
    [PreserveSig] int accNavigate(int direction, [In, MarshalAs(UnmanagedType.Struct)] object start, out object destination);
    [PreserveSig] int accHitTest(int x, int y, out object child);
    [PreserveSig] int accDoDefaultAction([In, MarshalAs(UnmanagedType.Struct)] object child);
    [PreserveSig] int put_accName([In, MarshalAs(UnmanagedType.Struct)] object child, [MarshalAs(UnmanagedType.BStr)] string name);
    [PreserveSig] int put_accValue([In, MarshalAs(UnmanagedType.Struct)] object child, [MarshalAs(UnmanagedType.BStr)] string value);
  }

  public static class Win {
    [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    // the same call with the pid written back: the per-program paste rules need the number
    [DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")]
    public static extern uint GetWindowOwnerProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool on);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int index);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int index, int value);
    [DllImport("imm32.dll")] private static extern IntPtr ImmGetContext(IntPtr h);
    [DllImport("imm32.dll")] private static extern bool ImmReleaseContext(IntPtr h, IntPtr ctx);
    [DllImport("imm32.dll")] private static extern int ImmGetCompositionString(IntPtr ctx, int index, byte[] buf, int len);
    // Is the input method composing in that control right now? The panel draws its own caret in
    // the theme colour and hides the system one, except while a composition is running: the
    // candidate window is placed at the real caret, so that one has to stay. Only a composition
    // string counts - the conversion mode reports "Chinese or Japanese mode is on", which stays
    // true for the whole session, while the drawn caret is wanted whenever nothing is composed.
    public static bool ImeComposing(IntPtr h) {
      if (h == IntPtr.Zero) { return false; }
      IntPtr ctx = ImmGetContext(h);
      if (ctx == IntPtr.Zero) { return false; }
      try {
        // GCS_COMPSTR with no buffer answers the length of the string being composed
        return (ImmGetCompositionString(ctx, 0x0008, null, 0) > 0);
      } finally {
        ImmReleaseContext(h, ctx);
      }
    }
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    // ---- is the window in front a place the panel may anchor to -------------------------
    // CopyQ's isAltTabWindow() asks the same three questions before it treats a window as the
    // one the user is working in, and for the same reason: a suspended store application, a
    // shell flyout and a tool window all report themselves as visible and foreground, but
    // none of them is typing anything, so anchoring to one puts the panel on the desktop.
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int value, int size);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr h);

    // DWMWA_CLOAKED: the window is on a virtual desktop, is a suspended store application, or
    // is a shell surface that is still in the window list
    public static bool IsCloaked(IntPtr h) {
      if (h == IntPtr.Zero) { return false; }
      try {
        int v = 0;
        if (DwmGetWindowAttribute(h, 14, out v, 4) != 0) { return false; }
        return v != 0;
      } catch { return false; }
    }

    // A window the panel may read a caret from. A tool window never takes the keyboard, and a
    // cloaked one cannot be seen at all; both report themselves as foreground, so both would
    // place the panel on a window that is typing nothing.
    public static bool IsUsableTarget(IntPtr h) {
      if (h == IntPtr.Zero || !IsWindow(h) || !IsWindowVisible(h)) { return false; }
      int ex = GetWindowLong(h, -20);
      if ((ex & 0x00000080) != 0) { return false; }
      return !IsCloaked(h);
    }

    // The DPI of the monitor that window is on. 0 when the system does not answer (before
    // Windows 10 1607, or after the window is gone), and the caller keeps its own scale.
    public static int WindowDpi(IntPtr h) {
      if (h == IntPtr.Zero) { return 0; }
      try { return (int)GetDpiForWindow(h); } catch { return 0; }
    }
    // ---- the focus the panel has to give back ----------------------------------------
    // While the hook feeds the panel nothing has to be restored. The panel does move the
    // foreground twice (an input method composing, and the paste that follows a pick), and
    // putting the window back is not enough: the control that owned the caret has to be asked
    // for by name, or it comes back with the focus on the window frame instead.
    [StructLayout(LayoutKind.Sequential)]
    private struct GUITHREADINFO {
      public int cbSize; public int flags;
      public IntPtr hwndActive; public IntPtr hwndFocus; public IntPtr hwndCapture;
      public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize; public IntPtr hwndCaret;
      public WINRECT rcCaret;
    }
    [DllImport("user32.dll", SetLastError = true)] private static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern IntPtr SetFocus(IntPtr h);

    // the control that owns the keyboard in that window, or IntPtr.Zero
    public static IntPtr FocusOfWindow(IntPtr hwnd) {
      if (hwnd == IntPtr.Zero) { return IntPtr.Zero; }
      uint tid = GetWindowThreadProcessId(hwnd, IntPtr.Zero);
      if (tid == 0) { return IntPtr.Zero; }
      GUITHREADINFO info = new GUITHREADINFO();
      info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
      if (!GetGUIThreadInfo(tid, ref info)) { return IntPtr.Zero; }
      if (info.hwndFocus == IntPtr.Zero || !IsWindow(info.hwndFocus)) { return IntPtr.Zero; }
      return info.hwndFocus;
    }

    // SetFocus only works for a thread attached to the focus window's thread. Returns true
    // when that control really owns the keyboard afterwards.
    public static bool FocusControl(IntPtr hwnd, IntPtr focus) {
      if (hwnd == IntPtr.Zero || focus == IntPtr.Zero || !IsWindow(focus)) { return false; }
      uint target = GetWindowThreadProcessId(hwnd, IntPtr.Zero);
      if (target == 0) { return false; }
      uint mine = GetCurrentThreadId();
      bool attached = false;
      try {
        if (target != mine) { attached = AttachThreadInput(mine, target, true); }
        SetFocus(focus);
        return (FocusOfWindow(hwnd) == focus);
      } finally {
        if (attached) { AttachThreadInput(mine, target, false); }
      }
    }

    // How wide an edit control lays out a string, measured with that control's own device
    // context and its own font. TextRenderer measures with the process default mapping instead
    // and comes out half again as wide on a scaled display, which is what put the self-drawn
    // caret a few pixels past the last glyph. Returns -1 when the control is gone.
    [StructLayout(LayoutKind.Sequential)] private struct TEXTSIZE { public int cx; public int cy; }
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetTextExtentPoint32(IntPtr dc, string s, int count, out TEXTSIZE size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    private static extern IntPtr SendMessageW(IntPtr h, int msg, IntPtr w, IntPtr l);
    public static int TextWidth(IntPtr hwnd, string s) {
      if (hwnd == IntPtr.Zero) { return -1; }
      if (s == null) { s = ""; }
      IntPtr dc = GetDC(hwnd);
      if (dc == IntPtr.Zero) { return -1; }
      // the font handle belongs to the control: selected in, never deleted here
      IntPtr font = SendMessageW(hwnd, 0x0031, IntPtr.Zero, IntPtr.Zero);
      IntPtr old = IntPtr.Zero;
      try {
        if (font != IntPtr.Zero) { old = SelectObject(dc, font); }
        TEXTSIZE size;
        if (!GetTextExtentPoint32(dc, s, s.Length, out size)) { return -1; }
        return size.cx;
      } finally {
        if (old != IntPtr.Zero) { SelectObject(dc, old); }
        ReleaseDC(hwnd, dc);
      }
    }

    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
    // the system caret cannot be given a colour, so the panel hides it and draws its own line;
    // a control re-shows its caret after every keystroke, so the caller repeats this
    [DllImport("user32.dll")] public static extern bool HideCaret(IntPtr h);
    // HideCaret counts: a caret that was hidden twice needs two ShowCaret calls before a
    // control can show it again. renderer/src/windows/picker.ps1 keeps the count.
    [DllImport("user32.dll")] public static extern bool ShowCaret(IntPtr h);
    // where a window is on screen, as a rectangle the geometry helpers can read. Empty for a
    // window that is gone, minimised or has no area, so the caller keeps its own fallback.
    [StructLayout(LayoutKind.Sequential)] private struct WINRECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll", SetLastError = true)] private static extern bool GetWindowRect(IntPtr h, out WINRECT rect);
    public static System.Drawing.Rectangle WindowBounds(IntPtr h) {
      WINRECT r;
      if (h == IntPtr.Zero || !GetWindowRect(h, out r)) { return System.Drawing.Rectangle.Empty; }
      int w = r.Right - r.Left;
      int hh = r.Bottom - r.Top;
      if (w <= 0 || hh <= 0) { return System.Drawing.Rectangle.Empty; }
      return new System.Drawing.Rectangle(r.Left, r.Top, w, hh);
    }

    // The caret the window is typing at, in screen pixels: the spot an input method or a
    // completion list would appear next to. Empty when the window is gone, has no focused
    // control, or that control shows no caret right now - a zero height is what a control
    // reports while it is scrolled away or in the middle of a layout pass.
    //
    // rcCaret is documented as screen coordinates, but a Win32 edit control reports it inside
    // its own client area (measured: a text box at 308,231 with the caret after "hello" answers
    // 104,1). Ditto and ClipAngel both simply add the focused control's screen origin, so the
    // client reading is tried first and the raw rectangle is kept only when the sum lands
    // outside the control - which is what a provider that really does answer in screen
    // coordinates produces. Reading it the other way round used to trust a client rectangle
    // whose numbers happened to fall inside the control, and put the panel near the corner.
    [StructLayout(LayoutKind.Sequential)] private struct CARETPOINT { public int X; public int Y; }
    [DllImport("user32.dll")] private static extern bool ClientToScreen(IntPtr h, ref CARETPOINT p);

    public static System.Drawing.Rectangle CaretOfWindow(IntPtr hwnd) {
      if (hwnd == IntPtr.Zero) { return System.Drawing.Rectangle.Empty; }
      uint tid = GetWindowThreadProcessId(hwnd, IntPtr.Zero);
      if (tid == 0) { return System.Drawing.Rectangle.Empty; }
      GUITHREADINFO info = new GUITHREADINFO();
      info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
      if (!GetGUIThreadInfo(tid, ref info)) { return System.Drawing.Rectangle.Empty; }
      if (info.hwndActive == IntPtr.Zero) { return System.Drawing.Rectangle.Empty; }
      WINRECT r = info.rcCaret;
      int ch = r.Bottom - r.Top;
      if (ch <= 0) { return System.Drawing.Rectangle.Empty; }
      int cw = r.Right - r.Left;
      if (cw <= 0) { cw = 1; }
      System.Drawing.Rectangle caret = new System.Drawing.Rectangle(r.Left, r.Top, cw, ch);
      if (info.hwndFocus == IntPtr.Zero || !IsWindow(info.hwndFocus)) { return caret; }
      System.Drawing.Rectangle bounds = WindowBounds(info.hwndFocus);
      if (bounds.IsEmpty) { return caret; }
      System.Drawing.Rectangle room = System.Drawing.Rectangle.Inflate(bounds, 4, 4);
      CARETPOINT origin = new CARETPOINT();
      if (ClientToScreen(info.hwndFocus, ref origin)) {
        System.Drawing.Rectangle moved = new System.Drawing.Rectangle(caret.Left + origin.X, caret.Top + origin.Y, cw, ch);
        if (room.Contains(moved)) { return moved; }
      }
      return caret;
    }

    // The rectangle of the control that owns the keyboard in that window, in screen pixels.
    // Controls that draw their own caret (RichEdit, Electron, terminals) report no rcCaret, so
    // this is the last thing that always exists: the area the typing goes into.
    public static System.Drawing.Rectangle FocusControlBounds(IntPtr hwnd) {
      if (hwnd == IntPtr.Zero) { return System.Drawing.Rectangle.Empty; }
      uint tid = GetWindowThreadProcessId(hwnd, IntPtr.Zero);
      if (tid == 0) { return System.Drawing.Rectangle.Empty; }
      GUITHREADINFO info = new GUITHREADINFO();
      info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
      if (!GetGUIThreadInfo(tid, ref info)) { return System.Drawing.Rectangle.Empty; }
      if (info.hwndFocus == IntPtr.Zero || !IsWindow(info.hwndFocus)) { return System.Drawing.Rectangle.Empty; }
      return WindowBounds(info.hwndFocus);
    }

    // The caret the input queue keeps for the focused thread, in screen pixels. The third
    // source, after rcCaret and before UI Automation: GetCaretPos only answers for the calling
    // thread, so the queues are attached for the call.
    //
    // It answers TRUE with 0,0 when the thread has no caret at all (measured on an Explorer
    // search box and on Electron windows, where hwndCaret is 0), which put the panel at the
    // corner of the window. hwndCaret is the thread's own answer to which window owns the
    // caret, and the point is read relative to that window, so it is both the test and the
    // origin. No size comes with the point - the caller adds the height of one line.
    [DllImport("user32.dll")] private static extern bool GetCaretPos(out CARETPOINT p);
    [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr h, out WINRECT r);

    public static System.Drawing.Rectangle AttachedCaret(IntPtr hwnd) {
      if (hwnd == IntPtr.Zero) { return System.Drawing.Rectangle.Empty; }
      uint target = GetWindowThreadProcessId(hwnd, IntPtr.Zero);
      if (target == 0) { return System.Drawing.Rectangle.Empty; }
      GUITHREADINFO info = new GUITHREADINFO();
      info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
      if (!GetGUIThreadInfo(target, ref info)) { return System.Drawing.Rectangle.Empty; }
      IntPtr owner = info.hwndCaret;
      if (owner == IntPtr.Zero || !IsWindow(owner)) { return System.Drawing.Rectangle.Empty; }
      WINRECT client;
      if (!GetClientRect(owner, out client)) { return System.Drawing.Rectangle.Empty; }
      uint mine = GetCurrentThreadId();
      bool attached = false;
      try {
        if (target != mine) { attached = AttachThreadInput(mine, target, true); }
        CARETPOINT p;
        if (!GetCaretPos(out p)) { return System.Drawing.Rectangle.Empty; }
        // a position left over from before the control lost the caret is outside the window
        if (p.X < 0 || p.Y < 0 || p.X > client.Right || p.Y > client.Bottom) { return System.Drawing.Rectangle.Empty; }
        CARETPOINT origin;
        origin.X = 0; origin.Y = 0;
        if (!ClientToScreen(owner, ref origin)) { return System.Drawing.Rectangle.Empty; }
        // a point, not a box: height 0 says "one line, the caller knows how tall that is"
        return new System.Drawing.Rectangle(p.X + origin.X, p.Y + origin.Y, 1, 0);
      } catch {
        return System.Drawing.Rectangle.Empty;
      } finally {
        if (attached) { AttachThreadInput(mine, target, false); }
      }
    }

    // ---- the caret the accessibility layer knows -----------------------------------------
    // A control that draws its own caret answers nothing in rcCaret and nothing through
    // GetCaretPos, but MSAA still keeps an OBJID_CARET object for it. Ditto asks this source
    // first (ExternalWindowTracker::FocusCaret) because it is the one that also answers for
    // older controls on Windows 10, which have no UI Automation text pattern at all.
    [DllImport("oleacc.dll")]
    private static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint id, ref Guid iid,
      [MarshalAs(UnmanagedType.IUnknown)] out object acc);

    // the object a window exposes to accessibility, or null when it exposes none
    private static object AccessibleRoot(IntPtr owner) {
      object acc = null;
      Guid iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
      if (AccessibleObjectFromWindow(owner, 0xFFFFFFFC, ref iid, out acc) != 0) { return null; }
      return acc;
    }

    // the rectangle of an accessible object, or of one of its simple children
    private static System.Drawing.Rectangle AccessibleRect(object acc, int child) {
      IAccessible a = acc as IAccessible;
      if (a == null) { return System.Drawing.Rectangle.Empty; }
      int left, top, w, h;
      try {
        if (a.accLocation(out left, out top, out w, out h, child) != 0) { return System.Drawing.Rectangle.Empty; }
      } catch {
        return System.Drawing.Rectangle.Empty;
      }
      if (w <= 0 && h <= 0) { return System.Drawing.Rectangle.Empty; }
      if (w <= 0) { w = 1; }
      if (h < 0) { h = 0; }
      return new System.Drawing.Rectangle(left, top, w, h);
    }

    public static System.Drawing.Rectangle MsaaCaret(IntPtr hwnd) {
      if (hwnd == IntPtr.Zero) { return System.Drawing.Rectangle.Empty; }
      uint tid = GetWindowThreadProcessId(hwnd, IntPtr.Zero);
      if (tid == 0) { return System.Drawing.Rectangle.Empty; }
      GUITHREADINFO info = new GUITHREADINFO();
      info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
      if (!GetGUIThreadInfo(tid, ref info)) { return System.Drawing.Rectangle.Empty; }
      // The caret object belongs to the control that holds the keyboard rather than to the
      // frame, so the two handles the thread reports are asked first. A frame that keeps the
      // caret itself answers only for its own handle - Ditto queries the active window for
      // that reason - and asking it costs one call that usually fails at once.
      IntPtr[] owners = new IntPtr[] { info.hwndFocus, info.hwndCaret, hwnd };
      for (int i = 0; i < owners.Length; i++) {
        IntPtr owner = owners[i];
        if (owner == IntPtr.Zero || !IsWindow(owner)) { continue; }
        bool seen = false;
        for (int k = 0; k < i; k++) { if (owners[k] == owner) { seen = true; break; } }
        if (seen) { continue; }
        // a window that hangs turns the cross-process call into a blocking wait
        try { if (!IsResponsive(owner, 40)) { continue; } } catch { continue; }
        object acc = null;
        try {
          Guid iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
          if (AccessibleObjectFromWindow(owner, 0xFFFFFFF8, ref iid, out acc) != 0 || acc == null) { continue; }
          System.Drawing.Rectangle caret = AccessibleRect(acc, 0);
          if (!caret.IsEmpty) { return caret; }
        } catch {
        } finally {
          try { if (acc != null && Marshal.IsComObject(acc)) { Marshal.ReleaseComObject(acc); } } catch { }
        }
      }
      return System.Drawing.Rectangle.Empty;
    }

    // The box of whatever holds the keyboard in that window, for a provider that keeps no caret
    // object: the frame reports its document, the document reports the field being typed in, and
    // the innermost object that answers with a rectangle is the one the user is working in. A
    // window with no focus at all answers Empty, so the caller keeps its own fallback.
    public static System.Drawing.Rectangle MsaaFocusRect(IntPtr hwnd) {
      if (hwnd == IntPtr.Zero) { return System.Drawing.Rectangle.Empty; }
      uint tid = GetWindowThreadProcessId(hwnd, IntPtr.Zero);
      if (tid == 0) { return System.Drawing.Rectangle.Empty; }
      GUITHREADINFO info = new GUITHREADINFO();
      info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
      if (!GetGUIThreadInfo(tid, ref info)) { return System.Drawing.Rectangle.Empty; }
      IntPtr owner = info.hwndFocus;
      if (owner == IntPtr.Zero || !IsWindow(owner)) { owner = hwnd; }
      try { if (!IsResponsive(owner, 40)) { return System.Drawing.Rectangle.Empty; } } catch { return System.Drawing.Rectangle.Empty; }
      object root = null;
      try {
        root = AccessibleRoot(owner);
        if (root == null) { return System.Drawing.Rectangle.Empty; }
        System.Drawing.Rectangle best = System.Drawing.Rectangle.Empty;
        object current = root;
        for (int step = 0; step < 4; step++) {
          IAccessible a = current as IAccessible;
          if (a == null) { break; }
          object child = null;
          try { if (a.get_accFocus(out child) != 0 || child == null) { break; } } catch { break; }
          // a simple child: its rectangle is the answer, and there is nothing deeper to ask
          int id = -1;
          if (child is int) { id = (int)child; }
          if (id == 0) { break; }
          if (id > 0) {
            System.Drawing.Rectangle box = AccessibleRect(current, id);
            if (!box.IsEmpty) { return box; }
            break;
          }
          // a focused object of its own: keep its box, then ask it for the focus inside it
          current = child;
          System.Drawing.Rectangle own = AccessibleRect(current, 0);
          if (own.IsEmpty) { break; }
          best = own;
        }
        return best;
      } catch {
        return System.Drawing.Rectangle.Empty;
      } finally {
        try { if (root != null && Marshal.IsComObject(root)) { Marshal.ReleaseComObject(root); } } catch { }
      }
    }

    // ---- naming a window in a log line ------------------------------------------------
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);

    // The title a user would read. A paste that landed in the wrong window is told apart by the
    // name of the window, never by its handle, so the log carries one narrow copy of it.
    public static string WindowTitle(IntPtr h, int max) {
      if (h == IntPtr.Zero) { return ""; }
      System.Text.StringBuilder sb = new System.Text.StringBuilder(320);
      if (GetWindowTextW(h, sb, sb.Capacity) <= 0) { return ""; }
      string t = sb.ToString().Replace("\r", " ").Replace("\n", " ").Trim();
      if (max > 0 && t.Length > max) { t = t.Substring(0, max) + "..."; }
      return t;
    }

    // True when the window belongs to this process: the panel, a tray or message window of the
    // daemon, or the console it was started from. None of them is somewhere to paste into.
    public static bool IsOwnWindow(IntPtr h) {
      if (h == IntPtr.Zero) { return false; }
      uint pid;
      GetWindowOwnerProcessId(h, out pid);
      return pid != 0 && pid == (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
    }

    // The window class a user never sees but a tool has to recognise: the shell's own UX frame
    // (Start, the search flyout) is one class, whatever process hosts it in this build.
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
    public static string WindowClass(IntPtr h) {
      if (h == IntPtr.Zero) { return ""; }
      System.Text.StringBuilder sb = new System.Text.StringBuilder(256);
      if (GetClassNameW(h, sb, sb.Capacity) <= 0) { return ""; }
      return sb.ToString();
    }

    // The window just below this one in the z-order, skipping the invisible ones: what a flyout
    // shows when it goes away is whatever was behind it, and that is the window to hand the
    // foreground to when the flyout ignores Escape.
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    public static IntPtr WindowBelow(IntPtr h) {
      if (h == IntPtr.Zero) { return IntPtr.Zero; }
      IntPtr w = GetWindow(h, 2);   // GW_HWNDNEXT
      while (w != IntPtr.Zero && !IsWindowVisible(w)) { w = GetWindow(w, 2); }
      return w;
    }

    // True when the window is an always-on-top one. The panel is topmost too but never activates,
    // so an active topmost window stays above it - measured on the shell's search flyout, which
    // sits there without UIAccess and stayed in front of the panel.
    public static bool IsTopmost(IntPtr h) {
      if (h == IntPtr.Zero) { return false; }
      return (GetWindowLong(h, -20) & 0x8) != 0;   // GWL_EXSTYLE, WS_EX_TOPMOST
    }

    // A window whose process holds UIAccess is drawn in a band above every topmost window, so no
    // z-order call puts a normal window over it: this is the general form of "the panel cannot go
    // there", and it costs no interaction with that process. Start and the search flyout are the
    // ones a user runs into; the band itself is not queryable (GetWindowBand is undocumented and
    // not exported by name, and calling the wrong ordinal kills the caller).
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(IntPtr token, int cls, out int value, int len, out int needed);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);

    public static bool HasUiAccess(IntPtr hwnd) {
      if (hwnd == IntPtr.Zero) { return false; }
      uint pid;
      if (GetWindowOwnerProcessId(hwnd, out pid) == 0 || pid == 0) { return false; }
      IntPtr process = IntPtr.Zero;
      IntPtr token = IntPtr.Zero;
      try {
        process = OpenProcess(0x1000, false, pid);                                  // PROCESS_QUERY_LIMITED_INFORMATION
        if (process == IntPtr.Zero) { return false; }
        if (!OpenProcessToken(process, 0x0008, out token)) { return false; }        // TOKEN_QUERY
        int value;
        int needed;
        if (!GetTokenInformation(token, 26, out value, 4, out needed)) { return false; }   // TokenUIAccess
        return value != 0;
      } catch {
        return false;
      } finally {
        if (token != IntPtr.Zero) { CloseHandle(token); }
        if (process != IntPtr.Zero) { CloseHandle(process); }
      }
    }

    // A window that does not answer WM_NULL within the budget is one whose accessibility calls
    // would block the caller, so the caret lookup is skipped for it instead of waiting.
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    public static bool IsResponsive(IntPtr hwnd, uint timeoutMs) {
      if (hwnd == IntPtr.Zero) { return false; }
      IntPtr result;
      return SendMessageTimeout(hwnd, 0, IntPtr.Zero, IntPtr.Zero, 0x0002, timeoutMs, out result) != IntPtr.Zero;
    }

    // ---- the selection of a plain edit control ---------------------------------------
    // An editor built on the Win32 edit control - Notepad, a WinForms TextBox, several chat
    // clients - answers UI Automation with no text pattern at all, so the caret the panel wants
    // back before pasting cannot be read there (measured: a WinForms TextBox reports an empty
    // pattern list while it still answers EM_GETSEL). These two messages reach it anyway.
    private const int EM_GETSEL = 0x00B0;
    private const int EM_SETSEL = 0x00B1;

    // The class names a Win32 edit control goes by: the plain one, the RichEdit generations and
    // the wrapper Windows Forms puts around both. Only these are asked, because a message the
    // control does not know returns zero - which would read as "the caret is at the start".
    public static bool IsEditControl(IntPtr hwnd) {
      string cls = WindowClass(hwnd);
      if (cls.Length == 0) { return false; }
      string lc = cls.ToLowerInvariant();
      if (lc == "edit" || lc == "tedit" || lc == "tmemo") { return true; }
      if (lc.StartsWith("richedit")) { return true; }
      if (lc.StartsWith("windowsforms10.edit")) { return true; }
      if (lc.StartsWith("windowsforms10.richedit")) { return true; }
      return false;
    }

    // EM_GETSEL packs the two ends into the result; the low word is where the selection starts.
    public static bool GetEditSelection(IntPtr hwnd, out int start, out int end) {
      start = 0; end = 0;
      if (hwnd == IntPtr.Zero) { return false; }
      long v = SendMessageW(hwnd, EM_GETSEL, IntPtr.Zero, IntPtr.Zero).ToInt64();
      start = (int)(v & 0xFFFF);
      end = (int)((v >> 16) & 0xFFFF);
      return true;
    }

    public static bool SetEditSelection(IntPtr hwnd, int start, int end) {
      if (hwnd == IntPtr.Zero) { return false; }
      SendMessageW(hwnd, EM_SETSEL, (IntPtr)start, (IntPtr)end);
      return true;
    }

    // The line a plain Win32 edit control types at, in screen pixels: EM_POSFROMCHAR answers the
    // corner of a character in client coordinates and the control's own font gives the line
    // height. rcCaret and GetCaretPos both describe the caret the keyboard is drawing, which is
    // what a control that draws none never reports; this reads the selection position instead.
    //
    // RichEdit is left out on purpose. Its EM_POSFROMCHAR takes a POINT to fill and does not fill
    // it (measured on a RichEdit20W: the point stays 0,0, which would anchor the panel at the
    // client corner), and it reports rcCaret anyway - so an empty answer here is better than a
    // wrong one.
    [StructLayout(LayoutKind.Sequential)] private struct TEXTMETRICW {
      public int tmHeight, tmAscent, tmDescent, tmInternalLeading, tmExternalLeading;
      public int tmAveCharWidth, tmMaxCharWidth, tmWeight, tmOverhang;
      public int tmDigitizedAspectX, tmDigitizedAspectY;
      public char tmFirstChar, tmLastChar, tmDefaultChar, tmBreakChar;
      public byte tmItalic, tmUnderlined, tmStruckOut, tmPitchAndFamily, tmCharSet;
    }
    [DllImport("gdi32.dll", EntryPoint = "GetTextMetricsW")]
    private static extern bool GetTextMetricsW(IntPtr dc, out TEXTMETRICW tm);
    private const int EM_POSFROMCHAR = 0x00D6;

    private static bool IsRichEditControl(IntPtr hwnd) {
      string cls = WindowClass(hwnd);
      if (cls.Length == 0) { return false; }
      return cls.ToLowerInvariant().IndexOf("richedit") >= 0;
    }

    // a plain edit packs the character's corner into the result and answers -1 past the text
    private static bool TryEditCharPoint(IntPtr hwnd, int index, out int x, out int y) {
      x = -1; y = -1;
      long v = SendMessageW(hwnd, EM_POSFROMCHAR, (IntPtr)index, IntPtr.Zero).ToInt64();
      if (v < 0) { return false; }
      x = (short)(v & 0xFFFF);
      y = (short)((v >> 16) & 0xFFFF);
      return (x >= 0 && y >= 0);
    }

    public static System.Drawing.Rectangle EditCaretRect(IntPtr hwnd) {
      if (hwnd == IntPtr.Zero) { return System.Drawing.Rectangle.Empty; }
      IntPtr edit = hwnd;
      if (!IsEditControl(edit)) {
        uint tid = GetWindowThreadProcessId(hwnd, IntPtr.Zero);
        if (tid == 0) { return System.Drawing.Rectangle.Empty; }
        GUITHREADINFO info = new GUITHREADINFO();
        info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
        if (!GetGUIThreadInfo(tid, ref info)) { return System.Drawing.Rectangle.Empty; }
        edit = info.hwndFocus;
      }
      if (edit == IntPtr.Zero || !IsWindow(edit) || !IsEditControl(edit)) { return System.Drawing.Rectangle.Empty; }
      if (IsRichEditControl(edit)) { return System.Drawing.Rectangle.Empty; }
      int start, end;
      if (!GetEditSelection(edit, out start, out end)) { return System.Drawing.Rectangle.Empty; }
      int x, y;
      if (!TryEditCharPoint(edit, start, out x, out y) && start > 0) {
        if (!TryEditCharPoint(edit, start - 1, out x, out y)) { return System.Drawing.Rectangle.Empty; }
      }
      if (x < 0 || y < 0) { return System.Drawing.Rectangle.Empty; }
      int lineH = 0;
      IntPtr dc = GetDC(edit);
      if (dc != IntPtr.Zero) {
        try {
          TEXTMETRICW tm;
          if (GetTextMetricsW(dc, out tm) && tm.tmHeight > 0) { lineH = tm.tmHeight; }
        } finally {
          ReleaseDC(edit, dc);
        }
      }
      if (lineH <= 0) { lineH = 16; }
      // a point left over from another line or another state sits outside the client area
      WINRECT client;
      if (!GetClientRect(edit, out client)) { return System.Drawing.Rectangle.Empty; }
      if (x > client.Right || y > client.Bottom) { return System.Drawing.Rectangle.Empty; }
      CARETPOINT origin = new CARETPOINT();
      if (!ClientToScreen(edit, ref origin)) { return System.Drawing.Rectangle.Empty; }
      return new System.Drawing.Rectangle(x + origin.X, y + origin.Y, 1, lineH);
    }

    // ---- typing without the clipboard ------------------------------------------------
    // SendInput with KEYEVENTF_UNICODE puts the characters straight into the focused control,
    // so a target that ignores Ctrl+V still receives the text and the clipboard is not
    // touched. INPUT must stay the size the API expects: MOUSEINPUT is its largest member, so
    // the union is 32 bytes on x64 and 24 on x86, and a short union fails with
    // ERROR_INVALID_PARAMETER (87).
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [StructLayout(LayoutKind.Sequential)] private struct KEYBDINPUT {
      public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr extra;
    }
    [StructLayout(LayoutKind.Sequential)] private struct MOUSEINPUT {
      public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra;
    }
    [StructLayout(LayoutKind.Explicit)] private struct INPUTUNION {
      [FieldOffset(0)] public MOUSEINPUT mi;
      [FieldOffset(0)] public KEYBDINPUT ki;
    }
    [StructLayout(LayoutKind.Sequential)] private struct INPUT { public uint type; public INPUTUNION u; }
    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;

    // number of UTF-16 code units the input queue accepted (a surrogate pair counts twice)
    public static int SendUnicode(string text) {
      if (string.IsNullOrEmpty(text)) { return 0; }
      int sent = 0;
      int size = Marshal.SizeOf(typeof(INPUT));
      for (int i = 0; i < text.Length; i++) {
        INPUT down = new INPUT();
        INPUT up = new INPUT();
        down.type = INPUT_KEYBOARD;
        up.type = INPUT_KEYBOARD;
        down.u.ki.wScan = text[i];
        up.u.ki.wScan = text[i];
        down.u.ki.dwFlags = KEYEVENTF_UNICODE;
        up.u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
        if (SendInput(2, new INPUT[] { down, up }, size) == 2) { sent++; }
      }
      return sent;
    }

    // ---- a shortcut on the physical keys ---------------------------------------------
    // SendKeys builds its modifier from a virtual key with no scan code, and an input method
    // can answer that with VK_PROCESSKEY: the chord then arrives as a bare letter and the paste
    // never happens (measured on Chromium 76, once in about ten opens, right after the browser
    // came up). The same keys through SendInput carry the scan code the keyboard reports, so
    // the target reads them as the key it knows.
    [DllImport("user32.dll")] private static extern uint MapVirtualKey(uint code, uint mapType);

    // false when the input queue did not take the whole chord
    public static bool SendChord(ushort vk, bool ctrl, bool alt, bool shift) {
      if (vk == 0) { return false; }
      int size = Marshal.SizeOf(typeof(INPUT));
      System.Collections.Generic.List<INPUT> seq = new System.Collections.Generic.List<INPUT>(8);
      if (ctrl) { seq.Add(KeyInput(0x11, false)); }
      if (alt) { seq.Add(KeyInput(0x12, false)); }
      if (shift) { seq.Add(KeyInput(0x10, false)); }
      seq.Add(KeyInput(vk, false));
      seq.Add(KeyInput(vk, true));
      // released in the reverse order: no modifier is left down when the key goes back up
      if (shift) { seq.Add(KeyInput(0x10, true)); }
      if (alt) { seq.Add(KeyInput(0x12, true)); }
      if (ctrl) { seq.Add(KeyInput(0x11, true)); }
      INPUT[] inputs = seq.ToArray();
      return SendInput((uint)inputs.Length, inputs, size) == inputs.Length;
    }

    private static INPUT KeyInput(ushort vk, bool up) {
      INPUT i = new INPUT();
      i.type = INPUT_KEYBOARD;
      i.u.ki.wVk = vk;
      i.u.ki.wScan = (ushort)MapVirtualKey(vk, 0);
      i.u.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
      return i;
    }

    // ---- formatted text, straight out of the clipboard ----
    // CF_HTML carries byte offsets into its own buffer, and both blocks are 8-bit buffers:
    // they must never travel through a .NET string. The default DATAOBJECT converter decodes
    // them with the ANSI code page, so UTF-8 html becomes mojibake and, once re-encoded,
    // every StartHTML/EndHTML offset points somewhere else - Word and Excel then paste
    // garbage. Reading the handle gives the bytes Word put there.
    [DllImport("user32.dll", SetLastError = true)] private static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint RegisterClipboardFormat(string name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalLock(IntPtr block);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GlobalUnlock(IntPtr block);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern UIntPtr GlobalSize(IntPtr block);
    [DllImport("gdi32.dll", SetLastError = true)] private static extern uint GetEnhMetaFileBits(IntPtr metafile, uint size, byte[] data);

    public static void ReadRichFormats(ref byte[] html, ref byte[] rtf) {
      byte[] png = null;
      byte[] dib = null;
      byte[] emf = null;
      ReadRichFormats(ref html, ref rtf, ref png, ref dib, ref emf);
    }

    // false after a read means another window held the clipboard, so the null blocks say
    // nothing about what it carries: the caller retries the read instead of falling back to
    // the string path, which decodes the block with the ANSI code page and can lose bytes
    public static bool ClipboardOpen { get; private set; }

    // one clipboard open for the whole snapshot: the two text blocks plus the picture blocks a
    // target may ask for instead (an Excel chart arrives as a metafile, a Word shape as a
    // bitmap). Reading them apart would let a second copy slip in between.
    public static void ReadRichFormats(ref byte[] html, ref byte[] rtf, ref byte[] png, ref byte[] dib, ref byte[] emf) {
      html = null;
      rtf = null;
      png = null;
      dib = null;
      emf = null;
      ClipboardOpen = OpenClipboard(IntPtr.Zero);
      if (!ClipboardOpen) { return; }
      try {
        html = ReadBlock(RegisterClipboardFormat("HTML Format"), true);
        rtf = ReadBlock(RegisterClipboardFormat("Rich Text Format"), false);
        png = ReadBlock(RegisterClipboardFormat("PNG"), false);
        dib = ReadDib();
        emf = ReadEmf();
      } finally { CloseClipboard(); }
    }

    // The third way in, for when the open above was refused because another window held the
    // clipboard. The OLE data object does not need that open, and it answers with the same
    // HGLOBAL the owner published - unlike the wrapper WinForms builds, which hands CF_HTML
    // over as a string that was decoded with the ANSI code page (a byte can go missing on the
    // way, "</span>" reads back as "?/span").
    [DllImport("ole32.dll")] private static extern int OleGetClipboard(out System.Runtime.InteropServices.ComTypes.IDataObject data);
    [DllImport("ole32.dll")] private static extern void ReleaseStgMedium(ref System.Runtime.InteropServices.ComTypes.STGMEDIUM medium);

    public static byte[] ReadFormatBytes(string format) {
      if (string.IsNullOrEmpty(format)) { return null; }
      System.Runtime.InteropServices.ComTypes.IDataObject data = null;
      if (OleGetClipboard(out data) != 0 || data == null) { return null; }
      uint cf = RegisterClipboardFormat(format);
      if (cf == 0) { return null; }
      System.Runtime.InteropServices.ComTypes.FORMATETC want =
        new System.Runtime.InteropServices.ComTypes.FORMATETC();
      want.cfFormat = (short)cf;
      want.dwAspect = System.Runtime.InteropServices.ComTypes.DVASPECT.DVASPECT_CONTENT;
      want.lindex = -1;
      want.tymed = System.Runtime.InteropServices.ComTypes.TYMED.TYMED_HGLOBAL;
      System.Runtime.InteropServices.ComTypes.STGMEDIUM got =
        new System.Runtime.InteropServices.ComTypes.STGMEDIUM();
      got.unionmember = IntPtr.Zero;
      try { data.GetData(ref want, out got); } catch { return null; }
      try {
        if (got.tymed != System.Runtime.InteropServices.ComTypes.TYMED.TYMED_HGLOBAL) { return null; }
        return ReadHandle(got.unionmember, format == "HTML Format");
      } catch { return null; } finally {
        try { ReleaseStgMedium(ref got); } catch { }
      }
    }

    private static byte[] ReadBlock(uint format, bool html) {
      if (format == 0) { return null; }
      return ReadHandle(GetClipboardData(format), html);
    }

    // ---- what the source says about being recorded ------------------------------------
    // Two documented formats tell a clipboard tool to keep its hands off, and the applications
    // that publish passwords set them: ExcludeClipboardContentFromMonitorProcessing (the format
    // is the message, its data is nothing) and CanIncludeInClipboardHistory = 0, which is what
    // Windows' own history honours. A tool that records them anyway is the one that shows the
    // password in a list the user scrolls through an hour later. Ditto asks the same question
    // (CClipboardViewer::GetIgnoreClipboardChange) and so does the shell's own history.
    //
    // '' means the snapshot may be recorded; the reason otherwise is what the log writes.
    [DllImport("user32.dll")] private static extern bool IsClipboardFormatAvailable(uint format);

    private static bool FormatPresent(string name) {
      uint cf = RegisterClipboardFormat(name);
      return cf != 0 && IsClipboardFormatAvailable(cf);
    }

    // a DWORD format, read through one open; false when the format is absent or not a DWORD
    private static bool TryFormatDword(string name, out int value) {
      value = 0;
      uint cf = RegisterClipboardFormat(name);
      if (cf == 0) { return false; }
      if (!OpenClipboard(IntPtr.Zero)) { return false; }
      try {
        IntPtr handle = GetClipboardData(cf);
        if (handle == IntPtr.Zero) { return false; }
        IntPtr block = GlobalLock(handle);
        if (block == IntPtr.Zero) { return false; }
        try { value = Marshal.ReadInt32(block); return true; } catch { return false; }
        finally { GlobalUnlock(handle); }
      } catch {
        return false;
      } finally { CloseClipboard(); }
    }

    public static string ClipboardExclusion() {
      if (FormatPresent("ExcludeClipboardContentFromMonitorProcessing")) { return "the source excludes itself from clipboard tools"; }
      if (FormatPresent("Clipboard Viewer Ignore")) { return "the source asked clipboard viewers to ignore it"; }
      int include;
      if (TryFormatDword("CanIncludeInClipboardHistory", out include) && include == 0) {
        return "the source is not meant for the clipboard history";
      }
      return "";
    }

    // ---- an elevated window cannot be pasted into -------------------------------------
    // A window whose process holds the administrator token ignores injected keys from a process
    // that does not: nothing arrives and nothing fails, which reads as "the panel is broken".
    // ClipAngel answers this case with a message of its own; here the caller does the same. The
    // token calls above are reused - TokenElevation is another single DWORD out of the same
    // question, and false for a process that cannot be opened (protected, or already gone).
    public static bool IsElevated(uint pid) {
      if (pid == 0) { return false; }
      IntPtr process = IntPtr.Zero;
      IntPtr token = IntPtr.Zero;
      try {
        process = OpenProcess(0x1000, false, pid);                                  // PROCESS_QUERY_LIMITED_INFORMATION
        if (process == IntPtr.Zero) { return false; }
        if (!OpenProcessToken(process, 0x0008, out token)) { return false; }        // TOKEN_QUERY
        int value;
        int needed;
        if (!GetTokenInformation(token, 20, out value, 4, out needed)) { return false; }   // TokenElevation
        return value != 0;
      } catch {
        return false;
      } finally {
        if (token != IntPtr.Zero) { CloseHandle(token); }
        if (process != IntPtr.Zero) { CloseHandle(process); }
      }
    }

    // CF_DIB is a global memory block too, but it is allocated in whole pages: the block is cut
    // back to the size its own header describes, so a paste and a decode see only the bitmap
    private static byte[] ReadDib() {
      byte[] raw = ReadHandle(GetClipboardData(8), false);
      if (raw == null) { return null; }
      long size = DibSize(raw);
      if (size <= 0 || size >= raw.Length) { return raw; }
      byte[] trimmed = new byte[size];
      Array.Copy(raw, trimmed, size);
      return trimmed;
    }

    private static long DibSize(byte[] data) {
      if (data.Length < 40) { return data.Length; }
      uint header = BitConverter.ToUInt32(data, 0);
      uint compression = BitConverter.ToUInt32(data, 16);
      if (compression == 4 || compression == 5) { return data.Length; }   // embedded jpeg / png
      int width = BitConverter.ToInt32(data, 4);
      int height = Math.Abs(BitConverter.ToInt32(data, 8));
      int bitCount = BitConverter.ToUInt16(data, 14);
      uint clrUsed = BitConverter.ToUInt32(data, 32);
      long extra = (compression == 3 || compression == 6) ? 12 : 0;
      long palette = 0;
      if (clrUsed > 0) { palette = (long)clrUsed * 4; }
      else if (bitCount > 0 && bitCount <= 8) { palette = (long)(1 << bitCount) * 4; }
      long stride = ((long)width * bitCount + 31) / 32 * 4;
      long total = header + extra + palette + stride * height;
      if (total <= 0 || total > data.Length) { return data.Length; }
      return total;
    }

    // CF_ENHMETAFILE is a GDI handle, not a memory block: its bits have to be copied out
    private static byte[] ReadEmf() {
      IntPtr handle = GetClipboardData(RegisterClipboardFormat("EnhancedMetafile"));
      if (handle == IntPtr.Zero) { return null; }
      uint size = GetEnhMetaFileBits(handle, 0, null);
      if (size == 0) { return null; }
      byte[] bits = new byte[size];
      if (GetEnhMetaFileBits(handle, size, bits) == 0) { return null; }
      return bits;
    }

    private static byte[] ReadHandle(IntPtr handle, bool html) {
      if (handle == IntPtr.Zero) { return null; }
      long size = (long)GlobalSize(handle);
      if (size <= 0) { return null; }
      IntPtr p = GlobalLock(handle);
      if (p == IntPtr.Zero) { return null; }
      try {
        byte[] raw = new byte[size];
        Marshal.Copy(p, raw, 0, (int)size);
        return TrimBlock(raw, html);
      } finally { GlobalUnlock(handle); }
    }

    // the block is rounded up to the allocator's step, so the tail is dropped: html stops at
    // the EndHTML byte offset it declares, rtf at its closing brace (a trailing NUL is padding)
    private static byte[] TrimBlock(byte[] raw, bool html) {
      int end = raw.Length;
      if (html) {
        string head = System.Text.Encoding.ASCII.GetString(raw, 0, Math.Min(raw.Length, 512));
        int at = head.IndexOf("EndHTML:", StringComparison.Ordinal);
        if (at >= 0) {
          long n = 0;
          bool digits = false;
          for (int i = at + 8; i < head.Length; i++) {
            char c = head[i];
            if (c < '0' || c > '9') { break; }
            n = n * 10 + (c - '0');
            digits = true;
          }
          if (digits && n > 0 && n <= raw.Length) { end = (int)n; }
        }
      }
      while (end > 0 && raw[end - 1] == 0) { end--; }
      if (end == raw.Length) { return raw; }
      byte[] trimmed = new byte[end];
      Array.Copy(raw, trimmed, end);
      return trimmed;
    }
  }
  // Rtf moved to src\main\media\rtf.cs, with the note on why the braces are counted by hand.
}


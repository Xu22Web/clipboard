using System;
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
    // control can show it again. lib/panel/picker.ps1 keeps the count.
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
  // Every {\pict ...} group of an RTF becomes a marker, whatever it nests - Word writes the
  // hex behind {\*\picprop{\sp{\sn shapeType}...}} chains, which no regex can follow without
  // risking a backtracking stall on a 13 MB document. A brace counter is linear and exact.
  public static class Rtf {
    // Replaces every {\pict ...} group with a marker paragraph tall enough for the block the
    // card paints over it, and reports each block as a w,rows pair in document order.
    // \picwgoal / \pichgoal are twips (1/20 point) and \picw / \pich are pixels, so a picture
    // that states its size keeps its proportions instead of becoming one fixed rectangle.
    // One pass, no copy of a picture block: the control words are read inside [i,j] of the
    // original string, which is what keeps a 10 MB document off the seconds budget.
    public static string PadPictures(string text, string token, int lineHeight, int maxWidth, int minWidth, int defaultRows, out int[] boxes) {
      boxes = new int[0];
      if (string.IsNullOrEmpty(text) || lineHeight < 1 || maxWidth < 1) { return text; }
      int n = text.Length;
      System.Text.StringBuilder sb = null;
      System.Collections.Generic.List<int> found = new System.Collections.Generic.List<int>();
      int i = 0;
      int start = 0;
      while (i < n) {
        char c = text[i];
        if (c != '{' || i + 6 > n || string.CompareOrdinal(text, i, "{\\pict", 0, 6) != 0) { i++; continue; }
        int depth = 0;
        int j = i;
        while (j < n) {
          char d = text[j];
          if (d == '\\') { j += 2; continue; }
          if (d == '{') { depth++; }
          else if (d == '}') { depth--; if (depth == 0) { break; } }
          j++;
        }
        if (j >= n) { break; }
        if (sb == null) { sb = new System.Text.StringBuilder(n); }
        sb.Append(text, start, i - start);
        int picW = SizeIn(text, i, j, "\\picwgoal", "\\picw", 15);
        int picH = SizeIn(text, i, j, "\\pichgoal", "\\pich", 15);
        int w = maxWidth;
        int rows = defaultRows;
        if (picW > 0 && picH > 0) {
          if (picW < w) { w = picW; }
          if (w < minWidth) { w = minWidth; }
          long h = (long)picH * w / picW;
          rows = (int)((h + lineHeight - 1) / lineHeight);
          if (rows < 1) { rows = 1; }
          if (rows > 24) { rows = 24; }
        }
        if (w < minWidth) { w = minWidth; }
        sb.Append("\\par");
        sb.Append(token);
        for (int k = 0; k < rows; k++) { sb.Append("\\par"); }
        found.Add(w);
        found.Add(rows);
        i = j + 1;
        start = i;
      }
      if (sb == null) { return text; }
      sb.Append(text, start, n - start);
      boxes = found.ToArray();
      return sb.ToString();
    }

    // twips are twip/divisor pixels at 96 dpi (1 pt = 20 twips = 4/3 px), while \picw is
    // already a pixel count - the divisor says which control word answered
    private static int SizeIn(string text, int from, int to, string goal, string plain, int divisor) {
      int v = ValueIn(text, from, to, goal);
      if (v > 0) { return v / divisor; }
      return ValueIn(text, from, to, plain);
    }

    // first occurrence inside [from,to) of the control word followed by a number, so "\picw"
    // does not answer from inside "\picwgoal"
    private static int ValueIn(string text, int from, int to, string word) {
      int at = from;
      while (at < to) {
        at = text.IndexOf(word, at, to - at, System.StringComparison.OrdinalIgnoreCase);
        if (at < 0) { return 0; }
        int p = at + word.Length;
        int digits = p;
        if (p < to && text[p] == '-') { p++; }
        while (p < to && text[p] >= '0' && text[p] <= '9') { p++; }
        if (p > digits) {
          int v;
          if (int.TryParse(text.Substring(digits, p - digits), out v)) { return v; }
        }
        at = p;
      }
      return 0;
    }
  }
  // RTF into a bitmap: a RichTextBox lays a document out into a device context through
  // EM_FORMATRANGE, which works while the control is not on screen at all. DrawToBitmap on
  // an unparented control renders nothing, so the preview card (lib/media.ps1) uses this.
  public static class Rich {
    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    private struct FORMATRANGE {
      public IntPtr hdc;
      public IntPtr hdcTarget;
      public RECT rc;
      public RECT rcPage;
      public int cpMin;
      public int cpMax;
    }
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, ref FORMATRANGE lParam);
    public static string LastError = "";
    public static bool RenderTo(System.Windows.Forms.RichTextBox box, System.Drawing.Graphics g, int width, int height) {
      const int EM_FORMATRANGE = 0x0400 + 57;
      // the dpi has to be read before the device context is taken: while its hdc is out the
      // Graphics is locked and any other property access throws
      double dpi = g.DpiX > 0 ? g.DpiX : 96.0;
      IntPtr hdc = IntPtr.Zero;
      try {
        hdc = g.GetHdc();
        FORMATRANGE fr = new FORMATRANGE();
        fr.hdc = hdc;
        fr.hdcTarget = hdc;
        fr.rc.Left = 0;
        fr.rc.Top = 0;
        fr.rc.Right = (int)(width * 1440.0 / dpi);
        fr.rc.Bottom = (int)(height * 1440.0 / dpi);
        fr.rcPage = fr.rc;
        fr.cpMin = 0;
        fr.cpMax = -1;
        SendMessage(box.Handle, EM_FORMATRANGE, (IntPtr)1, ref fr);
        // wParam 0 frees the layout the control cached for this range
        SendMessage(box.Handle, EM_FORMATRANGE, IntPtr.Zero, ref fr);
        return true;
      } catch (Exception ex) {
        LastError = ex.GetType().Name + ": " + ex.Message;
        return false;
      } finally {
        if (hdc != IntPtr.Zero) { g.ReleaseHdc(hdc); }
      }
    }
  }
  // The taskbar groups windows by the process's AppUserModelID and takes the button's icon from
  // the group, not from the window: a script host keeps the AUMID of its own executable, so a
  // window that sets its icon still shows the host's mark on the bar and in Alt-Tab. Declaring
  // an ID of our own before the first window exists puts the window in a group of ours, and the
  // group has no icon of its own, so the bar falls back to the window's (measured: the window
  // icon alone left the PowerShell mark, the ID plus the icon shows the tool's drawing).
  public static class Shell {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=true)]
    static extern int SetCurrentProcessExplicitAppUserModelID(string id);
    public static bool SetAppId(string id) {
      if (String.IsNullOrEmpty(id)) { return false; }
      return SetCurrentProcessExplicitAppUserModelID(id) == 0;
    }
  }
  // The tray icon is drawn here instead of being loaded from a file: there is no asset to
  // ship, and every size is rendered at its own resolution rather than scaled down from one
  // bitmap, which is what makes a bitmap icon look soft at 125% and 150% scaling.
  public static class Tray {
    [DllImport("user32.dll", SetLastError=true)] static extern bool DestroyIcon(IntPtr h);
    static System.Drawing.Drawing2D.GraphicsPath Round(float x, float y, float w, float h, float r) {
      System.Drawing.Drawing2D.GraphicsPath p = new System.Drawing.Drawing2D.GraphicsPath();
      float d = r * 2f;
      p.AddArc(x, y, d, d, 180f, 90f);
      p.AddArc(x + w - d, y, d, d, 270f, 90f);
      p.AddArc(x + w - d, y + h - d, d, d, 0f, 90f);
      p.AddArc(x, y + h - d, d, d, 90f, 90f);
      p.CloseFigure();
      return p;
    }
    // toward the given colour by percent, so one base colour yields the board, the clip and
    // the two lines without a second palette to keep in step
    static System.Drawing.Color Mix(System.Drawing.Color c, System.Drawing.Color with, int percent) {
      if (percent < 0) { percent = 0; }
      if (percent > 100) { percent = 100; }
      int a = percent, b = 100 - percent;
      return System.Drawing.Color.FromArgb(
        (c.A * b + with.A * a) / 100,
        (c.R * b + with.R * a) / 100,
        (c.G * b + with.G * a) / 100,
        (c.B * b + with.B * a) / 100);
    }
    // 16 px is the reference drawing: the clip at the top, the board under it and two lines of
    // text inside the board. Every size scales that one drawing, with nothing added or dropped:
    // the tray and a window draw the same mark, and a mark that grows a third line at 24 px is
    // a different picture at the two sizes the shell asks for on one screen.
    public static System.Drawing.Bitmap BuildBitmap(int size, int argb) {
      if (size < 16) { size = 16; }
      System.Drawing.Bitmap bmp = new System.Drawing.Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
      System.Drawing.Graphics g = System.Drawing.Graphics.FromImage(bmp);
      System.Drawing.Color fill = System.Drawing.Color.FromArgb(argb);
      try {
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        g.Clear(System.Drawing.Color.Transparent);
        float u = size / 16f;
        // board, the sheet of paper in it, the clip over the top of the sheet and the lines
        // on the sheet: that order is what reads as a clipboard at 16 px instead of a
        // rectangle with a tab
        using (System.Drawing.SolidBrush b = new System.Drawing.SolidBrush(fill))
        using (System.Drawing.Drawing2D.GraphicsPath p = Round(2.2f * u, 2.8f * u, 11.6f * u, 12.2f * u, 1.7f * u)) { g.FillPath(b, p); }
        using (System.Drawing.SolidBrush b = new System.Drawing.SolidBrush(Mix(fill, System.Drawing.Color.White, 92)))
        using (System.Drawing.Drawing2D.GraphicsPath p = Round(3.8f * u, 4.6f * u, 8.4f * u, 9.2f * u, 0.9f * u)) { g.FillPath(b, p); }
        using (System.Drawing.SolidBrush b = new System.Drawing.SolidBrush(Mix(fill, System.Drawing.Color.Black, 45)))
        using (System.Drawing.Drawing2D.GraphicsPath p = Round(5.7f * u, 1.0f * u, 4.6f * u, 4.4f * u, 1.4f * u)) { g.FillPath(b, p); }
        using (System.Drawing.SolidBrush b = new System.Drawing.SolidBrush(Mix(fill, System.Drawing.Color.Black, 12))) {
          using (System.Drawing.Drawing2D.GraphicsPath p = Round(5.0f * u, 7.4f * u, 5.4f * u, 1.4f * u, 0.7f * u)) { g.FillPath(b, p); }
          using (System.Drawing.Drawing2D.GraphicsPath p = Round(5.0f * u, 10.2f * u, 4.2f * u, 1.4f * u, 0.7f * u)) { g.FillPath(b, p); }
        }
      } finally { g.Dispose(); }
      return bmp;
    }
    // One icon carrying every size the shell may ask for: the tray asks for 16 * dpi, a taskbar
    // button for 24, Alt-Tab for 32 or 48. Each entry is drawn at its own size, so nothing is
    // scaled: a window that hands the bar a single 32 px icon gets a resampled 24 px one, which
    // is what made its button look soft beside the tray's. The entries are DIBs, not PNGs -
    // Windows reads a PNG entry, but System.Drawing's Icon does not (ToBitmap throws), and the
    // same stream has to be readable by both.
    public static System.Drawing.Icon BuildIcon(int[] sizes, int argb) {
      int count = (sizes == null || sizes.Length == 0) ? 1 : sizes.Length;
      int[] px = new int[count];
      byte[][] dib = new byte[count][];
      for (int i = 0; i < count; i++) {
        int s = (sizes == null || sizes.Length == 0) ? 16 : sizes[i];
        if (s < 16) { s = 16; }
        if (s > 256) { s = 256; }
        px[i] = s;
        dib[i] = IconDib(s, argb);
      }
      using (System.IO.MemoryStream ms = new System.IO.MemoryStream()) {
        using (System.IO.BinaryWriter w = new System.IO.BinaryWriter(ms, System.Text.Encoding.UTF8, true)) {
          w.Write((ushort)0);
          w.Write((ushort)1);
          w.Write((ushort)count);
          int offset = 6 + 16 * count;
          for (int i = 0; i < count; i++) {
            byte dim = (byte)(px[i] >= 256 ? 0 : px[i]);
            w.Write(dim);
            w.Write(dim);
            w.Write((byte)0);
            w.Write((byte)0);
            w.Write((ushort)1);
            w.Write((ushort)32);
            w.Write((uint)dib[i].Length);
            w.Write((uint)offset);
            offset += dib[i].Length;
          }
          for (int i = 0; i < count; i++) { w.Write(dib[i]); }
        }
        ms.Position = 0;
        return new System.Drawing.Icon(ms);
      }
    }
    // The tray is the one place that asks for a single size, and Shell_NotifyIcon wants an icon
    // handle rather than a stream: the same bitmap, turned into an HICON at the size the tray
    // draws. A window takes BuildIcon instead.
    public static IntPtr Build(int size, int argb) {
      System.Drawing.Bitmap bmp = BuildBitmap(size, argb);
      try { return bmp.GetHicon(); } finally { bmp.Dispose(); }
    }
    public static void Free(IntPtr h) { if (h != IntPtr.Zero) { DestroyIcon(h); } }
    // One icon entry: a header, the pixels bottom-up in 32 bits with their alpha, and the
    // 1 bit mask that older shell code still reads (a transparent pixel is a set bit there).
    static byte[] IconDib(int size, int argb) {
      int stride = size * 4;
      int maskStride = ((size + 31) / 32) * 4;
      byte[] data = new byte[40 + (stride * size) + (maskStride * size)];
      System.Drawing.Bitmap bmp = BuildBitmap(size, argb);
      try {
        System.Drawing.Imaging.BitmapData bd = bmp.LockBits(
          new System.Drawing.Rectangle(0, 0, size, size),
          System.Drawing.Imaging.ImageLockMode.ReadOnly,
          System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        byte[] row = new byte[stride];
        try {
          for (int y = 0; y < size; y++) {
            System.Runtime.InteropServices.Marshal.Copy(
              new IntPtr(bd.Scan0.ToInt64() + (long)(size - 1 - y) * bd.Stride), row, 0, stride);
            Buffer.BlockCopy(row, 0, data, 40 + (y * stride), stride);
            int mbase = 40 + (stride * size) + (y * maskStride);
            for (int x = 0; x < size; x++) {
              if (row[(x * 4) + 3] < 128) { data[mbase + (x / 8)] |= (byte)(0x80 >> (x % 8)); }
            }
          }
        } finally { bmp.UnlockBits(bd); }
        // biSize, biWidth, biHeight (pixels and mask), planes, 32 bpp, no compression
        BitConverter.GetBytes(40).CopyTo(data, 0);
        BitConverter.GetBytes(size).CopyTo(data, 4);
        BitConverter.GetBytes(size * 2).CopyTo(data, 8);
        BitConverter.GetBytes((short)1).CopyTo(data, 12);
        BitConverter.GetBytes((short)32).CopyTo(data, 14);
        BitConverter.GetBytes(stride * size).CopyTo(data, 20);
      } finally { bmp.Dispose(); }
      return data;
    }
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
    // The panel activates; a preview card raised by the panel must not, or the panel would
    // lose the foreground and close.
    public bool Activates = false;
    public FluentForm() { DoubleBuffered = true; }
    protected override bool ShowWithoutActivation { get { return !Activates; } }
    protected override System.Windows.Forms.CreateParams CreateParams {
      get {
        var cp = base.CreateParams;
        if (!Activates) { cp.ExStyle |= 0x08000000; }   // WS_EX_NOACTIVATE
        // Compositing makes the DWM assemble each frame off-screen, which keeps the child
        // controls from sitting half-painted while the window is moved. It is not what fixes
        // the row flicker (Cb.PinList buffers its own paint, lib/panel/pinlist.ps1), but the
        // panel needs it for its child controls.
        cp.ExStyle |= 0x02000000;   // WS_EX_COMPOSITED
        cp.ClassStyle |= 0x00020000;
        return cp;
      }
    }
  }

  // ---- the row surface (see lib/panel/pinlist.ps1 for why it exists) -------------------
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
    private int itemHeight = 40;
    // the row height as a property: a caller that changes it mid-life would otherwise leave
    // the pixel offset pointing into a row that no longer exists
    public int ItemHeight {
      get { return itemHeight; }
      set { itemHeight = value < 1 ? 1 : value; Invalidate(); }
    }
    // rows at the very top that never scroll: the pinned block
    public int PinnedCount = 0;
    public System.Drawing.Color SeparatorColor = System.Drawing.Color.Empty;
    // rows one wheel notch scrolls; the host keeps it current, because only it knows how many
    // rows the panel shows and how many of those are frozen at the top
    public int WheelRows = 0;

    private int topIndex = 0;
    private int selected = -1;
    private int updates = 0;
    // wheel movement carried between events, in pixels * 120
    private long wheelPix = 0;

    public event EventHandler DrawItem;
    public event EventHandler SelectedIndexChanged;
    // raised whenever the top row moves, so the host can move its scrollbar thumb too
    public event EventHandler ScrollChanged;
    // raised on a left click, together with what else was held: the host owns the rules for
    // Ctrl / Shift, this control only reports what happened and paints what it is told
    public event EventHandler RowClicked;
    public readonly System.Collections.Generic.HashSet<int> MultiSelect = new System.Collections.Generic.HashSet<int>();
    public int AnchorIndex = -1;
    public bool ClickHadControl = false;
    public bool ClickHadShift = false;
    public int ClickRow = -1;

    public PinList() {
      SetStyle(System.Windows.Forms.ControlStyles.UserPaint |
               System.Windows.Forms.ControlStyles.AllPaintingInWmPaint |
               System.Windows.Forms.ControlStyles.OptimizedDoubleBuffer |
               System.Windows.Forms.ControlStyles.ResizeRedraw, true);
      TabStop = false;
    }

    // first scrollable row on screen; never points into the frozen block
    public int TopIndex { get { return topIndex; } set { SetTop(value); } }

    // Distance the scrolling part has moved, in pixels: where it is and how far it can go.
    // The host maps both onto the thumb. Both are whole rows, because that is all the list
    // has: a row cut in half under a dragged thumb reads as a broken table.
    public int ScrollY { get { return topIndex * itemHeight; } }
    public int ScrollMax { get { return MaxTop * itemHeight; } }

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
    public void ScrollToPixel(int y) { SetScroll(y); }

    // A wheel event is not always one notch: a precision touchpad sends deltas well under 120
    // and a spun wheel sends several notches in one event. The movement is summed until it
    // covers a whole row, and only then does the list move - a row is the only landing point
    // it has, so the result is stepped rather than smeared, and one event never crosses a
    // whole screen.
    public void WheelBy(int delta) {
      if (itemHeight <= 0) return;
      int step = WheelRows > 0 ? WheelRows : 1;
      // a notch is WheelRows rows, and delta counts 1/120 of a notch
      wheelPix += (long)delta * step * itemHeight;
      int px = (int)(wheelPix / 120);
      if (px == 0) return;
      // half a row is enough: the list answers as soon as the movement is closer to the next
      // row than to where it started
      int rows = (int)Math.Round(px / (double)itemHeight, MidpointRounding.AwayFromZero);
      if (rows == 0) return;
      wheelPix -= (long)rows * itemHeight * 120;
      int room = VisibleRows - PinnedCount - 1;
      if (room < 1) room = 1;
      if (rows > room) rows = room;
      if (rows < -room) rows = -room;
      SetTop(topIndex - rows);
    }

    // scroll just enough to show one row; a frozen row is always visible already
    public void EnsureVisible(int index) {
      if (index < 0 || index < PinnedCount) return;
      int vis = VisibleRows - PinnedCount;
      if (vis < 1) return;
      if (index < topIndex) SetTop(index);
      else if (index >= topIndex + vis) SetTop(index - vis + 1);
    }

    private void SetTop(int value) {
      if (itemHeight <= 0) return;
      SetScroll(value * itemHeight);
    }

    // The one place the scroll position changes. A row is the smallest unit the list moves in:
    // the position is clamped between the frozen block and the last row, then rounded to the
    // nearest row, whatever the caller asked for (a thumb position, a wheel remainder).
    private void SetScroll(int y) {
      if (itemHeight <= 0) return;
      int min = PinnedCount * itemHeight;
      int max = ScrollMax;
      if (max < min) max = min;
      if (y < min) y = min;
      if (y > max) y = max;
      int ti = (y + (itemHeight / 2)) / itemHeight;
      if ((ti * itemHeight) > max) { ti = max / itemHeight; }
      if (ti == topIndex) return;
      topIndex = ti;
      Invalidate();
      EventHandler h = ScrollChanged;
      if (h != null) h(this, EventArgs.Empty);
    }

    // a refresh replaces what is under the pointer, so a half notch from before it is dropped
    public void BeginUpdate() { updates++; wheelPix = 0; }
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
      if (index < PinnedCount) y = index * itemHeight;
      else y = (PinnedCount + index - topIndex) * itemHeight;
      return new System.Drawing.Rectangle(0, y, ClientSize.Width, itemHeight);
    }

    public int IndexFromPoint(System.Drawing.Point pt) {
      if (itemHeight <= 0 || ItemCount == 0) return -1;
      int slot = pt.Y / itemHeight;
      if (slot < 0) return -1;
      int i;
      if (slot < PinnedCount) i = slot;
      else i = topIndex + slot - PinnedCount;
      return (i >= 0 && i < ItemCount) ? i : -1;
    }

    public bool IsMulti(int index) { return MultiSelect.Contains(index); }

    // A plain Control treats the arrow keys as dialog keys: the container answers them to move
    // the focus, so the panel's key handler never sees them and the selection cannot be walked
    // with them. This control is navigated by those keys - the host owns what one does - so it
    // reports them as input keys. Home/End/PageUp/PageDown are listed for the same reason: the
    // host decides whether they belong to the list or to the search field.
    protected override bool IsInputKey(System.Windows.Forms.Keys keyData) {
      switch (keyData & System.Windows.Forms.Keys.KeyCode) {
        case System.Windows.Forms.Keys.Up:
        case System.Windows.Forms.Keys.Down:
        case System.Windows.Forms.Keys.Left:
        case System.Windows.Forms.Keys.Right:
        case System.Windows.Forms.Keys.Home:
        case System.Windows.Forms.Keys.End:
        case System.Windows.Forms.Keys.PageUp:
        case System.Windows.Forms.Keys.PageDown:
          return true;
      }
      return base.IsInputKey(keyData);
    }

    // Clicking a row selects it. A plain Control has no built-in hit testing the way a
    // ListBox does, so the host would otherwise have to wire this per panel.
    protected override void OnMouseDown(System.Windows.Forms.MouseEventArgs e) {
      if (e.Button == System.Windows.Forms.MouseButtons.Left) {
        ClickHadControl = (System.Windows.Forms.Control.ModifierKeys & System.Windows.Forms.Keys.Control) != 0;
        ClickHadShift = (System.Windows.Forms.Control.ModifierKeys & System.Windows.Forms.Keys.Shift) != 0;
        int i = IndexFromPoint(e.Location);
        ClickRow = i;
        if (i >= 0) SelectedIndex = i;
        EventHandler h = RowClicked;
        if (h != null && i >= 0) h(this, EventArgs.Empty);
      }
      base.OnMouseDown(e);
    }

    // A ListBox scrolls itself on the wheel; this one has to do it too, or the event would
    // just bubble to the parent and nothing would move.
    protected override void OnMouseWheel(System.Windows.Forms.MouseEventArgs e) {
      WheelBy(e.Delta);
      System.Windows.Forms.HandledMouseEventArgs h = e as System.Windows.Forms.HandledMouseEventArgs;
      if (h != null) h.Handled = true;
      base.OnMouseWheel(e);
    }

    protected override void OnPaint(System.Windows.Forms.PaintEventArgs e) {
      System.Drawing.Graphics g = e.Graphics;
      using (System.Drawing.SolidBrush back = new System.Drawing.SolidBrush(BackColor)) { g.FillRectangle(back, ClientRectangle); }
      if (updates > 0 || itemHeight <= 0) return;
      int pinned = Math.Min(PinnedCount, ItemCount);
      for (int i = 0; i < pinned; i++) { PaintRow(g, i, i * itemHeight); }
      if (pinned > 0 && SeparatorColor != System.Drawing.Color.Empty) {
        using (System.Drawing.Pen pen = new System.Drawing.Pen(SeparatorColor)) {
          g.DrawLine(pen, 0, (pinned * itemHeight) - 1, ClientSize.Width, (pinned * itemHeight) - 1);
        }
      }
      int y = pinned * itemHeight;
      int k = topIndex;
      while (k < ItemCount && y < ClientSize.Height) {
        PaintRow(g, k, y);
        y += itemHeight;
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

  // ---- the tray menu (lib/panel/tray-menu.ps1) -----------------------------------------
  // Windows draws a menu in the system colours: a light surface with the system font, beside a
  // panel and a settings window that are both drawn from one palette. This menu is drawn from
  // that palette instead - the same surface and the same frame as the other windows, a glyph
  // column, rows that light up the way a panel row does, a right-hand column for a hint or a
  // switch, and hairlines instead of the system's etched separators.
  //
  // The numbers arrive already multiplied by the DPI scale, like every other pixel constant in
  // the tool (utils/dpi.ps1), so nothing here has to know about scaling.
  public class TraySkin {
    public System.Drawing.Color Surface = System.Drawing.Color.FromArgb(32, 32, 32);
    public System.Drawing.Color Border = System.Drawing.Color.Empty;
    public System.Drawing.Color Text = System.Drawing.Color.White;
    public System.Drawing.Color Dim = System.Drawing.Color.FromArgb(170, 170, 170);
    public System.Drawing.Color Faint = System.Drawing.Color.FromArgb(138, 138, 138);
    public System.Drawing.Color Accent = System.Drawing.Color.FromArgb(96, 205, 255);
    // the ink a destructive row and its glyph take: a remove is not the same weight as a paste
    public System.Drawing.Color Warn = System.Drawing.Color.Empty;
    // hover and pressed come from the theme as translucent overlays; an empty colour means the
    // row does not light up at all
    public System.Drawing.Color Hover = System.Drawing.Color.Empty;
    public System.Drawing.Color Selected = System.Drawing.Color.Empty;
    // the hairline between groups: the window border is far too faint for a line inside the
    // surface, so the caller resolves a stronger token for it
    public System.Drawing.Color Separator = System.Drawing.Color.Empty;
    // the switch: the field colour for the track that is off, the accent for the one that is on
    public System.Drawing.Color Field = System.Drawing.Color.Empty;
    public System.Drawing.Color FieldBorder = System.Drawing.Color.Empty;
    public System.Drawing.Font Body;
    public System.Drawing.Font Small;
    public System.Drawing.Font Glyph;
    // the 96 dpi fallback for a menu built without a skin from the tool: lib\panel\tray-menu.ps1
    // resolves every one of these through Px(), and that is what the resident uses
    public int Width = 222;
    public int RowHeight = 28;
    public int Radius = 8;
    public int RowRadius = 5;
    public int PadLeft = 9;
    public int PadRight = 11;
    public int GlyphBox = 18;
    public int Gap = 8;
    public int Top = 4;
    public int Bottom = 4;
    // how far an icon moves down to sit on the optical centre of the words beside it: a text
    // line's ink sits below the middle of its box and an icon's ink above its own. Filled in from
    // one measurement by lib\panel\tray-menu.ps1, not per glyph.
    public int IconDrop = 0;
    public int SeparatorInset = 9;
    // MenuFlyoutSeparator is a 1 px rectangle with a -4,1,-4,1 padding, so the row it occupies is
    // 3 px: one pixel of air above the line and one below it
    public int SeparatorHeight = 3;
    public int SwitchWidth = 26;
    public int SwitchHeight = 14;
    // the highlight is inset from the edge, the way a panel row is: a row that touches the
    // frame reads as part of the window edge
    public int RowInset = 3;
  }

  // One row, painted whole: the strip never draws a row, so the layout of a row (glyph, label,
  // hint or switch) lives in exactly one place. A header row is the same layout without the
  // hover state - it names the menu and carries the count.
  public class TrayItem : System.Windows.Forms.ToolStripMenuItem {
    public TraySkin Skin;
    public string Glyph = "";
    public string Hint = "";
    public bool IsHeader = false;
    public bool IsSwitch = false;
    // A caption names the group under it in the quiet ink at caption size: it is a label, not a
    // row, and the two inks below let one action stand out (the accent) or warn (the warn token)
    public bool IsCaption = false;
    // a row that only carries a hairline: the system separator keeps a height of its own, so the
    // menu draws its own and gets the 1 px line and the air around it it asked for
    public bool IsSeparator = false;
    public System.Drawing.Color Ink = System.Drawing.Color.Empty;
    public System.Drawing.Color GlyphInk = System.Drawing.Color.Empty;

    static readonly System.Drawing.StringFormat LeftFmt = MakeFormat(System.Drawing.StringAlignment.Near, false);
    static readonly System.Drawing.StringFormat RightFmt = MakeFormat(System.Drawing.StringAlignment.Far, false);
    static readonly System.Drawing.StringFormat GlyphFmt = MakeFormat(System.Drawing.StringAlignment.Center, true);

    static System.Drawing.StringFormat MakeFormat(System.Drawing.StringAlignment a, bool noTrim) {
      System.Drawing.StringFormat f = new System.Drawing.StringFormat();
      f.Alignment = a;
      f.LineAlignment = System.Drawing.StringAlignment.Center;
      f.FormatFlags = System.Drawing.StringFormatFlags.NoWrap | System.Drawing.StringFormatFlags.NoClip;
      if (!noTrim) f.Trimming = System.Drawing.StringTrimming.EllipsisCharacter;
      return f;
    }

    // A click says which row was hit. It has to be recorded on the way down, not from the
    // click that follows: the strip decides whether to close before the row raises its own
    // Click, which is why a flag set in a handler arrives one row too late (measured).
    protected override void OnMouseDown(System.Windows.Forms.MouseEventArgs e) {
      TrayMenu m = Parent as TrayMenu;
      if (m != null) { m.Clicked = this; }
      base.OnMouseDown(e);
    }

    protected override void OnClick(System.EventArgs e) {
      TrayMenu m = Parent as TrayMenu;
      if (m != null) { m.Clicked = this; }
      base.OnClick(e);
    }

    static System.Drawing.Drawing2D.GraphicsPath RoundRect(System.Drawing.Rectangle r, int radius) {
      System.Drawing.Drawing2D.GraphicsPath p = new System.Drawing.Drawing2D.GraphicsPath();
      int d = radius * 2;
      if (d <= 0 || d > r.Width || d > r.Height) { p.AddRectangle(r); return p; }
      p.AddArc(r.X, r.Y, d, d, 180f, 90f);
      p.AddArc(r.Right - d, r.Y, d, d, 270f, 90f);
      p.AddArc(r.Right - d, r.Bottom - d, d, d, 0f, 90f);
      p.AddArc(r.X, r.Bottom - d, d, d, 90f, 90f);
      p.CloseFigure();
      return p;
    }


    public TrayItem(string label, TraySkin skin) : base(label) {
      Skin = skin;
      AutoSize = false;
      Margin = System.Windows.Forms.Padding.Empty;
      Padding = System.Windows.Forms.Padding.Empty;
      Size = new System.Drawing.Size(skin.Width, skin.RowHeight);
      Font = skin.Body;
    }

    // the silhouette of the whole menu, for the window region the strip takes when it opens
    public static System.Drawing.Drawing2D.GraphicsPath RoundPath(int w, int h, int radius) {
      return RoundRect(new System.Drawing.Rectangle(0, 0, w, h), radius);
    }

    // A header is a label, not an action: an arrow key may not land on it and the hover tint
    // never lights it up. A click on it runs nothing and dismisses the menu the way any other
    // inert row does - ToolStripDropDown closes on an item click, and a title is not worth
    // holding the menu open for.
    public override bool CanSelect { get { return (IsHeader || IsCaption || IsSeparator) ? false : base.CanSelect; } }

    // the whole of one row: the background it lights up with, the glyph, the label and what the
    // right-hand column carries
    protected override void OnPaint(System.Windows.Forms.PaintEventArgs e) {
      System.Drawing.Graphics g = e.Graphics;
      // the same hint the panel and the settings window draw with, so the three surfaces
      // rasterise type the same way instead of whatever the system default happens to be
      System.Drawing.Text.TextRenderingHint hint = g.TextRenderingHint;
      g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
      try {
        PaintRow(g);
      } finally { g.TextRenderingHint = hint; }
    }

    void PaintRow(System.Drawing.Graphics g) {
      System.Drawing.Rectangle b = new System.Drawing.Rectangle(System.Drawing.Point.Empty, Size);
      if (IsSeparator) {
        // the hairline sits in the middle of the strip the row reserves for it, on a whole pixel:
        // a line at half a pixel is drawn twice, a pixel wide each time, and reads as 2 px of grey
        float mid = (Size.Height - 1) / 2f;
        System.Drawing.Color hair = Skin.Separator.A > 0 ? Skin.Separator : Skin.Border;
        using (System.Drawing.Pen pen = new System.Drawing.Pen(hair)) {
          g.DrawLine(pen, Skin.SeparatorInset, mid, b.Width - 1 - Skin.SeparatorInset, mid);
        }
        return;
      }
      bool hot = (Selected || Pressed) && Enabled && !IsHeader && !IsCaption;
      if (hot) {
        System.Drawing.Color fill = Pressed ? Skin.Selected : Skin.Hover;
        if (fill.A > 0) {
          System.Drawing.Drawing2D.SmoothingMode was = g.SmoothingMode;
          g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
          using (System.Drawing.Drawing2D.GraphicsPath p = RoundRect(
                   new System.Drawing.Rectangle(b.X + Skin.RowInset, b.Y, b.Width - 1 - (Skin.RowInset * 2), b.Height - 1), Skin.RowRadius))
          using (System.Drawing.SolidBrush br = new System.Drawing.SolidBrush(fill)) { g.FillPath(br, p); }
          g.SmoothingMode = was;
        }
      }
      System.Drawing.Color ink = Enabled ? Skin.Text : Skin.Faint;
      if (IsCaption) { ink = Skin.Dim; }
      if (Ink.A > 0) { ink = Ink; }
      if (!Enabled) { ink = Skin.Faint; }
      int x = Skin.PadLeft;
      if (Glyph.Length > 0 && Skin.Glyph != null) {
        System.Drawing.Color gc = Skin.Dim;
        if (!Enabled) { gc = Skin.Faint; }
        else if (GlyphInk.A > 0) { gc = GlyphInk; }
        else if (IsHeader) { gc = Skin.Accent; }
        // Segoe Fluent Icons gives every glyph the same advance and the same line box - measured at
        // 12 pt, fifteen of the ones this menu uses all come out 21.8 x 18.0 - so a glyph is centred
        // by its layout box, not by its ink, and the column lines up without a measurement per
        // glyph. The font asks to be set at 16, 20, 24, 32, 40, 48 or 64 px, and Px() keeps the box
        // on one of those, so the size is the theme's and nothing is rescaled.
        //
        // A glyph is one colour, so it is drawn with grayscale anti-aliasing: ClearType splits a
        // 1 px stroke into coloured subpixels, which reads as a heavier icon.
        System.Drawing.Text.TextRenderingHint ghint = g.TextRenderingHint;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        try {
          using (System.Drawing.SolidBrush br = new System.Drawing.SolidBrush(gc)) {
            g.DrawString(Glyph, Skin.Glyph, br,
              new System.Drawing.RectangleF(x, ((b.Height - Skin.GlyphBox) / 2f) + Skin.IconDrop, Skin.GlyphBox, Skin.GlyphBox), GlyphFmt);
          }
        } finally { g.TextRenderingHint = ghint; }
      }
      int labelX = x + Skin.GlyphBox + Skin.Gap;
      int rightW = 0;
      if (IsSwitch && Skin.Body != null) { rightW = Skin.SwitchWidth; }
      else if (Hint.Length > 0 && Skin.Small != null) {
        rightW = (int)System.Math.Ceiling(g.MeasureString(Hint, Skin.Small).Width);
      }
      int labelRight = b.Width - Skin.PadRight - (rightW > 0 ? rightW + Skin.Gap : 0);
      int labelW = labelRight - labelX;
      if (labelW > 0) {
        System.Drawing.Font face = (IsCaption && Skin.Small != null) ? Skin.Small : Skin.Body;
        using (System.Drawing.SolidBrush br = new System.Drawing.SolidBrush(ink)) {
          g.DrawString(Text, face, br,
            new System.Drawing.RectangleF(labelX, 0, labelW, b.Height), LeftFmt);
        }
      }
      if (IsSwitch) { PaintSwitch(g, b); }
      else if (Hint.Length > 0 && Skin.Small != null) {
        // the keyboard accelerator is secondary text in WinUI, not the disabled ink
        using (System.Drawing.SolidBrush br = new System.Drawing.SolidBrush(Skin.Dim)) {
          g.DrawString(Hint, Skin.Small, br,
            new System.Drawing.RectangleF(labelRight + Skin.Gap, 0, rightW, b.Height), RightFmt);
        }
      }
    }

    // A switch rather than a tick: the panel and the settings window are Fluent, and a tick in
    // a gutter belongs to the system menu that this one replaces. The knob is the surface on an
    // accent track and the dim ink on a field track, so it reads at both extremes.
    void PaintSwitch(System.Drawing.Graphics g, System.Drawing.Rectangle b) {
      int w = Skin.SwitchWidth, h = Skin.SwitchHeight;
      int x = b.Width - Skin.PadRight - w;
      int y = (b.Height - h) / 2;
      bool on = Checked;
      System.Drawing.Drawing2D.SmoothingMode was = g.SmoothingMode;
      g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
      try {
        System.Drawing.Rectangle track = new System.Drawing.Rectangle(x, y, w, h);
        using (System.Drawing.Drawing2D.GraphicsPath p = RoundRect(track, h / 2)) {
          using (System.Drawing.SolidBrush br = new System.Drawing.SolidBrush(on ? Skin.Accent : Skin.Field)) { g.FillPath(br, p); }
          if (!on && Skin.FieldBorder.A > 0) {
            using (System.Drawing.Pen pen = new System.Drawing.Pen(Skin.FieldBorder)) { g.DrawPath(pen, p); }
          }
        }
        int d = h - 4;
        int kx = on ? (x + w - 2 - d) : (x + 2);
        System.Drawing.Color knob = !Enabled ? Skin.Faint : (on ? Skin.Surface : Skin.Dim);
        using (System.Drawing.SolidBrush br = new System.Drawing.SolidBrush(knob)) {
          g.FillEllipse(br, kx, y + 2, d, d);
        }
      } finally { g.SmoothingMode = was; }
    }
  }

  // The strip itself paints only what a row cannot: the surface, the frame and the separators.
  // The region is rounded when the menu opens, so the silhouette matches the panel's instead of
  // the square one a menu gets, and the frame is filled as a one pixel ring rather than stroked
  // - a stroke on a curve covers half a pixel and the arcs come out paler than the sides.
  public class TrayMenu : System.Windows.Forms.ContextMenuStrip {
    public TraySkin Skin;
    // the row the last click landed on, so the close that follows knows what was hit
    public TrayItem Clicked;

    public TrayMenu(TraySkin skin) {
      Skin = skin;
      // the size is the skin's, not the labels': every row is laid out to one width so the
      // glyph column, the labels and the right-hand column line up all the way down
      AutoSize = false;
      Size = new System.Drawing.Size(skin.Width, skin.RowHeight);
      Margin = System.Windows.Forms.Padding.Empty;
      ShowImageMargin = false;
      ShowCheckMargin = false;
      DropShadowEnabled = false;
      Renderer = new TrayMenuRenderer(skin);
    }

    // The height follows from the rows that are there, so a hidden row does not leave a gap.
    //
    // Fit() has to run before the menu is first shown, not only when it opens: the drop-down
    // works out where it goes (flip above the cursor near the bottom edge) from the size it has
    // at that moment, and a menu that is still the one-row placeholder is placed as if it were
    // 32 px tall and then grows off the screen - the first right click after a start landed 27
    // px too low because of exactly that. lib\panel\tray-menu.ps1 calls it once the rows are in.
    public void Fit() {
      try {
        int top = System.Math.Max(0, Skin.Top - Padding.Top);
        int bottom = System.Math.Max(0, Skin.Bottom - Padding.Bottom);
        int h = Padding.Vertical;
        for (int n = 0; n < Items.Count; n++) {
          System.Windows.Forms.ToolStripItem it = Items[n];
          int mt = (n == 0) ? top : 0;
          int mb = (n == (Items.Count - 1)) ? bottom : 0;
          if ((it.Margin.Top != mt) || (it.Margin.Bottom != mb)) {
            it.Margin = new System.Windows.Forms.Padding(it.Margin.Left, mt, it.Margin.Right, mb);
          }
          h += it.Height + it.Margin.Vertical;
        }
        Size = new System.Drawing.Size(Skin.Width, h);
      } catch { }
    }

    protected override void OnOpening(System.ComponentModel.CancelEventArgs e) {
      base.OnOpening(e);
      Clicked = null;
      Fit();
    }

    // A theme saved while this menu exists has to reach the surface behind the rows and every row
    // on it: one call swaps the skin instead of building the menu again, which would mean wiring
    // the ten click handlers a second time. Fit() runs again because a theme carries its own row
    // height and padding.
    public void ApplySkin(TraySkin skin) {
      if (skin == null) { return; }
      Skin = skin;
      Renderer = new TrayMenuRenderer(skin);
      for (int n = 0; n < Items.Count; n++) {
        TrayItem row = Items[n] as TrayItem;
        if (row != null) { row.Skin = skin; }
      }
      Fit();
      Invalidate();
    }

    // the same ring the panel's frame is drawn with (lib/panel/picker-draw.ps1)
    public static void Frame(System.Drawing.Graphics g, int w, int h, int radius, System.Drawing.Color color) {
      if (w < 6 || h < 6) { return; }
      int t = 1;
      if ((radius * 2) > (w - 3) || (radius * 2) > (h - 3)) { radius = Math.Min(w - 3, h - 3) / 2; }
      System.Drawing.Drawing2D.SmoothingMode was = g.SmoothingMode;
      g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.None;
      using (System.Drawing.SolidBrush br = new System.Drawing.SolidBrush(color))
      using (System.Drawing.Drawing2D.GraphicsPath ring = new System.Drawing.Drawing2D.GraphicsPath()) {
        int span = w - (2 * t), side = h - (2 * t);
        if (span > 0) {
          g.FillRectangle(br, radius, 0, span, t);
          g.FillRectangle(br, radius, h - t, span, t);
        }
        if (side > 0) {
          g.FillRectangle(br, 0, radius, t, side);
          g.FillRectangle(br, w - t, radius, t, side);
        }
        if (radius > 0) {
          ring.FillMode = System.Drawing.Drawing2D.FillMode.Alternate;
          int d = radius * 2;
          int di = Math.Max(2, (radius - t) * 2);
          int[][] corners = new int[][] {
            new int[] { 0, 0, 180 }, new int[] { w - d, 0, 270 },
            new int[] { w - d, h - d, 0 }, new int[] { 0, h - d, 90 }
          };
          foreach (int[] c in corners) {
            ring.AddPie(c[0], c[1], d, d, c[2], 90);
            ring.AddPie(c[0] + t, c[1] + t, di, di, c[2], 90);
          }
          g.FillPath(br, ring);
        }
      }
      g.SmoothingMode = was;
    }

    protected override void OnOpened(System.EventArgs e) {
      base.OnOpened(e);
      try { PlaceUnderPointer(); } catch { }
      try {
        System.Drawing.Region old = Region;
        using (System.Drawing.Drawing2D.GraphicsPath p = TrayItem.RoundPath(Width, Height, Skin.Radius)) {
          Region = new System.Drawing.Region(p);
        }
        if (old != null) { old.Dispose(); }
      } catch { }
    }

    // A drop-down picks its corner from the size it has when it is shown, and a row menu is built
    // per opening, so its final size only exists after Show() returns: a tall one near the bottom
    // edge is pushed inside the working area instead of flipped (measured: pointer at y=622, menu
    // 482..1031 on a 1032 px work area, the pointer 140 px inside it). The rule is
    // Get-MenuPlacement in lib/panel/picker-geom.ps1, where it can be checked without a screen;
    // the menu only asks it where to go. The tray menu sets no placer and keeps the built-in one.
    public System.Func<System.Drawing.Point, System.Drawing.Size, System.Drawing.Point> Placer;

    void PlaceUnderPointer() {
      if (Placer == null) { return; }
      System.Drawing.Point at = Placer(System.Windows.Forms.Cursor.Position, Size);
      if ((at.X != Location.X) || (at.Y != Location.Y)) {
        Location = at;
      }
    }

    // A switch reports a state instead of doing something, so clicking one leaves the menu
    // open: the point of the row is what it now shows. Every other row closes it, the way a
    // menu does. Esc, a click elsewhere and a moved foreground all still close it.
    protected override void OnClosing(System.Windows.Forms.ToolStripDropDownClosingEventArgs e) {
      base.OnClosing(e);
      if (!e.Cancel && e.CloseReason == System.Windows.Forms.ToolStripDropDownCloseReason.ItemClicked) {
        TrayItem it = Clicked;
        if (it == null) {
          // reached from the keyboard: no mouse down came first, so the selected row is the one
          foreach (System.Windows.Forms.ToolStripItem o in Items) {
            TrayItem t = o as TrayItem;
            if (t != null && t.Selected) { it = t; break; }
          }
        }
        if (it != null && it.IsSwitch) { e.Cancel = true; }
      }
      Clicked = null;
    }
  }

  class TrayMenuRenderer : System.Windows.Forms.ToolStripRenderer {
    readonly TraySkin skin;
    public TrayMenuRenderer(TraySkin s) { skin = s; }

    protected override void OnRenderToolStripBackground(System.Windows.Forms.ToolStripRenderEventArgs e) {
      using (System.Drawing.SolidBrush br = new System.Drawing.SolidBrush(skin.Surface)) {
        e.Graphics.FillRectangle(br, new System.Drawing.Rectangle(System.Drawing.Point.Empty, e.ToolStrip.Size));
      }
    }

    protected override void OnRenderToolStripBorder(System.Windows.Forms.ToolStripRenderEventArgs e) {
      TrayMenu.Frame(e.Graphics, e.ToolStrip.Width, e.ToolStrip.Height, skin.Radius, skin.Border);
    }

    protected override void OnRenderImageMargin(System.Windows.Forms.ToolStripRenderEventArgs e) { }

    // a hairline, inset, instead of the system's etched pair - measured off the strip rather
    // than off the item, which the layout insets a little on each side
    protected override void OnRenderSeparator(System.Windows.Forms.ToolStripSeparatorRenderEventArgs e) {
      System.Drawing.Rectangle b = e.Item.Bounds;
      int y = b.Top + (b.Height / 2);
      int left = skin.SeparatorInset;
      int right = e.ToolStrip.Width - 1 - skin.SeparatorInset;
      if (right <= left) { return; }
      System.Drawing.Color colour = skin.Separator.A > 0 ? skin.Separator : skin.Border;
      using (System.Drawing.Pen pen = new System.Drawing.Pen(colour)) {
        e.Graphics.DrawLine(pen, left, y, right, y);
      }
    }
  }

  // ---- the filter behind the search box (see lib\query.ps1) -----------------------------
  // The panel asks for an answer on every typed character, and the PowerShell loop over the
  // rows was the one part of that answer it could not make cheap: the same loop costs a couple
  // of milliseconds warm and tens of them the first time a fresh process runs it. The heads
  // arrive already cut to the length a row shows, so a match is an ordinal-ignore-case
  // IndexOf over strings - the same rule Invoke-Query's plain path spells out.
  public class Search {
    public const int HeadChars = 4096;

    // indices of the heads that contain every term and none of the excludes, in order
    public static int[] Match(string[] heads, string[] terms, string[] excludes) {
      if (heads == null) { return new int[0]; }
      System.Collections.Generic.List<int> keep = new System.Collections.Generic.List<int>(heads.Length);
      for (int i = 0; i < heads.Length; i++) {
        string head = heads[i];
        if (head == null) { head = ""; }
        bool ok = true;
        if (terms != null) {
          for (int t = 0; t < terms.Length; t++) {
            string term = terms[t];
            if (term == null || term.Length == 0) { continue; }
            if (head.IndexOf(term, System.StringComparison.OrdinalIgnoreCase) < 0) { ok = false; break; }
          }
        }
        if (ok && excludes != null) {
          for (int t = 0; t < excludes.Length; t++) {
            string term = excludes[t];
            if (term == null || term.Length == 0) { continue; }
            if (head.IndexOf(term, System.StringComparison.OrdinalIgnoreCase) >= 0) { ok = false; break; }
          }
        }
        if (ok) { keep.Add(i); }
      }
      return keep.ToArray();
    }

    // the rows those indices name, in the same order; the caller keeps its own array
    public static object[] Pick(object[] rows, int[] indices) {
      if (rows == null || indices == null) { return new object[0]; }
      object[] picked = new object[indices.Length];
      for (int i = 0; i < indices.Length; i++) { picked[i] = rows[indices[i]]; }
      return picked;
    }
  }
}

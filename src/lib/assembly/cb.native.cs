using System;
using System.Runtime.InteropServices;
namespace Cb {
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
    // 104,1). Both are handled: the rect is taken as it is when it already lies inside the
    // control that holds the keyboard, and otherwise moved there with ClientToScreen. A caret
    // that fits neither way is returned raw, and the caller's validity test decides.
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
      if (room.Contains(caret)) { return caret; }
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
    // 16 px is the reference drawing: the clip at the top, the board under it, and - only when
    // there is room - two lines of text inside the board
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
        // the gap a real clip has: only worth drawing where there are pixels for it
        if (size >= 24) {
          using (System.Drawing.SolidBrush b = new System.Drawing.SolidBrush(Mix(fill, System.Drawing.Color.White, 92)))
          using (System.Drawing.Drawing2D.GraphicsPath p = Round(6.6f * u, 2.9f * u, 2.8f * u, 2.3f * u, 0.7f * u)) { g.FillPath(b, p); }
        }
        using (System.Drawing.SolidBrush b = new System.Drawing.SolidBrush(Mix(fill, System.Drawing.Color.Black, 12))) {
          using (System.Drawing.Drawing2D.GraphicsPath p = Round(5.0f * u, 7.4f * u, 5.4f * u, 1.4f * u, 0.7f * u)) { g.FillPath(b, p); }
          using (System.Drawing.Drawing2D.GraphicsPath p = Round(5.0f * u, 10.2f * u, 4.2f * u, 1.4f * u, 0.7f * u)) { g.FillPath(b, p); }
          if (size >= 24) {
            using (System.Drawing.Drawing2D.GraphicsPath p = Round(5.0f * u, 12.4f * u, 3.2f * u, 1.2f * u, 0.6f * u)) { g.FillPath(b, p); }
          }
        }
      } finally { g.Dispose(); }
      return bmp;
    }
    public static IntPtr Build(int size, int argb) {
      System.Drawing.Bitmap bmp = BuildBitmap(size, argb);
      IntPtr h = bmp.GetHicon();
      bmp.Dispose();
      return h;
    }
    public static void Free(IntPtr h) { if (h != IntPtr.Zero) { DestroyIcon(h); } }
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

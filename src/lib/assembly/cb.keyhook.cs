using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;
namespace Cb {
  public static class KeyHook {
    private delegate IntPtr Proc(int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookEx(int idHook, Proc cb, IntPtr hMod, uint tid);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] private static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int ToUnicodeEx(uint vk, uint scan, byte[] state, StringBuilder buf, int cch, uint flags, IntPtr layout);
    [DllImport("user32.dll")] private static extern IntPtr GetKeyboardLayout(uint tid);
    [DllImport("user32.dll")] private static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("imm32.dll")] private static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    private const int WM_KEYDOWN = 0x0100;

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT {
      public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr extra;
    }

    private static Proc proc;
    private static IntPtr hook = IntPtr.Zero;

    // virtual keys the panel took, in press order, drained by the panel's own thread
    public static readonly ConcurrentQueue<int> Keys = new ConcurrentQueue<int>();
    // set when the input needs a real keyboard focus (an IME is composing)
    public static volatile bool Escalate;
    public static int LastError;
    public static int Swallowed;

    public static IntPtr Install() {
      if (hook != IntPtr.Zero) { return hook; }
      proc = new Proc(Callback);
      Escalate = false;
      Swallowed = 0;
      hook = SetWindowsHookEx(13, proc, GetModuleHandle(null), 0);   // WH_KEYBOARD_LL
      LastError = Marshal.GetLastWin32Error();
      return hook;
    }

    public static void Remove() {
      if (hook == IntPtr.Zero) { return; }
      UnhookWindowsHookEx(hook);
      hook = IntPtr.Zero;
      proc = null;
      Escalate = false;
      int vk;
      while (Keys.TryDequeue(out vk)) { }
    }

    public static bool Active { get { return hook != IntPtr.Zero; } }

    // ctrl combinations the panel answers; everything else keeps working for the window
    // behind it. The panel adds its plugin keys on top of these.
    private static System.Collections.Generic.HashSet<uint> ctrlKeys = DefaultCtrlKeys();

    private static System.Collections.Generic.HashSet<uint> DefaultCtrlKeys() {
      var set = new System.Collections.Generic.HashSet<uint>();
      set.Add(0x41);                        // A  select every row in the result
      set.Add(0x5A);                        // Z  undo a delete
      set.Add(0x0D);                        // Enter  copy
      set.Add(0x50); set.Add(0x53); set.Add(0x48); set.Add(0x4F);   // plugin keys
      for (uint i = 0x30; i <= 0x39; i++) { set.Add(i); }           // 0-9  pick a visible row
      for (uint i = 0x60; i <= 0x69; i++) { set.Add(i); }           // numpad 0-9
      // the editing keys the search box needs in combination too: word jumps, word deletes and
      // the ends of the line. The control cannot read Ctrl from a posted key, so the panel
      // carries these out itself (lib\panel\picker.ps1, Step-SearchKey).
      set.Add(0x25); set.Add(0x27);         // Left / Right  jump a word
      set.Add(0x24); set.Add(0x23);         // Home / End    start / end of the text
      set.Add(0x08); set.Add(0x2E);         // Backspace / Delete  drop a word
      return set;
    }

    public static void SetCtrlKeys(int[] keys) {
      var set = DefaultCtrlKeys();
      if (keys != null) { foreach (int k in keys) { set.Add((uint)k); } }
      ctrlKeys = set;
    }

    // Keys the panel handles itself: printables, editing keys and the navigation keys. What
    // the panel does not use stays with the shell - the hook exists to feed the panel, not to
    // own the keyboard - so Alt/Win combinations, the other function keys and every Ctrl
    // shortcut the panel does not answer keep working while it is open.
    private static bool Eat(uint vk) {
      // Win combinations belong to the shell: Win+V, Win+Shift+S and Win+. would otherwise be
      // swallowed as plain letters and do nothing while the panel is open
      if (((GetAsyncKeyState(0x5B) & 0x8000) != 0) || ((GetAsyncKeyState(0x5C) & 0x8000) != 0)) { return false; }
      // Ctrl+Shift+Esc opens Task Manager; the panel only needs a bare Esc
      if (vk == 0x1B && (GetAsyncKeyState(0x11) & 0x8000) != 0 && (GetAsyncKeyState(0x10) & 0x8000) != 0) { return false; }
      bool ctrl = (GetAsyncKeyState(0x11) & 0x8000) != 0;
      if (ctrl) {
        // Ctrl+Space switches the input method on and off, so it is never swallowed
        if (vk == 0x20) { return false; }
        return ctrlKeys.Contains(vk);
      }
      if (vk >= 0x41 && vk <= 0x5A) { return true; }   // A-Z
      if (vk >= 0x30 && vk <= 0x39) { return true; }   // 0-9
      if (vk >= 0x60 && vk <= 0x69) { return true; }   // numpad 0-9
      if (vk == 0x20) { return true; }                 // space
      if (vk >= 0x21 && vk <= 0x28) { return true; }   // pgup, pgdn, end, home, arrows
      if (vk == 0x2E) { return true; }                 // delete (Insert stays with the shell)
      if (vk >= 0xBA && vk <= 0xC0) { return true; }   // ; = , - . /
      if (vk >= 0xDB && vk <= 0xDE) { return true; }   // [ \ ] '
      if (vk == 0x71) { return true; }                 // F2: in-place edit is the only F key used
      if (vk == 0x08 || vk == 0x09 || vk == 0x0D || vk == 0x1B) { return true; }
      return false;
    }

    private static IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam) {
      if (nCode >= 0) {
        int msg = (int)wParam;
        KBDLLHOOKSTRUCT k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
        bool alt = (k.flags & 0x20) != 0;
        if (msg == WM_KEYDOWN && k.vkCode == 0xE5) {
          // VK_PROCESSKEY: the input method wants this key. Swallowing it is the only way to
          // keep it out of the window behind the panel - passing it on is exactly how typed
          // Chinese ended up in the other application's box. The scan code still names the
          // real key, so the panel can replay it once it owns the focus and the IME composes
          // there instead.
          Escalate = true;
          uint real = MapVirtualKey(k.scanCode, 1);   // MAPVK_VSC_TO_VK
          Swallowed++;
          Keys.Enqueue(real != 0 ? (int)real : (int)k.vkCode);
          return (IntPtr)1;
        }
        if (msg == WM_KEYDOWN && !alt && Eat(k.vkCode)) {
          Swallowed++;
          Keys.Enqueue((int)k.vkCode);
          return (IntPtr)1;   // swallow: the panel replays it into its own controls
        }
      }
      return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }

    // the character a key produces under the current modifiers and layout (0 = not printable)
    public static char ToChar(int vk) {
      try {
        byte[] state = new byte[256];
        if ((GetAsyncKeyState(0x10) & 0x8000) != 0) { state[0x10] = 0x80; }   // shift
        if ((GetAsyncKeyState(0x14) & 0x8000) != 0) { state[0x14] = 0x01; }   // caps lock
        StringBuilder sb = new StringBuilder(4);
        int n = ToUnicodeEx((uint)vk, 0, state, sb, sb.Capacity, 0x04, GetKeyboardLayout(0));
        if (n == 1) { return sb[0]; }
      } catch { }
      return (char)0;
    }

    // Is the input method in its native (composing) mode? Merely "switched on" is not
    // enough - a Chinese IME stays open in alphanumeric mode and passes ASCII straight
    // through, which the hook handles fine. Only composing needs a real focus.
    public static bool ImeNeedsFocus(IntPtr hwnd) {
      try {
        IntPtr ime = ImmGetDefaultIMEWnd(hwnd);
        if (ime == IntPtr.Zero) { return false; }
        // WM_IME_CONTROL / IMC_GETCONVERSIONSTATUS: low word is the conversion mode
        IntPtr r = SendMessage(ime, 0x0283, (IntPtr)1, IntPtr.Zero);
        int mode = (int)(((long)r) & 0xFFFF);
        return (mode & 0x0001) != 0;   // IME_CMODE_NATIVE
      } catch { }
      return false;
    }
  }
}

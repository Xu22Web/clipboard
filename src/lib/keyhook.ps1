# lib/keyhook.ps1 - the low-level keyboard hook that lets the panel take typing without
# taking the foreground window.
#
# Why this exists: SetFocus always activates the window that receives it (documented), and a
# WS_EX_NOACTIVATE window is no exception, so "the panel has the keyboard while your editor
# is still the active window" cannot be done with focus at all. A WH_KEYBOARD_LL hook can:
# it swallows the keys the panel wants, and the panel replays them into its own controls
# from its own thread. The foreground window - its focus, its caret, its z-order - is never
# touched, so closing the panel only unhooks; nothing has to be restored.
#
# The callback runs on the input thread, so it does the minimum: decide, count, enqueue,
# swallow. Translation and delivery happen on the panel's thread (Get-HookedKeys +
# Cb.KeyHook::ToChar), which is also the only thread allowed to touch those windows.

function Add-KeyHookType {
  if ('Cb.KeyHook' -as [type]) { return }
  Add-Type -TypeDefinition @'
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

    // keys the panel handles itself: printables, editing keys and the navigation keys.
    // Modifiers and Win/Alt combinations pass through, so the shell keeps working and the
    // keyboard state stays consistent.
    private static bool Eat(uint vk) {
      // Ctrl+Space switches the input method on and off - never swallow it, or the panel
      // would be the only thing the user can no longer reach their IME with
      if (vk == 0x20 && (GetAsyncKeyState(0x11) & 0x8000) != 0) { return false; }
      if (vk >= 0x41 && vk <= 0x5A) { return true; }   // A-Z
      if (vk >= 0x30 && vk <= 0x39) { return true; }   // 0-9
      if (vk >= 0x60 && vk <= 0x69) { return true; }   // numpad 0-9
      if (vk == 0x20) { return true; }                 // space
      if (vk >= 0x21 && vk <= 0x28) { return true; }   // pgup, pgdn, end, home, arrows
      if (vk >= 0x2D && vk <= 0x2E) { return true; }   // insert, delete
      if (vk >= 0xBA && vk <= 0xC0) { return true; }   // ; = , - . /
      if (vk >= 0xDB && vk <= 0xDE) { return true; }   // [ \ ] '
      if (vk == 0x08 || vk == 0x09 || vk == 0x0D || vk == 0x1B) { return true; }
      return false;
    }

    private static IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam) {
      if (nCode >= 0) {
        int msg = (int)wParam;
        KBDLLHOOKSTRUCT k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
        bool alt = (k.flags & 0x20) != 0;
        if (k.vkCode == 0xE5) {
          // VK_PROCESSKEY: an IME is composing and needs a real focus
          Escalate = true;
        } else if (msg == WM_KEYDOWN && !alt && Eat(k.vkCode)) {
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
'@
}

# install the hook; returns $true when the panel may rely on it
function Enable-KeyHook {
  Add-KeyHookType
  $h = [Cb.KeyHook]::Install()
  if ($h -eq [IntPtr]::Zero) {
    Write-Log ('key hook failed: ' + [Cb.KeyHook]::LastError)
    return $false
  }
  Write-Log 'key hook installed'
  return $true
}

function Disable-KeyHook {
  if (-not ('Cb.KeyHook' -as [type])) { return }
  if (-not [Cb.KeyHook]::Active) { return }
  [Cb.KeyHook]::Remove()
  Write-Log ('key hook removed swallowed=' + [Cb.KeyHook]::Swallowed)
}

function Test-KeyHook { return ('Cb.KeyHook' -as [type]) -and [Cb.KeyHook]::Active }

# true when the input method is composing in its native mode for that window: that needs a
# real focus, so the panel hands itself the keyboard
function Test-ImeOpen([IntPtr]$hwnd) {
  if ($hwnd -eq [IntPtr]::Zero) { return $false }
  if (-not ('Cb.KeyHook' -as [type])) { return $false }
  return [Cb.KeyHook]::ImeNeedsFocus($hwnd)
}

# true once when the input needs a real focus (an IME started composing)
function Test-KeyHookEscalate {
  if (-not ('Cb.KeyHook' -as [type])) { return $false }
  if (-not [Cb.KeyHook]::Escalate) { return $false }
  [Cb.KeyHook]::Escalate = $false
  return $true
}

# drain the keys the hook took, in press order
function Get-HookedKeys {
  $out = New-Object System.Collections.Generic.List[int]
  if ('Cb.KeyHook' -as [type]) {
    $vk = 0
    while ([Cb.KeyHook]::Keys.TryDequeue([ref]$vk)) { $out.Add($vk) }
  }
  return $out.ToArray()
}

# the printable character behind a virtual key, or NUL
function Get-HookedChar([int]$vk) {
  if (-not ('Cb.KeyHook' -as [type])) { return [char]0 }
  return [Cb.KeyHook]::ToChar($vk)
}

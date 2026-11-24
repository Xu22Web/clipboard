// src/main/media/rich.cs - RTF laid out into a device context (see lib/media.ps1).
//
// A RichTextBox lays a document out into a device context through EM_FORMATRANGE, which works
// while the control is not on screen at all. DrawToBitmap on an unparented control renders
// nothing, so the preview card uses this instead.
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged.
using System;
using System.Runtime.InteropServices;

namespace Cb {
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
}

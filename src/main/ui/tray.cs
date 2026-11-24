// src/main/ui/tray.cs - the tray icon, drawn instead of loaded (see lib/panel/tray-menu.ps1).
//
// There is no asset to ship, and every size is rendered at its own resolution rather than scaled
// down from one bitmap, which is what makes a bitmap icon look soft at 125% and 150% scaling.
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged.
using System;
using System.Runtime.InteropServices;

namespace Cb {
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
}

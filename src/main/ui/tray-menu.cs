// src/main/ui/tray-menu.cs - the strip the tray rows sit on, and the renderer that paints what a
// row cannot (see renderer/src/windows/tray-menu.ps1).
//
// The strip paints only the surface, the frame and the separators. The region is rounded when the
// menu opens, so the silhouette matches the panel's instead of the square one a menu gets, and the
// frame is filled as a one pixel ring rather than stroked - a stroke on a curve covers half a pixel
// and the arcs come out paler than the sides.
//
// Compiled through src\main\index.cs; the namespace and the type names are unchanged.
using System;

namespace Cb {
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
    // px too low because of exactly that. renderer\src\windows\tray-menu.ps1 calls it once the rows are in.
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

    // the same ring the panel's frame is drawn with (renderer/src/components/picker-draw.ps1)
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
    // Get-MenuPlacement in renderer/src/components/picker-geom.ps1, where it can be checked without a screen;
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
}

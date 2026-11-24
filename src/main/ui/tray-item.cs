// src/main/ui/tray-item.cs - one row of the tray menu, painted whole (see
// lib/panel/tray-menu.ps1).
//
// The strip never draws a row, so the layout of a row (glyph, label, hint or switch) lives in
// exactly one place. A header row is the same layout without the hover state - it names the menu
// and carries the count.
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged.
namespace Cb {
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
}

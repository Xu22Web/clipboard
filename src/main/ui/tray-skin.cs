// src/main/ui/tray-skin.cs - the palette, fonts and metrics a tray menu row is drawn with (see
// renderer/src/windows/tray-menu.ps1).
//
// Windows draws a menu in the system colours: a light surface with the system font, beside a
// panel and a settings window that are both drawn from one palette. This menu is drawn from that
// palette instead - the same surface and the same frame as the other windows, a glyph column,
// rows that light up the way a panel row does, a right-hand column for a hint or a switch, and
// hairlines instead of the system's etched separators.
//
// The numbers arrive already multiplied by the DPI scale, like every other pixel constant in the
// tool (utils/dpi.ps1), so nothing here has to know about scaling.
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged.
namespace Cb {
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
    // the 96 dpi fallback for a menu built without a skin from the tool: renderer\src\windows\tray-menu.ps1
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
    // one measurement by renderer\src\windows\tray-menu.ps1, not per glyph.
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
}

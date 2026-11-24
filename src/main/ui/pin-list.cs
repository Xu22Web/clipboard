// src/main/ui/pin-list.cs - the row surface both drawn windows put their rows on (see
// renderer/src/components/pinlist.ps1 for why it exists).
//
// A plain Control paints nothing and hit-tests nothing, so this one owns the three things a row
// list needs and the host does not: the scroll position (always a whole row), the wheel the host
// cannot see, and the click that reports what else was held instead of deciding what to do.
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged.
using System;

namespace Cb {
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
}

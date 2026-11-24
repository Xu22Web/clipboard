// src/main/ui/pin-draw-event-args.cs - what Cb.PinList hands its caller for one row (see
// renderer/src/components/pinlist.ps1).
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged.
using System;

namespace Cb {
  public class PinDrawEventArgs : EventArgs {
    public int Index;
    public System.Drawing.Rectangle Bounds;
    public System.Drawing.Graphics Graphics;
    public System.Windows.Forms.DrawItemState State;
  }
}

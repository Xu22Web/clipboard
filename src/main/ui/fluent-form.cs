// src/main/ui/fluent-form.cs - the form both drawn windows and the preview card are built on
// (see lib/panel/picker.ps1 and lib/panel/preview.ps1).
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged.
namespace Cb {
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
}

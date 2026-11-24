// src/main/ui/fluent-form.cs - the form both drawn windows and the preview card are built on
// (see renderer/src/windows/picker.ps1 and renderer/src/components/preview.ps1).
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged.
namespace Cb {
  public class FluentForm : System.Windows.Forms.Form {
    // The panel activates; a preview card raised by the panel must not, or the panel would
    // lose the foreground and close.
    public bool Activates = false;
    // The three paint styles are what makes the drawn surface possible: UserPaint hands the
    // whole frame to OnPaint, AllPaintingInWmPaint keeps the framework from erasing behind it,
    // and OptimizedDoubleBuffer draws that OnPaint into one buffer. They are protected members
    // of Control, so they can only be set here - PowerShell cannot touch protected properties
    // on an instance, and a window that tried died on the first open.
    public FluentForm() {
      DoubleBuffered = true;
      SetStyle(System.Windows.Forms.ControlStyles.OptimizedDoubleBuffer
        | System.Windows.Forms.ControlStyles.AllPaintingInWmPaint
        | System.Windows.Forms.ControlStyles.UserPaint, true);
    }
    protected override bool ShowWithoutActivation { get { return !Activates; } }
    protected override System.Windows.Forms.CreateParams CreateParams {
      get {
        var cp = base.CreateParams;
        if (!Activates) { cp.ExStyle |= 0x08000000; }   // WS_EX_NOACTIVATE
        // Compositing makes the DWM assemble each frame off-screen, which keeps the child
        // controls from sitting half-painted while the window is moved. It is not what fixes
        // the row flicker (Cb.PinList buffers its own paint, renderer/src/components/pinlist.ps1), but the
        // panel needs it for its child controls.
        cp.ExStyle |= 0x02000000;   // WS_EX_COMPOSITED
        cp.ClassStyle |= 0x00020000;
        return cp;
      }
    }
  }
}

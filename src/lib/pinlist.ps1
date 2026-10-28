# lib/pinlist.ps1 - why the panel paints its own rows instead of using a ListBox.
#
# A native ListBox paints each owner-drawn row straight into the window DC through
# WM_DRAWITEM, so it can never be double buffered and it cannot hold a row still while the
# rest scrolls. Cb.PinList owns its paint loop instead: one buffered OnPaint draws the
# frozen block, then the scrolling rows under it, which is why neither the erase gap nor
# the "pins scroll away" problem exists.
#
# The type is compiled with the rest of the Win32 helpers in Add-Native (lib/util.ps1).
# A second Add-Type call would pay for another csc run at every cold start, and the class
# belongs with the other Cb types anyway. This module keeps the name the picker asks for,
# so the row surface still has one obvious home.
function Add-PinList {
  if ($script:PinListReady) { return }
  Add-Native
  $script:PinListReady = $true
}

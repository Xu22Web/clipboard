# renderer\src\windows\picker-live.ps1 - the panel's controls while the window is up.
#
# Show-Picker builds a window, runs it, and disposes it; the functions that run during that -
# rows on screen, the thumb, the caret, the chrome around the search field - used to be defined
# inside it. A function defined inside a function is a fresh ScriptBlock on every call, and
# PowerShell compiles it the first time it is invoked, so every open paid for about ten small
# compilations (measured at 60-70 ms of a 95 ms build). Here they are file scope: compiled once
# per process, and the controls they work on are read from $script:Panel*, which Show-Picker
# fills in as it builds them.
#
# Nothing here creates a control or a handle; the panel still builds and disposes one window per
# open, so nothing outlives a close that did not outlive it before.

# the rows the list can show at its current height
function Get-Rows {
  $lst = $script:PanelList
  if ($null -eq $lst) { return 0 }
  return (Get-VisibleRowCount $lst.ClientSize.Height $lst.ItemHeight)
}

# the list is wider than its host, so the host clips the strip a native bar would use
function Size-List {
  $lst = $script:PanelList
  $listHost = $script:PanelHost
  if ($null -eq $lst -or $null -eq $listHost) { return }
  $w = $listHost.ClientSize.Width
  $h = $listHost.ClientSize.Height
  if ($w -gt 0 -and $h -gt 0) { $lst.SetBounds(0, 0, $w + (Px 40), $h) }
}

# a page is the rows that scroll, not every row on screen: the frozen ones never move, so
# paging by the whole height would skip their number of rows on every press
function Get-PageRows {
  $lst = $script:PanelList
  if ($null -eq $lst) { return 1 }
  $n = (Get-Rows) - $lst.PinnedCount
  if ($n -lt 1) { $n = 1 }
  return $n
}

# The list can move without the selection (wheel, page keys, the scrollbar), and a selection
# that has left the view makes Enter paste a row that is not on screen. Pulling it to the edge
# the view moved toward keeps Enter pointing at something the user can see.
function Keep-SelectionInView {
  $lst = $script:PanelList
  if ($null -eq $lst) { return }
  $i = $lst.SelectedIndex
  if ($i -lt 0 -or $i -lt $lst.PinnedCount) { return }
  $vis = (Get-Rows) - $lst.PinnedCount
  if ($vis -lt 1) { return }
  $top = $lst.TopIndex
  $last = $top + $vis - 1
  if ($i -lt $top) { $lst.SelectedIndex = $top }
  elseif ($i -gt $last) { $lst.SelectedIndex = $last }
}

# thumb geometry from the scroll position in rows; the frozen block stays out of the
# scrollable range
function Sync-Sb {
  $lst = $script:PanelList
  $sbar = $script:PanelBar
  if ($null -eq $lst -or $null -eq $sbar) { return }
  $n = $lst.ItemCount
  $vis = Get-Rows
  $pin = $lst.PinnedCount
  $rowH = [Math]::Max(1, $lst.ItemHeight)
  # one notch moves a quarter of the rows that actually scroll: a short compact panel no
  # longer loses most of its content to one notch, and a tall one is still crossed in
  # about four. This sits here because a filter that pins rows and a panel shortened to
  # fit the screen both change how far a notch should go.
  $lst.WheelRows = Get-WheelStep ([Math]::Max(1, ($vis - $pin))) ([int]$script:ScrollLines)
  $h = $sbar.ClientSize.Height
  if ($n -le $vis -or $h -le (Px 12)) { $script:SbLen = 0; $sbar.Invalidate(); return }
  $track = $h - (Px 6)
  $scrollRows = [Math]::Max(1, $n - $pin)
  $scrollVis = [Math]::Max(1, $vis - $pin)
  $script:SbLen = [Math]::Max((Px 28), [int]($track * $scrollVis / $scrollRows))
  $span = $track - $script:SbLen
  # the scroll position is a row count, so it is scaled in row heights and the thumb lands
  # on the row the list would show
  $base = $pin * $rowH
  $room = $lst.ScrollMax - $base
  $t = 0
  if ($room -gt 0 -and $span -gt 0) { $t = [int]($span * ($lst.ScrollY - $base) / $room) }
  $script:SbTop = (Px 3) + $t
  $sbar.Invalidate()
}

# move the list so the thumb lands at $thumbTop
function Sb-ScrollTo([int]$thumbTop) {
  $lst = $script:PanelList
  $sbar = $script:PanelBar
  if ($null -eq $lst -or $null -eq $sbar) { return }
  if ($script:SbLen -le 0) { return }
  $span = ($sbar.ClientSize.Height - (Px 6)) - $script:SbLen
  $pin = $lst.PinnedCount
  $rowH = [Math]::Max(1, $lst.ItemHeight)
  $base = $pin * $rowH
  $room = $lst.ScrollMax - $base
  if ($room -le 0 -or $span -le 0) { return }
  $y = $base + [int][Math]::Round(($thumbTop - (Px 3)) * $room / $span)
  # the control lands on whole rows whatever position is asked for, so a dragged thumb
  # steps row by row; ScrollToPixel raises ScrollChanged, which syncs the thumb for us
  $lst.ScrollToPixel($y)
}

function Scroll-By([int]$rows) {
  $lst = $script:PanelList
  if ($null -eq $lst) { return }
  # ScrollBy raises ScrollChanged, which moves the thumb
  $lst.ScrollBy($rows)
}

# A page key moves the view and the selection by the same number of rows, so PgDown then
# PgUp comes back to the row it left. Scrolling alone left the landing spot to the edge pull
# in Keep-SelectionInView - down went to the first row of the next page, up to the last row
# of the previous one, so alternating the two keys drifted one row further down each time.
function Page-Selection([int]$rows) {
  $lst = $script:PanelList
  if ($null -eq $lst) { return }
  $i = $lst.SelectedIndex
  Scroll-By $rows
  if ($lst.ItemCount -le 0) { return }
  if ($i -lt 0) { $i = 0 }
  $k = $i + $rows
  if ($k -lt 0) { $k = 0 }
  if ($k -gt ($lst.ItemCount - 1)) { $k = $lst.ItemCount - 1 }
  $lst.SelectedIndex = $k
}

# The field draws its own caret, in the theme colour: the system one cannot be tinted, so it
# is hidden and this line stands in for it while the field has the keyboard. Composing with an
# input method is the exception - its candidate window is anchored at the real caret - and so
# is the row editor, which has a box of its own.
function Test-OwnCaret {
  $txt = $script:PanelTxt
  if ($null -eq $txt) { return $false }
  if ($null -ne $script:EditRow) { return $false }
  if (-not $txt.Focused) { return $false }
  return (-not $script:Composing)
}

# HideCaret is counted by USER32: the caret comes back only after as many ShowCaret calls.
# The count is capped, because a control undoes one hide per keystroke, so a handful is
# enough to keep the white caret off the screen - and giving the rest back stays cheap.
function Hide-SystemCaret {
  $txt = $script:PanelTxt
  if ($null -eq $txt) { return }
  if ($script:SysHides -ge 8) { return }
  try { if ([Cb.Win]::HideCaret($txt.Handle)) { $script:SysHides++ } } catch { }
}

function Show-SystemCaret {
  $txt = $script:PanelTxt
  if ($null -eq $txt) { return }
  while ($script:SysHides -gt 0) {
    $shown = $false
    try { $shown = [Cb.Win]::ShowCaret($txt.Handle) } catch { $shown = $false }
    if (-not $shown) { break }
    $script:SysHides--
  }
  # a control that lost the focus destroyed the caret and reset the count with it
  $script:SysHides = 0
}

# The index the drawn line sits at. With a selection the control knows where it starts and
# how long it is, but not which end the keyboard moved last, so that end is tracked here:
# without it a Shift+Left would draw the line at the wrong edge.
function Get-CaretIndex {
  $txt = $script:PanelTxt
  if ($null -eq $txt) { return 0 }
  if ($txt.SelectionLength -gt 0 -and $script:CaretEnd -ne 0) {
    $i = $(if ($script:CaretEnd -gt 0) { $txt.SelectionStart + $txt.SelectionLength } else { $txt.SelectionStart })
    return [Math]::Min([Math]::Max(0, $i), $txt.TextLength)
  }
  return [int]$txt.SelectionStart
}

function Sync-SearchCaret {
  $txt = $script:PanelTxt
  $caret = $script:PanelCaret
  if ($null -eq $txt -or $null -eq $caret) { return }
  try {
    if (-not (Test-OwnCaret)) {
      if ($caret.Visible) { $caret.Visible = $false }
      return
    }
    # The edit control knows where each character sits and answers even without being
    # asked to lay anything out (EM_POSFROMCHAR), and that is the only width that matches
    # what it draws: GDI measured the same prefix half again too wide on a scaled display.
    $idx = Get-CaretIndex
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -gt $txt.TextLength) { $idx = $txt.TextLength }
    $px = -1
    if ($idx -lt $txt.TextLength) {
      $px = [int](([int64][Cb.Win]::SendMessage($txt.Handle, 0x00D6, [IntPtr]$idx, [IntPtr]::Zero)) -band 0xFFFF)
      if ($px -ge 0x8000) { $px = $px - 0x10000 }
    }
    # the place after the last character has no answer of its own, and neither has an empty
    # field: both are the width of the text before the caret, measured with the control's own
    # font and device context (TextWidth) - zero for an empty field, which is where the first
    # character will land. A field scrolled by a long search keeps the line in view.
    if ($px -lt 0) {
      $px = [Cb.Win]::TextWidth($txt.Handle, $txt.Text.Substring(0, $idx))
      $cw = $txt.ClientSize.Width
      if ($cw -gt 1 -and $px -gt ($cw - 1)) { $px = $cw - 1 }
    }
    if ($px -lt 0) { $px = 0 }
    $ch = [Math]::Max(10, [int]$txt.Font.Height)
    $x = [int]$txt.Left + $px
    $y = [int]$txt.Top + [int](($txt.Height - $ch) / 2)
    $caret.SetBounds($x, $y, [Math]::Max(1, (Px 1)), $ch)
    $script:CaretIndex = $idx
    $caret.Visible = $true
    $script:CaretPulse = Get-Date
  } catch { }
}

function Sync-Placeholder {
  $txt = $script:PanelTxt
  $ph = $script:PanelPh
  $clr = $script:PanelClr
  if ($null -eq $txt -or $null -eq $ph -or $null -eq $clr) { return }
  $ph.Visible = ($txt.Text.Length -eq 0)
  $clr.Visible = ($txt.Text.Length -gt 0)
}

# Where the search field and its parts sit, and the two children that reach the rounded edge.
# Runs on every open and every resize: the region the box had is dropped here instead of
# waiting for the process to end.
function Layout-Chrome {
  $form = $script:PanelForm
  $box = $script:PanelBox
  $txt = $script:PanelTxt
  $ph = $script:PanelPh
  $clr = $script:PanelClr
  $head = $script:PanelHead
  $foot = $script:PanelFoot
  $footL = $script:PanelFootL
  $footR = $script:PanelFootR
  if ($null -eq $form -or $null -eq $box -or $null -eq $txt) { return }
  $boxTop = [int]$script:PanelBoxTop
  $preset = $script:PanelPreset
  try {
    $cw = $form.ClientSize.Width
    $box.SetBounds((Px 14), (Px $boxTop), ($cw - (Px 30)), (Px 40))
    $txt.SetBounds((Px 38), (Px 10), ($box.Width - (Px 80)), (Px 22))
    $ph.SetBounds((Px 40), (Px 10), ($box.Width - (Px 106)), (Px 22))
    $clr.SetBounds(($box.Width - (Px 30)), (Px 10), (Px 20), (Px 22))
    # Layout runs on every open and every resize: the region the box had is dropped here
    # instead of waiting for the process to end
    $oldBoxRegion = $box.Region
    $box.Region = New-RoundRegion $box.Width $box.Height (Px 4)
    if ($null -ne $oldBoxRegion) { $oldBoxRegion.Dispose() }
  } catch { }
  # the preset decides, not $footR.Visible: a control whose form is not shown yet reports
  # Visible = false, and this runs before Show(), which left the count label at the top
  # left corner in the full panel
  if ($preset.ShowFootRight) {
    try { $footR.SetBounds(($foot.ClientSize.Width - (Px 210)), 0, (Px 196), $foot.ClientSize.Height) } catch { }
  }
  # the two children that reach the rounded edge would paint over the frame's arcs
  $cornerR = [Math]::Max(2, (Get-WindowRadius) - 1)
  Set-FrameCornerRegion $head $cornerR 'top'
  Set-FrameCornerRegion $foot $cornerR 'bottom'
  Sync-SearchCaret
  if ($null -ne $footL) { $footL.Invalidate() }
}

function Restore-Foot {
  $footL = $script:PanelFootL
  $footR = $script:PanelFootR
  if ($null -eq $footL -or $null -eq $footR) { return }
  try {
    if ($script:Confirm) { return }
    $script:FootMode = 'hints'
    $script:FootMsg = ''
    $footL.Invalidate()
    $count = Get-UiText 'panel.foot.count' @([string]$script:Filtered.Count, [string]$script:Entries.Count)
    if ($script:StickyTop -gt 0) { $count = $count + '   ' + (Get-UiText 'panel.foot.pinned' @([string]$script:StickyTop)) }
    if ($script:CapturePaused) { $count = (Get-UiText 'panel.foot.paused' @($count)) }
    # the version sits at the right end of the same quiet label as the row count
    $footR.Text = $count + '   v' + $script:Version
  } catch { }
}

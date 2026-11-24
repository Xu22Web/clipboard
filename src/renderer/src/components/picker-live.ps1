# renderer\src\components\picker-live.ps1 - the panel's behaviour while the window is up.
#
# Show-Picker builds a window, runs it, and disposes it; the functions that run during that -
# rows on screen, the thumb, the caret, the chrome around the search field, the paste, the
# delete and undo, the row menu, the hover card - used to be defined inside it. A function
# defined inside a function is a fresh ScriptBlock on every call, and PowerShell compiles it the
# first time it is invoked, so every open paid for about twenty small compilations (measured at
# 60-70 ms for the first ten of a 95 ms build). Here they are file scope: compiled once per
# process, and the controls they work on are read from $script:Panel*, which Show-Picker fills in
# as it builds them.
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

# The rows move under a pointer that does not: after a scroll, or after the filter narrowed the
# list, the row below the cursor is a different one. Reading it again here keeps the highlight
# and the card on the row the user is actually pointing at, and the rest timer starts over - a
# preview follows a cursor that has come to rest, so sweeping the list with the wheel no longer
# flashes a card between two notches. MouseMove only sees the pointer move, which is why this
# cannot live there.
function Sync-HoverFromCursor {
  $lst = $script:PanelList
  if ($null -eq $lst) { return }
  $i = -1
  try {
    if (-not $lst.IsDisposed) {
      $p = $lst.PointToClient([Windows.Forms.Cursor]::Position)
      if ($lst.ClientRectangle.Contains($p)) { $i = $lst.IndexFromPoint($p) }
    }
  } catch { $i = -1 }
  if ($i -ne [int]$script:Hover) {
    $old = [int]$script:Hover
    $script:Hover = $i
    Set-AnimHover $script:Anim $i
    foreach ($k in @($old, $i)) {
      if ($k -ge 0 -and $k -lt $lst.ItemCount) { $lst.Invalidate($lst.GetItemRectangle($k)) }
    }
  }
  $script:PvAt = Get-Date
  $script:PvIdx = -1
  Hide-Preview $script:PanelPv
}

# The footer says one thing at a time: a hint list, or a message that times out back to the
# hints. The timer belongs to the window, so it comes in through $script:PanelFootTimer.
function Set-Foot([string]$msg, [int]$ms = 0) {
  if ($script:Confirm) { return }
  if ($ms -le 0) { $ms = [int]$script:Timing['FootMessage'] }
  $script:FootMode = 'message'
  $script:FootMsg = $msg
  $footL = $script:PanelFootL
  if ($null -ne $footL) { $footL.Invalidate() }
  $footTimer = $script:PanelFootTimer
  if ($null -eq $footTimer) { return }
  try {
    $footTimer.Stop()
    if ($ms -gt 0) { $footTimer.Interval = $ms; $footTimer.Start() }
  } catch { }
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

# One line for a window. A paste that lands elsewhere is the one report that cannot be
# reproduced from a screenshot, and a handle alone says nothing: the program name and the title
# are what the user recognises. File scope like the rest of this file, so an open pays for the
# block once per process instead of once per panel.
function Format-WindowName([IntPtr]$hwnd) {
  $where = 'hwnd=0x' + ([int64]$hwnd).ToString('X')
  $proc = ''
  try { $proc = Get-WindowProcessName $hwnd } catch { }
  if ($proc) { $where = $where + ' ' + $proc }
  try {
    $title = [Cb.Win]::WindowTitle($hwnd, 40)
    if ($title) { $where = $where + ' "' + $title + '"' }
  } catch { }
  return $where
}

# A key a plugin claimed (PanelKeys), with the modifiers written out: the panel asks this on
# every KeyDown for a key it does not handle itself.
function Find-PanelKey([string]$keyName, [bool]$ctrl, [bool]$alt, [bool]$shift) {
  $name = ([string]$keyName).ToUpperInvariant()
  foreach ($k in @($script:PanelKeys)) {
    if ($k.Key -ne $name) { continue }
    if ([bool]$k.Ctrl -ne $ctrl) { continue }
    if ([bool]$k.Alt -ne $alt) { continue }
    if ([bool]$k.Shift -ne $shift) { continue }
    return $k
  }
  return $null
}

# The first printable character moves the keyboard from the list to the search field. The panel
# already owns the front, so focusing the box is all that is needed; an edit in progress keeps
# the keyboard where it is, or the caret would jump out of the text being fixed.
function Start-Search {
  if ($null -ne $script:EditRow) { return }
  $txt = $script:PanelTxt
  if ($null -eq $txt) { return }
  if (-not $txt.Focused) { $txt.Focus() }
  $txt.SelectionStart = $txt.TextLength
  $script:CaretEnd = 0
  Sync-SearchCaret
}

# Which window a paste goes to. Decided when the key is pressed, not when the panel opened: the
# hook lets Alt+Tab through, so the user can bring another application forward while the panel
# is up, and the text still has to land where they are looking now. A window of this process does
# not count - after an input-method hand-over the panel itself is in front, and the daemon's own
# console can be too. Those are not places to paste into, and the window the panel came from is
# the answer for them.
function Get-PasteTarget {
  try {
    $fgNow = [Cb.Win]::GetForegroundWindow()
    if ($fgNow -ne [IntPtr]::Zero -and -not [Cb.Win]::IsOwnWindow($fgNow)) { return $fgNow }
  } catch { }
  return $script:PanelPrev
}

function Format-PasteTarget([IntPtr]$target) {
  $prev = $script:PanelPrev
  $where = Format-WindowName $target
  if ($target -ne $prev) { $where = $where + ' (switched, was 0x' + ([int64]$prev).ToString('X') + ')' }
  return $where
}

# Put the cloned selection back, once. Editors that reset their selection when they lose the
# foreground get the caret back this way, both before a paste and when the panel closes.
function Put-BackSelection([string]$why = '') {
  if (@($script:SavedSel).Count -le 0) { return }
  $back = 0
  try { $back = Restore-UiaSelection $script:SavedSel } catch { $back = 0 }
  Write-Log ('selection restored=' + $back + $why)
}

# The list re-reads the store and hands the rows to the control. Both controls come in through
# the script scope, so this block compiles once per process instead of once per open.
function Update-List([string]$q) {
  $lst = $script:PanelList
  $empty = $script:PanelEmpty
  if ($null -eq $lst) { return }
  $swUp = [Diagnostics.Stopwatch]::StartNew()
  $lst.BeginUpdate()
  try {
    # compiled in main/utils/query.ps1; highlight still works on plain words only
    $query = New-Query -Line $q
    $tokens = @($query.Terms)
    $script:Tokens = $tokens
    # sticky pins: the plugin names the mark and the cap, the base decides how many rows
    # actually fit - see Get-StickyPlan / Get-StickyTopRows in main/utils/ordering.ps1
    $plan = $null
    try { $plan = Get-PluginStickyPlan (Get-Rows) } catch [System.Management.Automation.CommandNotFoundException] { $plan = $null }
    if ($null -eq $plan) { $plan = @{ Mark = ''; Max = 0 } }
    # The rows: plain words go to the assembly, where the scan costs no PowerShell loop at all;
    # its heads are built once per store snapshot (a pin or a delete replaces the array), never
    # per keystroke. Everything else keeps the readable path in main\utils\query.ps1.
    if ($null -ne $script:SearchType -and $query.Bad.Count -eq 0 -and (Test-QueryPlain $query)) {
      if (-not [object]::ReferenceEquals($script:QueryHeadsFor, $script:Entries)) {
        $script:QueryHeads = New-QueryHeads $script:Entries
        $script:QueryHeadsFor = $script:Entries
      }
      $rows = @([Cb.Search]::Pick($script:Entries, [Cb.Search]::Match($script:QueryHeads, [string[]]@($query.Terms), [string[]]@($query.Excludes))))
    } else {
      $rows = @(Invoke-Query $script:Entries $query)
    }
    # the pins sort first, so the run of sticky rows at the top is what gets frozen
    $script:StickyTop = Get-StickyTopRows $rows $plan.Mark $plan.Max
    $res = [System.Collections.Generic.List[object]]::new()
    $labs = [System.Collections.Generic.List[string]]::new()
    $mk = $(if ($script:ShowNewlineMarker) { 1 } else { 0 })
    foreach ($rec in $rows) {
      $res.Add($rec)
      $lkey = ([int]$rec.Key * 2) + $mk
      $lab = $script:LabelCache[$lkey]
      if ($null -eq $lab) {
        $lab = Get-RecordLabel $rec $script:ShowNewlineMarker
        if ($script:LabelCache.Count -gt 1200) { $script:LabelCache.Clear() }
        $script:LabelCache[$lkey] = $lab
      }
      $labs.Add($lab)
    }
    $script:Filtered = $res.ToArray()
    $script:Labels = $labs.ToArray()
    # the control only learns how many rows there are; the labels stay in $script:Labels
    $lst.ItemCount = $script:Labels.Count
    # freeze the pinned run, then start the scrollable part right under it
    $lst.PinnedCount = $script:StickyTop
    if ($script:Labels.Count -gt 0) { $lst.SelectedIndex = 0 } else { $lst.SelectedIndex = -1 }
    $lst.TopIndex = $script:StickyTop
    # a filter that hides part of the list invalidates the positions behind it
    Trim-Selection $script:Sel ($script:Labels.Count)
    Sync-Selection $script:Sel $lst
  } catch {
    Write-Log ('update list failed: ' + $_.Exception.Message)
  } finally {
    # the lock has to come off even when a row above threw, or the list never paints
    $lst.EndUpdate()
  }
  if ($null -ne $empty) {
    if ($script:Labels.Count -eq 0) {
      $es = Get-EmptyState $script:Entries $query $q $script:Glyphs
      $script:EmptyGlyph = $es.Glyph
      $script:EmptyTitle = $es.Title
      $script:EmptySub = $es.Sub
      $empty.Visible = $true
      $empty.BringToFront()
      $empty.Invalidate()
    } else {
      $empty.Visible = $false
    }
  }
  # the filter changed what sits under the pointer: same reading as after a scroll
  Sync-HoverFromCursor
  Sync-Placeholder
  Sync-SearchCaret
  $lst.Invalidate()
  Sync-Sb
  Restore-Foot
  # A filter that took long enough to feel leaves a line: the row count says whether the cost is
  # the store or the list it fed, which is the first question a slow search asks
  $msUp = [int]$swUp.Elapsed.TotalMilliseconds
  if ($msUp -ge 40) { Write-Log ('picker: filter ' + $msUp + ' ms (' + $script:Labels.Count + ' of ' + @($script:Entries).Count + ' rows)') }
}

function Flush-List {
  $deb = $script:PanelDeb
  $txt = $script:PanelTxt
  if ($null -eq $deb -or $null -eq $txt) { return }
  if ($deb.Enabled) { $deb.Stop(); Update-List $txt.Text }
}

function Del-Index([int]$idx) {
  $txt = $script:PanelTxt
  $lst = $script:PanelList
  if ($idx -lt 0 -or $idx -ge $script:Filtered.Count) { return }
  $victim = $script:Filtered[$idx]
  $removed = [string]$script:History.Remove($victim.Payload)
  if ($removed -like 'protected:*') {
    # only the plugin that declared the mark knows how to remove it
    $pm = $removed.Substring(10)
    $info = Get-MarkInfo $pm
    $word = Get-MarkUiWord $pm
    if ($info -and $info.Unset) {
      $hint = [string]$info.Hint
      # the words the owner uses are named in the language files (plugin.<plugin>.<Set> /
      # plugin.<plugin>.<Unset>), so the sentence names the undo step in either language
      $unset = Get-UiTextOr ('plugin.' + [string]$info.Plugin + '.' + [string]$info.Unset) ([string]$info.Unset)
      if ($hint) { Set-Foot (Get-UiText 'panel.foot.markHint' @($word, $hint, $unset)) ([int]$script:Timing['FootWarn']) }
      else { Set-Foot (Get-UiText 'panel.foot.markNoHint' @($word, $unset)) ([int]$script:Timing['FootWarn']) }
    } else {
      # the sentence names the plugin, not the one character it declared
      $owner = $pm
      if ($info -and $info.Plugin) { $owner = [string]$info.Plugin }
      Set-Foot (Get-UiText 'panel.foot.markNoPlugin' @($word, $owner)) ([int]$script:Timing['FootWarn'])
    }
    return
  }
  if ($removed -eq 'removed') {
    if ($script:UndoOn) { $script:UndoRec = $victim; $script:UndoIdx = $idx }
  }
  # the store re-read only when something was deleted, so its rows are what the panel shows
  $script:Entries = @($script:History.Rows)
  if ($removed -eq 'removed') { Write-Log ('deleted entry (' + $victim.Payload.Length + ' chars), left ' + $script:Entries.Count) }
  if ($null -ne $txt) { Update-List $txt.Text }
  if ($null -ne $lst -and $script:Filtered.Count -gt 0) { $lst.SelectedIndex = [Math]::Min($idx, $script:Filtered.Count - 1) }
  if ($script:UndoOn -and $removed -eq 'removed') { Set-Foot (Get-UiText 'panel.foot.deleted') ([int]$script:Timing['FootMessage']) }
}

function Undo-Delete {
  if (-not $script:UndoOn) { Set-Foot (Get-UiText 'panel.foot.undoOff') ([int]$script:Timing['FootWarn']); return }
  if ($null -eq $script:UndoRec) { Set-Foot (Get-UiText 'panel.foot.nothingToUndo') ([int]$script:Timing['FootShort']); return }
  $rec = $script:UndoRec
  $at = $script:UndoIdx
  $script:UndoRec = $null
  [void](Restore-Record $rec $at)
  Write-Log ('undo restored (' + $rec.Payload.Length + ' chars) at ' + $at)
  $script:Entries = @($script:History.Refresh())
  $txt = $script:PanelTxt
  if ($null -ne $txt) { Update-List $txt.Text }
  Set-Foot (Get-UiText 'panel.foot.restored') ([int]$script:Timing['FootInfo'])
}

function Cancel-Confirm {
  $timer = $script:PanelConfirmTimer
  if ($null -ne $timer) { $timer.Stop() }
  if (-not $script:Confirm) { return }
  $script:Confirm = $false
  Restore-Foot
}

function Request-Clear {
  if ($script:Entries.Count -eq 0) { Set-Foot (Get-UiText 'panel.foot.nothingToClear') ([int]$script:Timing['FootShort']); return }
  $script:Confirm = $true
  $footTimer = $script:PanelFootTimer
  $confirmTimer = $script:PanelConfirmTimer
  $footL = $script:PanelFootL
  if ($null -ne $footTimer) { $footTimer.Stop() }
  $script:FootMode = 'confirm'
  if (@(Get-ClearKeepMarks).Count -gt 0) { $script:FootMsg = Get-UiText 'panel.foot.confirmClearKept' }
  else { $script:FootMsg = Get-UiText 'panel.foot.confirmClearAll' }
  if ($null -ne $footL) { $footL.Invalidate() }
  if ($null -ne $confirmTimer) { $confirmTimer.Stop(); $confirmTimer.Start() }
}

function Clear-All {
  $txt = $script:PanelTxt
  $confirmTimer = $script:PanelConfirmTimer
  $script:Confirm = $false
  if ($null -ne $confirmTimer) { $confirmTimer.Stop() }
  Clear-Store (Get-ClearKeepMarks)
  $script:Entries = @($script:History.Refresh())
  Write-Log ('history cleared from the panel, left ' + $script:Entries.Count + ' rows')
  if ($null -ne $txt) { Update-List $txt.Text }
  $kept = @(Get-MarkUiCount $script:Entries)
  if ($kept.Count -gt 0) { Set-Foot (Get-UiText 'panel.foot.clearedKept' @($kept -join ', ')) ([int]$script:Timing['FootWarn']) }
  else { Set-Foot (Get-UiText 'panel.foot.cleared') ([int]$script:Timing['FootInfo']) }
}

# Closing from inside the panel. The panel holds the foreground, so hiding it hands the front to
# whatever is next in the z-order: the window it came from has to be asked for by name, together
# with the control that owned the caret there.
function Close-Panel {
  $prev = $script:PanelPrev
  # Hiding the panel is what takes the activation away, and the Deactivate handler reads that as
  # a dismissal and clears the flag - so whether the foreground has to be handed back is decided
  # before the window goes, not after it.
  $handBack = ($script:OwnFront -and $prev -ne [IntPtr]::Zero)
  try { [void](Hide-AppWindow 'picker') } catch { }
  if ($handBack) {
    try { [void][Cb.Win]::SetForegroundWindow($prev) } catch { }
    try { [void](Restore-TargetFocus $prev $script:PrevFocus) } catch { }
    # the window that was typing gets its caret back too: some editors drop the selection when
    # they lose the foreground, and a closed panel must not move the caret either
    Put-BackSelection ' (panel closed)'
    $script:SavedSel = @()
  }
  try { [void](Close-AppWindow 'picker') } catch { }
}

function Paste-Clip([string]$TypedText = '', [int]$ClipMs = 0) {
  $prev = $script:PanelPrev
  # every step of a paste is a wait the user can feel, and which one it is cannot be told from a
  # screenshot: one line per paste carries the milliseconds of each stage
  $pasteSw = [Diagnostics.Stopwatch]::StartNew()
  $target = Get-PasteTarget
  Write-Log ('paste target: ' + (Format-PasteTarget $target))
  if ($script:NoPaste) { Close-Panel; return }
  # An elevated window ignores keys sent by a process that is not, and the failure says nothing:
  # nothing arrives and nothing throws. Say so instead of reporting a paste that never happened.
  if (Test-ElevatedTarget $target) {
    Write-Log 'paste skipped: the target window runs elevated'
    Set-Foot (Get-UiText 'panel.foot.copiedAdmin') ([int]$script:Timing['FootMessage'])
    return
  }
  # the hotkey is usually still held when the panel opens: pasting now would send Ctrl+V with
  # Alt/Ctrl down and land as something else entirely
  while ($pasteSw.ElapsedMilliseconds -lt $script:ModReleaseTimeout) {
    if (Test-Modifiers-Up) { break }
    Start-Sleep -Milliseconds 10
  }
  $modMs = [int]$pasteSw.ElapsedMilliseconds
  # waiting only works when the key is let go of soon: a modifier that is still down when the
  # wait ends is released, so the paste cannot arrive as another shortcut
  if (-not (Test-Modifiers-Up)) { Release-HeldModifiers }
  # SetForegroundWindow can be refused by the foreground lock and SendKeys types into whatever is
  # in front, so the target has to have the front. The panel holds it while it is open, so this
  # is the step that moves it back - and losing the activation here is part of the paste, which
  # is what $script:Pasting tells the Deactivate handler.
  $hadFront = $false
  try { $hadFront = ([Cb.Win]::GetForegroundWindow() -eq $target) } catch { $hadFront = $false }
  $frontSw = [Diagnostics.Stopwatch]::StartNew()
  $script:Pasting = $true
  try {
    if (-not $hadFront -and -not (Take-Foreground $target)) {
      Write-Log 'paste skipped: the target window did not take the foreground'
      Set-Foot (Get-UiText 'panel.foot.copiedNoFocus') ([int]$script:Timing['FootMessage'])
      return
    }
    # the window is back but its caret may not be: give the control the keyboard again, and only
    # when it lost it - AttachThreadInput plus SetFocus is another way to raise a window. Only the
    # window the panel came from has a remembered control; after a switch the caret already sits
    # where the user left it.
    if ($target -eq $prev -and $script:PrevFocus -ne [IntPtr]::Zero) {
      $hasFocus = $false
      try { $hasFocus = ([Cb.Win]::FocusOfWindow($target) -eq $script:PrevFocus) } catch { $hasFocus = $false }
      if (-not $hasFocus) { [void](Restore-TargetFocus $target $script:PrevFocus) }
    }
    # the window needs a moment before it takes the keyboard again: a chord sent inside that gap
    # is dropped without an error. After a page key moved the list the gap is longer, and 30 ms
    # lost one pick in three on Chromium 76 while 80 ms lost none.
    Start-Sleep -Milliseconds $script:PasteSettle
    $focusMs = [int]$frontSw.ElapsedMilliseconds
    # The foreground can move again while the panel settles (another window, a shell flyout), and
    # the keys would go into whatever is in front by then: Ditto re-checks the target at this
    # point too, and its log marks the case "paste timing around activate target".
    try {
      if ([Cb.Win]::GetForegroundWindow() -ne $target) {
        Write-Log 'paste: the foreground moved before the keys, taking it back'
        [void](Take-Foreground $target)
      }
    } catch { }
    # an editor that dropped its selection when the panel took the foreground gets the caret back
    # here, before the keys: only for the window the panel came from, because after an Alt+Tab
    # the caret already sits where the user left it in the other window
    if ($target -eq $prev) { Put-BackSelection }
    # the target moves the caret itself once the text is in, so the close that follows must not
    # select the old range again - that put the caret back in front of what was pasted
    $script:SavedSel = @()
    # The keys go out before the panel is hidden: hiding the active window first lets Windows pick
    # the next window in the z-order, and taking the front back afterwards is exactly what reads
    # as "the window I had focused before flashes up".
    if ($TypedText -ne '') {
      # typing lands in the focused control through SendInput: no clipboard and no paste key,
      # which is what a target that ignores Ctrl+V needs
      $keysSw = [Diagnostics.Stopwatch]::StartNew()
      $sent = 0
      try { $sent = [Cb.Win]::SendUnicode($TypedText) } catch { Write-Log ('typing failed: ' + $_.Exception.Message) }
      Write-Log ('typed ' + $sent + ' of ' + $TypedText.Length + ' characters')
    } else {
      $keysSw = [Diagnostics.Stopwatch]::StartNew()
      # SendKeys builds its modifier from a virtual key with no scan code, and an input method can
      # answer that with VK_PROCESSKEY: the chord then lands as a bare letter and nothing is
      # pasted (measured on Chromium 76, once in about ten opens). One chord is sent as the
      # physical key instead; a sequence or a repeat still needs SendKeys.
      $chord = $false
      try { $chord = Send-PasteChord $script:PasteKeys } catch { $chord = $false }
      if (-not $chord) {
        Write-Log 'paste keys: SendKeys (not a single chord)'
        try { [Windows.Forms.SendKeys]::SendWait($script:PasteKeys) } catch { Write-Log ('sendkeys fail: ' + $_.Exception.Message) }
      }
    }
    Write-Log ('paste: ' + [int]$pasteSw.ElapsedMilliseconds + ' ms (clip ' + $ClipMs + ', mod ' + $modMs + ', focus ' + $focusMs + ', settle ' + [int]$script:PasteSettle + ', keys ' + [int]$keysSw.ElapsedMilliseconds + ')')
    try {
      $after = [Cb.Win]::GetForegroundWindow()
      if ($after -ne $target) { Write-Log ('paste: the foreground changed while the keys were sent (' + (Format-WindowName $after) + ')') }
    } catch { }
    [void](Hide-AppWindow 'picker')
    # the panel leaving can still move the foreground; the paste is already done, so this only
    # puts the user back where they were
    if ([Cb.Win]::GetForegroundWindow() -ne $target) {
      $moved = [Cb.Win]::GetForegroundWindow()
      Write-Log ('paste: the foreground moved after the panel hid (' + (Format-WindowName $moved) + '), taking it back')
      [void](Take-Foreground $target)
    }
  } finally {
    $script:Pasting = $false
  }
  [void](Close-AppWindow 'picker')
}

function Use-Index([int]$idx, [switch]$NoInject) {
  if ($idx -lt 0 -or $idx -ge $script:Filtered.Count) { return }
  $rec = $script:Filtered[$idx]
  $payload = $rec.Payload
  # the formatted sidecar only applies to the text that produced it
  $rich = [string]$rec.Rich
  # a plugin may rewrite what gets pasted (text only, upper case, snake case ...)
  if (Get-Command Invoke-PluginTransform -ErrorAction SilentlyContinue) {
    try {
      $t = Invoke-PluginTransform $payload
      if ($null -ne $t -and [string]$t -ne '' -and [string]$t -cne $payload) {
        $payload = [string]$t
        $rich = ''
        Write-Log ('pasted via transform (' + $payload.Length + ' chars)')
      }
    } catch { Write-Log ('transform skipped: ' + $_.Exception.Message) }
  }
  $pasteTo = Get-PasteTarget
  if ($script:NoPaste -or $NoInject.IsPresent -or (Test-AppRuleNoPaste $pasteTo)) { [void](Set-ClipItem $payload $rich); Set-LastCapture $payload; Close-Panel; return }
  # the program in front decides whether the formatting travels with the paste: a terminal wants
  # the text, an editor wants the layout. The window asked about is the one the paste goes back
  # to - the panel itself may be in front after a hand-over.
  if ($rich -and -not (Test-AppRuleKeepsRich $pasteTo)) { $rich = '' }
  $clipSw = [Diagnostics.Stopwatch]::StartNew()
  $okClip = Set-ClipItem $payload $rich
  $clipMs = [int]$clipSw.ElapsedMilliseconds
  if (-not $okClip) { Write-Log 'set clipboard failed'; Close-Panel; return }
  # our own write must not come back as a new capture
  Set-LastCapture $payload
  # PasteTyping=1 skips the paste key. Only plain text can be typed: a file list and a picture
  # still need the clipboard.
  $typed = ''
  if ($script:PasteTyping -and $rich -eq '' -and -not (Test-FilePayload $payload) -and -not (Test-ImagePayload $payload)) { $typed = $payload }
  Paste-Clip -TypedText $typed -ClipMs $clipMs
}

# Hover preview (renderer\src\components\preview.ps1): it waits for the cursor to rest and
# prepares a record's text once, so sweeping the list costs a timestamp per row and nothing else.
function Show-HoverPreview {
  $pv = $script:PanelPv
  $lst = $script:PanelList
  $form = $script:PanelForm
  $pvCfg = $script:PanelPvCfg
  if ($null -eq $pv -or $null -eq $lst -or $null -eq $form -or $null -eq $pvCfg) { return }
  if ($script:Hover -lt 0 -or $script:Hover -ge $script:Filtered.Count) { Hide-Preview $pv; $script:PvIdx = -1; return }
  $pvCfg.Area = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
  $at = $lst.PointToScreen($lst.GetItemRectangle($script:Hover).Location)
  Update-Preview $pv $script:Filtered[$script:Hover] $at.Y $pvCfg $form.Bounds
  $script:PvIdx = $script:Hover
}

# The row menu is the tray menu's twin: the same skin, the same rounded rows and the same hairline
# separators. renderer\src\windows\tray-menu.ps1 owns the layout and the row helpers, and
# Cb.TrayMenu paints it, so a right click beside the panel does not open a window drawn in the
# system colours.
function Fill-RowMenu($cur) {
  $cm = $script:PanelMenu
  $cmSkin = $script:PanelMenuSkin
  $menuGlyph = $script:PanelMenuGlyph
  $lst = $script:PanelList
  $txt = $script:PanelTxt
  if ($null -eq $cm -or $null -eq $cmSkin -or $null -eq $menuGlyph) { return }
  $has = ($null -ne $cur)
  foreach ($old in @($cm.Items)) { try { $old.Dispose() } catch { } }
  $cm.Items.Clear()

  $paste = New-TrayMenuRow -Skin $cmSkin -Label (Get-UiText 'menu.paste') -Glyph $menuGlyph.Paste
  $paste.Hint = 'Enter'
  $paste.Enabled = $has
  # the primary action carries the accent on its glyph, the way a Fluent menu marks the one row a
  # press is usually meant for
  $paste.GlyphInk = $cmSkin.Accent
  $paste.Add_Click({ Use-Index $lst.SelectedIndex })
  [void]$cm.Items.Add($paste)

  $copy = New-TrayMenuRow -Skin $cmSkin -Label (Get-UiText 'menu.copyOnly') -Glyph $menuGlyph.Copy
  $copy.Hint = 'Ctrl+Enter'
  $copy.Enabled = $has
  $copy.Add_Click({ Use-Index $lst.SelectedIndex -NoInject })
  [void]$cm.Items.Add($copy)

  # a picture, a file list and a formatted entry have nothing the editor can show
  $editable = ($has -and (Test-RowEditable $cur))
  if ($editable) {
    $edit = New-TrayMenuRow -Skin $cmSkin -Label (Get-UiText 'menu.edit') -Glyph $menuGlyph.Edit
    $edit.Hint = 'F2'
    $edit.Add_Click({ Begin-RowEdit })
    [void]$cm.Items.Add($edit)
  }

  $del = New-TrayMenuRow -Skin $cmSkin -Label (Get-UiText 'menu.delete') -Glyph $menuGlyph.Delete
  $del.Hint = 'Del'
  $del.Enabled = $has
  # a removal warns in the same token the panel uses for a refusal
  $del.GlyphInk = $cmSkin.Warn
  $del.Ink = $cmSkin.Warn
  $del.Add_Click({ try { Del-Index $lst.SelectedIndex } catch { } })
  [void]$cm.Items.Add($del)

  $clear = New-TrayMenuRow -Skin $cmSkin -Label (Get-UiText 'menu.clearHistory') -Glyph $menuGlyph.Clear
  $clear.Enabled = ($script:Entries.Count -gt 0)
  $clear.GlyphInk = $cmSkin.Warn
  $clear.Ink = $cmSkin.Warn
  # the destructive row starts its own block: a separator row, not a line inside the row, so the
  # air above the line and below it is the same as everywhere else in the menu
  [void](Add-TrayMenuSeparator $cm $cmSkin)
  [void]$cm.Items.Add($clear)
  $clear.Add_Click({ Request-Clear })

  # plugin actions: one group per plugin, in load order, with a header that names it. Only the
  # actions whose Test passes for this row are built, so nothing has to be hidden later.
  $picked = New-Object System.Collections.Generic.List[object]
  try {
    if ($has -and (Get-Command Get-PluginActions -ErrorAction SilentlyContinue)) {
      foreach ($act in @(Get-PluginActions)) {
        if (-not (Test-PluginAction $act $cur)) { continue }
        [void]$picked.Add($act)
      }
    }
  } catch { Write-Log ('plugin menu failed: ' + $_.Exception.Message) }

  $seen = New-Object System.Collections.Generic.List[string]
  foreach ($act in $picked) {
    $owner = [string]$act['Plugin']
    if (-not $seen.Contains($owner)) {
      [void]$seen.Add($owner)
      # every plugin block starts with a line, the way the built-in block before it does
      [void](Add-TrayMenuSeparator $cm $cmSkin)
      $cap = New-TrayMenuRow -Skin $cmSkin -Label (Get-UiTextOr ('plugin.caption.' + $owner) $owner) -Caption
      [void]$cm.Items.Add($cap)
    }
    $row = New-TrayMenuRow -Skin $cmSkin -Label (Get-ActionText $act $cur)
    if ($act.ContainsKey('Key')) { $row.Hint = [string]$act['Key'] }
    $row.Tag = $act
    $row.Add_Click([System.EventHandler]{
        param($sn, $ev)
        try {
          $a = $sn.Tag
          if ($null -eq $a -or $lst.SelectedIndex -lt 0) { return }
          if ($lst.SelectedIndex -ge $script:Filtered.Count) { return }
          # a returned string is a note for the footer (a refused pin, for one)
          $note = (& $a['Invoke'] $script:Filtered[$lst.SelectedIndex]); if ($note) { Set-Foot ([string]$note) ([int]$script:Timing['FootMessage']) }
          $script:Entries = @($script:History.Refresh())
          # After = 'paste': the action put its result on the clipboard and wants it pasted into
          # the window the picker came from (transform does this)
          if ($a.ContainsKey('After') -and [string]$a['After'] -eq 'paste') { Paste-Clip }
          else { Update-List $txt.Text }
        } catch { Write-Log ('plugin action failed: ' + $_.Exception.Message) }
      })
    [void]$cm.Items.Add($row)
  }
  $cm.Fit()
}

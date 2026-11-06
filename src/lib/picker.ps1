# lib/picker.ps1 - the history panel. One function owns the whole window lifecycle (create,
# filter, draw, keys, paste); the standalone pieces live in picker-geom / entry / plugins.

function Show-Picker {
  if ($script:PickerOpen) { $script:PickerClose = $true; return }   # a second hotkey press closes it
  $script:PickerOpen = $true
  $script:PickerClose = $false
  try {
    Load-Forms
    Add-Native
    Initialize-Dpi
    if (-not $script:UiFamily) {
      $script:UiFamily = 'Tahoma'
      $wantFace = [string]$script:ThemeFace.Font
      if ($wantFace -and (Test-Font $wantFace)) { $script:UiFamily = $wantFace }
      elseif (Test-Font 'Segoe UI Variable Text') { $script:UiFamily = 'Segoe UI Variable Text' }
      elseif (Test-Font 'Segoe UI') { $script:UiFamily = 'Segoe UI' }
      # Win11 ships Segoe Fluent Icons; Win10 only has Segoe MDL2 Assets
      $wantIcon = [string]$script:ThemeFace.Icon
      $script:IconFamily = ''
      if ($wantIcon -and (Test-Font $wantIcon)) { $script:IconFamily = $wantIcon }
      elseif (Test-Font 'Segoe Fluent Icons') { $script:IconFamily = 'Segoe Fluent Icons' }
      elseif (Test-Font 'Segoe MDL2 Assets') { $script:IconFamily = 'Segoe MDL2 Assets' }
      $script:HasMdl2 = [bool]$script:IconFamily
    }
    $prev = [Cb.Win]::GetForegroundWindow()
    $script:Entries = @(Get-Records)
    if ($script:Entries.Count -eq 0) { Write-Log 'picker: empty (showing hint)' }

    $ui = Get-UiPalette
    if (-not $script:FBody) {
      # Win11 type ramp by default; a theme may override any of the sizes through Fonts.
      $tf = $script:ThemeFonts
      $szBody = 10.5; $szSmall = 9.0; $szTiny = 9.0; $szTitle = 13.0
      $szIcon = 12.0; $szIconSmall = 10.0; $szIconBig = 24.0
      if ($tf.ContainsKey('Body')) { $szBody = [double]$tf['Body'] }
      if ($tf.ContainsKey('Small')) { $szSmall = [double]$tf['Small'] }
      if ($tf.ContainsKey('Tiny')) { $szTiny = [double]$tf['Tiny'] }
      if ($tf.ContainsKey('Title')) { $szTitle = [double]$tf['Title'] }
      if ($tf.ContainsKey('Icon')) { $szIcon = [double]$tf['Icon'] }
      if ($tf.ContainsKey('IconSmall')) { $szIconSmall = [double]$tf['IconSmall'] }
      if ($tf.ContainsKey('IconBig')) { $szIconBig = [double]$tf['IconBig'] }
      $script:FBody = New-Object Drawing.Font($script:UiFamily, [single]$szBody)
      $script:FSmall = New-Object Drawing.Font($script:UiFamily, [single]$szSmall)
      $script:FTiny = New-Object Drawing.Font($script:UiFamily, [single]$szTiny)
      $script:FTitle = New-Object Drawing.Font($script:UiFamily, [single]$szTitle, [Drawing.FontStyle]::Bold)
      if ($script:IconFamily) {
        # 12 pt renders a 16 px glyph, 10 pt a 13 px one, 24 pt the empty-state art
        $script:FIcon = New-Object Drawing.Font($script:IconFamily, [single]$szIcon)
        $script:FIconSmall = New-Object Drawing.Font($script:IconFamily, [single]$szIconSmall)
        $script:FIconBig = New-Object Drawing.Font($script:IconFamily, [single]$szIconBig)
      } else {
        $script:FIcon = $script:FBody
        $script:FIconSmall = $script:FSmall
        $script:FIconBig = $script:FTitle
      }
    }
    $fBody = $script:FBody; $fSmall = $script:FSmall; $fTiny = $script:FTiny
    $fTitle = $script:FTitle; $fIcon = $script:FIcon; $fIconSmall = $script:FIconSmall; $fIconBig = $script:FIconBig
    $script:Hover = -1
    $script:Anim = New-AnimState
    $script:Confirm = $false
    $script:CtrlHeld = $false
    $script:SearchFocus = $false
    # true while the low-level hook is feeding the panel (the panel itself never activates)
    $script:PickerHook = $false
    $script:PickerEscalated = $false
    $script:PrevMouseDown = $false
    $script:FootMode = 'hints'
    $script:FootMsg = ''
    $script:CapturePaused = (Test-Path -LiteralPath $Paused)
    $script:UndoRec = $null
    $script:UndoIdx = 0
    $script:Filtered = @()
    # rows marked for a batch action (lib/select.ps1): positions in the filtered list
    $script:Sel = New-Selection
    $script:Labels = @()
    $script:Tokens = @()
    # rows frozen at the top of the list: the pinned block that never scrolls
    $script:StickyTop = 0
    # Plugin keys and per-row decoration are resolved once per entry, not per key press / paint.
    $panelKeys = @()
    if (Get-Command Get-PluginPanelKeys -ErrorAction SilentlyContinue) { $panelKeys = @(Get-PluginPanelKeys) }
    $ctrlHints = @($panelKeys | Where-Object { $_.Ctrl -and -not $_.Alt -and -not $_.Shift -and ([string]$_.Key).Length -eq 1 })
    # Both caches survive a refresh and a reopen: the record numbers keep growing, so an
    # entry carried over can never be mistaken for a different row.
    if ($null -eq $script:RowCache -or $null -eq $script:LabelCache) { $script:RowCache = @{}; $script:LabelCache = @{} }
    $rowCache = $script:RowCache; $labelCache = $script:LabelCache
    function Find-PanelKey([string]$keyName, [bool]$ctrl, [bool]$alt, [bool]$shift) {
      $name = ([string]$keyName).ToUpperInvariant()
      foreach ($k in $panelKeys) {
        if ($k.Key -ne $name) { continue }
        if ([bool]$k.Ctrl -ne $ctrl) { continue }
        if ([bool]$k.Alt -ne $alt) { continue }
        if ([bool]$k.Shift -ne $shift) { continue }
        return $k
      }
      return $null
    }

    $form = New-Object Cb.FluentForm
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'Manual'
    # no TopMost property: assigning it makes WinForms call SetWindowPos without
    # SWP_NOACTIVATE, which activates the panel; it is raised right after Show() instead.
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.Text = 'Clipboard history'
    $form.AccessibleName = 'Clipboard history'
    $form.Width = Px $script:WinWidth
    # The height comes from the row count, never from a setting of its own, so no row is ever
    # half cut off; the screen caps it and matching Min/Max heights leave the drag to width.
    $screenH = 0; try { $screenH = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea.Height } catch { }
    $rows = Get-RowsForScreen $script:Rows ([int]([double]$screenH / [double]$script:UiScale)) (Get-PanelRowHeight) (Get-PanelChrome) ([int]$script:IniSchema['Rows'].Minimum)
    if ($rows -ne $script:Rows) { Write-Log ('picker: rows ' + $script:Rows + ' -> ' + $rows + ' to fit this screen') }
    $form.Height = Px (Get-PanelHeight $rows (Get-PanelRowHeight) (Get-PanelChrome))
    $form.MinimumSize = New-Object Drawing.Size -ArgumentList @((Px ([int]$script:IniSchema['WindowWidth'].Minimum)), $form.Height)
    $form.MaximumSize = New-Object Drawing.Size -ArgumentList @((Px ([int]$script:IniSchema['WindowWidth'].Maximum)), $form.Height)
    $form.BackColor = $ui.Surface
    $form.Padding = New-Object Windows.Forms.Padding(1)

    Add-PinList
    $lst = New-Object Cb.PinList
    $lst.Dock = 'None'
    $lst.ItemHeight = Px (Get-PanelRowHeight)
    $lst.BackColor = $ui.Surface
    $lst.ForeColor = $ui.Text
    $lst.Font = $fBody
    $lst.AccessibleName = 'Clipboard entries'

    # The native scrollbar cannot be themed and ListBox has no property to hide it, so the list
    # sits in a clipping host and is made wider than it: the scrollbar lands outside the view.
    $listHost = New-Object Windows.Forms.Panel
    $listHost.Dock = 'Fill'
    $listHost.BackColor = $ui.Surface
    $lst.SetBounds(0, 0, 100, 100)
    $listHost.Controls.Add($lst)

    # empty state: a centered Fluent block (glyph + title + hint) drawn over the list
    $script:EmptyGlyph = [string][char]0xE721
    $script:EmptyTitle = ''
    $script:EmptySub = ''
    $empty = New-Object Windows.Forms.Panel
    $empty.Dock = 'Fill'
    $empty.BackColor = $ui.Surface
    $empty.Visible = $false
    $empty.Add_Paint({
        param($s, $e)
        try {
          $g = $e.Graphics
          $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
          $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
          $w = $empty.ClientSize.Width
          $cy = [int]($empty.ClientSize.Height / 2) - (Px 56)
          if ($script:IconFamily) {
            $gb = New-Object Drawing.SolidBrush $ui.Faint
            $gr = New-Object Drawing.RectangleF -ArgumentList @(0, [single]$cy, [single]$w, [single](Px 34))
            $g.DrawString($script:EmptyGlyph, $fIconBig, $gb, $gr, $sfCenter)
            $gb.Dispose()
            $cy = $cy + (Px 36)
          }
          if ($script:EmptyTitle) {
            $tb = New-Object Drawing.SolidBrush $ui.Dim
            $tr = New-Object Drawing.RectangleF -ArgumentList @(0, [single]$cy, [single]$w, [single](Px 26))
            $g.DrawString($script:EmptyTitle, $fTitle, $tb, $tr, $sfCenter)
            $tb.Dispose()
            $cy = $cy + (Px 28)
          }
          if ($script:EmptySub) {
            $sb = New-Object Drawing.SolidBrush $ui.Faint
            $sr = New-Object Drawing.RectangleF -ArgumentList @(0, [single]$cy, [single]$w, [single](Px 22))
            $g.DrawString($script:EmptySub, $fSmall, $sb, $sr, $sfCenter)
            $sb.Dispose()
          }
        } catch { }
      })
    $listHost.Controls.Add($empty)
    $empty.Add_Click({ Focus-Search })

    # A thin rounded thumb is painted instead, brightening on hover.
    $sbar = New-Object Windows.Forms.Panel
    $sbar.Dock = 'Right'
    $sbar.Width = Px 10
    $sbar.BackColor = $ui.Surface
    $script:SbTop = 0
    $script:SbLen = 0
    $script:SbDrag = -1
    $script:SbHot = $false

    $foot = New-Object Windows.Forms.Panel
    $foot.Dock = 'Bottom'
    $foot.Height = Px $script:Metric['FootHeight']
    $foot.BackColor = $ui.Surface

    $footR = New-Object Windows.Forms.Label
    $footR.Dock = 'None'
    $footR.TextAlign = 'MiddleRight'
    $footR.Font = $fSmall
    $footR.ForeColor = $ui.Faint
    $footR.BackColor = $ui.Surface
    $footR.AutoEllipsis = $true
    $footR.Text = ''

    $footL = New-Object Windows.Forms.Panel
    $footL.Dock = 'Fill'
    $footL.BackColor = $ui.Surface

    $foot.Controls.Add($footR)
    $foot.Controls.Add($footL)

    $head = New-Object Windows.Forms.Panel
    $head.Dock = 'Top'
    $head.Height = Px $script:Metric['HeadHeight']
    $head.BackColor = $ui.Surface
    # an empty piece of the header is still "the search area": clicking it puts the caret
    # in the box (the panel opens without the keyboard, so the first click brings it over)
    $head.Add_Click({ Focus-Search })

    $box = New-Object Windows.Forms.Panel
    $box.SetBounds((Px 14), (Px 14), ($form.ClientSize.Width - (Px 30)), (Px 40))
    $box.BackColor = $ui.Field
    $box.Add_Click({ Focus-Search })
    $box.Add_Paint({
        param($s, $e)
        try {
          $g = $e.Graphics
          $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
          $w = $box.ClientSize.Width
          $h = $box.ClientSize.Height
          # 1 px resting border; 2 px accent underline while the field has focus
          $pen = New-Object Drawing.Pen $ui.FieldBorder, 1
          $path = New-RoundPath 0 0 ($w - 1) ($h - 1) (Px 4)
          $g.DrawPath($pen, $path)
          $path.Dispose()
          $pen.Dispose()
          if ($script:Anim.Field -gt 0.02) {
            $accentPen = New-Object Drawing.Pen (Scale-Alpha $ui.Accent ([double]$script:Anim.Field)), (Px 2)
            $g.DrawLine($accentPen, (Px 4), ($h - (Px 2)), ($w - (Px 4)), ($h - (Px 2)))
            $accentPen.Dispose()
          }
        } catch { }
      })

    $icon = New-Object Windows.Forms.Label
    $icon.SetBounds((Px 12), (Px 10), (Px 20), (Px 20))
    $icon.Text = $(if ($script:IconFamily) { [string][char]0xE721 } else { '' })
    $icon.Font = $fIcon
    $icon.ForeColor = $ui.Faint
    $icon.BackColor = $ui.Field
    $icon.TextAlign = 'MiddleCenter'
    $icon.Cursor = 'IBeam'
    $icon.Add_Click({ Focus-Search })

    $txt = New-Object Windows.Forms.TextBox
    $txt.BorderStyle = 'None'
    $txt.SetBounds((Px 38), (Px 10), ($box.Width - (Px 80)), (Px 22))
    $txt.BackColor = $ui.Field
    $txt.ForeColor = $ui.Text
    $txt.Font = $fBody
    $txt.AccessibleName = 'Search clipboard history'

    $ph = New-Object Windows.Forms.Label
    $ph.SetBounds((Px 40), (Px 10), ($box.Width - (Px 106)), (Px 22))
    $ph.Text = 'Search clipboard history'
    $ph.Font = $fBody
    $ph.ForeColor = $ui.Faint
    $ph.BackColor = $ui.Field
    $ph.TextAlign = 'MiddleLeft'
    $ph.Cursor = 'IBeam'

    $clr = New-Object Windows.Forms.Label
    $clr.SetBounds(($box.Width - (Px 30)), (Px 10), (Px 20), (Px 22))
    $clr.Text = $(if ($script:IconFamily) { [string][char]0xE8BB } else { 'x' })
    # the glyph only exists in the icon font - with the text font it renders as a box
    $clr.Font = $(if ($script:IconFamily) { $fIconSmall } else { $fSmall })
    $clr.ForeColor = $ui.Dim
    $clr.BackColor = $ui.Field
    $clr.TextAlign = 'MiddleCenter'
    $clr.Cursor = 'Hand'
    $clr.Visible = $false
    $clr.AccessibleName = 'Clear search'
    $clr.Add_MouseEnter({ $clr.ForeColor = $ui.Text })
    $clr.Add_MouseLeave({ $clr.ForeColor = $ui.Dim })

    $line = New-Object Windows.Forms.Panel
    $line.Dock = 'Bottom'
    $line.Height = 1
    $line.BackColor = $ui.Border

    $box.Controls.Add($icon)
    $box.Controls.Add($txt)
    $box.Controls.Add($clr)
    $box.Controls.Add($ph)
    $ph.BringToFront()
    $head.Controls.Add($box)
    $head.Controls.Add($line)

    # drag grip: width only - the height follows from the row count (see MinimumSize above)
    $grip = New-Object Windows.Forms.Panel
    $grip.Size = New-Object Drawing.Size -ArgumentList @((Px 16), (Px 16))
    $grip.BackColor = $ui.Surface
    $grip.Cursor = 'SizeWE'

    $form.Controls.Add($listHost)
    $form.Controls.Add($sbar)
    $form.Controls.Add($foot)
    $form.Controls.Add($head)
    $form.Controls.Add($grip)

    # A remembered position wins only when the panel still lands on a screen.
    $areas = @()
    try { foreach ($sc in [Windows.Forms.Screen]::AllScreens) { $areas += $sc.WorkingArea } } catch { }
    $fallback = $null
    try { $fallback = [Windows.Forms.Screen]::FromHandle($prev).WorkingArea } catch { }
    if (-not $fallback) { try { $fallback = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea } catch { } }
    if (-not $fallback) { $fallback = New-Object Drawing.Rectangle -ArgumentList @(0, 0, $form.Width, $form.Height) }
    $pb = Get-PickerBounds $form.Width $form.Height ([string]$script:WinLeft) ([string]$script:WinTop) $areas $fallback
    $form.Left = [int]$pb.Left
    $form.Top = [int]$pb.Top

    function Layout-Chrome {
      try {
        $cw = $form.ClientSize.Width
        $box.SetBounds((Px 14), (Px 14), ($cw - (Px 30)), (Px 40))
        $txt.SetBounds((Px 38), (Px 10), ($box.Width - (Px 80)), (Px 22))
        $ph.SetBounds((Px 40), (Px 10), ($box.Width - (Px 106)), (Px 22))
        $clr.SetBounds(($box.Width - (Px 30)), (Px 10), (Px 20), (Px 22))
        $box.Region = New-RoundRegion $box.Width $box.Height (Px 4)
      } catch { }
      try {
        $grip.SetBounds(($form.ClientSize.Width - (Px 18)), ($form.ClientSize.Height - (Px 18)), (Px 16), (Px 16))
        $grip.BringToFront()
      } catch { }
      try {
        $footR.SetBounds(($foot.ClientSize.Width - (Px 210)), 0, (Px 196), $foot.ClientSize.Height)
      } catch { }
      $footL.Invalidate()
    }

    # shortcut hints as Fluent key chips: [key] action, built in lib/picker-draw.ps1
    $footL.Add_Paint({
        param($s, $e)
        try {
          $g = $e.Graphics
          $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
          $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
          $cy = [int]($footL.ClientSize.Height / 2)
          if ($script:FootMode -eq 'confirm') {
            $wb = New-Object Drawing.SolidBrush $ui.Warn
            $wr = New-Object Drawing.RectangleF -ArgumentList @([single](Px 14), 0, [single]($footL.ClientSize.Width - (Px 20)), [single]$footL.ClientSize.Height)
            $g.DrawString($script:FootMsg, $fSmall, $wb, $wr, $sfNone)
            $wb.Dispose()
            return
          }
          if ($script:FootMode -eq 'message') {
            $mb = New-Object Drawing.SolidBrush $ui.Dim
            $mr = New-Object Drawing.RectangleF -ArgumentList @([single](Px 14), 0, [single]($footL.ClientSize.Width - (Px 20)), [single]$footL.ClientSize.Height)
            $g.DrawString($script:FootMsg, $fSmall, $mb, $mr, $sfNone)
            $mb.Dispose()
            return
          }
          $chipLimit = $footR.Left - (Px 8)
          if ($chipLimit -lt (Px 60)) { $chipLimit = $footL.ClientSize.Width - (Px 8) }
          Draw-KeyChips $g (Px 14) $cy (Get-FootHints $script:Filtered.Count $script:CtrlHeld $ctrlHints) $ui.Dim $ui.Faint $chipLimit
        } catch { }
      })

    function Restore-Foot {
      try {
        if ($script:Confirm) { return }
        $script:FootMode = 'hints'
        $script:FootMsg = ''
        $footL.Invalidate()
        $count = ([string]$script:Filtered.Count) + ' of ' + ([string]$script:Entries.Count)
        if ($script:StickyTop -gt 0) { $count = $count + '   ' + ([string]$script:StickyTop) + ' pinned' }
        if ($script:CapturePaused) { $count = 'Paused: ' + $count }
        # the version sits at the right end of the same quiet label as the row count
        $footR.Text = $count + '   v' + $script:Version
      } catch { }
    }

    function Set-Foot([string]$msg, [int]$ms = 0) {
      if ($script:Confirm) { return }
      if ($ms -le 0) { $ms = [int]$script:Timing['FootMessage'] }
      $script:FootMode = 'message'
      $script:FootMsg = $msg
      $footL.Invalidate()
      try {
        $footTimer.Stop()
        if ($ms -gt 0) { $footTimer.Interval = $ms; $footTimer.Start() }
      } catch { }
    }

    function Sync-Placeholder {
      $ph.Visible = ($txt.Text.Length -eq 0)
      $clr.Visible = ($txt.Text.Length -gt 0)
    }

    function Get-Rows {
      return (Get-VisibleRowCount $lst.ClientSize.Height $lst.ItemHeight)
    }

    # the list is wider than its host, so the host clips the strip a native bar would use
    function Size-List {
      $w = $listHost.ClientSize.Width
      $h = $listHost.ClientSize.Height
      if ($w -gt 0 -and $h -gt 0) { $lst.SetBounds(0, 0, $w + (Px 40), $h) }
    }

    # thumb geometry from TopIndex; the frozen block stays out of the scrollable range
    function Sync-Sb {
      $n = $lst.ItemCount
      $vis = Get-Rows
      $pin = $lst.PinnedCount
      $h = $sbar.ClientSize.Height
      if ($n -le $vis -or $h -le (Px 12)) { $script:SbLen = 0; $sbar.Invalidate(); return }
      $track = $h - (Px 6)
      $scrollRows = [Math]::Max(1, $n - $pin)
      $scrollVis = [Math]::Max(1, $vis - $pin)
      $script:SbLen = [Math]::Max((Px 28), [int]($track * $scrollVis / $scrollRows))
      $span = $track - $script:SbLen
      $room = $lst.MaxTop - $pin
      $t = 0
      if ($room -gt 0 -and $span -gt 0) { $t = [int]($span * ($lst.TopIndex - $pin) / $room) }
      $script:SbTop = (Px 3) + $t
      $sbar.Invalidate()
    }

    # move the list so the thumb lands at $thumbTop
    function Sb-ScrollTo([int]$thumbTop) {
      if ($script:SbLen -le 0) { return }
      $span = ($sbar.ClientSize.Height - (Px 6)) - $script:SbLen
      $pin = $lst.PinnedCount
      $room = $lst.MaxTop - $pin
      if ($room -le 0 -or $span -le 0) { return }
      $i = $pin + [int][Math]::Round(($thumbTop - (Px 3)) * $room / $span)
      # ScrollTo raises ScrollChanged, which syncs the thumb for us
      $lst.ScrollTo($i)
      $lst.Invalidate()
    }

    function Scroll-By([int]$rows) {
      $lst.ScrollBy($rows)
      Sync-Sb
    }

    # rows per wheel notch: the ini setting wins, otherwise the system's own line count
    $wheelLines = $(try { [Windows.Forms.SystemInformation]::MouseWheelScrollLines } catch { 3 })
    if ($script:ScrollLines -gt 0) { $wheelLines = [int]$script:ScrollLines }
    $lst.WheelRows = [Math]::Max(1, [int]$wheelLines)
    # every way the list can scroll (wheel, drag, keys, selection) has to move the thumb
    $lst.Add_ScrollChanged({ Sync-Sb; Hide-Preview $pv; $script:PvIdx = -1 })

    # the list scrolls itself on the wheel; with the pointer anywhere else it bubbles here
    $form.Add_MouseWheel({
        param($s, $e)
        $step = $lst.WheelRows
        if ($e.Delta -gt 0) { Scroll-By (-$step) } else { Scroll-By $step }
      })

    $head.Add_MouseDown({
        param($s, $e)
        if ($e.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
        [void][Cb.Win]::ReleaseCapture()
        [void][Cb.Win]::SendMessage($form.Handle, 0xA1, [IntPtr]2, [IntPtr]::Zero)
      })
    $grip.Add_Paint({
        param($s, $e)
        if ($script:Anim.Grip -le 0.02) { return }
        try {
          $e.Graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
          $pen = New-Object Drawing.Pen (Scale-Alpha ([Drawing.Color]::FromArgb(120, $ui.Dim)) ([double]$script:Anim.Grip)), 1
          $cw = $grip.ClientSize.Width
          $e.Graphics.DrawLine($pen, ($cw - (Px 4)), ($cw - (Px 9)), ($cw - (Px 9)), ($cw - (Px 4)))
          $e.Graphics.DrawLine($pen, ($cw - (Px 4)), ($cw - (Px 13)), ($cw - (Px 13)), ($cw - (Px 4)))
          $pen.Dispose()
        } catch { }
      })
    $grip.Add_MouseEnter({ Set-AnimTarget $script:Anim 'Grip' 1.0 })
    $grip.Add_MouseLeave({ Set-AnimTarget $script:Anim 'Grip' 0.0 })
    $grip.Add_MouseDown({
        [void][Cb.Win]::ReleaseCapture()
        [void][Cb.Win]::SendMessage($form.Handle, 0xA1, [IntPtr]0x11, [IntPtr]::Zero)
      })

    $sbar.Add_Paint({
        param($s, $e)
        if ($script:SbLen -le 0) { return }
        $e.Graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $hot = ($script:SbHot -or $script:SbDrag -ge 0)
        $k = [double]$script:Anim.Sb
        if ($hot) { $k = 1.0 }
        $w = [int][Math]::Round((Px 3) + ($k * ((Px 6) - (Px 3))))
        $alpha = [int][Math]::Round(110 + ($k * 80))
        $x = [int](($sbar.ClientSize.Width - $w) / 2)
        $br = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb($alpha, $ui.Dim))
        $gp = New-RoundPath $x $script:SbTop $w $script:SbLen ([Math]::Max(1, [int]($w / 2)))
        $e.Graphics.FillPath($br, $gp)
        $gp.Dispose()
        $br.Dispose()
      })
    $sbar.Add_MouseEnter({ Set-AnimTarget $script:Anim 'Sb' 1.0; $script:SbHot = $true })
    $sbar.Add_MouseLeave({ Set-AnimTarget $script:Anim 'Sb' 0.0; $script:SbHot = $false })
    $sbar.Add_MouseDown({
        param($s, $e)
        if ($script:SbLen -le 0) { return }
        if ($e.Y -ge $script:SbTop -and $e.Y -le ($script:SbTop + $script:SbLen)) {
          $script:SbDrag = $e.Y - $script:SbTop
        } else {
          $script:SbDrag = [int]($script:SbLen / 2)
          Sb-ScrollTo ($e.Y - $script:SbDrag)
        }
        $sbar.Capture = $true
        $sbar.Invalidate()
      })
    $sbar.Add_MouseMove({
        param($s, $e)
        if ($script:SbDrag -lt 0) { return }
        Sb-ScrollTo ($e.Y - $script:SbDrag)
      })
    $sbar.Add_MouseUp({
        $script:SbDrag = -1
        $sbar.Capture = $false
        $sbar.Invalidate()
      })
    $form.Add_Resize({
        if ($form.WindowState -ne [Windows.Forms.FormWindowState]::Normal) { return }
        Update-PanelRegion $form
        Layout-Chrome
        Size-List
        Sync-Sb
        $lst.Invalidate()
      })
    $sbar.Add_SizeChanged({ Sync-Sb })
    $listHost.Add_Resize({ Size-List; Sync-Sb })

    function Update-List([string]$q) {
      $lst.BeginUpdate()
      try {
        # compiled in lib/query.ps1; highlight still works on plain words only
        $query = New-Query -Line $q
        $tokens = @($query.Terms)
        $script:Tokens = $tokens
        # sticky pins: the plugin names the mark and the cap, the base decides how many rows
        # actually fit - see Get-StickyPlan / Get-StickyTopRows in lib/layout.ps1
        $plan = $null
        if (Get-Command Get-PluginStickyPlan -ErrorAction SilentlyContinue) { $plan = Get-PluginStickyPlan (Get-Rows) }
        if ($null -eq $plan) { $plan = @{ Mark = ''; Max = 0 } }
        $rows = @(Invoke-Query $script:Entries $query)
        # the pins sort first, so the run of sticky rows at the top is what gets frozen
        $script:StickyTop = Get-StickyTopRows $rows $plan.Mark $plan.Max
        $res = New-Object System.Collections.Generic.List[object]
        $labs = New-Object System.Collections.Generic.List[string]
        $mk = $(if ($script:ShowNewlineMarker) { 1 } else { 0 })
        foreach ($rec in $rows) {
          $res.Add($rec)
          $lkey = ([int]$rec.Key * 2) + $mk
          $lab = $labelCache[$lkey]
          if ($null -eq $lab) {
            $lab = Get-RecordLabel $rec $script:ShowNewlineMarker
            if ($labelCache.Count -gt 1200) { $labelCache.Clear() }
            $labelCache[$lkey] = $lab
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
      Hide-Preview $pv
      $script:PvIdx = -1
      Sync-Placeholder
      $lst.Invalidate()
      Sync-Sb
      Restore-Foot
    }

    # The picker already put the text on the clipboard: hide it and paste into the window
    # that was in front. Shared by Enter and by a plugin action that asks for
    # After = 'paste' (transform copies the rewritten text, then wants it pasted).
    function Paste-Clip {
      $target = $prev
      # the hook would eat the injected Ctrl+V, so it goes first in every path
      Disable-KeyHook
      if ($script:NoPaste) { $form.Hide(); $form.Close(); return }
      # the hotkey is usually still held when the panel opens: pasting now would send
      # Ctrl+V with Alt/Ctrl down and land as something else entirely
      $sw = [Diagnostics.Stopwatch]::StartNew()
      while ($sw.ElapsedMilliseconds -lt $script:ModReleaseTimeout) {
        if (Test-Modifiers-Up) { break }
        Start-Sleep -Milliseconds 30
      }
      # SetForegroundWindow can be refused by the foreground lock and SendKeys types into
      # whatever is in front, so hand over and verify before typing.
      $ready = $false
      for ($try = 0; $try -lt 24 -and -not $ready; $try++) {
        [void][Cb.Win]::SetForegroundWindow($target)
        Start-Sleep -Milliseconds 25
        if ([Cb.Win]::GetForegroundWindow() -eq $target) { $ready = $true }
      }
      if (-not $ready) {
        Write-Log 'paste skipped: the target window did not take the foreground'
        Set-Foot 'Copied to the clipboard. The window did not come back to the front - press Ctrl+V there' ([int]$script:Timing['FootMessage'])
        return
      }
      $form.Hide()
      Start-Sleep -Milliseconds $script:PasteSettle
      try { [Windows.Forms.SendKeys]::SendWait($PasteKeys) } catch { Write-Log ('sendkeys fail: ' + $_.Exception.Message) }
      $form.Close()
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
      if ($script:NoPaste -or $NoInject.IsPresent -or (Test-AppRuleNoPaste)) { $form.Hide(); [void](Set-ClipItem $payload $rich); Set-LastCapture $payload; $form.Close(); return }
      # the program in front decides whether the formatting travels with the paste:
      # a terminal wants the text, an editor wants the layout
      if ($rich -and -not (Test-AppRuleKeepsRich)) { $rich = '' }
      if (-not (Set-ClipItem $payload $rich)) { Write-Log 'set clipboard failed'; $form.Close(); return }
      # our own write must not come back as a new capture
      Set-LastCapture $payload
      Paste-Clip
    }

    function Del-Index([int]$idx) {
      if ($idx -lt 0 -or $idx -ge $script:Filtered.Count) { return }
      $victim = $script:Filtered[$idx]
      $removed = Remove-Record $victim.Payload
      if ($removed -like 'protected:*') {
        # only the plugin that declared the mark knows how to remove it
        $pm = $removed.Substring(10)
        $info = Get-MarkInfo $pm
        $word = Get-MarkWord $pm
        $word = $word.Substring(0, 1).ToUpper() + $word.Substring(1)
        if ($info -and $info.Unset) {
          if ($info.Hint) { Set-Foot ($word + ' entry. Press ' + $info.Hint + ' to ' + $info.Unset + ' it first') ([int]$script:Timing['FootWarn']) }
          else { Set-Foot ($word + ' entry. ' + $info.Unset + ' it first, then delete') ([int]$script:Timing['FootWarn']) }
        } else {
          Set-Foot ($word + ' entry. Load the plugin that owns the ' + $pm + ' mark first') ([int]$script:Timing['FootWarn'])
        }
        return
      }
      if ($removed -eq 'removed') {
        if ($script:UndoOn) { $script:UndoRec = $victim; $script:UndoIdx = $idx }
      }
      $script:Entries = @(Get-Records)
      if ($removed -eq 'removed') { Write-Log ('deleted entry (' + $victim.Payload.Length + ' chars), left ' + $script:Entries.Count) }
      Update-List $txt.Text
      if ($script:Filtered.Count -gt 0) { $lst.SelectedIndex = [Math]::Min($idx, $script:Filtered.Count - 1) }
      if ($script:UndoOn -and $removed -eq 'removed') { Set-Foot 'Deleted. Press Ctrl+Z to undo' ([int]$script:Timing['FootMessage']) }
    }

    function Undo-Delete {
      if (-not $script:UndoOn) { Set-Foot 'Undo is off. Set Undo=1 in clipboard.ini to enable it' ([int]$script:Timing['FootWarn']); return }
      if ($null -eq $script:UndoRec) { Set-Foot 'Nothing to undo' ([int]$script:Timing['FootShort']); return }
      $rec = $script:UndoRec
      $at = $script:UndoIdx
      $script:UndoRec = $null
      Restore-Record $rec $at
      $script:Entries = @(Get-Records)
      Update-List $txt.Text
      Set-Foot 'Restored to its original position' ([int]$script:Timing['FootInfo'])
    }

    function Cancel-Confirm {
      $confirmTimer.Stop()
      if (-not $script:Confirm) { return }
      $script:Confirm = $false
      Restore-Foot
    }

    function Request-Clear {
      if ($script:Entries.Count -eq 0) { Set-Foot 'Nothing to clear' ([int]$script:Timing['FootShort']); return }
      $script:Confirm = $true
      $footTimer.Stop()
      $script:FootMode = 'confirm'
      if (@(Get-ClearKeepMarks).Count -gt 0) { $script:FootMsg = 'Delete the entries no mark keeps?   Enter to confirm, Esc to cancel' }
      else { $script:FootMsg = 'Delete the entire history?   Enter to confirm, Esc to cancel' }
      $footL.Invalidate()
      $confirmTimer.Stop()
      $confirmTimer.Start()
    }

    function Clear-All {
      $script:Confirm = $false
      $confirmTimer.Stop()
      Clear-Store (Get-ClearKeepMarks)
      $script:Entries = @(Get-Records)
      Update-List $txt.Text
      $kept = @(Get-MarkCountWords $script:Entries)
      if ($kept.Count -gt 0) { Set-Foot ('History cleared, ' + ($kept -join ', ') + ' kept') ([int]$script:Timing['FootWarn']) }
      else { Set-Foot 'History cleared' ([int]$script:Timing['FootInfo']) }
    }

    $cm = New-Object Windows.Forms.ContextMenuStrip
    $cm.Font = $fBody
    $cm.ShowImageMargin = $false
    # The popup must not take the foreground: that deactivates the window the user came from,
    # and Explorer's address bar / search box collapse - the paste then lands in the file view.
    [void]$cm.Handle
    [void][Cb.Win]::SetWindowLong($cm.Handle, -20, ([Cb.Win]::GetWindowLong($cm.Handle, -20) -bor 0x08000000))
    # Without visual styles the default renderer paints separators invisibly; the
    # professional renderer draws real divider lines between the plugin groups.
    try { $cm.Renderer = New-Object Windows.Forms.ToolStripProfessionalRenderer } catch { }
    # a group header is a grey, non-clickable line naming the plugin that owns the items
    $groupFont = $null
    try { $groupFont = New-Object Drawing.Font($fBody.FontFamily, [Math]::Max(7, $fBody.Size - 1)) } catch { $groupFont = $null }
    $m1 = $cm.Items.Add('Paste'); $m1.ShortcutKeyDisplayString = 'Enter'
    $m1.Add_Click({ Use-Index $lst.SelectedIndex })
    $m2 = $cm.Items.Add('Copy only'); $m2.ShortcutKeyDisplayString = 'Ctrl+Enter'
    $m2.Add_Click({ Use-Index $lst.SelectedIndex -NoInject })
    $m5 = $cm.Items.Add('Delete'); $m5.ShortcutKeyDisplayString = 'Del'
    $m5.Add_Click({ try { Del-Index $lst.SelectedIndex } catch { } })
    [void]$cm.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $m6 = $cm.Items.Add('Clear history')
    $m6.Add_Click({ Request-Clear })

    # plugin actions: appended after the built-in ones, hidden unless their Test passes. Items
    # stay grouped per plugin: a header names it and a separator closes the previous group.
    $pluginItems = New-Object System.Collections.Generic.List[object]
    $groupHeads = New-Object System.Collections.Generic.List[object]
    try {
      if (Get-Command Get-PluginActions -ErrorAction SilentlyContinue) {
        $actions = @(Get-PluginActions)
        if ($actions.Count -gt 0) {
          [void]$cm.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
          $lastOwner = ''
          foreach ($act in $actions) {
            $owner = [string]$act['Plugin']
            if ($owner -ne $lastOwner) {
              if ($lastOwner) { [void]$cm.Items.Add((New-Object Windows.Forms.ToolStripSeparator)) }
              $head = $cm.Items.Add($owner)
              $head.Enabled = $false
              if ($null -ne $groupFont) { $head.Font = $groupFont }
              $groupHeads.Add(@{ Item = $head; Owner = $owner; Index = ($cm.Items.Count - 1) })
              $lastOwner = $owner
            }
            $item = $cm.Items.Add((Get-ActionText $act $null))
            if ($act.ContainsKey('Key')) { $item.ShortcutKeyDisplayString = [string]$act['Key'] }
            $item.Tag = $act
            $item.Add_Click([System.EventHandler]{
                param($sn, $ev)
                try {
                  $a = $sn.Tag
                  if ($null -eq $a -or $lst.SelectedIndex -lt 0) { return }
                  if ($lst.SelectedIndex -ge $script:Filtered.Count) { return }
                  # a returned string is a note for the footer (a refused pin, for one)
                  $note = (& $a['Invoke'] $script:Filtered[$lst.SelectedIndex]); if ($note) { Set-Foot ([string]$note) ([int]$script:Timing['FootMessage']) }
                  $script:Entries = @(Get-Records)
                  # After = 'paste': the action put its result on the clipboard and wants
                  # it pasted into the window the picker came from (transform does this)
                  if ($a.ContainsKey('After') -and [string]$a['After'] -eq 'paste') { Paste-Clip }
                  else { Update-List $txt.Text }
                } catch { Write-Log ('plugin action failed: ' + $_.Exception.Message) }
              })
            $pluginItems.Add(@{ Item = $item; Owner = $owner; Index = ($cm.Items.Count - 1) })
          }
        }
      }
    } catch { Write-Log ('plugin menu failed: ' + $_.Exception.Message) }

    # right click acts on the row under the cursor, never on a stale selection
    $cm.Add_Opening({
        try {
          $pt = $lst.PointToClient([Windows.Forms.Cursor]::Position)
          $i = $lst.IndexFromPoint($pt)
          if ($i -ge 0 -and $i -lt $script:Filtered.Count) { $lst.SelectedIndex = $i } else { $lst.SelectedIndex = -1 }
          $has = ($lst.SelectedIndex -ge 0 -and $lst.SelectedIndex -lt $script:Filtered.Count)
          $m1.Enabled = $has
          $m2.Enabled = $has
          $m5.Enabled = $has
          $m6.Enabled = ($script:Entries.Count -gt 0)
          $cur = $null
          if ($has) { $cur = $script:Filtered[$lst.SelectedIndex] }
          # A drop-down that is still opening reports Visible=false for every item, so the
          # layout is tracked here and applied afterwards instead of read back.
          $keep = [bool[]]::new($cm.Items.Count)
          for ($k = 0; $k -lt $keep.Length; $k++) {
            $keep[$k] = ($cm.Items[$k] -isnot [Windows.Forms.ToolStripSeparator])
          }
          $ownerShown = @{}
          foreach ($slot in $pluginItems) {
            $it = $slot.Item
            $show = $false
            if ($null -ne $cur -and (Get-Command Test-PluginAction -ErrorAction SilentlyContinue)) {
              $show = Test-PluginAction $it.Tag $cur
            }
            $it.Visible = $show
            $it.Enabled = $show
            $keep[$slot.Index] = $show
            if ($show) {
              # a plugin may compute its label per row: 'Pin to top' / 'Remove pin'
              $it.Text = Get-ActionText $it.Tag $cur
              $ownerShown[[string]$slot.Owner] = $true
            }
          }
          # a header follows its group: when every item of a plugin is hidden the name goes
          # away with them, and the separators around it collapse
          foreach ($h in $groupHeads) {
            $any = $ownerShown.ContainsKey([string]$h.Owner)
            $h.Item.Visible = $any
            $keep[$h.Index] = $any
          }
          # a separator needs an item on both sides and never sits back to back, or hiding
          # every action of a plugin leaves an empty band between the neighbouring groups
          $prevSep = $false
          for ($k = 0; $k -lt $cm.Items.Count; $k++) {
            $it = $cm.Items[$k]
            if ($it -isnot [Windows.Forms.ToolStripSeparator]) {
              if ($keep[$k]) { $prevSep = $false }
              continue
            }
            $before = $false
            for ($j = 0; $j -lt $k; $j++) { if ($keep[$j]) { $before = $true; break } }
            $after = $false
            for ($j = $k + 1; $j -lt $keep.Length; $j++) { if ($keep[$j]) { $after = $true; break } }
            $show = ($before -and $after -and -not $prevSep)
            $it.Visible = $show
            if ($show) { $prevSep = $true }
          }
        } catch { }
      })
    $lst.ContextMenuStrip = $cm
    # Picking an item is a left click outside the panel: remember when the menu closed so
    # the loop below does not dismiss the panel on the very click that chose the item.
    $cm.Add_Closed({ $script:MenuClosedAt = Get-Date })

    # one StringFormat set per process, shared with the drawing helpers in lib/picker-draw.ps1
    $sfSet = New-PickerStringFormats
    $bgBrush = New-Object Drawing.SolidBrush $ui.Surface
    # One brush per colour now lives in lib/picker-draw.ps1: it outlives the panel, so
    # reopening does not have to build the palette again.
    $sfEll = $sfSet.Ellipsis
    $sfNone = $sfSet.None
    $sfRight = $sfSet.Right
    $sfCenter = $sfSet.Center
    $sfSeg = $sfSet.Seg
    # the hover card (lib/preview.ps1): geometry and brushes once per panel, never per hover
    $pvCfg = New-PreviewConfig $ui $sfNone $fBody $fSmall

    # draw one label in pieces so the matched tokens can be tinted; the tail is trimmed
    # with an ellipsis once the available width is exhausted (lib/picker-draw.ps1)

    $lst.Add_DrawItem({
        param($s, $e)
        if ($lst.IsDisposed) { return }
        if ($e.Index -lt 0) { return }
        # fill by hand: DrawBackground would paint the selected row a solid system highlight
        $g = $e.Graphics
        $g.FillRectangle($bgBrush, $e.Bounds)
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $b = $e.Bounds
        $m = $script:Metric
        $rowW = [Math]::Min($b.Width, $listHost.ClientSize.Width) - (Px $m['RowRight'])
        if ($rowW -lt (Px $m['RowMinWidth'])) { $rowW = Px $m['RowMinWidth'] }
        $r = New-Object Drawing.Rectangle -ArgumentList @(($b.X + (Px $m['RowInset'])), ($b.Y + (Px $m['RowGap'])), $rowW, ($b.Height - (Px (2 * $m['RowGap']))))
        $sel = ((($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0) -or $lst.IsMulti($e.Index))
        $isData = ($e.Index -lt $script:Filtered.Count)
        $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        # decoration / glyph / byte size are cached per entry: DrawItem runs on every hover
        $rec = $null
        $row = $null
        $decor = $null
        if ($isData) {
          $rec = $script:Filtered[$e.Index]
          # keyed by the record's number; a mark change is caught by the Marks check below
          $row = $rowCache[[int]$rec.Key]
          if ($null -eq $row -or $row.Marks -cne [string]$rec.Marks) {
            $dec = $null
            if (Get-Command Get-PluginRowDecor -ErrorAction SilentlyContinue) {
              try { $dec = Get-PluginRowDecor $rec } catch { $dec = $null }
            }
            $glyph = ''
            if ($dec -and $dec.Glyph) { $glyph = [string]$dec.Glyph } else { $glyph = Get-RowGlyph $rec.Payload }
            $bytes = 0
            try { $bytes = $Utf8.GetByteCount($rec.Payload) } catch { }
            $row = @{ Decor = $dec; Glyph = $glyph; Bytes = $bytes; Marks = [string]$rec.Marks }
            if ($rowCache.Count -gt 1200) { $rowCache.Clear() }
            $rowCache[[int]$rec.Key] = $row
          }
          $decor = $row.Decor
        }
        if ($null -eq $script:Anim) { $script:Anim = New-AnimState }
        $tint = $null
        if ($decor -and $decor.BackColor -and (Get-Command Get-UiColor -ErrorAction SilentlyContinue)) { $tint = Get-UiColor $decor.BackColor }
        $selK = $(if ($sel) { 1.0 } else { 0.0 })
        $hovK = 0.0
        if ($e.Index -eq $script:Anim.HoverIndex) { $hovK = [double]$script:Anim.Hover }
        try { Draw-RowBackdrop $g $r.X $r.Y $r.Width $r.Height (Px $m['RowRadius']) $tint $ui.SelBg $ui.HoverBg $selK $hovK } catch { Write-Log ('row backdrop failed: ' + $_.Exception.Message) }
        $label = [string]$script:Labels[$e.Index]
        if (-not $isData) {
          $rr = New-Object Drawing.RectangleF -ArgumentList @([single]($r.X + (Px $m['IconX'])), [single]$r.Y, [single]($r.Width - (Px (2 * $m['IconX']))), [single]$r.Height)
          $g.DrawString($label, $fBody, (Get-Brush $ui.Faint), $rr, $sfEll)
          return
        }

        # Trailing meta columns, right to left: key cap, time, two mark slots. Every width
        # comes from $script:Metric, so a theme can restyle the row.
        $capW = Px $m['CapWidth']
        $capH = Px $m['CapHeight']
        $capX = $r.Right - (Px $m['CapGap']) - $capW
        $capY = $r.Y + [int](($r.Height - $capH) / 2)
        $timeW = Px $m['TimeWidth']
        $timeX = $capX - (Px $m['TimeGap']) - $timeW
        $markR = $timeX - (Px $m['MarkGap']) - (Px $m['MarkSlot'])
        $markL = $markR - (Px $m['MarkGap2']) - (Px $m['MarkSlot'])
        $offset = $e.Index - $lst.TopIndex
        $showCap = ($offset -ge 0 -and $offset -le 9 -and $offset -lt (Get-Rows) -and -not $script:Confirm)

        if ($script:ShowTime) {
          $timeRect = New-Object Drawing.RectangleF -ArgumentList @([single]$timeX, [single]$r.Y, [single]$timeW, [single]$r.Height)
          $g.DrawString((Get-RelTime $rec.Time), $fSmall, (Get-Brush $ui.Faint), $timeRect, $sfRight)
        }
        # marks are pure decoration handed over by a plugin: fixed slots, right to left,
        # so a row with two marks never shifts the time column
        if ($decor -and $decor.Marks) {
          $slots = @($markR, $markL)
          $marks = @($decor.Marks)
          $n = [Math]::Min($marks.Count, $slots.Count)
          for ($mi = 0; $mi -lt $n; $mi++) {
            $mk = $marks[$mi]
            if (-not $mk -or -not $mk.Glyph) { continue }
            $mkColor = $ui.Mark
            if ($mk.Color -and (Get-Command Get-UiColor -ErrorAction SilentlyContinue)) {
              $mcc = Get-UiColor ([string]$mk.Color)
              if ($null -ne $mcc) { $mkColor = $mcc }
            }
            $mkBrush = Get-Brush $mkColor
            $mkRect = New-Object Drawing.RectangleF -ArgumentList @([single]$slots[$mi], [single]$r.Y, [single](Px $m['MarkGlyphWidth']), [single]$r.Height)
            $g.DrawString([string]$mk.Glyph, $fIconSmall, $mkBrush, $mkRect, $sfCenter)
          }
        }

        $textX = $r.X + (Px $m['TextInset'])
        # the icon is drawn only when a plugin supplied one; without a typing plugin the
        # row starts at the text and nothing is reserved for an icon
        $rowGlyph = [string]$row.Glyph
        # a picture row shows itself in the slot; the bitmap belongs to the media cache
        $side = Px ($m['TextGap'] - $m['IconX'])
        $thumb = $null
        if ($script:ShowThumbnails) { try { $thumb = Get-RowThumbBitmap $rec $side } catch { $thumb = $null } }
        if ($null -ne $thumb -and (Draw-RowThumb $g $thumb ($r.X + (Px $m['IconX'])) ($r.Y + [int](($r.Height - $side) / 2)) $side)) {
          $textX = $r.X + (Px $m['TextGap'])
        } elseif ($script:ShowTypeIcon -and $script:IconFamily -and $rowGlyph) {
          $glyphColor = $(if ($sel) { $ui.Text } else { $ui.Dim })
          if ($decor -and $decor.GlyphColor -and (Get-Command Get-UiColor -ErrorAction SilentlyContinue)) {
            $gcc = Get-UiColor $decor.GlyphColor
            if ($null -ne $gcc) { $glyphColor = $gcc }
          }
          $glyphBrush = Get-Brush $glyphColor
          $glyphRect = New-Object Drawing.RectangleF -ArgumentList @([single]($r.X + (Px $m['IconX'])), [single]$r.Y, [single](Px $m['IconSlot']), [single]$r.Height)
          $g.DrawString($rowGlyph, $fIcon, $glyphBrush, $glyphRect, $sfCenter)
          $textX = $r.X + (Px $m['TextGap'])
        }

        $textW = $markL - (Px $m['TextMarkGap']) - $textX
        if ($textW -lt (Px $m['TextMinWidth'])) { $textW = Px $m['TextMinWidth'] }
        $tr = New-Object Drawing.RectangleF -ArgumentList @([single]$textX, [single]$r.Y, [single]$textW, [single]$r.Height)

        if ($sel) {
          # selection indicator only: a short accent pill on the leading edge. It marks the
          # row the keys act on and never doubles as an entry highlight.
          $barBrush = Get-Brush $ui.Accent
          $barPath = New-RoundPath ($r.X + (Px $m['SelBarX'])) ($r.Y + (Px $m['SelBarInset'])) (Px $m['SelBarWidth']) ($r.Height - (Px (2 * $m['SelBarInset']))) (Px $m['SelBarRadius'])
          $g.FillPath($barBrush, $barPath)
          $barPath.Dispose()
        }

        # highlight ink: a plugin sets the text colour, the row keeps its own background
        $ink = $ui.Text
        if ($decor -and $decor.TextColor -and (Get-Command Get-UiColor -ErrorAction SilentlyContinue)) {
          $tcc = Get-UiColor $decor.TextColor
          if ($null -ne $tcc) { $ink = $tcc }
        }
        $tb = Get-Brush $ink
        $hb = Get-Brush $ui.Accent
        $hi = $script:HighlightOn -and $script:Tokens.Count -gt 0 -and ($label.Length -le 400)
        if ($hi -and $script:HighlightMax -gt 0) {
          if ([int]$row.Bytes -gt $script:HighlightMax) { $hi = $false }
        }
        if ($hi) { Draw-Highlight $g $label $tr $script:Tokens $tb $hb }
        else { $g.DrawString($label, $fBody, $tb, $tr, $sfEll) }

        if ($showCap) {
          # a key cap, not a data badge: neutral by default, accent while Ctrl is held
          $capFill = $ui.KeyCapBg
          $capStroke = $ui.KeyCapBorder
          $capInk = $ui.BadgeText
          if ($script:CtrlHeld) { $capFill = $ui.AccentSoft; $capStroke = $ui.Accent; $capInk = $ui.Accent }
          $capPath = New-RoundPath $capX $capY $capW $capH (Px $m['CapRadius'])
          $g.FillPath((Get-Brush $capFill), $capPath)
          $capPen = New-Object Drawing.Pen $capStroke, 1
          $g.DrawPath($capPen, $capPath)
          $capPen.Dispose()
          $capPath.Dispose()
          $capRect = New-Object Drawing.RectangleF -ArgumentList @([single]$capX, [single]$capY, [single]$capW, [single]$capH)
          $g.DrawString(('Ctrl+' + (Get-QuickKeyLabel $offset)), $fSmall, (Get-Brush $capInk), $capRect, $sfCenter)
        }
      })
    # Hover preview (lib/preview.ps1): it waits for the cursor to rest and prepares a record's
    # text once, so sweeping the list costs a timestamp per row and nothing else.
    $pv = New-PreviewState
    $script:PvAt = Get-Date; $script:PvIdx = -1
    function Show-HoverPreview {
      if ($null -eq $pv -or $script:Hover -lt 0 -or $script:Hover -ge $script:Filtered.Count) { Hide-Preview $pv; $script:PvIdx = -1; return }
      $pvCfg.Area = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
      $at = $lst.PointToScreen($lst.GetItemRectangle($script:Hover).Location)
      Update-Preview $pv $script:Filtered[$script:Hover] $at.Y $pvCfg $form.Bounds
      $script:PvIdx = $script:Hover
    }
    $lst.Add_SelectedIndexChanged({ if (-not $lst.IsDisposed) { Set-AnimSelection $script:Anim $lst.SelectedIndex } })
    $lst.Add_MouseMove({
        param($s, $e)
        if ($lst.IsDisposed) { return }
        $i = $lst.IndexFromPoint($e.Location)
        if ($i -ne $script:Hover) {
          $old = $script:Hover
          $script:Hover = $i
          Set-AnimHover $script:Anim $i
          # a new row restarts the rest timer and drops the card of the old one at once
          $script:PvAt = Get-Date
          $script:PvIdx = -1
          Hide-Preview $pv
          foreach ($k in @($old, $i)) {
            if ($k -ge 0 -and $k -lt $lst.ItemCount) { $lst.Invalidate($lst.GetItemRectangle($k)) }
          }
        }
      })
    $lst.Add_MouseLeave({
        if ($lst.IsDisposed) { $script:Hover = -1; return }
        Set-AnimHover $script:Anim -1
        $script:Hover = -1
        $script:PvIdx = -1
        Hide-Preview $pv
      })
    $lst.Add_DoubleClick({ if ($lst.SelectedIndex -ge 0) { Use-Index $lst.SelectedIndex } })
    # Ctrl toggles a row, Shift takes a run, a plain click starts over - the rules live in
    # lib/select.ps1 so they can be tested without a window
    $lst.Add_RowClicked({ param($sn, $ev) Update-Selection $script:Sel $lst ([int]$lst.ClickRow) ([bool]$lst.ClickHadControl) ([bool]$lst.ClickHadShift) })
    $lst.Add_MouseUp({ param($s, $e) if ($e.Button -eq 'Left') { Sync-Sb; Focus-Search } })

    $footTimer = New-Object Windows.Forms.Timer
    $footTimer.Interval = [int]$script:Timing['FootMessage']
    $footTimer.Add_Tick({ $footTimer.Stop(); Restore-Foot })

    $confirmTimer = New-Object Windows.Forms.Timer
    $confirmTimer.Interval = [int]$script:Timing['Confirm']
    $confirmTimer.Add_Tick({ $confirmTimer.Stop(); $script:Confirm = $false; Restore-Foot })

    $deb = New-Object Windows.Forms.Timer
    $deb.Interval = [int]$script:Timing['Debounce']
    $deb.Add_Tick({ $deb.Stop(); Update-List $txt.Text })
    # F2 edits the selected entry in place; the editor lives in lib/picker-edit.ps1
    Set-PickerEditHost $form $lst $txt $ui $fBody { param($q) Update-List $q } { param($m) Set-Foot $m ([int]$script:Timing['FootInfo']) }
    function Flush-List { if ($deb.Enabled) { $deb.Stop(); Update-List $txt.Text } }
    $txt.Add_TextChanged({ Sync-Placeholder; $deb.Stop(); $deb.Start() })
    $txt.Add_GotFocus({ $script:SearchFocus = $true; Set-AnimTarget $script:Anim 'Field' 1.0 })
    $txt.Add_LostFocus({ $script:SearchFocus = $false; Set-AnimTarget $script:Anim 'Field' 0.0 })
    $clr.Add_Click({ $txt.Text = ''; Focus-Search })
    $form.Add_KeyDown({
        param($s, $e)
        $code = [int]$e.KeyCode
        if ($e.Control -and -not $script:CtrlHeld) {
          $script:CtrlHeld = $true
          $lst.Invalidate()
          $footL.Invalidate()
        }
        if ($script:Confirm) {
          if ($e.KeyCode -eq 'Enter') { Clear-All } else { Cancel-Confirm }
          $e.Handled = $true; $e.SuppressKeyPress = $true
          return
        }
        if ($e.Control -and $e.KeyCode -eq 'A') {
          Select-AllRows $script:Sel $lst $script:Filtered.Count
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.Control -and $e.KeyCode -eq 'Enter') {
          Flush-List
          # a batch is copied as one text block; a single row keeps the original behaviour
          $batch = $(if ((Get-SelectionCount $script:Sel) -gt 1) { Invoke-SelectionCopy $script:Sel $script:Filtered } else { $null })
          if ($null -ne $batch) { Clear-Selection $script:Sel; Sync-Selection $script:Sel $lst; Set-Foot $batch.Note ([int]$script:Timing['FootInfo']) }
          elseif ($lst.SelectedIndex -ge 0) { Use-Index $lst.SelectedIndex -NoInject } else { Set-Foot 'Nothing to copy' ([int]$script:Timing['FootShort']) }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.Control -and (($code -ge 48 -and $code -le 57) -or ($code -ge 96 -and $code -le 105))) {
          $n = $code
          if ($n -ge 96) { $n = $n - 96 } else { $n = $n - 48 }
          Flush-List
          $idx = Get-QuickKeyIndex (Get-QuickKeyOffset $n) $lst.TopIndex $script:Filtered.Count (Get-Rows)
          if ($idx -ge 0) { Use-Index $idx } else { Set-Foot 'No entry at that number' ([int]$script:Timing['FootBrief']) }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.Control -and $e.KeyCode -eq 'Z') {
          try { Undo-Delete } catch { Write-Log ('undo failed: ' + $_.Exception.Message) }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($pluginKey = Find-PanelKey ([string]$e.KeyCode) $e.Control $e.Alt $e.Shift) {
          # a key a plugin claimed (PanelKeys): run it on the selected record, then refresh
          Flush-List
          $idx = $lst.SelectedIndex
          if ($idx -ge 0 -and $idx -lt $script:Filtered.Count) {
            $rec = $script:Filtered[$idx]
            $go = $true
            if ($pluginKey.Test) { try { $go = [bool](& $pluginKey.Test $rec) } catch { $go = $false } }
            if ($go) {
              $note = $null
              try { $note = & $pluginKey.Invoke $rec } catch { Write-Log ('plugin key failed: ' + $pluginKey.Plugin + ' - ' + $_.Exception.Message) }
              if ($note) { Set-Foot ([string]$note) ([int]$script:Timing['FootMessage']) }
              $script:Entries = @(Get-Records)
              Update-List $txt.Text
            }
          }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Home') {
          if ($lst.ItemCount -gt 0) { $lst.SelectedIndex = 0 }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'End') {
          if ($lst.ItemCount -gt 0) { $lst.SelectedIndex = $lst.ItemCount - 1 }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'PageDown') {
          Scroll-By (Get-Rows)
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'PageUp') {
          Scroll-By (-(Get-Rows))
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Up') {
          if ($lst.SelectedIndex -gt 0) { $lst.SelectedIndex-- }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Down') {
          if ($lst.SelectedIndex -lt $lst.ItemCount - 1) { $lst.SelectedIndex++ }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Enter') {
          Flush-List
          if ($lst.SelectedIndex -ge 0) { Use-Index $lst.SelectedIndex } else { Set-Foot 'Nothing to paste' ([int]$script:Timing['FootShort']) }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Escape') {
          if ($txt.Text.Length -gt 0) {
            $txt.Text = ''
            Flush-List
          } else {
            $form.Close()
          }
        } elseif ($e.KeyCode -eq 'Delete') {
          Flush-List
          if ((Get-SelectionCount $script:Sel) -gt 1) {
            # one write for the whole set, then the list rebuilds from the store
            $note = Invoke-SelectionDelete $script:Sel $script:Filtered
            Sync-Selection $script:Sel $lst
            $script:Entries = @(Get-Records)
            Update-List $txt.Text
            if ($note) { Set-Foot $note ([int]$script:Timing['FootInfo']) }
          } else { try { Del-Index $lst.SelectedIndex } catch { Write-Log ('delete failed: ' + $_.Exception.Message) } }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        }
      })
    $form.Add_KeyUp({
        param($s, $e)
        $held = [bool]$e.Control
        if ($e.KeyCode -eq [Windows.Forms.Keys]::ControlKey -or $e.KeyCode -eq [Windows.Forms.Keys]::RControlKey) { $held = $false }
        if ($held -ne $script:CtrlHeld) {
          $script:CtrlHeld = $held
          $lst.Invalidate()
          $footL.Invalidate()
        }
      })
    # ---- input plumbing for the hook model ------------------------------------
    # Under the hook the panel never activates, so the box must not take the real focus
    # either: keys are posted to the controls, keeping every handler working.
    function Focus-Search {
      if (-not $script:PickerHook) { $txt.Focus() }
    }

    function Invoke-HookedKey {
      $keys = @(Get-HookedKeys)
      if ($keys.Count -eq 0) { return }
      $claimed = Test-KeyHookEscalate   # true when the input method claimed a key
      for ($i = 0; $i -lt $keys.Count; $i++) {
        $vk = $keys[$i]
        $ch = Get-HookedChar $vk
        $mod = [Windows.Forms.Control]::ModifierKeys
        $plain = ($mod -band ([Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::Alt)) -eq 0
        # an input method needs a real focus: hand over and replay the key so it composes there
        if ($plain -and ($claimed -or ($script:ImeNative -and $vk -ge 0x30 -and $vk -le 0x5A))) {
          if (Switch-ToTakeover $form.Handle $txt) {
            $script:PickerHook = $false
            $script:PickerEscalated = $true
            Write-Log 'picker: handing the keyboard over for the input method'
            Send-HookedKeys $keys $i
          } else {
            Restore-KeyHook $form.Handle
          }
          return
        }
        # text (and Backspace, WM_CHAR 0x08) goes to the box; Esc/Enter/Tab are control chars
        $isText = $ch -ne [char]0 -and (-not [char]::IsControl($ch) -or $ch -eq [char]8)
        # Esc closes the panel, so the handle is read once and the delivery is guarded
        try {
          $tg = $(if ($null -ne $script:HookTargetBox) { $script:HookTargetBox } else { $txt })
          if ($isText -and $plain) { [void][Cb.Win]::SendMessage($tg.Handle, 0x0102, [IntPtr][int]$ch, [IntPtr]1) }
          else {
            $wh = $tg.Handle
            [void][Cb.Win]::SendMessage($wh, 0x0100, [IntPtr]$vk, [IntPtr]1); [void][Cb.Win]::SendMessage($wh, 0x0101, [IntPtr]$vk, [IntPtr]1)
          }
        } catch { return }
      }
    }

    $ph.Add_Click({ Focus-Search })

    $form.Add_Paint({
        param($s, $e)
        $e.Graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pen = New-Object Drawing.Pen $ui.Border
        $gp = New-RoundPath 0 0 ($form.ClientSize.Width - 1) ($form.ClientSize.Height - 1) (Px 8)
        $e.Graphics.DrawPath($pen, $gp)
        $gp.Dispose()
        $pen.Dispose()
      })
    $form.Add_Shown({
        Update-PanelRegion $form
        Layout-Chrome
        Size-List
        Sync-Sb
        Update-List ''
        # the box looks focused (accent underline) but only takes the real focus without a hook
        Focus-Search
        $script:SearchFocus = $true
        Set-AnimTarget $script:Anim 'Field' 1.0
        $box.Invalidate()
        Write-Log ('picker: shown ' + $script:Theme + '/' + $script:UiFamily + ' items=' + $script:Entries.Count + ' scale=' + $script:UiScale + ' size=' + $form.Width + 'x' + $form.Height + ' at ' + $form.Left + ',' + $form.Top + ' hook=' + $script:PickerHook)
      })

    $script:ShownAt = Get-Date
    # Close() disposes a non-modal form, so the geometry has to be read while it is still
    # alive - the window-size save below happens after the loop and would otherwise throw
    $script:PickerGeo = $null
    $form.Add_FormClosing({
        # a drop-down left standing keeps its menu filter, which then eats every later click
        try { if (-not $cm.IsDisposed -and $cm.Visible) { $cm.Close() } } catch { Write-Log ('menu close failed: ' + $_.Exception.Message) }
        # Close() can arrive again after Dispose() (Hide then Close, plus the deactivate timer)
        if ($form.IsDisposed) { return }
        $script:PickerGeo = @{ W = $form.Width; H = $form.Height; L = $form.Left; T = $form.Top }
      })
    $form.Add_Activated({
        # only reached in takeover mode; in hook mode the panel never activates
        if (-not $txt.Focused) { Focus-Search }
      })
    $form.Add_Deactivate({
        $script:CtrlHeld = $false
        if (((Get-Date) - $script:ShownAt).TotalMilliseconds -gt [int]$script:Timing['CloseOnBlur']) { $form.Close() }
      })

    # Two input models: hook - the form never activates and a low-level hook feeds the
    # controls, so the window the user typed in keeps the focus; takeover - no hook or an
    # IME asked for a real focus, the panel activates and hands the foreground back on close.
    $script:PickerHook = $false
    $script:PickerEscalated = $false
    $script:ImeCheckAt = Get-Date; $script:ImeNative = $false
    # seed from the real button state: starting at $false would read a button the user is
    # already holding as a fresh click and close the panel on its first frame
    $script:MenuClosedAt = $null
    $script:PrevMouseDown = ([Cb.Win]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0
    # Non-modal on purpose: ShowDialog would block this message pump. The rounded region is
    # set before the first paint, or one square frame shows through first.
    Update-PanelRegion $form
    $form.Show()
    # The hook keeps the foreground window untouched. An input method can only be driven
    # through a real focus, so the panel hands itself the keyboard as soon as one is active
    # (see the loop) - without that, Chinese/Japanese/Korean could never be typed in.
    Disable-KeyHook   # never inherit a hook from a panel that closed badly
    $script:PickerHook = Enable-KeyHook
    if (-not $script:PickerHook) { [void](Switch-ToTakeover $form.Handle $txt) }
    Write-Log ('picker: input=' + $(if ($script:PickerHook) { 'hook' } else { 'takeover' }))
    [void][Cb.Win]::SetWindowPos($form.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13)

    while (-not $form.IsDisposed) {
      [Windows.Forms.Application]::DoEvents()
      $am = Invoke-AnimFrame $script:Anim $(if ($script:Animations) { 0.4 } else { 1.0 })
      # repaint only the rows whose alpha moved, not the whole list on every tick
      if ($am -ne 0 -and -not $form.IsDisposed) { try { if ($am -band 1) { foreach ($i in @($script:Anim.HoverIndex, $script:Anim.PrevHoverIndex, $script:Anim.SelIndex, $script:Anim.PrevSelIndex)) { if ($i -ge 0 -and $i -lt $lst.ItemCount) { $lst.Invalidate($lst.GetItemRectangle($i)) } } }; if ($am -band 2) { $sbar.Invalidate() }; if ($am -band 4) { $grip.Invalidate() }; if ($am -band 8) { $box.Invalidate() } } catch { } }
      if ($script:PickerClose) { $form.Close(); break }
      if ($script:PickerHook) {
        # cache the IME state instead of asking per keystroke (a cross-process call); the
        # box the user is working in may have changed, so ask about the foreground window
        if (((Get-Date) - $script:ImeCheckAt).TotalMilliseconds -gt 400) {
          $script:ImeCheckAt = Get-Date
          $fgNow = [Cb.Win]::GetForegroundWindow()
          if ($fgNow -eq [IntPtr]::Zero -or $fgNow -eq $form.Handle) { $fgNow = $prev }
          $script:ImeNative = Test-ImeOpen $fgNow
        }
        if ($form.IsHandleCreated) { Invoke-HookedKey }
        if (-not $script:PickerHook) { continue }   # handed over above
        # a click outside dismisses it (Add_Deactivate never fires under the hook). A menu
        # that is up owns its own clicks - one of those is never a click outside the panel,
        # or picking an item (the popup reaches past the panel) would close the panel too.
        $mouseDown = ([Cb.Win]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0
        $justPicked = $script:MenuClosedAt -and (((Get-Date) - $script:MenuClosedAt).TotalMilliseconds -lt 400)
        if ($mouseDown -and -not $script:PrevMouseDown -and -not $justPicked -and -not $cm.Visible -and -not $form.Bounds.Contains([Windows.Forms.Cursor]::Position)) {
          Write-Log 'picker: dismissed by a click outside'
          $form.Close(); break
        }
        $script:PrevMouseDown = $mouseDown
      } elseif (-not $form.ContainsFocus -and ((Get-Date) - $script:ShownAt).TotalMilliseconds -gt 350) {
        # safety net for the takeover model: a click elsewhere dismisses the panel
        $fg = [Cb.Win]::GetForegroundWindow()
        if ($fg -ne $form.Handle -and $fg -ne $prev) { $form.Close(); break }
      }
      # a card waits for the cursor to rest, so sweeping the list never builds one
      if ($script:PreviewHover -and $script:Hover -ge 0 -and $script:PvIdx -ne $script:Hover -and -not $cm.Visible -and ((Get-Date) - $script:PvAt).TotalMilliseconds -gt $script:PreviewDelay) { Show-HoverPreview }
      # Idle ticks cost real CPU: 8 ms while something moves or the menu is open, else 20 ms.
      $busy = ($am -ne 0 -or $cm.Visible -or $script:PickerClose)
      Start-Sleep -Milliseconds $(if ($busy) { 8 } else { 20 })
    }

    # only takeover mode moved the foreground, which is also the only mode that restores it
    if ($script:PickerEscalated -or (-not $script:PickerHook)) {
      if ($prev -ne [IntPtr]::Zero) { [void][Cb.Win]::SetForegroundWindow($prev) }
    }

    if ($script:SaveWinWidth -or $script:SaveWinPos) {
      try {
        $geo = $script:PickerGeo
        if ($null -eq $geo) {
          # the form is gone by now: without the capture from FormClosing there is nothing
          # safe to read, so leave the stored geometry alone
          Write-Log 'save window state skipped: geometry was not captured'
        } else {
          if ($script:SaveWinWidth) {
            [void](Set-IniKey 'WindowWidth' ([string][int]([double]$geo.W / [double]$script:UiScale)))
          }
          if ($script:SaveWinPos) {
            [void](Set-IniKey 'WindowLeft' ([string]$geo.L))
            [void](Set-IniKey 'WindowTop' ([string]$geo.T))
          }
        }
      } catch { Write-Log ('save window state failed: ' + $_.Exception.Message) }
    }

    $deb.Dispose()
    $footTimer.Dispose()
    $confirmTimer.Dispose()
    Close-Preview $pv
    try { $pvCfg.InkBrush.Dispose(); $pvCfg.DimBrush.Dispose() } catch { }
    $cm.Dispose()
    # GDI handles this panel owns: the group heading font, and the region the form paints with
    try { if ($null -ne $groupFont) { $groupFont.Dispose() } } catch { }
    try { $rgn = $form.Region; $form.Dispose(); if ($null -ne $rgn) { $rgn.Dispose() } } catch { }
  } catch {
    Write-Log ('picker error: ' + $_.Exception.Message)
    try {
      $pos = [string]$_.InvocationInfo.PositionMessage
      $pos = ($pos -replace '\s+', ' ').Trim()
      if ($pos.Length -gt 200) { $pos = $pos.Substring(0, 200) }
      Write-Log ('picker at: ' + $pos)
    } catch { }
  } finally {
    # process-wide: a hook that outlives the panel swallows every key, so release it here
    Disable-KeyHook
    # an error can leave the window on screen with no loop left to serve it
    try { if ($form -and -not $form.IsDisposed) { $form.Close() } } catch { }
    $script:PickerOpen = $false
  }
}

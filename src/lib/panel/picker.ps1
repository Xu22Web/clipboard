# lib/panel/picker.ps1 - the history panel. One function owns the whole window lifecycle (create,
# filter, draw, keys, paste); the standalone pieces live in picker-geom / entry / plugins.

function Show-Picker([switch]$Warm) {
  if ($script:PickerOpen) {
    # a second hotkey press closes the panel; a warm run only builds and throws away, so it
    # must leave a panel the user is working in alone
    if (-not $Warm) { $script:PickerClose = $true }
    return
  }
  $script:PickerOpen = $true
  $script:PickerClose = $false
  # how long the window takes to appear: one line per open, so a slow start can be told
  # apart from a slow list (records / widgets / bind / list)
  $swOpen = [System.Diagnostics.Stopwatch]::StartNew()
  $msRecords = 0
  $msWidgets = 0
  $msBind = 0
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
    }
    $prev = [Cb.Win]::GetForegroundWindow()
    # Windows Start and its search flyout keep themselves above every other topmost window while
    # they are up (their process runs with UIAccess, so no z-order call moves a normal window
    # over them - measured with topmost, notopmost-then-topmost, BringWindowToTop and HWND_TOP).
    # A panel opened there is invisible, and its hook would swallow the keys meant for the search
    # box: nothing good comes of opening over them.
    if (-not $Warm -and (Test-ShellFlyout $prev)) {
      Write-Log 'picker: not opened (Windows Start / search is in front)'
      $script:PickerOpen = $false
      return
    }
    # the control that owns the keyboard there: restored when the panel hands the foreground
    # over (an input method) and after the paste that follows a pick
    $script:PrevFocus = Save-TargetFocus $prev
    $script:Entries = @(Get-Records)
    if ($script:Entries.Count -eq 0) { Write-Log 'picker: empty (showing hint)' }
    $msRecords = [int]$swOpen.ElapsedMilliseconds

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
    # no keyboard path yet; the derived flags are owned by Set-InputMode (lib\panel\keyhook.ps1)
    Set-InputMode 'none'
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

    # Two shapes, one code path: what differs is resolved here, before a control exists,
    # because the window height is fixed for the life of the panel.
    $preset = Get-PanelPreset $(if ($script:CompactMode) { 'compact' } else { 'full' })
    $script:PanelPreset = $preset
    $rowsKey = $(if ($preset.Mode -eq 'compact') { 'CompactRows' } else { 'Rows' })
    # the search field sits in the middle of the header: 14 px above it in a 68 px one
    $boxTop = [int](($preset.Head - 40) / 2)

    $form = New-Object Cb.FluentForm
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'Manual'
    # no TopMost property: assigning it makes WinForms call SetWindowPos without
    # SWP_NOACTIVATE, which activates the panel; it is raised right after Show() instead.
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.Text = 'Clipboard history'
    $form.AccessibleName = 'Clipboard history'
    $form.Width = Px $preset.Width
    # The height comes from the row count, never from a setting of its own, so no row is ever
    # half cut off. The screen caps it, and Min = Max keeps the window to the size it opens at.
    $screenH = 0; try { $screenH = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea.Height } catch { }
    $rows = Get-RowsForScreen $preset.Rows ([int]([double]$screenH / [double]$script:UiScale)) (Get-PanelRowHeight) (Get-PresetChrome $preset) ([int]$script:IniSchema[$rowsKey].Minimum)
    if ($rows -ne $preset.Rows) { Write-Log ('picker: rows ' + $preset.Rows + ' -> ' + $rows + ' to fit this screen') }
    $form.Height = Px (Get-PanelHeight $rows (Get-PanelRowHeight) (Get-PresetChrome $preset))
    $form.MinimumSize = New-Object Drawing.Size -ArgumentList @($form.Width, $form.Height)
    $form.MaximumSize = New-Object Drawing.Size -ArgumentList @($form.Width, $form.Height)
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
    $sbar.Width = Px 6
    $sbar.BackColor = $ui.Surface
    $script:SbTop = 0
    $script:SbLen = 0
    $script:SbDrag = -1
    $script:SbHot = $false

    $foot = New-Object Windows.Forms.Panel
    $foot.Dock = 'Bottom'
    $foot.Height = Px $preset.Foot
    $foot.BackColor = $ui.Surface

    $footR = New-Object Windows.Forms.Label
    $footR.Dock = 'None'
    $footR.TextAlign = 'MiddleRight'
    $footR.Font = $fSmall
    $footR.ForeColor = $ui.Faint
    $footR.BackColor = $ui.Surface
    $footR.AutoEllipsis = $true
    $footR.Text = ''
    # the count, the pin count and the version are scan-the-corner information: the compact
    # panel gives that width to the hints instead
    $footR.Visible = [bool]$preset.ShowFootRight

    $footL = New-Object Windows.Forms.Panel
    $footL.Dock = 'Fill'
    $footL.BackColor = $ui.Surface

    $foot.Controls.Add($footR)
    $foot.Controls.Add($footL)

    $head = New-Object Windows.Forms.Panel
    $head.Dock = 'Top'
    $head.Height = Px $preset.Head
    $head.BackColor = $ui.Surface
    # an empty piece of the header is still "the search area": clicking it asks for the
    # keyboard, so the panel takes it over (see Claim-Search)
    $head.Add_Click({ Claim-Search })

    $box = New-Object Windows.Forms.Panel
    $box.SetBounds((Px 14), (Px $boxTop), ($form.ClientSize.Width - (Px 30)), (Px 40))
    $box.BackColor = $ui.Field
    $box.Add_Click({ Claim-Search })
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
    $icon.Add_Click({ Claim-Search })

    $txt = New-Object Windows.Forms.TextBox
    $txt.BorderStyle = 'None'
    $txt.SetBounds((Px 38), (Px 10), ($box.Width - (Px 80)), (Px 22))
    $txt.BackColor = $ui.Field
    $txt.ForeColor = $ui.Text
    $txt.Font = $fBody
    $txt.AccessibleName = 'Search clipboard history'
    # the box itself takes the click before its parent panel ever sees it
    $txt.Add_Click({ Claim-Search })

    $ph = New-Object Windows.Forms.Label
    $ph.SetBounds((Px 40), (Px 10), ($box.Width - (Px 106)), (Px 22))
    $ph.Text = 'Search clipboard history'
    $ph.Font = $fBody
    $ph.ForeColor = $ui.Faint
    $ph.BackColor = $ui.Field
    $ph.TextAlign = 'MiddleLeft'
    $ph.Cursor = 'IBeam'
    # the placeholder covers the empty box, so this is what a click on an empty search field
    # actually hits
    $ph.Add_Click({ Claim-Search })

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

    $form.Controls.Add($listHost)
    $form.Controls.Add($sbar)
    $form.Controls.Add($foot)
    $form.Controls.Add($head)
    $msWidgets = [int]$swOpen.ElapsedMilliseconds

    # A remembered position wins only when the panel still lands on a screen.
    $areas = @()
    try { foreach ($sc in [Windows.Forms.Screen]::AllScreens) { $areas += $sc.WorkingArea } } catch { }
    $fallback = $null
    try { $fallback = [Windows.Forms.Screen]::FromHandle($prev).WorkingArea } catch { }
    if (-not $fallback) { try { $fallback = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea } catch { } }
    if (-not $fallback) { $fallback = New-Object Drawing.Rectangle -ArgumentList @(0, 0, $form.Width, $form.Height) }
    # PlaceNearForeground: with no saved position the panel sits on the window it came from.
    # A window that is gone, minimised or tiny keeps the centred fallback.
    $preferBox = $null
    if ($script:PlaceNearForeground -and $prev -ne [IntPtr]::Zero) {
      try {
        $b = [Cb.Win]::WindowBounds($prev)
        if ($null -ne $b -and $b.Width -ge 200 -and $b.Height -ge 200) { $preferBox = $b }
      } catch { $preferBox = $null }
    }
    # the caret is the tightest anchor there is: it marks the line being typed at. A target
    # that reports no caret right now falls through to the window or the centre.
    $caretBox = $null
    if ($preset.AnchorCaret -and $prev -ne [IntPtr]::Zero) {
      try {
        $c = Get-CaretAnchor $prev
        if ($null -ne $c -and $c.Width -gt 0 -and $c.Height -gt 0) {
          $caretBox = $c
          Write-Log ('picker: anchor=' + $script:CaretSource + ' at ' + $c.Left + ',' + $c.Top + ' ' + $c.Width + 'x' + $c.Height)
        } else { Write-Log 'picker: anchor=none' }
      } catch { $caretBox = $null; Write-Log ('picker: anchor failed: ' + $_.Exception.Message) }
    }
    # a saved position belongs to the full panel: the compact one is placed on every open
    $savedLeft = $(if ($preset.Mode -eq 'compact') { '' } else { [string]$script:WinLeft })
    $savedTop = $(if ($preset.Mode -eq 'compact') { '' } else { [string]$script:WinTop })
    $pb = Get-PickerBounds $form.Width $form.Height $savedLeft $savedTop $areas $fallback $preferBox $caretBox
    $form.Left = [int]$pb.Left
    $form.Top = [int]$pb.Top

    function Layout-Chrome {
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
      $footL.Invalidate()
    }

    # shortcut hints as Fluent key chips: [key] action, built in lib/panel/picker-draw.ps1
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
          $hintRec = $null
          if ($lst.SelectedIndex -ge 0 -and $lst.SelectedIndex -lt $script:Filtered.Count) { $hintRec = $script:Filtered[$lst.SelectedIndex] }
          Draw-KeyChips $g (Px 14) $cy (Get-PanelHints $script:Filtered.Count (Get-SelectionCount $script:Sel) (Test-RowEditable $hintRec) $txt.Text.Length $script:CtrlHeld $ctrlHints ($null -ne $script:EditRow) $script:UndoOn ($preset.Mode -eq 'compact')) $ui.Dim $ui.Faint $chipLimit
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
    # The rows move under a pointer that does not: after a scroll, or after the filter narrowed
    # the list, the row below the cursor is a different one. Reading it again here keeps the
    # highlight and the card on the row the user is actually pointing at, and the rest timer
    # starts over - a preview follows a cursor that has come to rest, so sweeping the list with
    # the wheel no longer flashes a card between two notches. MouseMove only sees the pointer
    # move, which is why this cannot live there.
    function Sync-HoverFromCursor {
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
      Hide-Preview $pv
    }
    # every way the list can scroll (wheel, drag, keys, selection) has to move the thumb
    $lst.Add_ScrollChanged({ Sync-Sb; Sync-HoverFromCursor })

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

    $sbar.Add_Paint({
        param($s, $e)
        if ($script:SbLen -le 0) { return }
        $e.Graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $hot = ($script:SbHot -or $script:SbDrag -ge 0)
        $k = [double]$script:Anim.Sb
        if ($hot) { $k = 1.0 }
        $w = [int][Math]::Round((Px 3) + ($k * ((Px 5) - (Px 3))))
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
        # actually fit - see Get-StickyPlan / Get-StickyTopRows in lib/ordering.ps1
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
      # the filter changed what sits under the pointer: same reading as after a scroll
      Sync-HoverFromCursor
      Sync-Placeholder
      $lst.Invalidate()
      Sync-Sb
      Restore-Foot
    }

    # The picker already put the text on the clipboard: hide it and paste into the window
    # that is in front. Shared by Enter and by a plugin action that asks for
    # After = 'paste' (transform copies the rewritten text, then wants it pasted).
    #
    # Which window that is gets decided when the key is pressed, not when the panel opened:
    # the hook lets Alt+Tab through, so the user can bring another application forward while
    # the panel is up, and the text still has to land where they are looking now. A window of
    # this process does not count - after an input-method hand-over the panel itself is in
    # front, and the daemon's own console can be too. Those are not places to paste into, and
    # the window the panel came from is the answer for them.
    function Get-PasteTarget {
      try {
        $fgNow = [Cb.Win]::GetForegroundWindow()
        if ($fgNow -ne [IntPtr]::Zero -and -not [Cb.Win]::IsOwnWindow($fgNow)) { return $fgNow }
      } catch { }
      return $prev
    }

    # One line for a window. A paste that lands elsewhere is the one report that cannot be
    # reproduced from a screenshot, and a handle alone says nothing: the program name and the
    # title are what the user recognises.
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

    function Format-PasteTarget([IntPtr]$target) {
      $where = Format-WindowName $target
      if ($target -ne $prev) { $where = $where + ' (switched, was 0x' + ([int64]$prev).ToString('X') + ')' }
      return $where
    }

    function Paste-Clip([string]$TypedText = '') {
      $target = Get-PasteTarget
      Write-Log ('paste target: ' + (Format-PasteTarget $target))
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
      # waiting only works when the key is let go of soon: a modifier that is still down when
      # the wait ends is released, so the paste cannot arrive as another shortcut
      if (-not (Test-Modifiers-Up)) { Release-HeldModifiers }
      # SetForegroundWindow can be refused by the foreground lock and SendKeys types into
      # whatever is in front, so hand over and verify before typing.
      if (-not (Take-Foreground $target)) {
        Write-Log 'paste skipped: the target window did not take the foreground'
        Set-Foot 'Copied to the clipboard. The window did not come back to the front - press Ctrl+V there' ([int]$script:Timing['FootMessage'])
        return
      }
      # the window is back but its caret may not be: give the control the keyboard again.
      # Only the window the panel came from has a remembered control; after a switch the
      # caret already sits where the user left it.
      if ($target -eq $prev) { [void](Restore-TargetFocus $target $script:PrevFocus) }
      $form.Hide()
      Start-Sleep -Milliseconds $script:PasteSettle
      # hiding the panel moves the foreground for a moment, and a target that noticed can be
      # behind it by now: the keys only mean anything while the target still has the front
      if ([Cb.Win]::GetForegroundWindow() -ne $target) {
        $moved = [Cb.Win]::GetForegroundWindow()
        Write-Log ('paste: the foreground moved after the panel hid (' + (Format-WindowName $moved) + '), taking it back')
        [void](Take-Foreground $target)
        if ($target -eq $prev) { [void](Restore-TargetFocus $target $script:PrevFocus) }
      }
      if ($TypedText -ne '') {
        # typing lands in the focused control through SendInput: no clipboard and no paste
        # key, which is what a target that ignores Ctrl+V needs
        $sent = 0
        try { $sent = [Cb.Win]::SendUnicode($TypedText) } catch { Write-Log ('typing failed: ' + $_.Exception.Message) }
        Write-Log ('typed ' + $sent + ' of ' + $TypedText.Length + ' characters')
      } else {
        try { [Windows.Forms.SendKeys]::SendWait($PasteKeys) } catch { Write-Log ('sendkeys fail: ' + $_.Exception.Message) }
      }
      try {
        $after = [Cb.Win]::GetForegroundWindow()
        if ($after -ne $target) { Write-Log ('paste: the foreground changed while the keys were sent (' + (Format-WindowName $after) + ')') }
      } catch { }
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
      $pasteTo = Get-PasteTarget
      if ($script:NoPaste -or $NoInject.IsPresent -or (Test-AppRuleNoPaste $pasteTo)) { $form.Hide(); [void](Set-ClipItem $payload $rich); Set-LastCapture $payload; $form.Close(); return }
      # the program in front decides whether the formatting travels with the paste:
      # a terminal wants the text, an editor wants the layout. The window asked about is the
      # one the paste goes back to - the panel itself may be in front after a hand-over.
      if ($rich -and -not (Test-AppRuleKeepsRich $pasteTo)) { $rich = '' }
      if (-not (Set-ClipItem $payload $rich)) { Write-Log 'set clipboard failed'; $form.Close(); return }
      # our own write must not come back as a new capture
      Set-LastCapture $payload
      # PasteTyping=1 skips the paste key. Only plain text can be typed: a file list and a
      # picture still need the clipboard.
      $typed = ''
      if ($script:PasteTyping -and $rich -eq '' -and -not (Test-FilePayload $payload) -and -not (Test-ImagePayload $payload)) { $typed = $payload }
      Paste-Clip -TypedText $typed
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
      [void](Restore-Record $rec $at)
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
    $m7 = $cm.Items.Add('Edit'); $m7.ShortcutKeyDisplayString = 'F2'
    $m7.Add_Click({ Begin-RowEdit })
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
          # a picture, a file list and a formatted entry have nothing the editor can show
          $editable = ($null -ne $cur -and (Test-RowEditable $cur))
          $m7.Visible = $editable
          $m7.Enabled = $editable
          $keep[[int]$cm.Items.IndexOf($m7)] = $editable
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
    # the empty-state layer covers the list and swallows its right click
    $empty.ContextMenuStrip = $cm
    # Picking an item is a left click outside the panel: remember when the menu closed so
    # the loop below does not dismiss the panel on the very click that chose the item.
    $cm.Add_Closed({ $script:MenuClosedAt = Get-Date })

    # one StringFormat set per process, shared with the drawing helpers in lib/panel/picker-draw.ps1
    $sfSet = New-PickerStringFormats
    $bgBrush = New-Object Drawing.SolidBrush $ui.Surface
    # One brush per colour lives in lib/panel/picker-draw.ps1, so reopening builds nothing.
    $sfEll = $sfSet.Ellipsis
    $sfNone = $sfSet.None
    $sfRight = $sfSet.Right
    $sfCenter = $sfSet.Center
    $sfSeg = $sfSet.Seg
    # the hover card (lib/panel/preview.ps1): geometry and brushes once per panel, never per
    # hover; it ellipsizes like the rows, because a Win11 flyout never cuts text mid-glyph
    $pvCfg = New-PreviewConfig $ui $sfEll $fBody $fSmall

    # draw one label in pieces so the matched tokens can be tinted; the tail is trimmed
    # with an ellipsis once the available width is exhausted (lib/panel/picker-draw.ps1)

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
        # The list gives up a column on the right for the scrollbar, so insetting both sides by
        # the same amount would leave every row sitting one gutter to the left of centre. The
        # gutter is added to the left inset and taken off the width instead, which balances the
        # block against the window while RowRight stays twice RowInset (11 px each side at
        # 700 wide, 96 dpi; see the metric table in lib\base.ps1).
        $gutter = [int]$sbar.Width
        $rowW = [Math]::Min($b.Width, $listHost.ClientSize.Width) - (Px $m['RowRight']) - $gutter
        if ($rowW -lt (Px $m['RowMinWidth'])) { $rowW = Px $m['RowMinWidth'] }
        $r = New-Object Drawing.Rectangle -ArgumentList @(($b.X + (Px $m['RowInset']) + $gutter), ($b.Y + (Px $m['RowGap'])), $rowW, ($b.Height - (Px (2 * $m['RowGap']))))
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
        $timeW = $(if ($script:PanelPreset.ShowTime) { Px $m['TimeWidth'] } else { 0 })
        $timeX = $capX - $(if ($timeW -gt 0) { Px $m['TimeGap'] } else { 0 }) - $timeW
        $markR = $timeX - (Px $m['MarkGap']) - (Px $m['MarkSlot'])
        $markL = $markR - (Px $m['MarkGap2']) - (Px $m['MarkSlot'])
        $offset = $e.Index - $lst.TopIndex
        $showCap = ($offset -ge 0 -and $offset -le 9 -and $offset -lt (Get-Rows) -and -not $script:Confirm)

        if ($timeW -gt 0) {
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
        if ($hi -and $script:HighlightMaxBytes -gt 0) {
          if ([int]$row.Bytes -gt $script:HighlightMaxBytes) { $hi = $false }
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
    # Hover preview (lib/panel/preview.ps1): it waits for the cursor to rest and prepares a record's
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
    $lst.Add_SelectedIndexChanged({ if (-not $lst.IsDisposed) { Set-AnimSelection $script:Anim $lst.SelectedIndex; $footL.Invalidate() } })
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
    # the footer lists what the selected row allows (F2 only for a plain text row), so every
    # path that changes the selection has to repaint it: the list redraws itself, the footer is
    # its own control and would otherwise keep the hints of the row selected before
    $lst.Add_RowClicked({ param($sn, $ev) Update-Selection $script:Sel $lst ([int]$lst.ClickRow) ([bool]$lst.ClickHadControl) ([bool]$lst.ClickHadShift); $footL.Invalidate() })
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
    # F2 edits the selected entry in place; the editor lives in lib/panel/picker-edit.ps1
    Set-PickerEditHost $form $lst $txt $ui $fBody { param($q) Update-List $q } { param($m, $ms) Set-Foot $m ([int]$ms) } { Focus-Search }
    function Flush-List { if ($deb.Enabled) { $deb.Stop(); Update-List $txt.Text } }
    $txt.Add_TextChanged({ Sync-Placeholder; $deb.Stop(); $deb.Start() })
    $txt.Add_GotFocus({ $script:SearchFocus = $true; Set-AnimTarget $script:Anim 'Field' 1.0 })
    $txt.Add_LostFocus({ $script:SearchFocus = $false; Set-AnimTarget $script:Anim 'Field' 0.0 })
    $clr.Add_Click({ $txt.Text = ''; Claim-Search })
    $form.Add_KeyDown({
        param($s, $e)
        # The editor owns the keyboard while it is open. KeyPreview runs this handler before
        # the focused control, so without this guard Ctrl+A / Del / Ctrl+Z would act on the
        # history instead of the text being edited.
        if ($null -ne $script:EditRow) { return }
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
    # either: keys are posted to the controls, keeping every handler working. While the
    # editor is open the search field must not take the focus back - that is what sent
    # keystrokes typed into the editor to the filter box.
    function Focus-Search {
      if ($null -ne $script:EditRow) { return }
      if (-not $script:PickerHook) { $txt.Focus() }
    }

    # Opening the panel only paints the field as active (see Add_Shown): the window in front
    # keeps the keyboard and the hook feeds the panel. A click is a different statement - the
    # user is aiming at the field - so the keyboard is handed over for real (the same
    # hand-over an input method asks for). From then on the panel owns the foreground, which
    # is why the restore after the loop puts it back where it came from.
    function Claim-Search {
      # 'off' means the panel never takes the foreground, not even for a click on the field
      if ($null -eq $script:EditRow -and $script:PickerHook -and $script:ImeTakeover -ne 'off') {
        if (Switch-ToTakeover $form.Handle $txt) {
          Set-InputMode 'takeover'
          Write-Log 'picker: the search area was clicked, the panel took the keyboard'
        } else {
          # the hook is armed again when the hand-over fails, so the flag has to follow it or
          # the keys it takes are swallowed and read by nobody
          Set-InputMode $(if (Restore-KeyHook $form.Handle) { 'hook' } else { 'none' })
        }
      }
      Focus-Search
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
        # where this key belongs: the editor while it is open, the search field otherwise. The
        # input-method hand-over has to use the same target, or the hand-over would move the
        # keyboard to the filter box and everything typed next would land there.
        $tg = $(if ($null -ne $script:HookTargetBox) { $script:HookTargetBox } else { $txt })
        # an input method needs a real focus: hand over and replay the key so it composes there
        if ($plain -and (Test-ImeTakeover $script:ImeTakeover $vk ([bool]$script:ImeNative) $claimed)) {
          if (Switch-ToTakeover $form.Handle $tg) {
            Set-InputMode 'takeover'
            Write-Log 'picker: handing the keyboard over for the input method'
            Send-HookedKeys $keys $i
          } else {
            # a refused hand-over re-arms the hook: the flag has to follow it, or the keys it
            # takes are swallowed and never read
            Set-InputMode $(if (Restore-KeyHook $form.Handle) { 'hook' } else { 'none' })
          }
          return
        }
        # text (and Backspace, WM_CHAR 0x08) goes to the box; Esc/Enter/Tab are control chars
        $isText = $ch -ne [char]0 -and (-not [char]::IsControl($ch) -or $ch -eq [char]8)
        # Esc closes the panel, so the handle is read once and the delivery is guarded
        try {
          if ($isText -and $plain) { [void][Cb.Win]::SendMessage($tg.Handle, 0x0102, [IntPtr][int]$ch, [IntPtr]1) }
          else {
            $wh = $tg.Handle
            [void][Cb.Win]::SendMessage($wh, 0x0100, [IntPtr]$vk, [IntPtr]1); [void][Cb.Win]::SendMessage($wh, 0x0101, [IntPtr]$vk, [IntPtr]1)
          }
        } catch { return }
      }
    }

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
        # the layout and the list were built before Show() (see below), so this only takes
        # the keyboard back and paints the search field as focused
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
        # an edit in progress keeps the panel open: closing would drop the text
        if ($null -ne $script:EditRow) { return }
        if (((Get-Date) - $script:ShownAt).TotalMilliseconds -gt [int]$script:Timing['CloseOnBlur']) { $form.Close() }
      })

    # Two input models: hook - the form never activates and a low-level hook feeds the
    # controls, so the window the user typed in keeps the focus; takeover - no hook or an
    # IME asked for a real focus, the panel activates and hands the foreground back on close.
    # Every switch goes through Set-InputMode (lib\panel\keyhook.ps1), which owns the two
    # derived flags the loop and the tests read.
    Set-InputMode 'none'
    $script:ImeCheckAt = Get-Date; $script:ImeNative = $false
    $script:ShellCheckAt = Get-Date
    # seed from the real button state: starting at $false would read a button the user is
    # already holding as a fresh click and close the panel on its first frame
    $script:MenuClosedAt = $null
    $script:PrevMouseDown = ([Cb.Win]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0
    # Non-modal on purpose: ShowDialog would block this message pump. Layout, list and the
    # rounded region all happen before the window appears, so the first frame is the whole
    # panel instead of an empty list that fills in a beat later (measured at ~60 ms).
    Layout-Chrome
    Size-List
    Sync-Sb
    Update-List ''
    Update-PanelRegion $form
    $msBuild = [int]$swOpen.ElapsedMilliseconds
    $swOpen.Stop()
    $shape = (' ms (records ' + $msRecords + ', widgets ' + $msWidgets + ', bind ' + ($msBuild - $msWidgets) + ', items ' + $script:Entries.Count + ')')
    # a warm run is a different event in the log: it built the panel and threw it away
    if ($Warm) { Write-Log ('picker: warm ' + $msBuild + $shape) } else { Write-Log ('picker: open ' + $msBuild + $shape) }
    Write-Log ('picker: mode=' + $preset.Mode + ' rows=' + $rows + ' width=' + $preset.Width)
    # A warm run (see Start-Serve) builds everything and throws it away: the first hotkey then
    # pays only for Show(), which is what the resident wants to avoid after a restart.
    if ($Warm) {
      try { $deb.Dispose() } catch { }
      try { $footTimer.Dispose() } catch { }
      try { $confirmTimer.Dispose() } catch { }
      try { Close-Preview $pv } catch { }
      try { $pvCfg.InkBrush.Dispose(); $pvCfg.DimBrush.Dispose() } catch { }
      try { $cm.Dispose() } catch { }
      try { if ($null -ne $groupFont) { $groupFont.Dispose() } } catch { }
      try { $rg = $form.Region; $form.Dispose(); if ($null -ne $rg) { $rg.Dispose() } } catch { }
      return
    }
    $form.Show()
    # The hook keeps the foreground window untouched. An input method can only be driven
    # through a real focus, so the panel hands itself the keyboard as soon as one is active
    # (see the loop) - without that, Chinese/Japanese/Korean could never be typed in.
    Disable-KeyHook   # never inherit a hook from a panel that closed badly
    # the Ctrl combinations this panel answers, plugin keys included; the rest of the
    # keyboard still reaches the window behind
    Set-KeyHookCtrlKeys ([int[]]@($ctrlHints | ForEach-Object { [int][char]([string]$_.Key).ToUpperInvariant() }))
    Set-InputMode $(if (Enable-KeyHook) { 'hook' } else { 'none' })
    if (-not $script:PickerHook) {
      # no hook: the panel has to own the foreground, so record it as the takeover it is
      if (Switch-ToTakeover $form.Handle $txt) { Set-InputMode 'takeover' }
    }
    Write-Log ('picker: input=' + (Get-InputMode))
    [void][Cb.Win]::SetWindowPos($form.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13)

    while (-not $form.IsDisposed) {
      [Windows.Forms.Application]::DoEvents()
      $am = Invoke-AnimFrame $script:Anim $(if ($script:Animations) { 0.4 } else { 1.0 })
      # repaint only the rows whose alpha moved, not the whole list on every tick
      if ($am -ne 0 -and -not $form.IsDisposed) { try { if ($am -band 1) { foreach ($i in @($script:Anim.HoverIndex, $script:Anim.PrevHoverIndex, $script:Anim.SelIndex, $script:Anim.PrevSelIndex)) { if ($i -ge 0 -and $i -lt $lst.ItemCount) { $lst.Invalidate($lst.GetItemRectangle($i)) } } }; if ($am -band 2) { $sbar.Invalidate() }; if ($am -band 8) { $box.Invalidate() }; if ($am -band 16) { if ($null -ne $script:EditRow) { $script:EditRow.Save.Invalidate(); $script:EditRow.Cancel.Invalidate() } } } catch { } }
      if ($script:PickerClose) { $form.Close(); break }
      # Ctrl is a modifier, not a key the hook answers: it stays with the window behind, so a
      # KeyDown for it never reaches the panel while the hook owns the keyboard, and the key
      # caps kept their neutral colour while Ctrl was held. Polling the key state is what makes
      # the accents (and the Ctrl group in the footer) follow the modifier in both modes.
      $ctrlNow = ([Cb.Win]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0
      if ($ctrlNow -ne $script:CtrlHeld) {
        $script:CtrlHeld = $ctrlNow
        try { $lst.Invalidate() } catch { }
        try { $footL.Invalidate() } catch { }
      }
      # Windows Start / search calls up a topmost flyout that no other window can cover, and it
      # takes the keyboard with it: a panel left open would be invisible and its hook would
      # swallow the keys the user is typing into the search box. Calling the shell up dismisses
      # the panel - the same answer as a click outside.
      if (((Get-Date) - $script:ShellCheckAt).TotalMilliseconds -gt 300) {
        $script:ShellCheckAt = Get-Date
        $fgShell = [Cb.Win]::GetForegroundWindow()
        if ($fgShell -ne $form.Handle -and (Test-ShellFlyout $fgShell)) {
          Write-Log 'picker: dismissed (Windows Start / search came up)'
          $form.Close(); break
        }
      }
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
        $clicked = ($mouseDown -and -not $script:PrevMouseDown)
        # One click outside ends both. The menu is shown without activation, so it does not
        # always see the click that lands beside it, and the check below deliberately skips
        # while it is up (a click on an item reaches past the panel). Doing it here means the
        # click that dismisses the menu also dismisses the panel, instead of needing two.
        if ($clicked -and $cm.Visible -and -not $justPicked) {
          $pos = [Windows.Forms.Cursor]::Position
          if (-not $cm.Bounds.Contains($pos) -and -not $form.Bounds.Contains($pos)) {
            try { $cm.Close() } catch { }
            Write-Log 'picker: dismissed by a click outside (menu was open)'
            $form.Close(); break
          }
        }
        if ($clicked -and -not $justPicked -and -not $cm.Visible -and -not $form.Bounds.Contains([Windows.Forms.Cursor]::Position)) {
          Write-Log 'picker: dismissed by a click outside'
          $form.Close(); break
        }
        $script:PrevMouseDown = $mouseDown
      } elseif (-not $form.ContainsFocus -and ((Get-Date) - $script:ShownAt).TotalMilliseconds -gt 350) {
        # safety net for the takeover model: a click elsewhere dismisses the panel
        $fg = [Cb.Win]::GetForegroundWindow()
        if ($fg -ne $form.Handle -and $fg -ne $prev) { $form.Close(); break }
      }
      # a card waits for the cursor to rest; a page built off-thread lands on the next tick
      if ($script:PreviewHover -and $script:Hover -ge 0 -and $script:PvIdx -ne $script:Hover -and -not $cm.Visible -and ((Get-Date) - $script:PvAt).TotalMilliseconds -gt $script:PreviewDelay) { Show-HoverPreview }
      [void](Step-PreviewCard $pv)
      # Idle ticks cost real CPU: 8 ms while something moves or the menu is open, else 20 ms.
      $busy = ($am -ne 0 -or $cm.Visible -or $script:PickerClose)
      Start-Sleep -Milliseconds $(if ($busy) { 8 } else { 20 })
    }

    # only takeover mode moved the foreground, which is also the only mode that restores it
    if ($script:PickerEscalated -or (-not $script:PickerHook)) {
      if ($prev -ne [IntPtr]::Zero) { [void][Cb.Win]::SetForegroundWindow($prev) }
      [void](Restore-TargetFocus $prev $script:PrevFocus)
    }

    # the compact panel is placed on every open, so there is no position of its own to keep
    if ($script:SaveWinPos -and $preset.Mode -ne 'compact') {
      try {
        $geo = $script:PickerGeo
        if ($null -eq $geo) {
          # the form is gone by now: without the capture from FormClosing there is nothing
          # safe to read, so leave the stored position alone
          Write-Log 'save window state skipped: geometry was not captured'
        } else {
          [void](Set-IniKey 'WindowLeft' ([string]$geo.L))
          [void](Set-IniKey 'WindowTop' ([string]$geo.T))
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

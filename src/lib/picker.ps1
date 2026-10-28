# lib/picker.ps1 - the history panel. One function owns the whole window lifecycle
# (create, filter, draw, keys, paste) because its parts share the control tree and the
# per-open state; the standalone pieces live in picker-geom / entry / plugins.

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
    $script:Labels = @()
    $script:Tokens = @()
    # rows frozen at the top of the list: the pinned block that never scrolls
    $script:StickyTop = 0
    # Plugin keys and per-row decoration are resolved once per entry, not per key press / paint.
    $panelKeys = @()
    if (Get-Command Get-PluginPanelKeys -ErrorAction SilentlyContinue) { $panelKeys = @(Get-PluginPanelKeys) }
    $ctrlHints = @($panelKeys | Where-Object { $_.Ctrl -and -not $_.Alt -and -not $_.Shift -and ([string]$_.Key).Length -eq 1 })
    # Both caches survive a refresh: a keystroke changes which rows match, not how a row
    # looks. Keys include the flags, so a mark change invalidates its own entry; the
    # comparer is ordinal, or two payloads differing only in case would share one entry.
    $rowCache = [hashtable]::new([StringComparer]::Ordinal)
    $labelCache = [hashtable]::new([StringComparer]::Ordinal)
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
    # no TopMost property here: assigning it makes WinForms call SetWindowPos without
    # SWP_NOACTIVATE, which activates the panel and takes the caret away from the user.
    # The panel is raised with a no-activate SetWindowPos right after Show() instead.
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.Text = 'Clipboard history'
    $form.AccessibleName = 'Clipboard history'
    $form.Width = Px $script:WinWidth
    # The height comes from the row count, never from a setting of its own, so no row is ever
    # half cut off; the screen caps it and matching Min/Max heights leave the drag to width.
    $screenH = 0; try { $screenH = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea.Height } catch { }
    $rows = Get-RowsForScreen $script:Rows ([int]([double]$screenH / [double]$script:UiScale)) (Get-PanelRowHeight) (Get-PanelChrome) ([int]$script:IniSchema['Rows'].Min)
    if ($rows -ne $script:Rows) { Write-Log ('picker: rows ' + $script:Rows + ' -> ' + $rows + ' to fit this screen') }
    $form.Height = Px (Get-PanelHeight $rows (Get-PanelRowHeight) (Get-PanelChrome))
    $form.MinimumSize = New-Object Drawing.Size -ArgumentList @((Px ([int]$script:IniSchema['WindowWidth'].Min)), $form.Height)
    $form.MaximumSize = New-Object Drawing.Size -ArgumentList @((Px ([int]$script:IniSchema['WindowWidth'].Max)), $form.Height)
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

    # The native Win32 scrollbar cannot be themed and ListBox has no property to hide it.
    # So the list lives in a clipping host and is made wider than the host: the scrollbar
    # ends up outside the visible area, while TopIndex scrolling keeps working.
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
        $footR.SetBounds(($foot.ClientSize.Width - (Px 176)), 0, (Px 162), $foot.ClientSize.Height)
      } catch { }
      $footL.Invalidate()
    }

    # shortcut hints as Fluent key chips: [key] action
    function Get-FootHints {
      if ($script:Filtered.Count -eq 0) {
        # the comma keeps the pair nested: a one-element array would be unrolled by the
        # function return and each string would then be read as a list of characters
        return ,@(@('Esc', 'Close'))
      }
      if ($script:CtrlHeld) {
        # Ctrl is held while these hints show, but a bare "1-9,0" reads as a plain digit row
        # (and "Z"/"P" like ordinary letters), so each chip spells the whole combination out.
        # Core combinations come first: the footer truncates whatever does not fit, and the
        # plugin keys at the end are the optional ones.
        $pairs = @(@('Ctrl+1-9,0', 'Pick'))
        $pairs += ,@('Ctrl+Enter', 'Copy only')
        $pairs += ,@('Ctrl+Z', 'Undo')
        foreach ($pk in @($ctrlHints)) { $pairs += ,@('Ctrl+' + [string]$pk.Key, [string]$pk.Hint) }
        return $pairs
      }
      return @(@('Enter', 'Paste'), @('Ctrl+Enter', 'Copy only'), @('Del', 'Delete'), @('Esc', 'Close'))
    }

    # key caps are drawn by lib/picker-draw.ps1; the footer only decides where they stop

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
          Draw-KeyChips $g (Px 14) $cy (Get-FootHints) $ui.Dim $ui.Faint $chipLimit
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
        $footR.Text = $count
      } catch { }
    }

    function Set-Foot([string]$msg, [int]$ms) {
      if ($script:Confirm) { return }
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

    # one Graphics for text measurement, reused for the lifetime of the panel
    $script:MeasureG = $null
    function Get-MeasureGraphics {
      if ($null -eq $script:MeasureG -or $script:MeasureG.IsDisposed) { $script:MeasureG = $lst.CreateGraphics() }
      return $script:MeasureG
    }

    # ListBox has no VerticalScrollbar property, so the scrollbar is kept just outside the
    # visible area by the clipping host instead.
    function Size-List {
      $w = $listHost.ClientSize.Width
      $h = $listHost.ClientSize.Height
      if ($w -gt 0 -and $h -gt 0) { $lst.SetBounds(0, 0, $w + (Px 40), $h) }
    }

    # recompute thumb geometry from the current TopIndex. The frozen block is outside the
    # scrollable range, so the thumb maps onto the rows below it only.
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

    # The control scrolls itself to keep the selection on screen; a frozen row never needs
    # that, so this is only about an empty list.
    function Keep-SelectionVisible {
      if ($lst.ItemCount -gt 0) { $lst.EnsureVisible($lst.SelectedIndex) }
    }

    # move the list so the thumb lands at $thumbTop
    function Sb-ScrollTo([int]$thumbTop) {
      if ($script:SbLen -le 0) { return }
      $span = ($sbar.ClientSize.Height - (Px 6)) - $script:SbLen
      $pin = $lst.PinnedCount
      $room = $lst.MaxTop - $pin
      if ($room -le 0 -or $span -le 0) { return }
      $i = $pin + [int][Math]::Round(($thumbTop - (Px 3)) * $room / $span)
      $lst.ScrollTo($i)
      Sync-Sb
      $lst.Invalidate()
    }

    function Scroll-By([int]$rows) {
      $lst.ScrollBy($rows)
      Sync-Sb
    }

    # focus stays in the search box, so wheel events bubble up here instead of the list
    $form.Add_MouseWheel({
        param($s, $e)
        $lines = 0
        try { $lines = [Windows.Forms.SystemInformation]::MouseWheelScrollLines } catch { }
        if ($script:ScrollLines -gt 0) { $step = [int]$script:ScrollLines }
        elseif ($lines -lt 1) { $step = (Get-Rows) }
        else { $step = [int]$lines }
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
        try { $form.Region = New-RoundRegion $form.ClientSize.Width $form.ClientSize.Height (Px 8) } catch { }
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
        $tokens = @($q -split '\s+' | Where-Object { $_ })
        $script:Tokens = $tokens
        # sticky pins: the plugin names the mark and the cap, the base decides how many rows
        # actually fit - see Get-StickyPlan / Get-StickyTopRows in lib/store.ps1
        $plan = Get-StickyPlan (Get-Rows)
        $rows = @(Select-QueryRows $script:Entries $tokens)
        # the pins sort first, so the run of sticky rows at the top is what gets frozen
        $script:StickyTop = Get-StickyTopRows $rows $plan.Mark $plan.Max
        $res = New-Object System.Collections.Generic.List[object]
        $labs = New-Object System.Collections.Generic.List[string]
        $mk = $(if ($script:ShowNewlineMarker) { '1' } else { '0' })
        foreach ($rec in $rows) {
          $res.Add($rec)
          $lkey = $rec.Payload + [char]0 + $mk
          $lab = $labelCache[$lkey]
          if ($null -eq $lab) {
            $lab = Get-ItemLabel $rec.Payload $script:ShowNewlineMarker
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
      } catch {
        Write-Log ('update list failed: ' + $_.Exception.Message)
      } finally {
        # the lock has to come off even when a row above threw, or the list never paints
        $lst.EndUpdate()
      }
      if ($script:Labels.Count -eq 0) {
        if ($script:Entries.Count -eq 0) {
          $script:EmptyGlyph = $script:Glyphs.History
          $script:EmptyTitle = 'Clipboard history is empty'
          $script:EmptySub = 'Copy something and it will appear here'
        } elseif ($tokens.Count -gt 0) {
          $script:EmptyGlyph = $script:Glyphs.Search
          $script:EmptyTitle = 'No results for "' + $q.Trim() + '"'
          $script:EmptySub = 'Try another keyword, or press Esc to clear the search'
        } else {
          $script:EmptyTitle = ''
          $script:EmptySub = ''
        }
        $empty.Visible = $true
        $empty.BringToFront()
        $empty.Invalidate()
      } else {
        $empty.Visible = $false
      }
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
      # SetForegroundWindow can be refused by the foreground lock, and SendKeys types into
      # whatever is in front at that moment - so hand over, then verify before typing. A
      # refused hand-over used to paste into the wrong window.
      $ready = $false
      for ($try = 0; $try -lt 24 -and -not $ready; $try++) {
        [void][Cb.Win]::SetForegroundWindow($target)
        Start-Sleep -Milliseconds 25
        if ([Cb.Win]::GetForegroundWindow() -eq $target) { $ready = $true }
      }
      if (-not $ready) {
        Write-Log 'paste skipped: the target window did not take the foreground'
        Set-Foot 'Copied to the clipboard. The window did not come back to the front - press Ctrl+V there' 2800
        return
      }
      $form.Hide()
      Start-Sleep -Milliseconds $script:PasteSettle
      try { [Windows.Forms.SendKeys]::SendWait($PasteKeys) } catch { Write-Log ('sendkeys fail: ' + $_.Exception.Message) }
      $form.Close()
    }

    function Use-Index([int]$idx, [switch]$NoInject) {
      if ($idx -lt 0 -or $idx -ge $script:Filtered.Count) { return }
      $payload = $script:Filtered[$idx].Payload
      # a plugin may rewrite what gets pasted (text only, upper case, snake case ...)
      if (Get-Command Invoke-PluginTransform -ErrorAction SilentlyContinue) {
        try {
          $t = Invoke-PluginTransform $payload
          if ($null -ne $t -and [string]$t -ne '' -and [string]$t -cne $payload) {
            $payload = [string]$t
            Write-Log ('pasted via transform (' + $payload.Length + ' chars)')
          }
        } catch { Write-Log ('transform skipped: ' + $_.Exception.Message) }
      }
      if ($script:NoPaste -or $NoInject.IsPresent) { $form.Hide(); [void](Set-ClipItem $payload); $form.Close(); return }
      if (-not (Set-ClipItem $payload)) { Write-Log 'set clipboard failed'; $form.Close(); return }
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
          if ($info.Hint) { Set-Foot ($word + ' entry. Press ' + $info.Hint + ' to ' + $info.Unset + ' it first') 2600 }
          else { Set-Foot ($word + ' entry. ' + $info.Unset + ' it first, then delete') 2600 }
        } else {
          Set-Foot ($word + ' entry. Load the plugin that owns the ' + $pm + ' mark first') 2600
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
      if ($script:UndoOn -and $removed -eq 'removed') { Set-Foot 'Deleted. Press Ctrl+Z to undo' 4000 }
    }

    function Undo-Delete {
      if (-not $script:UndoOn) { Set-Foot 'Undo is off. Set Undo=1 in clipboard.ini to enable it' 2200; return }
      if ($null -eq $script:UndoRec) { Set-Foot 'Nothing to undo' 1500; return }
      $rec = $script:UndoRec
      $at = $script:UndoIdx
      $script:UndoRec = $null
      Restore-Record $rec $at
      $script:Entries = @(Get-Records)
      Update-List $txt.Text
      Set-Foot 'Restored to its original position' 2000
    }

    function Cancel-Confirm {
      $confirmTimer.Stop()
      if (-not $script:Confirm) { return }
      $script:Confirm = $false
      Restore-Foot
    }

    function Request-Clear {
      if ($script:Entries.Count -eq 0) { Set-Foot 'Nothing to clear' 1500; return }
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
      if ($kept.Count -gt 0) { Set-Foot ('History cleared, ' + ($kept -join ', ') + ' kept') 2600 }
      else { Set-Foot 'History cleared' 2000 }
    }

    $cm = New-Object Windows.Forms.ContextMenuStrip
    $cm.Font = $fBody
    $cm.ShowImageMargin = $false
    # Without visual styles the default system renderer paints separators invisibly, which
    # would make the plugin groups read as one flat list; the professional renderer draws
    # real divider lines.
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

    # plugin actions: appended after the built-in ones, hidden unless their Test passes.
    # Items stay grouped per plugin, so a menu never mixes two of them: a header names the
    # plugin and a separator closes the previous group.
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
                  $note = (& $a['Invoke'] $script:Filtered[$lst.SelectedIndex]); if ($note) { Set-Foot ([string]$note) 3200 }
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
          # a separator only makes sense between two items that stay on screen, and two
          # separators never sit back to back: when every action of a plugin is hidden, the
          # separator before its header and the one after its group would otherwise both
          # survive and leave an empty band between the neighbouring groups
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

    # one StringFormat set per process, shared with the drawing helpers in lib/picker-draw.ps1
    $sfSet = New-PickerStringFormats
    $bgBrush = New-Object Drawing.SolidBrush $ui.Surface
    # One brush per colour, reused while the panel lives: the row painter runs on every
    # scroll tick, so allocating a SolidBrush per glyph would churn GDI+ handles for nothing.
    $brushCache = @{}
    function Get-Brush($color) {
      $k = $color.ToArgb()
      $b = $brushCache[$k]
      if ($null -eq $b) { $b = New-Object Drawing.SolidBrush $color; $brushCache[$k] = $b }
      return $b
    }
    $sfEll = $sfSet.Ellipsis
    $sfNone = $sfSet.None
    $sfRight = $sfSet.Right
    $sfCenter = $sfSet.Center
    $sfSeg = $sfSet.Seg

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
        $rowW = [Math]::Min($b.Width, $listHost.ClientSize.Width) - (Px 12)
        if ($rowW -lt (Px 60)) { $rowW = Px 60 }
        $r = New-Object Drawing.Rectangle -ArgumentList @(($b.X + (Px 6)), ($b.Y + (Px 2)), $rowW, ($b.Height - (Px 4)))
        $sel = (($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0)
        $isData = ($e.Index -lt $script:Filtered.Count)
        $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        # decoration / glyph / byte size are cached per entry: DrawItem runs on every hover
        $rec = $null
        $row = $null
        $decor = $null
        if ($isData) {
          $rec = $script:Filtered[$e.Index]
          # the flags are part of the key: a mark change repaints that row and nothing else
          $rkey = $rec.Payload + [char]0 + [string]$rec.Marks
          $row = $rowCache[$rkey]
          if ($null -eq $row) {
            $dec = $null
            if (Get-Command Get-PluginRowDecor -ErrorAction SilentlyContinue) {
              try { $dec = Get-PluginRowDecor $rec } catch { $dec = $null }
            }
            $glyph = ''
            if ($dec -and $dec.Glyph) { $glyph = [string]$dec.Glyph } else { $glyph = Get-RowGlyph $rec.Payload }
            $bytes = 0
            try { $bytes = $Utf8.GetByteCount($rec.Payload) } catch { }
            $row = @{ Decor = $dec; Glyph = $glyph; Bytes = $bytes }
            if ($rowCache.Count -gt 1200) { $rowCache.Clear() }
            $rowCache[$rkey] = $row
          }
          $decor = $row.Decor
        }
        if ($null -eq $script:Anim) { $script:Anim = New-AnimState }
        $tint = $null
        if ($decor -and $decor.BackColor -and (Get-Command Convert-ThemeColor -ErrorAction SilentlyContinue)) { $tint = Convert-ThemeColor $decor.BackColor }
        $selK = $(if ($sel) { 1.0 } else { 0.0 })
        $hovK = 0.0
        if ($e.Index -eq $script:Anim.HoverIndex) { $hovK = [double]$script:Anim.Hover }
        try { Draw-RowBackdrop $g $r.X $r.Y $r.Width $r.Height (Px 4) $tint $ui.SelBg $ui.HoverBg $selK $hovK } catch { Write-Log ('row backdrop failed: ' + $_.Exception.Message) }
        $label = [string]$script:Labels[$e.Index]
        if (-not $isData) {
          $rr = New-Object Drawing.RectangleF -ArgumentList @([single]($r.X + (Px 10)), [single]$r.Y, [single]($r.Width - (Px 20)), [single]$r.Height)
          $g.DrawString($label, $fBody, (Get-Brush $ui.Faint), $rr, $sfEll)
          return
        }

        # Trailing meta column, fixed for every row so nothing shifts around:
        #   [mark 14] [2] [mark 14] [6] [time 52] [12] [key cap 48] [10]
        # The cap spells the combination out (Ctrl+1 ... Ctrl+0): a bare digit reads as a
        # list number instead of a shortcut.
        $capW = Px 48
        $capH = Px 18
        $capX = $r.Right - (Px 10) - $capW
        $capY = $r.Y + [int](($r.Height - $capH) / 2)
        $timeW = Px 52
        $timeX = $capX - (Px 12) - $timeW
        $markR = $timeX - (Px 6) - (Px $script:Metric.MarkSlot)
        $markL = $markR - (Px 2) - (Px $script:Metric.MarkSlot)
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
            if ($mk.Color -and (Get-Command Convert-ThemeColor -ErrorAction SilentlyContinue)) {
              $mcc = Convert-ThemeColor ([string]$mk.Color)
              if ($null -ne $mcc) { $mkColor = $mcc }
            }
            $mkBrush = Get-Brush $mkColor
            $mkRect = New-Object Drawing.RectangleF -ArgumentList @([single]$slots[$mi], [single]$r.Y, [single](Px 14), [single]$r.Height)
            $g.DrawString([string]$mk.Glyph, $fIconSmall, $mkBrush, $mkRect, $sfCenter)
          }
        }

        $textX = $r.X + (Px 12)
        # the icon is drawn only when a plugin supplied one; without a typing plugin the
        # row starts at the text and nothing is reserved for an icon
        $rowGlyph = [string]$row.Glyph
        if ($script:ShowTypeIcon -and $script:IconFamily -and $rowGlyph) {
          $glyphColor = $(if ($sel) { $ui.Text } else { $ui.Dim })
          if ($decor -and $decor.GlyphColor -and (Get-Command Convert-ThemeColor -ErrorAction SilentlyContinue)) {
            $gcc = Convert-ThemeColor $decor.GlyphColor
            if ($null -ne $gcc) { $glyphColor = $gcc }
          }
          $glyphBrush = Get-Brush $glyphColor
          $glyphRect = New-Object Drawing.RectangleF -ArgumentList @([single]($r.X + (Px 10)), [single]$r.Y, [single](Px 20), [single]$r.Height)
          $g.DrawString($rowGlyph, $fIcon, $glyphBrush, $glyphRect, $sfCenter)
          $textX = $r.X + (Px 38)
        }

        $textW = $markL - (Px 8) - $textX
        if ($textW -lt (Px 20)) { $textW = Px 20 }
        $tr = New-Object Drawing.RectangleF -ArgumentList @([single]$textX, [single]$r.Y, [single]$textW, [single]$r.Height)

        if ($sel) {
          # selection indicator only: a short accent pill on the leading edge. It marks the
          # row the keys act on and never doubles as an entry highlight.
          $barBrush = Get-Brush $ui.Accent
          $barPath = New-RoundPath ($r.X + (Px 3)) ($r.Y + (Px 11)) (Px 3) ($r.Height - (Px 22)) (Px 1)
          $g.FillPath($barBrush, $barPath)
          $barPath.Dispose()
        }

        # highlight ink: a plugin sets the text colour, the row keeps its own background
        $ink = $ui.Text
        if ($decor -and $decor.TextColor -and (Get-Command Convert-ThemeColor -ErrorAction SilentlyContinue)) {
          $tcc = Convert-ThemeColor $decor.TextColor
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
          $capPath = New-RoundPath $capX $capY $capW $capH (Px 4)
          $g.FillPath((Get-Brush $capFill), $capPath)
          $capPen = New-Object Drawing.Pen $capStroke, 1
          $g.DrawPath($capPen, $capPath)
          $capPen.Dispose()
          $capPath.Dispose()
          $capRect = New-Object Drawing.RectangleF -ArgumentList @([single]$capX, [single]$capY, [single]$capW, [single]$capH)
          $g.DrawString(('Ctrl+' + (Get-QuickKeyLabel $offset)), $fSmall, (Get-Brush $capInk), $capRect, $sfCenter)
        }
      })
    $tip = New-Object Windows.Forms.ToolTip
    $tip.InitialDelay = 700
    $tip.ReshowDelay = 100
    $tip.AutoPopDelay = 30000
    $lst.Add_SelectedIndexChanged({ if (-not $lst.IsDisposed) { Set-AnimSelection $script:Anim $lst.SelectedIndex } })
    $lst.Add_MouseMove({
        param($s, $e)
        if ($lst.IsDisposed) { return }
        $i = $lst.IndexFromPoint($e.Location)
        if ($i -ne $script:Hover) {
          $old = $script:Hover
          $script:Hover = $i
          Set-AnimHover $script:Anim $i
          foreach ($k in @($old, $i)) {
            if ($k -ge 0 -and $k -lt $lst.Items.Count) { $lst.Invalidate($lst.GetItemRectangle($k)) }
          }
          # Win11 shows a tooltip when a row is truncated
          try {
            if ($i -ge 0 -and $i -lt $script:Filtered.Count) {
              $full = [string]$script:Labels[$i]
              $mw = [single](Get-MeasureGraphics).MeasureString($full, $fBody, 100000, $sfSeg).Width
              $avail = [single]($listHost.ClientSize.Width - (Px 168))
              if ($mw -gt $avail -and $full.Length -gt 0) {
                if ($full.Length -gt 800) { $full = $full.Substring(0, 800) + '...' }
                $tip.SetToolTip($lst, $full)
              } else {
                $tip.SetToolTip($lst, '')
              }
            } else {
              $tip.SetToolTip($lst, '')
            }
          } catch { }
        }
      })
    $lst.Add_MouseLeave({
        try { $tip.SetToolTip($lst, '') } catch { }
        if ($lst.IsDisposed) { $script:Hover = -1; return }
        Set-AnimHover $script:Anim -1
        $script:Hover = -1
      })
    $lst.Add_DoubleClick({ if ($lst.SelectedIndex -ge 0) { Use-Index $lst.SelectedIndex } })
    $lst.Add_MouseUp({ param($s, $e) if ($e.Button -eq 'Left') { Sync-Sb; Focus-Search } })
    # the list can also scroll itself when it owns the focus: keep the painted thumb and
    # the selection in sync when that happens
    $lst.Add_MouseWheel({ Keep-SelectionVisible; Sync-Sb; $lst.Invalidate() })

    $footTimer = New-Object Windows.Forms.Timer
    $footTimer.Interval = 3200
    $footTimer.Add_Tick({ $footTimer.Stop(); Restore-Foot })

    $confirmTimer = New-Object Windows.Forms.Timer
    $confirmTimer.Interval = 5000
    $confirmTimer.Add_Tick({ $confirmTimer.Stop(); $script:Confirm = $false; Restore-Foot })

    $deb = New-Object Windows.Forms.Timer
    $deb.Interval = 150
    $deb.Add_Tick({ $deb.Stop(); Update-List $txt.Text })
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
        if ($e.Control -and $e.KeyCode -eq 'Enter') {
          Flush-List
          if ($lst.SelectedIndex -ge 0) { Use-Index $lst.SelectedIndex -NoInject } else { Set-Foot 'Nothing to copy' 1500 }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.Control -and (($code -ge 48 -and $code -le 57) -or ($code -ge 96 -and $code -le 105))) {
          $n = $code
          if ($n -ge 96) { $n = $n - 96 } else { $n = $n - 48 }
          Flush-List
          $idx = Get-QuickKeyIndex (Get-QuickKeyOffset $n) $lst.TopIndex $script:Filtered.Count (Get-Rows)
          if ($idx -ge 0) { Use-Index $idx } else { Set-Foot 'No entry at that number' 1200 }
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
              if ($note) { Set-Foot ([string]$note) 3200 }
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
          if ($lst.SelectedIndex -ge 0) { Use-Index $lst.SelectedIndex } else { Set-Foot 'Nothing to paste' 1500 }
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
          try { Del-Index $lst.SelectedIndex } catch { Write-Log ('delete failed: ' + $_.Exception.Message) }
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
          if ($isText -and $plain) { [void][Cb.Win]::SendMessage($txt.Handle, 0x0102, [IntPtr][int]$ch, [IntPtr]1) }
          else {
            $wh = $form.Handle
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
        try { $form.Region = New-RoundRegion $form.ClientSize.Width $form.ClientSize.Height (Px 8) } catch { }
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
        # Close() can arrive a second time right after Dispose() (Hide then Close, plus the
        # deactivate timer); reading Width on a disposed form throws
        if ($form.IsDisposed) { return }
        $script:PickerGeo = @{ W = $form.Width; H = $form.Height; L = $form.Left; T = $form.Top }
      })
    $form.Add_Activated({
        # only reached in takeover mode; in hook mode the panel never activates
        if (-not $txt.Focused) { Focus-Search }
      })
    $form.Add_Deactivate({
        $script:CtrlHeld = $false
        if (((Get-Date) - $script:ShownAt).TotalMilliseconds -gt 450) { $form.Close() }
      })

    # Two input models, decided at runtime:
    #   hook     - the form never activates; a low-level hook feeds the controls, so the
    #              window the user was typing in keeps the foreground, the focus and the
    #              caret. Closing only unhooks; nothing has to be restored.
    #   takeover - no hook (or an IME asked for a real focus): the panel activates, and the
    #              foreground is handed back on close.
    $script:PickerHook = $false
    $script:PickerEscalated = $false
    $script:ImeCheckAt = Get-Date; $script:ImeNative = $false
    # seed from the real button state: starting at $false would read a button the user is
    # already holding as a fresh click and close the panel on its first frame
    $script:PrevMouseDown = ([Cb.Win]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0
    # Non-modal on purpose: ShowDialog would block this message pump. The rounded region is
    # set before the first paint: doing it in Shown let one square frame through first,
    # which is the "incomplete" flash the panel used to have.
    try { $form.Region = New-RoundRegion $form.ClientSize.Width $form.ClientSize.Height (Px 8) } catch { }
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
      if ($am -ne 0 -and -not $form.IsDisposed) { try { if ($am -band 1) { foreach ($i in @($script:Anim.HoverIndex, $script:Anim.SelIndex, $script:Anim.PrevSelIndex)) { if ($i -ge 0 -and $i -lt $lst.ItemCount) { $lst.Invalidate($lst.GetItemRectangle($i)) } } }; if ($am -band 2) { $sbar.Invalidate() }; if ($am -band 4) { $grip.Invalidate() }; if ($am -band 8) { $box.Invalidate() } } catch { } }
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
        # a click outside dismisses it (Add_Deactivate never fires under the hook)
        $mouseDown = ([Cb.Win]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0
        if ($mouseDown -and -not $script:PrevMouseDown -and -not $form.Bounds.Contains([Windows.Forms.Cursor]::Position)) {
          Write-Log 'picker: dismissed by a click outside'
          $form.Close(); break
        }
        $script:PrevMouseDown = $mouseDown
      } elseif (-not $form.ContainsFocus -and ((Get-Date) - $script:ShownAt).TotalMilliseconds -gt 350) {
        # safety net for the takeover model: a click elsewhere dismisses the panel
        $fg = [Cb.Win]::GetForegroundWindow()
        if ($fg -ne $form.Handle -and $fg -ne $prev) { $form.Close(); break }
      }
      Start-Sleep -Milliseconds 12
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
    $tip.Dispose()
    try { if ($script:MeasureG) { $script:MeasureG.Dispose() } } catch { }
    $script:MeasureG = $null
    $cm.Dispose()
    $form.Dispose()
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
    $script:PickerOpen = $false
  }
}

# lib/panel/picker.ps1 - the history panel. One function owns the whole window lifecycle (create,
# filter, draw, keys, paste); the standalone pieces live in picker-geom / entry / plugins.

function Show-Picker([switch]$Warm, [switch]$Tray) {
  if ($script:PickerOpen) {
    # a second hotkey press closes the panel; a warm run only builds and throws away, so it
    # must leave a panel the user is working in alone
    if (-not $Warm) { $script:PickerClose = $true }
    return
  }
  # One modal window at a time in this process: the settings window runs a modal loop, and opening
  # the panel from inside that loop left two modal windows on one thread. A chord being recorded is
  # the one case where the window keeps the front - the keys belong to the row being set - so only
  # then does the request bring that window forward. Otherwise the window steps aside (minimised)
  # and the panel opens over it, which is what pressing the hotkey asked for; it comes back when
  # the panel closes.
  $script:PickerOverSettings = $false
  if ((Get-Command Test-SettingsWindowOpen -ErrorAction SilentlyContinue) -and (Test-SettingsWindowOpen)) {
    $recording = $false
    if (Get-Command Test-HotkeyRecordRequested -ErrorAction SilentlyContinue) {
      try { $recording = [bool](Test-HotkeyRecordRequested $script:StoreDir) } catch { $recording = $false }
    }
    if ($recording -or -not (Get-Command Hide-SettingsForPanel -ErrorAction SilentlyContinue)) {
      [void](Ring-SettingsAsk)
      return
    }
    $script:PickerOverSettings = [bool](Hide-SettingsForPanel)
    if (-not $script:PickerOverSettings) { [void](Ring-SettingsAsk); return }
  }
  # A settings window in another process may have saved a language since this process started:
  # the panel is drawn from the words in force when it opens, so read the code first, and rebuild
  # the faces when it changed - a language may name its own font family. Nothing restarts.
  if ((Get-Command Sync-UiLanguage -ErrorAction SilentlyContinue) -and (Sync-UiLanguage)) {
    $script:UiFamily = ''
    $script:FBody = $null
    [void](Initialize-PanelFonts)
  }
  # The palette follows the file as well, and so does the family a theme names: a theme saved by a
  # settings window in another process was drawn with the colours and faces this process started
  # with. Reading it costs one ini key, and the faces are rebuilt only when it moved.
  if ((Get-Command Sync-UiTheme -ErrorAction SilentlyContinue) -and (Sync-UiTheme)) {
    $script:UiFamily = ''
    $script:FBody = $null
    [void](Initialize-PanelFonts)
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
    # The type ramp and the icon face are resolved once and shared with the settings window, so
    # the two can never end up on different families or sizes.
    [void](Initialize-PanelFonts)
    $prev = [Cb.Win]::GetForegroundWindow()
    # A click on the tray icon arrives from a topmost window of explorer, not from the window the
    # user was working in: that chain is walked down to the first window that belongs to somebody
    # else, and the "cannot be covered" check below does not apply to it - the shell's own tray
    # is exactly the window the panel is meant to open over.
    if ($Tray) {
      $prev = Get-UsableForeground $prev
      Write-Log ('picker: tray open from ' + (Format-ForegroundWindow $prev))
    }
    # A window in the UIAccess band cannot be covered by any topmost window, so a panel opened
    # over it is invisible while its hook swallows the keys meant for it. Ditto closes that
    # window instead of giving up, and so does this: Escape it away, then open over what is
    # behind it. A window that is not the shell's own flyout is left alone - closing somebody
    # else's window is not this tool's business, so the panel stays closed.
    if (-not $Warm -and -not $Tray -and (Test-UncoverableWindow $prev)) {
      # the hotkey arrives while Ctrl and Alt are still held, and Escape with them down is a
      # different key that the flyout ignores
      try { Release-HeldModifiers } catch { }
      # closing search can reveal the Start menu it was opened from, so this repeats a few times
      $tries = 0
      while ($tries -lt 3 -and (Test-ShellFlyout $prev)) {
        $tries++
        if (-not (Close-ShellFlyout $prev)) { break }
        Write-Log ('picker: closed the flyout in front (it cannot be covered): ' + (Format-ForegroundWindow $prev))
        $prev = [Cb.Win]::GetForegroundWindow()
      }
      if (Test-UncoverableWindow $prev) {
        Write-Log ('picker: not opened (the window in front cannot be covered): ' + (Format-ForegroundWindow $prev))
        $script:PickerOpen = $false
        return
      }
    }
    # the control that owns the keyboard there: restored when the panel hands the foreground
    # over (an input method) and after the paste that follows a pick
    $script:PrevFocus = Save-TargetFocus $prev
    # the caret that control was showing: taking the foreground makes some editors drop their
    # selection, and then the paste would land at the start of the field instead of where the
    # user was typing. Cloned ranges are put back just before the keys go out. The warm-up opens
    # and closes the same window to pay for the first fonts and palette, has no target of its
    # own, and its answer would land in the same slot as a real open right after it.
    $script:SavedSel = @()
    if (-not $Warm) {
      try { $script:SavedSel = @(Save-UiaSelection $prev $script:PrevFocus) } catch { $script:SavedSel = @() }
      if ($script:SavedSel.Count -gt 0) { Write-Log ('selection saved: ' + $script:SavedSel.Count + ' range(s)') }
    }
    # the rows arrive through the history store, which reads the channel once and keeps the
    # array: the query caches below compare one read with the next by reference
    $script:History = Use-UiStore 'history'
    $script:Entries = @($script:History.Refresh())
    if ($script:Entries.Count -eq 0) { Write-Log 'picker: empty (showing hint)' }
    $msRecords = [int]$swOpen.ElapsedMilliseconds

    $ui = Get-UiPalette
    $fBody = $script:FBody; $fSmall = $script:FSmall; $fTiny = $script:FTiny
    $fTitle = $script:FTitle; $fIcon = $script:FIcon; $fIconSmall = $script:FIconSmall; $fIconBig = $script:FIconBig
    $fIconTiny = $script:FIconTiny
    $script:Hover = -1
    $script:Anim = New-AnimState
    $script:Confirm = $false
    $script:CtrlHeld = $false
    $script:SearchFocus = $false
    # when the drawn caret last changed state, so the loop can blink it without a timer
    $script:CaretPulse = Get-Date
    # the selection the drawn caret currently sits at, so a key that only moves it is noticed
    $script:CaretIndex = -1
    # how many times the system caret was hidden and not given back yet. HideCaret counts, and
    # a caret that stays hidden is what an input method needs to see: the candidate window is
    # placed at it, and nothing in the control brings it back.
    $script:SysHides = 0
    # which end of a selection the caret is at: -1 the start, +1 the end, 0 no selection of its
    # own. The control keeps start and length but not the end the keyboard moved last.
    $script:CaretEnd = 0
    # the panel holds the foreground from Show() until something else takes it. Closing it has
    # to give the foreground back only in the first case - a panel dismissed by a click has
    # already handed it over.
    $script:OwnFront = $false
    # set while a paste moves the foreground to its target: losing the activation there is part
    # of the paste, not a dismissal
    $script:Pasting = $false
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
    # the panel activates; its preview cards keep the no-activate form
    $form.Activates = $true
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'Manual'
    # no TopMost property: assigning it makes WinForms call SetWindowPos without
    # SWP_NOACTIVATE, which activates the panel; it is raised right after Show() instead.
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.Text = (Get-UiText 'panel.title')
    $form.AccessibleName = (Get-UiText 'panel.title')
    # Where the panel opens is decided before any control exists, because both its size and its
    # place come out of the same question. Two shapes ask it differently:
    #
    #   compact - at the caret, below the line, flipping above when the monitor ends first, with
    #             the rows cut to the room on that side (Get-CompactPlacement)
    #   full    - never at the caret: a remembered position, otherwise the centre of the screen
    #             the pointer is on (Get-PickerBounds)
    $areas = @()
    try { foreach ($sc in [Windows.Forms.Screen]::AllScreens) { $areas += $sc.WorkingArea } } catch { }
    $pointerArea = $null
    try { $pointerArea = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea } catch { }
    if (-not $pointerArea) { try { $pointerArea = [Windows.Forms.Screen]::FromHandle($prev).WorkingArea } catch { } }
    if (-not $pointerArea -and $areas.Count -gt 0) { $pointerArea = $areas[0] }
    if (-not $pointerArea) { $pointerArea = New-Object Drawing.Rectangle -ArgumentList @(0, 0, (Px $preset.Width), (Px 200)) }
    $rowH = Px (Get-PanelRowHeight)
    $chrome = Px (Get-PresetChrome $preset)
    $minRows = [int]$script:IniSchema[$rowsKey].Minimum
    $caretBox = $null
    if ($preset.AnchorCaret -and $prev -ne [IntPtr]::Zero) {
      try {
        $c = Get-CaretAnchor $prev
        if ($null -ne $c -and $c.Width -gt 0 -and $c.Height -gt 0) {
          $caretBox = $c
          Write-Log ('picker: anchor=' + $script:CaretSource + ' at ' + $c.Left + ',' + $c.Top + ' ' + $c.Width + 'x' + $c.Height)
        } else { Write-Log ('picker: anchor=' + $script:CaretSource) }
      } catch { $caretBox = $null; Write-Log ('picker: anchor failed: ' + $_.Exception.Message) }
    }
    $place = $null
    if ($null -ne $caretBox) {
      $area = Get-AreaAt $areas $pointerArea ([int]$caretBox.Left) ([int]$caretBox.Top)
      $place = Get-CompactPlacement $preset.Rows $rowH $chrome (Px $preset.Width) $area ([int]$caretBox.Left) ([int]$caretBox.Top) ([int]$caretBox.Height) $minRows
      if ($place.Rows -ne $preset.Rows) { Write-Log ('picker: rows ' + $preset.Rows + ' -> ' + $place.Rows + ' beside the caret') }
    } else {
      $fitRows = Get-RowsForScreen $preset.Rows ([int]$pointerArea.Height) $rowH $chrome $minRows
      if ($fitRows -ne $preset.Rows) { Write-Log ('picker: rows ' + $preset.Rows + ' -> ' + $fitRows + ' to fit this screen') }
      $place = @{ Rows = $fitRows; Width = (Px $preset.Width); Height = (Get-PanelHeight $fitRows $rowH $chrome) }
    }
    $form.Width = [int]$place.Width
    $form.Height = [int]$place.Height
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
    $lst.AccessibleName = (Get-UiText 'panel.accEntries')

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
            $cy = $cy + (Draw-EmptyGlyph $g $script:EmptyGlyph $fIconBig $gb $w $cy (Px 4))
            $gb.Dispose()
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
    $empty.Add_Click({ $txt.Focus() })

    # A thin rounded thumb is painted instead, brightening on hover. The panel is wider than the
    # bar it draws: three pixels is what the design asks for, and a mouse cannot be trusted to
    # land on three pixels, so the hit area is twelve and the bar stays centred in it.
    $sbar = New-Object Windows.Forms.Panel
    $sbar.Dock = 'Right'
    $sbar.Width = Px 12
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
    # an empty piece of the header is still "the search area": clicking it puts the keyboard
    # into the filter
    $head.Add_Click({ $txt.Focus() })

    $box = New-Object Windows.Forms.Panel
    $box.SetBounds((Px 14), (Px $boxTop), ($form.ClientSize.Width - (Px 30)), (Px 40))
    $box.BackColor = $ui.Field
    $box.Add_Click({ $txt.Focus() })
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
    $icon.Add_Click({ $txt.Focus() })

    $txt = New-Object Windows.Forms.TextBox
    $txt.BorderStyle = 'None'
    $txt.SetBounds((Px 38), (Px 10), ($box.Width - (Px 80)), (Px 22))
    $txt.BackColor = $ui.Field
    $txt.ForeColor = $ui.Text
    $txt.Font = $fBody
    $txt.AccessibleName = (Get-UiText 'panel.search')
    # Not a tab stop: a form gives the focus to its first tabbable control when it is shown,
    # and that would put the keyboard - and a caret - in the filter row for one frame before
    # the list takes it. The list is where the panel starts; the box is reached by typing.
    $txt.TabStop = $false

    $ph = New-Object Windows.Forms.Label
    # the same left edge as the text the box will hold, so the caret of an empty field and the
    # hint next to it start at one line
    $ph.SetBounds((Px 38), (Px 10), ($box.Width - (Px 104)), (Px 22))
    $ph.Text = (Get-UiText 'panel.search')
    $ph.Font = $fBody
    $ph.ForeColor = $ui.Faint
    $ph.BackColor = $ui.Field
    $ph.TextAlign = 'MiddleLeft'
    $ph.Cursor = 'IBeam'
    # the placeholder covers the empty box, so this is what a click on an empty search field
    # actually hits - and a label never takes the keyboard itself
    $ph.Add_Click({ $txt.Focus() })

    $clr = New-Object Windows.Forms.Label
    $clr.SetBounds(($box.Width - (Px 30)), (Px 10), (Px 20), (Px 22))
    $clr.Text = $(if ($script:IconFamily) { [string][char]0xE8BB } else { 'x' })
    # the glyph only exists in the icon font - with the text font it renders as a box
    $clr.Font = $(if ($script:IconFamily) { $fIconTiny } else { $fSmall })
    $clr.ForeColor = $ui.Dim
    $clr.BackColor = $ui.Field
    $clr.TextAlign = 'MiddleCenter'
    $clr.Cursor = 'Hand'
    $clr.Visible = $false
    $clr.AccessibleName = (Get-UiText 'panel.accClearSearch')
    $clr.Add_MouseEnter({ $clr.ForeColor = $ui.Text })
    $clr.Add_MouseLeave({ $clr.ForeColor = $ui.Dim })

    # The field draws its own caret in the theme colour: the system one cannot be tinted, so it
    # is hidden and this one pixel panel stands in for it, following the selection and blinking
    # from the panel loop. The selection itself is the control's own - it has the real focus.
    $caret = New-Object Windows.Forms.Panel
    $caret.SetBounds((Px 38), (Px 14), (Px 1), (Px 16))
    $caret.BackColor = $ui.Accent
    $caret.Cursor = 'IBeam'
    $caret.Visible = $false
    $caret.AccessibleName = (Get-UiText 'panel.accCaret')
    $caret.Add_Click({ $txt.Focus() })

    $line = New-Object Windows.Forms.Panel
    $line.Dock = 'Bottom'
    $line.Height = 1
    $line.BackColor = $ui.Border

    $box.Controls.Add($icon)
    $box.Controls.Add($txt)
    $box.Controls.Add($clr)
    $box.Controls.Add($ph)
    $box.Controls.Add($caret)
    $ph.BringToFront()
    $caret.BringToFront()
    $head.Controls.Add($box)
    $head.Controls.Add($line)

    $form.Controls.Add($listHost)
    $form.Controls.Add($sbar)
    $form.Controls.Add($foot)
    $form.Controls.Add($head)
    # The functions that run while the panel is up live at file scope (lib\panel\picker-live.ps1),
    # so their bodies are compiled once per process instead of once per open. They read the
    # controls from here; nothing else in this function changes hands.
    $script:PanelForm = $form
    $script:PanelList = $lst
    $script:PanelHost = $listHost
    $script:PanelBar = $sbar
    $script:PanelHead = $head
    $script:PanelFoot = $foot
    $script:PanelFootL = $footL
    $script:PanelFootR = $footR
    $script:PanelBox = $box
    $script:PanelTxt = $txt
    $script:PanelPh = $ph
    $script:PanelClr = $clr
    $script:PanelCaret = $caret
    $script:PanelBoxTop = $boxTop
    $msWidgets = [int]$swOpen.ElapsedMilliseconds

    # the compact panel was placed against the caret; everything else takes the remembered
    # position, or the centre of the screen the pointer is on
    if ($null -ne $place -and $null -ne $place.Left) {
      $form.Left = [int]$place.Left
      $form.Top = [int]$place.Top
    } else {
      # a saved position belongs to the full panel: the compact one is placed on every open
      $savedLeft = $(if ($preset.Mode -eq 'compact') { '' } else { [string]$script:WinLeft })
      $savedTop = $(if ($preset.Mode -eq 'compact') { '' } else { [string]$script:WinTop })
      $pb = Get-PickerBounds $form.Width $form.Height $savedLeft $savedTop $areas $pointerArea
      $form.Left = [int]$pb.Left
      $form.Top = [int]$pb.Top
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

    # The wheel step is a property of the panel rather than of the mouse, so Sync-Sb sets it
    # from the rows on screen; ScrollLines overrides it. The control carries the fraction of a
    # notch between events, which is what a precision touchpad sends.
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
    # every way the list can scroll (wheel, drag, keys, selection) has to move the thumb, and
    # none of them may leave the selection behind off screen
    $lst.Add_ScrollChanged({ Sync-Sb; Keep-SelectionInView; Sync-HoverFromCursor })

    # the list scrolls itself on the wheel; with the pointer anywhere else it bubbles here
    $form.Add_MouseWheel({
        param($s, $e)
        $lst.WheelBy($e.Delta)
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
          # pressing the thumb starts a drag at the pixel that was grabbed
          $script:SbDrag = $e.Y - $script:SbTop
          $sbar.Capture = $true
        } else {
          # pressing the track pages toward the click, the way a fluent scrollbar does, instead
          # of dropping the view somewhere the user did not aim at
          if ($e.Y -lt $script:SbTop) { Scroll-By (-(Get-PageRows)) } else { Scroll-By (Get-PageRows) }
        }
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

    # The assembly answers the plain scan (Cb.Search). A run without it - the fallback that
    # compiles the .cs at run time has the class too, so this is only for a stripped copy -
    # keeps the readable path, which answers the same thing more slowly.
    $script:SearchType = $null
    try { $script:SearchType = [Cb.Search] } catch { $script:SearchType = $null }

    function Update-List([string]$q) {
      $swUp = [Diagnostics.Stopwatch]::StartNew()
      $lst.BeginUpdate()
      try {
        # compiled in lib/query.ps1; highlight still works on plain words only
        $query = New-Query -Line $q
        $tokens = @($query.Terms)
        $script:Tokens = $tokens
        # sticky pins: the plugin names the mark and the cap, the base decides how many rows
        # actually fit - see Get-StickyPlan / Get-StickyTopRows in lib/ordering.ps1. The
        # runtime is there in every run that draws a panel, so the call is made directly: a
        # missing command is the only case that means "no plan", and Get-Command per keystroke
        # cost more than the call itself
        $plan = $null
        try { $plan = Get-PluginStickyPlan (Get-Rows) } catch [System.Management.Automation.CommandNotFoundException] { $plan = $null }
        if ($null -eq $plan) { $plan = @{ Mark = ''; Max = 0 } }
        # The rows: plain words go to the assembly, where the scan costs no PowerShell loop at
        # all; its heads are built once per store snapshot (a pin or a delete replaces the
        # array), never per keystroke. Everything else keeps the readable path in lib\query.ps1.
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
      Sync-SearchCaret
      $lst.Invalidate()
      Sync-Sb
      Restore-Foot
      # A filter that took long enough to feel leaves a line: the row count says whether the
      # cost is the store or the list it fed, which is the first question a slow search asks
      $msUp = [int]$swUp.Elapsed.TotalMilliseconds
      if ($msUp -ge 40) { Write-Log ('picker: filter ' + $msUp + ' ms (' + $script:Labels.Count + ' of ' + @($script:Entries).Count + ' rows)') }
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

    # Put the cloned selection back, once. Editors that reset their selection when they lose the
    # foreground get the caret back this way, both before a paste and when the panel closes.
    function Put-BackSelection([string]$why = '') {
      if (@($script:SavedSel).Count -le 0) { return }
      $back = 0
      try { $back = Restore-UiaSelection $script:SavedSel } catch { $back = 0 }
      Write-Log ('selection restored=' + $back + $why)
    }

    function Paste-Clip([string]$TypedText = '', [int]$ClipMs = 0) {
      # every step of a paste is a wait the user can feel, and which one it is cannot be told
      # from a screenshot: one line per paste carries the milliseconds of each stage
      $pasteSw = [Diagnostics.Stopwatch]::StartNew()
      $target = Get-PasteTarget
      Write-Log ('paste target: ' + (Format-PasteTarget $target))
      if ($script:NoPaste) { Close-Panel; return }
      # An elevated window ignores keys sent by a process that is not, and the failure says
      # nothing: nothing arrives and nothing throws. Say so instead of reporting a paste that
      # never happened.
      if (Test-ElevatedTarget $target) {
        Write-Log 'paste skipped: the target window runs elevated'
        Set-Foot (Get-UiText 'panel.foot.copiedAdmin') ([int]$script:Timing['FootMessage'])
        return
      }
      # the hotkey is usually still held when the panel opens: pasting now would send
      # Ctrl+V with Alt/Ctrl down and land as something else entirely
      while ($pasteSw.ElapsedMilliseconds -lt $script:ModReleaseTimeout) {
        if (Test-Modifiers-Up) { break }
        Start-Sleep -Milliseconds 10
      }
      $modMs = [int]$pasteSw.ElapsedMilliseconds
      # waiting only works when the key is let go of soon: a modifier that is still down when
      # the wait ends is released, so the paste cannot arrive as another shortcut
      if (-not (Test-Modifiers-Up)) { Release-HeldModifiers }
      # SetForegroundWindow can be refused by the foreground lock and SendKeys types into
      # whatever is in front, so the target has to have the front. The panel holds it while it
      # is open, so this is the step that moves it back - and losing the activation here is part
      # of the paste, which is what $script:Pasting tells the Deactivate handler.
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
        # the window is back but its caret may not be: give the control the keyboard again, and
        # only when it lost it - AttachThreadInput plus SetFocus is another way to raise a window.
        # Only the window the panel came from has a remembered control; after a switch the caret
        # already sits where the user left it.
        if ($target -eq $prev -and $script:PrevFocus -ne [IntPtr]::Zero) {
          $hasFocus = $false
          try { $hasFocus = ([Cb.Win]::FocusOfWindow($target) -eq $script:PrevFocus) } catch { $hasFocus = $false }
          if (-not $hasFocus) { [void](Restore-TargetFocus $target $script:PrevFocus) }
        }
        # the window needs a moment before it takes the keyboard again: a chord sent inside that
        # gap is dropped without an error. After a page key moved the list the gap is longer, and
        # 30 ms lost one pick in three on Chromium 76 while 80 ms lost none.
        Start-Sleep -Milliseconds $script:PasteSettle
        $focusMs = [int]$frontSw.ElapsedMilliseconds
        # The foreground can move again while the panel settles (another window, a shell flyout),
        # and the keys would go into whatever is in front by then: Ditto re-checks the target at
        # this point too, and its log marks the case "paste timing around activate target".
        try {
          if ([Cb.Win]::GetForegroundWindow() -ne $target) {
            Write-Log 'paste: the foreground moved before the keys, taking it back'
            [void](Take-Foreground $target)
          }
        } catch { }
        # an editor that dropped its selection when the panel took the foreground gets the caret
        # back here, before the keys: only for the window the panel came from, because after an
        # Alt+Tab the caret already sits where the user left it in the other window
        if ($target -eq $prev) { Put-BackSelection }
        # the target moves the caret itself once the text is in, so the close that follows must
        # not select the old range again - that put the caret back in front of what was pasted
        $script:SavedSel = @()
        # The keys go out before the panel is hidden: hiding the active window first lets Windows
        # pick the next window in the z-order, and taking the front back afterwards is exactly
        # what reads as "the window I had focused before flashes up".
        if ($TypedText -ne '') {
          # typing lands in the focused control through SendInput: no clipboard and no paste
          # key, which is what a target that ignores Ctrl+V needs
          $keysSw = [Diagnostics.Stopwatch]::StartNew()
          $sent = 0
          try { $sent = [Cb.Win]::SendUnicode($TypedText) } catch { Write-Log ('typing failed: ' + $_.Exception.Message) }
          Write-Log ('typed ' + $sent + ' of ' + $TypedText.Length + ' characters')
        } else {
          $keysSw = [Diagnostics.Stopwatch]::StartNew()
          # SendKeys builds its modifier from a virtual key with no scan code, and an input
          # method can answer that with VK_PROCESSKEY: the chord then lands as a bare letter
          # and nothing is pasted (measured on Chromium 76, once in about ten opens). One chord
          # is sent as the physical key instead; a sequence or a repeat still needs SendKeys.
          $chord = $false
          try { $chord = Send-PasteChord $PasteKeys } catch { $chord = $false }
          if (-not $chord) {
            Write-Log 'paste keys: SendKeys (not a single chord)'
            try { [Windows.Forms.SendKeys]::SendWait($PasteKeys) } catch { Write-Log ('sendkeys fail: ' + $_.Exception.Message) }
          }
        }
        Write-Log ('paste: ' + [int]$pasteSw.ElapsedMilliseconds + ' ms (clip ' + $ClipMs + ', mod ' + $modMs + ', focus ' + $focusMs + ', settle ' + [int]$script:PasteSettle + ', keys ' + [int]$keysSw.ElapsedMilliseconds + ')')
        try {
          $after = [Cb.Win]::GetForegroundWindow()
          if ($after -ne $target) { Write-Log ('paste: the foreground changed while the keys were sent (' + (Format-WindowName $after) + ')') }
        } catch { }
        $form.Hide()
        # the panel leaving can still move the foreground; the paste is already done, so this
        # only puts the user back where they were
        if ([Cb.Win]::GetForegroundWindow() -ne $target) {
          $moved = [Cb.Win]::GetForegroundWindow()
          Write-Log ('paste: the foreground moved after the panel hid (' + (Format-WindowName $moved) + '), taking it back')
          [void](Take-Foreground $target)
        }
      } finally {
        $script:Pasting = $false
      }
      $form.Close()
    }

    # Closing from inside the panel. The panel holds the foreground, so hiding it hands the front
    # to whatever is next in the z-order: the window it came from has to be asked for by name,
    # together with the control that owned the caret there.
    function Close-Panel {
      # Hiding the panel is what takes the activation away, and the Deactivate handler reads that
      # as a dismissal and clears the flag - so whether the foreground has to be handed back is
      # decided before the window goes, not after it.
      $handBack = ($script:OwnFront -and $prev -ne [IntPtr]::Zero)
      try { $form.Hide() } catch { }
      if ($handBack) {
        try { [void][Cb.Win]::SetForegroundWindow($prev) } catch { }
        try { [void](Restore-TargetFocus $prev $script:PrevFocus) } catch { }
        # the window that was typing gets its caret back too: some editors drop the selection
        # when they lose the foreground, and a closed panel must not move the caret either
        Put-BackSelection ' (panel closed)'
        $script:SavedSel = @()
      }
      try { $form.Close() } catch { }
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
      # the program in front decides whether the formatting travels with the paste:
      # a terminal wants the text, an editor wants the layout. The window asked about is the
      # one the paste goes back to - the panel itself may be in front after a hand-over.
      if ($rich -and -not (Test-AppRuleKeepsRich $pasteTo)) { $rich = '' }
      $clipSw = [Diagnostics.Stopwatch]::StartNew()
      $okClip = Set-ClipItem $payload $rich
      $clipMs = [int]$clipSw.ElapsedMilliseconds
      if (-not $okClip) { Write-Log 'set clipboard failed'; Close-Panel; return }
      # our own write must not come back as a new capture
      Set-LastCapture $payload
      # PasteTyping=1 skips the paste key. Only plain text can be typed: a file list and a
      # picture still need the clipboard.
      $typed = ''
      if ($script:PasteTyping -and $rich -eq '' -and -not (Test-FilePayload $payload) -and -not (Test-ImagePayload $payload)) { $typed = $payload }
      Paste-Clip -TypedText $typed -ClipMs $clipMs
    }

    function Del-Index([int]$idx) {
      if ($idx -lt 0 -or $idx -ge $script:Filtered.Count) { return }
      $victim = $script:Filtered[$idx]
      $removed = Remove-Record $victim.Payload
      if ($removed -like 'protected:*') {
        # only the plugin that declared the mark knows how to remove it
        $pm = $removed.Substring(10)
        $info = Get-MarkInfo $pm
        $word = Get-MarkUiWord $pm
        if ($info -and $info.Unset) {
          $hint = [string]$info.Hint
          $unset = [string]$info.Unset
          if ($hint) { Set-Foot (Get-UiText 'panel.foot.markHint' @($word, $hint, $unset)) ([int]$script:Timing['FootWarn']) }
          else { Set-Foot (Get-UiText 'panel.foot.markNoHint' @($word, $unset)) ([int]$script:Timing['FootWarn']) }
        } else {
          Set-Foot (Get-UiText 'panel.foot.markNoPlugin' @($word, $pm)) ([int]$script:Timing['FootWarn'])
        }
        return
      }
      if ($removed -eq 'removed') {
        if ($script:UndoOn) { $script:UndoRec = $victim; $script:UndoIdx = $idx }
      }
      $script:Entries = @($script:History.Refresh())
      if ($removed -eq 'removed') { Write-Log ('deleted entry (' + $victim.Payload.Length + ' chars), left ' + $script:Entries.Count) }
      Update-List $txt.Text
      if ($script:Filtered.Count -gt 0) { $lst.SelectedIndex = [Math]::Min($idx, $script:Filtered.Count - 1) }
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
      Update-List $txt.Text
      Set-Foot (Get-UiText 'panel.foot.restored') ([int]$script:Timing['FootInfo'])
    }

    function Cancel-Confirm {
      $confirmTimer.Stop()
      if (-not $script:Confirm) { return }
      $script:Confirm = $false
      Restore-Foot
    }

    function Request-Clear {
      if ($script:Entries.Count -eq 0) { Set-Foot (Get-UiText 'panel.foot.nothingToClear') ([int]$script:Timing['FootShort']); return }
      $script:Confirm = $true
      $footTimer.Stop()
      $script:FootMode = 'confirm'
      if (@(Get-ClearKeepMarks).Count -gt 0) { $script:FootMsg = Get-UiText 'panel.foot.confirmClearKept' }
      else { $script:FootMsg = Get-UiText 'panel.foot.confirmClearAll' }
      $footL.Invalidate()
      $confirmTimer.Stop()
      $confirmTimer.Start()
    }

    function Clear-All {
      $script:Confirm = $false
      $confirmTimer.Stop()
      Clear-Store (Get-ClearKeepMarks)
      $script:Entries = @($script:History.Refresh())
      Write-Log ('history cleared from the panel, left ' + $script:Entries.Count + ' rows')
      Update-List $txt.Text
      $kept = @(Get-MarkUiCount $script:Entries)
      if ($kept.Count -gt 0) { Set-Foot (Get-UiText 'panel.foot.clearedKept' @($kept -join ', ')) ([int]$script:Timing['FootWarn']) }
      else { Set-Foot (Get-UiText 'panel.foot.cleared') ([int]$script:Timing['FootInfo']) }
    }

    # The row menu is the tray menu's twin: the same skin, the same rounded rows and the same
    # hairline separators. lib/panel/tray-menu.ps1 owns the layout and the row helpers, and
    # Cb.TrayMenu paints it (lib/assembly/cb.native.cs), so a right click beside the panel does
    # not open a window drawn in the system colours.
    $cmSkin = New-TrayMenuSkin (Px 252)
    $cm = New-Object Cb.TrayMenu -ArgumentList $cmSkin
    # Rows are rebuilt per opening, so the menu only knows its final height once it has opened: it
    # places itself, or it comes up covering the pointer on the rows near the bottom edge. The rule
    # and its wiring are shared with any other menu that has to place itself (New-TrayMenuPlacer).
    $cm.Placer = New-TrayMenuPlacer
    # The popup must not take the foreground: that deactivates the window the user came from,
    # and Explorer's address bar / search box collapse - the paste then lands in the file view.
    [void]$cm.Handle
    [void][Cb.Win]::SetWindowLong($cm.Handle, -20, ([Cb.Win]::GetWindowLong($cm.Handle, -20) -bor 0x08000000))
    # the glyphs the panel already draws with (Segoe Fluent Icons, Segoe MDL2 Assets as fallback)
    $menuGlyph = @{
      Paste  = [string][char]0xE77F
      Copy   = [string][char]0xE8C8
      Edit   = [string][char]0xE70F
      Delete = [string][char]0xE74D
      # one code point for both menus: the tray menu's own table is the one that decides it
      Clear  = [string](Get-TrayGlyphs).Clear
    }
    # The rows are rebuilt for the row under the pointer, in one helper: the menu hides the
    # actions that do not apply and names each plugin over its own group, and rebuilding is what
    # keeps the strip's layout right - a row that was hidden once never gets its place back.
    function Fill-RowMenu($cur) {
      $has = ($null -ne $cur)
      foreach ($old in @($cm.Items)) { try { $old.Dispose() } catch { } }
      $cm.Items.Clear()

      $paste = New-TrayMenuRow -Skin $cmSkin -Label (Get-UiText 'menu.paste') -Glyph $menuGlyph.Paste
      $paste.Hint = 'Enter'
      $paste.Enabled = $has
      # the primary action carries the accent on its glyph, the way a Fluent menu marks the one
      # row a press is usually meant for
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
      # the destructive row starts its own block: a separator row, not a line inside the row, so
      # the air above the line and below it is the same as everywhere else in the menu
      [void](Add-TrayMenuSeparator $cm $cmSkin)
      [void]$cm.Items.Add($clear)
      $clear.Add_Click({ Request-Clear })

      # plugin actions: one group per plugin, in load order, with a header that names it. Only
      # the actions whose Test passes for this row are built, so nothing has to be hidden later.
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
              # After = 'paste': the action put its result on the clipboard and wants
              # it pasted into the window the picker came from (transform does this)
              if ($a.ContainsKey('After') -and [string]$a['After'] -eq 'paste') { Paste-Clip }
              else { Update-List $txt.Text }
            } catch { Write-Log ('plugin action failed: ' + $_.Exception.Message) }
          })
        [void]$cm.Items.Add($row)
      }
      $cm.Fit()
    }
    # a placeholder fill so the strip has its real height before the first open: the drop-down
    # positions itself from the size it has then
    Fill-RowMenu $null

    # right click acts on the row under the cursor, never on a stale selection: the menu is built
    # for that row every time it opens, so the actions that do not apply are never in it at all
    $cm.Add_Opening({
        try {
          $pt = $lst.PointToClient([Windows.Forms.Cursor]::Position)
          $i = $lst.IndexFromPoint($pt)
          if ($i -ge 0 -and $i -lt $script:Filtered.Count) { $lst.SelectedIndex = $i } else { $lst.SelectedIndex = -1 }
          $cur = $null
          if ($lst.SelectedIndex -ge 0 -and $lst.SelectedIndex -lt $script:Filtered.Count) { $cur = $script:Filtered[$lst.SelectedIndex] }
          Fill-RowMenu $cur
        } catch { Write-Log ('row menu failed: ' + $_.Exception.Message) }
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
        $offset = Get-VisibleRowOffset $e.Index $lst.TopIndex $lst.PinnedCount
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
            Draw-UiGlyph $g ([string]$mk.Glyph) $fIconSmall $mkBrush $mkRect $sfCenter
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
          Draw-UiGlyph $g $rowGlyph $fIcon $glyphBrush $glyphRect $sfCenter
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
    $lst.Add_MouseUp({ param($s, $e) if ($e.Button -eq 'Left') { Sync-Sb } })

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
    Set-PickerEditHost $form $lst $txt $ui $fBody { param($q) Update-List $q } { param($m, $ms) Set-Foot $m ([int]$ms) } { param($t) $t.Focus() }
    function Flush-List { if ($deb.Enabled) { $deb.Stop(); Update-List $txt.Text } }
    $txt.Add_TextChanged({ $script:CaretEnd = 0; Sync-Placeholder; Sync-SearchCaret; $deb.Stop(); $deb.Start() })
    $txt.Add_GotFocus({ $script:SearchFocus = $true; $script:SysHides = 0; Set-AnimTarget $script:Anim 'Field' 1.0; $box.Invalidate(); Sync-SearchCaret })
    $txt.Add_LostFocus({ $script:SearchFocus = $false; $script:CaretEnd = 0; Set-AnimTarget $script:Anim 'Field' 0.0; $box.Invalidate(); Sync-SearchCaret })
    # The filter row is not where the panel starts, so the first character typed while the list
    # has the keyboard opens it: the focus moves to the box, and the character it was going to
    # receive is put in at the end.
    $form.Add_KeyPress({
        param($s, $e)
        if ($null -ne $script:EditRow -or $txt.Focused) { return }
        $ch = $e.KeyChar
        if ([char]0 -eq $ch -or [char]::IsControl($ch)) { return }
        Start-Search
        $txt.SelectedText = [string]$ch
        $e.Handled = $true
      })
    # Which end of a selection the keyboard is moving: the control keeps start and length but
    # not the end, and the drawn caret has to follow the end that moved.
    $form.Add_KeyDown({
        param($s, $e)
        if (-not $txt.Focused) { return }
        if ($e.Shift) {
          if ($e.KeyCode -eq 'Left' -or $e.KeyCode -eq 'Home') { $script:CaretEnd = -1 }
          elseif ($e.KeyCode -eq 'Right' -or $e.KeyCode -eq 'End') { $script:CaretEnd = 1 }
        } else { $script:CaretEnd = 0 }
      })
    $clr.Add_Click({ $txt.Text = ''; $txt.Focus() })
    $form.Add_KeyDown({
        param($s, $e)
        # The editor owns the keyboard while it is open. KeyPreview runs this handler before
        # the focused control, so without this guard Ctrl+A / Del / Ctrl+Z would act on the
        # history instead of the text being edited.
        if ($null -ne $script:EditRow) { return }
        $code = [int]$e.KeyCode
        # Home and End belong to the text once the filter has the keyboard: they move the caret
        # there, and the list keeps them only while it is the one being navigated
        if ($txt.Focused -and ($e.KeyCode -eq 'Home' -or $e.KeyCode -eq 'End')) { return }
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
          elseif ($lst.SelectedIndex -ge 0) { Use-Index $lst.SelectedIndex -NoInject } else { Set-Foot (Get-UiText 'panel.foot.nothingToCopy') ([int]$script:Timing['FootShort']) }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.Control -and (($code -ge 48 -and $code -le 57) -or ($code -ge 96 -and $code -le 105))) {
          $n = $code
          if ($n -ge 96) { $n = $n - 96 } else { $n = $n - 48 }
          Flush-List
          $idx = Get-QuickKeyIndex (Get-QuickKeyOffset $n) $lst.TopIndex $script:Filtered.Count (Get-Rows) $lst.PinnedCount
          if ($idx -ge 0) { Use-Index $idx } else { Set-Foot (Get-UiText 'panel.foot.noEntry') ([int]$script:Timing['FootBrief']) }
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
              $script:Entries = @($script:History.Refresh())
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
          Page-Selection (Get-PageRows)
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'PageUp') {
          Page-Selection (-(Get-PageRows))
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Up') {
          if ($lst.SelectedIndex -gt 0) { $lst.SelectedIndex-- }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Down') {
          if ($lst.SelectedIndex -lt $lst.ItemCount - 1) { $lst.SelectedIndex++ }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Enter') {
          Flush-List
          if ($lst.SelectedIndex -ge 0) { Use-Index $lst.SelectedIndex } else { Set-Foot (Get-UiText 'panel.foot.nothingToPaste') ([int]$script:Timing['FootShort']) }
          $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Escape') {
          if ($txt.Text.Length -gt 0) {
            $txt.Text = ''
            Flush-List
          } else {
            # the panel still has the foreground, so closing it this way has to hand both the
            # window and the caret back - a plain Close() skipped both
            Close-Panel
          }
        } elseif ($e.KeyCode -eq 'Delete') {
          Flush-List
          if ((Get-SelectionCount $script:Sel) -gt 1) {
            # one write for the whole set, then the list rebuilds from the store
            $note = Invoke-SelectionDelete $script:Sel $script:Filtered
            Sync-Selection $script:Sel $lst
            $script:Entries = @($script:History.Refresh())
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
    # ---- the keyboard the panel holds -----------------------------------------
    # The panel activates like any other window, so nothing has to be posted into its controls:
    # the list starts with the keyboard (no caret in the filter row until the user types), the
    # first printable character moves the focus to the search field, and a click anywhere in the
    # search area moves it there too.
    function Start-Search {
      if ($null -ne $script:EditRow) { return }
      if (-not $txt.Focused) { $txt.Focus() }
      $txt.SelectionStart = $txt.TextLength
      $script:CaretEnd = 0
      Sync-SearchCaret
    }

    $form.Add_Paint({
        param($s, $e)
        Draw-PanelFrame $e.Graphics $form.ClientSize.Width $form.ClientSize.Height $ui.Border (Get-WindowRadius) $ui.Surface
      })
    $form.Add_Shown({
        # the layout and the list were built before Show() (see below), so the frame is already
        # complete: the keyboard goes to the list, not to the filter row, so no caret shows until
        # the user actually types
        $script:SearchFocus = $false
        try { $lst.Focus() } catch { }
        Sync-SearchCaret
        Write-Log ('picker: shown ' + $script:Theme + '/' + $script:UiFamily + ' items=' + $script:Entries.Count + ' scale=' + $script:UiScale + ' size=' + $form.Width + 'x' + $form.Height + ' at ' + $form.Left + ',' + $form.Top)
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
        # the panel came back to the front: the keyboard goes to the list, which is where it
        # starts, unless the editor is open
        if (-not $form.ContainsFocus) { try { $lst.Focus() } catch { } }
      })
    $form.Add_Deactivate({
        $script:CtrlHeld = $false
        # a paste moves the foreground to its target on purpose: that is not a dismissal
        if ($script:Pasting) { return }
        # the context menu is a window of this process, and opening it takes the activation away
        # from the panel for as long as it is up - the panel is still the one that came forward
        if ($cm.Visible -or [Cb.Win]::IsOwnWindow([Cb.Win]::GetForegroundWindow())) { return }
        # A panel that never got the foreground gets this the moment it appears - closing on it
        # is what made the first open of a session flash and vanish. Ask again, then close.
        if (-not $script:OwnFront) {
          $script:OwnFront = Take-Foreground $form.Handle
          if (-not $script:OwnFront) { $form.Close() }
          return
        }
        # the panel is no longer the window in front: closing it has nothing to hand back
        $script:OwnFront = $false
        # an edit in progress keeps the panel open: closing would drop the text
        if ($null -ne $script:EditRow) { return }
        if (((Get-Date) - $script:ShownAt).TotalMilliseconds -gt [int]$script:Timing['CloseOnBlur']) { $form.Close() }
      })

    # The panel owns the foreground from Show() on (lib\panel\focus.ps1), so the box is not
    # focused until the user types into it.
    $script:ImeCheckAt = Get-Date; $script:Composing = $false
    $script:ShellCheckAt = Get-Date
    $script:MenuClosedAt = $null
    # Non-modal on purpose: ShowDialog would block this message pump. Layout, list and the
    # rounded region all happen before the window appears, so the first frame is the whole
    # panel instead of an empty list that fills in a beat later (measured at ~60 ms).
    Layout-Chrome
    Size-List
    Sync-Sb
    Update-List ''
    # A warm run has to warm the search as well: an empty line returns before the line is cut
    # into tokens and before the scan runs, so the first keystrokes of a fresh process paid the
    # JIT of both (measured at 60-110 ms each) and the panel felt frozen while it was typed in.
    # Two real lines pay that here, where nobody is waiting for a character to appear.
    if ($Warm) { Update-List 'a'; Update-List 'ab' }
    Update-PanelRegion $form
    $msBuild = [int]$swOpen.ElapsedMilliseconds
    $swOpen.Stop()
    $shape = (' ms (records ' + $msRecords + ', widgets ' + $msWidgets + ', bind ' + ($msBuild - $msWidgets) + ', items ' + $script:Entries.Count + ')')
    # a warm run is a different event in the log: it built the panel and threw it away
    if ($Warm) { Write-Log ('picker: warm ' + $msBuild + $shape) } else { Write-Log ('picker: open ' + $msBuild + $shape) }
    Write-Log ('picker: mode=' + $preset.Mode + ' rows=' + $place.Rows + ' at ' + $form.Left + ',' + $form.Top + ' ' + $form.Width + 'x' + $form.Height)
    # A warm run (see Start-Serve) builds everything and throws it away: the first hotkey then
    # pays only for Show(), which is what the resident wants to avoid after a restart.
    if ($Warm) {
      try { $deb.Dispose() } catch { }
      try { $footTimer.Dispose() } catch { }
      try { $confirmTimer.Dispose() } catch { }
      try { Close-Preview $pv } catch { }
      try { $pvCfg.InkBrush.Dispose(); $pvCfg.DimBrush.Dispose() } catch { }
      try { $cm.Dispose() } catch { }
      # the row background brush is built per panel; without this it waited for the finalizer,
      # which is what made the GDI count climb by one on every open until a collection
      try { $bgBrush.Dispose() } catch { }
      try { $rg = $form.Region; $form.Dispose(); if ($null -ne $rg) { $rg.Dispose() } } catch { }
      # a warm run throws its window away: the script-scope handles must not outlive it
      $script:PanelForm = $null
      $script:PanelList = $null
      $script:PanelHost = $null
      $script:PanelBar = $null
      $script:PanelHead = $null
      $script:PanelFoot = $null
      $script:PanelFootL = $null
      $script:PanelFootR = $null
      $script:PanelBox = $null
      $script:PanelTxt = $null
      $script:PanelPh = $null
      $script:PanelClr = $null
      $script:PanelCaret = $null
      return
    }
    $form.Show()
    # Show() creates the handle; without one there is nothing to position (Chromium 76 did that)
    if (-not $form.IsHandleCreated) { try { $form.CreateControl() } catch { } }
    if ([IntPtr]$form.Handle -eq [IntPtr]::Zero) { Write-Log 'picker: no handle'; try { $form.Dispose() } catch { }; return }
    # Take-Foreground repeats the call with the queues attached
    $front = Take-Foreground $form.Handle
    $script:OwnFront = $front
    if (-not $front) { Write-Log 'picker: the foreground was refused' }
    try { $lst.Focus() } catch { }
    Write-Log ('picker: input=real foreground=' + $front)
    # the handle can be gone by now (a handler reached from the focus call closed the panel):
    # asking for topmost then throws and the exception ends the open with the panel half up
    try { [void][Cb.Win]::SetWindowPos($form.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13) } catch { Write-Log ('picker: topmost skipped: ' + $_.Exception.Message) }

    while (-not $form.IsDisposed) {
      [Windows.Forms.Application]::DoEvents()
      # a handler reached from DoEvents can close the panel (a paste, Enter, Esc): the rest of
      # this tick would then run against disposed controls
      if ($form.IsDisposed) { break }
      $am = Invoke-AnimFrame $script:Anim $(if ($script:Animations) { 0.4 } else { 1.0 })
      # repaint only the rows whose alpha moved, not the whole list on every tick
      if ($am -ne 0 -and -not $form.IsDisposed) { try { if ($am -band 1) { foreach ($i in @($script:Anim.HoverIndex, $script:Anim.PrevHoverIndex, $script:Anim.SelIndex, $script:Anim.PrevSelIndex)) { if ($i -ge 0 -and $i -lt $lst.ItemCount) { $lst.Invalidate($lst.GetItemRectangle($i)) } } }; if ($am -band 2) { $sbar.Invalidate() }; if ($am -band 8) { $box.Invalidate() }; if ($am -band 16) { if ($null -ne $script:EditRow) { $script:EditRow.Save.Invalidate(); $script:EditRow.Cancel.Invalidate() } } } catch { } }
      if ($script:PickerClose) { Close-Panel; break }
      # Ctrl is a modifier, not a key the panel sees: a KeyDown for it never arrives on its own,
      # so the key caps kept their neutral colour while Ctrl was held. Polling the key state is
      # what makes the accents (and the Ctrl group in the footer) follow the modifier.
      $ctrlNow = ([Cb.Win]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0
      if ($ctrlNow -ne $script:CtrlHeld) {
        $script:CtrlHeld = $ctrlNow
        try { $lst.Invalidate() } catch { }
        try { $footL.Invalidate() } catch { }
      }
      # the same flyout coming up while the panel is open closes it, like a click outside
      if (((Get-Date) - $script:ShellCheckAt).TotalMilliseconds -gt 300) {
        $script:ShellCheckAt = Get-Date
        $fgShell = [Cb.Win]::GetForegroundWindow()
        if ($fgShell -ne $form.Handle -and (Test-ShellFlyout $fgShell)) {
          Write-Log 'picker: dismissed (Windows Start / search came up)'
          $form.Close(); break
        }
      }
      # Whether the drawn caret is the only one there is: while an input method composes, the
      # real caret has to be shown - the candidate window sits at it, and only the system can
      # draw it. The answer is asked of the control often enough that the switch is not seen.
      if (-not $form.IsDisposed -and ((Get-Date) - $script:ImeCheckAt).TotalMilliseconds -gt 120) {
        $script:ImeCheckAt = Get-Date
        try { $script:Composing = [Cb.Win]::ImeComposing($txt.Handle) } catch { $script:Composing = $false }
      }
      if (-not $form.ContainsFocus -and ((Get-Date) - $script:ShownAt).TotalMilliseconds -gt 350) {
        # a click elsewhere dismisses the panel; the context menu is ours, not somewhere else
        $fg = [Cb.Win]::GetForegroundWindow()
        if ($fg -ne $form.Handle -and $fg -ne $prev -and -not $cm.Visible -and -not [Cb.Win]::IsOwnWindow($fg)) { $form.Close(); break }
      }
      # A click beside the open menu closes it and the panel together: the menu eats that click,
      # so the panel would otherwise need a second one. The cursor says where it landed.
      if (-not $cm.Visible -and $null -ne $script:MenuClosedAt) {
        $recent = (((Get-Date) - $script:MenuClosedAt).TotalMilliseconds -lt 300)
        $script:MenuClosedAt = $null
        if ($recent -and -not $form.Bounds.Contains([Windows.Forms.Cursor]::Position)) {
          Write-Log 'picker: dismissed by a click outside (menu was open)'
          $form.Close(); break
        }
      }
      # a card waits for the cursor to rest; a page built off-thread lands on the next tick
      if ($script:PreviewHover -and $script:Hover -ge 0 -and $script:PvIdx -ne $script:Hover -and -not $cm.Visible -and ((Get-Date) - $script:PvAt).TotalMilliseconds -gt $script:PreviewDelay) { Show-HoverPreview }
      [void](Step-PreviewCard $pv)
      # The drawn line blinks and follows the selection on every tick: the arrow keys move the
      # insertion point without changing the text, so no TextChanged fires for them. The system
      # caret is hidden while the drawn one stands in for it - a control re-shows it after each
      # keystroke, and a second white caret next to the themed one is exactly the flicker to
      # avoid. While an input method composes the pair swaps: the system caret is given back.
      if (Test-OwnCaret) {
        Hide-SystemCaret
        if ((Get-CaretIndex) -ne $script:CaretIndex) { Sync-SearchCaret }
        elseif (((Get-Date) - $script:CaretPulse).TotalMilliseconds -ge 530) {
          $script:CaretPulse = Get-Date
          $caret.Visible = -not $caret.Visible
        }
      } else {
        if ($caret.Visible) { $caret.Visible = $false }
        Show-SystemCaret
      }
      # Idle ticks cost real CPU: 8 ms while something moves or the menu is open, else 20 ms.
      $busy = ($am -ne 0 -or $cm.Visible -or $script:PickerClose)
      Start-Sleep -Milliseconds $(if ($busy) { 8 } else { 20 })
    }

    # The panel took the foreground, so closing puts it back where it came from - but only while
    # it still holds it: a panel dismissed by a click has already handed it over, and taking it
    # back would pull the previous window over the one just clicked. The paste path has already
    # aimed the foreground at its target by then, which is the same window in the usual case.
    try {
      if ($script:OwnFront -and $prev -ne [IntPtr]::Zero) {
        [void][Cb.Win]::SetForegroundWindow($prev)
        [void](Restore-TargetFocus $prev $script:PrevFocus)
        Put-BackSelection ' (panel closed)'
      }
    } catch { }

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
    # GDI handles this panel owns: the row background brush and the region the form paints with
    try { $bgBrush.Dispose() } catch { }
    try { $rgn = $form.Region; $form.Dispose(); if ($null -ne $rgn) { $rgn.Dispose() } } catch { }
    # The functions in lib\panel\picker-live.ps1 read the controls from the script scope; the
    # window they belong to is gone, so nothing may keep pointing at a disposed control.
    $script:PanelForm = $null
    $script:PanelList = $null
    $script:PanelHost = $null
    $script:PanelBar = $null
    $script:PanelHead = $null
    $script:PanelFoot = $null
    $script:PanelFootL = $null
    $script:PanelFootR = $null
    $script:PanelBox = $null
    $script:PanelTxt = $null
    $script:PanelPh = $null
    $script:PanelClr = $null
    $script:PanelCaret = $null
  } catch {
    Write-Log ('picker error: ' + $_.Exception.Message)
    try {
      $pos = [string]$_.InvocationInfo.PositionMessage
      $pos = ($pos -replace '\s+', ' ').Trim()
      if ($pos.Length -gt 200) { $pos = $pos.Substring(0, 200) }
      Write-Log ('picker at: ' + $pos)
    } catch { }
  } finally {
    # an error can leave the window on screen with no loop left to serve it
    try { if ($form -and -not $form.IsDisposed) { $form.Close() } } catch { }
    $script:PickerOpen = $false
    # the settings window that stepped aside comes back with the state it had
    if ($script:PickerOverSettings) {
      $script:PickerOverSettings = $false
      if (Get-Command Show-SettingsAfterPanel -ErrorAction SilentlyContinue) { Show-SettingsAfterPanel }
    }
  }
}

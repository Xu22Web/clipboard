# lib/panel/settings.ps1 - the settings window: one function owns its lifecycle.
#
# The window is the same object the history panel is: a Cb.FluentForm with a rounded region, a
# custom paint, the theme's palette and the shared type ramp. What differs is what it does not
# do - it never takes the caret, never pastes, and it stays open when it loses the foreground,
# because a settings window is a place the user returns to rather than a flyout.
#
# Values are written the moment they change (lib/panel/settings-edit.ps1 writes through
# Set-IniKey and Apply-Config, exactly what `config set` does). The resident process is
# reloaded once, when the window closes: restarting it on every keystroke would make the
# window unusable.

function Show-Settings {
  $swOpen = [Diagnostics.Stopwatch]::StartNew()
  Load-Forms
  Add-Native
  Initialize-Dpi
  $msBase = [int]$swOpen.ElapsedMilliseconds
  Apply-Theme
  [void](Initialize-PanelFonts)
  $msTheme = [int]$swOpen.ElapsedMilliseconds
  # the whole schema, not $script:IniSchema: that one is already the property table, and the
  # model asks the schema for a key's type, range and help
  $schema = $script:SettingsSchema
  if ($null -eq (Get-SchemaProperties $schema)) {
    Write-Log 'settings: the settings schema is not loaded, nothing to show'
    return
  }
  $groups = @(Get-SettingGroups $schema)
  if ($groups.Count -eq 0) {
    Write-Log 'settings: the schema has no properties, nothing to show'
    return
  }
  $pal = Get-UiPalette

  $script:SetGroup = 0
  $script:SetSel = 0
  $script:SetScroll = 0
  $script:SetHover = -1
  $script:SetMsg = 'Up/Down select    Left/Right adjust    Enter edit    Tab group    Esc close'
  $script:SetMsgErr = $false
  $script:SetEditKey = ''
  $script:SetEditBox = $null
  $script:SetEditRect = $null
  $script:SetPal = $pal
  $script:SetDirty = $false
  $script:SetRows = @()
  # how far each switch has travelled, 0 or 1 at rest: the window eases these on a timer so a
  # flip moves instead of blinking between two states
  $script:SetToggleK = @{}
  $script:SetToggleTarget = @{}
  $script:SetDrop = $null
  $script:SetDropIndex = -1
  $script:SetDropHover = -1

  $w = [int](Px 780)
  $h = [int](Px 620)
  $layout = Get-SettingsLayout $w $h

  function Refresh-Settings {
    $script:SetRows = @(Get-SettingsRows $schema $groups[$script:SetGroup])
    # a switch that has never been drawn starts at the value it holds, not at zero
    foreach ($row in @($script:SetRows)) {
      if ($row.Kind -ne 'bool') { continue }
      $k = [string]$row.Key
      if (-not $script:SetToggleK.ContainsKey($k)) {
        $v = 0.0
        if ([string]$row.Raw -eq '1') { $v = 1.0 }
        $script:SetToggleK[$k] = $v
        $script:SetToggleTarget[$k] = $v
      }
    }
    $vis = Get-SettingsVisibleRows $script:SetLayout
    $maxScroll = [Math]::Max(0, @($script:SetRows).Count - $vis)
    if ($script:SetScroll -gt $maxScroll) { $script:SetScroll = $maxScroll }
    if ($script:SetScroll -lt 0) { $script:SetScroll = 0 }
    if ($script:SetSel -ge @($script:SetRows).Count) { $script:SetSel = [Math]::Max(0, @($script:SetRows).Count - 1) }
    if ($script:SetSel -lt 0) { $script:SetSel = 0 }
  }

  function Get-CurrentRow {
    $rows = $script:SetRows
    if ($null -eq $rows -or $script:SetSel -lt 0 -or $script:SetSel -ge @($rows).Count) { return $null }
    return $rows[$script:SetSel]
  }

  # a row whose owner setting is off: shown, greyed, and refusing edits with the reason
  function Test-RowEnabled($row) {
    if ($null -eq $row) { return $false }
    if (-not $row.ContainsKey('Enabled')) { return $true }
    return [bool]$row.Enabled
  }

  function Show-RowRefused($row) {
    $why = 'this setting is not in effect'
    if ($row.ContainsKey('Why') -and $row.Why) { $why = [string]$row.Why }
    Show-Message ([string]$row.Label + ': ' + $why) $true
  }

  function Set-CurrentGroup([int]$idx) {
    $n = @($groups).Count
    if ($n -eq 0) { return }
    if ($null -ne $script:SetDrop) { Close-Choices }
    $script:SetGroup = (($idx % $n) + $n) % $n
    $script:SetSel = 0
    $script:SetScroll = 0
    $script:SetHover = -1
    Refresh-Settings
    $form.Invalidate()
  }

  function Move-Selection([int]$delta) {
    $count = @($script:SetRows).Count
    if ($count -eq 0) { return }
    if ($null -ne $script:SetDrop) { Close-Choices }
    $next = $script:SetSel + $delta
    if ($next -lt 0) { $next = 0 }
    if ($next -gt ($count - 1)) { $next = $count - 1 }
    if ($next -eq $script:SetSel) { return }
    $script:SetSel = $next
    $vis = Get-SettingsVisibleRows $script:SetLayout
    if ($script:SetSel -lt $script:SetScroll) { $script:SetScroll = $script:SetSel }
    if ($script:SetSel -ge ($script:SetScroll + $vis)) { $script:SetScroll = $script:SetSel - $vis + 1 }
    $form.Invalidate()
  }

  function Show-Message([string]$text, [bool]$bad) {
    $script:SetMsg = $text
    $script:SetMsgErr = $bad
    $form.Invalidate()
  }

  # one write, whatever produced it: the toggle, the step, the cycle or a typed value
  function Apply-Setting([string]$key, [string]$value, [string]$what) {
    $r = Set-SettingValue $key $value
    if (-not $r.Ok) { Show-Message ([string]$key + ': ' + [string]$r.Error) $true; return $false }
    if ($script:SetToggleK.ContainsKey($key)) {
      # the switch is told where to go; the timer moves it there
      $script:SetToggleTarget[$key] = $(if ([string]$value -eq '1') { 1.0 } else { 0.0 })
    }
    if ($key -eq 'Theme') {
      # a new theme has to reach the palette and the fonts before the next paint
      Apply-Theme
      $script:FBody = $null
      [void](Initialize-PanelFonts)
      $script:SetPal = Get-UiPalette
    }
    Refresh-Settings
    Show-Message ($key + ': ' + $what) $false
    return $true
  }

  function End-Edit([bool]$cancel) {
    $box = $script:SetEditBox
    $script:SetEditBox = $null
    $script:SetEditKey = ''
    $script:SetEditRect = $null
    if ($null -ne $box) {
      try { $form.Controls.Remove($box); $box.Dispose() } catch { }
    }
    # the keyboard goes back to the window, or the next arrow key would reach nothing
    try { $form.Focus() } catch { }
    $form.Invalidate()
  }

  # A value typed into the field: the schema decides whether it is acceptable, and a refusal
  # leaves the field open with the reason in the footer, so the user can correct it instead of
  # losing what they typed.
  function Complete-Edit {
    $key = [string]$script:SetEditKey
    $box = $script:SetEditBox
    if (-not $key -or $null -eq $box) { End-Edit $true; return }
    $r = Convert-SettingInput $schema $key ([string]$box.Text)
    if (-not $r.Ok) { Show-Message ($key + ': ' + [string]$r.Error) $true; return }
    [void](Apply-Setting $key ([string]$r.Value) ('set to ' + [string]$r.Value))
    End-Edit $false
  }

  function Begin-Edit {
    $row = Get-CurrentRow
    if ($null -eq $row) { return }
    if ($row.Kind -eq 'bool') { return }
    if (-not (Test-RowEnabled $row)) { Show-RowRefused $row; return }
    End-Edit $true
    $rowTop = [int]$script:SetLayout.ListTop + (($script:SetSel - $script:SetScroll) * [int]$script:SetLayout.RowHeight)
    $rect = Get-SettingEditRect $script:SetLayout $rowTop
    $script:SetEditKey = [string]$row.Key
    $script:SetEditRect = $rect
    $box = New-SettingEditor $form $pal ([int]$rect.Left + (Px 4)) ([int]$rect.Top + (Px 4)) ([int]$rect.Width - (Px 8)) ([int]$rect.Height - (Px 8))
    $box.Text = Get-SettingEditSeed $schema ([string]$row.Key)
    $script:SetEditBox = $box
    $box.Add_LostFocus({ End-Edit $true })
    # the keyboard has to land in the field, not on the row it covers: assigning ActiveControl is
    # what moves it after the control was added while the window was already showing
    try { $form.ActiveControl = $box } catch { }
    $box.Focus()
    $box.SelectAll()
    $form.Invalidate()
  }

  # A value whose whole domain is known - the themes on disk, the three paste chords - opens a
  # list instead of a field. The list is its own small window: a popup inside the form would need
  # clipping against every row and still could not overlap the footer.
  function Close-Choices {
    $dd = $script:SetDrop
    $script:SetDrop = $null
    $script:SetDropIndex = -1
    $script:SetDropHover = -1
    if ($null -ne $dd) { try { $dd.Close(); $dd.Dispose() } catch { } }
    try { $form.Activate() } catch { }
    $form.Invalidate()
  }

  function Open-Choices {
    $row = Get-CurrentRow
    if ($null -eq $row) { return }
    if (-not (Test-RowEnabled $row)) { Show-RowRefused $row; return }
    $choices = @()
    if ($row.ContainsKey('Choices')) { $choices = @($row.Choices) }
    if ($choices.Count -eq 0) { Begin-Edit; return }
    if ($null -ne $script:SetDrop) { Close-Choices; return }
    $current = [string]$row.Raw
    $rowTop = [int]$script:SetLayout.ListTop + (($script:SetSel - $script:SetScroll) * [int]$script:SetLayout.RowHeight)
    $rect = Get-SettingDropRect $script:SetLayout $rowTop @($choices).Count
    $script:SetDropIndex = -1
    for ($i = 0; $i -lt $choices.Count; $i++) { if ([string]$choices[$i] -eq $current) { $script:SetDropIndex = $i } }
    $script:SetDropHover = -1
    $dd = New-Object Cb.FluentForm
    $dd.Activates = $true
    $dd.FormBorderStyle = 'None'
    $dd.StartPosition = 'Manual'
    $dd.ShowInTaskbar = $false
    $dd.KeyPreview = $true
    $dd.Text = 'Settings choices'
    $dd.ClientSize = New-Object Drawing.Size -ArgumentList @([int]$rect.Width, [int]$rect.Height)
    $dd.Left = $form.Left + [int]$rect.Left
    $dd.Top = $form.Top + [int]$rect.Top
    $dd.Tag = @{ Choices = $choices; Key = [string]$row.Key }
    Update-PanelRegion $dd
    $dd.Add_Paint({
      param($s, $e)
      try {
        $g = $e.Graphics
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $p = $script:SetPal
        $cw = [int]$s.ClientSize.Width
        $ch = [int]$s.ClientSize.Height
        $bg = New-Object Drawing.SolidBrush $p['Field']
        try { $g.FillRectangle($bg, 0, 0, $cw, $ch) } finally { $bg.Dispose() }
        Draw-SettingsFrame $g $cw $ch $p['Border'] (Px 6)
        $sf = New-PickerStringFormats
        $list = @($s.Tag.Choices)
        $itemH = Px 30
        for ($i = 0; $i -lt $list.Count; $i++) {
          $top = [int](Px 4) + ($i * $itemH)
          $isCur = ($i -eq $script:SetDropIndex)
          $isHot = ($i -eq $script:SetDropHover)
          if ($isHot -or $isCur) {
            $tint = $p['HoverBg']
            if ($isCur) { $tint = $p['SelBg'] }
            $b = New-Object Drawing.SolidBrush $tint
            $path = New-RoundPath (Px 4) $top ($cw - (2 * (Px 4))) ($itemH - (Px 2)) (Px 4)
            try { $g.FillPath($b, $path) } finally { $path.Dispose(); $b.Dispose() }
          }
          $ink = $p['Dim']
          if ($isCur -or $isHot) { $ink = $p['Text'] }
          $tb = New-Object Drawing.RectangleF -ArgumentList @(
            [single](Px 12), [single]$top, [single]($cw - (Px 24)), [single]($itemH - (Px 2)))
          $g.DrawString([string]$list[$i], $script:FBody, (Get-Brush $ink), $tb, $sf.Ellipsis)
        }
      } catch { Write-Log ('settings drop paint: ' + $_.Exception.Message) }
    })
    $dd.Add_MouseMove({
      param($s, $e)
      $i = [int][Math]::Floor(($e.Y - (Px 4)) / (Px 30))
      if ($i -ge @($s.Tag.Choices).Count) { $i = -1 }
      if ($i -ne $script:SetDropHover) { $script:SetDropHover = $i; $s.Invalidate() }
    })
    $dd.Add_MouseDown({
      param($s, $e)
      $i = [int][Math]::Floor(($e.Y - (Px 4)) / (Px 30))
      $list = @($s.Tag.Choices)
      if ($i -ge 0 -and $i -lt $list.Count) {
        [void](Apply-Setting ([string]$s.Tag.Key) ([string]$list[$i]) ('set to ' + [string]$list[$i]))
      }
      Close-Choices
    })
    $dd.Add_KeyDown({
      param($s, $e)
      $list = @($s.Tag.Choices)
      if ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) { Close-Choices }
      elseif ($e.KeyCode -eq [Windows.Forms.Keys]::Enter) {
        if ($script:SetDropIndex -ge 0 -and $script:SetDropIndex -lt $list.Count) {
          [void](Apply-Setting ([string]$s.Tag.Key) ([string]$list[$script:SetDropIndex]) ('set to ' + [string]$list[$script:SetDropIndex]))
        }
        Close-Choices
      } elseif ($e.KeyCode -eq [Windows.Forms.Keys]::Down) {
        if ($script:SetDropIndex -lt ($list.Count - 1)) { $script:SetDropIndex++; $s.Invalidate() }
      } elseif ($e.KeyCode -eq [Windows.Forms.Keys]::Up) {
        if ($script:SetDropIndex -gt 0) { $script:SetDropIndex--; $s.Invalidate() }
      }
    })
    $dd.Add_Deactivate({ Close-Choices })
    $script:SetDrop = $dd
    $dd.Show()
    try { $dd.Activate() } catch { }
  }

  function Adjust-Current([int]$dir) {
    $row = Get-CurrentRow
    if ($null -eq $row) { return }
    if (-not (Test-RowEnabled $row)) { Show-RowRefused $row; return }
    $key = [string]$row.Key
    if ($row.Kind -eq 'bool') {
      $v = Get-SettingToggle $schema $key
      if ($null -ne $v) { [void](Apply-Setting $key $v ('turned ' + $(if ($v -eq '1') { 'on' } else { 'off' }))) }
      return
    }
    if ($row.Kind -eq 'number') {
      $v = Get-SettingStepped $schema $key $dir
      if ($null -eq $v) { Show-Message ($key + ' is already at the end of its range') $true; return }
      [void](Apply-Setting $key $v ('set to ' + $v))
      return
    }
    if ($row.Kind -eq 'theme') {
      $v = Get-SettingCycled $schema $key $dir
      if ($null -eq $v) { Show-Message 'no other theme in themes\' $true; return }
      [void](Apply-Setting $key $v ('set to ' + $v))
      return
    }
    # nothing to step: the value is typed
    Begin-Edit
  }

  $form = New-Object Cb.FluentForm
  $form.Activates = $true
  $form.FormBorderStyle = 'None'
  $form.StartPosition = 'Manual'
  $form.ShowInTaskbar = $true
  $form.KeyPreview = $true
  $form.Text = 'Settings'
  $form.AccessibleName = 'Settings'
  $form.ClientSize = New-Object Drawing.Size -ArgumentList @($w, $h)
  $areas = @()
  try { foreach ($sc in [Windows.Forms.Screen]::AllScreens) { $areas += $sc.WorkingArea } } catch { }
  $fallback = $null
  try { $fallback = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea } catch { }
  $place = Get-PickerBounds $w $h '' '' $areas $fallback
  $form.Left = [int]$place.Left
  $form.Top = [int]$place.Top
  # The silhouette is a region, the same way the history panel draws its own: a Windows-rounded
  # window needs WS_THICKFRAME, and a topmost no-border window with it behaves like a resizable
  # frame. Everything inside the window is drawn anti-aliased instead, which is what made the
  # row and switch corners look stepped.
  Update-PanelRegion $form
  $script:SetLayout = $layout
  Refresh-Settings
  $msRows = [int]$swOpen.ElapsedMilliseconds
  Write-Log ('settings: open ' + [string]$msRows + ' ms (base ' + [string]$msBase + ', theme+fonts ' + [string]$msTheme + ', rows ' + [string]$msRows + '), ' + [string]@($script:SetRows).Count + ' rows')

  $form.Add_Paint({
    param($s, $e)
    # a paint that throws leaves the window red-crossed and says nothing; the log carries the
    # message and the line, which is the only way to find it from outside the process
    try {
      $g = $e.Graphics
      # a rounded corner drawn without anti-aliasing is a staircase, which is what the window
      # region, every row and the switch all are: one setting here covers them
      $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
      $rows = $script:SetRows
      $layout = $script:SetLayout
      $pal = $script:SetPal
      Draw-SettingsChrome $g $pal $layout 'Settings' ([string]$groups[$script:SetGroup] + '   ' + [string](@($rows).Count) + ' items')
      Draw-SettingsSide $g $pal $layout $groups $script:SetGroup
      $vis = Get-SettingsVisibleRows $layout
      $x = [int]$layout.ListLeft
      $width = [int]$layout.ListRight - [int]$layout.ListLeft
      for ($i = 0; $i -lt $vis; $i++) {
        $idx = $i + $script:SetScroll
        if ($idx -ge @($rows).Count) { break }
        $rowTop = [int]$layout.ListTop + ($i * [int]$layout.RowHeight)
        $row = $rows[$idx]
        $k = 1.0
        if ($row.Kind -eq 'bool') {
          $name = [string]$row.Key
          if ($script:SetToggleK.ContainsKey($name)) { $k = [double]$script:SetToggleK[$name] }
          elseif ([string]$row.Raw -eq '1') { $k = 1.0 } else { $k = 0.0 }
        }
        Draw-SettingsRow $g $pal $layout $row $x $rowTop $width ($idx -eq $script:SetHover) $k
      }
      Draw-SettingsScrollbar $g $pal $layout @($rows).Count $vis $script:SetScroll
      if ($script:SetEditKey -and $null -ne $script:SetEditRect) {
        $r = $script:SetEditRect
        Draw-SettingEditField $g $pal ([int]$r.Left) ([int]$r.Top) ([int]$r.Width) ([int]$r.Height) $script:SetMsgErr
      }
      Draw-SettingsFooter $g $pal $layout $script:SetMsg $script:SetMsgErr
    } catch {
      Write-Log ('settings paint: ' + $_.Exception.Message + ' @ ' + $_.ScriptStackTrace)
    }
  })

  $form.Add_KeyDown({
    param($s, $e)
    if ($null -ne $script:SetEditBox) {
      if ($e.KeyCode -eq [Windows.Forms.Keys]::Enter) {
        Complete-Edit
        $e.Handled = $true
        $e.SuppressKeyPress = $true
      } elseif ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) {
        End-Edit $true
        Show-Message 'edit cancelled' $false
        $e.Handled = $true
        $e.SuppressKeyPress = $true
      }
      return
    }
    switch ($e.KeyCode) {
      ([Windows.Forms.Keys]::Down) { Move-Selection 1; $e.Handled = $true; $e.SuppressKeyPress = $true }
      ([Windows.Forms.Keys]::Up) { Move-Selection -1; $e.Handled = $true; $e.SuppressKeyPress = $true }
      ([Windows.Forms.Keys]::PageDown) { Move-Selection (Get-SettingsVisibleRows $script:SetLayout); $e.Handled = $true }
      ([Windows.Forms.Keys]::PageUp) { Move-Selection (-(Get-SettingsVisibleRows $script:SetLayout)); $e.Handled = $true }
      ([Windows.Forms.Keys]::Right) { Adjust-Current 1; $e.Handled = $true; $e.SuppressKeyPress = $true }
      ([Windows.Forms.Keys]::Left) { Adjust-Current (-1); $e.Handled = $true; $e.SuppressKeyPress = $true }
      ([Windows.Forms.Keys]::Space) { Adjust-Current 1; $e.Handled = $true; $e.SuppressKeyPress = $true }
      ([Windows.Forms.Keys]::Enter) {
        $row = Get-CurrentRow
        if ($null -ne $row -and $row.Kind -eq 'bool') { Adjust-Current 1 }
        elseif ($null -ne $row -and $row.ContainsKey('Choices') -and @($row.Choices).Count -gt 0) { Open-Choices }
        else { Begin-Edit }
        $e.Handled = $true
        $e.SuppressKeyPress = $true
      }
      ([Windows.Forms.Keys]::F4) {
        # the key that opens a combo box in every Windows dialog
        Open-Choices
        $e.Handled = $true
        $e.SuppressKeyPress = $true
      }
      ([Windows.Forms.Keys]::Tab) {
        $dir = 1
        if ($e.Shift) { $dir = -1 }
        Set-CurrentGroup ($script:SetGroup + $dir)
        $e.Handled = $true
        $e.SuppressKeyPress = $true
      }
      ([Windows.Forms.Keys]::Escape) { $form.Close(); $e.Handled = $true }
      default { }
    }
  })

  $form.Add_MouseWheel({
    param($s, $e)
    # the wheel scrolls the page, it does not walk the keyboard through it: turning it must
    # never change a setting
    $vis = Get-SettingsVisibleRows $script:SetLayout
    $maxScroll = [Math]::Max(0, @($script:SetRows).Count - $vis)
    $dir = 1
    if ($e.Delta -gt 0) { $dir = -1 }
    $next = $script:SetScroll + ($dir * 3)
    if ($next -lt 0) { $next = 0 }
    if ($next -gt $maxScroll) { $next = $maxScroll }
    if ($next -ne $script:SetScroll) { $script:SetScroll = $next; $form.Invalidate() }
  })

  $form.Add_MouseMove({
    param($s, $e)
    $idx = Get-SettingsRowAt $script:SetLayout @($script:SetRows).Count $script:SetScroll $e.X $e.Y
    if ($idx -ne $script:SetHover) { $script:SetHover = $idx; $form.Invalidate() }
  })

  $form.Add_MouseDown({
    param($s, $e)
    if ($e.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
    # A click anywhere ends the edit that was open. Leaving the field is the only way out of it
    # for a pointer user, and committing is what a settings page does; a value the schema refuses
    # keeps the field open with the reason in the footer.
    if ($null -ne $script:SetEditBox) {
      $box = $script:SetEditBox
      $inside = ($e.X -ge $box.Left -and $e.X -le ($box.Left + $box.Width) -and
        $e.Y -ge $box.Top -and $e.Y -le ($box.Top + $box.Height))
      if (-not $inside) { Complete-Edit }
      return
    }
    # the left column is a set of buttons, not a list to scroll
    if ($e.X -lt [int]$script:SetLayout.SideWidth) {
      $i = [int][Math]::Floor(($e.Y - [int]$script:SetLayout.HeadHeight) / [int]$script:SetLayout.GroupHeight)
      if ($i -ge 0 -and $i -lt @($groups).Count) { Set-CurrentGroup $i }
      return
    }
    $idx = Get-SettingsRowAt $script:SetLayout @($script:SetRows).Count $script:SetScroll $e.X $e.Y
    if ($idx -lt 0) { return }
    $wasSel = ($idx -eq $script:SetSel)
    $script:SetSel = $idx
    $row = $script:SetRows[$idx]
    if (-not (Test-RowEnabled $row)) {
      Show-RowRefused $row
      $form.Invalidate()
      return
    }
    $rowTop = [int]$script:SetLayout.ListTop + (($idx - $script:SetScroll) * [int]$script:SetLayout.RowHeight)
    # every row is its own control: a click on a switch row flips it wherever it lands, and a
    # click on a value edits it - there is no separate "select, then act" step
    if ($row.Kind -eq 'bool') {
      Adjust-Current 1
      return
    }
    if ($row.ContainsKey('Choices') -and @($row.Choices).Count -gt 0) {
      Open-Choices
      return
    }
    Begin-Edit
  })

  # A switch that flips in one frame reads as a jump. One timer eases every switch in flight and
  # asks for a repaint only while something moves, so a window sitting still costs nothing;
  # Animations=0 makes the step 1.0, which lands on the target in a single frame.
  $animTimer = New-Object Windows.Forms.Timer
  $animTimer.Interval = 15
  $animTimer.Add_Tick({
    if ($form.IsDisposed) { return }
    $step = 0.22
    if (-not $script:Animations) { $step = 1.0 }
    $moved = $false
    foreach ($name in @($script:SetToggleK.Keys)) {
      $now = [double]$script:SetToggleK[$name]
      $want = [double]$script:SetToggleTarget[$name]
      if ([Math]::Abs($want - $now) -lt 0.001) { continue }
      $next = $now + (($want - $now) * $step)
      if ([Math]::Abs($want - $next) -lt 0.02) { $next = $want }
      $script:SetToggleK[$name] = $next
      $moved = $true
    }
    if ($moved) { $form.Invalidate() }
  })
  $animTimer.Start()

  $form.Add_Deactivate({
    # leaving the window is the other way out of the field: a value is committed, never quietly
    # dropped, and a refusal keeps it open until the user is back
    if ($null -ne $script:SetEditBox) { Complete-Edit }
  })

  try {
    # a paint or key handler that throws must not take the window down with a modal box the user
    # cannot read: the failure goes to the log with its stack, and the window stays usable
    try {
      [Windows.Forms.Application]::add_ThreadException({
        param($s, $e)
        Write-Log ('settings: ' + $e.Exception.Message + ' @ ' + $e.Exception.ScriptStackTrace)
      })
    } catch { }
    [void]$form.ShowDialog()
  } finally {
    try { $animTimer.Stop(); $animTimer.Dispose() } catch { }
    Close-Choices
    End-Edit $true
    try { $form.Dispose() } catch { }
    # one reload for the whole session, and only when something was actually written
    if ($script:SetDirty) {
      try { Restart-ResidentIfRunning } catch { }
      $script:SetDirty = $false
    }
  }
}

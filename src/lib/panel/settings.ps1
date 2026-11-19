# lib/panel/settings.ps1 - the settings window: one function owns its lifecycle.
#
# The window is the same object the history panel is: a Cb.FluentForm with a rounded region, a
# custom paint, the theme's palette and the shared type ramp. What differs is what it does not
# do - it never takes the caret, never pastes, and it stays open when it loses the foreground,
# because a settings window is a place the user returns to rather than a flyout.
#
# Values are staged, not written: every change lands in one pending table that the rows are
# drawn from, and Save writes the whole table in one pass (lib/panel/settings-edit.ps1). The
# resident process is reloaded once, when the window closes after a save: restarting it per
# keystroke would make the window unusable, and restarting it on a change nobody kept would be
# work for nothing.

# The lock that makes the window a single one: a named object that exists only while a settings
# window is open. Opening it either hands back that object - no window is open - or nothing, which
# means the request belongs to the window that already holds it. The name is a parameter so a
# test can use one of its own instead of racing the window someone has open.
function Open-SettingsLock([string]$name = '') {
  if (-not $name) { $name = $SettingsLock }
  $lock = $null
  $created = $false
  try { $lock = New-Object System.Threading.Mutex($false, $name, [ref]$created) } catch { return $null }
  if ($created) { return $lock }
  try { $lock.Dispose() } catch { }
  return $null
}

# The open window's doorbell, created by the window and wrung by a request that finds the lock
# taken. Polling it costs one WaitOne(0) on a loop the window already runs.
function Open-SettingsAsk([string]$name = '') {
  if (-not $name) { $name = $SettingsShow }
  try { return (New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $name)) } catch { return $null }
}

function Ring-SettingsAsk([string]$name = '') {
  if (-not $name) { $name = $SettingsShow }
  try {
    $ask = [System.Threading.EventWaitHandle]::OpenExisting($name)
    [void]$ask.Set()
    $ask.Dispose()
    return $true
  } catch { return $false }
}

# Is a settings window open in this session? Its lock exists only while one is, so asking is
# opening it and letting go again. The picker asks before it opens: see lib\panel\picker.ps1.
function Test-SettingsWindowOpen([string]$name = '') {
  $lock = Open-SettingsLock $name
  if ($null -eq $lock) { return $true }
  try { $lock.Dispose() } catch { }
  return $false
}

function Show-Settings {
  $swOpen = [Diagnostics.Stopwatch]::StartNew()
  Load-Forms
  Add-Native
  # One settings window per session. A second `clipboard settings`, or the tray entry while the
  # command line already opened it, brings that window forward instead of adding a copy beside it.
  $script:SetLock = Open-SettingsLock
  if ($null -eq $script:SetLock) {
    # the open window creates its doorbell right after the lock, so a request landing in between
    # waits for it rather than going unanswered
    for ($i = 0; $i -lt 20; $i++) { if (Ring-SettingsAsk) { break }; Start-Sleep -Milliseconds 25 }
    Write-Log 'settings: a window is already open, asked it to come forward'
    return
  }
  $script:SetAsk = Open-SettingsAsk
  # the ways out of here before the window exists (a schema that cannot be read) take the lock
  # with them: left behind, it would keep the process from ever opening a window again
  $releaseSettings = {
    if ($null -ne $script:SetAsk) { try { $script:SetAsk.Dispose() } catch { }; $script:SetAsk = $null }
    if ($null -ne $script:SetLock) { try { $script:SetLock.Dispose() } catch { }; $script:SetLock = $null }
  }
  # before the window exists, so the bar groups it on its own and shows its icon
  Set-AppId
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
    & $releaseSettings
    return
  }
  $groups = @(Get-SettingGroups $schema)
  if ($groups.Count -eq 0) {
    Write-Log 'settings: the schema has no properties, nothing to show'
    & $releaseSettings
    return
  }
  $pal = Get-UiPalette

  $script:SetGroup = 0
  $script:SetScroll = 0
  $script:SetHover = -1
  # nothing in this window is selected: every row is its own control, acted on with the pointer.
  # The footer is a status line - a message after a write, and the count at the right end.
  $script:SetMsg = ''
  $script:SetMsgErr = $false
  $script:SetEditBad = $false
  $script:SetEditKey = ''
  $script:SetEditBox = $null
  $script:SetEditRect = $null
  # a number is edited in the unit the row shows, so the unit and its factor travel with the
  # edit; a text field is the same field with neither
  $script:SetEditField = @{ Number = $false; Scale = 1; Unit = '' }
  $script:SetPal = $pal
  # set by Save-SettingsValues (settings-edit.ps1) when a written key needs the resident to
  # re-read the file; the reload itself happens on the way out, below
  $script:SettingsDirty = $false
  $script:SetRows = @()
  # the staged values: key -> file spelling, validated by the schema before it got here. The
  # window writes nothing until Save, so this table is what the rows, the switch positions and
  # the three footer actions all read.
  $script:SetPending = @{}
  # the footer actions, in the order they are drawn; Primary is the one that carries the accent
  $script:SetActions = @(
    @{ Key = 'defaults'; Label = 'Restore defaults'; Primary = $false },
    @{ Key = 'discard'; Label = 'Discard'; Primary = $false },
    @{ Key = 'save'; Label = 'Save'; Primary = $true }
  )
  $script:SetHotAction = -1
  # the chord line whose delete button is under the pointer, -1 for none
  $script:SetHotDelete = -1
  # the row under the pointer, and whether the close button is: the only two hover states left
  $script:SetHover = -1
  $script:SetCloseHot = $false
  # a shortcut row waiting for its chord, and the modifiers held so far
  $script:SetRecKey = ''
  $script:SetRecPreview = @()
  # how far each switch has travelled, 0 or 1 at rest: the window eases these on a timer so a
  # flip moves instead of blinking between two states
  $script:SetToggleK = @{}
  $script:SetToggleTarget = @{}
  $script:SetDrop = $null
  $script:SetDropKey = ''
  $script:SetDropIndex = -1
  $script:SetDropHover = -1
  $script:SetDropMulti = $false
  # the scrollbar thumb: hover ramp, the pixel that was grabbed, and whether the drag is on
  $script:SetSbK = 0.0
  $script:SetSbHot = $false
  $script:SetSbDrag = -1

  $w = [int](Px 780)
  # the footer holds a 26 px button and every row holds two lines of help, so the window is
  # taller than the rows alone would suggest
  $h = [int](Px 700)
  $layout = Get-SettingsLayout $w $h

  # The list scrolls by distance, not by row: a pixel offset keeps the pointer's grip on a row
  # through a drag and lets the wheel stop between two rows, neither of which a row index can
  # express. Everything that needs a row's y asks Get-SettingsRowTop, so the paint, the editors
  # and the hit tests cannot disagree about where a row is.
  function Get-SettingsScrollTop {
    $room = [int]$script:SetLayout.ListBottom - [int]$script:SetLayout.ListTop
    $all = @($script:SetRows).Count * [int]$script:SetLayout.RowHeight
    return [Math]::Max(0, $all - $room)
  }

  function Set-ScrollTo([int]$value) {
    $max = Get-SettingsScrollTop
    if ($value -lt 0) { $value = 0 }
    if ($value -gt $max) { $value = $max }
    if ($value -eq [int]$script:SetScroll) { return $false }
    $script:SetScroll = $value
    return $true
  }

  function Get-SettingsRowTop([int]$idx) {
    return ([int]$script:SetLayout.ListTop + ($idx * [int]$script:SetLayout.RowHeight) - [int]$script:SetScroll)
  }

  function Refresh-Settings {
    $script:SetRows = @(Get-SettingsRows $schema $groups[$script:SetGroup] $script:SetPending)
    # Every switch is told where its row now points - a staged flip travels there on the timer,
    # and a discard travels back - while a switch that has never been drawn starts there instead
    # of at zero.
    foreach ($row in @($script:SetRows)) {
      if ($row.Kind -ne 'bool') { continue }
      $k = [string]$row.Key
      $v = 0.0
      if ([string]$row.Raw -eq '1') { $v = 1.0 }
      $script:SetToggleTarget[$k] = $v
      if (-not $script:SetToggleK.ContainsKey($k)) { $script:SetToggleK[$k] = $v }
    }
    $vis = Get-SettingsVisibleRows $script:SetLayout
    $maxScroll = [Math]::Max(0, @($script:SetRows).Count - $vis)
    # the offset is a distance, so the clamp is one too, and it needs no visible-row count
    [void](Set-ScrollTo ([int]$script:SetScroll))
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

  # the index a row has in the list right now, so the pointer's fix on it survives a refresh
  function Get-RowIndex($row) {
    if ($null -eq $row) { return -1 }
    $rows = @($script:SetRows)
    for ($i = 0; $i -lt $rows.Count; $i++) { if ([string]$rows[$i].Key -eq [string]$row.Key) { return $i } }
    return -1
  }

  function Set-CurrentGroup([int]$idx) {
    $n = @($groups).Count
    if ($n -eq 0) { return }
    if ($null -ne $script:SetDrop) { Close-Choices }
    $script:SetGroup = (($idx % $n) + $n) % $n
    $script:SetScroll = 0
    $script:SetHover = -1
    Refresh-Settings
    $form.Invalidate()
  }

  # the footer returns to the key chips by itself: a message answers one action, it is not a
  # permanent line of the window
  function Clear-Message {
    $script:SetMsg = ''
    $script:SetMsgErr = $false
    if (-not $form.IsDisposed) { $form.Invalidate() }
  }

  function Show-Message([string]$text, [bool]$bad) {
    $script:SetMsg = $text
    $script:SetMsgErr = $bad
    $form.Invalidate()
    # a refusal is worth reading twice as long as a confirmation
    $ms = [int]$script:Timing['FootInfo']
    if ($bad) { $ms = [int]$script:Timing['FootWarn'] }
    if ($null -ne $script:SetFootTimer -and $ms -gt 0) {
      $script:SetFootTimer.Stop()
      $script:SetFootTimer.Interval = $ms
      $script:SetFootTimer.Start()
    }
  }

  # One change, whatever produced it: a flipped switch, a tick, a picked name, a typed value or a
  # recorded chord. Nothing is written here - Save does that - so the change lives in the staged
  # table and the footer says it is not saved yet.
  function Stage-Setting([string]$key, [string]$value, [string]$what) {
    if (-not $key) { return $false }
    $script:SetPending[$key] = [string]$value
    Refresh-Settings
    Show-Message ($key + ': ' + $what + ', not saved yet') $false
    return $true
  }

  # Save: the staged set written in one pass, then the palette and the rows follow it. The
  # resident is still reloaded once, when the window closes - not here.
  function Save-Settings {
    if ($script:SetPending.Count -eq 0) { return }
    $pending = $script:SetPending
    $r = Save-SettingsValues $pending
    if (-not $r.Ok) { Show-Message ('save failed: ' + [string]$r.Error) $true; return }
    $script:SetPending = @{}
    # the folder the window itself writes to moves with the store location it just saved
    if ($pending.Contains('DataDir')) { $script:StoreDir = [string]$pending['DataDir'] }
    if ($pending.Contains('Theme')) {
      # a new theme has to reach the palette and the fonts before the next paint
      Apply-Theme
      $script:FBody = $null
      [void](Initialize-PanelFonts)
      $script:SetPal = Get-UiPalette
    }
    Refresh-Settings
    $n = [int]$r.Count
    $said = ([string]$n) + ' setting'
    if ($n -ne 1) { $said = $said + 's' }
    Show-Message ($said + ' saved') $false
  }

  # Discard: the file is the truth, so dropping the staged table is the whole action, and every
  # switch travels back to the value it holds.
  function Discard-Settings {
    if ($script:SetPending.Count -eq 0) { return }
    $script:SetPending = @{}
    Refresh-Settings
    Show-Message 'changes discarded' $false
  }

  # Restore defaults: staged like every other change, so the page shows what it would become
  # before anything is written.
  function Restore-SettingsDefaults {
    $next = Get-SettingDefaultStaging $schema $script:SetPending
    if ($next.Count -eq 0) { Show-Message 'every value is already at its default' $false; return }
    foreach ($k in @($next.Keys)) { $script:SetPending[[string]$k] = [string]$next[$k] }
    Refresh-Settings
    $n = $next.Count
    $said = ([string]$n) + ' setting'
    if ($n -ne 1) { $said = $said + 's' }
    Show-Message ($said + ' back at the default, not saved yet') $false
  }

  # Which footer actions apply right now: the reset one always does, the other two only once
  # something is staged, because saving or discarding nothing would do nothing
  function Test-SettingsActionOn([string]$key) {
    if ($key -eq 'defaults') { return $true }
    return ($script:SetPending.Count -gt 0)
  }

  # one footer action, by the key the action table gives it
  function Invoke-SettingsAction([string]$key) {
    if (-not (Test-SettingsActionOn $key)) { return }
    if ($key -eq 'save') { Save-Settings; return }
    if ($key -eq 'discard') { Discard-Settings; return }
    Restore-SettingsDefaults
  }

  # The value a recorded chord produces: a single hotkey replaces what it holds, a chain gains the
  # chord at the end, which is where the resident tries it last.
  function Get-RecordedValue([string]$key, [string]$chord) {
    foreach ($r in @($script:SetRows)) {
      if ([string]$r.Key -ne $key) { continue }
      if ($r.ContainsKey('Chain') -and [bool]$r.Chain) { return (Get-SettingChordAdded ([string]$r.Raw) $chord) }
      return $chord
    }
    return $chord
  }

  # One chord off a chain. The last one stays: a chain with nothing in it falls back to the
  # default list, so removing it has to be refused the way an empty Plugins= is.
  function Remove-SettingChord($row, [int]$index) {
    $chords = @($row.Chords)
    if ($index -lt 0 -or $index -ge $chords.Count) { return }
    $next = Get-SettingChordRemoved ([string]$row.Raw) ([string]$chords[$index])
    if ($null -eq $next) {
      Show-Message 'keep at least one: a chain with no chord falls back to the default' $true
      return
    }
    [void](Stage-Setting ([string]$row.Key) $next ('removed ' + [string]$chords[$index]))
  }

  # which chord line of a chain is under the pointer, -1 for none
  function Get-ChordDeleteAt($row, [int]$rowTop, [int]$px, [int]$py) {
    if ($null -eq $row) { return -1 }
    if (-not ($row.ContainsKey('Chain') -and [bool]$row.Chain)) { return -1 }
    $drawn = [Math]::Min(@($row.Chords).Count, 3)
    for ($i = 0; $i -lt $drawn; $i++) {
      $rc = Get-SettingsChordDeleteRect $script:SetLayout $rowTop $i
      if ($px -ge [int]$rc.Left -and $px -le ([int]$rc.Left + [int]$rc.Width) -and
        $py -ge [int]$rc.Top -and $py -le ([int]$rc.Top + [int]$rc.Height)) { return $i }
    }
    return -1
  }

  function End-Edit([bool]$cancel) {
    $box = $script:SetEditBox
    $script:SetEditBox = $null
    $script:SetEditKey = ''
    $script:SetEditRect = $null
    $script:SetEditBad = $false
    $script:SetEditField = @{ Number = $false; Scale = 1; Unit = '' }
    if ($null -ne $box) {
      try { $form.Controls.Remove($box); $box.Dispose() } catch { }
    }
    # the keyboard goes back to the window, so a field that is closed does not keep the caret
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
    # a number is typed in the unit the row shows, so it is turned back into the stored value
    # before the schema looks at it - ranges stay stated once, in bytes or milliseconds
    $r = $null
    if ($script:SetEditField.Number) { $r = Convert-SettingNumberInput $schema $key ([string]$box.Text) ([double]$script:SetEditField.Scale) }
    else { $r = Convert-SettingInput $schema $key ([string]$box.Text) }
    if (-not $r.Ok) {
      # the field is what the refusal is about, so the field is what turns red - not whatever
      # message happened to be in the footer a moment ago
      $script:SetEditBad = $true
      Show-Message ($key + ': ' + [string]$r.Error) $true
      return
    }
    $what = 'set to ' + [string]$r.Value
    if ($script:SetEditField.Number) {
      $said = ([string]$box.Text).Trim()
      if ($script:SetEditField.Unit) { $said = $said + ' ' + [string]$script:SetEditField.Unit }
      $what = 'set to ' + $said
    }
    [void](Stage-Setting $key ([string]$r.Value) $what)
    End-Edit $false
  }

  function Begin-Edit($row) {
    if ($null -eq $row) { return }
    if ($row.Kind -eq 'bool') { return }
    if (-not (Test-RowEnabled $row)) { Show-RowRefused $row; return }
    $idx = Get-RowIndex $row
    if ($idx -lt 0) { return }
    End-Edit $true
    $rowTop = Get-SettingsRowTop $idx
    $isNumber = ($row.Kind -eq 'number')
    $rect = Get-SettingEditRect $script:SetLayout $rowTop (Get-SettingsControlWidth $row)
    if ($isNumber) { $rect = Get-SettingsNumberRect $script:SetLayout $rowTop }
    $script:SetEditKey = [string]$row.Key
    $script:SetEditRect = $rect
    $script:SetEditBad = $false
    $script:SetEditField = @{ Number = $isNumber; Scale = [double]$row.Scale; Unit = [string]$row.Unit }
    $boxW = [int]$rect.Width - (Px 8)
    if ($isNumber) {
      # the unit stays on screen while the number is edited, so the box stops before it
      $boxW = [int]$rect.Width - (Get-SettingsUnitWidth ([string]$row.Unit)) - (Px 6)
    }
    $box = New-SettingEditor $form $pal ([int]$rect.Left + (Px 4)) ([int]$rect.Top + (Px 4)) $boxW ([int]$rect.Height - (Px 8)) $isNumber
    $box.Text = Get-SettingEditSeed $schema ([string]$row.Key) ([string]$row.Raw)
    if ($isNumber) {
      # the value hugs the right edge of the field's text area and grows to the left as it is
      # typed, which is what a number field does without ES_RIGHT's caret sitting on the digit
      $rightEdge = [int]$rect.Left + [int](Px 4) + $boxW
      $minW = [int](Px 30)
      Fit-EditorBox $box $rightEdge $minW $boxW
      $box.Add_TextChanged({ Fit-EditorBox $box $rightEdge $minW $boxW }.GetNewClosure())
    }
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
    # cleared after the window is gone: the last paint during Close still reads it
    $script:SetDropMulti = $false
    try { $form.Activate() } catch { }
    $form.Invalidate()
  }

  # the value the open list is listing, read from the row itself: a tick has to show the setting
  # as it is now, not as it was when the list opened. The list remembers the key it is listing
  # rather than the position, because a write rebuilds the rows.
  function Get-DropRaw {
    if (-not $script:SetDropKey) { return '' }
    foreach ($r in @($script:SetRows)) { if ([string]$r.Key -eq [string]$script:SetDropKey) { return [string]$r.Raw } }
    return ''
  }

  # Tick one name in the open list and write the whole list back. A setting that would be left
  # empty is refused: an empty Plugins= means every plugin on disk, so unticking the last one
  # would read as "all of them" the moment the window redrew.
  function Toggle-DropItem([string]$name) {
    $key = ''
    if ($null -ne $script:SetDrop -and $null -ne $script:SetDrop.Tag) { $key = [string]$script:SetDrop.Tag.Key }
    if (-not $key) { return }
    $raw = Get-DropRaw
    $next = Get-SettingListToggled $raw $name
    if ($null -eq $next) {
      Show-Message ('keep at least one: an empty ' + $key + ' means every one') $true
      return
    }
    $what = 'unticked '
    if (-not (Get-SettingListOn $raw $name)) { $what = 'ticked ' }
    [void](Stage-Setting $key $next ($what + $name))
    if ($null -ne $script:SetDrop) { try { $script:SetDrop.Invalidate() } catch { } }
  }

  function Open-Choices($row) {
    if ($null -eq $row) { return }
    if (-not (Test-RowEnabled $row)) { Show-RowRefused $row; return }
    $choices = @()
    if ($row.ContainsKey('Choices')) { $choices = @($row.Choices) }
    if ($choices.Count -eq 0) { Begin-Edit $row; return }
    if ($null -ne $script:SetDrop) { Close-Choices; return }
    $idx = Get-RowIndex $row
    if ($idx -lt 0) { return }
    $current = [string]$row.Raw
    $multi = $false
    if ($row.ContainsKey('Multi')) { $multi = [bool]$row.Multi }
    $rowTop = Get-SettingsRowTop $idx
    $rect = Get-SettingDropRect $script:SetLayout $rowTop @($choices).Count
    $script:SetDropKey = [string]$row.Key
    $script:SetDropMulti = $multi
    $script:SetDropIndex = -1
    if (-not $multi) {
      for ($i = 0; $i -lt $choices.Count; $i++) { if ([string]$choices[$i] -eq $current) { $script:SetDropIndex = $i } }
    }
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
        # the same frame call and the same radius the window uses: the region clips at
        # Get-WindowRadius, so a ring drawn on any other radius is cut where it turns
        Draw-PanelFrame $g $cw $ch $p['Border'] (Get-WindowRadius) $p['Field']
        $sf = New-PickerStringFormats
        $list = @($s.Tag.Choices)
        $itemH = Px 30
        $bandH = [int]($itemH - (Px 2))
        $multi = [bool]$script:SetDropMulti
        $raw = Get-DropRaw
        for ($i = 0; $i -lt $list.Count; $i++) {
          $top = [int](Px 4) + ($i * $itemH)
          $isCur = ($i -eq $script:SetDropIndex)
          $isHot = ($i -eq $script:SetDropHover)
          $shown = (-not $multi) -and $isCur
          if ($isHot -or $shown) {
            $tint = $p['HoverBg']
            # the value in the file carries the accent, the way a selected entry does in the
            # panel: a hover tint alone is too quiet to tell "this is the one" from "this is
            # under the pointer"
            if ($shown) { $tint = $p['AccentSoft'] }
            $b = New-Object Drawing.SolidBrush $tint
            $path = New-RoundPath (Px 4) $top ($cw - (2 * (Px 4))) $bandH (Px 4)
            try { $g.FillPath($b, $path) } finally { $path.Dispose(); $b.Dispose() }
          }
          $ink = $p['Dim']
          if ($shown -or $isHot) { $ink = $p['Text'] }
          $textLeft = Px 12
          if ($multi) { $textLeft = Px 34 }
          $text = [string]$list[$i]
          if ($multi) {
            # The tick is centred on the band the name is centred in, one pixel up: a 16 px box
            # on the band's centre leaves its bottom edge below the text baseline (measured on
            # the rendered pixels), which is what made it read as sitting low.
            $tick = Px 16
            Draw-SettingsTick $g $p (Px 12) ($top + [int](($bandH - $tick) / 2) - [int](Px 1)) $tick (Get-SettingListOn $raw $text)
          }
          # A choice that names keys is drawn as the keys it sends: the list is where a person
          # picks which combination to paste with, and "^+{INSERT}" is not a thing anyone reads.
          $keys = @(Get-SettingChoiceKeys $text)
          if ($keys.Count -gt 0) {
            [void](Draw-SettingChord $g $p $textLeft ($top + [int]($bandH / 2)) $keys $true $false 'left')
            continue
          }
          $tb = New-Object Drawing.RectangleF -ArgumentList @(
            [single]$textLeft, [single]$top, [single]($cw - $textLeft - (Px 12)), [single]$bandH)
          $g.DrawString($text, $script:FBody, (Get-Brush $ink), $tb, $sf.Ellipsis)
        }
      } catch { Write-Log ('settings drop paint: ' + $_.Exception.Message) }
    })
    $dd.Add_MouseMove({
      param($s, $e)
      $i = [int][Math]::Floor(($e.Y - (Px 4)) / (Px 30))
      if ($i -ge @($s.Tag.Choices).Count -or $i -lt 0) { $i = -1 }
      if ($i -ne $script:SetDropHover) { $script:SetDropHover = $i; $s.Invalidate() }
    })
    $dd.Add_MouseDown({
      param($s, $e)
      $i = [int][Math]::Floor(($e.Y - (Px 4)) / (Px 30))
      $list = @($s.Tag.Choices)
      if ($i -lt 0 -or $i -ge $list.Count) { return }
      if ([bool]$script:SetDropMulti) {
        # a tick is not a choice, so the list stays open for the next one
        $script:SetDropIndex = $i
        Toggle-DropItem ([string]$list[$i])
        return
      }
      [void](Stage-Setting ([string]$s.Tag.Key) ([string]$list[$i]) ('set to ' + [string]$list[$i]))
      Close-Choices
    })
    $dd.Add_Deactivate({ Close-Choices })
    $script:SetDrop = $dd
    $dd.Show()
    try { $dd.Activate() } catch { }
  }

  # one switch, flipped where it was clicked: the only thing a bool row does. The flip starts
  # from what the row shows - the staged value when there is one - so a second click lands back
  # on the value the file holds.
  function Flip-Row($row) {
    if ($null -eq $row) { return }
    if (-not (Test-RowEnabled $row)) { Show-RowRefused $row; return }
    $v = '1'
    if ([string]$row.Raw -eq '1') { $v = '0' }
    [void](Stage-Setting ([string]$row.Key) $v ('turned ' + $(if ($v -eq '1') { 'on' } else { 'off' })))
  }

  # A shortcut is recorded, not typed: a spelled-out chord is the one value that is easier to get
  # wrong on paper than by pressing it. The row waits for one chord; the caps show what is held
  # while the keys are down.
  function Start-Record($row) {
    if ($null -eq $row) { return }
    if (-not (Test-RowEnabled $row)) { Show-RowRefused $row; return }
    End-Edit $true
    $script:SetRecKey = [string]$row.Key
    $script:SetRecPreview = @()
    [void](Start-HotkeyRecord ([string]$script:StoreDir))
    try { $form.Focus() } catch { }
    Show-Message ('Press the keys for ' + [string]$row.Label + ', Esc to cancel') $false
    $form.Invalidate()
  }

  function Cancel-Record {
    if (-not $script:SetRecKey) { return }
    $script:SetRecKey = ''
    $script:SetRecPreview = @()
    Stop-HotkeyRecord ([string]$script:StoreDir)
    Show-Message 'recording cancelled' $false
    $form.Invalidate()
  }

  # the chord the resident handed over, applied as if it had been pressed here
  function Apply-RecordedChord([string]$chord) {
    if (-not $script:SetRecKey -or -not $chord) { return }
    if (-not (Test-ChordUsable $chord)) {
      Show-Message ('that key cannot be used on its own: ' + $chord) $true
      return
    }
    $key = [string]$script:SetRecKey
    $script:SetRecKey = ''
    $script:SetRecPreview = @()
    [void](Stage-Setting $key (Get-RecordedValue $key $chord) ('set to ' + $chord))
    $form.Invalidate()
  }

  # A folder is chosen, not typed: the store location is a path, and a path typed by hand is a
  # path that does not exist. The picker is the system one, so it knows the drives and the
  # shares the user has.
  function Pick-Folder($row) {
    if ($null -eq $row) { return }
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    try {
      $dlg.Description = 'Where the history and the media files live'
      $dlg.ShowNewFolderButton = $true
      $cur = [string]$row.Raw
      if ($cur -and (Test-Path -LiteralPath $cur)) { $dlg.SelectedPath = $cur }
      if ($dlg.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
      $picked = [string]$dlg.SelectedPath
      if (-not $picked) { return }
      # the folder is staged like any other value: the row shows it, and Save moves the store
      if (-not (Stage-Setting ([string]$row.Key) $picked ('set to ' + $picked))) { return }
      $form.Invalidate()
    } catch {
      Show-Message ('folder picker failed: ' + $_.Exception.Message) $true
    } finally { try { $dlg.Dispose() } catch { } }
  }

  # the modifiers held right now, as the caps to show while the row waits for its key
  function Get-RecPreview($e) {
    $mods = @()
    if (Test-ChordWinHeld) { $mods += 'Win' }
    if ($e.Control) { $mods += 'Ctrl' }
    if ($e.Alt) { $mods += 'Alt' }
    if ($e.Shift) { $mods += 'Shift' }
    return $mods
  }

  # One key of a recording. A modifier on its own only updates the caps; the first key that is not
  # a modifier completes the chord, and a key the tool cannot register is refused with the reason.
  function Record-Key($e) {
    if ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) {
      Cancel-Record
      $e.Handled = $true
      $e.SuppressKeyPress = $true
      return
    }
    $modOnly = @(
      [Windows.Forms.Keys]::ControlKey, [Windows.Forms.Keys]::Menu, [Windows.Forms.Keys]::ShiftKey,
      [Windows.Forms.Keys]::LWin, [Windows.Forms.Keys]::RWin
    )
    if ($modOnly -contains $e.KeyCode) {
      $script:SetRecPreview = @(Get-RecPreview $e)
      $form.Invalidate()
      $e.Handled = $true
      return
    }
    $name = Get-ChordKeyName $e.KeyCode
    if (-not $name) {
      Show-Message 'that key cannot be a hotkey: use a letter, a digit, F1-F24, Insert, Delete, Home, End, PageUp, PageDown or Space' $true
      return
    }
    $chord = Format-ChordValue (Test-ChordWinHeld) $e.Control $e.Alt $e.Shift $name
    if (-not (Test-ChordUsable $chord)) {
      # a bare letter would take that key away from every program
      Show-Message 'a hotkey needs a modifier, or an F1-F24 key on its own' $true
      return
    }
    $key = [string]$script:SetRecKey
    $script:SetRecKey = ''
    $script:SetRecPreview = @()
    Stop-HotkeyRecord ([string]$script:StoreDir)
    [void](Stage-Setting $key (Get-RecordedValue $key $chord) ('set to ' + $chord))
    $e.Handled = $true
    $e.SuppressKeyPress = $true
    $form.Invalidate()
  }

  $form = New-Object Cb.FluentForm
  $form.Activates = $true
  $form.FormBorderStyle = 'None'
  $form.StartPosition = 'Manual'
  $form.ShowInTaskbar = $true
  $form.KeyPreview = $true
  $form.Text = 'Settings'
  $form.AccessibleName = 'Settings'
  # The one mark the tool draws (lib\native.ps1): the same icon the tray shows, so the taskbar
  # button and Alt-Tab never carry a second drawing of it.
  $icon = New-AppIcon
  if ($null -ne $icon) { $form.Icon = $icon }
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
      Draw-SettingsChrome $g $pal $layout 'Settings' ([string]$groups[$script:SetGroup])
      Draw-SettingsSide $g $pal $layout $groups $script:SetGroup
      $vis = Get-SettingsVisibleRows $layout
      # A pixel offset leaves a half row at each end: the first index and the remainder of the
      # offset place them, and the clip keeps the top one out of the header and the bottom one
      # out of the footer - both are drawn from the same list, with nothing snapped.
      $rowH = [int]$layout.RowHeight
      $off = [int]$script:SetScroll
      $first = 0
      if ($rowH -gt 0) { $first = [int][Math]::Floor($off / [double]$rowH) }
      $base = [int]$layout.ListTop - ($off - ($first * $rowH))
      $x = [int]$layout.ListLeft
      $width = [int]$layout.ListRight - [int]$layout.ListLeft
      $clipState = $g.Save()
      try {
        $g.SetClip((New-Object Drawing.Rectangle -ArgumentList @($x, [int]$layout.ListTop, $width, ([int]$layout.ListBottom - [int]$layout.ListTop))))
        for ($i = 0; $i -le $vis; $i++) {
          $idx = $first + $i
          if ($idx -ge @($rows).Count) { break }
          $rowTop = $base + ($i * $rowH)
          $row = $rows[$idx]
          $k = 1.0
          if ($row.Kind -eq 'bool') {
            $name = [string]$row.Key
            if ($script:SetToggleK.ContainsKey($name)) { $k = [double]$script:SetToggleK[$name] }
            elseif ([string]$row.Raw -eq '1') { $k = 1.0 } else { $k = 0.0 }
          }
          $armed = ($script:SetRecKey -and ($script:SetRecKey -eq [string]$row.Key))
          $editingRow = ($script:SetEditKey -and ($script:SetEditKey -eq [string]$row.Key))
          $hotDel = -1
          if ($idx -eq $script:SetHover) { $hotDel = $script:SetHotDelete }
          Draw-SettingsRow $g $pal $layout $row $x $rowTop $width ($idx -eq $script:SetHover) $k $armed @($script:SetRecPreview) $editingRow $hotDel
        }
      } finally { $g.Restore($clipState) }
      $thumb = Get-SettingsScrollThumb $layout @($rows).Count $vis $script:SetScroll
      Draw-SettingsScrollbar $g $pal $layout $thumb $script:SetSbK
      if ($script:SetEditKey -and $null -ne $script:SetEditRect) {
        # the same field the row draws, focused: the value is in the text box, the unit stays drawn
        $mode = 'edit'
        if ($script:SetEditBad) { $mode = 'bad' }
        Draw-SettingsValueField $g $pal $script:SetEditRect '' ([string]$script:SetEditField.Unit) $true $mode
      }
      # the close button, top right, where every window puts one
      Draw-SettingsClose $g $pal $layout $script:SetCloseHot
      # the footer is the window's own bar: the last change on the left, the actions on the right.
      # A page with nothing to act on (About) has no actions at all - a Save that can only ever be
      # disabled says the window is broken rather than that the page is a statement. A read-only
      # row with a folder picker still stages a value, so the pick counts as something to act on.
      # each action carries its own state: the reset one stays available, the pair waits for a change
      $acts = @()
      $actionable = @($script:SetRows | Where-Object {
          (-not $_.Locked) -or ($_.ContainsKey('Pick') -and [string]$_.Pick)
        })
      if ($actionable.Count -gt 0) {
        $acts = @(foreach ($a in $script:SetActions) {
          $copy = @{}
          foreach ($k in $a.Keys) { $copy[$k] = $a[$k] }
          $copy['Enabled'] = (Test-SettingsActionOn ([string]$a.Key))
          $copy
        })
      }
      Draw-SettingsFooter $g $pal $layout $script:SetMsg $script:SetMsgErr $acts ($script:SetPending.Count -gt 0) $script:SetHotAction
    } catch {
      Write-Log ('settings paint: ' + $_.Exception.Message + ' @ ' + $_.ScriptStackTrace)
    }
  })

  # The window answers no shortcut of its own: every row is acted on with the pointer. The keys it
  # listens for are the ones a value needs - the field's Enter and Esc, and the chord a recording
  # row is waiting for. Esc with nothing open closes the window, the habit every dialog has.
  $form.Add_KeyDown({
    param($s, $e)
    if ($null -ne $script:SetEditBox) {
      if ($e.KeyCode -eq [Windows.Forms.Keys]::Enter) {
        Complete-Edit
        $e.Handled = $true
        $e.SuppressKeyPress = $true
      } elseif ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) {
        End-Edit $true
        $e.Handled = $true
        $e.SuppressKeyPress = $true
      }
      return
    }
    if ($script:SetRecKey) { Record-Key $e; return }
    if ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) {
      $form.Close()
      $e.Handled = $true
    }
  })

  $form.Add_MouseWheel({
    param($s, $e)
    # the wheel scrolls the page - it never changes a value and never picks a row. A notch is the
    # system's line count and a line is a line of text, not a row: a list that jumps a whole row
    # per notch cannot be read while it moves
    $lines = 3
    try { $lines = [int][Windows.Forms.SystemInformation]::MouseWheelScrollLines } catch { }
    $step = 0
    if ($lines -lt 0) {
      $step = [int]$script:SetLayout.ListBottom - [int]$script:SetLayout.ListTop
    } elseif ($lines -gt 0) {
      $step = $lines * [int](Px 20)
    } else {
      $step = 3 * [int](Px 20)
    }
    $dir = 1
    if ($e.Delta -gt 0) { $dir = -1 }
    if (Set-ScrollTo ([int]$script:SetScroll + ($dir * $step))) { $form.Invalidate() }
  })

  # The thumb follows the pointer by distance: the press point keeps its grip, and the offset is
  # mapped through the same span the paint used, so a drag of one pixel moves the list by the
  # matching fraction of a pixel instead of snapping to the next row.
  function Scroll-ToThumb([int]$thumbTop) {
    $thumb = Get-SettingsScrollThumb $script:SetLayout @($script:SetRows).Count (Get-SettingsVisibleRows $script:SetLayout) $script:SetScroll
    if ($null -eq $thumb) { return }
    $room = [int]$thumb.TrackLen - [int]$thumb.Len
    if ($room -le 0) { return }
    $v = [int][Math]::Round((($thumbTop - [int]$thumb.TrackTop) * [int]$thumb.Span) / [double]$room)
    if (Set-ScrollTo $v) { $form.Invalidate() }
  }

  $form.Add_MouseMove({
    param($s, $e)
    if ($script:SetSbDrag -ge 0) { Scroll-ToThumb ($e.Y - $script:SetSbDrag); return }
    $lane = Get-SettingsScrollLane $script:SetLayout
    $hot = ($e.X -ge [int]$lane.Left -and $e.X -le ([int]$lane.Left + [int]$lane.Width) -and
      $e.Y -ge [int]$lane.Top -and $e.Y -le ([int]$lane.Top + [int]$lane.Height))
    if ($hot -ne $script:SetSbHot) {
      # the thumb widens and darkens as the pointer arrives, the way the panel's own does
      $script:SetSbHot = $hot
      $form.Invalidate()
    }
    $close = Get-SettingsCloseRect $script:SetLayout
    $overClose = ($e.X -ge [int]$close.Left -and $e.X -le ([int]$close.Left + [int]$close.Width) -and
      $e.Y -ge [int]$close.Top -and $e.Y -le ([int]$close.Top + [int]$close.Height))
    if ($overClose -ne $script:SetCloseHot) { $script:SetCloseHot = $overClose; $form.Invalidate() }
    # the footer actions light up under the pointer the way the edit card's buttons do
    $rects = @(Get-SettingsActionRects $script:SetLayout @($script:SetActions | ForEach-Object { [string]$_.Label }))
    $hotAction = -1
    for ($i = 0; $i -lt $rects.Count; $i++) {
      if (-not (Test-SettingsActionOn ([string]$script:SetActions[$i].Key))) { continue }
      $rc = $rects[$i]
      if ($e.X -lt [int]$rc.Left -or $e.X -gt ([int]$rc.Left + [int]$rc.Width)) { continue }
      if ($e.Y -lt [int]$rc.Top -or $e.Y -gt ([int]$rc.Top + [int]$rc.Height)) { continue }
      $hotAction = $i
    }
    if ($hotAction -ne $script:SetHotAction) { $script:SetHotAction = $hotAction; $form.Invalidate() }
    $idx = Get-SettingsRowAt $script:SetLayout @($script:SetRows).Count $script:SetScroll $e.X $e.Y
    if ($idx -ne $script:SetHover) { $script:SetHover = $idx; $script:SetHotDelete = -1; $form.Invalidate() }
    # a chord line's delete button is a target of its own
    $hotDel = -1
    if ($idx -ge 0) {
      $rowTop = Get-SettingsRowTop $idx
      $hotDel = Get-ChordDeleteAt $script:SetRows[$idx] $rowTop $e.X $e.Y
    }
    if ($hotDel -ne $script:SetHotDelete) { $script:SetHotDelete = $hotDel; $form.Invalidate() }
  })

  $form.Add_MouseUp({
    param($s, $e)
    if ($script:SetSbDrag -lt 0) { return }
    $script:SetSbDrag = -1
    $form.Capture = $false
    $form.Invalidate()
  })

  $form.Add_MouseDown({
    param($s, $e)
    if ($e.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
    # a recording that did not get its chord is dropped by the next click, the way a field is;
    # clicking the waiting row a second time is what clears it on purpose
    $wasRec = [string]$script:SetRecKey
    if ($wasRec) { $script:SetRecKey = ''; $script:SetRecPreview = @(); $form.Invalidate() }
    # A click anywhere ends the edit that was open. Leaving the field is the only way out of it
    # for a pointer user, and committing is what a settings page does; a value the schema refuses
    # keeps the field open with the reason in the footer.
    if ($null -ne $script:SetEditBox) {
      $box = $script:SetEditBox
      $inside = ($e.X -ge $box.Left -and $e.X -le ($box.Left + $box.Width) -and
        $e.Y -ge $box.Top -and $e.Y -le ($box.Top + $box.Height))
      if (-not $inside) { Complete-Edit }
      # A refusal keeps the field open, and then the click belongs to the field. A committed value
      # lets the same click reach what it pointed at, so Save works with the editor still up.
      if ($null -ne $script:SetEditBox) { return }
    }
    # the footer actions sit below the list, so no row and no lane can be under them
    $acts = @(Get-SettingsActionRects $script:SetLayout @($script:SetActions | ForEach-Object { [string]$_.Label }))
    for ($i = 0; $i -lt $acts.Count; $i++) {
      if (-not (Test-SettingsActionOn ([string]$script:SetActions[$i].Key))) { continue }
      $rc = $acts[$i]
      if ($e.X -lt [int]$rc.Left -or $e.X -gt ([int]$rc.Left + [int]$rc.Width)) { continue }
      if ($e.Y -lt [int]$rc.Top -or $e.Y -gt ([int]$rc.Top + [int]$rc.Height)) { continue }
      Invoke-SettingsAction ([string]$script:SetActions[$i].Key)
      return
    }
    # the scrollbar lane comes before the rows: it sits beside them, and a press on the thumb
    # starts a drag while a press on the track pages toward the click
    $lane = Get-SettingsScrollLane $script:SetLayout
    if ($e.X -ge [int]$lane.Left -and $e.X -le ([int]$lane.Left + [int]$lane.Width) -and
      $e.Y -ge [int]$lane.Top -and $e.Y -le ([int]$lane.Top + [int]$lane.Height)) {
      $thumb = Get-SettingsScrollThumb $script:SetLayout @($script:SetRows).Count (Get-SettingsVisibleRows $script:SetLayout) $script:SetScroll
      if ($null -eq $thumb) { return }
      if ($e.Y -ge [int]$thumb.Top -and $e.Y -le ([int]$thumb.Top + [int]$thumb.Len)) {
        $script:SetSbDrag = $e.Y - [int]$thumb.Top
        $form.Capture = $true
      } else {
        $page = [int]$script:SetLayout.ListBottom - [int]$script:SetLayout.ListTop
        $to = [int]$script:SetScroll - $page
        if ($e.Y -gt [int]$thumb.Top) { $to = [int]$script:SetScroll + $page }
        if (Set-ScrollTo $to) { $form.Invalidate() }
      }
      return
    }
    # the close button first: it sits in the header, above everything else
    $close = Get-SettingsCloseRect $script:SetLayout
    if ($e.X -ge [int]$close.Left -and $e.X -le ([int]$close.Left + [int]$close.Width) -and
      $e.Y -ge [int]$close.Top -and $e.Y -le ([int]$close.Top + [int]$close.Height)) {
      $form.Close()
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
    $row = $script:SetRows[$idx]
    # a page that states facts rather than settings has nothing to click
    if ($row.Kind -eq 'info') { return }
    if ($row.ContainsKey('Pick') -and $row.Pick) {
      Pick-Folder $row
      return
    }
    if ($row.ContainsKey('Locked') -and $row.Locked) {
      Show-Message ([string]$row.Label + ': ' + [string]$row.Help) $true
      return
    }
    if (-not (Test-RowEnabled $row)) {
      Show-RowRefused $row
      $form.Invalidate()
      return
    }
    # A chord line can be removed on its own: its delete button is a target inside the row, and
    # it is checked before the row's own action, which would start a recording.
    if ($row.ContainsKey('Chain') -and [bool]$row.Chain) {
      $rowTop = Get-SettingsRowTop $idx
      $on = Get-ChordDeleteAt $row $rowTop $e.X $e.Y
      if ($on -ge 0) { Remove-SettingChord $row $on; return }
    }
    # every row is its own control: a click on a switch row flips it wherever it lands, a click
    # on a shortcut waits for a chord, a click on a value opens its list, and anything else is
    # typed - there is no select-then-act step
    if ($row.ContainsKey('Record') -and $row.Record) {
      if ($wasRec -ne [string]$row.Key) { Start-Record $row } else { Show-Message 'recording cancelled' $false }
      return
    }
    if ($row.Kind -eq 'bool') {
      Flip-Row $row
      return
    }
    if ($row.ContainsKey('Choices') -and @($row.Choices).Count -gt 0) {
      Open-Choices $row
      return
    }
    Begin-Edit $row
  })

  # Bring this window forward, whoever asked for it. The request may come from another process,
  # where SetForegroundWindow is refused while that process owns the foreground, so the panel's
  # own routine is reused; a minimized window is restored first, or the bar has nothing to show.
  function Raise-Settings {
    try {
      if ($null -eq $form -or $form.IsDisposed) { return }
      if ($form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) {
        $form.WindowState = [Windows.Forms.FormWindowState]::Normal
      }
      [void](Take-Foreground $form.Handle)
      $form.Activate()
    } catch { }
  }

  # A switch that flips in one frame reads as a jump. One timer eases every switch in flight and
  # asks for a repaint only while something moves, so a window sitting still costs nothing;
  # Animations=0 makes the step 1.0, which lands on the target in a single frame. The scrollbar
  # ramp rides the same timer, at the same step the panel uses for its own thumb.
  $script:SetFootTimer = New-Object Windows.Forms.Timer
  $script:SetFootTimer.Add_Tick({ $script:SetFootTimer.Stop(); Clear-Message })

  $animTimer = New-Object Windows.Forms.Timer
  $animTimer.Interval = 15
  $animTimer.Add_Tick({
    if ($form.IsDisposed) { return }
    # a second request for the window: this process may be the one that owns it, or the other
    # way round, so the signal is checked here, on the loop that is already running
    try { if ($null -ne $script:SetAsk -and $script:SetAsk.WaitOne(0)) { Raise-Settings } } catch { }
    # a chord the resident handed over: it owns the key RegisterHotKey took, so this is the only
    # way the window can see it while recording
    if ($script:SetRecKey) {
      $chord = Read-HotkeyRecord ([string]$script:StoreDir)
      if ($chord) {
        Stop-HotkeyRecord ([string]$script:StoreDir)
        Apply-RecordedChord $chord
      }
    }
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
    # the scrollbar ramp: 1 under the pointer or while dragging, 0 otherwise
    $sbWant = 0.0
    if ($script:SetSbHot -or $script:SetSbDrag -ge 0) { $sbWant = 1.0 }
    $sbNow = [double]$script:SetSbK
    if ([Math]::Abs($sbWant - $sbNow) -gt 0.01) {
      $sbNext = $sbNow + (($sbWant - $sbNow) * $step)
      if ([Math]::Abs($sbWant - $sbNext) -lt 0.02) { $sbNext = $sbWant }
      $script:SetSbK = $sbNext
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

  # Leaving with staged work would drop it without a word, and once the window is gone there is
  # nowhere to say so: the one question is asked here, and No keeps the window open with the
  # staged values still in place.
  $form.Add_FormClosing({
    param($s, $e)
    if ($script:SetPending.Count -eq 0) { return }
    try {
      $ans = [Windows.Forms.MessageBox]::Show($form, 'Close without saving? The changed values are dropped.', 'Settings',
        [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning,
        [Windows.Forms.MessageBoxDefaultButton]::Button2)
      if ($ans -ne [Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true }
    } catch { }
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
    try { $script:SetFootTimer.Stop(); $script:SetFootTimer.Dispose() } catch { }
    Stop-HotkeyRecord ([string]$script:StoreDir)
    Close-Choices
    End-Edit $true
    try { $form.Dispose() } catch { }
    & $releaseSettings
    # one reload for the whole session, and only when a written key needed the resident to
    # read the file again (an install-only key does not)
    if ($script:SettingsDirty) {
      try { Restart-ResidentIfRunning } catch { }
      $script:SettingsDirty = $false
    }
  }
}

# renderer\src\windows\settings.ps1 - the settings window: one function owns its lifecycle.
#
# The window is the same object the history panel is: a Cb.FluentForm with a rounded region, a
# custom paint, the theme's palette and the shared type ramp. What differs is what it does not
# do - it never takes the caret, never pastes, and it stays open when it loses the foreground,
# because a settings window is a place the user returns to rather than a flyout.
#
# Values are staged, not written: every change lands in one pending table that the rows are
# drawn from, and Save writes the whole table in one pass (renderer/src/components/settings-edit.ps1). The
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
# opening it and letting go again. The picker asks before it opens: see renderer\src\windows\picker.ps1.
function Test-SettingsWindowOpen([string]$name = '') {
  $lock = Open-SettingsLock $name
  if ($null -eq $lock) { return $true }
  try { $lock.Dispose() } catch { }
  return $false
}

# -Group opens on that page instead of the first one: the tray's About entry lands on About,
# which is where the version, the store and the loaded plugins are stated. An unknown name falls
# back to the first page - a window on the wrong page is still a window that opens.
function Show-Settings {
  param([string]$Group = '')
  $swOpen = [Diagnostics.Stopwatch]::StartNew()
  Load-Forms
  Add-Native
  # One settings window per session. A second `clipboard settings`, or the tray entry while the
  # command line already opened it, brings that window forward instead of adding a copy beside it.
  #
  # The page this request asked for stays where the open window's own loop can read it: the ring
  # carries no payload. The tray entries open the window in this process, so this is the same
  # scope; a request from another process only raises the window.
  $script:SetWantGroup = [string]$Group
  # The handle stays a local of this call. A request that finds the lock taken must not touch it:
  # kept in one script variable, that request would clear it, and the window closing next would
  # have nothing left to release - the name would outlive it and no window could open again.
  $lock = Open-SettingsLock
  if ($null -eq $lock) {
    # the open window creates its doorbell right after the lock, so a request landing in between
    # waits for it rather than going unanswered
    for ($i = 0; $i -lt 20; $i++) { if (Ring-SettingsAsk) { break }; Start-Sleep -Milliseconds 25 }
    Write-Log 'settings: a window is already open, asked it to come forward'
    return
  }
  # the page below comes from the parameter itself, so nothing is left behind for the loop to apply
  $script:SetWantGroup = ''
  $script:SetAsk = Open-SettingsAsk
  # the ways out of here before the window exists (a schema that cannot be read) take the lock
  # with them: left behind, it would keep the process from ever opening a window again
  $releaseSettings = {
    if ($null -ne $script:SetAsk) { try { $script:SetAsk.Dispose() } catch { }; $script:SetAsk = $null }
    if ($null -ne $lock) { try { $lock.Dispose() } catch { } }
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
  if ($Group) {
    for ($g = 0; $g -lt $groups.Count; $g++) {
      if ([string]$groups[$g] -eq $Group) { $script:SetGroup = $g; break }
    }
  }
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
  # The rows of a page are kept by page, staged set and the state of the file, and the cache
  # outlives the window: opening the settings window a second time in one process used to build
  # every row again, because the cache died with the first window.
  if ($null -eq $script:SetRowCache) { $script:SetRowCache = New-UiKeepAlive 12 }
  # the page whose rows are in $script:SetRows, so the next refresh can be a diff instead of a build
  $script:SetPage = ''
  # that page's rows as a node tree (renderer\src\core\framework.ps1): the patch keeps the rows that did not
  # move and mounts only the ones that did, so a page is never rebuilt to change one value
  $script:SetPageNode = $null
  # the staged values: key -> file spelling, validated by the schema before it got here. The
  # window writes nothing until Save, so this table is what the rows, the switch positions and
  # the three footer actions all read.
  $script:SetPending = @{}
  # the pages those staged values live on, which is what the page list marks
  $script:SetPendingGroups = @()
  # The footer actions, in the order they are drawn; Primary is the one that carries the accent.
  # The labels are read again whenever the language can have changed: the window stays open after
  # a save, so its buttons must not keep the words they were built with.
  function Update-SettingsActions {
    $script:SetActions = @(
      @{ Key = 'defaults'; Label = (Get-UiText 'settings.action.defaults'); Primary = $false },
      @{ Key = 'discard'; Label = (Get-UiText 'settings.action.discard'); Primary = $false },
      @{ Key = 'save'; Label = (Get-UiText 'settings.action.save'); Primary = $true }
    )
  }
  Update-SettingsActions
  # The window's own controls - the two caption buttons and the footer actions - are view nodes
  # (renderer\src\components\views.ps1), kept on one parent so the patch can leave the ones that did not change
  # alone. Their boxes come from the layout, their hover from the node's own state: a pointer
  # crossing Save repaints Save, not the window.
  #
  # The parent is declared the way <script setup> declares a component (renderer\src\core\setup.ps1): it takes
  # its content from the window through a slot, so the button row does not know what the buttons
  # are, and the window does not have to call it whenever the set changes.
  $script:SetChromeFactory = New-UiSetupView 'chrome' @{ } {
    param($ctx)
    return @{ Slot = (Use-UiSlot $ctx 'actions') }
  }
  $script:SetChrome = & $script:SetChromeFactory @{
    Key = ''
    Slots = @{
      actions = {
        param($scope)
        # A page with nothing to act on (About) has no actions at all - a Save that can only ever
        # be disabled says the window is broken rather than that the page is a statement. A
        # read-only row with a folder picker still stages a value, so the pick counts.
        $actionable = @($script:SetRows | Where-Object {
            (-not $_.Locked) -or ($_.ContainsKey('Pick') -and [string]$_.Pick)
          })
        $script:SetActionSpecs = @()
        if ($actionable.Count -gt 0) { $script:SetActionSpecs = @($script:SetActions) }
        return $script:SetActionSpecs
      }
    }
  }
  [void](Mount-UiComponent $script:SetChrome)
  # the controls the rows own (a chord line's delete cross, the plus that adds one), kept apart
  # from the rows themselves so a hover on one of them invalidates 16 x 16 and nothing else
  $script:SetControls = New-UiView 'controls' '' @{ }
  [void](Mount-UiComponent $script:SetControls)
  # what the control list was last built for: a pointer move that changes none of it does not
  # rebuild the list
  $script:SetCtlStamp = ''
  # the row under the pointer: the controls in it paint their own hover
  $script:SetHover = -1
  # where the pointer grabbed the header: a window with no title bar is moved by its own header
  $script:SetDragFrom = $null
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

  # the band one row occupies: a repaint that has to cover that row and nothing else
  function Get-RowBandRect([int]$idx) {
    if ($idx -lt 0) { return [Drawing.Rectangle]::Empty }
    $rows = @($script:SetRows)
    if ($idx -ge $rows.Count) { return [Drawing.Rectangle]::Empty }
    $layout = $script:SetLayout
    return (New-Object Drawing.Rectangle -ArgumentList @(
      [int]$layout.ListLeft, (Get-SettingsRowTop $idx),
      ([int]$layout.ListRight - [int]$layout.ListLeft), [int]$layout.RowHeight))
  }

  # The rectangle one animation frame has to repaint: the switch that is moving, or the thumb
  # while it ramps. A whole-window repaint redraws the header, the page list, every row and the
  # footer for a 40 x 20 switch, which is what made the easing stutter.
  function Get-AnimationRect {
    $rect = [Drawing.Rectangle]::Empty
    $layout = $script:SetLayout
    $rows = @($script:SetRows)
    foreach ($name in @($script:SetToggleK.Keys)) {
      if ([Math]::Abs([double]$script:SetToggleTarget[$name] - [double]$script:SetToggleK[$name]) -lt 0.001) { continue }
      $idx = -1
      for ($i = 0; $i -lt $rows.Count; $i++) {
        if ([string]$rows[$i].Key -ceq [string]$name) { $idx = $i; break }
      }
      if ($idx -lt 0) { return [Drawing.Rectangle]::Empty }
      $t = Get-SettingsToggleRect $layout (Get-SettingsRowTop $idx)
      $one = New-Object Drawing.Rectangle -ArgumentList @(
        ([int]$t.Left - 4), ([int]$t.Top - 4), ([int]$t.Width + 8), ([int]$t.Height + 8))
      if ($rect.IsEmpty) { $rect = $one } else { $rect = [Drawing.Rectangle]::Union($rect, $one) }
    }
    $sbWant = 0.0
    if ($script:SetSbHot -or $script:SetSbDrag -ge 0) { $sbWant = 1.0 }
    if ([Math]::Abs($sbWant - [double]$script:SetSbK) -gt 0.01) {
      $lane = Get-SettingsScrollLane $layout
      $one = New-Object Drawing.Rectangle -ArgumentList @(
        [int]$lane.Left, [int]$lane.Top, [int]$lane.Width, [int]$lane.Height)
      if ($rect.IsEmpty) { $rect = $one } else { $rect = [Drawing.Rectangle]::Union($rect, $one) }
    }
    return $rect
  }

  function Refresh-Settings {
    # A page's rows are built from the schema and the staged set. Two paths save the work: the
    # same page re-entered comes from the cache, and a page that is already up is diffed against
    # the rows it showed, so one flipped switch rebuilds its own row instead of the whole page.
    $page = [string]$groups[$script:SetGroup]
    # the file itself is part of the key: a value written by `clipboard config set` while this
    # window was closed has to show up, so the cache cannot answer for an older file
    $stamp = ''
    try { if ($script:IniPath) { $stamp = Get-StoreFileStamp ([string]$script:IniPath) } } catch { $stamp = '' }
    $cacheKey = $page + '|' + (Get-SettingsPendingSignature $script:SetPending) + '|' + $stamp + '|' + [string]$script:Language
    $step = $null
    if ($page -ceq [string]$script:SetPage -and $null -ne $script:SetPageNode -and $script:SetPageNode.Children.Count -gt 0) {
      $step = Update-SettingRows $schema $page $script:SetPageNode $script:SetPending
    }
    if ($null -ne $step) {
      $script:SetRows = @($step.Rows)
      Set-UiKeepAliveValue $script:SetRowCache $cacheKey $step.Rows
    } else {
      $script:SetRows = @(Get-UiKeepAlive $script:SetRowCache $cacheKey { Get-SettingsRows $schema $page $script:SetPending })
      # the tree for the page that was up is done with: its rows are released before the new
      # page's nodes are made, so a page switch cannot leave a second tree behind
      if ($null -ne $script:SetPageNode) { Unmount-UiComponent $script:SetPageNode }
      $script:SetPageNode = New-SettingRowTree $script:SetRows
      $script:SetPage = $page
      # A switch travels to where its row points on the timer. That is a reaction to the row's
      # values, so it is attached to the row as its `updated` hook: a flip moves its own switch
      # and no other row is walked. Only a page being built needs the first pass, because a
      # switch that never moved has to start at the value the file holds.
      Update-SettingsRowHooks
      foreach ($row in @($script:SetRows)) {
        if ($row.Kind -ne 'bool') { continue }
        $k = [string]$row.Key
        $v = 0.0
        if ([string]$row.Raw -eq '1') { $v = 1.0 }
        $script:SetToggleTarget[$k] = $v
        if (-not $script:SetToggleK.ContainsKey($k)) { $script:SetToggleK[$k] = $v }
      }
    }
    # which pages carry a staged value, kept here so a paint does not walk the group table
    $script:SetPendingGroups = @(Get-SettingGroupsWithPending $schema $script:SetPending)
    $vis = Get-SettingsVisibleRows $script:SetLayout
    $maxScroll = [Math]::Max(0, @($script:SetRows).Count - $vis)
    # the offset is a distance, so the clamp is one too, and it needs no visible-row count
    [void](Set-ScrollTo ([int]$script:SetScroll))
    # The buttons say what the rows just said. Writing the signals is what tells the render
    # effect; it is not called from here, so every caller of a refresh gets the same single
    # update and none of them has to remember it.
    # the page has to be a plain variable: a cast written straight into the call is glued to the
    # literal before it by the package minifier, and the package then does not parse
    $pageNow = [string]$page
    [void](Set-UiAppSignal $script:SetApp 'Page' $pageNow)
    [void](Set-UiAppSignal $script:SetApp 'Pending' @($script:SetPending).Count)
    Request-UiFlush
    # a different page or a different staged set changes which lines exist at all
    $script:SetCtlStamp = ''
    Update-SettingsControls
  }

  # The footer says two things - the words and whether they are a warning - so both are signals,
  # and the effect that draws the band reads both. Nothing here calls Invalidate: the write
  # queues the effect, and the effect repaints the bar instead of the window.
  function Sync-SetMessage {
    if (-not (Test-UiAppOpen $script:SetApp)) { return }
    $msgNow = [string]$script:SetMsg
    $msgErrNow = 0
    if ($script:SetMsgErr) { $msgErrNow = 1 }
    [void](Set-UiAppSignal $script:SetApp 'Msg' $msgNow)
    [void](Set-UiAppSignal $script:SetApp 'MsgErr' $msgErrNow)
    Request-UiFlush
  }

  # One flush per batch: the request that finds nothing scheduled posts one, and the posted one
  # clears the mark first so a write made while it runs queues another. Before the window has a
  # handle nothing can be posted - and nothing is on screen to be out of date - so it does
  # nothing and the caller's own flush takes over.
  function Request-UiFlush {
    if ($script:SetFlushQueued) { return }
    if (-not (Test-UiFlushPending)) { return }
    $script:SetFlushQueued = $true
    try {
      [void]$form.BeginInvoke([Action]{
          $script:SetFlushQueued = $false
          try { [void](Invoke-UiFlush) } catch { }
        })
    } catch {
      $script:SetFlushQueued = $false
    }
  }

  # The controls a row owns beyond its value - the delete cross of each chord line, and the plus
  # that adds one - are view nodes (renderer\src\components\views.ps1). Only the rows on screen hold them, and
  # their geometry comes from the layout and the scroll offset, which is why this runs again
  # whenever either can have moved.
  function Update-SettingsRowHooks {
    # a row that carries a switch tells the animation where to travel when its value moves: the
    # hook is the row's own reaction to new values, not a pass over every row on every refresh
    if ($null -eq $script:SetPageNode) { return }
    foreach ($node in $script:SetPageNode.Children.ToArray()) {
      if ($node.Hooks.ContainsKey('updated')) { continue }
      $props = $node.Props
      if ($null -eq $props -or [string]$props.Kind -ne 'bool') { continue }
      Add-UiHook $node 'updated' {
        param($c, $old)
        $k = [string]$c.Key
        $v = 0.0
        if ([string]$c.Props.Raw -eq '1') { $v = 1.0 }
        $script:SetToggleTarget[$k] = $v
        if (-not $script:SetToggleK.ContainsKey($k)) { $script:SetToggleK[$k] = $v }
      }
    }
  }

  function Update-SettingsControls {
    $layout = $script:SetLayout
    if ($null -eq $layout) { return }
    $rows = @($script:SetRows)
    $rowH = [int]$layout.RowHeight
    $off = [int]$script:SetScroll
    $first = 0
    if ($rowH -gt 0) { $first = [int][Math]::Floor($off / [double]$rowH) }
    $base = [int]$layout.ListTop - ($off - ($first * $rowH))
    $vis = Get-SettingsVisibleRows $layout
    $specs = New-Object System.Collections.Generic.List[object]
    $boxes = @{}
    for ($i = 0; $i -le $vis; $i++) {
      $idx = $first + $i
      if ($idx -ge $rows.Count) { break }
      $row = $rows[$idx]
      if (-not ($row.ContainsKey('Chain') -and [bool]$row.Chain)) { continue }
      $rowTop = $base + ($i * $rowH)
      # a row outside the band holds no controls: a node for a line nobody can see would be a
      # press target with nothing under it
      if (($rowTop + $rowH) -le [int]$layout.ListTop) { continue }
      if ($rowTop -ge [int]$layout.ListBottom) { continue }
      $chords = @()
      if ($null -ne $row.Chords) { $chords = @($row.Chords) }
      $maxLines = 3
      $drawn = [Math]::Min($chords.Count, $maxLines)
      $armed = ($script:SetRecKey -and ($script:SetRecKey -eq [string]$row.Key))
      if ($armed -and $drawn -ge $maxLines) { $drawn = $maxLines - 1 }
      $enabled = Test-RowEnabled $row
      $key = [string]$row.Key
      for ($n = 0; $n -lt $drawn; $n++) {
        $id = New-SettingControlKey $key ('del' + $n)
        $specs.Add(@{ Key = $id; Type = 'row-del'; Props = @{ Enabled = $enabled } })
        $boxes[$id] = (Get-SettingsChordDeleteRect $layout $rowTop $n)
      }
      if (-not $armed -and $chords.Count -lt $maxLines) {
        $id = New-SettingControlKey $key 'add'
        $specs.Add(@{ Key = $id; Type = 'row-add'; Props = @{ Enabled = $enabled } })
        $boxes[$id] = (Get-SettingsChordAddRect $layout $rowTop $drawn)
      }
    }
    [void](Sync-UiViews $script:SetControls $specs.ToArray())
    foreach ($node in $script:SetControls.Children.ToArray()) {
      $id = [string]$node.Key
      if (-not $boxes.ContainsKey($id)) { continue }
      [void](Update-UiComponent $node $boxes[$id])
    }
  }

  # The window's own controls as the patch sees them: two caption buttons that never change, and
  # the footer actions whose words and enabled state follow the staged set. The patch keeps the
  # ones that stayed, so a refresh does not throw away a button's hover.
  function Update-SetChrome {
    # the window owns what the buttons say; the chrome asks for it, and is told only the scope
    # those answers depend on
    $acts = @(Invoke-UiSlot (Get-UiSetupContextOf $script:SetChrome) 'actions' @{
          Page    = [string]$script:SetPage
          Pending = @($script:SetPending).Count
        })
    $specs = New-Object System.Collections.Generic.List[object]
    $specs.Add(@{ Key = 'close'; Type = 'icon'; Props = @{ Glyph = 'close'; Enabled = $true } })
    $specs.Add(@{ Key = 'min'; Type = 'icon'; Props = @{ Glyph = 'min'; Enabled = $true } })
    foreach ($a in $acts) {
      $key = [string]$a.Key
      $specs.Add(@{ Key = $key; Type = 'button'; Props = @{
            Label = [string]$a.Label; Primary = [bool]$a.Primary; Enabled = (Test-SettingsActionOn $key) } })
    }
    [void](Sync-UiViews $script:SetChrome $specs.ToArray())
    # the layout owns where each one is; the node only carries it for the draw and the hit test
    $layout = $script:SetLayout
    $close = Get-SettingsCloseRect $layout
    $min = Get-SettingsMinRect $layout
    $labels = @($script:SetActionSpecs | ForEach-Object { [string]$_.Label })
    $rects = @(Get-SettingsActionRects $layout $labels)
    foreach ($node in $script:SetChrome.Children.ToArray()) {
      $box = $null
      if ([string]$node.Key -ceq 'close') { $box = $close }
      elseif ([string]$node.Key -ceq 'min') { $box = $min }
      else {
        for ($i = 0; $i -lt $labels.Count; $i++) {
          if ([string]$script:SetActionSpecs[$i].Key -ceq [string]$node.Key) { $box = $rects[$i]; break }
        }
      }
      [void](Update-UiComponent $node $box)
      # What a control does travels with the control: the press path asks the node it hit, and a
      # button with no handler is a button that does nothing, without the window keeping a second
      # table of keys beside the ones it draws.
      $what = [string]$node.Key
      if ($what -ceq 'close') {
        Add-UiHandler $node 'click' { param($p) [void](Close-AppWindow 'settings') }
      } elseif ($what -ceq 'min') {
        Add-UiHandler $node 'click' { param($p) $form.WindowState = [Windows.Forms.FormWindowState]::Minimized }
      } else {
        Add-UiHandler $node 'click' { param($p) Invoke-SettingsAction ([string]$p) }
      }
    }
  }

  # a row whose owner setting is off: shown, greyed, and refusing edits with the reason
  function Test-RowEnabled($row) {
    if ($null -eq $row) { return $false }
    if (-not $row.ContainsKey('Enabled')) { return $true }
    return [bool]$row.Enabled
  }

  function Show-RowRefused($row) {
    $why = Get-UiTextOr 'settings.why.generic' 'this setting is not in effect'
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
    # the message is a signal (see the footer effect): writing it is what asks for the repaint
    Sync-SetMessage
  }

  function Show-Message([string]$text, [bool]$bad) {
    $script:SetMsg = $text
    $script:SetMsgErr = $bad
    Sync-SetMessage
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
    # what the change means is decided in renderer\src\utils\settings-vm.ps1; the window repaints and words
    # the message, and nothing else
    $staged = Get-SettingStagedValue $script:SetPending $schema $key ([string]$value)
    $script:SetPending = $staged.Pending
    # the footer names the row the way the window does: the key is an identity for the file, not
    # a word to read (a Chinese window would otherwise say PasteTyping in the middle of a sentence)
    $label = Get-SettingLabel $key
    if (-not $label) { $label = $key }
    Refresh-Settings
    if (-not $staged.Changed) {
      Show-Message (Get-UiText 'settings.msg.unchanged' @($label)) $false
      return $true
    }
    Show-Message (Get-UiText 'settings.msg.staged' @($label, $what)) $false
    return $true
  }

  # Save: the staged set written in one pass, then the palette and the rows follow it. The
  # resident is still reloaded once, when the window closes - not here.
  function Save-Settings {
    if ($script:SetPending.Count -eq 0) { return }
    $pending = $script:SetPending
    $plan = Get-SettingsSavePlan $pending
    $r = Save-SettingsValues $pending
    if (-not $r.Ok) { Show-Message (Get-UiText 'settings.msg.saveFailed' @([string]$r.Error)) $true; return }
    $script:SetPending = @{}
    # the folder the window itself writes to moves with the store location it just saved
    if ($plan.HasDataDir) { $script:StoreDir = [string]$plan.DataDir }
    if ($plan.Theme) {
      # a new theme has to reach the palette and the fonts before the next paint
      Apply-Theme
      $script:FBody = $null
      [void](Initialize-PanelFonts)
      $script:SetPal = Get-UiPalette
      # the tray may hold a menu and a mark drawn with the old palette: a window opened from the
      # tray runs in the resident, so those objects are right here to be re-skinned
      # the tray belongs to the resident: asking through the window layer keeps this file from
      # pulling the capture loop (and the panel it opens) into the settings bundle
      [void](Request-Window -Name 'tray' -Action 'look')
    }
    if ($plan.Language) {
      # a language may name its own font family, and the faces are built once per process: drop
      # the resolved family so the next initialize reads the one this language asks for. The
      # words themselves were reloaded by Apply-Config, which the save ran before this.
      $script:UiFamily = ''
      $script:FBody = $null
      [void](Initialize-PanelFonts)
      # the rows pick the new words up in the refresh below; the two texts fixed when the window
      # was built - the footer buttons and the title the shell shows - are read again here, so a
      # switch takes effect without closing and reopening the window
      Update-SettingsActions
      $form.Text = (Get-UiText 'settings.window.title')
      $form.AccessibleName = (Get-UiText 'settings.window.title')
    }
    Refresh-Settings
    $n = [int]$r.Count
    Show-Message (Get-UiTextCount 'settings.msg.saved' $n) $false
  }

  # Discard: the file is the truth, so dropping the staged table is the whole action, and every
  # switch travels back to the value it holds.
  function Discard-Settings {
    if ($script:SetPending.Count -eq 0) { return }
    $script:SetPending = @{}
    Refresh-Settings
    Show-Message (Get-UiText 'settings.msg.discarded') $false
  }

  # Restore defaults: staged like every other change, so the page shows what it would become
  # before anything is written.
  function Restore-SettingsDefaults {
    $next = Get-SettingDefaultStaging $schema $script:SetPending
    if ($next.Count -eq 0) { Show-Message (Get-UiText 'settings.msg.alreadyDefault') $false; return }
    foreach ($k in @($next.Keys)) { $script:SetPending[[string]$k] = [string]$next[$k] }
    Refresh-Settings
    $n = $next.Count
    Show-Message (Get-UiTextCount 'settings.msg.defaulted' $n) $false
  }

  # Which footer actions apply right now: the reset one always does, the other two only once
  # something is staged, because saving or discarding nothing would do nothing
  function Test-SettingsActionOn([string]$key) {
    $state = Get-SettingsActionState $script:SetPending
    if ($key -eq 'defaults') { return [bool]$state.Defaults }
    if ($key -eq 'save') { return [bool]$state.Save }
    return [bool]$state.Discard
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
      return (Get-SettingRecordValue $r $chord)
    }
    return $chord
  }

  # One chord off a chain. The last one stays: a chain with nothing in it falls back to the
  # default list, so removing it has to be refused the way an empty Plugins= is.
  function Remove-SettingChord($row, [int]$index) {
    $drop = Get-SettingChordDrop $row $index
    if (-not $drop.Ok) {
      Show-Message (Get-UiText 'settings.msg.keepOneChord') $true
      return
    }
    $removedNote = Get-UiText 'settings.msg.removed' @([string]$drop.Removed)
    [void](Stage-Setting ([string]$row.Key) $drop.Value $removedNote)
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
      # message happened to be in the footer a moment ago. The row is named the way the window
      # names it; the reason comes from the schema and stays as it is.
      $script:SetEditBad = $true
      $editLabel = Get-SettingLabel $key
      if (-not $editLabel) { $editLabel = $key }
      Show-Message (Get-UiText 'settings.msg.rejected' @($editLabel, [string]$r.Error)) $true
      return
    }
    $what = Get-UiText 'settings.msg.setTo' @([string]$r.Value)
    if ($script:SetEditField.Number) {
      $said = ([string]$box.Text).Trim()
      if ($script:SetEditField.Unit) { $said = $said + ' ' + [string]$script:SetEditField.Unit }
      $what = Get-UiText 'settings.msg.setTo' @($said)
    }
    # Entering a field and leaving it again is not an edit: the committed value is compared with
    # the one the row shows, and an equal one closes the field without saying anything
    $held = [string](Get-SettingRaw $schema $key)
    if ($script:SetPending.ContainsKey($key)) { $held = [string]$script:SetPending[$key] }
    if ([string]$r.Value -ceq $held) { End-Edit $false; return }
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
    $tick = Get-SettingListTick @{ Raw = (Get-DropRaw) } $name
    if (-not $tick.Ok) {
      $listLabel = Get-SettingLabel $key
      if (-not $listLabel) { $listLabel = $key }
      Show-Message (Get-UiText 'settings.msg.listNeedsOne' @($listLabel)) $true
      return
    }
    $next = [string]$tick.Value
    # the note names the item the way the list drew it, not the code the file stores
    $shown = $name
    try {
      $tag = $script:SetDrop.Tag
      $list = @($tag.Choices)
      $words = @($tag.Labels)
      for ($i = 0; $i -lt $list.Count; $i++) {
        if ([string]$list[$i] -ieq $name -and $i -lt $words.Count -and [string]$words[$i]) { $shown = [string]$words[$i] }
      }
    } catch { }
    $tickNote = Get-UiText 'settings.msg.unticked' @($shown)
    if ($tick.Ticked) { $tickNote = Get-UiText 'settings.msg.ticked' @($shown) }
    [void](Stage-Setting $key $next $tickNote)
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
    $dd.Text = (Get-UiText 'settings.choices.title')
    $dd.ClientSize = New-Object Drawing.Size -ArgumentList @([int]$rect.Width, [int]$rect.Height)
    $dd.Left = $form.Left + [int]$rect.Left
    $dd.Top = $form.Top + [int]$rect.Top
    $dd.Tag = @{ Choices = $choices; Labels = @($row.ChoiceLabels); Key = [string]$row.Key }
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
        $words = @($s.Tag.Labels)
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
          # what the row says is drawn, what the file holds is written: a language is picked by
          # the name it calls itself, and the code behind it never has to be read
          $shownText = $text
          if ($words.Count -eq $list.Count) { $shownText = [string]$words[$i] }
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
          $g.DrawString($shownText, $script:FBody, (Get-Brush $ink), $tb, $sf.Ellipsis)
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
      $pickNote = Get-UiText 'settings.msg.setTo' @([string]$list[$i])
      [void](Stage-Setting ([string]$s.Tag.Key) ([string]$list[$i]) $pickNote)
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
    $v = Get-SettingFlipValue $row
    $flipNote = Get-UiText 'settings.msg.turnedOff'
    if ($v -eq '1') { $flipNote = Get-UiText 'settings.msg.turnedOn' }
    [void](Stage-Setting ([string]$row.Key) $v $flipNote)
  }

  # A shortcut is recorded, not typed: a spelled-out chord is the one value that is easier to get
  # wrong on paper than by pressing it. The row waits for one chord; the caps show what is held
  # while the keys are down.
  function Start-Record($row) {
    if ($null -eq $row) { return }
    if (-not (Test-RowEnabled $row)) { Show-RowRefused $row; return }
    # three chord lines are all the card holds, and the schema refuses a longer chain: a fourth
    # recorded here would be written and then have nowhere to appear or be removed from
    if ($row.ContainsKey('Chain') -and [bool]$row.Chain -and @($row.Chords).Count -ge 3) {
      Show-Message (Get-UiText 'settings.msg.chainFull') $true
      return
    }
    End-Edit $true
    $script:SetRecKey = [string]$row.Key
    $script:SetRecPreview = @()
    [void](Start-HotkeyRecord ([string]$script:StoreDir))
    try { $form.Focus() } catch { }
    $recLabel = [string]$row.Label
    Show-Message (Get-UiText 'settings.msg.recording' @($recLabel)) $false
    $form.Invalidate()
  }

  function Cancel-Record {
    if (-not $script:SetRecKey) { return }
    $script:SetRecKey = ''
    $script:SetRecPreview = @()
    Stop-HotkeyRecord ([string]$script:StoreDir)
    Show-Message (Get-UiText 'settings.msg.recordingCancelled') $false
    $form.Invalidate()
  }

  # the chord the resident handed over, applied as if it had been pressed here
  function Apply-RecordedChord([string]$chord) {
    if (-not $script:SetRecKey -or -not $chord) { return }
    if (-not (Test-ChordUsable $chord)) {
      Show-Message (Get-UiText 'settings.msg.chordAlone' @($chord)) $true
      return
    }
    $key = [string]$script:SetRecKey
    $script:SetRecKey = ''
    $script:SetRecPreview = @()
    $chordNote = Get-UiText 'settings.msg.setTo' @($chord)
    [void](Stage-Setting $key (Get-RecordedValue $key $chord) $chordNote)
    $form.Invalidate()
  }

  # A folder is chosen, not typed: the store location is a path, and a path typed by hand is a
  # path that does not exist. The picker is the system one, so it knows the drives and the
  # shares the user has.
  function Pick-Folder($row) {
    if ($null -eq $row) { return }
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    try {
      $dlg.Description = (Get-UiText 'settings.pick.folder')
      $dlg.ShowNewFolderButton = $true
      $cur = [string]$row.Raw
      if ($cur -and (Test-Path -LiteralPath $cur)) { $dlg.SelectedPath = $cur }
      if ($dlg.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
      $picked = [string]$dlg.SelectedPath
      if (-not $picked) { return }
      # the folder is staged like any other value: the row shows it, and Save moves the store
      $pickedNote = Get-UiText 'settings.msg.setTo' @($picked)
      if (-not (Stage-Setting ([string]$row.Key) $picked $pickedNote)) { return }
      $form.Invalidate()
    } catch {
      Show-Message (Get-UiText 'settings.msg.pickFailed' @([string]$_.Exception.Message)) $true
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
      Show-Message (Get-UiText 'settings.msg.hotkeyUnusable') $true
      return
    }
    $chord = Format-ChordValue (Test-ChordWinHeld) $e.Control $e.Alt $e.Shift $name
    if (-not (Test-ChordUsable $chord)) {
      # a bare letter would take that key away from every program
      Show-Message (Get-UiText 'settings.msg.hotkeyNeedsModifier') $true
      return
    }
    $key = [string]$script:SetRecKey
    $script:SetRecKey = ''
    $script:SetRecPreview = @()
    Stop-HotkeyRecord ([string]$script:StoreDir)
    $recNote = Get-UiText 'settings.msg.setTo' @($chord)
    [void](Stage-Setting $key (Get-RecordedValue $key $chord) $recNote)
    $e.Handled = $true
    $e.SuppressKeyPress = $true
    $form.Invalidate()
  }

  $form = New-AppWindow -Name 'settings' -Frame 'Cb.FluentForm' -Borderless
  # the resident and the panel reach this window through the script scope: a hotkey pressed while
  # it is open asks it to step aside (see Hide-SettingsForPanel below)
  $script:SetWindow = $form
  $form.Activates = $true
  $form.FormBorderStyle = 'None'
  $form.StartPosition = 'Manual'
  $form.ShowInTaskbar = $true
  $form.KeyPreview = $true
  $form.Text = (Get-UiText 'settings.window.title')
  $form.AccessibleName = (Get-UiText 'settings.window.title')
  # The one mark the tool draws (main\utils\native.ps1): the same icon the tray shows, so the taskbar
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
  # The window's state as signals (renderer\src\core\reactive.ps1), and two effects that read them. A write
  # queues them instead of rebuilding on the spot, and one flush runs each once - so a handler
  # that stages five values rebuilds the footer once, and a message repaints the bar, not the page.
  $script:SetApp = New-UiApp @{ Page = ''; Pending = 0; Msg = ''; MsgErr = 0 }
  $script:SetFlushQueued = $false
  [void](Add-UiAppEffect $script:SetApp {
      [void](Get-UiAppSignal $script:SetApp 'Page' '')
      [void](Get-UiAppSignal $script:SetApp 'Pending' 0)
      Update-SetChrome
      $form.Invalidate()
    })
  [void](Add-UiAppEffect $script:SetApp {
      [void](Get-UiAppSignal $script:SetApp 'Msg' '')
      [void](Get-UiAppSignal $script:SetApp 'MsgErr' 0)
      if ($form.IsDisposed) { return }
      $l = $script:SetLayout
      if ($null -eq $l) { $form.Invalidate(); return }
      $band = New-Object Drawing.Rectangle -ArgumentList @(
        0, [int]$l.ListBottom, [int]$l.Width, [int]([int]$l.FootHeight + 1))
      $form.Invalidate($band)
    })
  Refresh-Settings
  # nothing is on screen yet, so the first pass is run here rather than posted
  [void](Invoke-UiFlush)
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
      # A frame of an easing switch dirties only the switch, so whatever the clip leaves out is
      # not drawn at all: the header, the page list, six other rows and the footer cost more
      # than the row that is moving. A strip inside the list still gets the page behind it.
      $dirty = $e.Graphics.VisibleClipBounds
      $listOnly = ($dirty.Top -ge [int]$layout.ListTop) -and ($dirty.Bottom -le [int]$layout.ListBottom) -and
        ($dirty.Left -ge [int]$layout.ListLeft) -and ($dirty.Right -le [int]$layout.ListRight)
      if ($listOnly) {
        # The strip has to be written, not blended: the clip bounds are fractional, and a surface
        # fill that is antialiased along its edge leaves the old row showing through at half
        # strength - a light line across the page at the edge of whatever was repainted.
        #
        # It also has to land on whole pixels. Written half over with SourceCopy, the edge row
        # becomes a half transparent pixel, and the compositor blends what is left with the black
        # behind the window: a dark line across the top of the list, which is what the first
        # hovered row left behind until the smoothing came off for this one fill (measured, a
        # row of #101010 against a #202020 surface).
        $strip = New-Object Drawing.SolidBrush $pal['Surface']
        $was = $g.CompositingMode
        $sm = $g.SmoothingMode
        try {
          $g.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
          $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::None
          $band = [Drawing.Rectangle]::Round($dirty)
          $band.Inflate(2, 2)
          # the blur of the strip must stay inside the list: two pixels up would reach the
          # header, two down the footer's hairline, and neither is drawn while only a strip is
          $listRect = New-Object Drawing.Rectangle -ArgumentList @(
            ([int]$layout.ListLeft - 2), [int]$layout.ListTop,
            (([int]$layout.ListRight - [int]$layout.ListLeft) + 4),
            ([int]$layout.ListBottom - [int]$layout.ListTop))
          $band = [Drawing.Rectangle]::Intersect($band, $listRect)
          $g.FillRectangle($strip, $band)
        } finally {
          $g.SmoothingMode = $sm
          $g.CompositingMode = $was
          $strip.Dispose()
        }
      } else {
        $headGroup = [string]$groups[$script:SetGroup]
        $headKey = 'settings.group.' + $headGroup
        Draw-SettingsChrome $g $pal $layout (Get-UiText 'settings.window.title') (Get-UiTextOr $headKey $headGroup)
        Draw-SettingsSide $g $pal $layout $groups $script:SetGroup $script:SetPendingGroups
      }
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
          # a row the clip does not reach is not drawn: the strip of one switch is 40 x 20
          if (($rowTop + $rowH) -lt $dirty.Top -or $rowTop -gt $dirty.Bottom) { continue }
          $row = $rows[$idx]
          $k = 1.0
          if ($row.Kind -eq 'bool') {
            $name = [string]$row.Key
            if ($script:SetToggleK.ContainsKey($name)) { $k = [double]$script:SetToggleK[$name] }
            elseif ([string]$row.Raw -eq '1') { $k = 1.0 } else { $k = 0.0 }
          }
          $armed = ($script:SetRecKey -and ($script:SetRecKey -eq [string]$row.Key))
          $editingRow = ($script:SetEditKey -and ($script:SetEditKey -eq [string]$row.Key))
          Draw-SettingsRow $g $pal $layout $row $x $rowTop $width $k $armed @($script:SetRecPreview) $editingRow
        }
        # The delete cross of a chord line and the plus that adds one are view nodes, drawn from
        # the same list the hover and the press walk: what lights up under the pointer is what a
        # press acts on, and neither is drawn twice.
        foreach ($ctl in $script:SetControls.Children.ToArray()) {
          if (-not $dirty.IntersectsWith((Get-UiViewRect $ctl))) { continue }
          [void](Draw-UiView $g $pal $ctl)
        }
      } finally { $g.Restore($clipState) }
      $lane = Get-SettingsScrollLane $layout
      $laneRect = New-Object Drawing.Rectangle -ArgumentList @(
        ([int]$lane.Left - 4), [int]$lane.Top, ([int]$lane.Width + 8), [int]$lane.Height)
      if ($dirty.IntersectsWith($laneRect)) {
        $thumb = Get-SettingsScrollThumb $layout @($rows).Count $vis $script:SetScroll
        Draw-SettingsScrollbar $g $pal $layout $thumb $script:SetSbK
      }
      if ($script:SetEditKey -and $null -ne $script:SetEditRect) {
        # the same field the row draws, focused: the value is in the text box, the unit stays drawn
        $mode = 'edit'
        if ($script:SetEditBad) { $mode = 'bad' }
        Draw-SettingsValueField $g $pal $script:SetEditRect '' ([string]$script:SetEditField.Unit) $true $mode
      }
      if ($listOnly) { return }
      # the caption buttons and the footer actions are view nodes (renderer\src\components\views.ps1): one walk
      # draws them all, in the order the patch kept them
      [void](Render-UiTree $script:SetChrome { param($c) if ($c.Type -ne 'chrome') { [void](Draw-UiView $g $pal $c) } })
      # the footer is the window's own bar: the last change on the left, the actions on the right.
      # The bar itself - its hairline and its message - is not a control, so it stays here.
      Draw-SettingsFooter $g $pal $layout $script:SetMsg $script:SetMsgErr $script:SetActionSpecs
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
      [void](Close-AppWindow 'settings')
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
    if (Set-ScrollTo ([int]$script:SetScroll + ($dir * $step))) { Update-SettingsControls; $form.Invalidate() }
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
    if (Set-ScrollTo $v) { Update-SettingsControls; $form.Invalidate() }
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
    # The caption buttons and the footer actions are view nodes (renderer\src\components\views.ps1), so one diff
    # moves the hover and answers the rectangle that changed: crossing Save repaints Save instead
    # of the whole window, and a disabled action never takes the hover at all.
    $dirty = Update-UiViewHot $script:SetChrome.Children.ToArray() $e.X $e.Y $true
    if (-not $dirty.IsEmpty) { $form.Invalidate($dirty) }
    # a press on the header moves the window: there is no title bar to drag
    if ($null -ne $script:SetDragFrom) {
      $now = [Windows.Forms.Cursor]::Position
      $form.Location = (New-Object Drawing.Point (
          ([int]$script:SetDragFrom.Left + ($now.X - [int]$script:SetDragFrom.X)),
          ([int]$script:SetDragFrom.Top + ($now.Y - [int]$script:SetDragFrom.Y))))
      return
    }
    $idx = Get-SettingsRowAt $script:SetLayout @($script:SetRows).Count $script:SetScroll $e.X $e.Y
    if ($idx -ne $script:SetHover) {
      # A row does not light up under the pointer: only the control in it is a target, and a
      # control that needs a hover (the delete cross of a chord) paints its own. So a change of
      # row repaints nothing by itself.
      $script:SetHover = $idx
    }
    # The controls the rows own are nodes too, so the hover is one diff that answers the two
    # 16 x 16 boxes that changed - the row band is not repainted for a cross.
    $stamp = ([string]$idx + '|' + [string]$script:SetScroll + '|' + [string]$script:SetRecKey + '|' + [string]$script:SetRows.Count)
    if ($stamp -ne [string]$script:SetCtlStamp) {
      $script:SetCtlStamp = $stamp
      Update-SettingsControls
    }
    $dirty = Update-UiViewHot $script:SetControls.Children.ToArray() $e.X $e.Y $true
    if (-not $dirty.IsEmpty) { $form.Invalidate($dirty) }
  })

  $form.Add_MouseUp({
    param($s, $e)
    if ($null -ne $script:SetDragFrom) {
      $script:SetDragFrom = $null
      $form.Capture = $false
      return
    }
    if ($script:SetSbDrag -lt 0) { return }
    $script:SetSbDrag = -1
    $form.Capture = $false
    $form.Invalidate()
  })

  # A window in the taskbar is not listening. A chord being recorded ends when the window is put
  # away, or the resident would keep handing the next hotkey to a window the user cannot see, and
  # the history could not be opened until that recording timed out.
  $form.Add_Resize({
    param($s, $e)
    if ($null -ne $script:SetDragFrom) { $script:SetDragFrom = $null; $form.Capture = $false }
    if ($form.WindowState -ne [Windows.Forms.FormWindowState]::Minimized) { return }
    if ($script:SetRecKey) { Cancel-Record }
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
    # the window's own controls first: the caption buttons sit in the header, above everything,
    # and the footer actions below the list, where no row and no lane can be under them
    $hit = Hit-UiViewList $script:SetChrome.Children.ToArray() $e.X $e.Y $true
    if ($null -ne $hit) {
      # the control answers for itself; an action passes its own key, the caption buttons need none
      [void](Invoke-UiEmit $hit 'click' ([string]$hit.Key))
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
        if (Set-ScrollTo $to) { Update-SettingsControls; $form.Invalidate() }
      }
      return
    }
    # the header is the title bar this window does not draw: a press on it moves the window, and
    # the move is followed from the pointer's own position so a fast drag cannot outrun it
    if ($e.Y -lt [int]$script:SetLayout.HeadHeight) {
      $now = [Windows.Forms.Cursor]::Position
      $script:SetDragFrom = @{ X = $now.X; Y = $now.Y; Left = $form.Left; Top = $form.Top }
      $form.Capture = $true
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
    # a page that states facts rather than settings has nothing to click, except a link: that one
    # row leaves the window, so it opens in the browser and the window stays where it is
    if ($row.Kind -eq 'info') { return }
    $rowTop = Get-SettingsRowTop $idx
    # Only the control answers a press: the switch itself, the field a value is typed in, the
    # column a dropdown or a chord sits in. The row used to be the target, which made a click on
    # the label or beside a switch act on the row.
    $ctrl = Get-SettingsControlRect $script:SetLayout $row $rowTop
    if ($ctrl.IsEmpty) { return }
    if ($e.X -lt [int]$ctrl.Left -or $e.X -ge ([int]$ctrl.Left + [int]$ctrl.Width)) { return }
    if ($e.Y -lt [int]$ctrl.Top -or $e.Y -ge ([int]$ctrl.Top + [int]$ctrl.Height)) { return }
    if ($row.Kind -eq 'link') {
      $url = ''
      if ($row.ContainsKey('Url')) { $url = [string]$row.Url }
      if (-not $url) { return }
      try {
        Start-Process -FilePath $url
        Show-Message (Get-UiText 'settings.msg.linkOpened' @($url)) $false
        Write-Log ('settings: opened ' + $url)
      } catch { Show-Message (Get-UiText 'settings.msg.linkFailed' @($url)) $true }
      $form.Invalidate()
      return
    }
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
    # A chain is a list with its own controls: the delete cross removes one line, and the plus on
    # the next free line is the only way into a recording. A press on the caps or on the blank
    # space of the column does nothing, so the row cannot start recording by accident. Both
    # controls are nodes, and the one the press lands on is the one that was drawn lit.
    if ($row.ContainsKey('Chain') -and [bool]$row.Chain) {
      $ctl = Hit-UiViewList $script:SetControls.Children.ToArray() $e.X $e.Y $true
      if ($null -ne $ctl) {
        $parts = Get-SettingControlKeyParts ([string]$ctl.Key)
        if ($parts.What -eq 'add') {
          if (-not $wasRec) { Start-Record $row }
          return
        }
        if ($parts.Index -ge 0) { Remove-SettingChord $row ([int]$parts.Index) }
      }
      return
    }
    # every row is its own control: a click on a switch row flips it wherever it lands, a click
    # on a shortcut waits for a chord, a click on a value opens its list, and anything else is
    # typed - there is no select-then-act step
    if ($row.ContainsKey('Record') -and $row.Record) {
      if ($wasRec -ne [string]$row.Key) { Start-Record $row } else { Show-Message (Get-UiText 'settings.msg.recordingCancelled') $false }
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
      # a request names the page it wants (the tray's About entry); the ring has no payload, so the
      # name was left in this scope by Show-Settings and is spent here, on the window's own loop
      $want = [string]$script:SetWantGroup
      $script:SetWantGroup = ''
      if ($want) {
        $n = @($groups).Count
        for ($g = 0; $g -lt $n; $g++) {
          if (-not ([string]$groups[$g] -eq $want)) { continue }
          if ($g -ne [int]$script:SetGroup) { Set-CurrentGroup $g }
          break
        }
      }
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
    if ($moved) {
      # repaint the switch that moved, not the page it sits on
      $rect = Get-AnimationRect
      if ($rect.IsEmpty) { $form.Invalidate() } else { $form.Invalidate($rect) }
    }
  })
  $animTimer.Start()

  Register-AppWindowEvent -Name 'settings' -Event Deactivate -Handler {
    # leaving the window is the other way out of the field: a value is committed, never quietly
    # dropped, and a refusal keeps it open until the user is back
    if ($null -ne $script:SetEditBox) { Complete-Edit }
  }

  # Leaving with staged work would drop it without a word, and once the window is gone there is
  # nowhere to say so: the one question is asked here, and No keeps the window open with the
  # staged values still in place.
  Register-AppWindowEvent -Name 'settings' -Event Closing -Handler {
    param($e)
    if ($script:SetPending.Count -eq 0) { return }
    try {
      $askText = Get-UiText 'settings.msg.closeUnsaved'
      $askTitle = Get-UiText 'settings.window.title'
      $ans = [Windows.Forms.MessageBox]::Show($form, $askText, $askTitle,
        [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning,
        [Windows.Forms.MessageBoxDefaultButton]::Button2)
      if ($ans -ne [Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true }
    } catch { }
  }

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
    # An effect holds a ScriptBlock, and that ScriptBlock holds this window: the app gives back
    # every effect and derived value it started, in one call, or the next open would find a
    # disposed form still alive behind a registered effect.
    Close-UiApp $script:SetApp
    $script:SetApp = $null
    # the row tree is the only thing this window mounts; taking it down releases whatever the rows
    # hold, so a window opened a hundred times leaves nothing behind
    if ($null -ne $script:SetPageNode) { Unmount-UiComponent $script:SetPageNode }
    $script:SetPageNode = $null
    $script:SetRows = @()
    try { $form.Dispose() } catch { }
    $script:SetWindow = $null
    & $releaseSettings
    # one reload for the whole session, and only when a written key needed the resident to
    # read the file again (an install-only key does not)
    if ($script:SettingsDirty) {
      try { Restart-ResidentIfRunning } catch { }
      $script:SettingsDirty = $false
    }
  }
}

# The panel and this window share one UI thread, and the window runs a modal loop. A hotkey pressed
# while the window is open used to bring the window forward instead of showing the history; a
# window that is not recording a chord now steps aside - minimised into the taskbar - so the panel
# can open over it. The state it was in is kept, because it may have been maximised or already
# lowered, and the restore puts that back.
function Hide-SettingsForPanel {
  $w = $script:SetWindow
  if ($null -eq $w -or $w.IsDisposed) { return $false }
  try {
    $script:SetWindowState = $w.WindowState
    $w.WindowState = [Windows.Forms.FormWindowState]::Minimized
    return $true
  } catch { return $false }
}

function Show-SettingsAfterPanel {
  $w = $script:SetWindow
  if ($null -eq $w -or $w.IsDisposed) { $script:SetWindowState = $null; return }
  try {
    $state = [Windows.Forms.FormWindowState]::Normal
    if ($null -ne $script:SetWindowState) { $state = $script:SetWindowState }
    $w.WindowState = $state
    if ($state -ne [Windows.Forms.FormWindowState]::Minimized) { $w.Activate() }
  } catch { }
  $script:SetWindowState = $null
}

# What the rest of the program may ask this window to do. It is registered here, at the end of the
# file, because every handler names a function this file defines: the window owns its behaviour,
# and a caller reaches it by action name instead of by function name - which is what keeps the
# three windows from being one closure.
Register-Window -Name 'settings' -Handlers @{
  open    = { param($args) Show-Settings -Group ([string]$args['Group']) }
  hide    = { param($args) [bool](Hide-SettingsForPanel) }
  restore = { param($args) Show-SettingsAfterPanel }
  ring    = { param($args) [void](Ring-SettingsAsk ([string]$args['Name'])) }
  test    = { param($args) [bool](Test-SettingsWindowOpen ([string]$args['Name'])) }
}

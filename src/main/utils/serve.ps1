# main/utils/serve.ps1 - the resident process: capture loop, hotkey, tray icon, and the supervisor
# that restarts the loop after a crash.

# The suppression state (LastSeq) lives here because the capture loop compares against it.
# Writing to it is main/utils/clip.ps1's job - see Set-LastCapture there.

# The tray shows the one mark main\utils\native.ps1 draws, at the size the notification area asks for
# (16 * dpi): a bitmap scaled up from 16 is what made it look soft at 125% and 150%.
$script:TrayIcon = $null
$script:TrayHicon = [IntPtr]::Zero
function New-TrayIcon {
  $size = 16
  try {
    $dpi = [Cb.Win]::GetDpiForSystem()
    if ($dpi -gt 0) { $size = [int][Math]::Round(16 * $dpi / 96) }
  } catch { $size = 16 }
  if ($size -lt 16) { $size = 16 }
  if ($size -gt 48) { $size = 48 }
  $h = [IntPtr]::Zero
  try { $h = [Cb.Tray]::Build($size, (Get-AppIconArgb)) } catch { return $null }
  if ($h -eq [IntPtr]::Zero) { return $null }
  if ($script:TrayHicon -ne [IntPtr]::Zero) { try { [Cb.Tray]::Free($script:TrayHicon) } catch { } }
  $script:TrayHicon = $h
  $script:TrayIcon = [Drawing.Icon]::FromHandle($h)
  return $script:TrayIcon
}

# A theme saved while the resident runs reaches the menu and the mark it already holds: the rows
# carry the skin they were built with, and the icon is drawn from the palette's accent, so both
# are rebuilt here. The menu object stays the one the tray owns - its rows keep their handlers.
function Update-TrayLook {
  if ($null -eq $script:TraySkin) { return }
  $script:TraySkin = New-TrayMenuSkin
  if ($null -ne $script:TrayMenuRef) {
    try { $script:TrayMenuRef.ApplySkin($script:TraySkin) } catch { Write-Log ('tray skin: ' + $_.Exception.Message) }
  }
  try {
    $icon = New-TrayIcon
    if ($null -ne $icon -and $null -ne $script:Tray) { $script:Tray.Icon = $icon }
  } catch { Write-Log ('tray icon: ' + $_.Exception.Message) }
}

# the settings window asks for this re-skin through the window layer (Request-Window 'tray'), so
# saving a theme does not load the capture loop into that window's bundle
Register-Window -Name 'tray' -Handlers @{ look = { Update-TrayLook } }

# The text of the clear confirmation, and the two numbers behind it. It counts rows, not mark
# names: the kept names are s and p whether or not a single entry carries them, so counting
# names said "2 pinned entries stay" on a history that had no pinned entry at all.
#   @{ Text; Gone; Stay }
function Get-ClearPrompt($records) {
  $recs = @($records)
  $keeps = @(Get-ClearKeepMarks)
  $stay = 0
  $words = [ordered]@{}
  foreach ($r in $recs) {
    $marks = [string]$r.Marks
    if (-not $marks) { continue }
    $hit = ''
    foreach ($k in $keeps) { if ($marks.Contains([string]$k)) { $hit = [string]$k; break } }
    if (-not $hit) { continue }
    $stay++
    $w = Get-MarkUiWord $hit
    if ($words.Contains($w)) { $words[$w]++ } else { $words[$w] = 1 }
  }
  $gone = $recs.Count - $stay
  $goneWord = Get-UiTextCount 'menu.entries' $gone
  $text = Get-UiText 'tray.clearAsk' @($goneWord)
  if ($stay -gt 0) {
    $parts = @($words.Keys | Sort-Object | ForEach-Object { [string]$words[$_] + ' ' + [string]$_ })
    $stayWord = Get-UiTextCount 'menu.entries' $stay
    $text += "`n`n" + (Get-UiText 'tray.clearStay' @($stayWord, ($parts -join ', ')))
  }
  return @{ Text = $text; Gone = $gone; Stay = $stay }
}

function Start-Serve {
  $created = $false
  $mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$created)
  if (-not $created) {
    try {
      $e = [System.Threading.EventWaitHandle]::OpenExisting($EventName)
      [void]$e.Set()
      Write-Host 'clipboard already running -> asked the running instance to show the picker'
    } catch { Write-Host 'clipboard already running (could not signal it, try: clipboard ui)' }
    return
  }

  $script:StopEvt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $StopName)
  $script:ExitKind = ''
  # the settings window is opened from the tray in this process, and a save has to rebuild the
  # loop instead of restarting the process it lives in (main\utils\config.ps1, Restart-ResidentIfRunning)
  $script:InResident = $true
  try {
    Load-Forms
    Add-Native
    try { [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { }
    # The message loop keeps running after it, so the log line has to carry where it happened:
    # the script position and the call frame are what turn "cannot index into a null array"
    # into a fix.
    [Windows.Forms.Application]::add_ThreadException({
        param($s, $e)
        $ex = $e.Exception
        $where = ''
        try {
          $rec = $ex.ErrorRecord
          if ($null -ne $rec) {
            $pos = [string]$rec.InvocationInfo.PositionMessage
            $pos = ($pos -replace '\s+', ' ').Trim()
            if ($pos.Length -gt 300) { $pos = $pos.Substring(0, 300) }
            $where = ' at ' + $pos
          }
        } catch { }
        if (-not $where) {
          try {
            $all = ([string]$ex.ToString() -replace '\s+', ' ').Trim()
            if ($all.Length -gt 300) { $all = $all.Substring(0, 300) }
            $where = ' at ' + $all
          } catch { }
        }
        Write-Log ('ui error (ignored): ' + $ex.Message + $where)
      })

    # supervisor: keep the daemon alive across crashes, back off when it keeps dying
    $round = 0
    $delay = 1000
    while ($true) {
      if ($script:StopEvt.WaitOne(0)) { break }
      $script:ExitKind = ''
      $started = Get-Date
      try { Invoke-ServeOnce } catch { Write-Log ('serve crash: ' + $_.Exception.Message) }
      # the tray's Restart entry, or a save in a settings window opened from the tray: rebuild the
      # scene without leaving the supervisor loop, so the mutex, the stop event and the process
      # itself stay exactly as they are
      if ($script:ExitKind -eq 'restart') {
        Write-Log 'serve restart (requested inside the process)'
        $round = 0
        $delay = 1000
        if ($script:StopEvt.WaitOne(200)) { break }
        continue
      }
      if ($script:ExitKind) { Write-Log ('serve stop (' + $script:ExitKind + ')'); break }
      if (((Get-Date) - $started).TotalSeconds -gt 60) { $round = 0; $delay = 1000 }
      $round++
      Write-Log ('serve restart #' + $round + ' in ' + $delay + 'ms')
      if ($script:StopEvt.WaitOne($delay)) { break }
      $delay = [Math]::Min($delay * 2, 30000)
    }
  } finally {
    try { if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() } } catch { }
    $script:Tray = $null
    try { [IO.File]::WriteAllText((Join-Path $StoreDir 'hotkey.txt'), '(stopped)', $Utf8) } catch { }
    Write-Log 'supervisor exit'
    try { $script:StopEvt.Dispose() } catch { }
    try { $mutex.ReleaseMutex() } catch { }
    try { $mutex.Dispose() } catch { }
  }
}

function Invoke-ServeOnce {
  $script:PickerOpen = $false
  # The show event is pinned on the script scope for the same reason as the stop event: the
  # tick below runs as an event handler, where an unqualified name is resolved through whatever
  # scope happens to be on the stack - the panel's own frame is on that stack while it pumps
  # messages, and a number it holds under the same name used to be found instead (reported as
  # "[System.Double] does not contain a method named 'WaitOne'").
  $script:ShowEvt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $EventName)
  # Clients that hand their command to this process instead of starting their own: the
  # listener exists for the whole scene, and every request runs on this thread, so it walks
  # the same state the capture loop and the panel use.
  $script:ProxyListener = $null
  try { $script:ProxyListener = New-ProxyListener }
  catch { Write-Log ('proxy listener: ' + $_.Exception.Message) }

  $stored = @(Get-Records)
  if ($MaxItems -ge 1 -and $stored.Count -gt $MaxItems) {
    Use-StoreLock {
      $list = New-Object System.Collections.Generic.List[object]
      foreach ($r in @(Get-Records)) { $list.Add($r) }
      Trim-Records $list
      Save-Records $list.ToArray()
    }
    Write-Log ('trimmed store to ' + $MaxItems + ' (was ' + $stored.Count + ')')
  }

  $hw = New-Object Cb.HotWindow
  # the chain itself is the schema default of HotkeyFallbacks, so the file and `config` are
  # where it is read from; an empty value was already replaced by that default
  $fb = @($script:HotkeyFallbacks -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $cands = @(@($Hotkey) + $fb | Select-Object -Unique)
  $script:Hot = ''
  $reg = $false
  foreach ($c in $cands) {
    $p = Parse-Hotkey $c
    if ($p.Vk -eq 0) { continue }
    if ([Cb.Win]::RegisterHotKey($hw.Handle, 1, ($p.Mods -bor 0x4000), $p.Vk)) {
      $script:Hot = $c; $reg = $true; break
    }
    Write-Log ('hotkey registration failed: ' + $c)
  }
  $script:UsePoll = -not $reg
  $script:PrevHotKey = $false
  if (-not $reg) { Write-Log 'all hotkeys rejected, falling back to GetAsyncKeyState polling' }

  # record the hotkey that actually took effect, then surface it in the tray
  $eff = if ($reg) { $script:Hot } else { 'poll:' + $Hotkey }
  try { Ensure-Dir; [IO.File]::WriteAllText((Join-Path $StoreDir 'hotkey.txt'), $eff, $Utf8) } catch { }
  try {
    $script:Tray = New-Object Windows.Forms.NotifyIcon
    $trayIcon = New-TrayIcon
    if ($null -ne $trayIcon) { $script:Tray.Icon = $trayIcon } else { $script:Tray.Icon = [Drawing.SystemIcons]::Information }
    $script:Tray.Text = (Get-UiText 'app.tooltip' @($eff))
    # One left click opens the panel. Windows reports a click on a tray icon as a mouse click, and
    # the right button opens the menu, so the button is what tells the two apart. A habit of
    # double-clicking is harmless: the second click lands on the panel the first one opened.
    $script:Tray.Add_MouseClick({
        param($sender, $e)
        try {
          if ($e.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
          [void](Request-Window -Name 'picker' -Action 'show' -Args @{ Tray = $true })
        } catch { Write-Log ('tray open: ' + $_.Exception.Message) }
      })
    # the skin and the hotkey that took effect outlive this call: an opening menu re-reads its
    # words, and a language may name another font family, so both stay reachable from the handler
    $script:TraySkin = New-TrayMenuSkin
    $script:TrayHot = $eff
    $dm = New-TrayMenu $script:TraySkin
    # the menu is replaced when its skin changes, and the settings window runs in this same
    # process: it finds the one the tray holds here
    $script:TrayMenuRef = $dm.Menu

    # The menu is built once and read every time it opens: the count on its header, the hotkey
    # and the two switches come from the Opening handler, so they never go stale while the tray
    # lives. The look is renderer\src\windows\tray-menu.ps1 - the panel's palette, frame and row rhythm.
    $iShow = $dm.Show
    $iShow.Add_Click({ try { [void](Request-Window -Name 'picker' -Action 'show' -Args @{ Tray = $true }) } catch { Write-Log ('tray open: ' + $_.Exception.Message) } })
    # The two panel shapes are a user preference, not a momentary state, so the tick writes the
    # ini key and the running copy of it: the next open is the other shape.
    $iCompact = $dm.Compact
    $iCompact.Add_Click({
        try {
          $on = -not [bool]$script:CompactMode
          $script:CompactMode = $on
          $iCompact.Checked = $on
          $iCompact.Invalidate()
          [void](Set-IniKey 'CompactMode' $(if ($on) { '1' } else { '0' }))
          Write-Log ('tray: compact mode=' + $on)
        } catch { Write-Log ('tray compact: ' + $_.Exception.Message) }
      })

    $iPause = $dm.Pause
    $iPause.Add_Click({
        try {
          if (Test-Path -LiteralPath $Paused) { Remove-Item -LiteralPath $Paused -Force }
          else { Ensure-Dir; New-Item -ItemType File -Path $Paused -Force | Out-Null }
          $iPause.Checked = (Test-Path -LiteralPath $Paused)
          $iPause.Invalidate()
        } catch { Write-Log ('tray pause: ' + $_.Exception.Message) }
      })
    $iClear = $dm.Clear
    $iClear.Add_Click({
        try {
          $prompt = Get-ClearPrompt @(Get-Records)
          if ([int]$prompt.Gone -le 0) {
            $noDelete = Get-UiText 'tray.nothingToDelete'
            [void][Windows.Forms.MessageBox]::Show($noDelete, 'clipboard', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information)
            return
          }
          $r = [Windows.Forms.MessageBox]::Show($prompt.Text, 'clipboard', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question)
          if ($r -ne [Windows.Forms.DialogResult]::Yes) { return }
          Clear-Store (Get-ClearKeepMarks)
          Write-Log 'tray: history cleared'
        } catch { Write-Log ('tray clear: ' + $_.Exception.Message) }
      })

    # The settings window is opened here, in the resident: a process of its own costs a PowerShell
    # start (2.0 s measured) for a window that is built in 0.9 s. What that cannot allow is two
    # modal windows on this one thread, so the panel's own `show` refuses while the window is open
    # and rings it instead - see renderer\src\windows\picker.ps1.
    $iSettings = $dm.Settings
    $iSettings.Add_Click({
        try {
          $opened = Request-Window -Name 'settings' -Action 'open'
          if ($null -eq $opened) {
            Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
              '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', (Join-Path $Root 'clipboard.ps1'), 'settings'
            )
          }
        } catch { Write-Log ('tray settings: ' + $_.Exception.Message) }
      })
    # the file itself, for a key the window does not cover (a plugin's settings, a retired key)
    $iSet = $dm.EditFile
    $iSet.Add_Click({
        try {
          $p = Write-IniTemplate
          Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $p + '"')
        } catch { Write-Log ('tray settings file: ' + $_.Exception.Message) }
      })
    $iOpen = $dm.Folder
    $iOpen.Add_Click({
        try { Ensure-Dir; Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $StoreDir + '"') }
        catch { Write-Log ('tray folder: ' + $_.Exception.Message) }
      })
    $iRestart = $dm.Restart
    $iRestart.Add_Click({ $script:ExitKind = 'restart'; [Windows.Forms.Application]::ExitThread() })
    $iAbout = $dm.About
    $iAbout.Add_Click({
        try {
          # the About page of the settings window states the version, the data format, the entry
          # count, the store and the plugins, read from the same variables as the rest of the
          # tool - so this row opens that page instead of spelling them out in a message box
          $opened = Request-Window -Name 'settings' -Action 'open' -Args @{ Group = 'About' }
          if ($null -eq $opened) {
            Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
              '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', (Join-Path $Root 'clipboard.ps1'), 'settings', 'About'
            )
          }
        } catch { Write-Log ('tray about: ' + $_.Exception.Message) }
      })

    $iExit = $dm.Exit
    $iExit.Add_Click({ $script:ExitKind = 'user'; [Windows.Forms.Application]::ExitThread() })

    $dm.Menu.Add_Opening({
        try {
          # A language saved in another process (a settings window of its own, or a `config set`)
          # has to reach the menu that is about to open and the tray tip, without restarting the
          # resident: only the words and, if the language names one, the font family change.
          $langChanged = $false
          if (Get-Command Sync-UiLanguage -ErrorAction SilentlyContinue) { $langChanged = [bool](Sync-UiLanguage) }
          if ($langChanged) {
            $script:UiFamily = ''
            $script:FBody = $null
            [void](Initialize-PanelFonts)
            try { $script:Tray.Text = (Get-UiText 'app.tooltip' @([string]$script:TrayHot)) } catch { }
          }
          # A theme saved elsewhere reaches the menu that is about to open: the rows carry the
          # skin they were built with, so the whole menu is re-skinned rather than rebuilt.
          $themeChanged = $false
          if (Get-Command Sync-UiTheme -ErrorAction SilentlyContinue) { $themeChanged = [bool](Sync-UiTheme) }
          if ($themeChanged) {
            $script:UiFamily = ''
            $script:FBody = $null
            [void](Initialize-PanelFonts)
            if (Get-Command Update-TrayLook -ErrorAction SilentlyContinue) { Update-TrayLook }
          }
          # the rows draw with the skin's faces, so a language that names its own family reaches
          # them without rebuilding the menu or the rows
          if ($null -ne $script:TraySkin -and $null -ne $script:FBody -and -not [object]::ReferenceEquals($script:TraySkin.Body, $script:FBody)) {
            $script:TraySkin.Body = $script:FBody
            $script:TraySkin.Small = $script:FSmall
          }
          $entries = -1
          try { $entries = @(Get-Records).Count } catch { $entries = -1 }
          [void](Request-Window -Name 'tray' -Action 'update' -Args @{
              Form = $dm; Entries = $entries; Hotkey = $eff
              Paused = (Test-Path -LiteralPath $Paused); Compact = [bool]$script:CompactMode
            })
        } catch { Write-Log ('tray menu: ' + $_.Exception.Message) }
      })

    $script:Tray.ContextMenuStrip = $dm.Menu

    $script:Tray.Visible = $true
    if ($script:ShowBalloon) {
      $script:Tray.ShowBalloonTip(5000, (Get-UiText 'app.balloonTitle'), (Get-UiText 'app.balloonText' @($eff)), [Windows.Forms.ToolTipIcon]::Info)
    }
  } catch { Write-Log ('tray failed: ' + $_.Exception.Message) }

  $hw.add_Hot({
      try {
        # a recording settings window takes the chord; nobody else opens the panel
        if (Send-HotkeyRecord $StoreDir $script:Hot) {
          Write-Log ('hotkey handed to the settings window: ' + $script:Hot)
          return
        }
        [void](Request-Window -Name 'picker' -Action 'show')
      } catch { Write-Log ('hotkey handler: ' + $_.Exception.Message) }
    })

  # Build the panel once, in the background, and throw it away: right after a restart the
  # first hotkey would otherwise pay for the type load, the fonts, the GDI objects and every
  # event binding (~1.3 s, measured). The timer keeps it off the startup path; a failure is
  # only a log line, and the next hotkey builds the panel the usual way.
  # The timer lives on the script scope on purpose: an event handler resolves a plain name
  # through whatever scope happens to be on the stack - the panel's own -Warm switch was
  # found as "Warm", so this is named for what it is and pinned where it is set.
  $script:WarmTimer = New-Object Windows.Forms.Timer
  $script:WarmTimer.Interval = 1500
  $script:WarmTimer.Add_Tick({
      $script:WarmTimer.Stop()
      $script:WarmTimer.Dispose()
      # a panel that is already on screen is the warm-up: there is nothing left to build, and
      # `show` with Warm answers straight away for a live panel (it never closes one)
      if ([bool](Request-Window -Name 'picker' -Action 'test')) { return }
      try {
        $tw = Get-Date
        [void](Request-Window -Name 'picker' -Action 'show' -Args @{ Warm = $true })
        Write-Log ('picker: warm-up in ' + [string]([int]((Get-Date) - $tw).TotalMilliseconds) + ' ms')
      } catch { Write-Log ('picker warm-up failed: ' + $_.Exception.Message) }
    })
  $script:WarmTimer.Start()

  $script:LastSeq = [Cb.Win]::GetClipboardSequenceNumber()
  # resolved once: asking for the command on every poll costs more than the work it guards
  $hasTicks = $null -ne (Get-Command Invoke-PluginTicks -ErrorAction SilentlyContinue)
  $timer = New-Object Windows.Forms.Timer
  $timer.Interval = $Interval
  $timer.Add_Tick({      if ($script:StopEvt.WaitOne(0)) { $script:ExitKind = 'stop'; [Windows.Forms.Application]::ExitThread(); return }
      if ($script:ShowEvt.WaitOne(0)) { [void](Request-Window -Name 'picker' -Action 'show'); return }

      # plugin background work (expiry sweeps and the like); throttled inside
      if ($hasTicks) {
        try { Invoke-PluginTicks } catch { }
      }

      if ($script:UsePoll) {
        $pk = Parse-Hotkey $script:Hot
        $down = (([Cb.Win]::GetAsyncKeyState([int]$pk.Vk) -band 0x8000) -ne 0)
        if ($down -and -not $script:PrevHotKey) {
          $script:PrevHotKey = $true
          if (Send-HotkeyRecord $StoreDir $script:Hot) { return }
          [void](Request-Window -Name 'picker' -Action 'show')
          return
        }
        if (-not $down) { $script:PrevHotKey = $false }
      }

      $seq = [Cb.Win]::GetClipboardSequenceNumber()
      if ($seq -ne 0 -and $seq -eq $script:LastSeq) { return }
      if (Test-Path -LiteralPath $Paused) { return }
      $t0 = Get-Date
      $cap = Get-ClipCapture
      if ($null -eq $cap) { return }
      if ($cap.ContainsKey('Skipped')) {
        # one line per change, and the sequence number moves on so the same snapshot does not
        # log again on every tick
        Write-Log ('capture skipped: ' + [string]$cap.Skipped)
        $script:LastSeq = $seq
        return
      }
      # an image payload is its descriptor, so the comparison stays a short string compare
      $t = [string]$cap.Text
      if ($null -ne $cap.Image) { $t = New-ImagePayload $cap.Image.Png $cap.Image.W $cap.Image.H $cap.Image.Fmt }
      if ([string]::IsNullOrEmpty($t)) { return }
      # Only "did the clipboard change?" is asked here (the sequence number). A payload is
      # not compared: the same text copied again has to be captured again, or an entry that
      # was deleted could never come back. What is already in the history is Add-Item's
      # business - it moves a known payload to the top by itself.
      Add-Item $t $cap
      # one line per capture, with what it cost: a slow clipboard read or a block that was
      # dropped is only visible here
      Write-Log ('capture: ' + (Format-Capture $t $cap) + ' in ' + [string]([int]((Get-Date) - $t0).TotalMilliseconds) + ' ms')
      $script:LastSeq = [Cb.Win]::GetClipboardSequenceNumber()
    })
  $timer.Start()
  # the proxy runs on its own, faster clock: a command should not wait for the capture
  # interval, and serving one is a connect plus a few milliseconds of work
  $proxyTimer = New-Object Windows.Forms.Timer
  $proxyTimer.Interval = 50
  $proxyTimer.Add_Tick({
      if (-not $script:ProxyListener) { return }
      try { $script:ProxyListener = Step-ProxyListener $script:ProxyListener $Root } catch { Write-Log ('proxy: ' + $_.Exception.Message) }
    })
  $proxyTimer.Start()

  $shown = if ($reg) { $script:Hot } else { '(not registered, polling ' + $Hotkey + ')' }
  Write-Host ('clipboard resident   hotkey=' + $shown + '   store=' + $StoreFile)
  Write-Log ('serve start hotkey=' + $script:Hot + ' reg=' + $reg + ' store=' + $StoreDir)
  try { [Windows.Forms.Application]::Run() }
  catch { Write-Log ('run error: ' + $_.Exception.Message) }
  finally {
    Write-Log 'serve exit'
    try { $proxyTimer.Stop() } catch { }
    try { $proxyTimer.Dispose() } catch { }
    Close-ProxyListener $script:ProxyListener
    $script:ProxyListener = $null
    try { $timer.Stop() } catch { }
    try { $timer.Dispose() } catch { }
    try { if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() } } catch { }
    $script:Tray = $null
    try { if ($reg) { [void][Cb.Win]::UnregisterHotKey($hw.Handle, 1) } } catch { }
    try { $hw.DestroyHandle() } catch { }
    try { $script:ShowEvt.Dispose() } catch { }
  }
}

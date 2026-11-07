# lib/serve.ps1 - the resident process: capture loop, hotkey, tray icon, and the supervisor
# that restarts the loop after a crash.

# The suppression state (LastSeq) lives here because the capture loop compares against it.
# Writing to it is lib/clip.ps1's job - see Set-LastCapture there.

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
  try {
    Load-Forms
    Add-Native
    try { [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { }
    [Windows.Forms.Application]::add_ThreadException({ param($s, $e) Write-Log ('ui error (ignored): ' + $e.Exception.Message) })

    # supervisor: keep the daemon alive across crashes, back off when it keeps dying
    $round = 0
    $delay = 1000
    while ($true) {
      if ($script:StopEvt.WaitOne(0)) { break }
      $script:ExitKind = ''
      $started = Get-Date
      try { Invoke-ServeOnce } catch { Write-Log ('serve crash: ' + $_.Exception.Message) }
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
  $evt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $EventName)
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
  $fb = @($script:HotkeyFallbacks -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if ($fb.Count -eq 0) { $fb = @('Ctrl+Alt+V', 'Win+V', 'Alt+`', 'Win+Shift+V') }
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
    $script:Tray.Icon = [Drawing.SystemIcons]::Information
    $script:Tray.Text = 'clipboard - ' + $eff
    $script:Tray.Add_DoubleClick({ try { Show-Picker } catch { } })
    $dm = New-Object Windows.Forms.ContextMenuStrip
    $i1 = $dm.Items.Add('Show history'); $i1.Add_Click({ try { Show-Picker } catch { } })
    $i2 = $dm.Items.Add('Pause capture'); $i2.Add_Click({ Ensure-Dir; New-Item -ItemType File -Path $Paused -Force | Out-Null })
    $i3 = $dm.Items.Add('Resume capture'); $i3.Add_Click({ if (Test-Path -LiteralPath $Paused) { Remove-Item -LiteralPath $Paused -Force } })
    $i4 = $dm.Items.Add('Clear history'); $i4.Add_Click({ Clear-Store (Get-ClearKeepMarks) })
    $i5 = $dm.Items.Add('Exit'); $i5.Add_Click({ $script:ExitKind = 'user'; [Windows.Forms.Application]::ExitThread() })
    $script:Tray.ContextMenuStrip = $dm
    $script:Tray.Visible = $true
    if ($script:ShowBalloon) {
      $script:Tray.ShowBalloonTip(5000, 'clipboard is running', ('Hotkey: ' + $eff + '  |  double-click the tray icon for history'), [Windows.Forms.ToolTipIcon]::Info)
    }
  } catch { Write-Log ('tray failed: ' + $_.Exception.Message) }

  $hw.add_Hot({ try { Show-Picker } catch { Write-Log ('hotkey handler: ' + $_.Exception.Message) } })

  # Build the panel once, in the background, and throw it away: right after a restart the
  # first hotkey would otherwise pay for the type load, the fonts, the GDI objects and every
  # event binding (~1.3 s, measured). The timer keeps it off the startup path; a failure is
  # only a log line, and the next hotkey builds the panel the usual way.
  $warm = New-Object Windows.Forms.Timer
  $warm.Interval = 1500
  $warm.Add_Tick({
      $warm.Stop()
      $warm.Dispose()
      try {
        $tw = Get-Date
        Show-Picker -Warm
        Write-Log ('picker: warm-up in ' + [string]([int]((Get-Date) - $tw).TotalMilliseconds) + ' ms')
      } catch { Write-Log ('picker warm-up failed: ' + $_.Exception.Message) }
    })
  $warm.Start()

  $script:LastSeq = [Cb.Win]::GetClipboardSequenceNumber()
  # resolved once: asking for the command on every poll costs more than the work it guards
  $hasTicks = $null -ne (Get-Command Invoke-PluginTicks -ErrorAction SilentlyContinue)
  $timer = New-Object Windows.Forms.Timer
  $timer.Interval = $Interval
  $timer.Add_Tick({      if ($script:StopEvt.WaitOne(0)) { $script:ExitKind = 'stop'; [Windows.Forms.Application]::ExitThread(); return }
      if ($evt.WaitOne(0)) { Show-Picker; return }

      # plugin background work (expiry sweeps and the like); throttled inside
      if ($hasTicks) {
        try { Invoke-PluginTicks } catch { }
      }

      if ($script:UsePoll) {
        $pk = Parse-Hotkey $script:Hot
        $down = (([Cb.Win]::GetAsyncKeyState([int]$pk.Vk) -band 0x8000) -ne 0)
        if ($down -and -not $script:PrevHotKey) { $script:PrevHotKey = $true; Show-Picker; return }
        if (-not $down) { $script:PrevHotKey = $false }
      }

      $seq = [Cb.Win]::GetClipboardSequenceNumber()
      if ($seq -ne 0 -and $seq -eq $script:LastSeq) { return }
      if (Test-Path -LiteralPath $Paused) { return }
      $t0 = Get-Date
      $cap = Get-ClipCapture
      if ($null -eq $cap) { return }
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
  Write-Log ('serve start hotkey=' + $script:Hot + ' reg=' + $reg)
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
    try { $evt.Dispose() } catch { }
  }
}

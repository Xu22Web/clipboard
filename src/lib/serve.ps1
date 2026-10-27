# lib/serve.ps1 - the resident process: capture loop, hotkey, tray icon, and the supervisor
# that restarts the loop after a crash.

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

  $script:LastSeq = [Cb.Win]::GetClipboardSequenceNumber()
  $script:LastText = Get-ClipItem

  $timer = New-Object Windows.Forms.Timer
  $timer.Interval = $Interval
  $timer.Add_Tick({
      if ($script:StopEvt.WaitOne(0)) { $script:ExitKind = 'stop'; [Windows.Forms.Application]::ExitThread(); return }
      if ($evt.WaitOne(0)) { Show-Picker; return }

      # plugin background work (expiry sweeps and the like); throttled inside
      if (Get-Command Invoke-PluginTicks -ErrorAction SilentlyContinue) {
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
      $t = Get-ClipItem
      if ($null -eq $t) { return }
      if ($t -cne $script:LastText) { $script:LastText = $t; Add-Item $t }
      $script:LastSeq = [Cb.Win]::GetClipboardSequenceNumber()
    })
  $timer.Start()

  $shown = if ($reg) { $script:Hot } else { '(not registered, polling ' + $Hotkey + ')' }
  Write-Host ('clipboard resident   hotkey=' + $shown + '   store=' + $StoreFile)
  Write-Log ('serve start hotkey=' + $script:Hot + ' reg=' + $reg)
  try { [Windows.Forms.Application]::Run() }
  catch { Write-Log ('run error: ' + $_.Exception.Message) }
  finally {
    Write-Log 'serve exit'
    try { $timer.Stop() } catch { }
    try { $timer.Dispose() } catch { }
    try { if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() } } catch { }
    $script:Tray = $null
    try { if ($reg) { [void][Cb.Win]::UnregisterHotKey($hw.Handle, 1) } } catch { }
    try { $hw.DestroyHandle() } catch { }
    try { $evt.Dispose() } catch { }
  }
}

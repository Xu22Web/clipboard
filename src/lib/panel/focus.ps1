# lib/panel/focus.ps1 - the foreground and the keyboard focus the panel borrows while it is open.
#
# The panel activates like any other window: it opens in front, the search field takes the real
# focus as soon as the user types, and keys reach it because the panel owns them - no keyboard
# hook stands in for a focus it does not have. Two things still have to be handled by hand: a
# window that is refused the foreground while another process holds it, and the control that
# owned the caret before the panel opened, which a paste has to give the keyboard back to.

# The control that owned the keyboard in the window the panel came from, remembered at open so
# the paste after a pick can put the caret back where it was. Zero means the window has no
# focused control.
function Save-TargetFocus([IntPtr]$hwnd) {
  if ($hwnd -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
  try { return [Cb.Win]::FocusOfWindow($hwnd) } catch { return [IntPtr]::Zero }
}

# Give that control the keyboard back. False means it is gone or refused; the caller restores
# the window either way.
function Restore-TargetFocus([IntPtr]$hwnd, [IntPtr]$focus) {
  if ($hwnd -eq [IntPtr]::Zero -or $focus -eq [IntPtr]::Zero) { return $false }
  $ok = $false
  try { $ok = [Cb.Win]::FocusControl($hwnd, $focus) } catch { $ok = $false }
  Write-Log ('focus restored=' + $ok)
  return $ok
}

# a modifier that is still down turns "Ctrl+V" into a different shortcut, so it is let go of
# instead of waited for: the keys are only ever sent up, never down
function Release-HeldModifiers {
  foreach ($vk in @($script:ModifierKeys)) {
    try {
      if ((([Cb.Win]::GetAsyncKeyState([int]$vk) -band 0x8000) -ne 0)) {
        [Cb.Win]::keybd_event([byte]$vk, 0, 2, [IntPtr]::Zero)
        Write-Log ('released a held modifier: vk=0x' + ([int]$vk).ToString('X'))
      }
    } catch { }
  }
}

# Bring a window to the front for real. SetForegroundWindow alone is refused while another
# process owns the foreground (the foreground lock), so a refused call is repeated with the
# input queues attached - the documented workaround - and the result is checked, never assumed.
function Take-Foreground([IntPtr]$hwnd) {
  if ($hwnd -eq [IntPtr]::Zero) { return $false }
  for ($try = 0; $try -lt 3; $try++) {
    try { [void][Cb.Win]::SetForegroundWindow($hwnd) } catch { }
    Start-Sleep -Milliseconds 25
    if ([Cb.Win]::GetForegroundWindow() -eq $hwnd) { return $true }
    $otid = [Cb.Win]::GetCurrentThreadId()
    $fg = [Cb.Win]::GetForegroundWindow()
    $ftid = [uint32]0
    if ($fg -ne [IntPtr]::Zero) { $ftid = [Cb.Win]::GetWindowThreadProcessId($fg, [IntPtr]::Zero) }
    $attached = $false
    try {
      if ($ftid -ne 0 -and $ftid -ne $otid) { $attached = [Cb.Win]::AttachThreadInput($otid, $ftid, $true) }
      [void][Cb.Win]::BringWindowToTop($hwnd)
      [void][Cb.Win]::SetForegroundWindow($hwnd)
      Start-Sleep -Milliseconds 25
    } finally {
      if ($attached) { [void][Cb.Win]::AttachThreadInput($otid, $ftid, $false) }
    }
    if ([Cb.Win]::GetForegroundWindow() -eq $hwnd) { return $true }
  }
  return $false
}

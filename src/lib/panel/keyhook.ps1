# lib/panel/keyhook.ps1 - the low-level keyboard hook that lets the panel take typing without
# taking the foreground window.
#
# Why this exists: SetFocus always activates the window that receives it (documented), and a
# WS_EX_NOACTIVATE window is no exception, so "the panel has the keyboard while your editor
# is still the active window" cannot be done with focus at all. A WH_KEYBOARD_LL hook can:
# it swallows the keys the panel wants, and the panel replays them into its own controls
# from its own thread. The foreground window - its focus, its caret, its z-order - is never
# touched, so closing the panel only unhooks; nothing has to be restored.
#
# The callback runs on the input thread, so it does the minimum: decide, count, enqueue,
# swallow. Translation and delivery happen on the panel's thread (Get-HookedKeys +
# Cb.KeyHook::ToChar), which is also the only thread allowed to touch those windows.

function Add-KeyHookType {
  if ('Cb.KeyHook' -as [type]) { return }
  # the compiled assembly carries this type too (see Test-NativeAssembly in lib\native.ps1)
  if (Get-Command Test-NativeAssembly -ErrorAction SilentlyContinue) {
    [void](Test-NativeAssembly)
    if ('Cb.KeyHook' -as [type]) { return }
  }
  # The C# lives in lib\assembly. A packaged copy ships without it and runs from
  # lib\assembly\clipboard.dll, so empty source here means the assembly went missing: say so
  # instead of handing Add-Type "".
  $cs = ''
  $csPath = Join-Path $Root 'lib\assembly\cb.keyhook.cs'
  if (Test-Path -LiteralPath $csPath) { $cs = [IO.File]::ReadAllText($csPath) }
  if (-not $cs) { throw 'lib\assembly\clipboard.dll is missing and this copy carries no C# source' }
  Add-Type -TypeDefinition $cs -ErrorAction Stop
}

# install the hook; returns $true when the panel may rely on it
function Enable-KeyHook {
  Add-KeyHookType
  $h = [Cb.KeyHook]::Install()
  if ($h -eq [IntPtr]::Zero) {
    Write-Log ('key hook failed: ' + [Cb.KeyHook]::LastError)
    return $false
  }
  Write-Log 'key hook installed'
  return $true
}

# The panel answers Ctrl+A / Ctrl+Z / Ctrl+Enter / Ctrl+0-9 plus whatever its plugins claim;
# passing those in means every other Ctrl shortcut keeps reaching the window behind.
function Set-KeyHookCtrlKeys([int[]]$keys) {
  try {
    Add-KeyHookType
    [Cb.KeyHook]::SetCtrlKeys($keys)
  } catch { Write-Log ('key hook keys: ' + $_.Exception.Message) }
}

function Disable-KeyHook {
  if (-not ('Cb.KeyHook' -as [type])) { return }
  if (-not [Cb.KeyHook]::Active) { return }
  [Cb.KeyHook]::Remove()
  Write-Log ('key hook removed swallowed=' + [Cb.KeyHook]::Swallowed)
}

function Test-KeyHook { return ('Cb.KeyHook' -as [type]) -and [Cb.KeyHook]::Active }

# Hand the keyboard over for real: an input method needs an ordinary window that owns the
# foreground and the focus. SetForegroundWindow is refused while another process owns the
# foreground (the foreground lock), so the call attaches to that thread first - the
# documented workaround - and WS_EX_NOACTIVATE comes off for as long as the IME needs it.
function Switch-ToTakeover([IntPtr]$hwnd, $TextBox) {
  Disable-KeyHook
  [Cb.Win]::SetNoActivate($hwnd, $false)
  $otid = [Cb.Win]::GetCurrentThreadId()
  $fg = [Cb.Win]::GetForegroundWindow()
  $ftid = [uint32]0
  if ($fg -ne [IntPtr]::Zero) { $ftid = [Cb.Win]::GetWindowThreadProcessId($fg, [IntPtr]::Zero) }
  $attached = $false
  try {
    if ($ftid -ne 0 -and $ftid -ne $otid) { $attached = [Cb.Win]::AttachThreadInput($otid, $ftid, $true) }
    [void][Cb.Win]::BringWindowToTop($hwnd)
    [void][Cb.Win]::SetForegroundWindow($hwnd)
    if ($null -ne $TextBox) { try { $TextBox.Focus() } catch { } }
  } finally {
    if ($attached) { [void][Cb.Win]::AttachThreadInput($otid, $ftid, $false) }
  }
  $ok = ([Cb.Win]::GetForegroundWindow() -eq $hwnd)
  Write-Log ('takeover: foreground=' + $ok + ' fgTid=' + $ftid + ' ourTid=' + $otid)
  return $ok
}

# the hand-over did not take: make the panel unreachable again and re-arm the hook, so the
# keys stay out of the window the user is working in
function Restore-KeyHook([IntPtr]$hwnd) {
  [Cb.Win]::SetNoActivate($hwnd, $true)
  $ok = Enable-KeyHook
  Write-Log ('takeover: refused, hook re-armed=' + $ok)
  return $ok
}

# replay keys through the real input queue, so the input method and the control see them
function Send-HookedKeys([int[]]$keys, [int]$from) {
  for ($i = $from; $i -lt $keys.Count; $i++) {
    [Cb.Win]::keybd_event([byte]$keys[$i], 0, 0, [IntPtr]::Zero)
    [Cb.Win]::keybd_event([byte]$keys[$i], 0, 2, [IntPtr]::Zero)
  }
}

# true when the input method is composing in its native mode for that window: that needs a
# real focus, so the panel hands itself the keyboard
function Test-ImeOpen([IntPtr]$hwnd) {
  if ($hwnd -eq [IntPtr]::Zero) { return $false }
  if (-not ('Cb.KeyHook' -as [type])) { return $false }
  return [Cb.KeyHook]::ImeNeedsFocus($hwnd)
}

# true once when the input needs a real focus (an IME started composing)
function Test-KeyHookEscalate {
  if (-not ('Cb.KeyHook' -as [type])) { return $false }
  if (-not [Cb.KeyHook]::Escalate) { return $false }
  [Cb.KeyHook]::Escalate = $false
  return $true
}

# drain the keys the hook took, in press order
function Get-HookedKeys {
  $out = New-Object System.Collections.Generic.List[int]
  if ('Cb.KeyHook' -as [type]) {
    $vk = 0
    while ([Cb.KeyHook]::Keys.TryDequeue([ref]$vk)) { $out.Add($vk) }
  }
  return $out.ToArray()
}

# the printable character behind a virtual key, or NUL
function Get-HookedChar([int]$vk) {
  if (-not ('Cb.KeyHook' -as [type])) { return [char]0 }
  return [Cb.KeyHook]::ToChar($vk)
}

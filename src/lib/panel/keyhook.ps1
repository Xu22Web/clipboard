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
  if (-not (Test-KeyHook)) { return }
  [Cb.KeyHook]::Remove()
  Write-Log ('key hook removed swallowed=' + [Cb.KeyHook]::Swallowed)
}

# $true when the type is loaded and the hook is installed; both are asked together because every
# caller that removes or reports the hook has to know the type exists first
function Test-KeyHook { return ('Cb.KeyHook' -as [type]) -and [Cb.KeyHook]::Active }
# How the panel receives typing. Every path ends here, so the rest of the panel reads one
# value instead of keeping two flags in step by hand:
#   hook     - WH_KEYBOARD_LL feeds the controls, the foreground window is untouched
#   takeover - the panel owns the foreground (a click on the search field, or an input method
#              that needs a real focus); the foreground is handed back when the panel closes
#   none     - no keyboard path (the hook could not be installed)
# $script:PickerHook / $script:PickerEscalated stay as derived values: the panel loop, the
# logs and the tests read them, and only this function writes them.
function Set-InputMode([string]$mode) {
  if (@('hook', 'takeover', 'none') -notcontains $mode) { throw ('unknown input mode: ' + $mode) }
  $script:InputMode = $mode
  $script:PickerHook = ($mode -eq 'hook')
  $script:PickerEscalated = ($mode -eq 'takeover')
  return $mode
}

function Get-InputMode { return [string]$script:InputMode }

# When the panel hands the foreground over so an input method can compose. That hand-over is
# the only way to type CJK into the filter, and it gives up what the hook exists for, so it is
# a setting:
#   auto   - the first letter (or a key the input method already claimed) hands over
#   manual - only a click on the search area asks for it
#   off    - never; the filter stays fed by the hook and no input method can compose
# The character range is the same one the filter accepts: letters and digits, never a
# modifier or a shortcut key.
function Test-ImeTakeover([string]$mode, [int]$vk, [bool]$imeNative, [bool]$claimed) {
  if ($mode -ne 'auto') { return $false }
  if ($claimed) { return $true }
  return ($imeNative -and $vk -ge 0x30 -and $vk -le 0x5A)
}

# The control that owned the keyboard in the window the panel came from, remembered at open so
# a hand-over (or the paste after a pick) can put the caret back where it was. Zero means the
# window has no focused control.
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

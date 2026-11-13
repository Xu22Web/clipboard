# lib/apprules.ps1 - which program is in front, and what that means for this paste.
#
# The rules are about the window the paste goes back to, so every lookup can name that window.
# Usually it is still the one in front; when the panel owns the foreground (an input method
# handed the keyboard over, or the user clicked into the search field) the caller passes the
# window it came from instead. Reading a process name costs a few calls to Windows, so the
# answer is cached for a moment - a rule set does not change per keystroke, and neither does
# the window a paste is being prepared for.

# Background swaps are rare, so the cache only has to cover "the same paste asks twice".
$script:AppRuleCache = @{ Stamp = [DateTime]::MinValue; Key = ''; Action = '' }

# the program that owns a window, or '' when it cannot be read
function Get-WindowProcessName($hwnd) {
  try {
    if ($null -eq $hwnd) { return '' }
    $h = [IntPtr]$hwnd
    if ($h -eq [IntPtr]::Zero) { return '' }
    $ownerPid = 0
    [void][Cb.Win]::GetWindowOwnerProcessId($h, [ref]$ownerPid)
    if ($ownerPid -le 0) { return '' }
    $proc = [Diagnostics.Process]::GetProcessById($ownerPid)
    if ($null -eq $proc) { return '' }
    return ($proc.ProcessName.ToLowerInvariant() + '.exe')
  } catch { return '' }
}

function Get-ForegroundProcessName {
  try { return (Get-WindowProcessName ([Cb.Win]::GetForegroundWindow())) } catch { return '' }
}

# Windows Start and the search flyout are topmost windows of the shell, and they take the
# keyboard with them. The panel gets out of the way for them: while it is open its hook swallows
# the printable keys, so the box the user is typing into would never see them - and the flyout
# would cover the panel anyway. The class name is what the shell's own UX frame uses; the process
# names cover the builds where that frame is hosted by a different process (Windows 11 search is
# SearchHost, Windows 10 1903-2004 is SearchApp, Windows 10 1809 and earlier is SearchUI).
$script:ShellFlyoutClasses = @('shelluxframewindowclass')
$script:ShellFlyoutProcesses = @('startmenuexperiencehost.exe', 'searchhost.exe', 'searchapp.exe',
  'searchui.exe', 'shellhost.exe', 'shellexperiencehost.exe')

# pure: is this the program that hosts Start / search
function Test-ShellProcessName([string]$name) {
  if (-not $name) { return $false }
  return ($script:ShellFlyoutProcesses -contains $name.Trim().ToLowerInvariant())
}

function Test-ShellFlyout($hwnd) {
  try {
    if ($null -eq $hwnd) { return $false }
    $h = [IntPtr]$hwnd
    if ($h -eq [IntPtr]::Zero) { return $false }
    $cls = ''
    if (Get-Command Test-NativeAssembly -ErrorAction SilentlyContinue) { [void](Test-NativeAssembly) }
    try { $cls = [string][Cb.Win]::WindowClass($h) } catch { $cls = '' }
    if ($cls -and ($script:ShellFlyoutClasses -contains $cls.ToLowerInvariant())) { return $true }
    return (Test-ShellProcessName (Get-WindowProcessName $h))
  } catch { return $false }
}

# A window the topmost panel cannot be placed over: the panel is topmost but never activates,
# so an active topmost window stays above it, and a process with UIAccess sits in a band above
# every topmost window. Own windows are not one of them - the panel, a tray icon and the console
# run in this process.
function Test-UncoverableWindow($hwnd) {
  try {
    if ($null -eq $hwnd) { return $false }
    $h = [IntPtr]$hwnd
    if ($h -eq [IntPtr]::Zero) { return $false }
    if ([Cb.Win]::IsOwnWindow($h)) { return $false }
    if (Test-ShellFlyout $h) { return $true }
    if ([Cb.Win]::IsTopmost($h)) { return $true }
    return [Cb.Win]::HasUiAccess($h)
  } catch { return $false }
}

# Windows the shell owns rather than the user: the taskbar, the tray, the overflow island that
# holds the tray icons of Windows 11, and the desktop itself. They are topmost and belong to a
# process with UIAccess, so the panel treats them as uncouverageable - which is right for a
# hotkey, where the window in front is what the user is working in, and wrong for a click on the
# tray icon, where it is only the window the click came from.
function Test-ShellWindowClass([string]$cls) {
  if (-not $cls) { return $false }
  $c = $cls.Trim().ToLowerInvariant()
  if ($c -eq 'shell_traywnd' -or $c -eq 'traynotifywnd' -or $c -eq 'notifyiconoverflowwindow' -or
      $c -eq 'toplevelwindowforoverflowxamlisland' -or $c -eq 'progman' -or $c -eq 'workerw') { return $true }
  # a taskbar moved to another monitor is still a taskbar, and its class says which one
  return $c.StartsWith('shell_secondarytraywnd')
}

function Test-ShellOwnWindow($hwnd) {
  try {
    $h = [IntPtr]$hwnd
    if ($h -eq [IntPtr]::Zero) { return $false }
    $proc = ''
    try { $proc = [string][IO.Path]::GetFileName([string](Get-WindowProcessName $h)) } catch { $proc = '' }
    if ($proc.ToLowerInvariant() -ne 'explorer.exe') { return $false }
    $cls = ''
    try { $cls = [string][Cb.Win]::WindowClass($h) } catch { $cls = '' }
    if (Test-ShellWindowClass $cls) { return $true }
    return ([Cb.Win]::IsTopmost($h))
  } catch { return $false }
}

# The window the panel should come from when the request did not come from one: the first window
# below the given one that is neither this process's own nor the shell's. The argument is kept
# when the chain runs out, so a caller that passes a normal window gets it back unchanged.
function Get-UsableForeground([IntPtr]$hwnd) {
  $h = $hwnd
  for ($i = 0; $i -lt 16; $i++) {
    if ($h -eq [IntPtr]::Zero) { break }
    if ([Cb.Win]::IsOwnWindow($h)) { $h = [Cb.Win]::WindowBelow($h); continue }
    if (Test-ShellOwnWindow $h) { $h = [Cb.Win]::WindowBelow($h); continue }
    return $h
  }
  return $hwnd
}

# a window as a log line names it: its class, then the program that owns it
function Format-ForegroundWindow($hwnd) {
  try {
    $h = [IntPtr]$hwnd
    $what = ''
    try { $what = [string][Cb.Win]::WindowClass($h) } catch { $what = '' }
    try { $p = Get-WindowProcessName $h; if ($p) { $what = ($what + ' ' + $p).Trim() } } catch { }
    if (-not $what) { $what = 'hwnd=0x' + ([int64]$h).ToString('X') }
    return $what
  } catch { return '' }
}

# Close the shell flyout that is in front, so the panel can open over what is behind it (the way
# Ditto does it). Two ways, because the flyout is not ours to configure: Escape is what Start and
# search listen for, and a shell flyout also closes when it loses the foreground, so the window
# below it in the z-order is brought forward when Escape is ignored. The wait is for its window
# to go before the panel reads the foreground it will paste back to.
function Close-ShellFlyout($hwnd) {
  try {
    if (-not (Test-ShellFlyout $hwnd)) { return $false }
    $h = [IntPtr]$hwnd
    [Cb.Win]::keybd_event(0x1B, 0, 0, [IntPtr]::Zero)
    [Cb.Win]::keybd_event(0x1B, 0, 2, [IntPtr]::Zero)
    if (Wait-FlyoutGone 400) { return $true }
    $below = [Cb.Win]::WindowBelow($h)
    while ($below -ne [IntPtr]::Zero -and ([Cb.Win]::IsOwnWindow($below) -or (Test-ShellFlyout $below))) {
      $below = [Cb.Win]::WindowBelow($below)
    }
    if ($below -eq [IntPtr]::Zero) { return $false }
    [void][Cb.Win]::SetForegroundWindow($below)
    return (Wait-FlyoutGone 300)
  } catch { return $false }
}

# wait for the foreground to stop being a shell flyout, answer whether it did
function Wait-FlyoutGone([int]$Milliseconds) {
  $deadline = (Get-Date).AddMilliseconds($Milliseconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 25
    try { if (-not (Test-ShellFlyout ([Cb.Win]::GetForegroundWindow()))) { return $true } } catch { return $true }
  }
  return $false
}

# The action the rules give this program: '' means "no rule, do what the settings say".
function Get-AppRuleAction([string]$processName = '') {
  $rules = $null
  if (Get-Command ConvertFrom-AppRuleText -ErrorAction SilentlyContinue) {
    $rules = ConvertFrom-AppRuleText ([string]$script:AppRules)
  }
  if ($null -eq $rules -or $rules.Count -eq 0) { return '' }
  if (-not $processName) { $processName = Get-ForegroundProcessName }
  if ($processName) {
    $processName = $processName.ToLowerInvariant()
    if ($processName -notlike '*.exe' -and $processName -ne '*') { $processName = $processName + '.exe' }
    if ($rules.Contains($processName)) { return [string]$rules[$processName] }
  }
  if ($rules.Contains('*')) { return [string]$rules['*'] }
  return ''
}

# The action for a window - the one in front when none is named - remembered for a few hundred
# milliseconds so one paste pays for the process lookup once. With no rules at all nothing is
# asked of Windows.
function Get-CurrentAppRule($hwnd = $null) {
  $rules = ConvertFrom-AppRuleText ([string]$script:AppRules)
  if ($null -eq $rules -or $rules.Count -eq 0) { return '' }
  if ($null -eq $hwnd) {
    try { $hwnd = [Cb.Win]::GetForegroundWindow() } catch { $hwnd = $null }
  }
  $now = [DateTime]::UtcNow
  $key = ''
  if ($null -ne $hwnd) { $key = ([IntPtr]$hwnd).ToString() }
  if ($script:AppRuleCache.Key -eq $key -and ($now - $script:AppRuleCache.Stamp).TotalMilliseconds -lt 400) {
    return [string]$script:AppRuleCache.Action
  }
  $action = Get-AppRuleAction (Get-WindowProcessName $hwnd)
  $script:AppRuleCache = @{ Stamp = $now; Key = $key; Action = $action }
  return $action
}

# Does the formatted sidecar stay with this entry? A rule that says plain wins over the
# setting; PasteRich=0 still wins over everything, because it is the master switch.
function Test-AppRuleKeepsRich($hwnd = $null) {
  if (-not $script:PasteRich) { return $false }
  return ((Get-CurrentAppRule $hwnd) -ne 'plain')
}

# A program the user never wants a paste into: the copy still happens, the keys do not.
function Test-AppRuleNoPaste($hwnd = $null) {
  return ((Get-CurrentAppRule $hwnd) -eq 'no-paste')
}

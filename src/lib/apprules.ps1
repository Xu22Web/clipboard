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
# names cover the builds where that frame is hosted by a different process.
$script:ShellFlyoutClasses = @('shelluxframewindowclass')
$script:ShellFlyoutProcesses = @('startmenuexperiencehost.exe', 'searchhost.exe', 'shellhost.exe', 'shellexperiencehost.exe')

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

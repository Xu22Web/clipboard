# lib/apprules.ps1 - which program is in front, and what that means for this paste.
#
# The panel never takes the foreground, so at paste time the window in front is still the one
# the user came from: that is the window the rules are about. Reading a process name costs a
# few calls to Windows, so the answer is cached for a moment - a rule set does not change per
# keystroke, and neither does the foreground window while a paste is being prepared.

# Background swaps are rare, so the cache only has to cover "the same paste asks twice".
$script:AppRuleCache = @{ Stamp = [DateTime]::MinValue; Key = ''; Action = '' }

function Get-ForegroundProcessName {
  try {
    $hwnd = [Cb.Win]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return '' }
    $ownerPid = 0
    [void][Cb.Win]::GetWindowOwnerProcessId($hwnd, [ref]$ownerPid)
    if ($ownerPid -le 0) { return '' }
    $proc = [Diagnostics.Process]::GetProcessById($ownerPid)
    if ($null -eq $proc) { return '' }
    return ($proc.ProcessName.ToLowerInvariant() + '.exe')
  } catch { return '' }
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

# The action for whatever is in front right now, remembered for a few hundred milliseconds so
# one paste pays for the process lookup once. With no rules at all nothing is asked of Windows.
function Get-CurrentAppRule {
  $rules = ConvertFrom-AppRuleText ([string]$script:AppRules)
  if ($null -eq $rules -or $rules.Count -eq 0) { return '' }
  $now = [DateTime]::UtcNow
  $key = ''
  try { $key = [Cb.Win]::GetForegroundWindow().ToString() } catch { $key = '' }
  if ($script:AppRuleCache.Key -eq $key -and ($now - $script:AppRuleCache.Stamp).TotalMilliseconds -lt 400) {
    return [string]$script:AppRuleCache.Action
  }
  $action = Get-AppRuleAction (Get-ForegroundProcessName)
  $script:AppRuleCache = @{ Stamp = $now; Key = $key; Action = $action }
  return $action
}

# Does the formatted sidecar stay with this entry? A rule that says plain wins over the
# setting; PasteRich=0 still wins over everything, because it is the master switch.
function Test-AppRuleKeepsRich {
  if (-not $script:PasteRich) { return $false }
  return ((Get-CurrentAppRule) -ne 'plain')
}

# A program the user never wants a paste into: the copy still happens, the keys do not.
function Test-AppRuleNoPaste {
  return ((Get-CurrentAppRule) -eq 'no-paste')
}

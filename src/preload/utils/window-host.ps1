# src\preload\utils\window-host.ps1 - the layer the three windows talk through.
#
# The windows are loaded as separate chunks and must not call each other: a call is a compile-time
# edge, and an edge means the module travels in every window that reaches it. What they share is
# this file - a table of handlers plus the state that decides whether a request can be answered.
#
#   a window registers what it can do
#       Register-Window -Name 'settings' -Handlers @{ open = {...}; hide = {...} }
#   anyone asks for it by name
#       $null = Request-Window -Name 'settings' -Action 'open' -Args @{ Group = 'Theme' }
#
# A request for a window that is not loaded returns $null. That is the same answer a caller used
# to get from `Get-Command ... -ErrorAction SilentlyContinue`, so a command that never opens a
# window still does not pay for one, and a package missing a window still runs.
$script:WindowHandlers = @{}
$script:WindowState = @{}

# What a window can do, keyed by action name. Registering merges into what the name already
# answers, so a window can add an action without dropping the ones another module registered for
# it; registering the same action twice replaces that action.
function Register-Window {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)]$Handlers
  )
  $key = [string]$Name
  if (-not $script:WindowHandlers.ContainsKey($key)) { $script:WindowHandlers[$key] = @{} }
  $table = $script:WindowHandlers[$key]
  foreach ($k in @($Handlers.Keys)) { $table[[string]$k] = $Handlers[$k] }
  if (-not $script:WindowState.ContainsKey($key)) {
    $script:WindowState[$key] = @{ Open = $false }
  }
}

# Ask a window to do something. An unknown window or an unknown action answers $null - "not here",
# never an error: the caller decides whether that matters.
function Request-Window {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Action,
    $Args = @{}
  )
  $key = [string]$Name
  if (-not $script:WindowHandlers.ContainsKey($key)) { return $null }
  $handlers = $script:WindowHandlers[$key]
  if (-not $handlers.ContainsKey([string]$Action)) { return $null }
  $call = @{ Arguments = $Args }
  return (& $handlers[[string]$Action] $Args)
}

# The state a window keeps about itself, for the questions the caller may ask without waking it:
# whether it is open, whether it is hidden behind the panel.
function Set-WindowState([string]$Name, [string]$Key, $Value) {
  $window = [string]$Name
  if (-not $script:WindowState.ContainsKey($window)) { $script:WindowState[$window] = @{ Open = $false } }
  $script:WindowState[$window][[string]$Key] = $Value
}

function Get-WindowState([string]$Name, [string]$Key, $Default = $null) {
  $window = [string]$Name
  if (-not $script:WindowState.ContainsKey($window)) { return $Default }
  $state = $script:WindowState[$window]
  if (-not $state.ContainsKey([string]$Key)) { return $Default }
  return $state[[string]$Key]
}

# Whether a window is up. The window layer (src\main\utils\window.ps1) is the authority once it is
# loaded; this table is the answer for the commands that never load it (a base-module command
# asking whether a window exists just gets "no" without paying for WinForms).
function Test-WindowOpen([string]$Name) {
  if (Get-Command Test-AppWindowVisible -ErrorAction SilentlyContinue) { return (Test-AppWindowVisible $Name) }
  return [bool](Get-WindowState $Name 'Open' $false)
}

# preload\utils\ipc.ps1 - the one way a caller inside this process reaches the program's data.
#
# A window does not call the store's functions. It calls a channel:
#
#     $rows  = Invoke-Ipc 'list'
#     $count = Invoke-Ipc 'list' | Measure-Object | Select-Object -ExpandProperty Count
#
# and src\shared\ipc\channels.ini says which function answers it. That is the same split Electron
# makes with a preload script: the surface is written down in one place, and the caller cannot
# reach past it. A name that is not a channel, or a channel with no Handler=, is refused here
# rather than silently running some function that happens to exist.
#
# The call itself is a plain function call in this process - the panel, the tray and the
# settings window live in the resident, where the store is already loaded and warm. A caller
# in a process of its own is a different question, answered by main\utils\proxy.ps1: that file sends
# a command over the pipe, and a command it may send is the same table's Remote=1.
#
# Nothing here decides what the data means. A channel returns what its handler returns, so a
# caller that needs rows gets the same objects Get-Records hands the panel today.

# The channel table, read on first use and kept for the life of the process. An empty table
# refuses every call: a missing file is a packaging problem, and a loud "not a channel" beats
# a caller quietly reading a stale answer.
#
# Two things happen inside this function on purpose. The root comes from the entry's $Root
# rather than a path built from a module's own location, which inside a section folder points
# at that folder and would make every path one level deep. And the table reader is pulled in
# here rather than at the top of the file: a module is declarations, and the entry's fast path
# dot-sources only
# the transport.
function Get-IpcTable {
  if ($null -eq $script:IpcTable) {
    $root = [string]$Root
    if (-not $root) { throw 'Invoke-Ipc needs the tool root: call it from inside the program' }
    if (-not (Get-Command Get-ProxyChannels -ErrorAction SilentlyContinue)) {
      . (Join-Path (Join-Path $root 'main\utils') 'proxy.ps1')
    }
    $script:IpcTable = Get-ProxyChannels $root
  }
  return $script:IpcTable
}

# the handler a channel names, '' when the channel is not part of the surface
function Get-IpcHandler([string]$Channel) {
  if (-not $Channel) { return '' }
  $table = Get-IpcTable
  $name = ''
  if ($table.Handler.ContainsKey($Channel)) { $name = [string]$table.Handler[$Channel] }
  return $name
}

# Call one channel. Positional arguments go to its handler as -ArgumentList, so a handler that
# takes none ignores an empty @(); a hash table goes as named parameters.
function Invoke-Ipc([string]$Channel, $Arguments = $null) {
  $handler = Get-IpcHandler $Channel
  if (-not $handler) { throw ('not a channel: ' + [string]$Channel) }
  $fn = Get-Command $handler -CommandType Function -ErrorAction SilentlyContinue
  if (-not $fn) { throw ('channel ' + $Channel + ' names a handler that is not loaded: ' + $handler) }
  if ($null -eq $Arguments) { return (& $fn) }
  if ($Arguments -is [System.Collections.IDictionary]) {
    $named = @{}
    foreach ($k in $Arguments.Keys) { $named[[string]$k] = $Arguments[$k] }
    return (& $fn @named)
  }
  return (& $fn @($Arguments))
}

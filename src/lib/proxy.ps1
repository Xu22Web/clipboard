# lib/proxy.ps1 - handing a command to the resident process instead of starting a new one.
#
# A call to the command line costs about 2.5 s, and almost all of it is PowerShell starting
# and parsing this program. The resident already paid that: it holds every module, the
# plugins and a warm store cache. So a command that only reads or writes the history can be
# sent over a named pipe and answered in milliseconds.
#
# What travels is a request, never a script: a command name, the four positional values, the
# count, the four switches that may be present, and stdin. The server refuses anything else,
# and only answers a client that names the same tool root.
#
# The pipe is per user and a request names its tool root: the resident answers only requests
# that name its own root, so a copy of the tool with its own data\ (a test sandbox, a second
# install) gets a refusal instead of an answer.
#
# The client half runs before the module table, so it may only use this file: it needs no ini
# and no path, only the account name the pipe is made of. The server half has no such limit:
# it runs inside the resident, where everything is loaded.

$script:ProxyFrameLimit = 1048576
# names the resident never answers: they change settings, move the store, touch the registry,
# or are the resident itself
$script:ProxyDirectOnly = @(
  '', 'config', 'themes', 'install', 'uninstall', 'serve', 'stop', 'ui', 'edit',
  'export', 'import', 'backup', 'restore', 'migrate', '-h', '--help'
)

# The pipe one user talks over: one name per account, not per data folder. That keeps the
# client cheap - it needs no ini and no path, so it can be up and connected before the module
# table is even parsed - and the server still holds the line: a request names its tool root,
# and only the resident of that root answers it. A sandbox or a second install gets "wrong
# root" back and quietly takes the slow path.
function Get-ProxyPipeName {
  $sid = ''
  try { $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $sid = [string]$env:USERNAME }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sid))
    $hex = -join @($hash[0..7] | ForEach-Object { $_.ToString('x2') })
  } finally { $sha.Dispose() }
  return ('clipboard-cmd-' + $hex)
}

# May this command be answered by the resident? A name the dispatcher knows is proxyable
# unless it is on the direct list; a name it does not know is a plugin verb, and those read
# and write entries exactly like the built-in ones do.
function Test-Proxyable([string]$Command, $CommandGroups) {
  $name = ''
  if ($null -ne $Command) { $name = ([string]$Command).Trim().ToLowerInvariant() }
  if ($script:ProxyDirectOnly -contains $name) { return $false }
  if ($CommandGroups -and $CommandGroups.ContainsKey($name)) { return $true }
  return ($name -match '^[a-z][a-z0-9_-]*$')
}

# ---- framing: four bytes of length, then that many bytes of UTF-8 -------------------------

function Write-ProxyFrame([System.IO.Stream]$Stream, [string]$Text) {
  $body = [Text.Encoding]::UTF8.GetBytes($Text)
  $Stream.Write([BitConverter]::GetBytes([int]$body.Length), 0, 4)
  $Stream.Write($body, 0, $body.Length)
  $Stream.Flush()
}

# a read that gives up instead of blocking the caller's thread on a client that never sends
function Read-ProxyBytes([System.IO.Stream]$Stream, [byte[]]$Buffer, [int]$Offset, [int]$Count, [int]$TimeoutMs) {
  $read = 0
  while ($read -lt $Count) {
    $task = $null
    try { $task = $Stream.ReadAsync($Buffer, $Offset + $read, $Count - $read) } catch { return $false }
    if (-not $task.Wait($TimeoutMs)) { return $false }
    $n = 0
    try { $n = [int]$task.Result } catch { return $false }
    if ($n -le 0) { return $false }
    $read += $n
  }
  return $true
}

function Read-ProxyFrame([System.IO.Stream]$Stream, [int]$TimeoutMs) {
  $header = [byte[]]::new(4)
  if (-not (Read-ProxyBytes $Stream $header 0 4 $TimeoutMs)) { return $null }
  $length = [BitConverter]::ToInt32($header, 0)
  if ($length -le 0 -or $length -gt $script:ProxyFrameLimit) { return $null }
  $body = [byte[]]::new($length)
  if (-not (Read-ProxyBytes $Stream $body 0 $length $TimeoutMs)) { return $null }
  return [Text.Encoding]::UTF8.GetString($body)
}

# one field of a request, whatever ConvertFrom-Json produced for it (and a hashtable, for the
# in-process callers in the tests)
function Get-ProxyField($Request, [string]$Name, [string]$Fallback = '') {
  if ($null -eq $Request) { return $Fallback }
  if ($Request -is [System.Collections.IDictionary]) {
    if (-not $Request.Contains($Name)) { return $Fallback }
    if ($null -eq $Request[$Name]) { return $Fallback }
    return [string]$Request[$Name]
  }
  $p = $Request.PSObject.Properties[$Name]
  if ($null -eq $p -or $null -eq $p.Value) { return $Fallback }
  return [string]$p.Value
}

# ---- client ----------------------------------------------------------------------------

# The whole client side of the entry: decide, ask, print, exit. Returns (falls through) when
# no resident answered, so the caller goes on to parse this program and run the command the
# slow way. The request carries what the caller bound, so `config set key ""` stays different
# from `config set key`.
function Invoke-ProxyAttempt([string]$Root, $CommandGroups, [string]$Command, $Value, $Sub, $Arg, [int]$Count, $Bound) {
  if (-not (Test-Proxyable $Command $CommandGroups)) { return }
  $switches = @()
  foreach ($s in @('Purge', 'All', 'Media', 'Replace')) {
    if ($Bound -and $Bound.ContainsKey($s) -and $Bound[$s]) { $switches += $s }
  }
  $client = New-ProxyConnection
  if (-not $client) { return }
  $request = @{
    v        = 1
    root     = $Root
    cmd      = [string]$Command
    value    = [string]$Value
    sub      = [string]$Sub
    arg      = [string]$Arg
    count    = $Count
    switches = $switches
    bound    = @($Bound.Keys)
  }
  $reply = Invoke-ProxySession $client $request
  if (-not $reply) { return }
  $code = 1
  [void][int]::TryParse((Get-ProxyField $reply 'code' '1'), [ref]$code)
  # 2 and 3 are refusals - another tool root answered the pipe, or a version that does not know
  # this command. Both mean "run it yourself", so the caller falls through with nothing printed.
  if ($code -eq 2 -or $code -eq 3) { return }
  if ($code -ne 0) {
    # the resident started the command and it failed there: printing the error is the answer,
    # and running it a second time in this process could do the work twice
    $err = [string](Get-ProxyField $reply 'err')
    if ($err) { [Console]::Error.WriteLine('[x] ' + $err) }
    exit $code
  }
  [Console]::Out.Write([string](Get-ProxyField $reply 'out'))
  exit 0
}

# A connected client, or $null when no resident is listening for this user. The caller owns
# the stream and has to dispose it.
function New-ProxyConnection([int]$ConnectMs = 120) {
  $client = $null
  try {
    # [T]::new(), not New-Object: the first New-Object in a process costs about 200 ms, and
    # this whole call is meant to cost less than that
    $client = [System.IO.Pipes.NamedPipeClientStream]::new('.', (Get-ProxyPipeName), [System.IO.Pipes.PipeDirection]::InOut)
    $client.Connect($ConnectMs)
    return $client
  } catch {
    if ($client) { try { $client.Dispose() } catch { } }
    return $null
  }
}

# One request over an open connection; $null when the resident did not answer.
function Invoke-ProxySession($Client, $Request, [int]$IOMs = 2000) {
  if (-not $Client) { return $null }
  try {
    Write-ProxyFrame $Client ($Request | ConvertTo-Json -Compress -Depth 4)
    $text = Read-ProxyFrame $Client $IOMs
    if (-not $text) { return $null }
    $reply = $text | ConvertFrom-Json
    return @{ Code = [int](Get-ProxyField $reply 'code' '1'); Out = (Get-ProxyField $reply 'out') }
  } catch {
    return $null
  }
}

# Connect, ask, disconnect: what a caller that only wants one answer uses.
function Invoke-ProxyClient($Request, [int]$ConnectMs = 120, [int]$IOMs = 2000) {
  $client = New-ProxyConnection (Get-ProxyField $Request 'store') $ConnectMs
  if (-not $client) { return $null }
  try { return (Invoke-ProxySession $client $Request $IOMs) }
  finally { try { $client.Dispose() } catch { } }
}

# ---- server ----------------------------------------------------------------------------

# One pending connection, created before the first client knocks. The security descriptor is
# the caller's own account; when that overload is refused the stream still runs as this user,
# and the request is checked again below anyway.
function New-ProxyListener {
  $name = Get-ProxyPipeName
  $stream = $null
  try {
    $security = [System.IO.Pipes.PipeSecurity]::new()
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = [System.IO.Pipes.PipeAccessRule]::new($sid, [System.IO.Pipes.PipeAccessRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)
    $security.AddAccessRule($rule)
    $stream = [System.IO.Pipes.NamedPipeServerStream]::new($name, [System.IO.Pipes.PipeDirection]::InOut, 1, [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous, 65536, 65536, $security)
  } catch {
    $stream = [System.IO.Pipes.NamedPipeServerStream]::new($name, [System.IO.Pipes.PipeDirection]::InOut, 1, [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous)
  }
  return @{ Name = $name; Stream = $stream; Task = $stream.WaitForConnectionAsync() }
}

function Close-ProxyListener($Listener) {
  if (-not $Listener) { return }
  try { $Listener.Stream.Dispose() } catch { }
}

# The request as the dispatcher wants it: the four positional values, the count, and the
# switches that may be present. Anything else is dropped rather than passed on.
function ConvertFrom-ProxyRequest($Request) {
  $call = @{}
  $call['Command'] = (Get-ProxyField $Request 'cmd')
  $call['Value'] = (Get-ProxyField $Request 'value')
  $call['Sub'] = (Get-ProxyField $Request 'sub')
  $call['Arg'] = (Get-ProxyField $Request 'arg')
  $count = 0
  [void][int]::TryParse((Get-ProxyField $Request 'count' '0'), [ref]$count)
  $call['Count'] = $count
  $switches = @()
  $p = $Request.PSObject.Properties['switches']
  if ($null -ne $p -and $null -ne $p.Value) { $switches = @($p.Value) }
  foreach ($s in @('Purge', 'All', 'Media', 'Replace')) { $call[$s] = [bool]($switches -contains $s) }
  # the command runs inside the resident, so `status` has to say so: its own mutex test would
  # find the mutex held by this very thread and call it "not running"
  $call['Resident'] = $true
  return $call
}

# Serve at most one waiting request and hand back the listener for the next poll. The same
# listener comes back when nobody knocked, so the caller keeps one variable.
function Step-ProxyListener($Listener, [string]$Root) {
  if (-not $Listener) { return $null }
  if (-not $Listener.Task.IsCompleted) { return $Listener }
  $stream = $Listener.Stream
  $reply = @{ v = 1; code = 1; out = ''; err = '' }
  try {
    try { $stream.EndWaitForConnection($Listener.Task) } catch { }
    $text = Read-ProxyFrame $stream 500
    if ($text) {
      $request = $null
      try { $request = $text | ConvertFrom-Json } catch { $request = $null }
      $sameRoot = ([string](Get-ProxyField $request 'root')) -eq $Root
      if (-not $sameRoot) {
        $reply.code = 2
        $reply.err = 'wrong root'
      } elseif (-not (Test-Proxyable (Get-ProxyField $request 'cmd') $null)) {
        $reply.code = 3
        $reply.err = 'not proxied'
      } else {
        $reply.code = 0
        $reply.out = [string](Invoke-ProxyCommand $request)
      }
    }
  } catch {
    $reply.code = 1
    $reply.err = $_.Exception.Message
  }
  try { Write-ProxyFrame $stream (ConvertTo-Json $reply -Compress -Depth 3) } catch { }
  try { $stream.Dispose() } catch { }
  return (New-ProxyListener)
}

# Run one request inside the resident and collect what it printed. `get` writes with
# [Console]::Out, everything else with Write-Host (the information stream in 5.1), so both
# channels are redirected for the length of the call.
function Invoke-ProxyCommand($Request) {
  $call = ConvertFrom-ProxyRequest $Request
  $text = ''
  $writer = [System.IO.StringWriter]::new()
  $stdout = [Console]::Out
  try {
    [Console]::SetOut($writer)
    $text = [string](& { Invoke-Dispatch $call } 6>&1 | Out-String)
  } catch {
    $text = ('[x] ' + $_.Exception.Message)
  } finally {
    try { [Console]::SetOut($stdout) } catch { }
    $direct = ''
    try { $direct = $writer.ToString() } catch { }
    if ($direct) { $text = $direct + $text }
    try { $writer.Dispose() } catch { }
  }
  return $text
}

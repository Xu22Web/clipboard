#Requires -Version 5.1
<#
  tests\lib\cli-runner.ps1 - one process that runs command line calls for a part, one at a time.

  A cold call costs about 4 s: 1.4-2 s is powershell.exe starting and another second is the
  modules the entry dot-sources. The price of the interpreter is paid once here instead, and
  each request runs in a fresh runspace, so a command still starts from nothing the way the
  user's shell does.

  A fresh runspace is not the same as a fresh process: a plugin that keeps a script block and
  calls back into the tool finds the tool's functions missing. Commands that reach a plugin
  therefore say so (Cold) and are run as a real child process, exactly as before.

  Protocol, one JSON object per line in each direction:
    in   { "Args": ["status"], "Cold": false }
    out  { "Ok": true, "Text": "<the command's stdout+stdout+error as one string>" }

  Nothing else may be written to stdout: the tool's own output is captured with 6>&1 2>&1.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Sandbox
)

$ErrorActionPreference = 'Stop'
$ps1 = Join-Path $Sandbox 'clipboard.ps1'
if (-not (Test-Path -LiteralPath $ps1)) {
  [Console]::Out.WriteLine('{"Ok":false,"Text":"no clipboard.ps1 in the sandbox"}')
  exit 2
}
$utf8 = New-Object System.Text.UTF8Encoding $false
$stdin = [Console]::In
$stdout = [Console]::Out

function Quote-Token([string]$t) {
  if ($t -match '^-[A-Za-z]') { return $t }
  return ("'" + ($t -replace "'", "''") + "'")
}

# one command in a runspace of its own: every dot-source, every $script: value and every
# plugin object starts empty, which is what a new process gave us
function Invoke-Warm([string[]]$Tokens) {
  $line = '& "' + $ps1 + '" ' + (($Tokens | ForEach-Object { Quote-Token ([string]$_) }) -join ' ') + ' 6>&1 2>&1'
  $rs = [runspacefactory]::CreateRunspace()
  $rs.Open()
  $ps = [powershell]::Create()
  $ps.Runspace = $rs
  try {
    [void]$ps.AddScript($line)
    $out = $ps.Invoke()
    $sb = New-Object System.Text.StringBuilder
    foreach ($o in $out) { [void]$sb.AppendLine([string]$o) }
    foreach ($e in $ps.Streams.Error) { [void]$sb.AppendLine([string]$e) }
    return $sb.ToString()
  } finally {
    $ps.Dispose()
    $rs.Close()
    $rs.Dispose()
  }
}

function Invoke-Cold([string[]]$Tokens) {
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $ps1) + $Tokens
  return (& powershell @a 2>&1 | Out-String)
}

while ($true) {
  $line = $stdin.ReadLine()
  if ($null -eq $line) { break }
  if ($line.Trim().Length -eq 0) { continue }
  $text = ''
  $ok = $true
  try {
    $req = $line | ConvertFrom-Json
    $tokens = @($req.Args | ForEach-Object { [string]$_ })
    if ($req.Cold) { $text = Invoke-Cold $tokens } else { $text = Invoke-Warm $tokens }
  } catch {
    $ok = $false
    $text = $_.Exception.Message
  }
  $payload = @{ Ok = $ok; Text = $text } | ConvertTo-Json -Compress
  $stdout.WriteLine($payload)
  $stdout.Flush()
}

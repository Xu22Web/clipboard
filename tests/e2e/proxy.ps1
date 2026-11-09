#Requires -Version 5.1
<#
  proxy.ps1 - the resident answers a command instead of a fresh process parsing everything

  Everything else runs one process per command line, because that is the contract. This part
  checks the shortcut: a resident is started in a sandbox, and the same commands are run once
  through the pipe and once with -NoProxy, then compared.

  It needs the real clipboard, like the end-to-end part: the resident captures it. The machine
  clipboard is saved around the run and given back afterwards.
#>
[CmdletBinding()]
param(
  [string]$Source = '',
  [string]$ResultFile = '',
  [string]$ProgressFile = '',
  [switch]$Quiet,
  [switch]$ClipShared
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'lib\harness.ps1')
$script:Harness.Part = 'proxy'
Start-TestPart -Source $Source -ClipShared:$ClipShared -Quiet:$Quiet -ProgressFile $ProgressFile
$dir = New-Sandbox 'proxy'
$clip = Join-Path $dir 'clipboard.ps1'
$log = Join-Path $dir 'data\clipboard.log'

# the resident keeps its log open while it runs, so a read can lose the race
function Read-TextSafe([string]$path) {
  try { if (Test-Path -LiteralPath $path) { return [IO.File]::ReadAllText($path) } } catch { }
  return ''
}

# one command line in a fresh process; -Direct adds -NoProxy, which is the path this part is
# measuring against. Returns the text and how long it took.
function Run-Clip([string[]]$cliArgs, [switch]$Direct) {
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $clip)
  if ($Direct) { $a += '-NoProxy' }
  $a += $cliArgs
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $out = (& powershell @a 2>&1 | Out-String)
  $sw.Stop()
  return @{ Out = $out; Ms = [int]$sw.Elapsed.TotalMilliseconds }
}

Describe 'e2e' {
  BeforeAll {
    $script:skipAll = ''
    $script:up = $false
    $script:child = $null
    $script:fast = $null
    $script:slow = $null
    $script:clipBak = ''
    try { $script:clipBak = (Get-Clipboard -Raw -ErrorAction Stop) } catch { $script:clipBak = '' }
    if (-not (Test-MutexFree 'Local\clipboard.daemon')) {
      $script:skipAll = 'a resident is already running - stop it first'
      return
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $clip, 'serve')
    $script:child = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argList -PassThru
    for ($i = 0; $i -lt 80 -and -not $script:up; $i++) {
      Start-Sleep -Milliseconds 250
      if ((Read-TextSafe $log) -match 'serve start') { $script:up = $true }
    }
  }

  AfterAll {
    if ($script:child -and -not $script:child.HasExited) { try { $script:child.Kill() } catch { } }
    if ($script:clipBak) { [void](Set-Clip $script:clipBak) } else { [void](Set-Clip '') }
  }

  It 'resident answers on the pipe' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    Expect $script:up 'the resident should log serve start while it comes up'
  }
  # a first command warms nothing on the resident side: it is already warm by design
  It 'the proxied call is the faster one' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    if (-not $script:up) { Expect $false 'the resident did not come up'; return }
    # the pipe does not remove PowerShell's own start, so the honest claim is "faster than a
    # fresh process"; the numbers are printed either way so a regression is visible
    $script:fast = Run-Clip @('list')
    $script:slow = Run-Clip @('list') -Direct
    Expect ($script:fast.Ms -lt $script:slow.Ms) ('proxy ' + $script:fast.Ms + ' ms / direct ' + $script:slow.Ms + ' ms')
  }
  It 'a proxied answer matches the direct one' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    if (-not $script:up) { Expect $false 'the resident did not come up'; return }
    # the same two calls the row above made: a second pair would only measure the machine again
    if ($null -eq $script:fast) {
      $script:fast = Run-Clip @('list')
      $script:slow = Run-Clip @('list') -Direct
    }
    Expect ($script:fast.Out -ceq $script:slow.Out) ('proxy=' + $script:fast.Out.Trim() + ' direct=' + $script:slow.Out.Trim())
  }
  It 'a proxied status sees the resident' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    if (-not $script:up) { Expect $false 'the resident did not come up'; return }
    $o = Run-Clip @('status')
    Expect-Match $o.Out 'resident    : running' $o.Out.Trim()
  }
  # put carries its text in the request; the direct list then reads what the resident wrote
  It 'put through the pipe answers like put' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    if (-not $script:up) { Expect $false 'the resident did not come up'; return }
    $script:mark = 'proxy-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $o = Run-Clip @('put', $script:mark)
    Expect-Match $o.Out 'clipboard set' $o.Out.Trim()
  }
  It 'the row the resident wrote is in the store' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    if (-not $script:up) { Expect $false 'the resident did not come up'; return }
    $check = Run-Clip @('list') -Direct
    Expect-Match $check.Out ([regex]::Escape($script:mark)) $script:mark
  }
  # the entry reads stdin before it asks the resident, so the text travels as the value
  It 'put with stdin survives the pipe' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    if (-not $script:up) { Expect $false 'the resident did not come up'; return }
    $mark2 = 'proxy-stdin-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $o = ($mark2 | & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $clip put 2>&1 | Out-String)
    $check = Run-Clip @('list') -Direct
    Expect (($o -match 'clipboard set') -and ($check.Out -match [regex]::Escape($mark2))) $mark2
  }
  # config changes settings and is never proxied, but it has to keep working alongside
  It 'a direct-only command still runs' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    if (-not $script:up) { Expect $false 'the resident did not come up'; return }
    $o = Run-Clip @('config', 'get', 'Rows')
    Expect-Match $o.Out 'Rows' $o.Out.Trim()
  }
  # the pipe is per user, so a second copy of the tool finds the same pipe but names a different
  # root. It has to be refused and quietly run the command in its own process - a refusal that
  # printed nothing and exited would break every sandbox on the machine.
  It 'another root is refused and runs the command itself' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    if (-not $script:up) { Expect $false 'the resident did not come up'; return }
    $other = New-Sandbox 'proxy-other'
    $otherClip = Join-Path $other 'clipboard.ps1'
    $mark3 = 'other-root-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $otherArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $otherClip)
    $o = (& powershell @otherArgs put $mark3 2>&1 | Out-String)
    $o2 = (& powershell @otherArgs list 2>&1 | Out-String)
    Expect (($o -match 'clipboard set') -and ($o2 -match [regex]::Escape($mark3))) ($o.Trim() + ' / ' + $o2.Trim())
  }
  It 'clipboard.cmd answers through the compiled client' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    if (-not $script:up) { Expect $false 'the resident did not come up'; return }
    # The compiled client is what a user actually goes through: clipboard.cmd starts it before
    # any PowerShell exists, so a proxied command costs a native start. It is optional, so a
    # machine that cannot build one skips this instead of failing.
    $client = Get-ClientExe
    if (-not $client) { Skip-Test 'no compiler and no prebuilt client.exe'; return }
    Copy-Item -LiteralPath $client -Destination (Join-Path $dir 'client.exe') -Force
    Copy-Item -LiteralPath (Join-Path $script:Harness.SrcRoot 'clipboard.cmd') -Destination $dir -Force
    $script:line = '"' + (Join-Path $dir 'clipboard.cmd') + '" list'
    $o = (& cmd.exe '/c' $script:line 2>&1 | Out-String)
    Expect-Match $o 'proxy-' $o.Trim()
  }
  # and the same file without the exe keeps working: that is the fallback the batch file is
  # written around, not an error path
  It 'clipboard.cmd still answers without the exe' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    if (-not $script:up) { Expect $false 'the resident did not come up'; return }
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'clipboard.cmd'))) { Skip-Test 'the compiled client was not built here'; return }
    Remove-Item -LiteralPath (Join-Path $dir 'client.exe') -Force -ErrorAction SilentlyContinue
    $o = (& cmd.exe '/c' $script:line 2>&1 | Out-String)
    Expect-Match $o 'proxy-' $o.Trim()
  }
  # after the resident is gone the same command line has to work the slow way
  It 'falls back to a fresh process when the resident is gone' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    if (-not $script:up) { Expect $false 'the resident did not come up'; return }
    [void](Run-Clip @('stop'))
    $down = $false
    for ($i = 0; $i -lt 60 -and -not $down; $i++) {
      Start-Sleep -Milliseconds 250
      if ($script:child.HasExited) { $down = $true }
    }
    # the assertion below is about the fallback, not about how long a loaded machine takes to
    # shut a resident down: if it is still there, end it here
    if (-not $down) { try { $script:child.Kill(); $down = $true } catch { } }
    $o = Run-Clip @('list')
    Expect ($down -and $o.Out -match 'proxy-' -and $o.Ms -gt 0) ([string]$o.Ms + ' ms')
  }
}

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

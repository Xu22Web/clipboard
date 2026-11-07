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
  [switch]$Quiet,
  [switch]$ClipShared
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'lib\harness.ps1')
$script:Harness.Part = 'proxy'
Start-TestPart -Source $Source -ClipShared:$ClipShared
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

$clipBak = ''
try { $clipBak = (Get-Clipboard -Raw -ErrorAction Stop) } catch { }
$child = $null
try {
    if (-not (Test-MutexFree 'Local\clipboard.daemon')) {
      Skip 'e2e' 'resident answers on the pipe' 'a resident is already running - stop it first'
    }
    else {
      $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $clip, 'serve')
      $child = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argList -PassThru

      $up = $false
      for ($i = 0; $i -lt 80 -and -not $up; $i++) {
        Start-Sleep -Milliseconds 250
        if ((Read-TextSafe $log) -match 'serve start') { $up = $true }
      }
      Check 'e2e' 'resident answers on the pipe' $up ''

      if ($up) {
        # a first command warms nothing on the resident side: it is already warm by design
        $fast = Run-Clip @('list')
        $slow = Run-Clip @('list') -Direct
        # the pipe does not remove PowerShell's own start, so the honest claim is "faster than a
        # fresh process"; the numbers are printed either way so a regression is visible
        Check 'e2e' 'the proxied call is the faster one' ($fast.Ms -lt $slow.Ms) ('proxy ' + $fast.Ms + ' ms / direct ' + $slow.Ms + ' ms')
        Check 'e2e' 'a proxied answer matches the direct one' ($fast.Out -ceq $slow.Out) ('proxy=' + $fast.Out.Trim() + ' direct=' + $slow.Out.Trim())

        $o = Run-Clip @('status')
        Check 'e2e' 'a proxied status sees the resident' ($o.Out -match 'resident    : running') $o.Out.Trim()

        # put carries its text in the request; the direct list then reads what the resident wrote
        $mark = 'proxy-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $o = Run-Clip @('put', $mark)
        Check 'e2e' 'put through the pipe answers like put' ($o.Out -match 'clipboard set') $o.Out.Trim()
        $check = Run-Clip @('list') -Direct
        Check 'e2e' 'the row the resident wrote is in the store' ($check.Out -match [regex]::Escape($mark)) $mark

        # the entry reads stdin before it asks the resident, so the text travels as the value
        $mark2 = 'proxy-stdin-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $o = ($mark2 | & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $clip put 2>&1 | Out-String)
        $check = Run-Clip @('list') -Direct
        Check 'e2e' 'put with stdin survives the pipe' (($o -match 'clipboard set') -and ($check.Out -match [regex]::Escape($mark2))) $mark2

        # config changes settings and is never proxied, but it has to keep working alongside
        $o = Run-Clip @('config', 'get', 'Rows')
        Check 'e2e' 'a direct-only command still runs' ($o.Out -match 'Rows') $o.Out.Trim()

        # the pipe is per user, so a second copy of the tool finds the same pipe but names a
        # different root. It has to be refused and quietly run the command in its own process -
        # a refusal that printed nothing and exited would break every sandbox on the machine.
        $other = New-Sandbox 'proxy-other'
        $otherClip = Join-Path $other 'clipboard.ps1'
        $mark3 = 'other-root-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $otherArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $otherClip)
        $o = (& powershell @otherArgs put $mark3 2>&1 | Out-String)
        $o2 = (& powershell @otherArgs list 2>&1 | Out-String)
        Check 'e2e' 'another root is refused and runs the command itself' (($o -match 'clipboard set') -and ($o2 -match [regex]::Escape($mark3))) ($o.Trim() + ' / ' + $o2.Trim())
      }

      # after the resident is gone the same command line has to work the slow way
      [void](Run-Clip @('stop'))
      $down = $false
      for ($i = 0; $i -lt 60 -and -not $down; $i++) {
        Start-Sleep -Milliseconds 250
        if ($child.HasExited) { $down = $true }
      }
      # the assertion below is about the fallback, not about how long a loaded machine takes to
      # shut a resident down: if it is still there, end it here
      if (-not $down) { try { $child.Kill(); $down = $true } catch { } }
      $o = Run-Clip @('list')
      Check 'e2e' 'falls back to a fresh process when the resident is gone' ($down -and $o.Out -match 'proxy-' -and $o.Ms -gt 0) ([string]$o.Ms + ' ms')
    }
} catch {
  Check 'harness' 'run finished without an exception' $false $_.Exception.Message
} finally {
  if ($child -and -not $child.HasExited) { try { $child.Kill() } catch { } }
  if ($clipBak) { [void](Set-Clip $clipBak) } else { [void](Set-Clip '') }
}

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

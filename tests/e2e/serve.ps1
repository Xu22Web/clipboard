#Requires -Version 5.1
<#
  serve.ps1 - the end-to-end part: a real resident process, the real clipboard.

  Everything else runs in a sandbox with a fake clipboard (tests\lib\fake-clip.ps1). This part
  cannot: the point is the capture loop, the hotkey and the shutdown path, so it starts the
  program the way a user does and writes the machine clipboard. tests\run.ps1 runs it alone,
  after the parts that can run side by side.
#>
[CmdletBinding()]
param(
  [string]$Source = '',
  [string]$ResultFile = '',
  [string]$ProgressFile = '',
  [switch]$Quiet
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'lib\harness.ps1')
$script:Harness.Part = 'e2e'
Start-TestPart -Source $Source -Quiet:$Quiet -ProgressFile $ProgressFile
$e2eDir = New-Sandbox 'e2e'
# the resident keeps its log and store open while it runs, so a read can lose the race
function Read-TextSafe([string]$path) {
  try { if (Test-Path -LiteralPath $path) { return [IO.File]::ReadAllText($path) } } catch { }
  return ''
}
# the resident records whatever lands on the clipboard, so the machine clipboard is saved
# around the run and given back afterwards
$clipBak = ''
try { $clipBak = (Get-Clipboard -Raw -ErrorAction Stop) } catch { }
try {

    if (-not (Test-MutexFree 'Local\clipboard.daemon')) {
      Skip 'e2e' 'daemon lifecycle' 'a resident is already running - stop it first'
      Skip 'e2e' 'capture pipeline' 'a resident is already running - stop it first'
    }
    else {
      $child = $null
      $log = Join-Path $e2eDir 'data\clipboard.log'
      try {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', (Join-Path $e2eDir 'clipboard.ps1'), 'serve')
        $child = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argList -PassThru

        # wait on the log instead of polling `status`: reading a file is free, and every
        # `status` here would be another three second process
        $up = $false
        for ($i = 0; $i -lt 80 -and -not $up; $i++) {
          Start-Sleep -Milliseconds 250
          if ((Read-TextSafe $log) -match 'serve start') { $up = $true }
        }
        Check 'e2e' 'daemon starts' $up ''

        # one status, three answers
        $s = Clip $e2eDir @('status')
        Check 'e2e' 'resident reports running' ($s -match 'resident    : running') (@($s -split "`n" | Where-Object { $_ -match 'resident' }) -join '')
        Check 'e2e' 'hotkey registered' ($s -match 'active key  : Ctrl\+Alt\+V') (@($s -split "`n" | Where-Object { $_ -match 'active key' }) -join '')
        Check 'e2e' 'store lives in the sandbox' ($s -match [regex]::Escape((Join-Path $e2eDir 'data'))) ''

        # the resident polls the clipboard on its own clock, and this part shares the machine
        # with the command line parts: wait on the store file (free) instead of guessing a sleep
        $store = Join-Path $e2eDir 'data\history.dat'
        $marker = 'e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        [void](Set-Clip $marker)
        $seen = $false
        for ($i = 0; $i -lt 100 -and -not $seen; $i++) {
          Start-Sleep -Milliseconds 200
          if ((Read-TextSafe $store).Contains($marker)) { $seen = $true }
        }
        Check 'e2e' 'capture pipeline' ($seen -and ((Clip $e2eDir @('list', '-Count', '5')) -match [regex]::Escape($marker))) $marker

        # copy -> delete -> copy the same text again: it has to come back. The loop compares
        # clipboard sequence numbers, not payloads, so a text it saw before is not skipped.
        [void](Clip $e2eDir @('del', '1'))
        $gone = -not ((Clip $e2eDir @('list', '-Count', '5')) -match [regex]::Escape($marker))
        [void](Set-Clip $marker)
        $returned = $false
        for ($i = 0; $i -lt 50 -and -not $returned; $i++) {
          Start-Sleep -Milliseconds 200
          if ((Clip $e2eDir @('list', '-Count', '5')) -match [regex]::Escape($marker)) { $returned = $true }
        }
        Check 'e2e' 'a deleted entry comes back when it is copied again' ($gone -and $returned) ('gone=' + [string]$gone + ' back=' + [string]$returned)

        [void](Clip $e2eDir @('pause'))
        $marker2 = 'e2e-paused-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        [void](Set-Clip $marker2)
        # a pause means "nothing is written", so wait the same window and look for the marker
        # that must not be there
        $leaked = $false
        for ($i = 0; $i -lt 15 -and -not $leaked; $i++) {
          Start-Sleep -Milliseconds 200
          if ((Read-TextSafe $store).Contains($marker2)) { $leaked = $true }
        }
        Check 'e2e' 'pause stops capture' (-not $leaked) $marker2
        [void](Clip $e2eDir @('resume'))

        [void](Clip $e2eDir @('stop'))
        $down = $false
        for ($i = 0; $i -lt 80 -and -not $down; $i++) {
          Start-Sleep -Milliseconds 250
          if ($child.HasExited) { $down = $true }
          elseif ((Read-TextSafe $log) -match 'serve stop \(stop\)') { $down = $true }
        }
        Check 'e2e' 'daemon stops' ($down -and ((Clip $e2eDir @('status')) -match 'resident    : not running')) ''

        $logText = Read-TextSafe $log
        Check 'e2e' 'clean shutdown logged' (($logText -match 'serve stop \(stop\)') -and ($logText -match 'supervisor exit')) ''
        Check 'e2e' 'no restart loop' (-not ($logText -match 'serve restart #')) ''
      }
      finally {
        if ($child -and -not $child.HasExited) { try { $child.Kill() } catch { } }
      }
    }
} catch {
  Check 'harness' 'run finished without an exception' $false $_.Exception.Message
} finally {
  if ($clipBak) { [void](Set-Clip $clipBak) } else { [void](Set-Clip '') }
}

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

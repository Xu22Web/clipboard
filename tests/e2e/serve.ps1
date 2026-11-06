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
  [switch]$Quiet
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'lib\harness.ps1')
$script:Harness.Part = 'e2e'
Start-TestPart -Source $Source
$e2eDir = New-Sandbox 'e2e'
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
      try {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', (Join-Path $e2eDir 'clipboard.ps1'), 'serve')
        $child = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argList -PassThru

        $up = $false
        for ($i = 0; $i -lt 30 -and -not $up; $i++) {
          Start-Sleep -Milliseconds 500
          if ((Clip $e2eDir @('status')) -match 'resident    : running') { $up = $true }
        }
        Check 'e2e' 'daemon starts' $up ''

        $s = Clip $e2eDir @('status')
        Check 'e2e' 'hotkey registered' ($s -match 'active key  : Ctrl\+Alt\+V') (@($s -split "`n" | Where-Object { $_ -match 'active key' }) -join '')
        Check 'e2e' 'store lives in the sandbox' ($s -match [regex]::Escape((Join-Path $e2eDir 'data'))) ''

        $marker = 'e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        [void](Set-Clip $marker)
        Start-Sleep -Milliseconds 1600
        Check 'e2e' 'capture pipeline' ((Clip $e2eDir @('list', '-Count', '5')) -match [regex]::Escape($marker)) $marker

        [void](Clip $e2eDir @('pause'))
        $marker2 = 'e2e-paused-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        [void](Set-Clip $marker2)
        Start-Sleep -Milliseconds 1600
        Check 'e2e' 'pause stops capture' (-not ((Clip $e2eDir @('list', '-Count', '5')) -match [regex]::Escape($marker2))) $marker2
        [void](Clip $e2eDir @('resume'))

        [void](Clip $e2eDir @('stop'))
        $down = $false
        for ($i = 0; $i -lt 25 -and -not $down; $i++) {
          Start-Sleep -Milliseconds 400
          if ((Clip $e2eDir @('status')) -match 'resident    : not running') { $down = $true }
        }
        Check 'e2e' 'daemon stops' $down ''

        $log = Join-Path $e2eDir 'data\clipboard.log'
        $logText = if (Test-Path -LiteralPath $log) { [IO.File]::ReadAllText($log) } else { '' }
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

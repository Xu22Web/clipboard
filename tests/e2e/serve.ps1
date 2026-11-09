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

Describe 'e2e' {
  # The resident records whatever lands on the clipboard, so the machine clipboard is saved
  # around the whole block and given back when it ends.
  BeforeAll {
    $script:skipAll = ''
    $script:child = $null
    $script:up = $false
    $script:clipBak = ''
    $script:log = Join-Path $e2eDir 'data\clipboard.log'
    $script:store = Join-Path $e2eDir 'data\history.dat'
    try { $script:clipBak = (Get-Clipboard -Raw -ErrorAction Stop) } catch { $script:clipBak = '' }
    if (-not (Test-MutexFree 'Local\clipboard.daemon')) {
      $script:skipAll = 'a resident is already running - stop it first'
      return
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', (Join-Path $e2eDir 'clipboard.ps1'), 'serve')
    $script:child = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argList -PassThru
    # wait on the log instead of polling `status`: reading a file is free, and every `status`
    # here would be another three second process
    for ($i = 0; $i -lt 80 -and -not $script:up; $i++) {
      Start-Sleep -Milliseconds 250
      if ((Read-TextSafe $script:log) -match 'serve start') { $script:up = $true }
    }
  }

  AfterAll {
    if ($script:child -and -not $script:child.HasExited) { try { $script:child.Kill() } catch { } }
    if ($script:clipBak) { [void](Set-Clip $script:clipBak) } else { [void](Set-Clip '') }
  }

  It 'daemon starts' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    Expect $script:up 'the resident should log serve start while it comes up'
  }
  It 'resident reports running' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    $s = Clip $e2eDir @('status')
    Expect-Match $s 'resident    : running' (@($s -split "`n" | Where-Object { $_ -match 'resident' }) -join '')
  }
  It 'hotkey registered' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    $s = Clip $e2eDir @('status')
    Expect-Match $s 'active key  : Ctrl\+Alt\+V' (@($s -split "`n" | Where-Object { $_ -match 'active key' }) -join '')
  }
  It 'store lives in the sandbox' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    $s = Clip $e2eDir @('status')
    Expect-Match $s ([regex]::Escape((Join-Path $e2eDir 'data'))) 'the store has to stay inside the sandbox'
  }
  It 'capture pipeline' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    # the resident polls the clipboard on its own clock: wait on the store file (free) instead of
    # guessing a sleep
    $script:marker = 'e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    [void](Set-Clip $script:marker)
    $seen = $false
    for ($i = 0; $i -lt 100 -and -not $seen; $i++) {
      Start-Sleep -Milliseconds 200
      if ((Read-TextSafe $script:store).Contains($script:marker)) { $seen = $true }
    }
    Expect ($seen -and ((Clip $e2eDir @('list', '-Count', '5')) -match [regex]::Escape($script:marker))) $script:marker
  }
  # copy -> delete -> copy the same text again: it has to come back. The loop compares clipboard
  # sequence numbers, not payloads, so a text it saw before is not skipped.
  It 'a deleted entry comes back when it is copied again' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    [void](Clip $e2eDir @('del', '1'))
    $gone = -not ((Clip $e2eDir @('list', '-Count', '5')) -match [regex]::Escape($script:marker))
    [void](Set-Clip $script:marker)
    $returned = $false
    for ($i = 0; $i -lt 50 -and -not $returned; $i++) {
      Start-Sleep -Milliseconds 200
      if ((Clip $e2eDir @('list', '-Count', '5')) -match [regex]::Escape($script:marker)) { $returned = $true }
    }
    Expect ($gone -and $returned) ('gone=' + [string]$gone + ' back=' + [string]$returned)
  }
  It 'pause stops capture' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    [void](Clip $e2eDir @('pause'))
    $marker2 = 'e2e-paused-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    [void](Set-Clip $marker2)
    # a pause means "nothing is written", so wait the same window and look for the marker that
    # must not be there
    $leaked = $false
    for ($i = 0; $i -lt 15 -and -not $leaked; $i++) {
      Start-Sleep -Milliseconds 200
      if ((Read-TextSafe $script:store).Contains($marker2)) { $leaked = $true }
    }
    Expect (-not $leaked) $marker2
    [void](Clip $e2eDir @('resume'))
  }
  It 'daemon stops' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    [void](Clip $e2eDir @('stop'))
    $down = $false
    for ($i = 0; $i -lt 80 -and -not $down; $i++) {
      Start-Sleep -Milliseconds 250
      if ($script:child.HasExited) { $down = $true }
      elseif ((Read-TextSafe $script:log) -match 'serve stop \(stop\)') { $down = $true }
    }
    Expect ($down -and ((Clip $e2eDir @('status')) -match 'resident    : not running')) 'the resident should be gone after stop'
  }
  It 'clean shutdown logged' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    $logText = Read-TextSafe $script:log
    Expect (($logText -match 'serve stop \(stop\)') -and ($logText -match 'supervisor exit')) 'the log should record a clean shutdown'
  }
  It 'no restart loop' {
    if ($script:skipAll) { Skip-Test $script:skipAll; return }
    $logText = Read-TextSafe $script:log
    Expect (-not ($logText -match 'serve restart #')) 'the supervisor must not restart after a stop'
  }
}

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

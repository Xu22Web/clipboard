#Requires -Version 5.1
<#
  history.ps1 - the history verbs and the clipboard they read and write

  One part of the self tests: it runs alone, in its own process, with its own sandbox and its
  own clipboard (tests\lib\fake-clip.ps1). tests\run.ps1 starts several of these at once.

  One command per process on purpose: `-Media` and the plugin verbs are parsed from the real
  command line, and `& clipboard.ps1 ...` inside a warm process does not read the same way.
#>
[CmdletBinding()]
param(
  [string]$Source = '',
  [string]$ResultFile = '',
  [switch]$Quiet,
  # set by tests\run.ps1 when another part of the same run drives the real clipboard
  [switch]$ClipShared
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'lib\harness.ps1')
$script:Harness.Part = 'history'
Start-TestPart -Source $Source -ClipShared:$ClipShared
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'


    # A sandbox can carry its own clipboard (tests\lib\fake-clip.ps1), which is what lets the
    # suite run beside another copy of itself and keeps the user's clipboard out of it. The
    # checks below are the contract: the same commands, the same answers, and the machine's
    # clipboard untouched.
    $fakeDir = New-FakeSandbox 'fakeclip'
    $realBefore = ''
    try { $realBefore = [string](Get-Clipboard -Raw -ErrorAction Stop) } catch { $realBefore = '' }
    $o = Clip $fakeDir @('put', 'fake-one')
    Check 'int' 'a sandbox can carry its own clipboard' ($o -match 'clipboard set') $o.Trim()
    $o = Clip $fakeDir @('get')
    Check 'int' 'the fake clipboard reads back' ($o -match 'fake-one') $o.Trim()
    $o = Clip $fakeDir @('list')
    Check 'int' 'a capture from the fake clipboard is stored' ($o -match 'fake-one') $o.Trim()
    $o = Clip $fakeDir @('pick', '1')
    Check 'int' 'picking writes the fake clipboard' (($o -match 'clipboard set') -or ($o -match 'picked')) $o.Trim()
    $o = Clip $fakeDir @('get')
    Check 'int' 'the picked entry comes back through the fake clipboard' ($o -match 'fake-one') $o.Trim()
    $realAfter = ''
    try { $realAfter = [string](Get-Clipboard -Raw -ErrorAction Stop) } catch { $realAfter = '' }
    # a packaged copy runs on the real clipboard, so there is nothing to compare against; and
    # when the end-to-end part is part of this run it writes the machine clipboard on purpose
    if ($script:Harness.IsPackaged) {
      Skip 'int' 'the machine clipboard is never touched' 'packaged copy: real clipboard'
    } elseif ($script:clipShared) {
      Skip 'int' 'the machine clipboard is never touched' 'the end-to-end part is driving it too'
    } else {
      Check 'int' 'the machine clipboard is never touched' ($realBefore -ceq $realAfter) ('before=' + $realBefore.Length + ' after=' + $realAfter.Length)
    }

    # the state is reported exactly when there is something to report, so a machine where
    # Win+V works keeps a clean status
    $o = Clip $intDir @('status')
    $winv = ''
    if (Get-Command Get-WinVState -ErrorAction SilentlyContinue) { $winv = Get-WinVState }
    $hasLine = [bool]($o -match 'win\+v')
    Check 'int' 'status states the win+v state only when it is not usable' ($hasLine -eq [bool]$winv) ([string]$winv + ' / printed=' + [string]$hasLine)

    $o = Clip $intDir @('config')
    Check 'int' 'config shows ini path' ($o -match 'clipboard\.ini') ''

    $o = Clip $intDir @('put', 'itest-alpha')
    Check 'int' 'put' ($o -match 'clipboard set') $o.Trim()

    $o = Clip $intDir @('get')
    Check 'int' 'get' ($o -match 'itest-alpha') $o.Trim()

    $o = Clip $intDir @('list', '-Count', '5')
    Check 'int' 'list' ($o -match 'itest-alpha') ''

    $o = Clip $intDir @('pick', '1')
    Check 'int' 'pick' ($o -match 'clipboard set') $o.Trim()
    $o = Clip $intDir @('get')
    Check 'int' 'pick sets clipboard' ($o -match 'itest-alpha') ''

    $o = Clip $intDir @('del', '1')
    Check 'int' 'del' ($o -match 'deleted') $o.Trim()

    $o = Clip $intDir @('clear')
    Check 'int' 'clear' ($o -match 'history cleared') ''
    $o = Clip $intDir @('list')
    Check 'int' 'list empty after clear' ($o -match 'history is empty') ''

    [void](Clip $intDir @('put', 'stdin-like-value'))
    $o = Clip $intDir @('del', '9')
    Check 'int' 'del out of range' ($o -match 'index out of range') $o.Trim()

    $o = Clip $intDir @('pick', 'x')
    Check 'int' 'pick bad arg' ($o -match 'usage: clipboard pick') $o.Trim()

    $o = Clip $intDir @('nosuchcommand')
    Check 'int' 'unknown command' ($o -match 'unknown command') ''

    $o = Clip $intDir @('pause')
    $s = Clip $intDir @('status')
    Check 'int' 'pause' (($o -match 'paused') -and ($s -match 'capture     : paused')) ''
    [void](Clip $intDir @('resume'))
    $s = Clip $intDir @('status')
    Check 'int' 'resume' ($s -match 'capture     : active') ''

    $o = Clip $intDir @('status')
    Check 'int' 'status fields' (($o -match 'autostart   :') -and ($o -match 'desktop     :') -and ($o -match 'store file')) ''


Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

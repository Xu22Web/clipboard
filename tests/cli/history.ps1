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
  [string]$ProgressFile = '',
  [switch]$Quiet,
  # set by tests\run.ps1 when another part of the same run drives the real clipboard
  [switch]$ClipShared
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'lib\harness.ps1')
$script:Harness.Part = 'history'
Start-TestPart -Source $Source -ClipShared:$ClipShared -Quiet:$Quiet -ProgressFile $ProgressFile
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'
$cli = Start-CliRunner $intDir
function Run([string[]]$cliArgs, [switch]$Cold) { return (Invoke-CliRunner $cli $cliArgs -Cold:$Cold) }


    # A sandbox can carry its own clipboard (tests\lib\fake-clip.ps1), which is what lets the
    # suite run beside another copy of itself and keeps the user's clipboard out of it. The
    # checks below are the contract: the same commands, the same answers, and the machine's
    # clipboard untouched.
    $fakeDir = New-FakeSandbox 'fakeclip'
    $fakeCli = Start-CliRunner $fakeDir
    function RunFake([string[]]$cliArgs, [switch]$Cold) { return (Invoke-CliRunner $fakeCli $cliArgs -Cold:$Cold) }
    $realBefore = ''
    try { $realBefore = [string](Get-Clipboard -Raw -ErrorAction Stop) } catch { $realBefore = '' }
    $o = RunFake @('put', 'fake-one')
    Check 'int' 'a sandbox can carry its own clipboard' ($o -match 'clipboard set') $o.Trim()
    $o = RunFake @('get')
    Check 'int' 'the fake clipboard reads back' ($o -match 'fake-one') $o.Trim()
    $o = RunFake @('list') -Cold
    Check 'int' 'a capture from the fake clipboard is stored' ($o -match 'fake-one') $o.Trim()
    $o = RunFake @('pick', '1') -Cold
    Check 'int' 'picking writes the fake clipboard' (($o -match 'clipboard set') -or ($o -match 'picked')) $o.Trim()
    $o = RunFake @('get')
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
    # Win+V works keeps a clean status. The probe lives in the product module, which this
    # process never loads: without it the expected value would be '' and the check would only
    # ever pass where Win+V happens to work - a runner without the shell service failed here.
    $o = Run @('status') -Cold
    if (-not (Get-Command Get-WinVState -ErrorAction SilentlyContinue)) {
      $nativeFile = Join-Path $script:srcRoot 'lib\native.ps1'
      if (Test-Path -LiteralPath $nativeFile) { . $nativeFile }
    }
    $hasLine = [bool]($o -match 'win\+v')
    if (Get-Command Get-WinVState -ErrorAction SilentlyContinue) {
      $winv = [string](Get-WinVState)
      Check 'int' 'status states the win+v state only when it is not usable' ($hasLine -eq [bool]$winv) ([string]$winv + ' / printed=' + [string]$hasLine)
    } else {
      # nothing to compare against: say so instead of asserting a value nobody computed
      Skip 'int' 'status states the win+v state only when it is not usable' 'the probe module is not loadable here'
    }

    $o = Run @('config')
    Check 'int' 'config shows ini path' ($o -match 'clipboard\.ini') ''

    $o = Run @('put', 'itest-alpha')
    Check 'int' 'put' ($o -match 'clipboard set') $o.Trim()

    $o = Run @('get')
    Check 'int' 'get' ($o -match 'itest-alpha') $o.Trim()

    $o = Run @('list', '-Count', '5') -Cold
    Check 'int' 'list' ($o -match 'itest-alpha') ''

    $o = Run @('pick', '1') -Cold
    Check 'int' 'pick' ($o -match 'clipboard set') $o.Trim()
    $o = Run @('get')
    Check 'int' 'pick sets clipboard' ($o -match 'itest-alpha') ''

    $o = Run @('del', '1')
    Check 'int' 'del' ($o -match 'deleted') $o.Trim()

    $o = Run @('clear')
    Check 'int' 'clear' ($o -match 'history cleared') ''
    $o = Run @('list') -Cold
    Check 'int' 'list empty after clear' ($o -match 'history is empty') ''

    [void](Run @('put', 'stdin-like-value'))
    $o = Run @('del', '9')
    Check 'int' 'del out of range' ($o -match 'index out of range') $o.Trim()

    $o = Run @('pick', 'x') -Cold
    Check 'int' 'pick bad arg' ($o -match 'usage: clipboard pick') $o.Trim()

    $o = Run @('nosuchcommand')
    Check 'int' 'unknown command' ($o -match 'unknown command') ''

    $o = Run @('pause')
    $s = Run @('status')
    Check 'int' 'pause' (($o -match 'paused') -and ($s -match 'capture     : paused')) ''
    [void](Run @('resume'))
    $s = Run @('status')
    Check 'int' 'resume' ($s -match 'capture     : active') ''

    $o = Run @('status')
    Check 'int' 'status fields' (($o -match 'autostart   :') -and ($o -match 'desktop     :') -and ($o -match 'store file')) ''


Stop-CliRunner $cli
Stop-CliRunner $fakeCli
Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

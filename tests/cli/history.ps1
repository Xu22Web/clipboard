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
# suite run beside another copy of itself and keeps the user's clipboard out of it.
$fakeDir = New-FakeSandbox 'fakeclip'
$fakeCli = Start-CliRunner $fakeDir
function RunFake([string[]]$cliArgs, [switch]$Cold) { return (Invoke-CliRunner $fakeCli $cliArgs -Cold:$Cold) }

# The state probe lives in the product module, which this process never loads: loading it here
# keeps the win+v row comparable whether or not the module is otherwise in use.
if (-not (Get-Command Get-WinVState -ErrorAction SilentlyContinue)) {
  $nativeFile = Join-Path $script:srcRoot 'lib\native.ps1'
  if (Test-Path -LiteralPath $nativeFile) { . $nativeFile }
}

Describe 'int' {
  AfterAll {
    Stop-CliRunner $cli
    Stop-CliRunner $fakeCli
  }

  # the same commands, the same answers, and the machine's clipboard untouched
  Describe 'fake clipboard' {
    BeforeAll {
      $script:realBefore = ''
      try { $script:realBefore = [string](Get-Clipboard -Raw -ErrorAction Stop) } catch { $script:realBefore = '' }
    }
    It 'a sandbox can carry its own clipboard' {
      $o = RunFake @('put', 'fake-one')
      Expect-Match $o 'clipboard set' $o.Trim()
    }
    It 'the fake clipboard reads back' {
      $o = RunFake @('get')
      Expect-Match $o 'fake-one' $o.Trim()
    }
    It 'a capture from the fake clipboard is stored' {
      $o = RunFake @('list') -Cold
      Expect-Match $o 'fake-one' $o.Trim()
    }
    It 'picking writes the fake clipboard' {
      $o = RunFake @('pick', '1') -Cold
      Expect (($o -match 'clipboard set') -or ($o -match 'picked')) $o.Trim()
    }
    It 'the picked entry comes back through the fake clipboard' {
      $o = RunFake @('get')
      Expect-Match $o 'fake-one' $o.Trim()
    }
    # a packaged copy runs on the real clipboard, so there is nothing to compare against; and
    # when the end-to-end part is part of this run it writes the machine clipboard on purpose
    if ($script:Harness.IsPackaged) {
      It 'the machine clipboard is never touched' { } -Skip 'packaged copy: real clipboard'
    } elseif ($script:clipShared) {
      It 'the machine clipboard is never touched' { } -Skip 'the end-to-end part is driving it too'
    } else {
      It 'the machine clipboard is never touched' {
        $realAfter = ''
        try { $realAfter = [string](Get-Clipboard -Raw -ErrorAction Stop) } catch { $realAfter = '' }
        Expect ($script:realBefore -ceq $realAfter) ('before=' + $script:realBefore.Length + ' after=' + $realAfter.Length)
      }
    }
  }

  # the state is reported exactly when there is something to report, so a machine where Win+V
  # works keeps a clean status
  Describe 'win+v state' {
    It 'status states the win+v state only when it is not usable' {
      $o = Run @('status') -Cold
      $hasLine = [bool]($o -match 'win\+v')
      $winv = [string](Get-WinVState)
      Expect ($hasLine -eq [bool]$winv) ([string]$winv + ' / printed=' + [string]$hasLine)
    }
  }

  Describe 'commands' {
    It 'config shows ini path' {
      $o = Run @('config')
      Expect-Match $o 'clipboard\.ini' 'config should print where the ini lives'
    }
    It 'put' {
      $o = Run @('put', 'itest-alpha')
      Expect-Match $o 'clipboard set' $o.Trim()
    }
    It 'get' {
      $o = Run @('get')
      Expect-Match $o 'itest-alpha' $o.Trim()
    }
    It 'list' {
      $o = Run @('list', '-Count', '5') -Cold
      Expect-Match $o 'itest-alpha' 'list should show the entry just put'
    }
    It 'pick' {
      $o = Run @('pick', '1') -Cold
      Expect-Match $o 'clipboard set' $o.Trim()
    }
    It 'pick sets clipboard' {
      $o = Run @('get')
      Expect-Match $o 'itest-alpha' 'the picked entry should be on the clipboard'
    }
    It 'del' {
      $o = Run @('del', '1')
      Expect-Match $o 'deleted' $o.Trim()
    }
    It 'clear' {
      $o = Run @('clear')
      Expect-Match $o 'history cleared' 'clear should report the emptied history'
    }
    It 'list empty after clear' {
      $o = Run @('list') -Cold
      Expect-Match $o 'history is empty' $o.Trim()
    }
    It 'del out of range' {
      [void](Run @('put', 'stdin-like-value'))
      $o = Run @('del', '9')
      Expect-Match $o 'index out of range' $o.Trim()
    }
    It 'pick bad arg' {
      $o = Run @('pick', 'x') -Cold
      Expect-Match $o 'usage: clipboard pick' $o.Trim()
    }
    It 'unknown command' {
      $o = Run @('nosuchcommand')
      Expect-Match $o 'unknown command' 'an unknown verb should fall back to the usage text'
    }
    It 'pause' {
      $o = Run @('pause')
      $s = Run @('status')
      Expect (($o -match 'paused') -and ($s -match 'capture     : paused')) 'pause should be visible in status'
      [void](Run @('resume'))
    }
    It 'resume' {
      $s = Run @('status')
      Expect-Match $s 'capture     : active' 'resume should restore the active capture state'
    }
    It 'status fields' {
      $o = Run @('status')
      Expect (($o -match 'autostart   :') -and ($o -match 'desktop     :') -and ($o -match 'store file')) 'status should keep its field names'
    }
  }
}

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

#Requires -Version 5.1
<#
  transfer.ps1 - the history leaves and comes back: export, import, backup, restore, migrate, cli entry

  One part of the self tests: it runs alone, in its own process, with its own sandbox and its
  own clipboard (tests\lib\fake-clip.ps1). tests\run.ps1 starts several of these at once.
#>
[CmdletBinding()]
param(
  [string]$Source = '',
  [string]$ResultFile = '',
  [switch]$Quiet
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'lib\harness.ps1')
$script:Harness.Part = 'transfer'
Start-TestPart -Source $Source
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
    # a packaged copy runs on the real clipboard, so there is nothing to compare against
    if ($script:Harness.IsPackaged) {
      Skip 'int' 'the machine clipboard is never touched' 'packaged copy: real clipboard'
    } else {
      Check 'int' 'the machine clipboard is never touched' ($realBefore -ceq $realAfter) ('before=' + $realBefore.Length + ' after=' + $realAfter.Length)
    }

    $o = Clip $intDir @('help')
    Check 'int' 'help' ($o -match 'Usage: clipboard') ''

    $o = Clip $intDir @('version')
    Check 'int' 'version prints the program and data version' ($o -match ('clipboard ' + [regex]::Escape($programVersion) + '\s+data v\d+')) $o.Trim()

    $o = Clip $intDir @('migrate')
    Check 'int' 'migrate reports a store it does not need to touch' ($o -match 'nothing to migrate|migrated') $o.Trim()

    # export / import / backup, through the command line the user actually types
    $jsonOut = Join-Path $intDir 'history-export.json'
    [void](Clip $intDir @('put', 'export round trip'))
    $o = Clip $intDir @('export', $jsonOut)
    Check 'int' 'export writes a json file' ((Test-Path -LiteralPath $jsonOut) -and ($o -match 'exported')) $o.Trim()
    $o = Clip $intDir @('export', (Join-Path $intDir 'history-export.csv'))
    Check 'int' 'export writes a csv file' ($o -match 'exported') $o.Trim()
    $notes = Join-Path $intDir 'note.txt'
    $o = Clip $intDir @('export', $notes, '-Media')
    Check 'int' 'export refuses -Media for a format that cannot carry pictures' ($o -match 'needs a .json') $o.Trim()
    $o = Clip $intDir @('import', $jsonOut)
    Check 'int' 'import reports what it did' ($o -match 'imported|already there') $o.Trim()
    $o = Clip $intDir @('backup', 'unit')
    Check 'int' 'backup writes a snapshot' ($o -match 'backup written') $o.Trim()
    $o = Clip $intDir @('restore', 'nosuchsnapshot')
    Check 'int' 'restore refuses an unknown snapshot' ($o -match 'no snapshot matches') $o.Trim()

    # cli reads package.ini and runs the command line it finds there
    $cli = Join-Path $repoRoot 'cli.ps1'
    if (Test-Path -LiteralPath $cli) {
      $o = (& powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $cli 2>&1 | Out-String)
      Check 'int' 'cli lists the declared commands' (($o -match '\bdev\b') -and ($o -match '\bbuild\b') -and ($o -match '\btest\b') -and ($o -match '\bshot\b')) $o.Trim()
      $o = (& powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $cli 'nosuchcmd' 2>&1 | Out-String)
      Check 'int' 'cli reports an unknown command' (($o -match 'unknown command') -and ($o -match '\bdev\b')) $o.Trim()
      $o = (& powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $cli 'dev' 'nosuch' 2>&1 | Out-String)
      Check 'int' 'cli runs a script through its command line' ($o -match 'dev always watches') $o.Trim()
    } else {
      Check 'int' 'cli lists the declared commands' $false 'no cli.ps1'
    }

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

    $o = Clip $intDir @('put', 'stdin-like-value')
    $o = Clip $intDir @('del', '9')
    Check 'int' 'del out of range' ($o -match 'index out of range') $o.Trim()

    $o = Clip $intDir @('pick', 'x')
    Check 'int' 'pick bad arg' ($o -match 'usage: clipboard pick') $o.Trim()

    $o = Clip $intDir @('nosuchcommand')
    Check 'int' 'unknown command' ($o -match 'unknown command') ''

    $o = Clip $intDir @('pause')
    $s = Clip $intDir @('status')
    Check 'int' 'pause' (($o -match 'paused') -and ($s -match 'capture     : paused')) ''
    $o = Clip $intDir @('resume')
    $s = Clip $intDir @('status')
    Check 'int' 'resume' ($s -match 'capture     : active') ''

    $o = Clip $intDir @('status')
    Check 'int' 'status fields' (($o -match 'autostart   :') -and ($o -match 'desktop     :') -and ($o -match 'store file')) ''


Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

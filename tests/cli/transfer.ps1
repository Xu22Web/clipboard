#Requires -Version 5.1
<#
  transfer.ps1 - the history leaves and comes back: export, import, backup, restore, migrate,
  plus the command names that are gone and the repo's own cli

  One part of the self tests: it runs alone, in its own process, with its own sandbox and its
  own clipboard (tests\lib\fake-clip.ps1). tests\run.ps1 starts several of these at once.
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
$script:Harness.Part = 'transfer'
Start-TestPart -Source $Source -ClipShared:$ClipShared
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'


    # diag and the native Win+V restore are gone: an old command name falls through to the
    # usage text instead of doing something
    $o = Clip $intDir @('diag')
    Check 'int' 'removed commands fall back to usage' ($o -match 'unknown command: diag') $o.Trim()
    $o = Clip $intDir @('restore-data')
    Check 'int' 'restore-data is not a command any more' ($o -match 'unknown command: restore-data') $o.Trim()

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
    $o = Clip $intDir @('export', (Join-Path $intDir 'note.txt'), '-Media')
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


Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

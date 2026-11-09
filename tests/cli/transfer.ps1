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
  [string]$ProgressFile = '',
  [switch]$Quiet,
  # set by tests\run.ps1 when another part of the same run drives the real clipboard
  [switch]$ClipShared
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'lib\harness.ps1')
$script:Harness.Part = 'transfer'
Start-TestPart -Source $Source -ClipShared:$ClipShared -Quiet:$Quiet -ProgressFile $ProgressFile
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'
$runner = Start-CliRunner $intDir
function Run([string[]]$cliArgs, [switch]$Cold) { return (Invoke-CliRunner $runner $cliArgs -Cold:$Cold) }
# defined outside the blocks: a variable made inside a Describe is gone by the time its rows run
$cliPath = Join-Path $repoRoot 'cli.ps1'


Describe 'int' {
  AfterAll { Stop-CliRunner $runner }

  # diag and the native Win+V restore are gone: an old command name falls through to the
  # usage text instead of doing something
  It 'removed commands fall back to usage' {
    $o = Run @('diag')
    Expect-Match $o 'unknown command: diag' $o.Trim()
  }
  It 'restore-data is not a command any more' {
    $o = Run @('restore-data')
    Expect-Match $o 'unknown command: restore-data' $o.Trim()
  }
  It 'help' {
    $o = Run @('help')
    Expect-Match $o 'Usage: clipboard' 'help should print the usage line'
  }
  It 'version prints the program and data version' {
    $o = Run @('version')
    Expect-Match $o ('clipboard ' + [regex]::Escape($programVersion) + '\s+data v\d+') $o.Trim()
  }
  It 'migrate reports a store it does not need to touch' {
    $o = Run @('migrate')
    Expect-Match $o 'nothing to migrate|migrated' $o.Trim()
  }

  # export / import / backup, through the command line the user actually types
  Describe 'export and restore' {
    BeforeAll {
      $script:jsonOut = Join-Path $intDir 'history-export.json'
      [void](Run @('put', 'export round trip'))
    }
    It 'export writes a json file' {
      $o = Run @('export', $script:jsonOut)
      Expect ((Test-Path -LiteralPath $script:jsonOut) -and ($o -match 'exported')) $o.Trim()
    }
    It 'export writes a csv file' {
      $o = Run @('export', (Join-Path $intDir 'history-export.csv'))
      Expect-Match $o 'exported' $o.Trim()
    }
    It 'export refuses -Media for a format that cannot carry pictures' {
      $o = Run @('export', (Join-Path $intDir 'note.txt'), '-Media')
      Expect-Match $o 'needs a .json' $o.Trim()
    }
    It 'import reports what it did' {
      $o = Run @('import', $script:jsonOut)
      Expect-Match $o 'imported|already there' $o.Trim()
    }
    It 'backup writes a snapshot' {
      $o = Run @('backup', 'unit')
      Expect-Match $o 'backup written' $o.Trim()
    }
    It 'restore refuses an unknown snapshot' {
      $o = Run @('restore', 'nosuchsnapshot')
      Expect-Match $o 'no snapshot matches' $o.Trim()
    }
  }

  # cli reads package.ini and runs the command line it finds there
  if (Test-Path -LiteralPath $cliPath) {
    Describe 'the repo cli' {
      It 'cli lists the declared commands' {
        $o = (& powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $cliPath 2>&1 | Out-String)
        Expect (($o -match '\bdev\b') -and ($o -match '\bbuild\b') -and ($o -match '\btest\b') -and ($o -match '\bshot\b')) $o.Trim()
      }
      It 'cli reports an unknown command' {
        $o = (& powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $cliPath 'nosuchcmd' 2>&1 | Out-String)
        Expect (($o -match 'unknown command') -and ($o -match '\bdev\b')) $o.Trim()
      }
      It 'cli runs a script through its command line' {
        $o = (& powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $cliPath 'dev' 'nosuch' 2>&1 | Out-String)
        Expect-Match $o 'dev always watches' $o.Trim()
      }
    }
  } else {
    It 'cli lists the declared commands' { Expect $false 'no cli.ps1' }
  }
}

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

#Requires -Version 5.1
<#
  marks.ps1 - the two marks the item-marks plugin puts on an entry: star and highlight

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
$script:Harness.Part = 'marks'
Start-TestPart -Source $Source -ClipShared:$ClipShared -Quiet:$Quiet -ProgressFile $ProgressFile
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'
$cli = Start-CliRunner $intDir
# the mark verbs run a plugin script block, which needs a real process; the store verbs do not
function Run([string[]]$cliArgs, [switch]$Cold) { return (Invoke-CliRunner $cli $cliArgs -Cold:$Cold) }


Describe 'int' {
  # the runner belongs to this block: it is stopped even when a row inside fails or throws
  AfterAll { Stop-CliRunner $cli }

  Describe 'starring' {
    # every row is collected before any of them runs, so the setup is a hook rather than a
    # statement: a statement here would run while the rows are still being counted
    BeforeAll {
      [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks'), $Utf8)
      [void](Run @('clear', '-All'))
      [void](Run @('put', 'star-alpha'))
      [void](Run @('put', 'star-beta'))
    }

    It 'star command' {
      Expect-HasAssertions
      $o = Run @('star', '1') -Cold
      Expect-Match $o 'starred:' $o.Trim()
    }
    It 'status counts starred' {
      $o = Run @('status')
      Expect-Match $o '1 starred' $o.Trim()
    }
    It 'starred entry cannot be deleted' {
      $o = Run @('del', '1')
      Expect-Match $o 'starred entry, unstar it first' $o.Trim()
    }
    It 'clear keeps starred' {
      $o = Run @('clear', '-All')
      Expect (($o -match '1 starred kept') -and ((Run @('list') -Cold) -match 'star-beta')) $o.Trim()
    }
    It 'unstar command' {
      $o = Run @('unstar', '1') -Cold
      Expect-Match $o 'unstarred:' $o.Trim()
    }
    It 'delete works after unstar' {
      $o = Run @('del', '1')
      Expect-Match $o 'deleted:' $o.Trim()
    }
  }

  Describe 'highlight' {
    BeforeAll { [void](Run @('put', 'mark-gamma')) }

    It 'highlight command' {
      $o = Run @('highlight', '1') -Cold
      Expect-Match $o 'highlighted:' $o.Trim()
    }
    It 'highlight is repeatable-safe' {
      $o = Run @('highlight', '1') -Cold
      Expect-Match $o 'already highlighted' $o.Trim()
    }
    It 'unhighlight command' {
      $o = Run @('unhighlight', '1') -Cold
      Expect-Match $o 'highlight cleared:' $o.Trim()
    }
    It 'unhighlight reports the empty state' {
      $o = Run @('unhighlight', '1') -Cold
      Expect-Match $o 'not highlighted' $o.Trim()
    }
  }
}

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

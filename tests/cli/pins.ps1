#Requires -Version 5.1
<#
  pins.ps1 - pinned entries: the cap on the frozen block, and what the pin count reports

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
$script:Harness.Part = 'pins'
Start-TestPart -Source $Source -ClipShared:$ClipShared -Quiet:$Quiet -ProgressFile $ProgressFile
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'
$cli = Start-CliRunner $intDir
# pin and list run a plugin script block, which needs a real process; the store verbs do not
function Run([string[]]$cliArgs, [switch]$Cold) { return (Invoke-CliRunner $cli $cliArgs -Cold:$Cold) }


Describe 'int' {
  AfterAll {
    Stop-CliRunner $cli
    Remove-Item -LiteralPath $cfg2 -Force -ErrorAction SilentlyContinue
  }

  # pin / unpin / clear / status  (pin is a verb of the item-marks plugin)
  Describe 'pin verbs' {
    BeforeAll {
      [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks'), $Utf8)
      [void](Run @('clear', '-All'))
      [void](Run @('put', 'pin-me'))
      [void](Run @('put', 'other-one'))
    }
    It 'pin' {
      $o = Run @('pin', '2') -Cold
      Expect-Match $o 'pinned' $o.Trim()
    }
    It 'pin floats to the top' {
      $o = Run @('list') -Cold
      $pinLine = @($o -split "`n" | Where-Object { $_ -match 'pin-me' })
      Expect ($pinLine.Count -gt 0 -and $pinLine[0] -match '\*') $o.Trim()
    }
    It 'status shows the pin count' {
      $o = Run @('status')
      Expect-Match $o '1 pinned' $o.Trim()
    }
    It 'clear keeps the pin mark' {
      $o = Run @('clear')
      Expect ((($o -match 'kept by marks')) -and ((Run @('list') -Cold) -match 'pin-me')) $o.Trim()
    }
    It 'clear -All drops the pin mark' {
      $o = Run @('clear', '-All')
      Expect-Match $o 'history cleared' $o.Trim()
    }
    It 'list empty after clear -All' {
      $o = Run @('list') -Cold
      Expect-Match $o 'history is empty' $o.Trim()
    }
  }

  # with sticky pins on, the frozen block may never fill the list: the third pin is
  # refused instead of pushing the rows below out of reach
  Describe 'sticky pin cap' {
    AfterAll {
      [void](Run @('clear', '-All'))
      [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks'), $Utf8)
    }
    BeforeAll {
      [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks', 'item-marks.StickyPins=1', 'item-marks.StickyRows=2'), $Utf8)
      [void](Run @('clear', '-All'))
      [void](Run @('put', 'cap-one'))
      [void](Run @('put', 'cap-two'))
      [void](Run @('put', 'cap-three'))
    }
    It 'pin fits under the sticky cap' {
      $o = Run @('pin', '1') -Cold
      Expect-Match $o 'pinned' $o.Trim()
    }
    It 'pin refused when the sticky cap is full' {
      [void](Run @('pin', '2') -Cold)
      $o = Run @('pin', '3') -Cold
      Expect (($o -match '\[!\]') -and ($o -match 'unpin one first') -and ($o -match 'raise Rows')) $o.Trim()
    }
    It 'refused pin leaves the row unmarked' {
      $o = Run @('list') -Cold
      $capLine = @($o -split "`n" | Where-Object { $_ -match 'cap-one' })
      Expect ($capLine.Count -gt 0 -and $capLine[0] -notmatch '\*') ($capLine -join '/')
    }
    It 'no cap while sticky pins are off' {
      # turning the feature off drops the cap, so the same pin goes through
      [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks', 'item-marks.StickyPins=0', 'item-marks.StickyRows=2'), $Utf8)
      $o = Run @('pin', '3') -Cold
      Expect-Match $o 'pinned' $o.Trim()
    }
  }
}

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

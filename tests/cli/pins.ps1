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


    # pin / unpin / clear / status  (pin is a verb of the item-marks plugin)
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks'), $Utf8)
    [void](Run @('clear', '-All'))
    [void](Run @('put', 'pin-me'))
    [void](Run @('put', 'other-one'))
    $o = Run @('pin', '2') -Cold
    Check 'int' 'pin' ($o -match 'pinned') $o.Trim()
    $o = Run @('list') -Cold
    $pinLine = @($o -split "`n" | Where-Object { $_ -match 'pin-me' })
    Check 'int' 'pin floats to the top' ($pinLine.Count -gt 0 -and $pinLine[0] -match '\*') $o.Trim()
    $o = Run @('status')
    Check 'int' 'status shows the pin count' ($o -match '1 pinned') $o.Trim()
    $o = Run @('clear')
    Check 'int' 'clear keeps the pin mark' ((($o -match 'kept by marks')) -and ((Run @('list') -Cold) -match 'pin-me')) $o.Trim()
    $o = Run @('clear', '-All')
    Check 'int' 'clear -All drops the pin mark' (($o -match 'history cleared')) $o.Trim()
    $o = Run @('list') -Cold
    Check 'int' 'list empty after clear -All' ($o -match 'history is empty') $o.Trim()

    # with sticky pins on, the frozen block may never fill the list: the third pin is
    # refused instead of pushing the rows below out of reach
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks', 'item-marks.StickyPins=1', 'item-marks.StickyRows=2'), $Utf8)
    [void](Run @('clear', '-All'))
    [void](Run @('put', 'cap-one'))
    [void](Run @('put', 'cap-two'))
    [void](Run @('put', 'cap-three'))
    $o = Run @('pin', '1') -Cold
    Check 'int' 'pin fits under the sticky cap' ($o -match 'pinned') $o.Trim()
    [void](Run @('pin', '2') -Cold)
    $o = Run @('pin', '3') -Cold
    Check 'int' 'pin refused when the sticky cap is full' (($o -match '\[!\]') -and ($o -match 'unpin one first') -and ($o -match 'raise Rows')) $o.Trim()
    $o = Run @('list') -Cold
    $capLine = @($o -split "`n" | Where-Object { $_ -match 'cap-one' })
    Check 'int' 'refused pin leaves the row unmarked' ($capLine.Count -gt 0 -and $capLine[0] -notmatch '\*') ($capLine -join '/')
    # turning the feature off drops the cap, so the same pin goes through
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks', 'item-marks.StickyPins=0', 'item-marks.StickyRows=2'), $Utf8)
    $o = Run @('pin', '3') -Cold
    Check 'int' 'no cap while sticky pins are off' ($o -match 'pinned') $o.Trim()
    [void](Run @('clear', '-All'))
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks'), $Utf8)


Stop-CliRunner $cli
Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

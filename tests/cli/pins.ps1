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
  [switch]$Quiet,
  # set by tests\run.ps1 when another part of the same run drives the real clipboard
  [switch]$ClipShared
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'lib\harness.ps1')
$script:Harness.Part = 'pins'
Start-TestPart -Source $Source -ClipShared:$ClipShared
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'


    # pin / unpin / clear / status  (pin is a verb of the item-marks plugin)
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks'), $Utf8)
    [void](Clip $intDir @('clear', '-All'))
    [void](Clip $intDir @('put', 'pin-me'))
    [void](Clip $intDir @('put', 'other-one'))
    $o = Clip $intDir @('pin', '2')
    Check 'int' 'pin' ($o -match 'pinned') $o.Trim()
    $o = Clip $intDir @('list')
    $pinLine = @($o -split "`n" | Where-Object { $_ -match 'pin-me' })
    Check 'int' 'pin floats to the top' ($pinLine.Count -gt 0 -and $pinLine[0] -match '\*') $o.Trim()
    $o = Clip $intDir @('status')
    Check 'int' 'status shows the pin count' ($o -match '1 pinned') $o.Trim()
    $o = Clip $intDir @('clear')
    Check 'int' 'clear keeps the pin mark' ((($o -match 'kept by marks')) -and ((Clip $intDir @('list')) -match 'pin-me')) $o.Trim()
    $o = Clip $intDir @('clear', '-All')
    Check 'int' 'clear -All drops the pin mark' (($o -match 'history cleared')) $o.Trim()
    $o = Clip $intDir @('list')
    Check 'int' 'list empty after clear -All' ($o -match 'history is empty') $o.Trim()

    # with sticky pins on, the frozen block may never fill the list: the third pin is
    # refused instead of pushing the rows below out of reach
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks', 'item-marks.StickyPins=1', 'item-marks.StickyRows=2'), $Utf8)
    [void](Clip $intDir @('clear', '-All'))
    [void](Clip $intDir @('put', 'cap-one'))
    [void](Clip $intDir @('put', 'cap-two'))
    [void](Clip $intDir @('put', 'cap-three'))
    $o = Clip $intDir @('pin', '1')
    Check 'int' 'pin fits under the sticky cap' ($o -match 'pinned') $o.Trim()
    [void](Clip $intDir @('pin', '2'))
    $o = Clip $intDir @('pin', '3')
    Check 'int' 'pin refused when the sticky cap is full' (($o -match '\[!\]') -and ($o -match 'unpin one first') -and ($o -match 'raise Rows')) $o.Trim()
    $o = Clip $intDir @('list')
    $capLine = @($o -split "`n" | Where-Object { $_ -match 'cap-one' })
    Check 'int' 'refused pin leaves the row unmarked' ($capLine.Count -gt 0 -and $capLine[0] -notmatch '\*') ($capLine -join '/')
    # turning the feature off drops the cap, so the same pin goes through
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks', 'item-marks.StickyPins=0', 'item-marks.StickyRows=2'), $Utf8)
    $o = Clip $intDir @('pin', '3')
    Check 'int' 'no cap while sticky pins are off' ($o -match 'pinned') $o.Trim()
    [void](Clip $intDir @('clear', '-All'))
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks'), $Utf8)


Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

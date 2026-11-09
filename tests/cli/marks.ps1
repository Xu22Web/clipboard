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


    # ------------------------------------------------- starring
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks'), $Utf8)
    [void](Clip $intDir @('clear', '-All'))
    [void](Clip $intDir @('put', 'star-alpha'))
    [void](Clip $intDir @('put', 'star-beta'))
    $o = Clip $intDir @('star', '1')
    Check 'int' 'star command' ($o -match 'starred:') $o.Trim()
    $o = Clip $intDir @('status')
    Check 'int' 'status counts starred' ($o -match '1 starred') $o.Trim()
    $o = Clip $intDir @('del', '1')
    Check 'int' 'starred entry cannot be deleted' ($o -match 'starred entry, unstar it first') $o.Trim()
    $o = Clip $intDir @('clear', '-All')
    Check 'int' 'clear keeps starred' (($o -match '1 starred kept') -and ((Clip $intDir @('list')) -match 'star-beta')) $o.Trim()
    $o = Clip $intDir @('unstar', '1')
    Check 'int' 'unstar command' ($o -match 'unstarred:') $o.Trim()
    $o = Clip $intDir @('del', '1')
    Check 'int' 'delete works after unstar' ($o -match 'deleted:') $o.Trim()

    # ------------------------------------------------- highlight
    [void](Clip $intDir @('put', 'mark-gamma'))
    $o = Clip $intDir @('highlight', '1')
    Check 'int' 'highlight command' ($o -match 'highlighted:') $o.Trim()
    $o = Clip $intDir @('highlight', '1')
    Check 'int' 'highlight is repeatable-safe' ($o -match 'already highlighted') $o.Trim()
    $o = Clip $intDir @('unhighlight', '1')
    Check 'int' 'unhighlight command' ($o -match 'highlight cleared:') $o.Trim()
    $o = Clip $intDir @('unhighlight', '1')
    Check 'int' 'unhighlight reports the empty state' ($o -match 'not highlighted') $o.Trim()


Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

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


    # ------------------------------------------------- starring
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks'), $Utf8)
    [void](Run @('clear', '-All'))
    [void](Run @('put', 'star-alpha'))
    [void](Run @('put', 'star-beta'))
    $o = Run @('star', '1') -Cold
    Check 'int' 'star command' ($o -match 'starred:') $o.Trim()
    $o = Run @('status')
    Check 'int' 'status counts starred' ($o -match '1 starred') $o.Trim()
    $o = Run @('del', '1')
    Check 'int' 'starred entry cannot be deleted' ($o -match 'starred entry, unstar it first') $o.Trim()
    $o = Run @('clear', '-All')
    Check 'int' 'clear keeps starred' (($o -match '1 starred kept') -and ((Run @('list') -Cold) -match 'star-beta')) $o.Trim()
    $o = Run @('unstar', '1') -Cold
    Check 'int' 'unstar command' ($o -match 'unstarred:') $o.Trim()
    $o = Run @('del', '1')
    Check 'int' 'delete works after unstar' ($o -match 'deleted:') $o.Trim()

    # ------------------------------------------------- highlight
    [void](Run @('put', 'mark-gamma'))
    $o = Run @('highlight', '1') -Cold
    Check 'int' 'highlight command' ($o -match 'highlighted:') $o.Trim()
    $o = Run @('highlight', '1') -Cold
    Check 'int' 'highlight is repeatable-safe' ($o -match 'already highlighted') $o.Trim()
    $o = Run @('unhighlight', '1') -Cold
    Check 'int' 'unhighlight command' ($o -match 'highlight cleared:') $o.Trim()
    $o = Run @('unhighlight', '1') -Cold
    Check 'int' 'unhighlight reports the empty state' ($o -match 'not highlighted') $o.Trim()


Stop-CliRunner $cli
Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

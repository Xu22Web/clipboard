#Requires -Version 5.1
<#
  marks.ps1 - entries a plugin has marked, and the shipped plugins

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
$script:Harness.Part = 'marks'
Start-TestPart -Source $Source
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'


    # ------------------------------------------------- starred entries + new plugins
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
    [void](Clip $intDir @('put', 'mark-gamma'))
    $o = Clip $intDir @('highlight', '1')
    Check 'int' 'highlight command' ($o -match 'highlighted:') $o.Trim()
    $o = Clip $intDir @('highlight', '1')
    Check 'int' 'highlight is repeatable-safe' ($o -match 'already highlighted') $o.Trim()
    $o = Clip $intDir @('unhighlight', '1')
    Check 'int' 'unhighlight command' ($o -match 'highlight cleared:') $o.Trim()
    $o = Clip $intDir @('unhighlight', '1')
    Check 'int' 'unhighlight reports the empty state' ($o -match 'not highlighted') $o.Trim()

    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=transform,retention,item-marks,entry-actions', 'transform.Mode=snake'), $Utf8)
    [void](Clip $intDir @('clear', '-All'))
    [void](Clip $intDir @('put', 'Hello World Demo'))
    $o = Clip $intDir @('transform', '1 upper')
    Check 'int' 'transform one-off mode' ($o -match '\[upper\] HELLO WORLD DEMO') $o.Trim()
    $o = Clip $intDir @('transform', '1')
    Check 'int' 'transform uses configured mode' ($o -match '\[snake\] hello_world_demo') $o.Trim()
    $o = Clip $intDir @('marks')
    Check 'int' 'marks command' (($o -match 'star glyph') -and ($o -match 'highlight ink')) $o.Trim()
    $o = Clip $intDir @('sweep', 'force')
    Check 'int' 'sweep command' ($o -match 'retention') $o.Trim()
    $o = Clip $intDir @('kind', '1')
    Check 'int' 'kind detail block' (($o -match 'kind text') -and ($o -match '(?m)^  size\s+:') -and ($o -match '(?m)^  preview\s+:')) $o.Trim()
    $o = Clip $intDir @('kind', '0')
    Check 'int' 'kind out of range' ($o -match 'index out of range') $o.Trim()
    $o = Clip $intDir @('kinds')
    Check 'int' 'kinds distribution' (($o -match 'kinds in ') -and ($o -match '(?m)^  text\s')) $o.Trim()
    $o = Clip $intDir @('config')
    Check 'int' 'config groups plugin settings' (($o -match '\[plugin: transform\]') -and ($o -match '(?m)^    Mode\s+=\s+snake')) ''
    Check 'int' 'config groups each enabled plugin' (($o -match '\[plugin: retention\]') -and ($o -match '\[plugin: item-marks\]') -and ($o -match '\[plugin: entry-actions\]')) ''
    Check 'int' 'config has no theme-only keys' (-not ($o -match 'Theme\.(Accent|Surface|Pin)|item-marks\.StarColor')) ''
    $o = Clip $intDir @('help')
    Check 'int' 'help groups every plugin' (($o -match '\[plugin: transform\]') -and ($o -match '\[plugin: retention\]') -and ($o -match 'transform entry N')) ''
    Check 'int' 'help groups pin and star' (($o -match '(?s)\[plugin: item-marks\].*pin\s+pin entry N.*unstar')) ''
    Check 'int' 'help lists the highlight verbs' (($o -match '(?s)\[plugin: item-marks\].*highlight\s+highlight entry N.*unhighlight')) ''
    Check 'int' 'help puts kind under entry-actions' ($o -match '(?s)\[plugin: entry-actions\].*kind\s+analyse entry N.*kinds') ''
    $o = Clip $intDir @('config', 'set', 'transform.Mode', 'kebab')
    Check 'int' 'plugin setting is writable' (($o -match 'transform\.Mode') -and ((Clip $intDir @('config', 'get', 'transform.Mode')) -match 'kebab')) $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Theme.Accent', '#FF6600')
    Check 'int' 'theme colour keys are rejected' ($o -match 'unknown key') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Theme', 'win11-light')
    Check 'int' 'theme name is still settable' ($o -match 'win11-light') $o.Trim()
    Remove-Item -LiteralPath $cfg2 -Force -ErrorAction SilentlyContinue


Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

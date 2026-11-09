#Requires -Version 5.1
<#
  plugins.ps1 - what the shipped plugins add: transform, retention, entry-actions, and how
  config / help group them

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
$script:Harness.Part = 'plugins'
Start-TestPart -Source $Source -ClipShared:$ClipShared -Quiet:$Quiet -ProgressFile $ProgressFile
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'
$cli = Start-CliRunner $intDir
# the plugin verbs (transform/marks/sweep/kind/kinds) run a plugin script block, which needs a
# real process; every reading command here does not
function Run([string[]]$cliArgs, [switch]$Cold) { return (Invoke-CliRunner $cli $cliArgs -Cold:$Cold) }


    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=transform,retention,item-marks,entry-actions', 'transform.Mode=snake'), $Utf8)
    [void](Run @('clear', '-All'))
    [void](Run @('put', 'Hello World Demo'))
    $o = Run @('transform', '1 upper') -Cold
    Check 'int' 'transform one-off mode' ($o -match '\[upper\] HELLO WORLD DEMO') $o.Trim()
    $o = Run @('transform', '1') -Cold
    Check 'int' 'transform uses configured mode' ($o -match '\[snake\] hello_world_demo') $o.Trim()
    $o = Run @('marks') -Cold
    Check 'int' 'marks command' (($o -match 'star glyph') -and ($o -match 'highlight ink')) $o.Trim()
    $o = Run @('sweep', 'force') -Cold
    Check 'int' 'sweep command' ($o -match 'retention') $o.Trim()
    $o = Run @('kind', '1') -Cold
    Check 'int' 'kind detail block' (($o -match 'kind text') -and ($o -match '(?m)^  size\s+:') -and ($o -match '(?m)^  preview\s+:')) $o.Trim()
    $o = Run @('kind', '0') -Cold
    Check 'int' 'kind out of range' ($o -match 'index out of range') $o.Trim()
    $o = Run @('kinds') -Cold
    Check 'int' 'kinds distribution' (($o -match 'kinds in ') -and ($o -match '(?m)^  text\s')) $o.Trim()

    # config groups settings under their plugin, and never invents theme-only keys
    $o = Run @('config')
    Check 'int' 'config groups plugin settings' (($o -match '\[plugin: transform\]') -and ($o -match '(?m)^    Mode\s+=\s+snake')) ''
    Check 'int' 'config groups each enabled plugin' (($o -match '\[plugin: retention\]') -and ($o -match '\[plugin: item-marks\]') -and ($o -match '\[plugin: entry-actions\]')) ''
    Check 'int' 'config has no theme-only keys' (-not ($o -match 'Theme\.(Accent|Surface|Pin)|item-marks\.StarColor')) ''

    $o = Run @('help')
    Check 'int' 'help groups every plugin' (($o -match '\[plugin: transform\]') -and ($o -match '\[plugin: retention\]') -and ($o -match 'transform entry N')) ''
    Check 'int' 'help groups pin and star' ($o -match '(?s)\[plugin: item-marks\].*pin\s+pin entry N.*unstar') ''
    Check 'int' 'help lists the highlight verbs' ($o -match '(?s)\[plugin: item-marks\].*highlight\s+highlight entry N.*unhighlight') ''
    Check 'int' 'help puts kind under entry-actions' ($o -match '(?s)\[plugin: entry-actions\].*kind\s+analyse entry N.*kinds') ''

    $o = Run @('config', 'set', 'transform.Mode', 'kebab')
    Check 'int' 'plugin setting is writable' (($o -match 'transform\.Mode') -and ((Run @('config', 'get', 'transform.Mode')) -match 'kebab')) $o.Trim()
    $o = Run @('config', 'set', 'Theme.Accent', '#FF6600')
    Check 'int' 'theme colour keys are rejected' ($o -match 'unknown key') $o.Trim()
    $o = Run @('config', 'set', 'Theme', 'win11-light')
    Check 'int' 'theme name is still settable' ($o -match 'win11-light') $o.Trim()
    Remove-Item -LiteralPath $cfg2 -Force -ErrorAction SilentlyContinue


Stop-CliRunner $cli
Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

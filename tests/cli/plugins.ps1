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


Describe 'int' {
  AfterAll {
    Stop-CliRunner $cli
    Remove-Item -LiteralPath $cfg2 -Force -ErrorAction SilentlyContinue
  }

  Describe 'plugin verbs' {
    BeforeAll {
      [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=transform,retention,item-marks,entry-actions', 'transform.Mode=snake'), $Utf8)
      [void](Run @('clear', '-All'))
      [void](Run @('put', 'Hello World Demo'))
    }
    It 'transform one-off mode' {
      $o = Run @('transform', '1 upper') -Cold
      Expect-Match $o '\[upper\] HELLO WORLD DEMO' $o.Trim()
    }
    It 'transform uses configured mode' {
      $o = Run @('transform', '1') -Cold
      Expect-Match $o '\[snake\] hello_world_demo' $o.Trim()
    }
    It 'marks command' {
      $o = Run @('marks') -Cold
      Expect (($o -match 'star glyph') -and ($o -match 'highlight ink')) $o.Trim()
    }
    It 'sweep command' {
      $o = Run @('sweep', 'force') -Cold
      Expect-Match $o 'retention' $o.Trim()
    }
    It 'kind detail block' {
      $o = Run @('kind', '1') -Cold
      Expect (($o -match 'kind text') -and ($o -match '(?m)^  size\s+:') -and ($o -match '(?m)^  preview\s+:')) $o.Trim()
    }
    It 'kind out of range' {
      $o = Run @('kind', '0') -Cold
      Expect-Match $o 'index out of range' $o.Trim()
    }
    It 'kinds distribution' {
      $o = Run @('kinds') -Cold
      Expect (($o -match 'kinds in ') -and ($o -match '(?m)^  text\s')) $o.Trim()
    }
  }

  # config groups settings under their plugin, and never invents theme-only keys
  Describe 'grouping' {
    It 'config groups plugin settings' {
      $o = Run @('config')
      Expect (($o -match '\[plugin: transform\]') -and ($o -match '(?m)^    Mode\s+=\s+snake')) 'config should group the transform setting'
    }
    It 'config groups each enabled plugin' {
      $o = Run @('config')
      Expect (($o -match '\[plugin: retention\]') -and ($o -match '\[plugin: item-marks\]') -and ($o -match '\[plugin: entry-actions\]')) 'config should list every enabled plugin'
    }
    It 'config has no theme-only keys' {
      $o = Run @('config')
      Expect (-not ($o -match 'Theme\.(Accent|Surface|Pin)|item-marks\.StarColor')) 'config must not invent theme-only keys'
    }
    It 'help groups every plugin' {
      $o = Run @('help')
      Expect (($o -match '\[plugin: transform\]') -and ($o -match '\[plugin: retention\]') -and ($o -match 'transform entry N')) 'help should group every plugin'
    }
    It 'help groups pin and star' {
      $o = Run @('help')
      Expect-Match $o '(?s)\[plugin: item-marks\].*pin\s+pin entry N.*unstar' 'help should group pin and star'
    }
    It 'help lists the highlight verbs' {
      $o = Run @('help')
      Expect-Match $o '(?s)\[plugin: item-marks\].*highlight\s+highlight entry N.*unhighlight' 'help should list the highlight verbs'
    }
    It 'help puts kind under entry-actions' {
      $o = Run @('help')
      Expect-Match $o '(?s)\[plugin: entry-actions\].*kind\s+analyse entry N.*kinds' 'help should put kind under entry-actions'
    }
  }

  Describe 'plugin settings' {
    It 'plugin setting is writable' {
      $o = Run @('config', 'set', 'transform.Mode', 'kebab')
      Expect (($o -match 'transform\.Mode') -and ((Run @('config', 'get', 'transform.Mode')) -match 'kebab')) $o.Trim()
    }
    It 'theme colour keys are rejected' {
      $o = Run @('config', 'set', 'Theme.Accent', '#FF6600')
      Expect-Match $o 'unknown key' $o.Trim()
    }
    It 'theme name is still settable' {
      $o = Run @('config', 'set', 'Theme', 'win11-light')
      Expect-Match $o 'win11-light' $o.Trim()
    }
  }
}

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

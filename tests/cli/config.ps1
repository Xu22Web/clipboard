#Requires -Version 5.1
<#
  config.ps1 - which plugins load: the whitelist in the ini, what config / status / help say
  about them, and their own settings

  One part of the self tests: it runs alone, in its own process, with its own sandbox and its
  own clipboard (tests\lib\fake-clip.ps1). tests\run.ps1 starts several of these at once.

  Every command here goes through the part's runner (tests\lib\cli-runner.ps1): one process
  for the whole part, a runspace of its own per command. None of these commands reaches a
  plugin's script block, so none of them has to be a cold process.
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
$script:Harness.Part = 'config'
Start-TestPart -Source $Source -ClipShared:$ClipShared -Quiet:$Quiet -ProgressFile $ProgressFile
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'
$cli = Start-CliRunner $intDir
function Run([string[]]$cliArgs) { return (Invoke-CliRunner $cli $cliArgs) }


Describe 'int' {
  AfterAll { Stop-CliRunner $cli }

  # plugin commands (loaded by default)
  Describe 'plugins load by default' {
    BeforeAll {
      [void](Run @('clear', '-All'))
      [void](Run @('put', 'https://example.com/hello'))
      Remove-Item -LiteralPath $cfg2 -Force -ErrorAction SilentlyContinue
    }
    It 'kind is available by default' {
      $o = Run @('kind', '1')
      Expect-Match $o 'link' $o.Trim()
    }
    It 'open reports a bad index' {
      $o = Run @('open', '99')
      Expect-Match $o 'index out of range' $o.Trim()
    }
    It 'config lists every loaded plugin' {
      $o = Run @('config')
      Expect (($o -match 'plugins     : loaded') -and ($o -match 'item-marks') -and ($o -match 'entry-actions') -and ($o -match 'retention') -and ($o -match 'transform')) $o.Trim()
    }
    It 'status lists every loaded plugin' {
      $o = Run @('status')
      Expect-Match $o 'plugins     : entry-actions, item-marks, retention, transform' $o.Trim()
    }
    It 'help has the plugin groups by default' {
      $o = Run @('help')
      Expect (($o -match '\[plugin: item-marks\]') -and ($o -match '(?m)^    pin\s')) 'help should group the item-marks verbs'
    }
    It 'help lists the plugin panel keys' {
      $o = Run @('help')
      Expect-Match $o 'Ctrl\+S\s+star.*\(item-marks\)' 'help should list the item-marks panel keys'
    }
  }

  # a shorter list narrows it: a plugin that is not named never runs
  Describe 'Plugins= narrows the list' {
    BeforeAll { [IO.File]::WriteAllLines($cfg2, @('Plugins=entry-actions'), $Utf8) }

    It 'a shorter list turns the other plugins off' {
      $o = Run @('star', '1')
      Expect-Match $o 'unknown command' $o.Trim()
    }
    It 'Plugins= enables the plugin' {
      $o = Run @('open', '99')
      Expect-Match $o 'index out of range' $o.Trim()
    }
    It 'config lists the loaded plugin' {
      $o = Run @('config')
      Expect-Match $o 'plugins     : loaded entry-actions' $o.Trim()
    }
    It 'status lists the loaded plugin' {
      $o = Run @('status')
      Expect-Match $o 'plugins     : entry-actions' $o.Trim()
    }
    It 'help groups base commands' {
      $o = Run @('help')
      Expect (($o -match '\[history\]') -and ($o -match '(?m)^    del N\s')) 'help should group the base commands'
    }
    It 'help groups plugin commands' {
      $o = Run @('help')
      Expect (($o -match '\[plugin: entry-actions\]') -and ($o -match '(?m)^    open\s')) 'help should group the entry-actions verbs'
    }
    It 'help lists plugin panel keys' {
      $o = Run @('help')
      Expect-Match $o 'Ctrl\+O\s+open link or path\s+\(entry-actions\)' 'help should list the entry-actions panel keys'
    }
    It 'plugin setting is visible' {
      $o = Run @('config', 'get', 'entry-actions.Browser')
      Expect-Match $o 'entry-actions\.Browser' $o.Trim()
    }
    It 'plugin setting is writable' {
      $o = Run @('config', 'set', 'entry-actions.Reveal', '0')
      $iniPlugin = [IO.File]::ReadAllText($cfg2)
      # a plugin key lands in its own section, which is created when the file has none yet
      Expect (($o -match 'entry-actions\.Reveal') -and ($iniPlugin -match '(?m)^\[entry-actions\]\r?$') -and ($iniPlugin -match '(?m)^Reveal=0\r?$')) $o.Trim()
    }
    It 'plugin setting rejects bad value' {
      $o = Run @('config', 'set', 'entry-actions.Reveal', 'maybe')
      Expect-Match $o '0 or 1' $o.Trim()
    }
    It 'config init fills plugin settings only' {
      $o = Run @('config', 'init')
      $tplText = [IO.File]::ReadAllText($cfg2)
      # the missing plugin key is added inside the existing section, the one the user set to 0
      # keeps its value, and the section header is not duplicated
      Expect (($tplText -match '(?m)^Browser=\r?$') -and ($tplText -match '(?m)^Reveal=0\r?$') -and (([regex]::Matches($tplText, '(?m)^\[entry-actions\]\r?$')).Count -eq 1)) 'config init should only fill the plugin settings'
    }
  }

  Describe 'unknown plugin name' {
    BeforeAll { [IO.File]::WriteAllLines($cfg2, @('Plugins=nosuch'), $Utf8) }

    It 'unknown plugin name is reported' {
      $o = Run @('status')
      Expect-Match $o 'not found: nosuch' $o.Trim()
    }
    It 'help reports unknown plugin' {
      $o = Run @('help')
      Expect-Match $o 'plugin not found: nosuch' 'help should report the unknown plugin'
    }
    It 'data commands stay clean' {
      $o = Run @('list')
      Expect (-not ($o -match 'plugin')) $o.Trim()
    }
    It 'base commands survive a bad plugin name' {
      $o = Run @('list')
      Expect-Match $o 'example\.com/hello' $o.Trim()
    }
    It 'config get Plugins' {
      $o = Run @('config', 'get', 'Plugins')
      Expect-Match $o 'Plugins = nosuch' $o.Trim()
    }
    It 'config set accepts a plugin list' {
      $o = Run @('config', 'set', 'Plugins', 'entry-actions')
      Expect-Match $o 'entry-actions' $o.Trim()
    }
  }
}

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

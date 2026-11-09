#Requires -Version 5.1
<#
  config.ps1 - which plugins load: the whitelist in the ini, what config / status / help say
  about them, and their own settings

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
$script:Harness.Part = 'config'
Start-TestPart -Source $Source -ClipShared:$ClipShared -Quiet:$Quiet -ProgressFile $ProgressFile
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'


    # --------------------------------------- plugin commands (loaded by default)
    [void](Clip $intDir @('clear', '-All'))
    [void](Clip $intDir @('put', 'https://example.com/hello'))
    Remove-Item -LiteralPath $cfg2 -Force -ErrorAction SilentlyContinue
    $o = Clip $intDir @('kind', '1')
    Check 'int' 'kind is available by default' ($o -match 'link') $o.Trim()
    $o = Clip $intDir @('open', '99')
    Check 'int' 'open reports a bad index' ($o -match 'index out of range') $o.Trim()
    $o = Clip $intDir @('config')
    Check 'int' 'config lists every loaded plugin' (($o -match 'plugins     : loaded') -and ($o -match 'item-marks') -and ($o -match 'entry-actions') -and ($o -match 'retention') -and ($o -match 'transform')) $o.Trim()
    $o = Clip $intDir @('status')
    Check 'int' 'status lists every loaded plugin' ($o -match 'plugins     : entry-actions, item-marks, retention, transform') $o.Trim()
    $o = Clip $intDir @('help')
    Check 'int' 'help has the plugin groups by default' (($o -match '\[plugin: item-marks\]') -and ($o -match '(?m)^    pin\s')) ''
    Check 'int' 'help lists the plugin panel keys' ($o -match 'Ctrl\+S\s+star.*\(item-marks\)') ''

    # a shorter list narrows it: a plugin that is not named never runs
    [IO.File]::WriteAllLines($cfg2, @('Plugins=entry-actions'), $Utf8)
    $o = Clip $intDir @('star', '1')
    Check 'int' 'a shorter list turns the other plugins off' ($o -match 'unknown command') $o.Trim()
    $o = Clip $intDir @('open', '99')
    Check 'int' 'Plugins= enables the plugin' ($o -match 'index out of range') $o.Trim()
    $o = Clip $intDir @('config')
    Check 'int' 'config lists the loaded plugin' ($o -match 'plugins     : loaded entry-actions') $o.Trim()
    $o = Clip $intDir @('status')
    Check 'int' 'status lists the loaded plugin' ($o -match 'plugins     : entry-actions') $o.Trim()
    $o = Clip $intDir @('help')
    Check 'int' 'help groups base commands' (($o -match '\[history\]') -and ($o -match '(?m)^    del N\s')) ''
    Check 'int' 'help groups plugin commands' (($o -match '\[plugin: entry-actions\]') -and ($o -match '(?m)^    open\s')) ''
    Check 'int' 'help lists plugin panel keys' ($o -match 'Ctrl\+O\s+open link or path\s+\(entry-actions\)') ''

    $o = Clip $intDir @('config', 'get', 'entry-actions.Browser')
    Check 'int' 'plugin setting is visible' ($o -match 'entry-actions\.Browser') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'entry-actions.Reveal', '0')
    $iniPlugin = [IO.File]::ReadAllText($cfg2)
    # a plugin key lands in its own section, which is created when the file has none yet
    Check 'int' 'plugin setting is writable' (($o -match 'entry-actions\.Reveal') -and ($iniPlugin -match '(?m)^\[entry-actions\]\r?$') -and ($iniPlugin -match '(?m)^Reveal=0\r?$')) $o.Trim()
    $o = Clip $intDir @('config', 'set', 'entry-actions.Reveal', 'maybe')
    Check 'int' 'plugin setting rejects bad value' ($o -match '0 or 1') $o.Trim()
    $o = Clip $intDir @('config', 'init')
    $tplText = [IO.File]::ReadAllText($cfg2)
    # the missing plugin key is added inside the existing section, the one the user set to 0
    # keeps its value, and the section header is not duplicated
    Check 'int' 'config init fills plugin settings only' (($tplText -match '(?m)^Browser=\r?$') -and ($tplText -match '(?m)^Reveal=0\r?$') -and (([regex]::Matches($tplText, '(?m)^\[entry-actions\]\r?$')).Count -eq 1)) ''
    [IO.File]::WriteAllLines($cfg2, @('Plugins=entry-actions'), $Utf8)

    [IO.File]::WriteAllLines($cfg2, @('Plugins=nosuch'), $Utf8)
    $o = Clip $intDir @('status')
    Check 'int' 'unknown plugin name is reported' ($o -match 'not found: nosuch') $o.Trim()
    $o = Clip $intDir @('help')
    Check 'int' 'help reports unknown plugin' ($o -match 'plugin not found: nosuch') ''
    $o = Clip $intDir @('list')
    Check 'int' 'data commands stay clean' (-not ($o -match 'plugin')) $o.Trim()
    $o = Clip $intDir @('list')
    Check 'int' 'base commands survive a bad plugin name' ($o -match 'example\.com/hello') $o.Trim()
    $o = Clip $intDir @('config', 'get', 'Plugins')
    Check 'int' 'config get Plugins' ($o -match 'Plugins = nosuch') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Plugins', 'entry-actions')
    Check 'int' 'config set accepts a plugin list' ($o -match 'entry-actions') $o.Trim()


Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

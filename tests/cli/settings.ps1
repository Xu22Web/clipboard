#Requires -Version 5.1
<#
  settings.ps1 - the ini decides the behaviour, and settings can only be changed there

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
$script:Harness.Part = 'settings'
Start-TestPart -Source $Source -ClipShared:$ClipShared
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'


    # config precedence: ini MaxItems=2 caps the list, whatever the command line asks for
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=2'), $Utf8)
    [void](Clip $intDir @('clear'))
    1..3 | ForEach-Object { [void](Clip $intDir @('put', ('cfg-' + $_))) }
    $o = Clip $intDir @('list')
    Check 'int' 'ini MaxItems respected' (@($o -split "`n" | Where-Object { $_ -match 'cfg-' }).Count -eq 2) $o.Trim()

    [void](Clip $intDir @('clear'))
    # settings are config-only: a setting switch is refused, nothing is silently applied
    [void](Clip $intDir @('put', 'cfg-guard'))
    $bad = & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File (Join-Path $intDir 'clipboard.ps1') put 'cli-override' -MaxItems 5 2>&1
    $badText = ($bad -join ' ')
    Check 'int' 'setting switches are refused' (($badText -match 'MaxItems') -and -not ((Clip $intDir @('get')) -match 'cli-override')) $badText.Trim()
    $o = Clip $intDir @('help')
    Check 'int' 'help advertises no setting switches' ((-not ($o -match 'Options \(override')) -and ($o -match 'clipboard\.ini only') -and (-not ($o -match '-MaxItems'))) ''

    # the sandbox keeps its store next to its own script, never in the repo
    Check 'int' 'data dir isolate' ((Test-Path -LiteralPath (Join-Path $intDir 'data\history.dat')) -and -not (Test-Path -LiteralPath (Join-Path $srcRoot 'data\integration'))) ''

    # DataDir= in clipboard.ini decides the write location
    $altDir = Join-Path $tmpRoot 'alt'
    $cfgRoot = Join-Path $tmpRoot 'cfgroot'
    foreach ($d in @($altDir, $cfgRoot)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item -LiteralPath $clipPs1 -Destination (Join-Path $cfgRoot 'clipboard.ps1')
    # the program is entry file + lib\ + utils\ + schema\: a lone clipboard.ps1 cannot start
    foreach ($d in @('lib', 'utils', 'schema')) { Copy-Item -LiteralPath (Join-Path $srcRoot $d) -Destination $cfgRoot -Recurse -Force }
    [IO.File]::WriteAllLines((Join-Path $cfgRoot 'clipboard.ini'), @('DataDir=' + $altDir), $Utf8)
    & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File (Join-Path $cfgRoot 'clipboard.ps1') put 'ini-datadir' 2>&1 | Out-Null
    Check 'int' 'DataDir from ini' (Test-Path -LiteralPath (Join-Path $altDir 'history.dat')) $altDir

    # the config verbs: read, write, and every refusal
    $o = Clip $intDir @('config', 'get', 'Rows')
    Check 'int' 'config get' ($o -match 'Rows = 10') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Rows', '12')
    $iniAfter = [IO.File]::ReadAllText($cfg2)
    Check 'int' 'config set writes' (($o -match '10 -> 12') -and ($iniAfter -match '(?m)^Rows=12\r?$')) $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Rows', '1')
    Check 'int' 'config set rejects range' ($o -match 'must be >= 3') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'NopeKey', '1')
    Check 'int' 'config set rejects unknown key' ($o -match 'unknown key') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'DataDir', 'D:\x')
    Check 'int' 'config set rejects DataDir' ($o -match 'DataDir cannot be changed') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Hotkey', 'Ctrl+Nope')
    Check 'int' 'config set rejects bad hotkey' ($o -match 'unknown key name') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'PreviewDelay', '900')
    Check 'int' 'a preview setting is writable' ($o -match '350 -> 900') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'PreviewDelay', '350')
    Check 'int' 'a preview setting is restorable' ($o -match '900 -> 350') $o.Trim()


Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

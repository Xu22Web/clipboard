#Requires -Version 5.1
<#
  capture.ps1 - capture, paste, status and the mark verbs, through the command line

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
$script:Harness.Part = 'cli'
Start-TestPart -Source $Source
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'


    # diag and the native Win+V restore are gone: the shell's own history state is a single
    # line in `status`, and an old command name falls through to the usage text
    $o = Clip $intDir @('diag')
    Check 'int' 'removed commands fall back to usage' ($o -match 'unknown command: diag') $o.Trim()
    $o = Clip $intDir @('restore-data')
    Check 'int' 'restore-data is not a command any more' ($o -match 'unknown command: restore-data') $o.Trim()
    $o = Clip $intDir @('status')
    # the state is reported exactly when there is something to report, so a machine where
    # Win+V works keeps a clean status
    $winv = ''
    if (Get-Command Get-WinVState -ErrorAction SilentlyContinue) { $winv = Get-WinVState }
    $hasLine = [bool]($o -match 'win\+v')
    Check 'int' 'status states the win+v state only when it is not usable' ($hasLine -eq [bool]$winv) ([string]$winv + ' / printed=' + [string]$hasLine)

    # config precedence: ini MaxItems=2, then the CLI switch must win
    $cfg2 = Join-Path $intDir 'clipboard.ini'
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

    # pin / unpin / clear / config set  (pin and star are verbs of the item-marks plugin)
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

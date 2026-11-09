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
  [string]$ProgressFile = '',
  [switch]$Quiet,
  # set by tests\run.ps1 when another part of the same run drives the real clipboard
  [switch]$ClipShared
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'lib\harness.ps1')
$script:Harness.Part = 'settings'
Start-TestPart -Source $Source -ClipShared:$ClipShared -Quiet:$Quiet -ProgressFile $ProgressFile
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'
$cli = Start-CliRunner $intDir
function Run([string[]]$cliArgs, [switch]$Cold) { return (Invoke-CliRunner $cli $cliArgs -Cold:$Cold) }


Describe 'int' {
  AfterAll { Stop-CliRunner $cli }

  # config precedence: ini MaxItems=2 caps the list, whatever the command line asks for
  Describe 'ini MaxItems' {
    BeforeAll {
      [IO.File]::WriteAllLines($cfg2, @('MaxItems=2'), $Utf8)
      [void](Run @('clear'))
      1..3 | ForEach-Object { [void](Run @('put', ('cfg-' + $_))) }
    }
    It 'ini MaxItems respected' {
      $o = Run @('list') -Cold
      Expect (@($o -split "`n" | Where-Object { $_ -match 'cfg-' }).Count -eq 2) $o.Trim()
    }
  }

  # settings are config-only: a setting switch is refused, nothing is silently applied
  Describe 'settings are config only' {
    BeforeAll {
      [void](Run @('clear'))
      [void](Run @('put', 'cfg-guard'))
    }
    It 'setting switches are refused' {
      $bad = & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File (Join-Path $intDir 'clipboard.ps1') put 'cli-override' -MaxItems 5 2>&1
      $badText = ($bad -join ' ')
      Expect (($badText -match 'MaxItems') -and -not ((Run @('get')) -match 'cli-override')) $badText.Trim()
    }
    It 'help advertises no setting switches' {
      $o = Run @('help')
      Expect ((-not ($o -match 'Options \(override')) -and ($o -match 'clipboard\.ini only') -and (-not ($o -match '-MaxItems'))) 'help must not offer setting switches'
    }
  }

  # the sandbox keeps its store next to its own script, never in the repo
  It 'data dir isolate' {
    Expect ((Test-Path -LiteralPath (Join-Path $intDir 'data\history.dat')) -and -not (Test-Path -LiteralPath (Join-Path $srcRoot 'data\integration'))) 'the store has to stay inside the sandbox'
  }

  # DataDir= in clipboard.ini decides the write location
  Describe 'DataDir from ini' {
    BeforeAll {
      $script:altDir = Join-Path $tmpRoot 'alt'
      $cfgRoot = Join-Path $tmpRoot 'cfgroot'
      foreach ($d in @($script:altDir, $cfgRoot)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
      Copy-Item -LiteralPath $clipPs1 -Destination (Join-Path $cfgRoot 'clipboard.ps1')
      # the program is entry file + lib\ + utils\ + schema\: a lone clipboard.ps1 cannot start
      foreach ($d in @('lib', 'utils', 'schema')) { Copy-Item -LiteralPath (Join-Path $srcRoot $d) -Destination $cfgRoot -Recurse -Force }
      [IO.File]::WriteAllLines((Join-Path $cfgRoot 'clipboard.ini'), @('DataDir=' + $script:altDir), $Utf8)
      & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File (Join-Path $cfgRoot 'clipboard.ps1') put 'ini-datadir' 2>&1 | Out-Null
    }
    It 'DataDir from ini' {
      Expect (Test-Path -LiteralPath (Join-Path $script:altDir 'history.dat')) $script:altDir
    }
  }

  # the config verbs: read, write, and every refusal
  Describe 'config verbs' {
    It 'config get' {
      $o = Run @('config', 'get', 'Rows')
      Expect-Match $o 'Rows = 10' $o.Trim()
    }
    It 'config set writes' {
      $o = Run @('config', 'set', 'Rows', '12')
      $iniAfter = [IO.File]::ReadAllText($cfg2)
      Expect (($o -match '10 -> 12') -and ($iniAfter -match '(?m)^Rows=12\r?$')) $o.Trim()
    }
    It 'config set rejects range' {
      $o = Run @('config', 'set', 'Rows', '1')
      Expect-Match $o 'must be >= 3' $o.Trim()
    }
    It 'config set rejects unknown key' {
      $o = Run @('config', 'set', 'NopeKey', '1')
      Expect-Match $o 'unknown key' $o.Trim()
    }
    It 'config set rejects DataDir' {
      $o = Run @('config', 'set', 'DataDir', 'D:\x')
      Expect-Match $o 'DataDir cannot be changed' $o.Trim()
    }
    It 'config set rejects bad hotkey' {
      $o = Run @('config', 'set', 'Hotkey', 'Ctrl+Nope')
      Expect-Match $o 'unknown key name' $o.Trim()
    }
    It 'a preview setting is writable' {
      $o = Run @('config', 'set', 'PreviewDelay', '900')
      Expect-Match $o '350 -> 900' $o.Trim()
    }
    It 'a preview setting is restorable' {
      $o = Run @('config', 'set', 'PreviewDelay', '350')
      Expect-Match $o '900 -> 350' $o.Trim()
    }
  }
}

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

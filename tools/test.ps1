#Requires -Version 5.1
<#
  tools\test.ps1 - run the self test suite.

      cli test                       every part (tests\run.ps1)
      cli test -Unit                 only the in-process unit part
      cli test -Integration          only the command line parts
      cli test -E2E                  only the resident / clipboard part
      cli test -Part history          one part by name (history, transfer, settings, config,
                                     template, marks, pins, plugins, build, unit, serve)
      cli test -Changed              only the parts a change since HEAD can break
      cli test -Workers 6            fewer parts at a time (default: one per logical processor)
      cli test -Serial               one after another
      cli test -Reporter verbose      one row per check, with the path and the time
      cli test -Bail                 stop starting parts after the first failure
      cli test -Profile              print the slowest command line calls and the time per part
      cli test -NoProgress           do not repaint the block of running parts
      cli test -NoColor              no escape sequences and ascii marks (also the default when
                                     redirected)
      cli test -Source dist\clipboard-0.1.0
                                     run the command line parts against a packaged copy

  Switches are passed straight to tests\run.ps1; -Sta is required because the program loads
  System.Windows.Forms.
#>
[CmdletBinding()]
param(
  [switch]$Unit,
  [switch]$Integration,
  [switch]$E2E,
  [string]$Source = '',
  [string]$Part = '',
  [int]$Workers = 0,
  [switch]$Serial,
  [switch]$Changed,
  [string]$Reporter = '',
  [switch]$Bail,
  [switch]$Profile,
  [switch]$NoProgress,
  [switch]$NoColor,
  [switch]$Verbose_Log
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'tools\utils\console.ps1')
$driver = Join-Path $root 'tests\run.ps1'
if (-not (Test-Path -LiteralPath $driver)) {
  Write-Fail ('missing: ' + $driver)
  exit 1
}
# the suite decides its own colour, but NO_COLOR means the same thing to every tool: a log
# rendered somewhere else has to lose the escape sequences here too
if ($env:NO_COLOR) { $NoColor = $true }

$cli = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $driver)
if ($Unit) { $cli += '-Unit' }
if ($Integration) { $cli += '-Integration' }
if ($E2E) { $cli += '-E2E' }
if ($Source) { $cli += @('-Source', $Source) }
if ($Part) { $cli += @('-Part', $Part) }
if ($Workers -gt 0) { $cli += @('-Workers', [string]$Workers) }
if ($Serial) { $cli += '-Serial' }
if ($Changed) { $cli += '-Changed' }
if ($Reporter) { $cli += @('-Reporter', $Reporter) }
if ($Bail) { $cli += '-Bail' }
if ($Profile) { $cli += '-Profile' }
if ($NoProgress) { $cli += '-NoProgress' }
if ($NoColor) { $cli += '-NoColor' }
if ($Verbose_Log) { $cli += '-Verbose_Log' }
& powershell @cli
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }
exit $code

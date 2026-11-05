#Requires -Version 5.1
<#
  scripts\test.ps1 - run the self test suite.

      xpm test                       every group (struct, unit, integration, e2e)
      xpm test -Unit                 one group
      xpm test -Source dist\clipboard-0.1.0
                                     run the CLI groups against a packaged copy

  Switches are passed straight to tests\run-tests.ps1; -Sta is required because the
  program loads System.Windows.Forms.
#>
[CmdletBinding()]
param(
  [switch]$Unit,
  [switch]$Integration,
  [switch]$E2E,
  [string]$Source = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$suite = Join-Path $root 'tests\run-tests.ps1'
if (-not (Test-Path -LiteralPath $suite)) {
  Write-Host ('[x] missing: ' + $suite)
  exit 1
}

$cli = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $suite)
if ($Unit) { $cli += '-Unit' }
if ($Integration) { $cli += '-Integration' }
if ($E2E) { $cli += '-E2E' }
if ($Source) { $cli += @('-Source', $Source) }
& powershell @cli
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }
exit $code

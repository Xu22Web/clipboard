#Requires -Version 5.1
<#
  cli.ps1 - run a command declared in package.ini.

      cli                 list the commands
      cli <command> ...   run scripts.<command>, passing the remaining arguments on

  cli.cmd and cli (Git Bash / MSYS) call this file; all three read the same package.ini.
  The working directory is set to the project root first, so the command lines in
  package.ini may use paths relative to that folder.

  This file is the launcher and nothing else: the command table, the two config files and the
  three packages live under packages\, and everything below the first line is one call into
  packages\cli. That is the same split an npm binary keeps from the project it runs.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = '',
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$entry = Join-Path $root 'packages\cli\index.ps1'
if (-not (Test-Path -LiteralPath $entry)) {
  Write-Host ('[x] missing: ' + $entry)
  exit 1
}
. $entry
$code = Invoke-CliCommand -Command $Command -Rest $Rest
exit $code

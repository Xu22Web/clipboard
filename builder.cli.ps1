#Requires -Version 5.1
<#
  builder.cli.ps1 - the launcher the repository's scripts already call.

  The command lives in packages\cli\bin\cli.ps1, the way vite's lives in bin\vite.js. This file
  keeps the path package.ini's Dev / Build / Bundle / Test lines use and adds no behaviour of its
  own: the package owns the command, the repository root owns the name.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = '',
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$entry = Join-Path (Join-Path $PSScriptRoot 'packages\cli\bin') 'cli.ps1'
if (-not (Test-Path -LiteralPath $entry)) {
  Write-Host ('[x] missing: ' + $entry)
  exit 1
}

# the package's own exit reaches the caller: every branch of it ends in exit
if ($Command) { & $entry $Command @Rest } else { & $entry @Rest }

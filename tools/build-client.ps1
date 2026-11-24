#Requires -Version 5.1
<#
  tools\build-client.ps1 - compile src\preload\client.cs into src\preload\client.exe.

  The client is an accelerator, never a requirement: clipboard.cmd runs it when the file sits
  in preload\ next to clipboard.ps1 and falls back to the PowerShell path when it is missing or
  exits 100. A machine without the .NET Framework compiler loses about 1 s per command, not a
  feature.

      cli client                        write src\preload\client.exe
      cli client -Out dist\client.exe    write it somewhere else

  The compiler and its flags are the bundler's client entry (cli.ini [entry.client], built by
  tools\bundler\plugins\60-cs-compile.ps1), so this file only knows the command line. -Source
  exists because the test suite compiles its own copy of the same file out of a temp src tree
  instead of the repository's.

  The assembly (main\clipboard.dll) is a separate product: tools\build-assembly.ps1 builds
  that one.
#>
param(
  [string]$Source = '',
  [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'tools\utils\console.ps1')
$bundler = Join-Path $root 'tools\bundler\bundler.ps1'
if (-not (Test-Path -LiteralPath $bundler)) { Write-Fail ('missing: ' + $bundler); exit 1 }

$bundlerArgs = @('-Entry', 'client')
if ($Source) { $bundlerArgs += @('-From', $Source) }
if ($Out) { $bundlerArgs += @('-Out', $Out) }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bundler @bundlerArgs
exit $LASTEXITCODE

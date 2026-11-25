#Requires -Version 5.1
<#
  packages\cli\client.ps1 - compile src\preload\client.cs into src\preload\client.exe.

  The client is an accelerator, never a requirement: clipboard.cmd runs it when the file sits
  in preload\ next to clipboard.ps1 and falls back to the PowerShell path when it is missing or
  exits 100. A machine without the .NET Framework compiler loses about 1 s per command, not a
  feature.

      run client                          write src\preload\client.exe
      run client -Out dist\client.exe     write it somewhere else

  The compiler and its flags are the bundler's client entry (cli.ini [entry.client], built by
  packages\bundler\plugins\60-cs-compile.ps1), so this file only knows the command line. -Source
  exists because the test suite compiles its own copy of the same file out of a temp src tree
  instead of the repository's.

  The assembly (main\clipboard.dll) is a separate product: packages\cli\assembly.ps1 builds
  that one.
#>
param(
  [string]$Source = '',
  [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
. (Join-Path $root 'packages\cli\utils\console.ps1')
$cli = Join-Path $root 'packages\cli\bin\cli.ps1'
if (-not (Test-Path -LiteralPath $cli)) { Write-Fail ('missing: ' + $cli); exit 1 }

$cliArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli, 'bundle', '-Entry', 'Preload')
if ($Source) { $cliArgs += @('-From', $Source) }
& powershell.exe @cliArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
# the bundle writes under out\ and the launcher looks for the exe in src\preload
$built = Join-Path $root 'out\preload\client.exe'
if (-not $Out) { $Out = 'src\preload\client.exe' }
if (-not [System.IO.Path]::IsPathRooted($Out)) { $Out = Join-Path $root $Out }
if ((Test-Path -LiteralPath $built) -and ($built -ne $Out)) {
  $dir = Split-Path -Parent $Out
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Copy-Item -LiteralPath $built -Destination $Out -Force
}
exit 0

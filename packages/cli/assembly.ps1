#Requires -Version 5.1
<#
  packages\cli\assembly.ps1 - compile the type library into src\main\clipboard.dll.

  The assembly is an accelerator, never a requirement: a cold panel open takes 850 ms with it
  against 1050 ms compiling the source (measured, three runs each). The .cs files stay as the
  fallback, and a source file newer than the assembly also falls back (main\utils\native.ps1,
  Test-NativeAssembly), so a stale dll never wins.

  What the compiler is given is decided in one place: src\main\index.cs lists the sources with
  a #part line each, and the bundler resolves that list (packages\bundler\plugins\50-cs-part.ps1).
  The executable source lives in src\preload (tools\build-client.ps1).

      run assembly                          write src\main\clipboard.dll
      run assembly -Out dist\clipboard.dll  write it somewhere else

  A failed build only prints a note: the run-time compile still works. The client
  (preload\client.exe) is the other product: packages\cli\client.ps1 builds that one.
#>
param(
  [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
. (Use-Module './utils/console.ps1' $PSCommandPath)
$cli = Join-Path $root 'packages\cli\bin\cli.ps1'
if (-not (Test-Path -LiteralPath $cli)) { Write-Fail ('missing: ' + $cli); exit 1 }

# the sources, the compiler and its flags live in builder.cli.config.ps1 (the Main target): this
# file only knows the command line and what to say when the compiler is missing. The bundle writes
# under out\ and the program reads the dll from src\main, so the copy is part of the step.
$cliArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'packages\module\bin\module.ps1'), $cli, 'bundle', '-Entry', 'Main')
& powershell.exe @cliArgs
$built = Join-Path $root 'out\main\clipboard.dll'
$target = if ($Out) { $Out } else { Join-Path $root 'src\main\clipboard.dll' }
if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $root $target }
if ((Test-Path -LiteralPath $built) -and ($built -ne $target)) {
  $dir = Split-Path -Parent $target
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Copy-Item -LiteralPath $built -Destination $target -Force
}
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $target)) {
  Write-Warn 'clipboard.dll not built; the package compiles the C# at run time'
}
exit 0

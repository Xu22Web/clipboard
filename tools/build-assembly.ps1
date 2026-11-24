#Requires -Version 5.1
<#
  tools\build-assembly.ps1 - compile the type library into src\main\clipboard.dll.

  The assembly is an accelerator, never a requirement: a cold panel open takes 850 ms with it
  against 1050 ms compiling the source (measured, three runs each). The .cs files stay as the
  fallback, and a source file newer than the assembly also falls back (lib\native.ps1,
  Test-NativeAssembly), so a stale dll never wins.

  What the compiler is given is decided in one place: src\main\index.cs lists the sources with
  a #part line each, and the bundler resolves that list (tools\bundler\plugins\50-cs-part.ps1).
  The executable source lives in src\preload (tools\build-client.ps1).

      cli assembly                       write src\main\clipboard.dll
      cli assembly -Out dist\clipboard.dll  write it somewhere else

  A failed build only prints a note: the run-time compile still works. The client
  (preload\client.exe) is the other product: tools\build-client.ps1 builds that one.
#>
param(
  [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'tools\utils\console.ps1')
$bundler = Join-Path $root 'tools\bundler\bundler.ps1'
if (-not (Test-Path -LiteralPath $bundler)) { Write-Fail ('missing: ' + $bundler); exit 1 }

# the list of sources, the compiler and its flags live in the bundler's main entry: this file
# only knows the command line and what to say when the compiler is missing
$bundlerArgs = @('-Entry', 'main')
if ($Out) { $bundlerArgs += @('-Out', $Out) }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bundler @bundlerArgs
if ($LASTEXITCODE -ne 0) {
  Write-Warn 'clipboard.dll not built; the package compiles the C# at run time'
}
exit 0

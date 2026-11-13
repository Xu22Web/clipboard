#Requires -Version 5.1
<#
  tools\build-assembly.ps1 - compile src\lib\assembly\*.cs into lib\assembly\clipboard.dll.

  The assembly is an accelerator, never a requirement: a cold panel open takes 850 ms with it
  against 1050 ms compiling the source (measured, three runs each). The .cs files stay as the
  fallback, and a source file newer than the assembly also falls back (lib\native.ps1,
  Test-NativeAssembly), so a stale dll never wins.

  Every .cs file in src\lib\assembly is compiled, so adding one needs no change here. The
  executable source lives in src\lib\client (tools\build-client.ps1).

      cli assembly                       write src\lib\assembly\clipboard.dll
      cli assembly -Out dist\clipboard.dll  write it somewhere else

  A failed build only prints a note: the run-time compile still works. The client (client.exe)
  is the other product: tools\build-client.ps1 builds that one.
#>
param(
  [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'tools\utils\console.ps1')
. (Join-Path $root 'tools\utils\csc.ps1')
if (-not $Out) { $Out = Join-Path $root 'src\lib\assembly\clipboard.dll' }

$csDir = Join-Path $root 'src\lib\assembly'
$sources = @()
if (Test-Path -LiteralPath $csDir) {
  $sources = @(Get-ChildItem -LiteralPath $csDir -Filter '*.cs' -File | ForEach-Object { $_.FullName })
}
if ($sources.Count -eq 0) { Write-Fail ('no C# sources in ' + $csDir); exit 1 }

$csc = Find-Csc
if (-not $csc) {
  Write-Fail 'no C# compiler found (looked for the .NET Framework 4 csc.exe)'
  Write-Note 'the tool still works without it: the types are compiled at run time'
  exit 1
}

$parent = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

$sw = Start-Step
$cscArgs = @('-nologo', '-optimize+', '-target:library', ('-out:' + $Out),
  '-r:System.Windows.Forms.dll', '-r:System.Drawing.dll') + $sources
$output = & $csc @cscArgs 2>&1
$code = $LASTEXITCODE
if ($code -ne 0 -or -not (Test-Path -LiteralPath $Out)) {
  Write-CscLog $output
  Write-Warn 'clipboard.dll not built; the package compiles the C# at run time'
  exit 0
}

$size = (Get-Item -LiteralPath $Out).Length
Write-Done $sw ($Out + '   ' + [Math]::Round($size / 1024, 1) + ' KB')

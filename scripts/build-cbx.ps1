#Requires -Version 5.1
<#
  scripts\build-cbx.ps1 - compile the optional native client (src\lib\cbx.cs) with the C#
  compiler that ships inside the .NET Framework.

  The tool itself stays pure PowerShell: this executable is an accelerator, and every caller
  falls back to the script when it is missing or refuses (exit code 100).

      cli cbx                       write src\cbx.exe, for a development copy
      cli cbx -Out dist\cbx.exe     write it somewhere else

  Exits 1 with a clear message when no compiler is installed: installing the .NET Framework
  4.x is what provides one, and Windows 10 / 11 have it already.
#>
param(
  [string]$Source = '',
  [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $Source) { $Source = Join-Path $root 'src\lib\cbx.cs' }
if (-not $Out) { $Out = Join-Path $root 'src\cbx.exe' }

if (-not (Test-Path -LiteralPath $Source)) { Write-Host ('[x] missing: ' + $Source); exit 1 }

# the 64-bit compiler first, then the 32-bit one: the client is AnyCPU, so either will do
$csc = ''
foreach ($dir in @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'))) {
  $candidate = Join-Path $dir 'csc.exe'
  if (Test-Path -LiteralPath $candidate) { $csc = $candidate; break }
}
if (-not $csc) {
  Write-Host '[x] no C# compiler found (looked for the .NET Framework 4 csc.exe)'
  Write-Host '    the tool still works without it: the PowerShell client answers the same commands'
  exit 1
}

$parent = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

$cscArgs = @('-nologo', '-optimize+', '-target:exe', ('-out:' + $Out), $Source)
$output = & $csc @cscArgs 2>&1
$code = $LASTEXITCODE
foreach ($line in @($output)) {
  $text = ([string]$line).Trim()
  # the compiler prints a version advisory on every run; it is not a problem report
  if (-not $text -or $text -like '*provided as part of the Microsoft*') { continue }
  Write-Host ('    ' + $text)
}
if ($code -ne 0 -or -not (Test-Path -LiteralPath $Out)) {
  Write-Host ('[x] compile failed (' + $code + ')')
  exit 1
}

$size = (Get-Item -LiteralPath $Out).Length
Write-Host ('[ok] ' + $Out + '   ' + [Math]::Round($size / 1024, 1) + ' KB')

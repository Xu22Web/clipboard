#Requires -Version 5.1
<#
  tools\build-client.ps1 - compile src\lib\client\client.cs into client.exe.

  The client is an accelerator, never a requirement: clipboard.cmd runs it when the file sits
  next to clipboard.ps1 and falls back to the PowerShell path when it is missing or exits 100.
  A machine without the .NET Framework compiler loses about 1 s per command, not a feature.

      cli client                        write src\client.exe
      cli client -Out dist\client.exe    write it somewhere else

  The assembly (lib\assembly\clipboard.dll) is a separate product: tools\build-assembly.ps1
  builds that one.
#>
param(
  [string]$Source = '',
  [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'tools\utils\console.ps1')
. (Join-Path $root 'tools\utils\csc.ps1')
if (-not $Source) { $Source = Join-Path $root 'src\lib\client\client.cs' }
if (-not $Out) { $Out = Join-Path $root 'src\client.exe' }

if (-not (Test-Path -LiteralPath $Source)) { Write-Fail ('missing: ' + $Source); exit 1 }

$csc = Find-Csc
if (-not $csc) {
  Write-Fail 'no C# compiler found (looked for the .NET Framework 4 csc.exe)'
  Write-Note 'the tool still works without it: the PowerShell client answers the same commands'
  exit 1
}

$parent = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

$sw = Start-Step
$cscArgs = @('-nologo', '-optimize+', '-target:exe', ('-out:' + $Out), $Source)
$output = & $csc @cscArgs 2>&1
$code = $LASTEXITCODE
Write-CscLog $output
if ($code -ne 0 -or -not (Test-Path -LiteralPath $Out)) {
  Write-Fail ('compile failed (' + $code + ')')
  exit 1
}

$size = (Get-Item -LiteralPath $Out).Length
Write-Done $sw ($Out + '   ' + [Math]::Round($size / 1024, 1) + ' KB')

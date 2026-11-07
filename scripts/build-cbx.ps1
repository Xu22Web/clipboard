#Requires -Version 5.1
<#
  scripts\build-cbx.ps1 - compile the project's C# with the compiler that ships inside the
  .NET Framework.

  Two products, both optional:

    cbx.exe      the native command-line client (src\lib\cbx.cs), an accelerator: every
                 caller falls back to the script when it is missing or returns 100
    lib\cb.dll   the two C# blocks embedded in src\lib\native.ps1 and
                 src\lib\panel\keyhook.ps1, compiled ahead of time. A cold panel open takes
                 850 ms with the assembly against 1050 ms compiling the source (measured,
                 three runs each); the source stays as the fallback, and a source file
                 newer than the assembly also falls back, so a stale dll never wins.

      cli cbx                       write src\cbx.exe and src\lib\cb.dll
      cli cbx -Out dist\cbx.exe     write the client somewhere else

  Exits 1 with a clear message when no compiler is installed: installing the .NET Framework
  4.x is what provides one, and Windows 10 / 11 have it already. A failure to build the
  assembly only prints a note - the run-time compile still works.
#>
param(
  [string]$Source = '',
  [string]$Out = '',
  [string]$Asm = ''
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

# ---- lib\cb.dll: the two C# blocks, compiled ahead of time ----------------------------------
# lib\native.ps1 and lib\panel\keyhook.ps1 carry their C# as here-strings. The runtime loads
# this assembly when it exists (Test-NativeAssembly) and compiles the source only when it does
# not, so this step failing costs start-up time, never features.
if (-not $Asm) { $Asm = Join-Path $root 'src\lib\cb.dll' }

function Get-CSharpBlock([string]$path, [string]$pattern) {
  $text = [IO.File]::ReadAllText($path)
  $m = [regex]::Match($text, $pattern)
  if (-not $m.Success) { return '' }
  return $m.Groups[1].Value
}

$blockNative = Get-CSharpBlock (Join-Path $root 'src\lib\native.ps1') '(?s)\$cs = @''\r?\n(.*?)\r?\n''@'
$blockHook = Get-CSharpBlock (Join-Path $root 'src\lib\panel\keyhook.ps1') '(?s)Add-Type -TypeDefinition @''\r?\n(.*?)\r?\n''@'
if (-not $blockNative -or -not $blockHook) {
  Write-Host '[!] could not find the C# blocks; the package compiles them at run time'
  exit 0
}

$asmParent = Split-Path -Parent $Asm
if (-not (Test-Path -LiteralPath $asmParent)) { New-Item -ItemType Directory -Path $asmParent -Force | Out-Null }
$asmTmp = Join-Path $env:TEMP ('cbasm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $asmTmp -Force | Out-Null
try {
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  $csNative = Join-Path $asmTmp 'native.cs'
  $csHook = Join-Path $asmTmp 'keyhook.cs'
  [IO.File]::WriteAllText($csNative, $blockNative, $utf8NoBom)
  [IO.File]::WriteAllText($csHook, $blockHook, $utf8NoBom)
  $asmArgs = @('-nologo', '-optimize+', '-target:library', ('-out:' + $Asm),
    '-r:System.Windows.Forms.dll', '-r:System.Drawing.dll', $csNative, $csHook)
  $asmLog = & $csc @asmArgs 2>&1
  $asmCode = $LASTEXITCODE
  if ($asmCode -ne 0 -or -not (Test-Path -LiteralPath $Asm)) {
    foreach ($line in @($asmLog)) {
      $text = ([string]$line).Trim()
      if (-not $text -or $text -like '*provided as part of the Microsoft*') { continue }
      Write-Host ('    ' + $text)
    }
    Write-Host '[!] cb.dll not built; the package compiles the C# at run time'
  } else {
    Write-Host ('[ok] ' + $Asm + '   ' + [Math]::Round((Get-Item -LiteralPath $Asm).Length / 1024, 1) + ' KB')
  }
} finally {
  Remove-Item -LiteralPath $asmTmp -Recurse -Force -ErrorAction SilentlyContinue
}

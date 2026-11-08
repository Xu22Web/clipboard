#Requires -Version 5.1
<#
  cli.ps1 - run a command declared in package.ini.

      cli                 list the commands
      cli <command> ...   run scripts.<command>, passing the remaining arguments on

  cli.cmd and cli (Git Bash / MSYS) call this file; all three read the same package.ini.
  The working directory is set to the project root first, so the command lines in
  package.ini may use paths relative to that folder.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = '',
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
Set-Location -LiteralPath $root
$pkgPath = Join-Path $root 'package.ini'
$iniTools = Join-Path $root 'src\utils'

if (-not (Test-Path -LiteralPath $pkgPath)) {
  Write-Host ('[x] missing: ' + $pkgPath)
  exit 1
}
foreach ($tool in @('ini', 'inifile')) {
  $toolPath = Join-Path $iniTools ($tool + '.ps1')
  if (-not (Test-Path -LiteralPath $toolPath)) {
    Write-Host ('[x] missing: ' + $toolPath)
    exit 1
  }
}
# the repository has one ini layer (src\utils\ini.ps1 + inifile.ps1); the tooling uses it
# too, so a rule cannot hold for clipboard.ini and not for package.ini
. (Join-Path $iniTools 'ini.ps1')
. (Join-Path $iniTools 'inifile.ps1')
$pkgDoc = Import-Ini $pkgPath
$pkg = $pkgDoc.Map
$order = New-Object System.Collections.Generic.List[string]
foreach ($k in @($pkgDoc.Keys)) {
  if ($k -like 'scripts.*') { $order.Add($k.Substring(8)) }
}

# a key may be written inside its section or with the dotted name at the top level
function PkgValue([string]$name) {
  if ($pkg.ContainsKey('package.' + $name)) { return [string]$pkg['package.' + $name] }
  if ($pkg.ContainsKey($name)) { return [string]$pkg[$name] }
  return ''
}$pkgName = PkgValue 'name'
$pkgVersion = PkgValue 'version'

function Show-Commands {
  $title = $pkgName
  if ($pkgVersion) { $title = $title + '@' + $pkgVersion }
  Write-Host $title -ForegroundColor Cyan
  Write-Host ''
  if ($order.Count -eq 0) {
    Write-Host 'no scripts.<name>= lines in package.ini'
    return
  }
  Write-Host 'usage: cli <command> [args]'
  Write-Host ''
  # the command is typed in any case, so the list shows it in lower case
  foreach ($name in $order) {
    Write-Host ('  {0,-8} ' -f $name.ToLowerInvariant()) -NoNewline -ForegroundColor Cyan
    Write-Host ([string]$pkg['scripts.' + $name])
  }
}

$wanted = $Command.ToLower()
if (-not $wanted -or @('help', '-h', '--help', '-?', '/?') -contains $wanted) {
  Show-Commands
  exit 0
}

$line = [string]$pkg['scripts.' + $wanted]
if (-not $line) {
  Write-Host ('[!] unknown command: ' + $Command)
  Write-Host ''
  Show-Commands
  exit 1
}

if ($Rest -and $Rest.Count -gt 0) { $line = $line + ' ' + ($Rest -join ' ') }
# The script gets a PowerShell of its own, and that start plus its first output is a second
# or two of blank terminal. The two lines npm prints before a script runs say what is about to
# happen and what will actually be executed, so the wait is never unexplained; a non-zero exit
# gets a closing line as well, because the script's own output may not make it obvious.
$shown = $wanted
if ($Rest -and $Rest.Count -gt 0) { $shown = $shown + ' ' + ($Rest -join ' ') }
$title = $pkgName
if ($pkgVersion) { $title = $title + '@' + $pkgVersion }
$sw = [Diagnostics.Stopwatch]::StartNew()
# The same two lines npm prints, then a blank line: the header stays quiet and the colour only
# marks the command name, so what the script prints is what the eye lands on.
Write-Host '> ' -NoNewline -ForegroundColor DarkGray
Write-Host $title -NoNewline
Write-Host (' ' + $shown) -ForegroundColor Cyan
Write-Host ('> ' + $line) -ForegroundColor DarkGray
Write-Host ''
$global:LASTEXITCODE = 0
Invoke-Expression $line
$sw.Stop()
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }
if ($code -ne 0) {
  Write-Host ('[x] ' + $shown + ' exited with code ' + $code + ' after ' + [string][int]$sw.Elapsed.TotalSeconds + ' s') -ForegroundColor Red
}
exit $code

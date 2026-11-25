#Requires -Version 5.1
<#
  run.ps1 - run a command declared in package.ini. The role npm plays for package.json.

      run                 list the commands
      run <command> ...   run scripts.<command>, passing the remaining arguments on

  run.cmd and run (Git Bash / MSYS) call this file; all three read the same package.ini.
  The working directory is set to the project root first, so the command lines in
  package.ini may use paths relative to that folder.

  Two shapes of script line, the same two package.json uses. "Build=builder-cli build" names a
  tool a package registers in its Bin=, the way "build": "vite build" names the vite package's
  command. "Shot=powershell -File packages\cli\shot.ps1" names the interpreter and the file, the
  way "shot": "node tools/shot.js" runs a plain script. A line that starts with neither runs as
  written.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = '',
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath

# The cli package's public surface, imported the way a script imports anything. run.cmd and run.sh
# start this file through packages\module\bin\module.ps1, so Use-Module is already there - the
# block below is only for a caller that ran run.ps1 straight from PowerShell.
if (-not (Get-Command -Name 'Use-Module' -CommandType Function -ErrorAction SilentlyContinue)) {
  $moduleMain = Join-Path $root 'packages\module\index.ps1'
  if (-not (Test-Path -LiteralPath $moduleMain)) {
    Write-Host ('[x] missing: ' + $moduleMain)
    exit 1
  }
  . $moduleMain
  $ModuleHostRoot = $root
  . (Join-Path $root 'packages\module\lib\host.ps1')
}
. (Use-Module 'cli/index.ps1' $PSCommandPath)

$code = Invoke-CliCommand -Command $Command -Rest $Rest
exit $code

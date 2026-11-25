# packages\test\index.ps1 - the test package's public surface.
#
# A caller dot-sources this file and calls what package.ini Exports. The driver, the harness and
# the reporter live under tests\ and stay behind it; what a caller can depend on is the shape of
# Invoke-Test.
#
# The suite runs in a process of its own: it starts sandboxes, drives the machine clipboard and
# must be able to fail without taking the caller down with it.
$script:TestHome = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:TestHome) { throw 'test: cannot locate the package folder' }
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $script:TestHome)
$script:Driver = Join-Path $script:RepoRoot 'tests\run.ps1'
$script:ModuleBin = Join-Path $script:RepoRoot 'packages\module\bin'

. (Use-Module './utils/console.ps1' $PSCommandPath)
. (Use-Module './config.ps1' $PSCommandPath)

function Get-TestRoot {
  return $script:TestHome
}

# Run the suite.
#
#   -Unit / -Integration / -E2E   only that group
#   -Part <name>                  one part by name
#   -Source <dir>                 run the command line parts against a packaged copy
#   -Workers <n> / -Serial        fewer parts at a time, or one after another
#   -Reporter <mode>              default | verbose
#   -Bail                         stop starting parts after the first failure
#
# Returns the exit code the driver gave back.
function Invoke-Test {
  param(
    [string[]]$Arguments = @()
  )
  if (-not (Test-Path -LiteralPath $script:Driver)) { throw ('test: missing ' + $script:Driver) }
  # the driver is started by the module layer, the same way a tool is: one process, with the
  # import and export statements in the packages it reads live
  $moduleBin = Join-Path $script:ModuleBin 'module.ps1'
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $moduleBin, $script:Driver)
  foreach ($a in @($Arguments)) { if ([string]$a) { $argv += [string]$a } }
  & powershell.exe @argv | Out-Host
  $code = $LASTEXITCODE
  if ($null -eq $code) { $code = 0 }
  return $code
}

Export-Function Get-TestRoot, Invoke-Test

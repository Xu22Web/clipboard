#Requires -Version 5.1
<#
  clipboard.ps1 - lightweight clipboard history for Windows 10 / 11 (a Win+V replacement).
  Zero dependencies: PowerShell 5.1 + .NET Framework only.

  clipboard migrate | version | serve | ui | config [edit|init] | install | uninstall
  clipboard list [-Count N] | put "text" | get | pick N | del N | clear | pause | resume | status | stop
  clipboard export FILE | import FILE | backup [name] | restore [name]
  Text, file lists (CF_HDROP), pictures and formatted text (HTML / RTF) are captured and
  can be pasted back with their formats.

  Settings are not command line switches: every value, including where the history is
  written, lives in clipboard.ini and is changed with `clipboard config set <key> <value>`.

  This file is the entry point only: parameter binding, the tool root, the module list and
  the runtime paths. The sections follow Electron: main\ runs the program, preload\ carries
  the channel and the window link, renderer\ draws, and shared\ holds the helpers and schemas:

    base -> shared\utils (ini / inifile / schema) -> log / time / format / dpi -> native
         -> media -> clip -> store -> entry -> picker-geom -> anim -> picker
         -> config / serve / shortcut / usage -> dispatch
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = '',
  [Parameter(Position = 1)][string]$Value,
  [Parameter(Position = 2)][string]$Sub,
  [Parameter(Position = 3)][string]$Arg,
  [int]$Count = 0,
  [switch]$Purge,
  [switch]$All,
  [switch]$Media,
  [switch]$Replace,
  [switch]$Library,
  # skip the resident and always run the command in this process (same as CLIPBOARD_NO_PROXY=1)
  [switch]$NoProxy
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSCommandPath

#region modules
# The loader decides what this command reads: it holds the roots (the base layer and the group a
# command can reach), and every module states its own edges with Use-Module. The entry only names
# the two files that get it going - the statement names, and the loader itself.
$loadedModules = @{}
. (Join-Path $Root 'shared\utils\module.ps1')
. (Use-Module 'main/utils/modules')
#endregion

#region runtime paths
# Write location: DataDir= in clipboard.ini, default data (a relative path is relative to
# the script dir). Nothing is written outside that folder (no %LOCALAPPDATA% fallback).
$IniPath = Join-Path $Root 'clipboard.ini'
$iniMap = Read-Ini
# Resolve-StoreDir reads DataDir= out of the ini and makes sure the directory is writable.
# It runs on the one-shot path only: a proxied command never gets this far, and the resident
# resolved its own store once, at start.
$StoreDir = Resolve-StoreDir $Root $iniMap
if (-not $StoreDir) {
  if ($Library) { return }
  Write-Host ('[x] invalid DataDir: ' + [string]$iniMap['DataDir'])
  exit 1
}
# Only the data folder has to be writable; the settings file may live anywhere and is
# never created just because the tool started.
try {
  if (-not (Test-Path -LiteralPath $StoreDir)) { New-Item -ItemType Directory -Path $StoreDir -Force | Out-Null }
  $probe = Join-Path $StoreDir 'p.probe'
  [IO.File]::WriteAllText($probe, 'x')
  Remove-Item -LiteralPath $probe -Force
} catch {
  if ($Library) { return }
  Write-Host ('[x] not writable: ' + $StoreDir)
  Write-Host '    set DataDir=<path> in clipboard.ini to move the write location.'
  Write-Host '    nothing is written to %LOCALAPPDATA% or any other user folder.'
  exit 1
}
$StoreFile = Join-Path $StoreDir 'history.dat'
$Paused    = Join-Path $StoreDir 'paused.flag'
$LogFile   = Join-Path $StoreDir 'clipboard.log'
$Utf8      = New-Object System.Text.UTF8Encoding $false
# which positional arguments were actually passed (an explicit empty value is valid)
$script:BoundParams = $PSBoundParameters
#endregion

try { [Console]::OutputEncoding = $Utf8 } catch { }

# Dot-source mode (the test suite uses it): every function is defined, nothing runs. The
# plugins are loaded by Invoke-Main, so this mode stays a base-tool view.
if ($Library) { return }
$mainArgs = @{
  Command = $Command; Value = $Value; Sub = $Sub; Arg = $Arg; Count = $Count
  Purge = [bool]$Purge; All = [bool]$All; Media = [bool]$Media; Replace = [bool]$Replace
}
try {
  Invoke-Main @mainArgs
} catch {
  # A module this command needed was not in its group. The self tests check the groups against
  # the code, so this is the safety net rather than the plan: load everything once and retry.
  if ($_.Exception -isnot [System.Management.Automation.CommandNotFoundException]) { throw }
  Write-Log ('module group too small for ' + $Command + ': ' + $_.Exception.Message)
  foreach ($g in @('store', 'transfer', 'config', 'panel')) {
    foreach ($m in $groupModules[$g]) {
      if ($requiredModules.Contains($m)) { continue }
      . (Join-Path $Root ($m + '.ps1'))
      $requiredModules.Add($m)
    }
  }
  Invoke-Main @mainArgs
}



#Requires -Version 5.1
<#
  clipboard.ps1 - lightweight clipboard history for Windows 10 / 11 (a Win+V replacement).
  Zero dependencies: PowerShell 5.1 + .NET Framework only.

  clipboard diag | restore | serve | ui | config [edit|init] | install | uninstall
  clipboard list [-Count N] | put "text" | get | pick N | del N | clear | pause | resume | status | stop
  Files copied in Explorer are captured too (CF_HDROP) and can be pasted back.

  Settings are not command line switches: every value, including where the history is
  written, lives in clipboard.ini and is changed with `clipboard config set <key> <value>`.

  This file is the entry point only: parameter binding, the tool root, the module list and
  the runtime paths. The program itself lives under lib\, layer by layer:

    base -> ini -> util / theme-stub -> clip -> store -> entry -> picker-geom -> picker
         -> serve / diag / shortcut / config / usage -> dispatch

  Copy the whole folder, not just this file: every module is required except themes.ps1 and
  plugins.ps1, which degrade to the built-in palette and the base feature set.
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
  [switch]$Library
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSCommandPath
$libDir = Join-Path $Root 'lib'

#region modules
# The tool root is computed here and nowhere else: inside a dot-sourced file $PSScriptRoot
# points at lib\, so a path built there would resolve themes\, plugins\ and data\ one level
# too deep. Only base.ps1 and ini.ps1 assign anything while loading (the defaults and the
# settings schema); the order below matters for those two and is otherwise for readers.
$requiredModules = @(
  'base', 'ini', 'values', 'util', 'theme-stub', 'clip', 'store', 'hotkey', 'entry',
  'picker-geom', 'picker-draw', 'picker', 'serve', 'diag', 'shortcut', 'config', 'usage', 'dispatch'
)
foreach ($module in $requiredModules) {
  $modulePath = Join-Path $libDir ($module + '.ps1')
  if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host ('[x] missing: ' + $modulePath)
    Write-Host '    this build is clipboard.ps1 + lib\ - copy the whole folder.'
    exit 1
  }
  . $modulePath
}
# optional layers: without them the tool runs on the built-in palette and the base commands
$themeModule = Join-Path $libDir 'themes.ps1'
if (Test-Path -LiteralPath $themeModule) { . $themeModule }
# the plugin layer is three files: the runtime, what a mark means, and the settings surface
$pluginModule = Join-Path $libDir 'plugins.ps1'
if (Test-Path -LiteralPath $pluginModule) {
  . $pluginModule
  foreach ($extra in @('plugin-settings', 'plugin-marks')) {
    $extraPath = Join-Path $libDir ($extra + '.ps1')
    if (Test-Path -LiteralPath $extraPath) { . $extraPath }
  }
}
#endregion

#region runtime paths
# Write location: DataDir= in clipboard.ini, else <script dir>\data. Nothing is written
# outside those two folders (no %LOCALAPPDATA% fallback).
$IniPath = Join-Path $Root 'clipboard.ini'
$script:IniCache = Read-Ini
$dataRoot = ''
if ($script:IniCache.ContainsKey('DataDir')) { $dataRoot = [string]$script:IniCache['DataDir'] }
if ($dataRoot) {
  if (-not [IO.Path]::IsPathRooted($dataRoot)) { $dataRoot = Join-Path $Root $dataRoot }
  try {
    $dataRoot = [IO.Path]::GetFullPath($dataRoot).TrimEnd([char]92, [char]47)
    if ($dataRoot -match '^[A-Za-z]:$') { $dataRoot += '\' }
  } catch {
    if ($Library) { return }
    Write-Host ('[x] invalid DataDir: ' + $dataRoot)
    exit 1
  }
}
$StoreDir = if ($dataRoot) { $dataRoot } else { Join-Path $Root 'data' }
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
Invoke-Main -Command $Command -Value $Value -Sub $Sub -Arg $Arg -Count $Count -Purge:$Purge -All:$All

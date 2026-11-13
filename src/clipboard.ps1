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
  the runtime paths. The program itself lives under lib\, with the pure helpers under
  utils\ and the ini schemas under schema\, layer by layer:

    base -> utils (ini / inifile / schema) -> log / time / format / dpi -> native / theme-stub
         -> media -> clip -> store -> entry -> picker-geom -> anim -> picker
         -> config / serve / shortcut / usage -> dispatch

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
  [switch]$Media,
  [switch]$Replace,
  [switch]$Library,
  # skip the resident and always run the command in this process (same as CLIPBOARD_NO_PROXY=1)
  [switch]$NoProxy
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSCommandPath
$libDir = Join-Path $Root 'lib'

#region modules
# The tool root is computed here and nowhere else: inside a dot-sourced file $PSScriptRoot
# points at the folder it lives in (lib\ or utils\), so a path built there would resolve
# themes\, plugins\ and data\ one level too deep. Only base.ps1 and values.ps1 assign
# anything while loading (the defaults and the settings schema); the order below matters for
# those two and is otherwise for readers.
#
# Paths are relative to the tool root, so a module can sit in lib\, in lib\panel\ or in
# utils\. The utils\ files are the pure helpers: utils\ini parses text into a document,
# utils\inifile reads a file once and writes a key back, utils\schema validates a value
# against src\schema\, utils\hash names a file after its content, utils\cfhtml reads and
# rewrites the CF_HTML header.
#
# Only what a command can reach is parsed: compiling a module costs about 20 ms, so `version`
# reads eighteen files, `list` about thirty, and only `ui` / `serve` pay for the panel, the
# palette and the renderers. -Library loads everything, because the tests call those functions
# by name. Everything Invoke-Main does before it reaches a command (the ini, the settings
# schema, the palette stubs, the usage text, the dispatcher) is in the base list, because every
# command pays for it.
$baseModules = @(
  'lib\base',
  'utils\ini', 'utils\inifile', 'utils\schema', 'utils\log', 'utils\time', 'utils\format', 'utils\fileio',
  'utils\hotkey', 'utils\apprules',
  'lib\native', 'lib\theme-stub', 'lib\settings', 'lib\marks', 'lib\ordering', 'lib\config', 'lib\usage', 'lib\dispatch'
)
# one group per job: the files a job can reach, and nothing else. Storing an entry and getting
# it back are one job - the capture pipeline (clip), the payload files (blobs), the image and
# formatted-text sidecars (media, cfhtml) and the paste modifiers all live in it.
$groupModules = @{
  store    = @('utils\hash', 'utils\image', 'utils\cfhtml', 'lib\store', 'lib\entry', 'lib\query', 'lib\select', 'lib\clip', 'lib\media', 'lib\blobs', 'lib\cfhtml', 'lib\modifiers', 'lib\apprules', 'utils\query-words')
  transfer = @('lib\transfer', 'utils\transfer', 'lib\migrate')
  config   = @('lib\config', 'lib\config-template', 'lib\shortcut', 'utils\dpi')
  panel    = @('utils\image', 'lib\panel\media-render', 'lib\panel\anim', 'lib\panel\picker-draw', 'lib\panel\picker-edit', 'lib\panel\pinlist', 'lib\panel\preview', 'lib\panel\focus', 'lib\panel\picker', 'lib\panel\picker-geom', 'lib\serve')
  # the panel size and shape are arithmetic over the metric table: `status` prints them, and no
  # window, palette or renderer is involved
  panelgeom = @('lib\panel\picker-geom')
}
# what each command can reach. A name that is not listed here is a plugin verb: those read and
# write entries, so they get the store group.
$commandGroups = @{
  'version'   = @()
  'status'    = @('store', 'config', 'panelgeom')
  'list'      = @('store')
  'get'       = @('store')
  'put'       = @('store')
  'edit'      = @('store')
  'del'       = @('store')
  'clear'     = @('store')
  'pause'     = @('store')
  'resume'    = @('store')
  'pick'      = @('store')
  'migrate'   = @('store', 'transfer')
  'export'    = @('store', 'transfer')
  'import'    = @('store', 'transfer')
  'backup'    = @('store', 'transfer')
  'restore'   = @('store', 'transfer')
  'config'    = @('config')
  'themes'    = @('config')
  'stop'      = @()
  'install'   = @('config')
  'uninstall' = @('config')
}
$wantGroups = @('store')
if ($Library) { $wantGroups = @('store', 'transfer', 'config', 'panel') }
elseif ($Command -eq '' -or $Command -eq 'ui' -or $Command -eq 'serve') { $wantGroups = @('store', 'config', 'panel') }
elseif ($commandGroups.ContainsKey($Command)) { $wantGroups = @($commandGroups[$Command]) }
$requiredModules = New-Object System.Collections.Generic.List[string]
foreach ($m in $baseModules) { $requiredModules.Add($m) }
foreach ($g in $wantGroups) { foreach ($m in $groupModules[$g]) { $requiredModules.Add($m) } }

#region command proxy
# The resident process has already parsed all of this. When it is up and the command is one
# it may answer, hand the command over: one pipe connect instead of a 2.5 s start. Anything
# unexpected - no resident, an older one, a command that moves settings or the store - falls
# through to the loop below, which is exactly what happened before this block existed. `put`
# with no text on the command line reads stdin here rather than in the dispatcher, so a
# refused attempt can still fall through: by then the pipe is drained, and the process that
# runs the command for real would have seen nothing.
if (-not $Library -and $Command -eq 'put' -and [string]::IsNullOrEmpty($Value)) {
  try { $Value = [Console]::In.ReadToEnd() } catch { $Value = '' }
  $Value = $Value -replace '(\r\n|\n|\r)$', ''
}
$loadedModules = @{}
if (-not $Library -and -not $NoProxy -and $env:CLIPBOARD_NO_PROXY -ne '1') {
  # only the proxy itself: it needs no ini and no path, so the fast path never parses one
  . (Join-Path $Root 'lib\proxy.ps1')
  $loadedModules['lib\proxy'] = $true
  Invoke-ProxyAttempt $Root $commandGroups $Command $Value $Sub $Arg $Count $PSBoundParameters
}
#endregion

foreach ($module in $requiredModules) {
  if ($loadedModules.ContainsKey($module)) { continue }
  $modulePath = Join-Path $Root ($module + '.ps1')
  if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host ('[x] missing: ' + $modulePath)
    Write-Host '    this build is clipboard.ps1 + lib\ + utils\ - copy the whole folder.'
    exit 1
  }
  . $modulePath
}
# optional layers: without them the tool runs on the built-in palette and the base commands
$themeModule = Join-Path $libDir 'themes.ps1'
if (Test-Path -LiteralPath $themeModule) { . $themeModule }
# the plugin layer is three files: the runtime, what a mark means, and the settings surface
$pluginDir = Join-Path $libDir 'plugin'
$pluginModule = Join-Path $pluginDir 'plugins.ps1'
if (Test-Path -LiteralPath $pluginModule) {
  . $pluginModule
  foreach ($extra in @('plugin-settings', 'plugin-marks')) {
    $extraPath = Join-Path $pluginDir ($extra + '.ps1')
    if (Test-Path -LiteralPath $extraPath) { . $extraPath }
  }
}
#endregion

#region runtime paths
# Write location: DataDir= in clipboard.ini, else <script dir>\data. Nothing is written
# outside those two folders (no %LOCALAPPDATA% fallback).
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

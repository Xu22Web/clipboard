# main\utils\modules.ps1 - which modules this command needs, in the order they are read.
#
# The entry file calls this loader and nothing else about modules: it says what the program is
# made of, and how a command reaches the part of it that answers.
#
# A module states its own edges now (`. (Use-Module 'renderer/src/core/draw')`), so the lists
# below are roots rather than manifests: a root is the file a command starts from, and everything
# it imports follows. Loading is one pass over the roots in order, and `Use-Module` answers the
# empty file for anything already claimed - which is what makes a diamond cheap and a cycle
# harmless.
#
# Paths are relative to the tool root, so a module can sit in main\utils\, in
# renderer\src\windows\ or renderer\src\components\, or in shared\utils\. The shared\utils\ files
# are the pure helpers: shared\utils\ini parses text into a document, shared\utils\inifile reads a
# file once and writes a key back, shared\utils\schema validates a value against
# src\shared\schema\, shared\utils\hash names a file after its content, shared\utils\cfhtml reads
# and rewrites the CF_HTML header.
#
# Only what a command can reach is parsed: compiling a module costs about 20 ms, so `version`
# reads eighteen files, `list` about thirty, and only `ui` / `serve` pay for the panel, the
# palette and the renderers. -Library loads everything, because the tests call those functions
# by name. Everything Invoke-Main does before it reaches a command (the ini, the settings
# schema, the palette stubs, the usage text, the dispatcher) is in the base list, because every
# command pays for it.
$baseModules = @(
  'main\utils\base', 'preload\utils\window-host',
  'shared\utils\ini', 'shared\utils\inifile', 'shared\utils\schema', 'shared\utils\log', 'shared\utils\time', 'shared\utils\format', 'shared\utils\fileio',
  'shared\utils\hotkey', 'shared\utils\apprules',
  'main\utils\native', 'renderer\src\utils\theme-stub', 'main\utils\settings', 'main\utils\marks', 'main\utils\ordering', 'renderer\src\utils\text', 'main\utils\config', 'main\utils\usage', 'main\utils\dispatch'
)
# one group per job: the files a job starts from, and nothing else. Storing an entry and getting
# it back are one job - the capture pipeline (clip), the payload files (blobs), the image and
# formatted-text sidecars (media, cfhtml) and the paste modifiers all live in it.
#
# The window layer is its own list because a package carries it as chunks: the bundler resolves
# the three windows, groups the modules by the entries that reach them, and writes
# renderer\manifest.ini beside the files. The build leaves the merged modules out of the copy, and
# a working copy has no manifest, so the same list is loaded module by module - one list, two
# shapes, and nothing to keep in step by hand.
$windowBundle = 'renderer'
$windowModules = @('renderer\src\core\draw', 'renderer\src\utils\tray-draw', 'preload\utils\ipc', 'renderer\src\store\define', 'renderer\src\store\history-store', 'renderer\src\components\media-render', 'renderer\src\utils\anim', 'renderer\src\components\picker-draw', 'renderer\src\components\picker-edit', 'renderer\src\components\pinlist', 'renderer\src\components\preview', 'renderer\src\utils\focus', 'renderer\src\windows\picker', 'renderer\src\components\picker-live', 'renderer\src\core\layout', 'renderer\src\components\widgets', 'renderer\src\core\component', 'renderer\src\core\framework', 'renderer\src\components\views', 'renderer\src\core\setup', 'renderer\src\core\reactive', 'renderer\src\utils\settings-model', 'renderer\src\utils\settings-types', 'renderer\src\utils\settings-vm', 'preload\utils\hotkey-record', 'renderer\src\components\settings-draw', 'renderer\src\components\settings-edit', 'renderer\src\windows\settings', 'renderer\src\windows\tray-menu')
$groupModules = @{
  store    = @('shared\utils\hash', 'shared\utils\image', 'shared\utils\cfhtml', 'main\utils\store', 'main\utils\entry', 'main\utils\query', 'main\utils\select', 'main\utils\clip', 'main\utils\media', 'main\utils\blobs', 'main\utils\cfhtml', 'main\utils\modifiers', 'main\utils\apprules', 'shared\utils\query-words')
  transfer = @('main\utils\transfer', 'shared\utils\transfer', 'main\utils\migrate')
  config   = @('main\utils\config', 'main\utils\config-template', 'main\utils\shortcut', 'shared\utils\dpi')
  # utils\image stays in the store group, and picker-geom in panelgeom: the window layer uses
  # both, but so do `list` and `status`, and a command that opens no window must not load the
  # bundle to get them - they travel as their own files
  panel    = @('main\utils\window', 'shared\utils\image', 'renderer\src\components\picker-geom') + $windowModules + @('main\utils\serve')
  # panelgeom: the arithmetic `status` prints; settings: the palette, the frame helpers and focus
  panelgeom = @('renderer\src\components\picker-geom')
  settings = @('main\utils\window', 'renderer\src\core\draw', 'renderer\src\core\layout', 'renderer\src\components\widgets', 'renderer\src\core\component', 'renderer\src\core\framework', 'renderer\src\components\views', 'renderer\src\core\setup', 'renderer\src\core\reactive', 'renderer\src\utils\settings-model', 'renderer\src\utils\settings-types', 'renderer\src\utils\settings-vm', 'preload\utils\hotkey-record', 'renderer\src\utils\anim', 'renderer\src\components\picker-draw', 'renderer\src\components\picker-geom', 'renderer\src\utils\focus', 'renderer\src\components\settings-draw', 'renderer\src\components\settings-edit', 'renderer\src\windows\settings')
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
  'settings'  = @('config', 'settings')   # the window writes clipboard.ini itself
}
$wantGroups = @('store')
if ($Library) { $wantGroups = @('store', 'transfer', 'config', 'panel') }
elseif ($Command -eq '' -or $Command -eq 'ui' -or $Command -eq 'serve') { $wantGroups = @('store', 'config', 'panel') }
elseif ($commandGroups.ContainsKey($Command)) { $wantGroups = @($commandGroups[$Command]) }
$requiredModules = New-Object System.Collections.Generic.List[string]
foreach ($m in $baseModules) { $requiredModules.Add($m) }
foreach ($g in $wantGroups) { foreach ($m in $groupModules[$g]) { $requiredModules.Add($m) } }
# A package carries the window layer as one file, so the command that opens a window parses one
# file instead of thirty. Which shape is here decides the load, and a command that never opens a
# window does not pay for the bundle.
$bundlePath = Join-Path $Root ($windowBundle + '\app.ps1')
$bundleManifest = Join-Path $Root ($windowBundle + '\manifest.ini')
$bundleCovered = @{}
foreach ($m in $windowModules) { $bundleCovered[[string]$m] = $true }
$bundleLoaded = $false
if ((Test-Path -LiteralPath $bundleManifest) -or (Test-Path -LiteralPath $bundlePath)) {
  foreach ($m in $requiredModules) { if ($bundleCovered.ContainsKey([string]$m)) { $bundleLoaded = $true; break } }
}

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
  # only the proxy itself: it reads src\shared\ipc\channels.ini, the one file that says what may cross
  . (Join-Path $Root 'main\utils\proxy.ps1')
  $loadedModules['main\utils\proxy'] = $true
  Invoke-ProxyAttempt $Root $Command $Value $Sub $Arg $Count $PSBoundParameters
}
#endregion

foreach ($module in $requiredModules) {
  if ($loadedModules.ContainsKey($module)) { continue }
  # the bundle already defines these, and loading a module over it would only cost a parse
  if ($bundleLoaded -and $bundleCovered.ContainsKey([string]$module)) { continue }
  $modulePath = Join-Path $Root ($module + '.ps1')
  if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host ('[x] missing: ' + $modulePath)
    Write-Host '    this build is clipboard.ps1 + main\ + shared\ - copy the whole folder.'
    exit 1
  }
  # recorded before it runs: a module that imports one of the files further down this list must
  # find it already claimed, or the two would load each other forever
  $loadedModules[$module] = $true
  . $modulePath
}
# the window layer as one file, or as the chunks its manifest lists, when the package carries it
if ($bundleLoaded) {
  if (Test-Path -LiteralPath $bundleManifest) { foreach ($one in @(Get-ChunkList $bundleManifest)) { . $one } }
  else { . $bundlePath }
}
# optional layers: without them the tool runs on the built-in palette and the base commands
$themeModule = Join-Path $Root 'renderer\src\utils\themes.ps1'
if (Test-Path -LiteralPath $themeModule) { . $themeModule }
# the plugin layer is three files: the runtime, what a mark means, and the settings surface
$pluginDir = Join-Path $Root 'main\utils\plugin'
$pluginModule = Join-Path $pluginDir 'plugins.ps1'
if (Test-Path -LiteralPath $pluginModule) {
  . $pluginModule
  foreach ($extra in @('plugin-settings', 'plugin-marks')) {
    $extraPath = Join-Path $pluginDir ($extra + '.ps1')
    if (Test-Path -LiteralPath $extraPath) { . $extraPath }
  }
}

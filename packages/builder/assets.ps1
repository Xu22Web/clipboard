# tools\bundler\assets.ps1 - what one file becomes on its way into the package.
#
# cli.ini [copy] Includes says which files a release carries; this table says what happens to
# each of them. One row wins, in declaration order: the first Match that fits the path inside
# the package names the handler, so a new kind of file is a row here and no new branch in the
# build or the watcher.
#
# It lives beside the bundler because it is the same job: an entry turns several modules into
# one file, a handler here turns one source file into the file a package holds. Neither is
# configuration - a release says what to carry in cli.ini, this says how.
#
# A path here is the one the file keeps in the package: "main\utils\base.ps1", "plugins\x.ps1",
# "preload\client.exe". The build maps a source file to that path, the watcher maps it to the
# path under src\ - the same string for everything the program itself carries.

# How a file is handled. 'product' is the only handler that needs a second table (the C# targets
# in builder.cli.config.ps1): a .cs outside a product folder is plain data and travels as it is.
$script:LibraryRules = @(
  @{ Match = 'main\utils\base.ps1'; Handler = 'version' }
  @{ Match = '*.ps1';        Handler = 'script' }
  @{ Match = '*.cmd';        Handler = 'batch' }
  @{ Match = '*.bat';        Handler = 'batch' }
  @{ Match = '*.sh';         Handler = 'shell' }
  @{ Match = '*.ini';        Handler = 'ini' }
  @{ Match = '*.cs';         Handler = 'product' }
  @{ Match = '*';            Handler = 'copy' }
)

# Files outside src\ keep the shape they have under the repository root (docs\ stays docs\).
# The rows here are the exception: they land at the package root, because their callers expect
# them next to the program - a batch helper is started by double-clicking, and %~dp0 has to
# point at clipboard.ps1.
$script:FlattenRules = @(
  'scripts\*'
)

# Folders whose scripts run in a scope of their own: the program loads them by path and calls
# them, so their $script: names are never the ones the dot-sourced modules share. The renamer
# reads this, which is why the folder is named once here rather than in the build.
$script:OwnScopeDirs = @('plugins')

# Does this path lose its folders on the way into the package?
function Test-Flatten([string]$rel) {
  $path = ([string]$rel) -replace '/', '\'
  foreach ($pattern in @($script:FlattenRules)) {
    if ($path -like $pattern) { return $true }
  }
  return $false
}

# the handler for one package path; every path gets one, 'copy' is the fallback
function Get-LibraryHandler([string]$rel) {
  $path = ([string]$rel) -replace '/', '\'
  foreach ($rule in @($script:LibraryRules)) {
    if ($path -like $rule.Match) { return [string]$rule.Handler }
  }
  return 'copy'
}

# every handler name the table can reach, in table order and without repeating one: what a
# test asks for when it checks that each name has a file behind it. 'product' is in the list
# because a .cs row still names one, but it rewrites nothing: the C# targets of
# builder.cli.config.ps1 decide which folder compiles into which file, and the build has already
# taken those files out of this loop.
function Get-AssetHandlerNames {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($rule in @($script:LibraryRules)) {
    $name = [string]$rule.Handler
    if (-not $out.Contains($name)) { $out.Add($name) }
  }
  return $out.ToArray()
}

function Test-OwnScope([string]$rel) {
  $path = ([string]$rel) -replace '/', '\'
  foreach ($d in @($script:OwnScopeDirs)) {
    $prefix = $d.TrimEnd([char]92) + '\'
    if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

# One handler per kind of file, each in its own file under assets\: a table named after the row
# that reaches it, with a Convert script block. A handler may name Next, and then its work is
# a step in front of another one - version patches main\utils\base.ps1 and hands the result to script.
#
# Loading is by name and cached, so a build parses each handler once however many files it
# rewrites. The folder is given, not derived: a dot-sourced module has no idea where its caller
# keeps its things, and guessing is how a path silently points one level off.
$script:AssetDir = ''
$script:AssetHandlers = @{}

function Initialize-AssetHandlers([string]$dir) {
  $script:AssetDir = [string]$dir
  $script:AssetHandlers = @{}
}

function Get-AssetHandler([string]$name) {
  $key = [string]$name
  if ($script:AssetHandlers.ContainsKey($key)) { return $script:AssetHandlers[$key] }
  if (-not $script:AssetDir) { throw 'no handler folder: call Initialize-AssetHandlers first' }
  $file = Join-Path $script:AssetDir ($key + '.ps1')
  if (-not (Test-Path -LiteralPath $file)) { throw ('no handler named ' + $key + ': ' + $file) }
  $table = . $file
  if ($null -eq $table -or -not $table.ContainsKey('Convert')) {
    throw ('handler ' + $file + ' answers no table with a Convert block')
  }
  # the name inside the file has to be the name that found it, or a row points at a lie
  if ([string]$table.Name -ne $key) { throw ('handler ' + $file + ' calls itself ' + $table.Name + ', not ' + $key) }
  $script:AssetHandlers[$key] = $table
  return $table
}

# Rewrite one file. $ctx carries the read paths, the write path, the two switches and the maps
# the renamer works from; whatever the chain answers is a count of bytes and an optional row.
function Invoke-AssetConvert($ctx) {
  $name = [string]$ctx.Handler
  $result = $null
  $hops = 0
  while ($name) {
    $hops++
    if ($hops -gt 4) { throw ('handler chain too long at ' + [string]$ctx.Rel) }
    $handler = Get-AssetHandler $name
    $result = & $handler.Convert $ctx
    if (-not $handler.ContainsKey('Next')) { return $result }
    $name = [string]$handler.Next
  }
  return $result
}

Export-Function Get-AssetHandler, Get-AssetHandlerNames, Get-LibraryHandler, Initialize-AssetHandlers, Invoke-AssetConvert, Test-Flatten, Test-OwnScope

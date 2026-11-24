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
# A path here is the one the file keeps in the package: "lib\base.ps1", "plugins\x.ps1",
# "preload\client.exe". The build maps a source file to that path, the watcher maps it to the
# path under src\ - the same string for everything the program itself carries.

# How a file is handled. 'product' is the only handler that needs a second table (products.ps1):
# a .cs outside a product folder is plain data and travels as it is.
$script:LibraryRules = @(
  @{ Match = 'lib\base.ps1'; Handler = 'version' }
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

function Test-OwnScope([string]$rel) {
  $path = ([string]$rel) -replace '/', '\'
  foreach ($d in @($script:OwnScopeDirs)) {
    $prefix = $d.TrimEnd([char]92) + '\'
    if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

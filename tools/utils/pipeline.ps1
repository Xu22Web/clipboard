# tools\utils\pipeline.ps1 - what the build and the watcher do with a file.
#
# One table decides everything, in order of precedence: the first row whose Match fits the path
# inside the package says how the file is rewritten. The two tools only ask this module, so a
# new file kind or a new special file is a row here and no new branch anywhere else.
#
# A path here is the one the file keeps in the package: "lib\base.ps1", "plugins\x.ps1",
# "client.exe". The build maps a source file to that path, the watcher maps it to the path
# under src\ - the same string for everything the program itself carries.

# How a file is handled. The handlers are named after what they do, and 'product' is the only
# one that needs the second table (a .cs outside a product folder is plain data).
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

# A folder whose C# is compiled into one file. Dir is the package folder, Ext the suffix of the
# sources that belong to it, Script the compiler, Out where the product lands in the package,
# Required whether a package without it cannot start.
$script:Products = @(
  @{ Dir = 'lib\client'; Ext = '.cs'; Script = 'tools\build-client.ps1'; Out = 'client.exe'; Label = 'client.exe'; Required = $false }
  @{ Dir = 'lib\assembly'; Ext = '.cs'; Script = 'tools\build-assembly.ps1'; Out = 'lib\assembly\clipboard.dll'; Label = 'lib\assembly\clipboard.dll'; Required = $true }
)

# Files outside src\ keep the shape they have under the repository root (docs\ stays docs\).
# The rows here are the exception: they land at the package root, because their callers expect
# them next to the program - a batch helper is started by double-clicking, and %~dp0 has to
# point at clipboard.ps1.
$script:FlattenRules = @(
  'scripts\*'
)

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

# the product a source file belongs to, or $null when it belongs to none
function Get-ProductFor([string]$rel) {
  $path = ([string]$rel) -replace '/', '\'
  foreach ($p in @($script:Products)) {
    $prefix = $p.Dir.TrimEnd([char]92) + '\'
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if ($path -like ('*' + $p.Ext)) { return $p }
  }
  return $null
}

# every declared product, in declaration order
function Get-ProductList {
  return @($script:Products)
}

# Folders whose scripts run in a scope of their own: the program loads them by path and calls
# them, so their $script: names are never the ones the dot-sourced modules share. A folder is
# named once, here, for the same reason the rest of this file exists.
$script:OwnScopeDirs = @('plugins')

function Test-OwnScope([string]$rel) {
  $path = ([string]$rel) -replace '/', '\'
  foreach ($d in @($script:OwnScopeDirs)) {
    $prefix = $d.TrimEnd([char]92) + '\'
    if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

# a file's path under src\, the coordinate this module speaks; '' for a file outside the tree
function Get-SourceRel([string]$srcRoot, [string]$file) {
  $full = [IO.Path]::GetFullPath($file)
  $rootFull = [IO.Path]::GetFullPath($srcRoot).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return '' }
  return $full.Substring($rootFull.Length)
}

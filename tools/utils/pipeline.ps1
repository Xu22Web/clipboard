# tools\utils\pipeline.ps1 - what the build and the watcher do with a file.
#
# One table decides everything, in order of precedence: the first row whose Match fits the path
# inside the package says how the file is rewritten. The two tools only ask this module, so a
# new file kind or a new special file is a row here and no new branch anywhere else.
#
# A path here is the one the file keeps in the package: "lib\base.ps1", "plugins\x.ps1",
# "preload\client.exe". The build maps a source file to that path, the watcher maps it to the
# path under src\ - the same string for everything the program itself carries.

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

# A folder whose C# is compiled into one file. Dir is the package folder (or a comma separated
# list of them, since one product can be built from more than one tree), Ext the suffix of the
# sources that belong to it, Entry the cli.ini entry that compiles it, Out where the product
# lands in the package, Required whether a package without it cannot start.
#
# Out is read twice: as the package path and, under src\, as the path the compiler writes. One
# string for both is why a product never needs a mapping table of its own - and why the two
# names below are shaped like the folders Electron divides a program into.
#
# Entry names the compile command; this table never runs a compiler. `cli bundle -Entry <name>`
# compiles it (tools\bundler\plugins\60-cs-compile.ps1), so the compiler and its flags live in
# one place and neither the build nor the watcher knows what a .cs costs to build.
$script:Products = @(
  @{ Dir = 'preload'; Ext = '.cs'; Entry = 'client'; Out = 'preload\client.exe'; Label = 'preload\client.exe'; Required = $false }
  @{ Dir = 'main'; Ext = '.cs'; Entry = 'main'; Out = 'main\clipboard.dll'; Label = 'main\clipboard.dll'; Required = $true }
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

# the product a source file belongs to, or $null when it belongs to none. A product may name
# more than one folder, so a tree that is being split across folders can still be one product.
function Get-ProductFor([string]$rel) {
  $path = ([string]$rel) -replace '/', '\'
  foreach ($p in @($script:Products)) {
    if ($path -notlike ('*' + $p.Ext)) { continue }
    foreach ($one in @(([string]$p.Dir) -split '[,;]')) {
      $dir = $one.Trim()
      if (-not $dir) { continue }
      $prefix = $dir.TrimEnd([char]92) + '\'
      if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $p }
    }
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

# Compile one product into src\. The command is the cli.ini entry the table names, run by the
# bundler, so neither the build nor the watcher knows how C# is compiled or what flags it wants.
# A product that could not be built is not an error here: the caller decides what a missing
# product means - the build lets its sources travel, the watcher waits for the next save.
function Invoke-ProductBuild($product, [string]$bundler, [string]$srcRoot) {
  $out = Join-Path $srcRoot ([string]$product.Out)
  $parent = Split-Path -Parent $out
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  $log = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bundler -Entry ([string]$product.Entry) -Out $out 2>&1
  return @{
    Ok  = (Test-Path -LiteralPath $out)
    Out = $out
    Log = @($log)
  }
}

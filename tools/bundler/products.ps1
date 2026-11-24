# tools\bundler\products.ps1 - a folder of C# that becomes one file.
#
# A product is the C# half of a release: the files under one source folder are compiled into a
# single dll or exe by an entry cli.ini declares. This table says which folders those are and
# where each product lands; it never runs a compiler - `cli bundle -Entry <name>` does, so the
# compiler and its flags stay in one place (plugins\60-cs-compile.ps1) and neither the build
# nor the watcher knows what a .cs costs to build.
#
# Dir    the source folder, as a package path (a comma separated list when one product is built
#        from more than one tree), Ext the suffix of the sources that belong to it, Entry the
#        cli.ini entry that compiles it, Out where it lands, Required whether a package without
#        it cannot start.
#
# Out is read twice: as the package path and, under src\, as the path the compiler writes. One
# string for both is why a product needs no mapping table of its own - and why the two names
# are shaped like the folders Electron divides a program into.
$script:Products = @(
  @{ Dir = 'preload'; Ext = '.cs'; Entry = 'client'; Out = 'preload\client.exe'; Label = 'preload\client.exe'; Required = $false }
  @{ Dir = 'main'; Ext = '.cs'; Entry = 'main'; Out = 'main\clipboard.dll'; Label = 'main\clipboard.dll'; Required = $true }
)

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

# Compile one product into src\. The command is the cli.ini entry the table names, run by the
# bundler. A product that could not be built is not an error here: the caller decides what a
# missing product means - the build lets its sources travel, the watcher waits for the next save.
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

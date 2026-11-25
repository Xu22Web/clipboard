# packages\module\index.ps1 - the module layer's public surface.
#
# A caller dot-sources this file and uses what package.ini Exports. Everything under lib\ stays
# behind it: specifiers, the two-pass graph, the folded export set and the order.
#
#   Resolve-ModuleSpecifier  one import line to one file, or to the problem that stops it
#   Get-ModuleGraph          the files an entry needs, dependencies first, entry last
#   Get-ModuleOrder          the same list ready to load, cached by write time
#   Get-ModuleDiagnostics    every row one entry would report, with file and line
#   Resolve-ModuleExports    what each module finally exports (forward, all, default)
#   New-ModuleMeta           import.meta for one file
#   Get-ModuleLoadNote       why the caller does the dot-source itself
#   Test-ModuleSpecifiers    missing modules and exports naming nothing
#
# Loading is one line at the entry's top level:
#
#     foreach ($module in Get-ModuleOrder $PSCommandPath $root $alias) { . $module }
#
# and import.meta is the same two lines before it:
#
#     $script:ModuleMeta = New-ModuleMeta $module $root
#     . $module
#
# A dot-source inside a function defines its names in that function, so no loader here can load
# on the caller's behalf - the order is the part that can be shared.
$script:ModuleHome = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:ModuleHome) { throw 'module: cannot locate the package folder' }
$script:ModuleRoot = Split-Path -Parent (Split-Path -Parent $script:ModuleHome)

. (Join-Path $script:ModuleHome 'lib\specifier.ps1')
. (Join-Path $script:ModuleHome 'lib\graph.ps1')
. (Join-Path $script:ModuleHome 'lib\exports.ps1')
. (Join-Path $script:ModuleHome 'lib\order.ps1')

function Get-ModuleHome {
  return $script:ModuleHome
}

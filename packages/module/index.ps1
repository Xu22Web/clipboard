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
#   Get-ModulePathKind       'script' / 'ini' / '' - the suffix decides
#   Read-ModuleData          an ini file as nested tables
#
# The pairing is the one a JavaScript project already has: .ps1 is the code module and plays the
# part ts and js play, .ini is the data module and plays the part json plays.
#
#     . (Use-Module './b.ps1' $PSCommandPath)             code: the file runs in this scope
#     $conf = Use-Module './settings.ini' $PSCommandPath  data: the import answers the value
#     $conf.package.Name
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
. (Join-Path $script:ModuleHome 'lib\data.ps1')
. (Join-Path $script:ModuleHome 'lib\graph.ps1')
. (Join-Path $script:ModuleHome 'lib\exports.ps1')
. (Join-Path $script:ModuleHome 'lib\order.ps1')

function Get-ModuleHome {
  return $script:ModuleHome
}

# A caller that dot-sources this package without a run in front of it - a test part, an old script -
# still has to find the two statement names, because every module file calls them at its own top
# level. The run itself puts a richer pair in place first (see bin\module.ps1); these are the same
# pair with no root and no load cache.
if (-not (Get-Command -Name 'Export-Function' -CommandType Function -ErrorAction SilentlyContinue)) {
  function Export-Function { }
}
if (-not (Get-Command -Name 'Use-Module' -CommandType Function -ErrorAction SilentlyContinue)) {
  $ModuleHostRoot = ''
  . (Join-Path $script:ModuleHome 'lib\host.ps1')
}

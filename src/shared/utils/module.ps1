# shared\utils\module.ps1 - the two statements a module file writes, for the running program.
#
# This is the small half of packages\module: a module names its edges in code, and the names it
# offers, so nothing has to keep a hand-written list in step with the files.
#
#     . (Use-Module 'renderer/src/core/draw')
#     Export-Function New-UiBox, Get-UiBox
#
# The caller is the one that dot-sources: `Use-Module` answers a path and the leading `.` runs the
# file in this scope. Only ids are accepted here - a specifier is a path under the tool root
# without its extension, which is what a module id has always been in this program.
#
# Three cases come back as an empty file instead of a path:
#
#   already loaded   a diamond is the normal shape of the window layer, and a cycle is not an
#                    error: the id is recorded BEFORE the path is answered, so the second visit
#                    stops at an empty file instead of recursing
#   in the bundle    a package carries the window layer as chunks, so the file the id names is not
#                    there any more; the chunk already defines it
#   not present      the theme file and the plugin layer are optional, and a command that runs
#                    without them must not fail on an import
#
# The variables it reads ($Root, $loadedModules, $bundleLoaded, $bundleCovered) belong to the
# entry: a function reads its definition scope, so they are found without being passed.
$ModuleStub = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'module-stub.ps1'

function Use-Module {
  param($Spec)
  $id = ([string]$Spec).Trim() -replace '/', '\'
  if (-not $id) { throw 'import: empty specifier' }
  $key = ([string]$id).ToLowerInvariant()

  # asked once per process: record before answering, so a cycle lands here on its second visit
  if ($loadedModules.ContainsKey($key)) { return $ModuleStub }
  $loadedModules[$key] = $true

  if ($bundleLoaded -and $bundleCovered.ContainsKey($key)) { return $ModuleStub }
  $file = Join-Path $Root ($id + '.ps1')
  if (-not (Test-Path -LiteralPath $file)) { return $ModuleStub }
  return $file
}

# A declaration, not an action: what a module offers is read from the syntax tree by the bundler
# (`Get-BundleDirectives`), which is also what checks the claim. The name has to exist because the
# file that carries the line calls it.
function Export-Function { }

Export-Function Use-Module, Export-Function

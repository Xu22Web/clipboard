# packages\module\lib\host.ps1 - the two statements, for the length of one process.
#
# A dot-source runs a file in the scope that writes the line, so an import only needs an answer to
# "which file": `. (Use-Module './b' $PSCommandPath)` puts b's functions beside a's code. This file
# supplies that answer and the export declaration the other half of a module writes.
#
# It is dot-sourced at the top of a script's own scope, never inside a function: a function body
# that defines Use-Module hands the name back when it returns, which is the same reason a loader
# cannot dot-source for its caller. The host sets two variables first:
#
#     $ModuleHostRoot = <the repository root, or '' when there is none>
#     . <module package>\lib\host.ps1
#
# A file is handed back once per process. Two modules that both import a third one are the normal
# shape of a package, and re-running that third file would redo whatever it does at the top - the
# same reason a JavaScript runtime keeps a module record. The second call gets an empty file, so
# `. (Use-Module ...)` still has something to dot-source and does nothing.
if (-not (Get-Variable -Name 'ModuleHostRoot' -Scope Local -ErrorAction SilentlyContinue)) {
  $ModuleHostRoot = ''
}
$ModuleLoadCache = @{}
$ModuleStub = Join-Path $env:TEMP ('module-empty-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
[IO.File]::WriteAllText($ModuleStub, '', (New-Object System.Text.UTF8Encoding $false))

# Use-Module answers an import. A script answers a path, because the dot-source in front of the
# call runs the file in the caller's own scope; a data file (ini, json) answers the value itself,
# because there is nothing to run:
#
#     . (Use-Module './b.ps1' $PSCommandPath)              a module
#     $conf = Use-Module './settings.ini' $PSCommandPath   a document
#
# -Caller is the file that wrote the line; -Root overrides the host's root for a specifier that
# needs one.
function Use-Module {
  param($Spec, $Caller = '', $Root = '', [string[]]$Named = @())
  if (-not $Caller) { $Caller = $PSCommandPath }
  if (-not $Root) { $Root = $ModuleHostRoot }
  $ref = Resolve-ModuleSpecifier ([string]$Spec) ([string]$Caller) $Root
  if ($ref.Problem) { throw ('import ' + $Spec + ': ' + $ref.Problem) }
  if ($ref.PathKind -eq 'ini') { return (Read-ModuleData $ref.Path) }
  $key = ([string]$ref.Path).ToLowerInvariant()
  if ($ModuleLoadCache.ContainsKey($key)) { return $ModuleStub }
  $ModuleLoadCache[$key] = $true
  return $ref.Path
}

# A declaration, not an action: the set it describes is read from the syntax tree before the run
# and is what `module -Check` reports on. It has to exist because the file that carries the line
# calls it.
function Export-Function { }

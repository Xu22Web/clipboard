# packages\module\lib\order.ps1 - the load order, and why it is only an order.
#
# A dot-source in PowerShell is textual: the module's functions land in the scope that runs it.
# Inside a function that scope is the function, and the definitions are gone when it returns -
# so a loader cannot dot-source on the caller's behalf. What it can do is answer, exactly, in
# which order the caller has to load the files, and that is what this file provides.
#
# The entry uses it at its own top level:
#
#     foreach ($module in Get-ModuleOrder $PSCommandPath $root $alias) { . $module }
#
# which is the one line that replaces a written module list. #@export stays a check for the build
# and for Test-ModuleSpecifiers: PowerShell has no module object to enforce it at run time.
$script:ModuleLoadNote = 'the caller dot-sources the order itself: a dot-source inside a function stays in that function'

# The files an entry needs, dependencies first, the entry last. Missing imports are reported as
# warnings and skipped, so a source tree with one broken line still starts and says which line.
function Get-ModuleOrder([string]$entry, [string]$root, $alias = $null, [string[]]$Exclude = @()) {
  $graph = Get-ModuleGraph $entry $root $alias
  $skip = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  foreach ($one in @($Exclude)) {
    if (-not $one) { continue }
    [void]$skip.Add(([IO.Path]::GetFullPath([string]$one)).ToLowerInvariant())
  }
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($file in @($graph.Order)) {
    $full = [IO.Path]::GetFullPath([string]$file)
    if ($skip.Contains($full.ToLowerInvariant())) { continue }
    $out.Add($full)
  }
  foreach ($one in @($graph.Missing)) { Write-Warning ('import: ' + $one) }
  return $out.ToArray()
}

# The sentence a caller gets when it asks why the loader does not load for it.
function Get-ModuleLoadNote {
  return $script:ModuleLoadNote
}

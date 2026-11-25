# packages\module\lib\exports.ps1 - what one entry's modules finally export.
#
# The statements a module writes are only half the answer: a module may forward another one
# ('-From'), take everything another one exports ('-All -From'), or mark one name as the default.
# This file folds those into one table per module, and reports the three ways the set can be
# wrong - a forwarded name the source does not export, two modules exporting one name, and a
# default naming a function the module does not define. Every row carries the line that wrote it.
#
# The fold runs three passes so a chain of re-exports resolves whatever order the files are read
# in; a fourth pass would only repeat the third. Two modules exporting one name is reported under
# Duplicates and is not a Problem: both are dot-sourced into one scope and the later one wins.
function Resolve-ModuleExports($graph, [string]$root, $alias = $null, [string[]]$Conditions = @()) {
  $problems = New-Object System.Collections.Generic.List[string]
  $byId = @{}
  foreach ($node in @($graph.Nodes)) { $byId[([string]$node.Id).ToLowerInvariant()] = $node }

  $own = @{}
  $default = @{}
  foreach ($node in @($graph.Nodes)) { $own[([string]$node.Id).ToLowerInvariant()] = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase) }

  for ($pass = 0; $pass -lt 3; $pass++) {
    foreach ($node in @($graph.Nodes)) {
      $key = ([string]$node.Id).ToLowerInvariant()
      foreach ($one in @($node.Statements.Exports)) {
        $line = [int]$one.Line
        $spec = [string]$one.From
        if ($spec) {
          $ref = Resolve-ModuleSpecifier (Expand-ModuleAlias $spec $alias) ([string]$node.Path) $root $Conditions
          if ($ref.Problem) {
            $problems.Add(('{0}:{1} re-exports from {2} ({3})' -f (Split-Path -Leaf $node.Path), $line, $spec, $ref.Problem))
            continue
          }
          $fromId = (Get-ModuleId $root $ref.Path).ToLowerInvariant()
          if (-not $own.ContainsKey($fromId)) {
            $problems.Add(('{0}:{1} re-exports from {2}, which the entry does not carry' -f (Split-Path -Leaf $node.Path), $line, $spec))
            continue
          }
          if ([bool]$one.All) {
            foreach ($name in $own[$fromId]) { [void]$own[$key].Add([string]$name) }
            if ($default.ContainsKey($fromId) -and -not $default.ContainsKey($key)) { $default[$key] = $default[$fromId] }
            continue
          }
          foreach ($name in @($one.Names)) {
            if ($pass -eq 2 -and -not $own[$fromId].Contains([string]$name)) {
              $problems.Add(('{0}:{1} re-exports {2}, which {3} does not export' -f (Split-Path -Leaf $node.Path), $line, $name, $spec))
              continue
            }
            [void]$own[$key].Add([string]$name)
          }
          continue
        }
        foreach ($name in @($one.Names)) { [void]$own[$key].Add([string]$name) }
        if ($one.Default) { $default[$key] = [string]$one.Default }
      }
    }
  }

  $exported = @{}
  $duplicates = New-Object System.Collections.Generic.List[string]
  foreach ($node in @($graph.Nodes)) {
    $key = ([string]$node.Id).ToLowerInvariant()
    foreach ($name in $own[$key]) {
      if ($exported.ContainsKey($name)) {
        $duplicates.Add(('{0} is exported by both {1} and {2}' -f $name, $exported[$name], $node.Id))
      } else {
        $exported[$name] = [string]$node.Id
      }
    }
  }

  # Two modules exporting one name is not an error: both are dot-sourced into one scope and the
  # later one wins, which is how the repository's own tables already work. It is reported, it is
  # not refused - only the rows in Problems are.
  return @{ Own = $own; Default = $default; Exported = $exported; Problems = $problems.ToArray(); Duplicates = $duplicates.ToArray() }
}

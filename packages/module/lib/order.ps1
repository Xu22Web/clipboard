# packages\module\lib\order.ps1 - the load order, with a cache, and the meta a module can read.
#
# A dot-source in PowerShell is textual: the module's functions land in the scope that runs it.
# Inside a function that scope is the function, and the definitions are gone when it returns -
# so a loader cannot dot-source on the caller's behalf. What it can do is answer, exactly, in
# which order the caller has to load the files:
#
#     foreach ($module in Get-ModuleOrder $PSCommandPath $root $alias) { . $module }
#
# The cache is keyed by path and write time, so a watcher re-reads only the files that changed
# and a rebuild pays for one parse per module, not one per entry.
$script:ModuleLoadNote = 'the caller dot-sources the order itself: a dot-source inside a function stays in that function'
$script:ModuleGraphCache = @{}

function Get-ModuleOrder([string]$entry, [string]$root, $alias = $null, [string[]]$Conditions = @(), [string[]]$Exclude = @(), [switch]$NoCache) {
  $key = ([string]$entry).ToLowerInvariant()
  if ($NoCache -or -not (Test-Path -LiteralPath $entry)) { $script:ModuleGraphCache.Remove($key) }
  $stamp = ''
  if (-not $NoCache -and (Test-Path -LiteralPath $entry)) { $stamp = (Get-Item -LiteralPath $entry).LastWriteTimeUtc.Ticks.ToString() }
  $graph = $null
  $cached = $null
  if (-not $NoCache -and $stamp -and $script:ModuleGraphCache.ContainsKey($key) -and $script:ModuleGraphCache[$key].Stamp -eq $stamp) {
    $graph = $script:ModuleGraphCache[$key].Graph
    $cached = $script:ModuleGraphCache[$key]
  } else {
    $graph = Get-ModuleGraph $entry $root $alias $Conditions
    if ($stamp) {
      $cached = @{ Stamp = $stamp; Graph = $graph; Order = $null }
      $script:ModuleGraphCache[$key] = $cached
    }
  }
  foreach ($one in @($graph.Missing)) { Write-Warning ('import: ' + $one) }

  # a caller with nothing to skip gets the list the last call built, so the answer is one array
  # per entry for as long as the files it came from are unchanged
  if (@($Exclude).Count -eq 0 -and $null -ne $cached -and $null -ne $cached.Order) { return $cached.Order }

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
  $answer = $out.ToArray()
  if (@($Exclude).Count -eq 0 -and $null -ne $cached) { $cached.Order = $answer }
  return $answer
}

# The sentence a caller gets when it asks why the loader does not load for it.
function Get-ModuleLoadNote {
  return $script:ModuleLoadNote
}

# import.meta: what a module may know about itself. Written before the file is dot-sourced, so a
# module reads $script:ModuleMeta instead of guessing from $MyInvocation.
function New-ModuleMeta([string]$path, [string]$root) {
  $full = [IO.Path]::GetFullPath($path)
  return @{
    Path = $full
    Id   = (Get-ModuleId $root $full)
    Root = $root
    Dir  = (Split-Path -Parent $full)
  }
}

# One entry, everything it would report, folded into one list: the graph's own rows (a missing
# file, a cycle), the export set's rows (a forwarded name that is not there), and a statement
# naming a function the file does not define. Two modules exporting one name is reported by
# Resolve-ModuleExports separately and is not repeated here.
function Get-ModuleDiagnostics([string]$entry, [string]$root, $alias = $null, [string[]]$Conditions = @()) {
  $graph = Get-ModuleGraph $entry $root $alias $Conditions
  $problems = New-Object System.Collections.Generic.List[string]
  foreach ($one in @($graph.Missing)) { $problems.Add($one) }
  foreach ($one in @($graph.Cycles)) { $problems.Add($one) }

  foreach ($node in @($graph.Nodes)) {
    # the function names came out of the same syntax-tree walk that found the edges: parsing the
    # file a second time only to list them again was the most expensive thing this pass did
    $set = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($node.Statements.Defined)) { [void]$set.Add([string]$f) }
    foreach ($one in @($node.Statements.Exports)) {
      # only named exports: `-All` is a star re-export and `-Default` names one export the whole
      # program leans on - both hide which names a module really offers
      if ([bool]$one.All) {
        $problems.Add(('{0}:{1} re-exports everything; name each export' -f (Split-Path -Leaf $node.Path), [int]$one.Line))
      }
      if ([string]$one.Default) {
        $problems.Add(('{0}:{1} marks {2} as the default export; name every export instead' -f (Split-Path -Leaf $node.Path), [int]$one.Line, $one.Default))
      }
      if ($one.From) { continue }
      foreach ($name in @($one.Names)) {
        if (-not $set.Contains([string]$name)) {
          $problems.Add(('{0}:{1} exports {2}, which it does not define' -f (Split-Path -Leaf $node.Path), [int]$one.Line, $name))
        }
      }
      if ($one.Default -and -not $set.Contains([string]$one.Default)) {
        $problems.Add(('{0}:{1} defaults to {2}, which it does not define' -f (Split-Path -Leaf $node.Path), [int]$one.Line, $one.Default))
      }
    }
  }

  $folded = Resolve-ModuleExports $graph $root $alias $Conditions
  foreach ($one in @($folded.Problems)) { $problems.Add($one) }

  # Two checks on the import lines, both needing the export set: a named import has to name
  # something the target exports (a rename on one side would otherwise only surface at run time),
  # and a bare import may not reach a name of the target without naming it - that is the star
  # import this program does not allow. A bare import that uses nothing stays: it is the
  # side-effect form.
  foreach ($node in @($graph.Nodes)) {
    foreach ($use in @($node.Statements.Uses)) {
      $ref = Resolve-ModuleSpecifier (Expand-ModuleAlias ([string]$use.Spec) $alias) ([string]$node.Path) $root $Conditions
      if ($ref.Problem) { continue }
      $fromKey = (Get-ModuleId $root $ref.Path).ToLowerInvariant()
      if (-not $folded.Own.ContainsKey($fromKey)) { continue }
      $named = @($use.Named)
      if ($named.Count -gt 0) {
        foreach ($name in $named) {
          if (-not $folded.Own[$fromKey].Contains([string]$name)) {
            $problems.Add(('{0}:{1} imports {2}, which {3} does not export' -f (Split-Path -Leaf $node.Path), [int]$use.Line, $name, $use.Spec))
          }
        }
        continue
      }
      $hit = New-Object System.Collections.Generic.List[string]
      foreach ($name in @($node.Statements.Calls)) {
        if ($folded.Own[$fromKey].Contains([string]$name)) { $hit.Add([string]$name) }
      }
      if ($hit.Count -gt 0) {
        $problems.Add(('{0}:{1} imports {2} whole; name what it uses with -Named ({3})' -f (Split-Path -Leaf $node.Path), [int]$use.Line, [string]$use.Spec, (@($hit | Sort-Object) -join ', ')))
      }
    }
  }
  return $problems.ToArray()
}

# The name the older callers use for the same answer.
function Test-ModuleSpecifiers([string]$entry, [string]$root, $alias = $null, [string[]]$Conditions = @()) {
  return (Get-ModuleDiagnostics $entry $root $alias $Conditions)
}

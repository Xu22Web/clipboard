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
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile([string]$node.Path, [ref]$tokens, [ref]$errors)
    $set = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
      [void]$set.Add([string]$f.Name)
    }
    foreach ($one in @($node.Statements.Exports)) {
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
  return $problems.ToArray()
}

# The name the older callers use for the same answer.
function Test-ModuleSpecifiers([string]$entry, [string]$root, $alias = $null, [string[]]$Conditions = @()) {
  return (Get-ModuleDiagnostics $entry $root $alias $Conditions)
}

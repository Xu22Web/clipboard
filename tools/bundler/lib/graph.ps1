#Requires -Version 5.1
<#
  tools\bundler\lib\graph.ps1 - which function definitions a bundle still needs.

  PowerShell has no module exports, so reachability is the only honest answer: a definition is
  kept when the runtime could reach it. The roots are the statements that run at load time
  (every module's top-level statements, which is exactly what dot-sourcing runs today) and the
  functions named by Keep. An edge is a call by name.

  A module that calls through a variable, through Invoke-Expression or through Get-Command
  makes the walk useless for that module, so its functions all count as reachable. Dropping is
  off by default: a bundle that keeps everything behaves exactly like the dot-sourced program,
  and Treeshake=1 is a decision made per entry once its fingerprints are stable.
#>

# modules: records with Path, Ast, Functions, Opaque (see the load step in bundler.ps1).
# Returns the same records with a Functions list reduced to the reachable ones, and .Dropped
# holding what was left out.
function Get-BundleReachable($modules, [string[]]$keep) {
  $byName = @{}
  foreach ($m in @($modules)) {
    foreach ($name in @($m.Functions)) {
      $key = $name.ToLowerInvariant()
      if ($byName.ContainsKey($key)) { $byName[$key] = @($byName[$key]) + @($m) } else { $byName[$key] = @($m) }
    }
  }

  $opaque = $false
  foreach ($m in @($modules)) {
    if (@($m.Opaque).Count -gt 0) { $opaque = $true }
  }
  # a call through anything but a name stops the analysis: keep every definition
  if ($opaque) {
    foreach ($m in @($modules)) {
      $m.Dropped = @()
      $m.Kept = @($m.Functions)
    }
    return @($modules)
  }

  $live = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  $queue = New-Object System.Collections.Generic.Queue[string]
  $mark = {
    param([string]$name)
    if ([string]::IsNullOrEmpty($name)) { return }
    $key = $name.ToLowerInvariant()
    if (-not $byName.ContainsKey($key)) { return }
    if ($live.Add($key)) { $queue.Enqueue($key) }
  }

  # roots: every call made by a statement that runs at load time, every name the module asks
  # for by string, and every definition of a module that invokes a scriptblock it was handed
  foreach ($m in @($modules)) {
    foreach ($s in @(Get-BundleStatements $m.Ast)) {
      if ($s -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
      foreach ($name in @(Get-BundleCommandNames $s)) { & $mark $name }
      foreach ($name in @(Get-BundleLookupNames $s)) { & $mark $name }
    }
    if ($m.BlockInvoke) {
      foreach ($name in @($m.Functions)) { & $mark $name }
    }
  }
  foreach ($name in @($keep)) { & $mark $name }

  # edges: the calls inside the body of a reachable function, wherever that function is
  while ($queue.Count -gt 0) {
    $key = $queue.Dequeue()
    foreach ($m in @($byName[$key])) {
      foreach ($f in @(Find-BundleFunction $m.Ast $key)) {
        foreach ($name in @(Get-BundleCommandNames $f)) { & $mark $name }
        foreach ($name in @(Get-BundleLookupNames $f)) { & $mark $name }
      }
    }
  }

  foreach ($m in @($modules)) {
    $kept = New-Object System.Collections.Generic.List[string]
    $gone = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($m.Functions)) {
      if ($live.Contains($name.ToLowerInvariant())) { $kept.Add($name) } else { $gone.Add($name) }
    }
    $m.Kept = $kept.ToArray()
    $m.Dropped = $gone.ToArray()
  }
  return @($modules)
}

# The top-level definitions of one module whose name matches, whatever its case.
function Find-BundleFunction($ast, [string]$name) {
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($s in @(Get-BundleStatements $ast)) {
    if ($s -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
    if ([string]$s.Name -eq $name) { $out.Add($s) }
  }
  return $out.ToArray()
}

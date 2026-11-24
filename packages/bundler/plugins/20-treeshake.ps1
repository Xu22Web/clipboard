#Requires -Version 5.1
<#
  tools\bundler\plugins\20-treeshake.ps1 - mark the definitions a bundle cannot reach.

  Off unless the entry asks for it. When it is on, the answer still comes from the AST: a
  definition is reachable when a load-time statement or a reachable function names it. A module
  that calls through a variable or through Get-Command disables the walk for the whole bundle,
  because a name nothing can read is not a name that is safe to drop.
#>

$Plugin = @{
  Name  = 'treeshake'
  Hooks = @{
    treeshake = {
      param($ctx, $modules)
      $keep = @()
      if ($null -ne $ctx.Entry.Keep) { $keep = @($ctx.Entry.Keep) }
      if (-not $ctx.Options.Treeshake) {
        foreach ($m in @($modules)) {
          $m.Kept = @($m.Functions)
          $m.Dropped = @()
        }
        return @($modules)
      }
      $result = @(Get-BundleReachable $modules $keep)
      $gone = 0
      $held = 0
      foreach ($m in $result) {
        $gone += @($m.Dropped).Count
        if (@($m.Opaque).Count -gt 0) { $held++ }
      }
      $note = 'treeshake   dropped ' + $gone + ' definition(s)'
      if ($held -gt 0) { $note = $note + ', ' + $held + ' module(s) kept whole (a call no name can follow)' }
      Write-Note $note
      return $result
    }
  }
}

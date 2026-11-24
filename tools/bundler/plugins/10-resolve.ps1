#Requires -Version 5.1
<#
  tools\bundler\plugins\10-resolve.ps1 - which files a bundle is made of, and in which order.

  The order is the one cli.ini writes, never the order the file system returns: dot-sourcing
  runs the modules in order and a later definition wins, so the merged bundle has to run them in
  the same order to mean the same thing.
#>

$Plugin = @{
  Name  = 'resolve'
  Hooks = @{
    resolve = {
      param($ctx)
      $list = New-Object System.Collections.Generic.List[string]
      $seen = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
      foreach ($rel in @($ctx.Entry.Modules)) {
        $one = ([string]$rel).Trim()
        if (-not $one) { continue }
        $full = [IO.Path]::GetFullPath((Join-Path $ctx.Root $one))
        if (-not (Test-Path -LiteralPath $full)) { throw ('module not found: ' + $one) }
        if ($seen.Add($full)) { $list.Add($full) }
      }
      if ($list.Count -eq 0) { throw ('entry ' + $ctx.Entry.Name + ' lists no module') }
      return $list.ToArray()
    }
  }
}

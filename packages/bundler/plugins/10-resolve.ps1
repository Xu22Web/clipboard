# packages\bundler\plugins\10-resolve.ps1 - which files a bundle is made of, and in which order.
#
# Two modes, the way a bundler has to work:
#
#   a list      Input= is a list of files: they are taken in the order written. Every target that
#               already exists uses this, so the behaviour has to stay exactly as it was.
#   one entry   Input= is a table of entries: each entry is walked through the call graph and its
#               closure is returned. A module that is called from another one is pulled in, and
#               the order is dependency first, entry last - dot-sourcing the result in order
#               reproduces the same picture the list writes by hand.
#
# The graph is read from the parsed AST, not from the text: a name inside a string or a comment is
# not an edge. #@use adds an edge by hand for the cases a call cannot express - a script loaded by
# path, a name assembled at run time.
#
# Scan= is what the graph may reach. It is the target's own source set, so a module that nothing
# calls is not silently dragged in.
$Plugin = @{
  Name  = 'resolve'
  Hooks = @{
    resolve = {
      param($ctx)

      $entries = @()
      if ($null -ne $ctx.Entry.Entries) { $entries = @($ctx.Entry.Entries) }

      if ($entries.Count -eq 0) {
        # ---------------------------------------------------------------- the explicit list
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

      # ---------------------------------------------------------------- the call graph
      $root = [string]$ctx.Root
      $candidates = New-Object System.Collections.Generic.List[string]
      $seenCandidate = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
      foreach ($pattern in @($ctx.Entry.Scan)) {
        $one = ([string]$pattern).Trim()
        if (-not $one) { continue }
        $hits = @()
        if ($one -match '[*?]') { $hits = @(Expand-Glob $root $one) }
        else {
          $full = [IO.Path]::GetFullPath((Join-Path $root $one))
          if (Test-Path -LiteralPath $full) { $hits = @($full) }
        }
        foreach ($hit in $hits) {
          $full = [IO.Path]::GetFullPath([string]$hit)
          if ($seenCandidate.Add($full)) { $candidates.Add($full) }
        }
      }
      if ($candidates.Count -eq 0) { throw ('entry ' + $ctx.Entry.Name + ' has no Scan= to resolve against') }

      # owner: a definition name -> the file that defines it (first one wins, which is the same
      # rule the renamer uses); calls: a file -> the names it calls; uses: a file -> #@use ids
      $owner = @{}
      $calls = @{}
      $uses = @{}
      $byId = @{}
      foreach ($file in $candidates) {
        $parsed = Get-BundleParse ([IO.File]::ReadAllText($file))
        if (Get-BundleRejectReason $parsed) { continue }
        $id = ([string](Get-BundleModuleId $root $file)).ToLowerInvariant()
        if ($id -and -not $byId.ContainsKey($id)) { $byId[$id] = $file }
        foreach ($name in @(Get-BundleFunctionNames $parsed.Ast)) {
          $key = ([string]$name).ToLowerInvariant()
          if (-not $owner.ContainsKey($key)) { $owner[$key] = $file }
        }
        $calls[$file] = @(Get-BundleCommandNames $parsed.Ast)
        $uses[$file] = @((Get-BundleDirectives $parsed).Uses)
      }

      $order = New-Object System.Collections.Generic.List[string]
      $state = @{}
      $visit = {
        param($file)
        $key = ([string]$file).ToLowerInvariant()
        # a module already finished, or one this walk is inside of: a cycle is not an error, the
        # later module simply lands after the one that closes it
        if ($state.ContainsKey($key)) { return }
        $state[$key] = 0
        if ($calls.ContainsKey($file)) {
          foreach ($name in @($calls[$file])) {
            $dep = ([string]$name).ToLowerInvariant()
            if (-not $owner.ContainsKey($dep)) { continue }
            $target = [string]$owner[$dep]
            if ($target -eq $file) { continue }
            & $visit $target
          }
        }
        if ($uses.ContainsKey($file)) {
          foreach ($one in @($uses[$file])) {
            $use = ([string]$one).ToLowerInvariant()
            if ($byId.ContainsKey($use)) { & $visit ([string]$byId[$use]) }
          }
        }
        $state[$key] = 1
        $order.Add([string]$file)
      }

      foreach ($entry in $entries) {
        $full = [IO.Path]::GetFullPath((Join-Path $root ([string]$entry)))
        if (-not (Test-Path -LiteralPath $full)) { throw ('entry not found: ' + $entry) }
        if (-not $calls.ContainsKey($full)) {
          # an entry outside the scanned set still takes part: it is parsed so its calls can be
          # followed, it just cannot be a dependency of anything
          $parsed = Get-BundleParse ([IO.File]::ReadAllText($full))
          $calls[$full] = @(Get-BundleCommandNames $parsed.Ast)
          $uses[$full] = @((Get-BundleDirectives $parsed).Uses)
        }
        & $visit $full
      }

      if ($order.Count -eq 0) { throw ('entry ' + $ctx.Entry.Name + ' resolved to nothing') }
      return $order.ToArray()
    }
  }
}

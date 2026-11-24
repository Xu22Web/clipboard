#Requires -Version 5.1
<#
  tools\bundler\plugins\30-merge.ps1 - many modules into one text.

  The merge takes statements, not lines: each module body arrives as a list of AST nodes (the
  render stage already put each module's text through the parser again), and the bundle text is
  those nodes in module order, each read through its own extent.
#>

$Plugin = @{
  Name  = 'merge'
  Hooks = @{
    merge = {
      param($ctx, $modules)
      $chunk = New-BundleChunk $modules
      if (-not $chunk.Text) { throw ('entry ' + $ctx.Entry.Name + ' merged to nothing') }
      return $chunk
    }
  }
}

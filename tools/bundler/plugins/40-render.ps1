#Requires -Version 5.1
<#
  tools\bundler\plugins\40-render.ps1 - the two passes that rewrite text.

  renderModule works on one module: the reachability decision is applied first (a definition
  that is not kept is not in the text this stage hands on, so nothing is deleted afterwards),
  then the module goes through the same minifier the package build uses, with one map for the
  whole bundle - the modules share a single script scope once they are merged, so a name has to
  mean the same thing in all of them.

  renderChunk is the single pass over the finished text: the statement merge and the whitespace
  pass that can only be done once the modules are already glued together.
#>

$Plugin = @{
  Name  = 'render'
  Hooks = @{
    renderModule = {
      param($ctx, $modules)
      $paths = New-Object System.Collections.Generic.List[string]
      foreach ($m in @($modules)) { $paths.Add([string]$m.Path) }
      if ($ctx.Options.Rename -and $null -eq $ctx.Maps) {
        $ctx.Maps = @{
          Functions = New-FunctionMap $paths.ToArray()
          Script    = New-ScriptVariableMap $paths.ToArray()
          Global    = New-GlobalVariableMap $paths.ToArray()
        }
        Write-Note ('names        ' + $ctx.Maps.Functions.Count + ' function(s), ' + $ctx.Maps.Script.Count + ' script variable(s), ' + $ctx.Maps.Global.Count + ' shared name(s)')
      }
      $index = 0
      foreach ($m in @($modules)) {
        $index++
        # the drop happens here, on original names, before anything is renamed
        $body = New-BundleModuleText $m
        $m.Kept = $null
        $m.Dropped = @()
        if (-not $ctx.Options.Minify -and -not $ctx.Options.Rename) {
          $m.Ast = (Get-BundleParse $body).Ast
          continue
        }
        $inPath = Join-Path $ctx.Tmp ('mod-' + $index + '.ps1')
        $outPath = Join-Path $ctx.Tmp ('mod-' + $index + '.min.ps1')
        [IO.File]::WriteAllText($inPath, $body, (New-Object System.Text.UTF8Encoding $false))
        if ($ctx.Options.Rename) {
          [void](Invoke-MinifyFile -Path $inPath -OutPath $outPath -FunctionMap $ctx.Maps.Functions -ScriptVarMap $ctx.Maps.Script -GlobalVarMap $ctx.Maps.Global)
        } else {
          [void](Invoke-MinifyFile -Path $inPath -OutPath $outPath -NoRename)
        }
        $rendered = [IO.File]::ReadAllText($outPath)
        $parsed = Get-BundleParse $rendered
        if ($parsed.Errors.Count -gt 0) {
          throw ([string]$m.Rel + ': the rewritten module does not parse (' + [string]$parsed.Errors[0].Message + ')')
        }
        $m.Ast = $parsed.Ast
      }
      return @($modules)
    }

    renderChunk = {
      param($ctx, $chunk)
      if (-not $ctx.Options.Minify -and -not $ctx.Options.Rename) { return $chunk }
      $inPath = Join-Path $ctx.Tmp 'chunk.ps1'
      $outPath = Join-Path $ctx.Tmp 'chunk.min.ps1'
      [IO.File]::WriteAllText($inPath, [string]$chunk.Text, (New-Object System.Text.UTF8Encoding $false))
      [void](Invoke-MinifyFile -Path $inPath -OutPath $outPath -NoRename)
      $chunk.Text = [IO.File]::ReadAllText($outPath)
      return $chunk
    }
  }
}

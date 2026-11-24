# tools\bundler\assets\script.ps1 - a .ps1 on its way into the package.
#
# The handler the renamer and the minifier live behind. It is handed the maps the build worked
# out for the whole program (functions, script variables, shared-scope variables), because a
# name means the same thing in every file of one package - a per-file table would give two
# variables the same short name.
$Plugin = @{
  Name    = 'script'
  Convert = {
    param($ctx)
    if (-not $ctx.Minify) {
      Copy-Item -LiteralPath $ctx.Source -Destination $ctx.OutPath -Force
      $len = (Get-Item -LiteralPath $ctx.Source).Length
      return @{ Before = $len; After = $len; Row = $null }
    }
    if ($ctx.Rename) {
      $r = Invoke-MinifyFile -Path $ctx.Source -OutPath $ctx.OutPath -FunctionMap $ctx.FunctionMap -ScriptVarMap $ctx.ScriptVarMap -GlobalVarMap $ctx.GlobalVarMap
    } else {
      $r = Invoke-MinifyFile -Path $ctx.Source -OutPath $ctx.OutPath -NoRename
    }
    # the row is reported under the source path, which is what a reader recognizes
    $r.Path = $ctx.Path
    return @{ Before = $r.Before; After = $r.After; Row = $r }
  }
}
$Plugin

# tools\bundler\assets\batch.ps1 - a .cmd / .bat on its way into the package.
#
# CRLF on purpose: cmd.exe reads both line endings, and a batch file written with LF alone
# breaks on some versions of the goto/label handling. The file keeps a trailing newline, which
# a label at the very end needs.
$Plugin = @{
  Name    = 'batch'
  Convert = {
    param($ctx)
    $text = [IO.File]::ReadAllText($ctx.Path).Replace("`r`n", "`n").Replace("`n", "`r`n").TrimEnd()
    if ($ctx.Minify) { $text = Compress-Batch $text }
    [IO.File]::WriteAllText($ctx.OutPath, ($text + "`r`n"), $ctx.Ascii)
    return @{ Before = 0; After = 0; Row = $null }
  }
}
$Plugin

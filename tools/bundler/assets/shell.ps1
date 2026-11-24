# tools\bundler\assets\shell.ps1 - a .sh launcher on its way into the package.
#
# LF on purpose: sh would take the CR as part of the command, so a Unix launcher converted to
# CRLF stops working the moment it is copied to a machine with a real shell.
$Plugin = @{
  Name    = 'shell'
  Convert = {
    param($ctx)
    $text = [IO.File]::ReadAllText($ctx.Path)
    if ($ctx.Minify) { $text = (Compress-Shell $text).TrimEnd() + "`n" }
    [IO.File]::WriteAllText($ctx.OutPath, $text, $ctx.Ascii)
    return @{ Before = 0; After = 0; Row = $null }
  }
}
$Plugin

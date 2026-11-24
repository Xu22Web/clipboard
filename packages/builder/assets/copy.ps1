# tools\bundler\assets\copy.ps1 - everything else, carried byte for byte.
#
# The fallback handler, and the reason the table needs no negative cases: a LICENSE, a picture,
# a documentation page all take this row, and a new kind of file a package only stores needs no
# handler at all.
$Plugin = @{
  Name    = 'copy'
  Convert = {
    param($ctx)
    Copy-Item -LiteralPath $ctx.Source -Destination $ctx.OutPath -Force
    return @{ Before = 0; After = 0; Row = $null }
  }
}
$Plugin

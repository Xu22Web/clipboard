# tools\bundler\assets\ini.ps1 - an .ini on its way into the package.
#
# UTF-8 with a BOM: an ini can carry words outside ASCII (a language file, a theme name), and
# the program reads its language files in that form. Key and value stay, comments and blank
# lines go.
$Plugin = @{
  Name    = 'ini'
  Convert = {
    param($ctx)
    $text = [IO.File]::ReadAllText($ctx.Path)
    if ($ctx.Minify) { $text = (Compress-Ini $text).TrimEnd() + "`r`n" }
    [IO.File]::WriteAllText($ctx.OutPath, $text, $ctx.Utf8Bom)
    return @{ Before = 0; After = 0; Row = $null }
  }
}
$Plugin

# tools\bundler\assets\version.ps1 - lib\base.ps1, whose version block is a dev-time read.
#
# A development copy reads the number from package.ini; a package carries the number itself,
# so the block between the two markers is replaced before anything else looks at the file.
# The rewrite happens first and the result is handed on as a script: this handler owns the
# package.ini question, not the minifier.
$Plugin = @{
  Name    = 'version'
  Next    = 'script'
  Convert = {
    param($ctx)
    $text = [IO.File]::ReadAllText($ctx.Path)
    $begin = $text.IndexOf('#@version-begin')
    $end = $text.IndexOf('#@version-end')
    if ($begin -lt 0 -or $end -lt $begin) { Fail ($ctx.Rel + ' carries no #@version-begin / #@version-end block') }
    $head = $text.Substring(0, $begin)
    $tail = $text.Substring($text.IndexOf("`n", $end) + 1)
    $patched = $head + "`$script:Version = '" + [string]$ctx.Version + "'`r`n" + $tail
    # the patched copy sits beside the stage, so the source tree is never written to
    $tmp = Join-Path $ctx.StageRoot ('verpatch\' + (Split-Path -Leaf $ctx.Path))
    $parent = Split-Path -Parent $tmp
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($tmp, $patched)
    $ctx.Source = $tmp
    return $null
  }
}
$Plugin

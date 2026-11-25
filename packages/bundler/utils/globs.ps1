# tools\bundler\utils\globs.ps1 - the glob rules cli.ini uses for Includes and Excludes.
#
# One syntax for every list: "*" and "?" match inside one file name, "**/" walks any number
# of folders, and the text in front of the last "/" is the folder a pattern starts in.
# Patterns are written relative to BaseUrl, the folder each section names - "." is the
# repository root - so "src/**/*.ps1" and "../scripts/x.bat" both mean what they say. Both
# lists expand to absolute file paths, and a file matched by an exclude glob is dropped from
# the include result.

# One list value into its entries: a comma, a semicolon or plain whitespace separates them, and
# an empty entry is not a glob. A comma inside {...} belongs to the pattern, so "{a,b}" stays one
# entry - electron-builder reads a brace alternation the same way.
function Split-GlobList([string]$value) {
  $text = [string]$value
  $out = New-Object System.Collections.Generic.List[string]
  $sb = New-Object System.Text.StringBuilder
  $depth = 0
  foreach ($c in $text.ToCharArray()) {
    if ($c -eq '{') { $depth++; [void]$sb.Append($c); continue }
    if ($c -eq '}') { if ($depth -gt 0) { $depth-- }; [void]$sb.Append($c); continue }
    if ($depth -eq 0 -and ($c -eq ',' -or $c -eq ';' -or [char]::IsWhiteSpace($c))) {
      $one = $sb.ToString().Trim()
      if ($one) { $out.Add($one) }
      [void]$sb.Clear()
      continue
    }
    [void]$sb.Append($c)
  }
  $one = $sb.ToString().Trim()
  if ($one) { $out.Add($one) }
  return $out.ToArray()
}

# "{a,b}" is two patterns, the way minimatch expands a brace alternation before matching: the
# expansion happens here so the regex never has to know about braces. Nested braces work, and
# the result is capped the way electron-builder caps it.
function Expand-GlobBraces([string]$glob) {
  $g = [string]$glob
  $open = -1
  $close = -1
  $depth = 0
  for ($i = 0; $i -lt $g.Length; $i++) {
    if ($g[$i] -eq '{') {
      if ($depth -eq 0) { $open = $i }
      $depth++
    } elseif ($g[$i] -eq '}') {
      $depth--
      if ($depth -eq 0 -and $open -ge 0) { $close = $i; break }
    }
  }
  if ($open -lt 0 -or $close -lt 0) { return @($g) }
  $head = $g.Substring(0, $open)
  $body = $g.Substring($open + 1, $close - $open - 1)
  $tail = $g.Substring($close + 1)
  $parts = New-Object System.Collections.Generic.List[string]
  $sb = New-Object System.Text.StringBuilder
  $inner = 0
  foreach ($c in $body.ToCharArray()) {
    if ($c -eq '{') { $inner++; [void]$sb.Append($c); continue }
    if ($c -eq '}') { $inner--; [void]$sb.Append($c); continue }
    if ($c -eq ',' -and $inner -eq 0) { $parts.Add($sb.ToString()); [void]$sb.Clear(); continue }
    [void]$sb.Append($c)
  }
  $parts.Add($sb.ToString())
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($part in $parts) {
    foreach ($one in @(Expand-GlobBraces ($head + $part + $tail))) {
      if ($out.Count -ge 64) { return $out.ToArray() }
      $out.Add($one)
    }
  }
  return $out.ToArray()
}

# One pattern as a regex over a relative path. "*" and "?" stay inside one name, "[abc]" is a
# character class (a leading "!" or "^" negates it), and "**" as a path portion walks any number
# of folders - minimatch's rules, which is what electron-builder's file list is written in.
function ConvertTo-GlobRegex([string]$glob) {
  $g = ($glob -replace '\\', '/').Trim()
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('^')
  $i = 0
  while ($i -lt $g.Length) {
    $c = $g[$i]
    if ($c -eq '*' -and ($i + 1) -lt $g.Length -and $g[$i + 1] -eq '*') {
      if (($i + 2) -lt $g.Length -and $g[$i + 2] -eq '/') {
        # "**/" also matches no folder at all, so "**/*.ps1" covers "clipboard.ps1"
        [void]$sb.Append('(?:.*/)?')
        $i += 3
      } else {
        [void]$sb.Append('.*')
        $i += 2
      }
      continue
    }
    if ($c -eq '*') { [void]$sb.Append('[^/]*'); $i++; continue }
    if ($c -eq '?') { [void]$sb.Append('[^/]'); $i++; continue }
    if ($c -eq '[') {
      $end = $g.IndexOf(']', $i + 1)
      if ($end -gt ($i + 1)) {
        $body = $g.Substring($i + 1, $end - $i - 1)
        if ($body.StartsWith('!')) { $body = '^' + $body.Substring(1) }
        elseif ($body.StartsWith('^')) { $body = '\^' + $body.Substring(1) }
        [void]$sb.Append('[' + $body + ']')
        $i = $end + 1
        continue
      }
    }
    [void]$sb.Append([regex]::Escape([string]$c))
    $i++
  }
  [void]$sb.Append('$')
  return $sb.ToString()
}

# Every file one pattern reaches, as absolute paths. The walk starts at the last folder the
# pattern writes without a wildcard, so "src/**/*.ps1" reads src\ and "**/*.ps1" reads BaseUrl.
# A missing folder is not an error: a list may name a folder this copy does not have.
function Expand-Glob([string]$baseDir, [string]$glob) {
  $out = New-Object System.Collections.Generic.List[string]
  $g = ($glob -replace '\\', '/').Trim()
  if (-not $g) { return $out }
  $baseFull = ([IO.Path]::GetFullPath($baseDir)).TrimEnd([char]92, [char]47)
  foreach ($pattern in @(Expand-GlobBraces $g)) {
    $segments = @($pattern -split '/')
    $fixed = New-Object System.Collections.Generic.List[string]
    foreach ($segment in $segments) {
      $text = [string]$segment
      if ($text -match '[*?]' -or $text.Contains('[')) { break }
      $fixed.Add($text)
    }
    $start = $baseFull
    if ($fixed.Count -gt 0) { $start = [IO.Path]::GetFullPath((Join-Path $baseFull ($fixed -join '\'))) }
    $tail = ''
    if ($fixed.Count -lt $segments.Count) { $tail = (@($segments[$fixed.Count..($segments.Count - 1)]) -join '/') }
    if (-not (Test-Path -LiteralPath $start)) { continue }
    $item = Get-Item -LiteralPath $start -Force
    if (-not $tail) {
      # a pattern with no wildcard names one file or one folder; a folder means everything in it,
      # which is how electron-builder reads a bare "dist" entry
      if ($item.PSIsContainer) {
        foreach ($f in @(Get-ChildItem -LiteralPath $item.FullName -File -Recurse -ErrorAction SilentlyContinue)) { $out.Add($f.FullName) }
      } else { $out.Add($item.FullName) }
      continue
    }
    if (-not $item.PSIsContainer) { continue }
    $rx = New-Object System.Text.RegularExpressions.Regex ((ConvertTo-GlobRegex $tail), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $startFull = ([IO.Path]::GetFullPath($item.FullName)).TrimEnd([char]92, [char]47)
    $prefixLen = $startFull.Length + 1
    foreach ($f in @(Get-ChildItem -LiteralPath $startFull -File -Recurse -ErrorAction SilentlyContinue)) {
      if ($f.FullName.Length -le $prefixLen) { continue }
      $rel = $f.FullName.Substring($prefixLen).Replace('\', '/')
      if ($rx.IsMatch($rel)) { $out.Add($f.FullName) }
    }
  }
  return $out
}

# The list applied in order, the way electron-builder reads `files`: a pattern adds the files it
# reaches, a "!pattern" takes them away again, and a later pattern can put a file back.
function Expand-GlobList([string]$baseDir, [string[]]$patterns) {
  $out = New-Object System.Collections.Generic.List[string]
  $index = @{}
  foreach ($pattern in @($patterns)) {
    $one = ([string]$pattern).Trim()
    if (-not $one) { continue }
    $negate = $one.StartsWith('!')
    if ($negate) { $one = $one.Substring(1).Trim() }
    if (-not $one) { continue }
    foreach ($f in @(Expand-Glob $baseDir $one)) {
      if ($negate) {
        if ($index.ContainsKey($f)) { [void]$out.Remove($f); $index.Remove($f) }
      } elseif (-not $index.ContainsKey($f)) {
        $index[$f] = $true
        $out.Add($f)
      }
    }
  }
  return $out
}

# BaseUrl is written the way OutDir is: relative to the repository root, or absolute. Both
# tools that read a glob list resolve it here, so a path means the same thing to the watcher
# and to the package.
function Resolve-BaseDir([string]$root, [string]$setting) {
  $value = ([string]$setting).Trim()
  if (-not $value) { return '' }
  if ([IO.Path]::IsPathRooted($value)) { return $value }
  return (Join-Path $root $value)
}

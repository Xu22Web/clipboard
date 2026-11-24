# tools\utils\globs.ps1 - the glob rules cli.ini uses for Includes and Excludes.
#
# One syntax for every list: "*" and "?" match inside one file name, "**/" walks any number
# of folders, and the text in front of the last "/" is the folder a pattern starts in.
# Patterns are written relative to BaseUrl, the folder each section names - "." is the
# repository root - so "src/**/*.ps1" and "../scripts/x.bat" both mean what they say. Both
# lists expand to absolute file paths, and a file matched by an exclude glob is dropped from
# the include result.

# One list value into its entries: a comma, a semicolon or plain whitespace separates them,
# and an empty entry is not a glob. Both tools read Includes and Excludes this way.
function Split-GlobList([string]$value) {
  return @($value -split '[,;\s]+' | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}

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
    [void]$sb.Append([regex]::Escape([string]$c))
    $i++
  }
  [void]$sb.Append('$')
  return $sb.ToString()
}

# Every file one pattern reaches, as absolute paths. A missing folder is not an error: a list
# may name a folder that this copy does not have.
function Expand-Glob([string]$baseDir, [string]$glob) {
  $out = New-Object System.Collections.Generic.List[string]
  $g = ($glob -replace '\\', '/').Trim()
  if (-not $g) { return $out }
  $dirPart = ''
  $namePart = $g
  $slash = $g.LastIndexOf('/')
  if ($slash -ge 0) {
    $dirPart = $g.Substring(0, $slash)
    $namePart = $g.Substring($slash + 1)
  }
  if (-not $namePart) { return $out }
  $deep = $dirPart.Contains('**')
  if ($deep) { $dirPart = $dirPart.Replace('**', '') }
  $dir = $baseDir
  if ($dirPart) { $dir = [IO.Path]::GetFullPath((Join-Path $baseDir ($dirPart -replace '/', '\'))) }
  if (-not (Test-Path -LiteralPath $dir)) { return $out }
  $rx = New-Object System.Text.RegularExpressions.Regex (ConvertTo-GlobRegex $namePart)
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Recurse:$deep -ErrorAction SilentlyContinue)) {
    if ($rx.IsMatch($f.Name)) { $out.Add($f.FullName) }
  }
  return $out
}

# The include list minus everything the exclude list reaches.
function Expand-GlobList([string]$baseDir, [string[]]$includes, [string[]]$excludes) {
  $drop = @{}
  foreach ($glob in @($excludes)) {
    foreach ($f in @(Expand-Glob $baseDir $glob)) { $drop[$f] = $true }
  }
  $out = New-Object System.Collections.Generic.List[string]
  $seen = @{}
  foreach ($glob in @($includes)) {
    foreach ($f in @(Expand-Glob $baseDir $glob)) {
      if ($drop.ContainsKey($f) -or $seen.ContainsKey($f)) { continue }
      $seen[$f] = $true
      $out.Add($f)
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

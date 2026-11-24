#Requires -Version 5.1
<#
  tools\bundler\plugins\50-cs-part.ps1 - the file list a C# product is compiled from.

  A product's root file declares what belongs to it, one line per source:

      // #part store/records.cs
      // #part store/blobs.cs

  The closure is resolved here, dependencies first, and it is what the compiler is given - no
  file is ever concatenated into another. A source that nothing reaches is therefore not merely
  unused: it is never compiled, so its types are absent from the assembly.

  The directive is found by scanning the source character by character, not by a regular
  expression over the text: "//" inside a string, a verbatim string, an interpolated string or
  a block comment is not a comment, and a file that happens to hold the text "#part" in a
  literal must not be treated as declaring anything. Only a line comment that starts outside
  any of those counts.

  A path is relative to the file that declares it and may not leave src\main.
#>

# The directive targets of one file, in the order they are written.
function Get-CSharpParts([string]$path) {
  $text = [IO.File]::ReadAllText($path)
  $out = New-Object System.Collections.Generic.List[string]
  $i = 0
  $n = $text.Length
  $state = 'code'      # code | line | block | string | verbatim | char
  $lineStart = 0
  while ($i -lt $n) {
    $c = $text[$i]
    $next = [char]0
    if ($i + 1 -lt $n) { $next = $text[$i + 1] }

    if ($state -eq 'line') {
      if ($c -eq "`n") {
        # the comment ended: test the line it described
        $line = $text.Substring($lineStart, $i - $lineStart)
        $m = [regex]::Match($line, '^\s*//\s*#part\s+(\S+)\s*$')
        if ($m.Success) { $out.Add($m.Groups[1].Value) }
        $state = 'code'
        $lineStart = $i + 1
      }
      $i++
      continue
    }
    if ($state -eq 'block') {
      if ($c -eq '*' -and $next -eq '/') { $state = 'code'; $i += 2; continue }
      if ($c -eq "`n") { $lineStart = $i + 1 }
      $i++
      continue
    }
    if ($state -eq 'string') {
      if ($c -eq '\') { $i += 2; continue }
      if ($c -eq '"') { $state = 'code' }
      if ($c -eq "`n") { $lineStart = $i + 1 }
      $i++
      continue
    }
    if ($state -eq 'verbatim') {
      if ($c -eq '"' -and $next -eq '"') { $i += 2; continue }
      if ($c -eq '"') { $state = 'code' }
      if ($c -eq "`n") { $lineStart = $i + 1 }
      $i++
      continue
    }
    if ($state -eq 'char') {
      if ($c -eq '\') { $i += 2; continue }
      if ($c -eq "'") { $state = 'code' }
      $i++
      continue
    }

    # code
    if ($c -eq "`n") { $lineStart = $i + 1; $i++; continue }
    if ($c -eq '/' -and $next -eq '/') { $state = 'line'; $i += 2; continue }
    if ($c -eq '/' -and $next -eq '*') { $state = 'block'; $i += 2; continue }
    if ($c -eq '@' -and $next -eq '"') { $state = 'verbatim'; $i += 2; continue }
    if ($c -eq '@' -and $next -eq '$' -and $i + 2 -lt $n -and $text[$i + 2] -eq '"') { $state = 'verbatim'; $i += 3; continue }
    if ($c -eq '$' -and $next -eq '@' -and $i + 2 -lt $n -and $text[$i + 2] -eq '"') { $state = 'verbatim'; $i += 3; continue }
    if ($c -eq '$' -and $next -eq '"') { $state = 'string'; $i += 2; continue }
    if ($c -eq '"') { $state = 'string'; $i++; continue }
    if ($c -eq "'") { $state = 'char'; $i++; continue }
    $i++
  }
  # a directive on the last line, with no newline after it
  if ($state -eq 'line') {
    $line = $text.Substring($lineStart)
    $m = [regex]::Match($line, '^\s*//\s*#part\s+(\S+)\s*$')
    if ($m.Success) { $out.Add($m.Groups[1].Value) }
  }
  return $out.ToArray()
}

# The whole closure of one root file, dependencies first, each file once.
function Resolve-CSharpParts([string]$root, [string]$entry, [string]$mainRoot) {
  $mainFull = [IO.Path]::GetFullPath($mainRoot).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
  $seen = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  $list = New-Object System.Collections.Generic.List[string]
  $stack = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  $walk = $null
  $walk = {
    param([string]$file, [string]$from)
    $full = [IO.Path]::GetFullPath($file)
    if (-not $full.StartsWith($mainFull, [StringComparison]::OrdinalIgnoreCase)) {
      throw ('#part ' + $full + ' leaves src\main' + $(if ($from) { ' (declared in ' + $from + ')' } else { '' }))
    }
    if (-not (Test-Path -LiteralPath $full)) { throw ('#part not found: ' + $full) }
    if (-not $seen.Add($full)) { return }
    if (-not $stack.Add($full)) { throw ('#part cycle at ' + $full) }
    foreach ($one in @(Get-CSharpParts $full)) {
      & $walk (Join-Path (Split-Path -Parent $full) $one) $full
    }
    [void]$stack.Remove($full)
    $list.Add($full)
  }
  & $walk $entry ''
  return $list.ToArray()
}

$Plugin = @{
  Name  = 'cs-part'
  Hooks = @{
    part = {
      param($ctx)
      # From= is written relative to the repository root, while a caller that compiles another
      # copy of the same source hands over an absolute path: Join-Path would glue the two into
      # one impossible path, so a rooted value is used as it stands.
      $entry = [string]$ctx.Entry.From
      if (-not [IO.Path]::IsPathRooted($entry)) { $entry = Join-Path $ctx.Root $entry }
      if (-not $entry -or -not (Test-Path -LiteralPath $entry)) { throw ('no root file: ' + [string]$ctx.Entry.From) }
      # the folder a directive may not leave is the one the root file sits in: src\main for the
      # type library, src\preload for the single-source client. A caller that compiles another
      # copy of the same source moves the root, and the tree moves with it.
      $mainRoot = Split-Path -Parent $entry
      $files = @(Resolve-CSharpParts $ctx.Root $entry $mainRoot)
      $declared = @($files).Count
      foreach ($glob in @($ctx.Entry.Append)) {
        $pattern = Join-Path $ctx.Root $glob
        foreach ($one in @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
          if (-not ($files -contains $one.FullName)) { $files += $one.FullName }
        }
      }
      Write-Field 'sources' ([string]$declared + ' from #part, ' + [string](@($files).Count - $declared) + ' appended')
      return $files
    }
  }
}

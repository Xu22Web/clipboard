# utils/ini.ps1 - the ini document and the operations on it. Pure: lines in, lines out.
#
# No file is opened here (utils/inifile.ps1 does that), no cache lives here, and no key is
# known here: what a key means is a schema's business (src/schema/*.ps1).
#
# A document - a "doc" - keeps the file as it was read, plus an index into it:
#
#   Lines    the file line by line, comments and blank lines included
#   Map      key -> value, case-insensitive, the last value wins
#   Keys     the keys in file order, at the first position of a repeated key
#   Index    key -> @{ Lines = <line numbers>; Section = <name or ''>; Leaf = <name in it> }
#   Sections section name -> @{ Head = <header line>; Last = <last line of the block> }
#
# Keys are flat: a "[section]" line prefixes the keys that follow it, so
#
#   [scripts]      and     scripts.Dev=x
#   Dev=x
#
# produce the same key. Section names are lower case and keys PascalCase by convention, and
# both are read case-insensitively.
#
# Every writer changes Lines and then reindexes, so a key keeps its line, the comment above it
# and the order of the file. `config set` writes one key and `config init` adds the ones this
# version has: both go through the functions below instead of walking the text themselves.

# rebuild Map, Keys, Index and Sections from Lines
function Update-IniDocIndex($doc) {
  $map = @{}
  $keys = [System.Collections.Generic.List[string]]::new()
  $index = @{}
  $sections = @{}
  $section = ''
  $sectionKey = ''
  $lineNo = -1
  foreach ($raw in @($doc.Lines)) {
    $lineNo++
    $l = ([string]$raw).Trim()
    if ($l.Length -eq 0) { continue }
    if ($l[0] -eq '#' -or $l[0] -eq ';') {
      # a comment still belongs to the block: a key added later goes after it, not before
      if ($sectionKey -and $sections.ContainsKey($sectionKey)) { $sections[$sectionKey].Last = $lineNo }
      continue
    }
    if ($l.StartsWith('[') -and $l.EndsWith(']')) {
      $section = $l.Substring(1, $l.Length - 2).Trim()
      $sectionKey = $section.ToLowerInvariant()
      $sections[$sectionKey] = @{ Head = $lineNo; Last = $lineNo }
      continue
    }
    $i = $l.IndexOf('=')
    if ($i -lt 1) { continue }
    $leaf = $l.Substring(0, $i).Trim()
    $key = $leaf
    if ($section) { $key = $section + '.' + $leaf }
    $v = $l.Substring($i + 1).Trim()
    if ($v.Length -ge 2 -and $v[0] -eq '"' -and $v[$v.Length - 1] -eq '"') { $v = $v.Substring(1, $v.Length - 2) }
    if (-not $map.ContainsKey($key)) { $keys.Add($key) }
    $map[$key] = $v
    if (-not $index.ContainsKey($key)) {
      $index[$key] = @{ Lines = @(); Section = [string]$section; Leaf = $leaf }
    }
    $index[$key].Lines += $lineNo
    if ($sectionKey -and $sections.ContainsKey($sectionKey)) { $sections[$sectionKey].Last = $lineNo }
  }
  $doc.Map = $map
  $doc.Keys = $keys.ToArray()
  $doc.Index = $index
  $doc.Sections = $sections
  return $doc
}

# parse lines into a doc. A repeated key keeps the last value and its first position, so a file
# that sets a key twice reads like the browser reading a stylesheet.
function Read-IniDoc([string[]]$lines) {
  $doc = @{ Lines = @(); Map = @{}; Keys = @(); Index = @{}; Sections = @{} }
  $list = [System.Collections.Generic.List[string]]::new()
  foreach ($l in @($lines)) { $list.Add([string]$l) }
  $doc.Lines = $list.ToArray()
  return (Update-IniDocIndex $doc)
}

# an empty doc, for a caller that builds one up instead of parsing
function New-IniDoc {
  return @{ Lines = @(); Map = @{}; Keys = @(); Index = @{}; Sections = @{} }
}

# the value of one key, "" when the doc does not have it
function Get-IniDocValue($doc, [string]$key) {
  if ($null -eq $doc) { return '' }
  if ($doc.Map.ContainsKey($key)) { return [string]$doc.Map[$key] }
  return ''
}

# true when the key exists, whatever its value
function Test-IniDocKey($doc, [string]$key) {
  if ($null -eq $doc) { return $false }
  return $doc.Map.ContainsKey($key)
}

# the header line and the last line of a block, $null when the file has no such section
function Get-IniDocSection($doc, [string]$name) {
  if ($null -eq $doc -or -not $name) { return $null }
  $key = $name.Trim().ToLowerInvariant()
  if (-not $doc.Sections.ContainsKey($key)) { return $null }
  return $doc.Sections[$key]
}

# replace one line by its number; the index is rebuilt, so a key commented out here stops
# being a key
function Set-IniDocLine($doc, [int]$index, [string]$text) {
  if ($null -eq $doc) { return $doc }
  $lines = @($doc.Lines)
  if ($index -lt 0 -or $index -ge $lines.Count) { return $doc }
  $lines[$index] = [string]$text
  $doc.Lines = $lines
  return (Update-IniDocIndex $doc)
}

# put a block of lines (a comment, a section header and a key, say) in at one position
function Insert-IniDocLines($doc, [int]$at, [string[]]$block) {
  if ($null -eq $doc) { return $doc }
  $list = [System.Collections.Generic.List[string]]::new()
  foreach ($l in @($doc.Lines)) { $list.Add([string]$l) }
  if ($at -lt 0) { $at = 0 }
  if ($at -gt $list.Count) { $at = $list.Count }
  $n = 0
  foreach ($b in @($block)) { $list.Insert($at + $n, [string]$b); $n++ }
  $doc.Lines = $list.ToArray()
  return (Update-IniDocIndex $doc)
}

# write one key: an existing key keeps its line and the spelling the file already uses, a new
# one joins its [section] block, or is appended with a fresh header when the file has none
function Set-IniDocValue($doc, [string]$key, [string]$value) {
  if ($null -eq $doc) { return $doc }
  if ($doc.Index.ContainsKey($key)) {
    $hit = $doc.Index[$key]
    $lines = @($doc.Lines)
    foreach ($n in @($hit.Lines)) {
      $lines[[int]$n] = [string]$hit.Leaf + '=' + $value
    }
    $doc.Lines = $lines
    return (Update-IniDocIndex $doc)
  }
  $leaf = $key
  $group = ''
  $dot = $key.LastIndexOf('.')
  if ($dot -gt 0) {
    $group = $key.Substring(0, $dot)
    $leaf = $key.Substring($dot + 1)
  }
  if ($group) {
    $sec = Get-IniDocSection $doc $group
    if ($null -ne $sec) { return (Insert-IniDocLines $doc ([int]$sec.Last + 1) @($leaf + '=' + $value)) }
    $block = @(('[' + $group + ']'), ($leaf + '=' + $value))
    $cur = @($doc.Lines)
    if ($cur.Count -gt 0 -and $cur[$cur.Count - 1].Trim()) { $block = @('') + $block }
    return (Insert-IniDocLines $doc $cur.Count $block)
  }
  return (Insert-IniDocLines $doc @($doc.Lines).Count @($key + '=' + $value))
}

# every key under a group ("item-marks"), or every key when the prefix is empty
function Select-IniDocKeys($doc, [string]$prefix = '') {
  $out = [System.Collections.Generic.List[string]]::new()
  if ($null -eq $doc) { return $out.ToArray() }
  $head = ''
  if ($prefix) { $head = $prefix.TrimEnd('.') + '.' }
  foreach ($k in @($doc.Keys)) {
    $name = [string]$k
    if (-not $head) { $out.Add($name); continue }
    if ($name.StartsWith($head, [StringComparison]::OrdinalIgnoreCase)) { $out.Add($name) }
  }
  return $out.ToArray()
}

# the file as it would be written: the lines that were read, with every edit in place
function ConvertTo-IniText($doc) {
  if ($null -eq $doc) { return @() }
  return @($doc.Lines)
}

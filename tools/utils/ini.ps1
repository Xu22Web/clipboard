# tools\utils\ini.ps1 - the ini reader the tooling needs, and nothing else.
#
# src\utils\ini.ps1 + inifile.ps1 implement the whole layer for the program: the document
# model (Lines, Map, Keys, Index, Sections), every operation on it, the parse cache and the
# line-preserving writer. The tooling only ever asks one question - "what does this file say"
# - so this copy keeps the parser and a one-shot reader, and returns a doc with Map and Keys.
# The line index is left out on purpose: no tool script edits an ini file, and cli.ini is
# written by hand. Keeping the copy here is what lets a tool script run without loading
# anything out of src\.
#
# The rules are the program's rules - one "Key=Value" per line, "#" or ";" comments, a
# "[section]" line prefixing the keys that follow it, the last value of a repeated key wins at
# the first position - because a cli.ini written by hand and a clipboard.ini the program writes
# have to read the same way. tests\unit\unit.ps1 runs both readers over the same sample and
# compares values and key order, so a rule added to one side only fails there.

# the same parse as src\utils\ini.ps1, minus the line index: Map and Keys are what a tool asks
# for, and both come out in the same shape
function Read-IniDoc([string[]]$lines) {
  $map = @{}
  $keys = [System.Collections.Generic.List[string]]::new()
  $section = ''
  foreach ($raw in $lines) {
    $l = ([string]$raw).Trim()
    if ($l.Length -eq 0) { continue }
    if ($l[0] -eq '#' -or $l[0] -eq ';') { continue }
    if ($l.StartsWith('[') -and $l.EndsWith(']')) {
      $section = $l.Substring(1, $l.Length - 2).Trim()
      continue
    }
    $i = $l.IndexOf('=')
    if ($i -lt 1) { continue }
    $k = $l.Substring(0, $i).Trim()
    if ($section) { $k = $section + '.' + $k }
    $v = $l.Substring($i + 1).Trim()
    if ($v.Length -ge 2 -and $v[0] -eq '"' -and $v[$v.Length - 1] -eq '"') { $v = $v.Substring(1, $v.Length - 2) }
    if (-not $map.ContainsKey($k)) { $keys.Add($k) }
    $map[$k] = $v
  }
  return @{ Map = $map; Keys = $keys.ToArray() }
}

# The flat key map of one file. A missing file reads as an empty map and so does an unreadable
# one: the caller's own defaults then decide what happens, which is the only sane answer for
# an optional settings file.
function Import-IniMap([string]$path) {
  $map = @{}
  if (-not (Test-Path -LiteralPath $path)) { return $map }
  try {
    return (Read-IniDoc ([IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8))).Map
  } catch {
    return $map
  }
}

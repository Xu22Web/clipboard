# utils/ini.ps1 - the ini document and the operations on it. Pure: text in, values out.
#
# No file is opened here (utils/inifile.ps1 does that), no cache lives here, and no key is
# known here: what a key means is a schema's business (src/schema/*.ps1).
#
# A document - a "doc" - is @{ Map = <key -> value, case-insensitive>; Keys = <file order> }.
# Keys are flat: a "[section]" line prefixes the keys that follow it, so
#
#   [scripts]      and     scripts.Dev=x
#   Dev=x
#
# produce the same key. Section names are lower case and keys PascalCase by convention, and
# both are read case-insensitively.

# parse lines into a doc. A repeated key keeps the last value and its first position, so a
# file that sets a key twice reads like the browser reading a stylesheet.
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

# an empty doc, for a caller that builds one up instead of parsing
function New-IniDoc {
  return @{ Map = @{}; Keys = @() }
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

# write one key: an existing key keeps its position, a new one is appended
function Set-IniDocValue($doc, [string]$key, [string]$value) {
  if (-not $doc.Map.ContainsKey($key)) {
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($k in @($doc.Keys)) { $list.Add([string]$k) }
    $list.Add($key)
    $doc.Keys = $list.ToArray()
  }
  $doc.Map[$key] = [string]$value
  return $doc
}

# add a key only when it is not there yet; $false means the doc already had it
function Add-IniDocValue($doc, [string]$key, [string]$value) {
  if ($doc.Map.ContainsKey($key)) { return $false }
  [void](Set-IniDocValue $doc $key $value)
  return $true
}

# drop one key; $false when it was not there
function Remove-IniDocValue($doc, [string]$key) {
  if (-not $doc.Map.ContainsKey($key)) { return $false }
  $doc.Map.Remove($key)
  $list = [System.Collections.Generic.List[string]]::new()
  foreach ($k in @($doc.Keys)) { if ([string]$k -ne $key) { $list.Add([string]$k) } }
  $doc.Keys = $list.ToArray()
  return $true
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

# the doc as lines, in file order. Sections are not rebuilt - a grouped key is written in its
# flat form - so this is for inspecting or rebuilding a file, not for editing one in place
# (utils/inifile.ps1 rewrites a single line and keeps the original text).
function ConvertTo-IniText($doc) {
  $out = [System.Collections.Generic.List[string]]::new()
  if ($null -eq $doc) { return $out.ToArray() }
  foreach ($k in @($doc.Keys)) { $out.Add(([string]$k + '=' + [string]$doc.Map[$k])) }
  return $out.ToArray()
}

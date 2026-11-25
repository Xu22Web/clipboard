# packages\module\lib\data.ps1 - an ini file read as data, the way ESM imports json.
#
# Two kinds of module, told apart by the suffix and nothing else - the pairing the whole layer is
# built on:
#
#     .ps1   code      the role ts and js play: functions, Use-Module / Export-Function
#     .ini   data      the role json plays: a document, read instead of run
#
# A script module is dot-sourced: the file runs and its functions land in the scope that wrote the
# line. A data module is not run at all - it is read, and the import answers the value:
#
#     $conf = Use-Module './settings.ini' $PSCommandPath
#     $name = $conf.package.Name
#
# That is `import conf from './settings.json' with { type: 'json' }` in one line of PowerShell: the
# binding is the value, and nothing is added to the scope.
#
# The ini rules are the program's rules (one Key=Value per line, "#" or ";" comments, a [section]
# line prefixing the keys after it), because a file written by hand and a file the program writes
# have to read the same way. The difference is the shape: the tooling's flat reader answers
# "section.key", this one nests, so a section is a table and not a prefix - the shape a json
# document would have had.

# One ini file as nested tables. A key that appears twice in the same section becomes an array;
# a section written twice is merged rather than replaced, which is what a reader expects and what
# keeps an appended section from silently dropping the earlier one.
function Read-ModuleIniFile([string]$path) {
  $root = @{}
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $root }
  $section = $root
  foreach ($raw in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
    $line = ([string]$raw).Trim()
    if ($line.Length -eq 0) { continue }
    if ($line[0] -eq '#' -or $line[0] -eq ';') { continue }
    if ($line.StartsWith('[') -and $line.EndsWith(']')) {
      $name = $line.Substring(1, $line.Length - 2).Trim()
      if (-not $name) { $section = $root; continue }
      if (-not $root.ContainsKey($name) -or -not ($root[$name] -is [System.Collections.IDictionary])) {
        $root[$name] = @{}
      }
      $section = $root[$name]
      continue
    }
    $cut = $line.IndexOf('=')
    if ($cut -lt 1) { continue }
    $key = $line.Substring(0, $cut).Trim()
    $value = $line.Substring($cut + 1).Trim()
    if ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') {
      $value = $value.Substring(1, $value.Length - 2)
    }
    if (-not $section.ContainsKey($key)) { $section[$key] = $value; continue }
    $old = $section[$key]
    if ($old -is [System.Collections.IList] -and -not ($old -is [string])) { $old.Add($value); continue }
    $section[$key] = @($old, $value)
  }
  return $root
}

# What a data module answers for the file its specifier named.
function Read-ModuleData([string]$path) {
  if ((Get-ModulePathKind $path) -ne 'ini') { throw ('not a data module: ' + $path) }
  return (Read-ModuleIniFile $path)
}

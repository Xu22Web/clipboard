# tools\utils\schema.ps1 - validate a settings file against a schema in tools\schema\.
#
# A key that is missing, unknown or of the wrong type stops the command with the list of
# problems, so a typo in a hand-written file never becomes "the command quietly did something
# else". A spec marked Optional is the exception: the command that reads it has a fallback of
# its own, and leaving the key out is a documented choice rather than a mistake.
#
# Two files use this: cli.ini (tools\schema\cli.ps1) and package.ini (tools\schema\package.ps1).
# A schema is a hashtable with Name, Keys and optionally DynamicKeys:
#
#   Keys         fixed keys, written flat ("dev.Interval")
#   DynamicKeys  a prefix and the spec of every key under it ("scripts." + any command name)

# Load a schema file. It is evaluated in its own scope and must return one hashtable.
function Import-ToolSchema([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return (& $path) } catch { return $null }
}

# The spec of one flat key, $null when the schema does not know it. A key under a dynamic
# prefix ("scripts.Dev") takes the prefix spec.
function Get-ToolSchemaSpec($schema, [string]$key) {
  if ($null -eq $schema) { return $null }
  if ($schema.Contains('Keys') -and $schema['Keys'].Contains($key)) { return $schema['Keys'][$key] }
  if ($schema.Contains('DynamicKeys')) {
    foreach ($prefix in @($schema['DynamicKeys'].Keys)) {
      if ($key.StartsWith([string]$prefix, [StringComparison]::Ordinal)) { return $schema['DynamicKeys'][$prefix] }
    }
  }
  return $null
}

# Validate and normalise one value. Never throws; the answer is
# @{ Ok = <bool>; Value = <normalised value>; Error = <reason when not Ok> }.
function Convert-ToolSchemaValue($spec, [string]$raw) {
  $type = [string]$spec['Type']
  $v = ([string]$raw).Trim()
  if ($type -eq 'bool') {
    $l = $v.ToLowerInvariant()
    if (@('1', 'true', 'on', 'yes') -contains $l) { return @{ Ok = $true; Value = '1'; Error = '' } }
    if (@('0', 'false', 'off', 'no') -contains $l) { return @{ Ok = $true; Value = '0'; Error = '' } }
    return @{ Ok = $false; Value = ''; Error = 'expected 0 or 1' }
  }
  if ($type -eq 'int') {
    $n = 0
    if (-not [int]::TryParse($v, [ref]$n)) { return @{ Ok = $false; Value = ''; Error = 'expected an integer' } }
    if ($spec.Contains('Minimum') -and $n -lt [int]$spec['Minimum']) { return @{ Ok = $false; Value = ''; Error = 'must be >= ' + $spec['Minimum'] } }
    if ($spec.Contains('Maximum') -and $n -gt [int]$spec['Maximum']) { return @{ Ok = $false; Value = ''; Error = 'must be <= ' + $spec['Maximum'] } }
    return @{ Ok = $true; Value = [string]$n; Error = '' }
  }
  if ($type -eq 'list') {
    $tokens = @($v -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($tokens.Count -eq 0 -and $spec.Contains('NonEmpty') -and [bool]$spec['NonEmpty']) {
      return @{ Ok = $false; Value = ''; Error = 'needs at least one value' }
    }
    $shape = '^[A-Za-z0-9_.-]+$'
    if ($spec.Contains('Pattern')) { $shape = [string]$spec['Pattern'] }
    $allowed = @()
    if ($spec.Contains('Enum')) { $allowed = @($spec['Enum'] | ForEach-Object { ([string]$_).ToLowerInvariant() }) }
    foreach ($t in $tokens) {
      if ($t -notmatch $shape) { return @{ Ok = $false; Value = ''; Error = 'invalid value: ' + $t } }
      if ($allowed.Count -gt 0 -and ($allowed -notcontains $t.ToLowerInvariant())) {
        return @{ Ok = $false; Value = ''; Error = 'unknown value: ' + $t + ' (allowed: ' + (@($spec['Enum']) -join ', ') + ')' }
      }
    }
    return @{ Ok = $true; Value = ($tokens -join ','); Error = '' }
  }
  # string: any text, but a required one may not be blank and a Pattern must match
  if ($v -eq '' -and $spec.Contains('NonEmpty') -and [bool]$spec['NonEmpty']) {
    return @{ Ok = $false; Value = ''; Error = 'may not be empty' }
  }
  if ($v -ne '' -and $spec.Contains('Pattern') -and $v -notmatch [string]$spec['Pattern']) {
    return @{ Ok = $false; Value = ''; Error = 'does not match ' + $spec['Pattern'] }
  }
  return @{ Ok = $true; Value = $v; Error = '' }
}

# Every problem the file has against the schema, "" when it is clean. A key may be written
# inside its section ("[dev]" + "Interval") or flat ("dev.Interval"); both read the same.
#
# $section limits the check to one section ("build"): a command validates what it reads, so a
# temporary settings file only has to carry that section. Without it the whole file is checked.
#
# The schema itself is checked first: with a mistyped table every value would pass, because
# the value check falls back to "any string" for a type it does not recognise.
function Test-ToolConfigMap($schema, $map, [string]$fileName, [string]$section = '') {
  $out = New-Object System.Collections.Generic.List[string]
  if ($null -eq $schema -or -not $schema.Contains('Keys')) {
    $out.Add('schema not found or malformed')
    return $out.ToArray()
  }
  foreach ($p in @(Test-ToolSchemaFormat $schema)) { $out.Add(('schema: ' + $p)) }
  if ($out.Count -gt 0) { return $out.ToArray() }
  $prefix = ''
  if ($section) { $prefix = $section + '.' }
  foreach ($k in @($map.Keys)) {
    $key = [string]$k
    if ($prefix) {
      if ($key.Contains('.')) {
        # a key of another section belongs to another command
        if (-not $key.StartsWith($prefix)) { continue }
        if ($null -eq (Get-ToolSchemaSpec $schema $key)) { $out.Add(('unknown key: ' + $key)) }
        continue
      }
      # a short name is this section's key written at the top level
      if ($null -eq (Get-ToolSchemaSpec $schema ($prefix + $key))) { $out.Add(('unknown key: ' + $key)) }
      continue
    }
    if ($null -eq (Get-ToolSchemaSpec $schema $key)) { $out.Add(('unknown key: ' + $key)) }
  }
  foreach ($k in @($schema['Keys'].Keys)) {
    if ($prefix -and -not ([string]$k).StartsWith($prefix)) { continue }
    $spec = $schema['Keys'][$k]
    $raw = ''
    if ($map.ContainsKey($k)) { $raw = [string]$map[$k] }
    elseif ($map.ContainsKey($k.Substring($k.IndexOf('.') + 1))) { $raw = [string]$map[$k.Substring($k.IndexOf('.') + 1)] }
    else {
      # an optional key may be left out: the command that reads it has a fallback of its own
      if ($spec.Contains('Optional') -and [bool]$spec['Optional']) { continue }
      $out.Add(('missing key: ' + $k))
      continue
    }
    $r = Convert-ToolSchemaValue $spec $raw
    if (-not $r.Ok) { $out.Add(($k + '=' + $raw + '  (' + $r.Error + ')')) }
  }
  # a dynamic key is not required to exist, but the ones that do must have a valid value
  if ($schema.Contains('DynamicKeys')) {
    foreach ($k in @($map.Keys)) {
      if ($schema['Keys'].Contains([string]$k)) { continue }
      $spec = Get-ToolSchemaSpec $schema ([string]$k)
      if ($null -eq $spec) { continue }
      $r = Convert-ToolSchemaValue $spec ([string]$map[$k])
      if (-not $r.Ok) { $out.Add(([string]$k + '=' + [string]$map[$k] + '  (' + $r.Error + ')')) }
    }
  }
  if ($out.Count -gt 0 -and $fileName) { $out.Insert(0, ($fileName + ' does not match its schema:')) }
  return $out.ToArray()
}

# Check the shape of a schema file itself, so a broken table is reported instead of being
# applied as "everything passes".
function Test-ToolSchemaFormat($schema) {
  $out = New-Object System.Collections.Generic.List[string]
  if ($null -eq $schema) { $out.Add('schema is empty or does not return a hashtable'); return $out.ToArray() }
  if (-not $schema.Contains('Name') -or -not [string]$schema['Name']) { $out.Add('Name is missing') }
  if (-not $schema.Contains('Keys') -or $schema['Keys'] -isnot [System.Collections.IDictionary]) {
    $out.Add('Keys is missing or is not a hashtable')
    return $out.ToArray()
  }
  $types = @('string', 'int', 'bool', 'list', 'enum')
  $groups = @(@{ Label = 'Keys'; Table = $schema['Keys'] })
  if ($schema.Contains('DynamicKeys')) { $groups += @{ Label = 'DynamicKeys'; Table = $schema['DynamicKeys'] } }
  foreach ($group in $groups) {
    foreach ($k in @($group['Table'].Keys)) {
      $spec = $group['Table'][$k]
      $name = [string]$group['Label'] + '[' + [string]$k + ']'
      if ($spec -isnot [System.Collections.IDictionary]) { $out.Add($name + ' is not a hashtable'); continue }
      $t = [string]$spec['Type']
      if ($types -notcontains $t) { $out.Add($name + ': unknown Type ' + $t) }
      if ($t -eq 'enum' -and -not $spec.Contains('Enum')) { $out.Add($name + ': enum needs Enum') }
      if ($group['Label'] -eq 'DynamicKeys' -and -not ([string]$k).EndsWith('.')) { $out.Add($name + ': a dynamic prefix must end with "."') }
    }
  }
  return $out.ToArray()
}

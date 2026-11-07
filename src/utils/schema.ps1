# utils/schema.ps1 - loading a schema file, checking its shape, and reading one value
# against it. Pure: a schema is data, a value is a string, the answer is a value or a
# reason. No ini file is opened here and no setting is applied here.
#
# Schema files live in src/schema\<name>.ps1 and describe one ini file each:
#
#   Name        schema id, also the file name
#   File        the ini file it describes ('clipboard.ini', 'themes\*.ini')
#   Description one line, for whoever reads the schema
#   Version     revision of the schema, bumped when keys are added or removed
#   Properties  [ordered] key -> property spec (top-level and sectioned keys alike)
#   ThemeProperties  optional: the same, for look-and-feel keys a theme may restyle; never
#               ini keys of the settings file (a plugin's ThemeSettings live here)
#   Sections    optional: [ordered] section name -> spec for the keys inside it
#   ExtraSections  optional: spec for a section the schema does not name (plugin sections)
#
# Property spec fields, JSON Schema names where one exists:
#
#   Type        required: string | int | number | bool | list | enum | regex | color |
#               hotkey | theme | any
#   Default     the value the file is written with; every reader falls back to it
#   Minimum     int / number lower bound
#   Maximum     int / number upper bound
#   Enum        for enum: the values allowed; for list: the tokens allowed
#   Pattern     for list: the shape of one item (default: letters, digits, _ . -)
#   Description one line, shown by `config`
#   Ref         the variable the value drives ([ref]$script:X); Apply-Config writes through
#               it, which is why it is a reference and not a name - the minifier renames
#               script variables, a name string would survive and address nothing
#   Themeable   true: a look-and-feel key a theme may restyle, not an ini key
#
# A schema file is dot-sourced (not invoked in a child scope) so a Ref can point at the
# tool's own variables.

# --- value shapes this program happens to use ---------------------------------
# Two checks the type table needs that would otherwise reach into lib\: the list of theme
# names (a folder listing) and the shape of a colour (a regular expression). Both stay here
# so that checking a value never depends on a module that draws.

# Theme names are file names: the list is the folder.
function Get-ThemeNameList([string]$dir) {
  $out = New-Object System.Collections.Generic.List[string]
  try {
    if ($dir -and (Test-Path -LiteralPath $dir)) {
      foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.ini' -File -ErrorAction Stop | Sort-Object -Property Name)) {
        $out.Add($f.BaseName)
      }
    }
  } catch { }
  return $out.ToArray()
}

# '#RRGGBB' (opaque) or '#AARRGGBB' (with alpha)
function Test-ThemeColorValue([string]$spec) {
  return ([string]$spec -match '^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$')
}

# load one schema file; $null when the file is missing or unusable. Checking the shape costs
# about a fifth of a second and the schema ships with the program, so a normal run trusts it:
# only the test suite (-Library) asks for the check.
function Import-Schema([string]$path, [switch]$Validate) {
  if (-not (Test-Path -LiteralPath $path)) {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log ('schema missing: ' + $path) }
    return $null
  }
  $schema = $null
  try { $schema = . $path } catch {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log ('schema failed: ' + $path + ' - ' + $_.Exception.Message) }
    return $null
  }
  if ($Validate) {
    $problems = @(Test-SchemaFormat $schema)
    if ($problems.Count -gt 0) {
      if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log ('schema rejected: ' + $path + ' - ' + ($problems -join '; ')) }
      return $null
    }
  }
  return $schema
}

# the shape of a schema itself: a problem list, empty when the schema is usable
function Test-SchemaFormat($schema) {
  $bad = New-Object System.Collections.Generic.List[string]
  if ($schema -isnot [System.Collections.IDictionary]) {
    $bad.Add('not a dictionary')
    return $bad.ToArray()
  }
  foreach ($field in @('Name', 'Properties')) {
    if (-not $schema.Contains($field)) { $bad.Add('missing ' + $field) }
  }
  if ($schema.Contains('Properties')) {
    $props = $schema['Properties']
    if ($props -isnot [System.Collections.IDictionary]) {
      $bad.Add('Properties is not a dictionary')
    } else {
      foreach ($k in @($props.Keys)) {
        $spec = $props[$k]
        if ($spec -isnot [System.Collections.IDictionary]) { $bad.Add($k + ': not a dictionary'); continue }
        if (-not $spec.Contains('Type')) { $bad.Add($k + ': missing Type'); continue }
        $t = [string]$spec['Type']
        if (@('string', 'int', 'number', 'bool', 'list', 'enum', 'regex', 'color', 'hotkey', 'theme', 'apprule', 'any') -notcontains $t) {
          $bad.Add($k + ': unknown Type ' + $t)
        }
        if ($t -eq 'enum' -and -not $spec.Contains('Enum')) { $bad.Add($k + ': enum needs Enum') }
      }
    }
  }
  return $bad.ToArray()
}

# the property table of a schema
function Get-SchemaProperties($schema) {
  if ($null -eq $schema -or -not $schema.Contains('Properties')) { return $null }
  return $schema['Properties']
}

# the theme-only property table of a schema (a plugin's restyleable keys)
function Get-SchemaThemeProperties($schema) {
  if ($null -eq $schema -or -not $schema.Contains('ThemeProperties')) { return $null }
  return $schema['ThemeProperties']
}

# the spec of one key, $null when this schema does not know it
function Get-SchemaProperty($schema, [string]$key) {
  $props = Get-SchemaProperties $schema
  if ($null -eq $props) { return $null }
  if (-not $props.Contains($key)) { return $null }
  return $props[$key]
}

# register a property the schema file cannot know about - a plugin's settings are declared
# by the plugin itself, and join the settings schema when the plugin loads
function Add-SchemaProperty($schema, [string]$key, $spec) {
  $props = Get-SchemaProperties $schema
  if ($null -eq $props -or $null -eq $spec) { return $false }
  if ($props.Contains($key)) { return $false }
  $props[$key] = $spec
  return $true
}

# the section spec a schema declares ("palette"), or the ExtraSections spec, or $null
function Get-SchemaSection($schema, [string]$name) {
  if ($null -eq $schema) { return $null }
  if ($schema.Contains('Sections')) {
    $sections = $schema['Sections']
    if ($null -ne $sections -and $sections -is [System.Collections.IDictionary] -and $sections.Contains($name)) {
      return $sections[$name]
    }
  }
  if ($schema.Contains('ExtraSections')) { return $schema['ExtraSections'] }
  return $null
}

# the declared default of one key, "" when the schema does not declare one
function Get-SchemaDefault($schema, [string]$key) {
  $spec = Get-SchemaProperty $schema $key
  if ($null -eq $spec -or -not $spec.Contains('Default')) { return '' }
  return [string]$spec['Default']
}

# Validate and normalise one raw value. Never throws; the answer is
# @{ Ok = <bool>; Value = <normalised value>; Error = <reason when not Ok> }.
# The value comes back in its file spelling ('1' / '0', plain numbers), because that is what
# gets written back and what the template shows.
function Convert-SchemaValue($schema, [string]$key, [string]$raw) {
  $spec = Get-SchemaProperty $schema $key
  if ($null -eq $spec) { return @{ Ok = $false; Value = ''; Error = 'unknown key' } }
  $type = [string]$spec['Type']
  $v = ([string]$raw).Trim()
  if ($type -eq 'bool') {
    $l = $v.ToLowerInvariant()
    if (@('1', 'true', 'on', 'yes') -contains $l) { return @{ Ok = $true; Value = '1'; Error = '' } }
    if (@('0', 'false', 'off', 'no') -contains $l) { return @{ Ok = $true; Value = '0'; Error = '' } }
    return @{ Ok = $false; Value = ''; Error = 'expected 0 or 1' }
  }
  if ($type -eq 'int' -or $type -eq 'number') {
    if ($type -eq 'int') {
      $n = 0
      if (-not [int]::TryParse($v, [ref]$n)) { return @{ Ok = $false; Value = ''; Error = 'expected an integer' } }
      if ($spec.Contains('Minimum') -and $n -lt [int]$spec['Minimum']) { return @{ Ok = $false; Value = ''; Error = 'must be >= ' + $spec['Minimum'] } }
      if ($spec.Contains('Maximum') -and $n -gt [int]$spec['Maximum']) { return @{ Ok = $false; Value = ''; Error = 'must be <= ' + $spec['Maximum'] } }
      return @{ Ok = $true; Value = [string]$n; Error = '' }
    }
    $d = 0.0
    if (-not [double]::TryParse($v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
      return @{ Ok = $false; Value = ''; Error = 'expected a number' }
    }
    if ($spec.Contains('Minimum') -and $d -lt [double]$spec['Minimum']) { return @{ Ok = $false; Value = ''; Error = 'must be >= ' + $spec['Minimum'] } }
    if ($spec.Contains('Maximum') -and $d -gt [double]$spec['Maximum']) { return @{ Ok = $false; Value = ''; Error = 'must be <= ' + $spec['Maximum'] } }
    return @{ Ok = $true; Value = $d.ToString([Globalization.CultureInfo]::InvariantCulture); Error = '' }
  }
  if ($type -eq 'enum') {
    foreach ($o in @($spec['Enum'])) { if ([string]$o -ieq $v) { return @{ Ok = $true; Value = [string]$o; Error = '' } } }
    return @{ Ok = $false; Value = ''; Error = 'expected one of: ' + (@($spec['Enum']) -join ', ') }
  }
  if ($type -eq 'regex') {
    if ($v -eq '') { return @{ Ok = $true; Value = ''; Error = '' } }
    try { [void](New-Object System.Text.RegularExpressions.Regex $v); return @{ Ok = $true; Value = $v; Error = '' } }
    catch { return @{ Ok = $false; Value = ''; Error = 'invalid regular expression' } }
  }
  if ($type -eq 'list') {
    $tokens = @($v -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $shape = '^[A-Za-z0-9_.-]+$'
    if ($spec.Contains('Pattern')) { $shape = [string]$spec['Pattern'] }
    # a list may declare the tokens it accepts; one outside that set is a typo, not a new
    # feature, so it is rejected instead of being silently ignored by the consumer
    $allowed = @()
    if ($spec.Contains('Enum')) { $allowed = @($spec['Enum'] | ForEach-Object { ([string]$_).ToLowerInvariant() }) }
    foreach ($t in $tokens) {
      if ($t -notmatch $shape) { return @{ Ok = $false; Value = ''; Error = 'names may only use letters, digits, _ . -' } }
      if ($allowed.Count -gt 0 -and ($allowed -notcontains $t.ToLowerInvariant())) {
        return @{ Ok = $false; Value = ''; Error = 'unknown value: ' + $t + ' (allowed: ' + (@($spec['Enum']) -join ', ') + ')' }
      }
    }
    return @{ Ok = $true; Value = ($tokens -join ','); Error = '' }
  }
  if ($type -eq 'theme') {
    if ($v -eq '') { return @{ Ok = $true; Value = (Get-SchemaDefault $schema $key); Error = '' } }
    # only a real theme name counts: the name is the file in themes\, so there is nothing
    # to guess from. The folder is read here rather than through lib/themes.ps1, because a
    # value check must not depend on the module that draws.
    $have = @(Get-ThemeNameList (Join-Path $Root 'themes'))
    foreach ($n in $have) { if ($n -ieq $v) { return @{ Ok = $true; Value = $n; Error = '' } } }
    if ($have.Count -eq 0) { return @{ Ok = $true; Value = 'win11-dark'; Error = '' } }
    return @{ Ok = $false; Value = ''; Error = 'unknown theme, available: ' + ($have -join ', ') }
  }
  if ($type -eq 'color') {
    if ($v -eq '') { return @{ Ok = $true; Value = ''; Error = '' } }
    if (-not (Test-ThemeColorValue $v)) { return @{ Ok = $false; Value = ''; Error = 'expected #RRGGBB or #AARRGGBB' } }
    return @{ Ok = $true; Value = $v.ToUpperInvariant(); Error = '' }
  }
  if ($type -eq 'hotkey') {
    if ((Parse-Hotkey $v).Vk -eq 0) { return @{ Ok = $false; Value = ''; Error = 'unknown key name' } }
    return @{ Ok = $true; Value = $v; Error = '' }
  }
  if ($type -eq 'apprule') {
    return (Test-AppRuleText $v)
  }
  return @{ Ok = $true; Value = $v; Error = '' }
}

# Check a whole document against a schema: keys it does not know, and values it rejects.
# Returns a problem list, "" when the document is clean. An empty value means "not set",
# which is always allowed - the caller falls back to the default.
function Test-SchemaDoc($schema, $doc) {
  $out = New-Object System.Collections.Generic.List[string]
  if ($null -eq $schema -or $null -eq $doc) { return $out.ToArray() }
  foreach ($k in @($doc.Keys)) {
    $key = [string]$k
    $raw = [string]$doc.Map[$k]
    if ($null -eq (Get-SchemaProperty $schema $key)) { $out.Add('unknown key: ' + $key); continue }
    if ($raw -eq '') { continue }
    $r = Convert-SchemaValue $schema $key $raw
    if (-not $r.Ok) { $out.Add($key + '=' + $raw + '  (' + $r.Error + ')') }
  }
  return $out.ToArray()
}

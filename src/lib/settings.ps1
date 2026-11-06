# lib/settings.ps1 - clipboard.ini as data: the schema that describes every key, and the four
# calls that read or write one value from the file.
#
# This is the layer anything that touches a setting goes through: lib/config.ps1 builds the
# `config` command surface on top of it, and lib/plugin-settings.ps1 registers plugin keys
# into the same schema. Neither has to know how the file is parsed or cached, and neither has
# to call the other - which is why this file exists at all.
#
# Absent keys are not an error: a setting the file does not mention keeps the default that
# base.ps1 declares, and the schema says what that default is.

$script:SettingsSchema = Import-Schema (Join-Path $Root 'schema\clipboard.ps1')
$script:IniSchema = Get-SchemaProperties $script:SettingsSchema
if ($null -eq $script:IniSchema) { $script:IniSchema = [ordered]@{} }

# clipboard.ini, the settings file beside the entry point: one document per file version,
# imported once and re-read only when the file changes on disk
function Read-Ini {
  return (Import-Ini $IniPath).Map
}

# the raw value of one key, "" when the file does not set it
function Get-IniKey([string]$key) {
  return (Import-IniValue $IniPath $key)
}

# validate one raw value against the settings schema
function Convert-IniValue([string]$key, [string]$raw) {
  return (Convert-SchemaValue $script:SettingsSchema $key $raw)
}

# effective value of one key coming from clipboard.ini (null when unset or invalid)
function Get-CfgValue([string]$key) {
  $c = Read-Ini
  if (-not $c.ContainsKey($key)) { return $null }
  $raw = [string]$c[$key]
  if ($raw -eq '') { return $null }
  $r = Convert-IniValue $key $raw
  if (-not $r.Ok) { Write-Log ('config ignored: ' + $key + '=' + $raw + ' (' + $r.Error + ')'); return $null }
  return [string]$r.Value
}

# write exactly one key: the importer keeps the comments and every other line, and drops
# its cached parse so the next read sees the new text
function Set-IniKey([string]$key, [string]$value) {
  try {
    [void](Export-IniValue $IniPath $key $value)
    return $true
  } catch {
    Write-Log ('ini write failed: ' + $_.Exception.Message)
    return $false
  }
}

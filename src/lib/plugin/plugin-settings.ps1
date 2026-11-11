# lib/plugin/plugin-settings.ps1 - the plugin settings surface.
#
# A plugin does not describe its keys itself: it has a schema file of its own next to the
# others, schema\plugins\<name>.ps1, and that file declares both kinds of knobs -
#
#   Properties      clipboard.ini keys, merged into the settings schema as <plugin>.<Key>
#                   (the user's switches, written as a [<plugin>] section in the file)
#   ThemeProperties look-and-feel a theme may restyle through the same section in
#                   themes\*.ini; never an ini key of the settings file
#
# The merge happens when the plugin loads (Register-PluginSettings), so `config`,
# `config get`, `config set` and `config init` handle a plugin key with no extra plumbing.
#
# Loaded right after lib/plugin/plugins.ps1 and only when that file exists: without the plugin
# runtime there is nothing to configure.

$script:PluginSchemaCache = @{}

# the parsed schema of one plugin, $null when it has none
function Get-PluginSchema([string]$Name) {
  if ($script:PluginSchemaCache.ContainsKey($Name)) { return $script:PluginSchemaCache[$Name] }
  $schema = $null
  if ($Name -and (Get-Command Import-Schema -ErrorAction SilentlyContinue)) {
    $schema = Import-Schema (Join-Path $Root (Join-Path 'schema\plugins' ($Name + '.ps1')))
  }
  $script:PluginSchemaCache[$Name] = $schema
  return $schema
}


# Merge every loaded plugin's Properties into the shared schema as <plugin>.<Key>.
# Called once after Load-Plugins; a duplicate key never overwrites a key that is already
# there, whether it came from schema\clipboard.ps1 or from another plugin.
function Register-PluginSettings {
  $map = @{}
  if ($null -eq $script:IniSchema) { $script:PluginSettings = $map; return }
  foreach ($p in @($script:Plugins)) {
    $name = [string]$p['Name']
    $schema = Get-PluginSchema $name
    if ($null -eq $schema) {
      Write-Log ('plugin settings ignored (no schema): ' + $name)
      continue
    }
    $props = Get-SchemaProperties $schema
    if ($null -eq $props -or $props.Count -eq 0) { continue }
    $own = [ordered]@{}
    foreach ($k in @($props.Keys)) {
      $full = $name + '.' + [string]$k
      $s = $props[$k]
      if ($s -isnot [System.Collections.IDictionary] -or -not $s.Contains('Type')) {
        Write-Log ('plugin setting ignored (needs Type): ' + $full)
        continue
      }
      if (-not (Add-SchemaProperty $script:SettingsSchema $full $s)) {
        # A second Initialize-Main in the same process - the one-shot retry after a module the
        # command needed was missing - registers the same key again. The spec is the same, so
        # that is not a collision: only a key this plugin does not own is refused.
        if ($script:IniSchema.Contains($full)) { $own[$full] = $s; continue }
        Write-Log ('plugin setting ignored (duplicate key): ' + $full)
        continue
      }
      $own[$full] = $s
    }
    if ($own.Count -gt 0) { $map[$name] = $own }
  }
  $script:PluginSettings = $map
}


# Every settings key declared by the plugin schemas on disk, in the same shape
# Register-PluginSettings produces (<plugin> -> ordered { '<plugin>.<Key>' -> spec }), but
# WITHOUT loading the plugins: so `config init` can document every key that exists while
# help, the plugin commands and the panel still follow the resolved Plugins=. Only schema
# files are read - no plugin code is executed to find out what a plugin offers.
function Get-AllPluginSettings([string]$SchemaDir) {
  $out = [ordered]@{}
  if (-not $SchemaDir) { return $out }
  try { if (-not (Test-Path -LiteralPath $SchemaDir)) { return $out } } catch { return $out }
  $files = @()
  try { $files = @(Get-ChildItem -LiteralPath $SchemaDir -Filter '*.ps1' -File -ErrorAction Stop | Sort-Object Name) } catch { return $out }
  foreach ($f in $files) {
    $schema = Import-Schema $f.FullName
    if ($null -eq $schema) { continue }
    $props = Get-SchemaProperties $schema
    if ($null -eq $props -or $props.Count -eq 0) { continue }
    $name = [string]$schema['Name']
    if (-not $name) { $name = $f.BaseName }
    $own = [ordered]@{}
    foreach ($k in @($props.Keys)) {
      $spec = $props[$k]
      if ($spec -isnot [System.Collections.IDictionary] -or -not $spec.Contains('Type')) { continue }
      $own[$name + '.' + [string]$k] = $spec
    }
    if ($own.Count -gt 0) { $out[$name] = $own }
  }
  return $out
}


# Resolve plugin settings once, after the config file has been read: ini value when valid,
# otherwise the declared default. Rejects are logged so a typo is not silent.
function Apply-PluginSettings {
  $vals = @{}
  $cache = Read-Ini
  foreach ($name in @($script:PluginSettings.Keys)) {
    foreach ($full in @($script:PluginSettings[$name].Keys)) {
      $spec = $script:PluginSettings[$name][$full]
      $val = $null
      if ($cache.ContainsKey($full) -and [string]$cache[$full] -ne '') {
        $r = Convert-IniValue $full ([string]$cache[$full])
        if ($r.Ok) { $val = [string]$r.Value }
        else { Write-Log ('plugin setting rejected: ' + $full + ' (' + [string]$cache[$full] + ') ' + $r.Error) }
      }
      if ($null -eq $val -and $spec.Contains('Default')) { $val = [string]$spec['Default'] }
      $vals[$full] = [string]$val
    }
  }
  $script:PluginValues = $vals
}


# Effective value of one plugin setting (clipboard.ini). Safe to call from anywhere.
function Get-PluginSetting([string]$Plugin, [string]$Key) {
  $full = ([string]$Plugin) + '.' + ([string]$Key)
  if ($script:PluginValues -and $script:PluginValues.ContainsKey($full)) { return [string]$script:PluginValues[$full] }
  if ($script:IniSchema -and $script:IniSchema.Contains($full)) {
    try {
      $v = Get-CfgValue $full
      if ($null -ne $v) { return [string]$v }
    } catch { }
    $spec = $script:IniSchema[$full]
    if ($spec.Contains('Default')) { return [string]$spec['Default'] }
  }
  return ''
}


# ------------------------------------------------------- theme restyleable values
# ThemeSettings are NOT ini keys of clipboard.ini. They are look-and-feel defaults that a
# theme may restyle through a section named after the plugin in themes\*.ini:
#
#   [item-marks]
#   StarColor=#FFD700
#
# Validation reuses the schema validator (utils/schema.ps1) with a one-key schema built
# from the plugin's spec, so a theme value and an ini value follow the same rules.
function Convert-ThemeSettingValue($spec, [string]$raw) {
  $mini = @{ Name = 'theme-value'; Properties = @{ Value = $spec } }
  $r = Convert-SchemaValue $mini 'Value' ([string]$raw)
  if (-not $r.Ok) { return $null }
  return [string]$r.Value
}


# Collect the ThemeProperties of the loaded plugins (same schema file, other table).
function Register-PluginThemeSettings {
  $map = @{}
  foreach ($p in @($script:Plugins)) {
    $name = [string]$p['Name']
    $schema = Get-PluginSchema $name
    if ($null -eq $schema) { continue }
    $spec = Get-SchemaThemeProperties $schema
    if ($null -eq $spec -or $spec.Count -eq 0) { continue }
    $own = [ordered]@{}
    foreach ($k in @($spec.Keys)) {
      $s = $spec[$k]
      if ($s -isnot [System.Collections.IDictionary] -or -not $s.Contains('Type')) {
        Write-Log ('plugin ThemeSettings ignored (needs Type): ' + $name + '.' + $k)
        continue
      }
      $own[[string]$k] = $s
    }
    if ($own.Count -gt 0) { $map[$name] = $own }
  }
  $script:PluginThemeSpec = $map
}


# Effective theme value: the active theme's section wins, then the plugin default.
function Apply-PluginTheme {
  $vals = @{}
  foreach ($name in @($script:PluginThemeSpec.Keys)) {
    foreach ($k in @($script:PluginThemeSpec[$name].Keys)) {
      $key = [string]$k
      $full = $name + '.' + $key
      $spec = $script:PluginThemeSpec[$name][$key]
      $val = $null
      if ($script:ThemeOverrides -and $script:ThemeOverrides.ContainsKey($full)) {
        $val = Convert-ThemeSettingValue $spec ([string]$script:ThemeOverrides[$full])
        if ($null -eq $val) { Write-Log ('theme value ignored: ' + $full + '=' + [string]$script:ThemeOverrides[$full]) }
      }
      if ($null -eq $val) {
        if ($spec.Contains('Default')) { $val = [string]$spec['Default'] } else { $val = '' }
      }
      $vals[$full] = [string]$val
    }
  }
  $script:PluginThemeValues = $vals
}


# Theme-aware value of one plugin look-and-feel key.
function Get-PluginTheme([string]$Plugin, [string]$Key) {
  $full = ([string]$Plugin) + '.' + ([string]$Key)
  if ($script:PluginThemeValues -and $script:PluginThemeValues.ContainsKey($full)) { return [string]$script:PluginThemeValues[$full] }
  if ($script:PluginThemeSpec -and $script:PluginThemeSpec.ContainsKey([string]$Plugin)) {
    $own = $script:PluginThemeSpec[[string]$Plugin]
    if ($own.Contains([string]$Key)) {
      $spec = $own[[string]$Key]
      if ($spec.Contains('Default')) { return [string]$spec['Default'] }
    }
  }
  return ''
}

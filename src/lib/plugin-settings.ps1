# lib/plugin-settings.ps1 - the plugin settings surface.
#
# Two kinds of knobs, deliberately kept apart: Settings become clipboard.ini keys named
# <plugin>.<Key> (the user's switches), ThemeSettings are not ini keys at all - they are
# look-and-feel defaults a theme may restyle through a section named after the plugin.
#
# Loaded right after lib/plugins.ps1 and only when that file exists: without the plugin
# runtime there is nothing to configure.


# Merge every loaded plugin's Settings block into the shared schema as <plugin>.<Key>.
# Called once after Load-Plugins; a duplicate key never overwrites a base key.
function Register-PluginSettings {
  $map = @{}
  if ($null -eq $script:IniSchema) { $script:PluginSettings = $map; return }
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('Settings')) { continue }
    $spec = $p['Settings']
    if ($spec -isnot [System.Collections.IDictionary]) {
      Write-Log ('plugin settings ignored (not a dictionary): ' + [string]$p['Name'])
      continue
    }
    $name = [string]$p['Name']
    $own = [ordered]@{}
    foreach ($k in @($spec.Keys)) {
      $full = $name + '.' + [string]$k
      $s = $spec[$k]
      if ($s -isnot [System.Collections.IDictionary] -or -not $s.Contains('Kind')) {
        Write-Log ('plugin setting ignored (needs Kind): ' + $full)
        continue
      }
      if ($script:IniSchema.Contains($full)) {
        Write-Log ('plugin setting ignored (duplicate key): ' + $full)
        continue
      }
      $script:IniSchema[$full] = $s
      $own[$full] = $s
    }
    if ($own.Count -gt 0) { $map[$name] = $own }
  }
  $script:PluginSettings = $map
}


# Resolve plugin settings once, after the config file has been read: ini value when valid,
# otherwise the declared default. Rejects are logged so a typo is not silent.
function Apply-PluginSettings {
  $vals = @{}
  $cache = $script:IniCache
  if ($null -eq $cache) { $cache = Read-Ini; $script:IniCache = $cache }
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
# Validation reuses the same Kind vocabulary (color / int / bool / enum / string).
function Convert-ThemeSettingValue($spec, [string]$raw) {
  $v = ([string]$raw).Trim()
  $kind = 'string'
  if ($spec.Contains('Kind')) { $kind = [string]$spec['Kind'] }
  if ($kind -eq 'color') {
    if (Get-Command Convert-ThemeColor -ErrorAction SilentlyContinue) {
      if ($null -eq (Convert-ThemeColor $v)) { return $null }
    }
    return $v
  }
  if ($kind -eq 'int') {
    $n = 0
    if (-not [int]::TryParse($v, [ref]$n)) { return $null }
    if ($spec.Contains('Min') -and $n -lt [int]$spec['Min']) { return $null }
    if ($spec.Contains('Max') -and $n -gt [int]$spec['Max']) { return $null }
    return [string]$n
  }
  if ($kind -eq 'bool') {
    $l = $v.ToLowerInvariant()
    if (@('1', 'true', 'on', 'yes') -contains $l) { return '1' }
    if (@('0', 'false', 'off', 'no') -contains $l) { return '0' }
    return $null
  }
  if ($kind -eq 'enum') {
    foreach ($o in @($spec['Options'])) { if ([string]$o -eq $v) { return [string]$o } }
    return $null
  }
  return $v
}


# Collect the ThemeSettings blocks of the loaded plugins.
function Register-PluginThemeSettings {
  $map = @{}
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('ThemeSettings')) { continue }
    $spec = $p['ThemeSettings']
    if ($spec -isnot [System.Collections.IDictionary]) {
      Write-Log ('plugin ThemeSettings ignored (not a dictionary): ' + [string]$p['Name'])
      continue
    }
    $name = [string]$p['Name']
    $own = [ordered]@{}
    foreach ($k in @($spec.Keys)) {
      $s = $spec[$k]
      if ($s -isnot [System.Collections.IDictionary] -or -not $s.Contains('Kind')) {
        Write-Log ('plugin ThemeSettings ignored (needs Kind): ' + $name + '.' + $k)
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

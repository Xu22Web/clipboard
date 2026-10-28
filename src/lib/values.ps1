# lib/values.ps1 - one value at a time: read it, validate it against the schema, write it.
#
# This sits between the raw reader (lib/ini.ps1) and everything that needs a usable value:
# the config commands, the plugin settings and the panel. Validating a value needs the
# hotkey parser and the theme list, so this layer has to be above both - and keeping it
# separate is what stops config and the plugin settings from calling each other.


function Get-IniKey([string]$key) {
  if ($null -eq $script:IniCache) { $script:IniCache = Read-Ini }
  if ($script:IniCache.ContainsKey($key)) { return [string]$script:IniCache[$key] }
  return ''
}



# validate + normalise one raw value; never throws
function Convert-IniValue([string]$key, [string]$raw) {
  if (-not $script:IniSchema.Contains($key)) { return @{ Ok = $false; Value = ''; Error = 'unknown key' } }
  $spec = $script:IniSchema[$key]
  $v = ([string]$raw).Trim()
  if ($spec.Kind -eq 'bool') {
    $l = $v.ToLower()
    if (@('1', 'true', 'on', 'yes') -contains $l) { return @{ Ok = $true; Value = '1'; Error = '' } }
    if (@('0', 'false', 'off', 'no') -contains $l) { return @{ Ok = $true; Value = '0'; Error = '' } }
    return @{ Ok = $false; Value = ''; Error = 'expected 0 or 1' }
  }
  if ($spec.Kind -eq 'int') {
    $n = 0
    if (-not [int]::TryParse($v, [ref]$n)) { return @{ Ok = $false; Value = ''; Error = 'expected an integer' } }
    if ($null -ne $spec.Min -and $n -lt [int]$spec.Min) { return @{ Ok = $false; Value = ''; Error = 'must be >= ' + $spec.Min } }
    if ($null -ne $spec.Max -and $n -gt [int]$spec.Max) { return @{ Ok = $false; Value = ''; Error = 'must be <= ' + $spec.Max } }
    return @{ Ok = $true; Value = [string]$n; Error = '' }
  }
  if ($spec.Kind -eq 'enum') {
    foreach ($o in @($spec.Options)) { if ($o -eq $v.ToLower()) { return @{ Ok = $true; Value = $o; Error = '' } } }
    return @{ Ok = $false; Value = ''; Error = 'expected one of: ' + (@($spec.Options) -join ', ') }
  }
  if ($spec.Kind -eq 'regex') {
    if ($v -eq '') { return @{ Ok = $true; Value = ''; Error = '' } }
    try { [void](New-Object System.Text.RegularExpressions.Regex $v); return @{ Ok = $true; Value = $v; Error = '' } }
    catch { return @{ Ok = $false; Value = ''; Error = 'invalid regular expression' } }
  }
  if ($spec.Kind -eq 'list') {
    $tokens = @($v -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    # a list may declare the values it accepts; an entry outside that set is a typo, not a
    # new feature, so it is rejected instead of silently ignored by the consumer
    $allowed = @()
    if ($spec.Contains('Options')) { $allowed = @($spec.Options | ForEach-Object { ([string]$_).ToLowerInvariant() }) }
    foreach ($t in $tokens) {
      if ($t -notmatch '^[A-Za-z0-9_.-]+$') { return @{ Ok = $false; Value = ''; Error = 'names may only use letters, digits, _ . -' } }
      if ($allowed.Count -gt 0 -and ($allowed -notcontains $t.ToLowerInvariant())) {
        return @{ Ok = $false; Value = ''; Error = 'unknown value: ' + $t + ' (allowed: ' + ($allowed -join ', ') + ')' }
      }
    }
    return @{ Ok = $true; Value = ($tokens -join ','); Error = '' }
  }
  if ($spec.Kind -eq 'theme') {
    if ($v -eq '') { return @{ Ok = $true; Value = [string]$spec.Default; Error = '' } }
    # only a real theme name counts: the name is the file in themes\, so there is nothing
    # to guess from (an old dark/light alias is rejected like any typo)
    foreach ($n in @(Get-ThemeNames)) { if ($n -ieq $v) { return @{ Ok = $true; Value = $n; Error = '' } } }
    $have = @(Get-ThemeNames)
    if ($have.Count -eq 0) { return @{ Ok = $true; Value = 'win11-dark'; Error = '' } }
    return @{ Ok = $false; Value = ''; Error = 'unknown theme, available: ' + ($have -join ', ') }
  }
  if ($spec.Kind -eq 'color') {
    if ($v -eq '') { return @{ Ok = $true; Value = ''; Error = '' } }
    if (Get-Command Convert-ThemeColor -ErrorAction SilentlyContinue) {
      if ($null -eq (Convert-ThemeColor $v)) { return @{ Ok = $false; Value = ''; Error = 'expected #RRGGBB or #AARRGGBB' } }
      return @{ Ok = $true; Value = $v.ToUpper(); Error = '' }
    }
    return @{ Ok = $true; Value = $v; Error = '' }
  }
  if ($spec.Kind -eq 'hotkey') {
    if ((Parse-Hotkey $v).Vk -eq 0) { return @{ Ok = $false; Value = ''; Error = 'unknown key name' } }
    return @{ Ok = $true; Value = $v; Error = '' }
  }
  return @{ Ok = $true; Value = $v; Error = '' }
}



# effective value of one key coming from clipboard.ini (null when unset, CLI wins, or invalid)
function Get-CfgValue([string]$key) {
  if ($null -eq $script:IniCache) { $script:IniCache = Read-Ini }
  $c = $script:IniCache
  if (-not $c.ContainsKey($key)) { return $null }
  $raw = [string]$c[$key]
  if ($raw -eq '') { return $null }
  $r = Convert-IniValue $key $raw
  if (-not $r.Ok) { Write-Log ('config ignored: ' + $key + '=' + $raw + ' (' + $r.Error + ')'); return $null }
  return [string]$r.Value
}



# rewrite exactly one key, keeping comments and the rest of the file untouched
function Set-IniKey([string]$key, [string]$value) {
  try {
    $pd = Split-Path -Parent $IniPath
    if ($pd -and -not (Test-Path -LiteralPath $pd)) { New-Item -ItemType Directory -Path $pd -Force | Out-Null }
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $IniPath) {
      foreach ($l in [IO.File]::ReadAllLines($IniPath, [Text.Encoding]::UTF8)) { $lines.Add($l) }
    }
    $done = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match ('^\s*' + [regex]::Escape($key) + '\s*=')) {
        $lines[$i] = $key + '=' + $value
        $done = $true
      }
    }
    if (-not $done) { $lines.Add($key + '=' + $value) }
    $tmp = $IniPath + '.tmp'
    [IO.File]::WriteAllText($tmp, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), $Utf8)
    Move-Item -LiteralPath $tmp -Destination $IniPath -Force
    $script:IniCache = $null
    return $true
  } catch {
    Write-Log ('ini write failed: ' + $_.Exception.Message)
    return $false
  }
}

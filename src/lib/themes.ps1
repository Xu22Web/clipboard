# lib/themes.ps1 - theme discovery, validation and application for clipboard.
#
# A theme is one INI file inside <root>\themes:
#
#   name=win11-dark                       # optional, defaults to the file name
#   description=Windows 11 Fluent, dark
#   font_family=                          # empty = auto (Segoe UI Variable Text -> Segoe UI)
#   icon_family=                          # empty = auto (Segoe Fluent Icons -> MDL2)
#
#   [palette]                             # colour tokens, #RRGGBB or #AARRGGBB
#   Surface=#202020
#   Border=#16FFFFFF
#
#   [fonts]                               # point sizes
#   Body=10.5
#
#   [metrics]                             # optional 96 dpi overrides
#   RowHeight=40
#
#   [item-marks]                          # a section named after a plugin restyles that
#   StarColor=#FFC86E                     # plugin's ThemeSettings for this theme only
#
# Loading rules:
#   - only themes\*.ini are considered, by file name, case-insensitively
#   - nothing is executed while resolving a name: Get-ThemeNames / Resolve-ThemeName only
#     look at file names, so a broken theme cannot break `clipboard config`
#   - an unknown name falls back to win11-dark; 'dark' / 'light' are accepted as aliases
#   - unknown colour tokens, bad colour values and out-of-range numbers are logged and
#     skipped instead of failing the whole theme
#   - a missing themes folder or an unreadable theme keeps the built-in palette
#
# The settings file only picks a theme by name (Theme=win11-dark). Individual colours are
# NOT ini keys of clipboard.ini: a theme is a package, and per-theme plugin styling lives
# in the theme ini itself.
#
# The base tool keeps stubs for Get-ThemeNames / Resolve-ThemeName / Read-Theme /
# Apply-Theme plus the built-in palette, so a missing lib\themes.ps1 degrades to
# "built-in palette only" rather than breaking the panel.

# theme names on disk (file names without .ini, sorted); nothing is parsed here
function Get-ThemeNames {
  $out = New-Object System.Collections.Generic.List[string]
  $dir = Get-ThemeDir
  try {
    if (Test-Path -LiteralPath $dir) {
      foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.ini' -File -ErrorAction Stop | Sort-Object Name)) {
        $out.Add($f.BaseName)
      }
    }
  } catch { Write-Log ('themes folder not readable: ' + $_.Exception.Message) }
  return $out.ToArray()
}

# 'dark' / 'light' are accepted as aliases; anything unknown falls back to the default
function Resolve-ThemeName([string]$name) {
  $want = ([string]$name).Trim()
  if ($want -eq '') { return 'win11-dark' }
  if ($want -ieq 'dark') { $want = 'win11-dark' }
  elseif ($want -ieq 'light') { $want = 'win11-light' }
  foreach ($n in @(Get-ThemeNames)) { if ($n -ieq $want) { return $n } }
  return 'win11-dark'
}

# '#RRGGBB' (opaque) or '#AARRGGBB' (with alpha)
function Convert-ThemeColor([string]$spec) {
  Use-Drawing
  $s = ([string]$spec).Trim()
  if ($s -notmatch '^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$') { return $null }
  $hex = $s.Substring(1)
  try {
    if ($hex.Length -eq 6) {
      return [Drawing.Color]::FromArgb(
        [Convert]::ToInt32($hex.Substring(0, 2), 16),
        [Convert]::ToInt32($hex.Substring(2, 2), 16),
        [Convert]::ToInt32($hex.Substring(4, 2), 16))
    }
    return [Drawing.Color]::FromArgb(
      [Convert]::ToInt32($hex.Substring(0, 2), 16),
      [Convert]::ToInt32($hex.Substring(2, 2), 16),
      [Convert]::ToInt32($hex.Substring(4, 2), 16),
      [Convert]::ToInt32($hex.Substring(6, 2), 16))
  } catch { return $null }
}

# Parse one theme ini: top-level keys, plus [palette] [fonts] [metrics] and one section
# per plugin. A section is just a bag of strings; the plugin decides what they mean.
function Read-ThemeIni([string]$path) {
  $t = @{
    Name        = ''
    Description = ''
    FontFamily  = ''
    IconFamily  = ''
    Palette     = @{}
    Fonts       = @{}
    Metrics     = @{}
    PluginTheme = @{}
  }
  $section = ''
  foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
    $l = $line.Trim()
    if ($l.Length -eq 0) { continue }
    if ($l.StartsWith('#') -or $l.StartsWith(';')) { continue }
    if ($l.StartsWith('[') -and $l.EndsWith(']')) {
      $section = $l.Substring(1, $l.Length - 2).Trim().ToLowerInvariant()
      continue
    }
    $i = $l.IndexOf('=')
    if ($i -lt 1) { continue }
    $k = $l.Substring(0, $i).Trim()
    $v = $l.Substring($i + 1).Trim()
    if ($section -eq '') {
      switch ($k.ToLowerInvariant()) {
        'name' { $t.Name = $v }
        'description' { $t.Description = $v }
        'font_family' { $t.FontFamily = $v }
        'icon_family' { $t.IconFamily = $v }
      }
    } elseif ($section -eq 'palette') {
      $t.Palette[$k] = $v
    } elseif ($section -eq 'fonts') {
      $t.Fonts[$k] = $v
    } elseif ($section -eq 'metrics') {
      $t.Metrics[$k] = $v
    } else {
      if (-not $t.PluginTheme.ContainsKey($section)) { $t.PluginTheme[$section] = @{} }
      $t.PluginTheme[$section][$k] = $v
    }
  }
  if ($t.Name -eq '') { $t.Name = [IO.Path]::GetFileNameWithoutExtension($path) }
  return $t
}

# built-in palette = the last known-good Win11 dark look, used when no theme file exists
function Get-BasePalette {
  Use-Drawing
  return @{
    Surface      = [Drawing.Color]::FromArgb(32, 32, 32)
    Field        = [Drawing.Color]::FromArgb(45, 45, 45)
    FieldBorder  = [Drawing.Color]::FromArgb(24, 255, 255, 255)
    Text         = [Drawing.Color]::FromArgb(255, 255, 255)
    Dim          = [Drawing.Color]::FromArgb(170, 170, 170)
    Faint        = [Drawing.Color]::FromArgb(138, 138, 138)
    Accent       = [Drawing.Color]::FromArgb(96, 205, 255)
    AccentSoft   = [Drawing.Color]::FromArgb(30, 96, 205, 255)
    Border       = [Drawing.Color]::FromArgb(22, 255, 255, 255)
    SelBg        = [Drawing.Color]::FromArgb(26, 255, 255, 255)
    HoverBg      = [Drawing.Color]::FromArgb(18, 255, 255, 255)
    BadgeBg      = [Drawing.Color]::FromArgb(16, 255, 255, 255)
    BadgeText    = [Drawing.Color]::FromArgb(200, 200, 200)
    KeyCapBg     = [Drawing.Color]::FromArgb(12, 255, 255, 255)
    KeyCapBorder = [Drawing.Color]::FromArgb(28, 255, 255, 255)
    Mark         = [Drawing.Color]::FromArgb(255, 200, 110)
    Warn         = [Drawing.Color]::FromArgb(255, 153, 164)
  }
}

# the palette the panel draws with
function Get-UiPalette {
  if ($null -ne $script:ThemePalette) { return $script:ThemePalette }
  return (Get-BasePalette)
}

# parse a theme file; $null when the name matches no file or the file cannot be read
function Read-Theme([string]$name) {
  $dir = Get-ThemeDir
  $file = $null
  foreach ($n in @(Get-ThemeNames)) {
    if ($n -ieq $name) { $file = Join-Path $dir ($n + '.ini'); break }
  }
  if (-not $file) { return $null }
  try { return (Read-ThemeIni $file) } catch {
    Write-Log ('theme failed: ' + $name + ' - ' + $_.Exception.Message)
    return $null
  }
}

# Resolve palette / fonts / metric overrides and per-plugin theme values.
# Safe to call repeatedly; every call rebuilds from the theme file.
function Apply-Theme {
  Use-Drawing
  $script:ThemePalette = $null
  $script:ThemeFonts = @{}
  $script:ThemeFace = @{ Font = ''; Icon = '' }
  $script:ThemeOverrides = @{}
  $name = Resolve-ThemeName $script:Theme
  $script:Theme = $name
  $pal = Get-BasePalette
  $t = Read-Theme $name
  if ($t -is [hashtable]) {
    if ($t.FontFamily) { $script:ThemeFace.Font = [string]$t.FontFamily }
    if ($t.IconFamily) { $script:ThemeFace.Icon = [string]$t.IconFamily }
    foreach ($k in @($t.Palette.Keys)) {
      $key = [string]$k
      if (-not $pal.ContainsKey($key)) { Write-Log ('theme colour ignored (unknown token): ' + $name + '.' + $key); continue }
      $c = Convert-ThemeColor ([string]$t.Palette[$k])
      if ($null -eq $c) { Write-Log ('theme colour ignored (bad value): ' + $name + '.' + $key); continue }
      $pal[$key] = $c
    }
    foreach ($k in @($t.Fonts.Keys)) {
      $v = 0.0
      if (-not [double]::TryParse([string]$t.Fonts[$k], [ref]$v) -or $v -lt 6 -or $v -gt 48) {
        Write-Log ('theme font ignored (out of range): ' + $name + '.' + $k)
        continue
      }
      $script:ThemeFonts[[string]$k] = $v
    }
    foreach ($k in @($t.Metrics.Keys)) {
      $key = [string]$k
      if (-not $script:Metric.ContainsKey($key)) { Write-Log ('theme metric ignored (unknown): ' + $name + '.' + $key); continue }
      $v = 0
      if (-not [int]::TryParse([string]$t.Metrics[$k], [ref]$v) -or $v -lt 1 -or $v -gt 4000) {
        Write-Log ('theme metric ignored (out of range): ' + $name + '.' + $key)
        continue
      }
      $script:Metric[$key] = $v
    }
    # plugin sections: <plugin>.<Key> = value, only for keys the plugin declared as
    # ThemeSettings (the plugin layer enforces that when it applies them)
    foreach ($pname in @($t.PluginTheme.Keys)) {
      foreach ($k in @($t.PluginTheme[$pname].Keys)) {
        $script:ThemeOverrides[([string]$pname + '.' + [string]$k)] = [string]$t.PluginTheme[$pname][$k]
      }
    }
  } elseif ($name -ne 'win11-dark') {
    Write-Log ('theme not found, using built-in palette: ' + $name)
  }
  $script:ThemePalette = $pal
}

# lib/theme-stub.ps1 - the built-in palette and the no-op theme stubs.
#
# lib/themes.ps1 replaces every function in this file when it is present. Keeping the
# fallback separate is what lets a package ship without lib/themes.ps1: the panel and the
# CLI then run on the built-in Win11 dark palette instead of failing to start.

# ---------------------------------------------------------------------------- themes
# Theme discovery / validation / loading lives in lib\themes.ps1 (dot-sourced by the
# dispatch region). What stays here: the theme folder, the System.Drawing bootstrap, the
# built-in palette and no-op stubs, so the panel and the CLI still work when that file is
# missing - the tool then simply runs on the built-in palette.
function Get-ThemeDir { return (Join-Path $Root 'themes') }

# Themes are resolved from CLI commands too (config / themes), which never call Load-Forms,
# so System.Drawing has to be available independently of the panel.

# stubs replaced by lib\themes.ps1
function Get-ThemeNames { return @() }
function Resolve-ThemeName([string]$name) {
  return 'win11-dark'
}
function Read-Theme([string]$name) { return $null }
function Apply-Theme { param([switch]$SkipColors) }

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

# Opt into system DPI awareness before any window exists, then derive one scale factor
# that every pixel constant in the picker is multiplied by.

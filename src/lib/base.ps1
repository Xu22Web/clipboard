# lib/base.ps1 - constants, record format and every script-scope default value.
#
# Loaded first: together with ini.ps1 it is the only module that assigns at load time, so
# the rest of the tool sees exactly the defaults it saw when everything was one file.
#
# $Root is deliberately NOT defined here. A dot-sourced file's $PSScriptRoot points at
# lib\, so a path built from it would resolve themes\, plugins\ and data\ one level too
# deep. clipboard.ps1 owns $Root; every module below only reads it.

# --- record format: CBHIST2 + RS-separated records: flags US epoch US payload ----
$RS      = [string][char]30
$US      = [string][char]31
$FILESIG = [string][char]1
$V2TAG   = 'CBHIST2'

# --- runtime identities (stable: shortcuts and a second instance rely on them) ----
$MutexName = 'Local\clipboard.daemon'
$EventName = 'Local\clipboard.show'
$StopName  = 'Local\clipboard.stop'
$StoreLock = 'Local\clipboard.store'

# --- UI metrics: 96 dpi design values, every one of them goes through Px() --------
$script:Metric = @{
  RowHeight = 40; HeadHeight = 68; FootHeight = 40
  Margin = 14; FieldHeight = 40
  RowInset = 6; RowRadius = 4; PanelRadius = 8
  IconSlot = 20; TextGap = 38
  MarkSlot = 16; MarkCount = 2; TimeWidth = 52
  CapWidth = 22; CapHeight = 18; BadgeGap = 12
  ScrollIdle = 3; ScrollHot = 6
  ChipHeight = 18
}

# --- glyphs: present in both Segoe Fluent Icons (Win11) and MDL2 (Win10) ----------
$script:Glyphs = @{
  Search  = [string][char]0xE721
  Clear   = [string][char]0xE8BB
  History = [string][char]0xE81C
}

# --- timings (ms) ------------------------------------------------------------------
$script:Timing = @{
  Debounce = 150; FootMessage = 3200; Confirm = 5000
  CloseOnBlur = 450; HotkeyPoll = 30; Tooltip = 700
}

$script:UiScale = 1.0

# A missing or partial clipboard.ini is fine: these values apply until the file
# overrides them. Nothing in this region creates or rewrites the settings file.
$script:WinWidth = 700
# The panel height is derived, never stored: it is the chrome plus whole rows, so the only
# knob is how many rows are visible. The row height and chrome live in $script:Metric above
# (a theme may restyle them) and are read through Get-PanelRowHeight / Get-PanelChrome.
$script:Rows = 10
$script:WinLeft = ''
$script:WinTop = ''
$script:SaveWinWidth = $false
$script:SaveWinPos = $false
$script:ShowTime = $true
$script:ShowTypeIcon = $true
$script:HighlightOn = $true
$script:HighlightMax = 8192
$script:ShowNewlineMarker = $true
$script:UndoOn = $true
$script:DpiAware = $true
$script:ScrollLines = 0
$script:Animations = $true
# `install` creates both shortcuts unless one of these is 0
$script:Autostart = $true
$script:DesktopShortcut = $true
# Themes live in themes\<name>.ps1 and are picked by name; win11-dark is the default.
$script:Theme = 'win11-dark'
$script:ThemePalette = $null      # resolved Drawing.Color table, $null = built-in fallback
$script:ThemeFonts = @{}          # Body / Small / Tiny / Title / Icon / IconSmall / IconBig
$script:ThemeFace = @{ Font = ''; Icon = '' }   # optional family overrides from the theme
$script:ThemeOverrides = @{}      # '<plugin>.<Key>' -> default supplied by the theme
$script:ExcludePattern = ''
$script:ShowBalloon = $true
# Runtime knobs: these are settings, and settings only ever come from clipboard.ini
# (`clipboard config set`). A value on the command line is rejected by the param block.
$script:Hotkey = 'Ctrl+Alt+V'
$script:PasteKeys = '^v'
$script:HotkeyFallbacks = ''
$script:ModReleaseTimeout = 1200
$script:PasteSettle = 80
$script:MaxItems = 300
$script:MaxBytes = 204800
$script:MaxTotal = 4194304
$script:Interval = 300
$script:NoPaste = $false
# Plugins load by default: clipboard.ini spells out every plugin name, and the resolved
# list keeps that order.
$script:PluginList = @()
$script:Plugins = @()
$script:PluginSettings = @{}
$script:PluginValues = @{}
$script:PluginThemeSpec = @{}
$script:PluginThemeValues = @{}
$script:RecCache = $null
$script:IniCache = $null

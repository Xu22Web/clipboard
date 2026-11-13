# lib/base.ps1 - constants, record format and every script-scope default value.
#
# Loaded first: together with ini.ps1 it is the only module that assigns at load time, so
# the rest of the tool sees exactly the defaults it saw when everything was one file.
#
# $Root is deliberately NOT defined here. A dot-sourced file's $PSScriptRoot points at
# lib\, so a path built from it would resolve themes\, plugins\ and data\ one level too
# deep. clipboard.ps1 owns $Root; every module below only reads it.

# --- record format ------------------------------------------------------------
# CBHIST RS <data version> RS <flags> US <epoch> US <extra> US <payload> RS ...
# extra is '' for a record with no formatted-text sidecar. The type char is 't' (text),
# 'f' (file list) or 'i' (image); everything after it is the mark set.
$RS      = [string][char]30
$US      = [string][char]31
$FILESIG = [string][char]1
$IMGSIG  = [string][char]3
$TAG     = 'CBHIST'
# Layout version of the store. A release that changes the records bumps this number and adds
# the matching step to lib/migrate.ps1. Only this version is read: an older file is upgraded
# by `clipboard migrate`, never by a second code path in the reader.
$script:DataVersion = 1

# --- version --------------------------------------------------------------------
# package.ini owns the number. This is the development path: read it from the file above the
# script folder. tools\build.ps1 replaces the marked block with a literal assignment, so a
# package carries the value and reads nothing at run time.
#@version-begin
$script:Version = '0.0.0'
try {
  # the repository keeps package.ini one level above src\; a standalone copy may keep it
  # beside the script, which is also how a test sandbox sees the real number
  foreach ($versionFile in @((Join-Path (Split-Path -Parent $Root) 'package.ini'), (Join-Path $Root 'package.ini'))) {
    if (-not (Test-Path -LiteralPath $versionFile)) { continue }
    foreach ($versionLine in [IO.File]::ReadAllLines($versionFile)) {
      if ($versionLine -match '^\s*version\s*=\s*(\S+)\s*$') { $script:Version = $Matches[1]; break }
    }
    if ($script:Version -ne '0.0.0') { break }
  }
} catch { }
#@version-end

# --- runtime identities (stable: shortcuts and a second instance rely on them) ----
$MutexName = 'Local\clipboard.daemon'
$EventName = 'Local\clipboard.show'
$StopName  = 'Local\clipboard.stop'
$StoreLock = 'Local\clipboard.store'

# --- UI metrics: 96 dpi design values, every one of them goes through Px() --------
# A theme may override any key from its [metrics] section. MetricDefault is the built-in
# table Apply-Theme restores first, so switching themes never leaves a value behind.
$script:Metric = @{
  RowHeight = 40; HeadHeight = 68; FootHeight = 40; PanelRadius = 8
  # The row block is balanced against the window: the scrollbar lane shifts it right, so the
  # two insets are not equal - RowRight must stay twice RowInset or every row sits off centre
  # (left margin = 1 + RowInset + lane, right margin = lane + RowRight - RowInset + 1).
  RowInset = 4; RowGap = 2; RowRight = 8; RowRadius = 4; RowMinWidth = 60
  TextInset = 12; IconX = 10; IconSlot = 20; TextGap = 38
  TextMarkGap = 8; TextMinWidth = 20
  MarkSlot = 16; MarkCount = 2; MarkGlyphWidth = 14; MarkGap = 6; MarkGap2 = 2
  TimeWidth = 52; TimeGap = 12
  CapWidth = 48; CapHeight = 18; CapGap = 10; CapRadius = 4
  SelBarX = 3; SelBarWidth = 3; SelBarInset = 11; SelBarRadius = 1
  ChipHeight = 18
}
$script:MetricDefault = $script:Metric.Clone()

# --- glyphs: present in both Segoe Fluent Icons (Win11) and MDL2 (Win10) ----------
$script:Glyphs = @{
  Search  = [string][char]0xE721
  Clear   = [string][char]0xE8BB
  History = [string][char]0xE81C
}

# --- timings (ms) ------------------------------------------------------------------
# Named by what the message means, not by how long it happens to be.
$script:Timing = @{
  Debounce = 150       # typing in the search box before the list is rebuilt
  FootBrief = 1200     # the key did nothing, one line is enough
  FootShort = 1500     # nothing to do
  FootInfo = 2000      # an action succeeded
  FootWarn = 2600      # an action was refused, with the way out
  FootMessage = 3200   # a plugin's note, or a hint worth reading
  Confirm = 5000       # "press again to clear"
  CloseOnBlur = 450    # takeover mode: ignore the activation that opens the panel
}

$script:UiScale = 1.0

# A missing or partial clipboard.ini is fine: these values apply until the file
# overrides them. Nothing in this region creates or rewrites the settings file.
$script:WinWidth = 700
# The panel height is derived, never stored: it is the chrome plus whole rows, so the only
# knob is how many rows are visible. The row height and chrome live in $script:Metric above
# (a theme may restyle them) and are read through Get-PanelRowHeight / Get-PanelChrome.
$script:Rows = 10
# The compact panel is the same window with fewer rows, a narrower width and less chrome. Its
# own two numbers keep Rows / WindowWidth meaning the full panel.
$script:CompactMode = $false
$script:CompactRows = 6
$script:CompactWidth = 520
$script:WinLeft = ''
$script:WinTop = ''
$script:SaveWinPos = $false
# with no saved position the panel sits on the window it was opened from instead of the
# centre of that monitor; opt-in, because the middle of the screen is the familiar spot
$script:PlaceNearForeground = $false
# a caret is a tighter anchor than the window: the compact panel always uses it, the full
# panel only when asked, because its height would cover the line being read
$script:PlaceAtCaret = $false
$script:ShowTime = $true
$script:ShowTypeIcon = $true
# a picture or formatted-text row shows a small copy of its first picture in the icon slot
$script:ShowThumbnails = $true
$script:HighlightOn = $true
$script:HighlightMaxBytes = 8192
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
$script:ThemeSchema = $null        # schema/theme.ps1, loaded by lib/themes.ps1 on first use
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
# Size settings are named <Max|Inline> + <object> + <unit>: Text is the plain payload, Image
# one picture, Html / Rtf one block of a formatted copy, Media the files those own. The unit is
# in the name because two of these are counted in characters and the rest in bytes.
$script:MaxItems = 300
$script:MaxTextBytes = 204800
$script:MaxTextTotalBytes = 4194304
# media (image files, html/rtf sidecars) has its own budget: a 4 MB text total would evict
# every screenshot, so the two are counted apart and trimmed apart
$script:MaxMediaTotalBytes = 134217728
$script:CaptureImages = $true
$script:MaxImageBytes = 16777216
$script:CaptureRich = $true
# the html and the rtf are measured apart, so a large rtf cannot cost the html.
# 20 MB of rtf carries about 10 MB of picture (the hex spelling doubles every byte)
$script:MaxHtmlBytes = 20971520
$script:MaxRtfBytes = 20971520
# a picture the html points at is inlined only when it is at most this large, 0 = never
$script:InlineImageUpToBytes = 4194304
# an rtf above this size keeps its words and layout but loses every picture (each one becomes
# an [image not saved] marker), so a big document still pastes without a long stall. 0 = never
# drop them; above MaxRtfBytes the rtf is not kept at all.
$script:RtfImagesUpToBytes = 8388608
$script:PasteRich = $true
# a file list also goes on the clipboard as text, so an address bar or a terminal gets the paths
$script:PasteFilesAsText = $true
# type plain text into the focused control instead of sending the paste key: kept off by
# default, because it is slower on long text and cannot carry formatting
$script:PasteTyping = $false
# per program paste behaviour, empty = every program behaves the same (see utils/apprules.ps1)
$script:AppRules = ''
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
# records get a number when the store is parsed; the panel keys its caches by it instead of
# by the payload, because hashing a 200 KB text on every paint is what made it stutter
$script:RecKey = 0
# how many rows the file on disk holds, dropped duplicates and stale rows included: a capture
# appends, and the file is folded back into a clean list once it carries twice what the
# history may show
$script:RecLines = 0
# how many of those rows are tombstones a delete appended: a third of the file being
# tombstones is the other reason to fold
$script:RecGone = 0
# a payload above this many characters is kept in data\blobs instead of the history file:
# rewriting a 4 MB history on every capture is what hitched the panel
$script:BlobChars = 32768
# in-band reference to a blob (STX + B: + 40 hex chars of sha1); no real text starts with it
$script:BlobMark = [string][char]2 + 'B:'
# how much of an entry the hover preview reads: the card shows a screenful, and clamping here
# is what keeps a 200 KB entry as cheap as a 200 character one
$script:PreviewChars = 6000
# the card only appears after the cursor has rested on a row, and can be switched off
$script:PreviewHover = $true
$script:PreviewDelay = 350

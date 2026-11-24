# renderer\src\windows\tray-menu.ps1 - the tray menu, drawn the way the panel and the settings window are.
#
# The menu used to be a plain ContextMenuStrip: Windows draws those in the system colours, so
# beside a Fluent panel it read as somebody else's window. What it is now is the same surface,
# the same 1 px frame and the same rounded rows, with a glyph column, a right-hand column for a
# hint or a switch, and one row per action - the shape the settings window uses.
#
# The strip and its rows are C# (Cb.TrayMenu / Cb.TrayItem in lib\assembly\cb.native.cs) because
# ToolStripItem paints itself through an override, which a script cannot supply. Everything
# else stays here: the numbers go through Px() like every other pixel constant, the colours come
# from the panel palette, and the fonts are the panel's own, so a theme restyles all three
# surfaces at once.

# The measurements follow the WinUI MenuFlyout template, at the 96 dpi design size: a row is
# 32 px tall (MenuFlyoutThemeMinHeight), an icon is 16 px square, the row carries 12 px of padding
# on both sides and 12 px between the icon and its label, and a separator is its own row - a 1 px
# line with one pixel above it and one below (MenuFlyoutSeparatorHeight 1 inside a -4,1,-4,1
# padding), reaching 4 px past the row padding on either side. Only the width is the tool's own:
# the tray menu is 240 px so "Edit settings file..." still fits beside a hint or a switch.
function Get-TrayMenuLayout {
  return @{
    Width = (Px 240)
    RowHeight = (Px 32)
    Radius = (Get-WindowRadius)
    RowRadius = (Px 5)
    PadLeft = (Px 12)
    PadRight = (Px 12)
    GlyphBox = (Px 16)
    Gap = (Px 12)
    Top = (Px 4)
    Bottom = (Px 4)
    # the line spans the row content box grown by the 4 px of that negative padding, so it keeps
    # a visible margin at both ends and still lines up the same way in every menu
    SeparatorInset = ((Px 12) - (Px 4))
    SeparatorHeight = (Px 3)
    SwitchWidth = (Px 26)
    SwitchHeight = (Px 14)
  }
}

# Everything the C# side needs to draw one menu, resolved once from the palette and the fonts.
# $Width overrides the tray menu's own width: the row menu in the panel is a little wider, because
# its labels and shortcut column are longer than the tray's.
function New-TrayMenuSkin([int]$Width = 0) {
  $pal = Get-UiPalette
  [void](Initialize-PanelFonts)
  $skin = New-Object Cb.TraySkin
  $skin.Surface = $pal.Surface
  $skin.Border = $pal.Border
  $skin.Text = $pal.Text
  $skin.Dim = $pal.Dim
  $skin.Faint = $pal.Faint
  $skin.Accent = $pal.Accent
  $skin.Warn = $pal.Warn
  $skin.Hover = $pal.HoverBg
  $skin.Selected = $pal.SelBg
  # DividerStrokeColorDefault, the token MenuFlyoutSeparatorBackground points at: #15FFFFFF over a
  # dark surface and #0F000000 over a light one. It is not one alpha in both themes - the dark
  # value is 8% white and the light one 6% black - which is why the surfaces use two.
  $dark = ((0.299 * $pal.Surface.R) + (0.587 * $pal.Surface.G) + (0.114 * $pal.Surface.B)) -lt 128
  $divider = if ($dark) { [Drawing.Color]::FromArgb(0x15, 255, 255, 255) } else { [Drawing.Color]::FromArgb(0x0F, 0, 0, 0) }
  $skin.Separator = $divider
  $skin.Field = $pal.Field
  $skin.FieldBorder = $pal.FieldBorder
  $skin.Body = $script:FBody
  $skin.Small = $script:FSmall
  # MenuFlyoutItem's icon is a 16 px square. The icon face only names the family the glyph is cut
  # from: Cb.TrayItem rasterises each glyph and fits its own ink to GlyphBox, so the drawn size is
  # the skin's, not the font's
  $skin.Glyph = $script:FIcon
  $layout = Get-TrayMenuLayout
  if ($Width -gt 0) { $layout.Width = $Width }
  foreach ($k in @($layout.Keys)) { $skin.$k = [int]$layout[$k] }
  # the same number the panel uses: it measures the body font against the icon font, and both
  # surfaces set their icons out of those two
  $skin.IconDrop = [int]$script:IconDrop
  return $skin
}

# The glyphs come from the same two icon fonts the panel uses (Segoe Fluent Icons, with Segoe
# MDL2 Assets as the fallback), addressed by code point. The two the panel already names are
# read from its table; the rest are the ones a menu needs beyond it.
function Get-TrayGlyphs {
  return @{
    Mark = [string][char]0xE77F      # paste: the closest glyph to the clipboard mark the tray icon draws
    History = [string]$script:Glyphs.History
    Rows = [string][char]0xE7C3
    Pause = [string][char]0xE769
    # The broom, not a cross: at the menu's 12 pt the only thin crosses (E711 Cancel, E894 Clear)
    # ink 11 px where every other icon inks 16, and the cross that does ink 16 (E8BB ChromeClose)
    # is the thick title-bar one - measured, it carried 84 ink pixels against the trash can's 84
    # and the pencil's 60, and read as a bigger, bolder icon beside them. EA99 inks 16 x 15 with
    # 56, the same weight as the rest.
    Clear = [string][char]0xEA99
    Settings = [string][char]0xE713
    Edit = [string][char]0xE70F
    Folder = [string][char]0xE8B7
    Restart = [string][char]0xE72C
    Info = [string][char]0xE946
    Exit = [string][char]0xE7E8
  }
}

# One row. A header is the same row without the hover state, not selectable at all - an arrow
# key may not land on it - and with the accent on its glyph: it names the menu and carries the
# count the old "17 entries" line used to spell out. A caption is the quiet label over a group:
# caption size, the faint ink, and one row shorter than an action.
function New-TrayMenuRow {
  param($Skin, [string]$Label, [string]$Glyph = '', [switch]$Switch, [switch]$Header, [switch]$Caption)
  $row = New-Object Cb.TrayItem -ArgumentList @($Label, $Skin)
  $row.Glyph = $Glyph
  $row.IsHeader = [bool]$Header
  $row.IsCaption = [bool]$Caption
  $row.IsSwitch = [bool]$Switch
  if ($Caption) { $row.Size = New-Object Drawing.Size ([int]$Skin.Width), ([int](Px 26)) }
  return $row
}

# A group boundary is a row that carries only a hairline: the system separator ignores the height
# a caller gives it, so Add-TrayMenuSeparator adds a row of this menu instead and the line, the
# air around it and its width are the same everywhere.
function Add-TrayMenuSeparator {
  param($Menu, $Skin)
  $row = New-Object Cb.TrayItem -ArgumentList @('', $Skin)
  $row.IsSeparator = $true
  $row.Size = New-Object Drawing.Size ([int]$Skin.Width), ([int]$Skin.SeparatorHeight)
  [void]$Menu.Items.Add($row)
  return $row
}

# The menu itself. The item order and the glyphs are the design; what each row does belongs to
# the caller (lib/serve.ps1 binds the handlers), and so does anything that has to stay current
# while the resident lives - the count on the header, the two switches.
#
# The glyphs are the ones this tool already draws elsewhere in the panel (Segoe Fluent Icons,
# with Segoe MDL2 Assets as the fallback), and only code points that were seen rendering are
# used: a glyph that falls back to a box is worse than no glyph at all.
function New-TrayMenu {
  param($Skin)
  $menu = New-Object Cb.TrayMenu -ArgumentList $Skin
  $gl = Get-TrayGlyphs
  $items = @{}
  $items.Header = New-TrayMenuRow -Skin $Skin -Label 'clipboard' -Glyph $gl.Mark -Header
  [void]$menu.Items.Add($items.Header)
  [void](Add-TrayMenuSeparator $menu $Skin)
  $items.Show = New-TrayMenuRow -Skin $Skin -Label (Get-UiText 'menu.showHistory') -Glyph $gl.History
  [void]$menu.Items.Add($items.Show)
  $items.Compact = New-TrayMenuRow -Skin $Skin -Label (Get-UiText 'menu.compact') -Glyph $gl.Rows -Switch
  [void]$menu.Items.Add($items.Compact)
  $items.Pause = New-TrayMenuRow -Skin $Skin -Label (Get-UiText 'menu.pause') -Glyph $gl.Pause -Switch
  [void]$menu.Items.Add($items.Pause)
  $items.Clear = New-TrayMenuRow -Skin $Skin -Label (Get-UiText 'menu.clearHistory') -Glyph $gl.Clear
  [void]$menu.Items.Add($items.Clear)
  [void](Add-TrayMenuSeparator $menu $Skin)
  $items.Settings = New-TrayMenuRow -Skin $Skin -Label (Get-UiText 'menu.settings') -Glyph $gl.Settings
  [void]$menu.Items.Add($items.Settings)
  $items.EditFile = New-TrayMenuRow -Skin $Skin -Label (Get-UiText 'menu.editFile') -Glyph $gl.Edit
  [void]$menu.Items.Add($items.EditFile)
  $items.Folder = New-TrayMenuRow -Skin $Skin -Label (Get-UiText 'menu.openFolder') -Glyph $gl.Folder
  [void]$menu.Items.Add($items.Folder)
  $items.Restart = New-TrayMenuRow -Skin $Skin -Label (Get-UiText 'menu.restart') -Glyph $gl.Restart
  [void]$menu.Items.Add($items.Restart)
  $items.About = New-TrayMenuRow -Skin $Skin -Label (Get-UiText 'menu.about') -Glyph $gl.Info
  [void]$menu.Items.Add($items.About)
  [void](Add-TrayMenuSeparator $menu $Skin)
  $items.Exit = New-TrayMenuRow -Skin $Skin -Label (Get-UiText 'menu.exit') -Glyph $gl.Exit
  [void]$menu.Items.Add($items.Exit)
  # the size is settled here rather than at the first open: the drop-down positions itself from
  # the size it has when it opens, and the one-row placeholder it is built with would put the
  # first menu below the tray icon instead of above it (measured, 27 px too low)
  $menu.Fit()
  $items.Menu = $menu
  return $items
}

# Where a menu whose rows are rebuilt per opening has to place itself. Its final size only exists
# once it has opened, and the system then pushes a tall menu inside the work area instead of
# flipping it (measured: pointer at y=622, menu 482..1031 on a 1032 px work area). The rule is
# Get-MenuPlacement in renderer/src/windows/picker-geom.ps1, the same arithmetic the panel places itself with;
# this only hands it the pointer, the size and the screen the pointer is on, so every menu that
# needs it shares one implementation and one test.
function New-TrayMenuPlacer {
  return [System.Func[System.Drawing.Point, System.Drawing.Size, System.Drawing.Point]]{
    param($ptr, $size)
    $area = Get-AreaAt ([Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.WorkingArea }) $null ([int]$ptr.X) ([int]$ptr.Y)
    if ($null -eq $area) { return $ptr }
    $p = Get-MenuPlacement $area ([int]$ptr.X) ([int]$ptr.Y) ([int]$size.Width) ([int]$size.Height)
    return (New-Object System.Drawing.Point ([int]$p.Left), ([int]$p.Top))
  }
}

# What changes between two openings of the same menu: the count on the header, the hotkey that
# actually took effect, and the two switches. One call so the Opening handler in serve.ps1 stays
# a few lines, and so a new row that shows state has one place to be updated.
function Update-TrayMenu {
  param($Menu, [int]$Entries = -1, [string]$Hotkey = '', [bool]$Paused = $false, [bool]$Compact = $false)
  if ($null -eq $Menu) { return }
  # The row words are read every time the menu opens. A language can be saved while the resident
  # keeps running (a settings window in its own process, or one opened from this tray), and a menu
  # built before that must not keep the old words: re-labelling the rows is enough, the rows, the
  # glyphs and the skin stay as they are.
  $words = @(
    @('Show', 'menu.showHistory'), @('Compact', 'menu.compact'), @('Pause', 'menu.pause'),
    @('Clear', 'menu.clearHistory'), @('Settings', 'menu.settings'),
    @('EditFile', 'menu.editFile'), @('Folder', 'menu.openFolder'),
    @('Restart', 'menu.restart'), @('About', 'menu.about'), @('Exit', 'menu.exit')
  )
  foreach ($w in $words) {
    try {
      $row = $Menu[[string]$w[0]]
      if ($null -ne $row) { $row.Text = (Get-UiText ([string]$w[1])) }
    } catch { }
  }
  try {
    if ($Entries -ge 0) {
      $Menu.Header.Hint = (Get-UiTextCount 'menu.entries' $Entries)
    }
  } catch { }
  try { if ($Hotkey) { $Menu.Show.Hint = $Hotkey } } catch { }
  try { $Menu.Pause.Checked = $Paused } catch { }
  try { $Menu.Compact.Checked = $Compact } catch { }
}

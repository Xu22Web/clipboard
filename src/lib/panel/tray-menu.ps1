# lib/panel/tray-menu.ps1 - the tray menu, drawn the way the panel and the settings window are.
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

# The measurements at the 96 dpi design size. A row is 28 px with a 10.5 pt label - tighter
# than a settings row and tighter than the system menu this one replaces, which is what a menu
# opened from the tray should be: the settings window is the place to be roomy. The menu is
# 222 px, which still fits "Edit settings file..." beside its column.
function Get-TrayMenuLayout {
  return @{
    Width = (Px 222)
    RowHeight = (Px 28)
    Radius = (Get-WindowRadius)
    RowRadius = (Px 5)
    PadLeft = (Px 9)
    PadRight = (Px 11)
    GlyphBox = (Px 18)
    Gap = (Px 8)
    Top = (Px 4)
    Bottom = (Px 4)
    SeparatorInset = (Px 9)
    SeparatorGap = (Px 7)
    SwitchWidth = (Px 26)
    SwitchHeight = (Px 14)
  }
}

# Everything the C# side needs to draw one menu, resolved once from the palette and the fonts.
function New-TrayMenuSkin {
  $pal = Get-UiPalette
  [void](Initialize-PanelFonts)
  $skin = New-Object Cb.TraySkin
  $skin.Surface = $pal.Surface
  $skin.Border = $pal.Border
  $skin.Text = $pal.Text
  $skin.Dim = $pal.Dim
  $skin.Faint = $pal.Faint
  $skin.Accent = $pal.Accent
  $skin.Hover = $pal.HoverBg
  $skin.Selected = $pal.SelBg
  $skin.Field = $pal.Field
  $skin.FieldBorder = $pal.FieldBorder
  $skin.Body = $script:FBody
  $skin.Small = $script:FSmall
  $skin.Glyph = $script:FIconSmall
  $layout = Get-TrayMenuLayout
  foreach ($k in @($layout.Keys)) { $skin.$k = [int]$layout[$k] }
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
    Clear = [string]$script:Glyphs.Clear
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
# count the old "17 entries" line used to spell out.
function New-TrayMenuRow {
  param($Skin, [string]$Label, [string]$Glyph = '', [switch]$Switch, [switch]$Header)
  $row = New-Object Cb.TrayItem -ArgumentList @($Label, $Skin)
  $row.Glyph = $Glyph
  $row.IsHeader = [bool]$Header
  $row.IsSwitch = [bool]$Switch
  return $row
}

function Add-TrayMenuSeparator {
  param($Menu, $Skin)
  $sep = New-Object Windows.Forms.ToolStripSeparator
  $sep.AutoSize = $false
  $sep.Margin = New-Object Windows.Forms.Padding 0
  $sep.Size = New-Object Drawing.Size ([int]$Skin.Width), ([int]$Skin.SeparatorGap)
  [void]$Menu.Items.Add($sep)
  return $sep
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
  $items.Show = New-TrayMenuRow -Skin $Skin -Label 'Show history' -Glyph $gl.History
  [void]$menu.Items.Add($items.Show)
  $items.Compact = New-TrayMenuRow -Skin $Skin -Label 'Compact mode' -Glyph $gl.Rows -Switch
  [void]$menu.Items.Add($items.Compact)
  $items.Pause = New-TrayMenuRow -Skin $Skin -Label 'Pause capture' -Glyph $gl.Pause -Switch
  [void]$menu.Items.Add($items.Pause)
  $items.Clear = New-TrayMenuRow -Skin $Skin -Label 'Clear history...' -Glyph $gl.Clear
  [void]$menu.Items.Add($items.Clear)
  [void](Add-TrayMenuSeparator $menu $Skin)
  $items.Settings = New-TrayMenuRow -Skin $Skin -Label 'Settings...' -Glyph $gl.Settings
  [void]$menu.Items.Add($items.Settings)
  $items.EditFile = New-TrayMenuRow -Skin $Skin -Label 'Edit settings file...' -Glyph $gl.Edit
  [void]$menu.Items.Add($items.EditFile)
  $items.Folder = New-TrayMenuRow -Skin $Skin -Label 'Open data folder' -Glyph $gl.Folder
  [void]$menu.Items.Add($items.Folder)
  $items.Restart = New-TrayMenuRow -Skin $Skin -Label 'Restart' -Glyph $gl.Restart
  [void]$menu.Items.Add($items.Restart)
  $items.About = New-TrayMenuRow -Skin $Skin -Label 'About...' -Glyph $gl.Info
  [void]$menu.Items.Add($items.About)
  [void](Add-TrayMenuSeparator $menu $Skin)
  $items.Exit = New-TrayMenuRow -Skin $Skin -Label 'Exit' -Glyph $gl.Exit
  [void]$menu.Items.Add($items.Exit)
  # the size is settled here rather than at the first open: the drop-down positions itself from
  # the size it has when it opens, and the one-row placeholder it is built with would put the
  # first menu below the tray icon instead of above it (measured, 27 px too low)
  $menu.Fit()
  $items.Menu = $menu
  return $items
}

# What changes between two openings of the same menu: the count on the header, the hotkey that
# actually took effect, and the two switches. One call so the Opening handler in serve.ps1 stays
# a few lines, and so a new row that shows state has one place to be updated.
function Update-TrayMenu {
  param($Menu, [int]$Entries = -1, [string]$Hotkey = '', [bool]$Paused = $false, [bool]$Compact = $false)
  if ($null -eq $Menu) { return }
  try {
    if ($Entries -ge 0) {
      $Menu.Header.Hint = [string]$Entries + $(if ($Entries -eq 1) { ' entry' } else { ' entries' })
    }
  } catch { }
  try { if ($Hotkey) { $Menu.Show.Hint = $Hotkey } } catch { }
  try { $Menu.Pause.Checked = $Paused } catch { }
  try { $Menu.Compact.Checked = $Compact } catch { }
}

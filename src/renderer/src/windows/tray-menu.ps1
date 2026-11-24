# renderer\src\windows\tray-menu.ps1 - the tray menu, drawn the way the panel and the settings window are.
#
# The menu used to be a plain ContextMenuStrip: Windows draws those in the system colours, so
# beside a Fluent panel it read as somebody else's window. What it is now is the same surface,
# the same 1 px frame and the same rounded rows, with a glyph column, a right-hand column for a
# hint or a switch, and one row per action - the shape the settings window uses.
#
# The strip and its rows are C# (Cb.TrayMenu / Cb.TrayItem in main\ui\tray-menu.cs) because
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

# The menu object belongs to the resident; what it draws is decided here. `update` is how a new
# count, hotkey or switch reaches it without the resident naming a function of this file.
Register-Window -Name 'tray' -Handlers @{
  update = {
    param($args)
    Update-TrayMenu $args['Form'] -Entries $args['Entries'] -Hotkey $args['Hotkey'] -Paused ([bool]$args['Paused']) -Compact ([bool]$args['Compact'])
  }
}

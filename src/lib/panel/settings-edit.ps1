# lib/panel/settings-edit.ps1 - editing one setting in place.
#
# A value is edited in a real TextBox laid over the row, not by drawing a caret: the same
# reason the panel's row editor uses one - an input method needs a real control to compose
# into, and text selection, Ctrl+A and the clipboard come for free. Everything else about the
# window stays custom drawn.
#
# Writing goes through Set-IniKey and Apply-Config, which is exactly what `config set` does,
# so a value typed here and a value typed on the command line cannot end up in different
# places. The difference is the resident: a command restarts it on the spot, while a window
# would restart it on every keystroke, so this file marks the settings dirty and the window
# asks for one reload when it closes.

# one value written back, or the reason it was not
function Set-SettingValue([string]$key, [string]$value) {
  if (-not (Get-Command Set-IniKey -ErrorAction SilentlyContinue)) { return @{ Ok = $false; Error = 'the settings file is not loaded' } }
  if (-not (Set-IniKey $key $value)) { return @{ Ok = $false; Error = 'could not write clipboard.ini' } }
  try { Apply-Config } catch { return @{ Ok = $false; Error = [string]$_.Exception.Message } }
  $installOnly = @('autostart', 'desktopshortcut') -contains ([string]$key).ToLower()
  if (-not $installOnly) { $script:SettingsDirty = $true }
  return @{ Ok = $true; Error = '' }
}

# The text a row opens its editor with. A boolean never opens one - it flips - and a value that
# is currently empty opens with its default spelled out, because an empty box says nothing about
# what is allowed.
function Get-SettingEditSeed($schema, [string]$key) {
  $raw = Get-SettingEditText $schema $key
  if ([string]$raw -ne '') { return [string]$raw }
  return [string](Get-SchemaDefault $schema $key)
}

# The editor itself: a TextBox that covers the row's value area, styled from the theme so it
# reads as part of the surface rather than as a system control dropped on top.
function New-SettingEditor($form, $pal, [int]$x, [int]$y, [int]$w, [int]$h) {
  $box = New-Object Windows.Forms.TextBox
  $box.BorderStyle = 'None'
  $box.Font = $script:FBody
  $box.BackColor = $pal['Field']
  $box.ForeColor = $pal['Text']
  $box.Left = $x
  $box.Top = $y
  $box.Width = $w
  $box.Height = $h
  $form.Controls.Add($box)
  $box.BringToFront()
  return $box
}

# Where the choice list opens: under the row, in the control column, and above it when the list
# would run past the bottom of the window.
function Get-SettingDropRect($layout, [int]$rowTop, [int]$count) {
  $rowH = [int]$layout.RowHeight - (Px 4)
  $right = [int]$layout.ListRight - (Px 6)
  $w = (Px 170) + (Px 16)
  $itemH = Px 30
  $h = [int](Px 8) + ($count * $itemH)
  $top = $rowTop + $rowH + (Px 4)
  $limit = [int]$layout.ListBottom - [int](Px 8)
  if (($top + $h) -gt $limit) { $top = [Math]::Max([int]$layout.ListTop, $rowTop - $h - (Px 4)) }
  return @{ Left = ($right - $w); Top = $top; Width = $w; Height = $h }
}

# Puts the themed field behind the editor: a rounded rectangle filled with the field colour and
# stroked with the accent, the way a focused Fluent text field reads. A refused value turns the
# stroke to Warn instead, so the reason in the footer has something to point at.
function Draw-SettingEditField($g, $pal, [int]$x, [int]$y, [int]$w, [int]$h, [bool]$bad) {
  if ($null -eq $g) { return }
  $brush = New-Object Drawing.SolidBrush $pal['Field']
  $path = New-RoundPath $x $y $w $h (Px 4)
  try { $g.FillPath($brush, $path) } finally { $path.Dispose(); $brush.Dispose() }
  $edge = $pal['Accent']
  if ($bad) { $edge = $pal['Warn'] }
  $pen = New-Object Drawing.Pen $edge
  $stroke = New-RoundPath $x $y $w $h (Px 4)
  try { $g.DrawPath($pen, $stroke) } finally { $stroke.Dispose(); $pen.Dispose() }
}

# The row a click lands on: -1 when the click is outside the list, so a click on the header or
# the footer neither selects nor edits anything.
function Get-SettingsRowAt($layout, [int]$rows, [int]$scroll, [int]$px, [int]$py) {
  if ($py -lt [int]$layout.ListTop -or $py -ge [int]$layout.ListBottom) { return -1 }
  if ($px -lt [int]$layout.ListLeft -or $px -gt [int]$layout.ListRight) { return -1 }
  $i = [int][Math]::Floor(($py - [int]$layout.ListTop) / [int]$layout.RowHeight)
  $i = $i + $scroll
  if ($i -lt 0 -or $i -ge $rows) { return -1 }
  return $i
}

# Whether a click landed on the switch of a boolean row rather than somewhere else in the row.
# The switch is the only part of a row that acts on a single click; the rest of the row selects.
function Test-SettingsToggleHit($layout, [int]$px, [int]$py, [int]$rowTop) {
  $t = Get-SettingsToggleRect $layout $rowTop
  return ($px -ge [int]$t.Left -and $px -le ([int]$t.Left + [int]$t.Width) -and
    $py -ge [int]$t.Top -and $py -le ([int]$t.Top + [int]$t.Height))
}

# Where the editor sits for a row: over the control column, holding the same vertical middle the
# value does, so the text does not jump when the box appears.
function Get-SettingEditRect($layout, [int]$rowTop) {
  $rowH = [int]$layout.RowHeight - (Px 4)
  $h = Px 28
  $right = [int]$layout.ListRight - (Px 6)
  # the control column, so the box covers the value and not the description beside it
  $w = (Px 170) + (Px 16)
  $left = $right - $w
  if ($left -lt ([int]$layout.ListLeft + (Px 120))) { $left = [int]$layout.ListLeft + (Px 120) }
  return @{ Left = $left; Top = ($rowTop + [int](($rowH - $h) / 2)); Width = ($right - $left); Height = $h }
}

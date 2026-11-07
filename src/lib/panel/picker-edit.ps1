# lib/panel/picker-edit.ps1 - fix an entry without pasting it first.
#
# The panel never takes the foreground, so the editor is a TextBox laid over the list inside
# the panel itself. Two input models, two ways in: under the hook every keystroke is posted
# to $script:HookTargetBox instead of the search field (see Invoke-HookedKey), and without a
# hook the box simply takes the real focus.
#
# Enter saves, Shift+Enter adds a line, Esc walks away. The save is one store write and the
# row keeps its time and its marks - see Update-RecordText in lib/store.ps1.

# filled in by Show-Picker: @{ Form; List; Box; Ui; Font; Refresh; Note }
$script:EditorCtx = $null
# @{ Rec; Box } while the overlay is open, $null the rest of the time
$script:EditRow = $null
# non-null = the low-level hook feeds this box instead of the search field
$script:HookTargetBox = $null
# what a posted Complete-RowEdit should do, read from the lambda below
$script:EditSave = $false
# '' | 'cancel' | 'save': the first press of Esc or Enter only asks, the second one acts
$script:EditArm = ''

# Show-Picker calls this once, with the panel it built: the editor lays its card into that
# form, refreshes the list through that callback and reports in that footer. $focus puts the
# keyboard back where the panel expects it (the search field) once the card is gone.
function Set-PickerEditHost($form, $lst, $txt, $ui, $font, $refresh, $note, $focus) {
  $script:EditRow = $null
  $script:HookTargetBox = $null
  $script:EditArm = ''
  $script:EditorCtx = @{ Form = $form; List = $lst; Box = $txt; Ui = $ui; Font = $font; Refresh = $refresh; Note = $note; Focus = $focus }
  $form.Add_KeyDown({ param($s, $e) Invoke-PickerEditKey $e })
}

# F2 from the panel. It runs as a second KeyDown handler, after the panel's own: a key the
# panel does not use reaches this one untouched.
function Invoke-PickerEditKey($e) {  if ($null -eq $e) { return }
  if ($e.KeyCode -ne [Windows.Forms.Keys]::F2) { return }
  $e.Handled = $true
  $e.SuppressKeyPress = $true
  Begin-RowEdit
}

# The editor is a card inside the panel: a title line saying what is being edited, the box
# itself, a status line (cursor position, length, whether the text differs) and a Save /
# Cancel pair. It uses the same Fluent pieces as the rest of the panel - rounded corners, a
# 1 px accent stroke, accent fill for the primary action.

# cursor line, row count, length and a "modified" flag: the editor has no gutter, so this
# line is what tells the user where the caret is and whether there is anything to save
function Update-EditStatus {
  $st = $script:EditRow
  if ($null -eq $st) { return }
  try {
    $t = [string]$st.Box.Text
    $line = $st.Box.GetLineFromCharIndex($st.Box.SelectionStart) + 1
    $total = @($st.Box.Lines).Count
    $flag = ''
    if ($t -cne [string]$st.Payload) { $flag = '   modified' }
    $st.Stat.Text = ('line ' + [string]$line + ' of ' + [string]$total + '   ' + [string]$t.Length + ' chars' + $flag)
  } catch { }
}

# one rounded button; $primary fills it with the accent colour (the action Enter takes)
function New-EditAction([string]$label, [bool]$primary, [int]$w, [int]$h) {
  $b = New-Object Windows.Forms.Panel
  $b.Size = New-Object Drawing.Size -ArgumentList @($w, $h)
  $b.Cursor = 'Hand'
  $b.TabStop = $false
  $b.AccessibleName = $label
  $b.Tag = @{ Label = $label; Primary = $primary; Hot = $false }
  $b.Add_Paint({
      param($s, $e)
      try {
        $g = $e.Graphics
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pal = $script:EditorCtx.Ui
        $tag = $s.Tag
        $fill = $pal.Field
        $edge = $pal.FieldBorder
        $ink = $pal.Text
        if ($tag.Primary) { $fill = $pal.Accent; $edge = $pal.Accent; $ink = $pal.Surface }
        elseif ($tag.Hot) { $fill = $pal.HoverBg }
        $gp = New-RoundPath 0 0 ([int]$s.Width - 1) ([int]$s.Height - 1) (Px 4)
        $br = New-Object Drawing.SolidBrush $fill
        $g.FillPath($br, $gp)
        $br.Dispose()
        $pen = New-Object Drawing.Pen $edge
        $g.DrawPath($pen, $gp)
        $pen.Dispose()
        $gp.Dispose()
        $fmt = New-Object Drawing.StringFormat
        $fmt.Alignment = [Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [Drawing.StringAlignment]::Center
        $fmt.FormatFlags = [Drawing.StringFormatFlags]::NoWrap
        $r = New-Object Drawing.RectangleF -ArgumentList @(0, 0, [single]$s.Width, [single]$s.Height)
        $tb = New-Object Drawing.SolidBrush $ink
        $g.DrawString([string]$tag.Label, $script:FTiny, $tb, $r, $fmt)
        $tb.Dispose()
        $fmt.Dispose()
      } catch { }
    })
  $b.Add_MouseEnter({ param($s, $e) $s.Tag.Hot = $true; $s.Invalidate() })
  $b.Add_MouseLeave({ param($s, $e) $s.Tag.Hot = $false; $s.Invalidate() })
  return $b
}

# take the card away and forget the session; the region is ours, so it is released by hand
function Close-RowEdit {
  $ctx = $script:EditorCtx
  $st = $script:EditRow
  $script:EditRow = $null
  $script:HookTargetBox = $null
  $script:EditArm = ''
  if ($null -eq $st -or $null -eq $ctx) { return }
  try {
    $rgn = $st.Card.Region
    [void]$ctx.Form.Controls.Remove($st.Card)
    $st.Card.Dispose()
    if ($null -ne $rgn) { $rgn.Dispose() }
  } catch { }
  # the search field takes the keyboard again, exactly as it does for a panel that never
  # opened the editor; under the hook this is a no-op
  try { if ($ctx.Focus) { & $ctx.Focus } } catch { }
}

function Begin-RowEdit {
  if ($null -eq $script:EditorCtx -or $null -ne $script:EditRow) { return }
  $ctx = $script:EditorCtx
  $lst = $ctx.List
  $idx = [int]$lst.SelectedIndex
  if ($idx -lt 0 -or $idx -ge @($script:Filtered).Count) { & $ctx.Note 'Nothing selected'; return }
  $rec = $script:Filtered[$idx]
  if ($null -eq $rec) { return }
  $payload = [string]$rec.Payload
  # a picture is not text: editing it would silently turn the row into something else
  if ((Get-Command Test-ImagePayload -ErrorAction SilentlyContinue) -and (Test-ImagePayload $payload)) {
    & $ctx.Note 'A picture has no text to edit'
    return
  }
  # The card is the editor window: it covers the whole panel, so the search field and the
  # footer step aside while an entry is being edited and the text gets the full area.
  $cw = [int]$ctx.Form.ClientSize.Width
  $ch = [int]$ctx.Form.ClientSize.Height
  $pad = (Px 16)
  $card = New-Object Windows.Forms.Panel
  $card.BackColor = $ctx.Ui.Surface
  $card.SetBounds(0, 0, $cw, $ch)
  $card.Add_Paint({
      param($s, $e)
      try {
        $g = $e.Graphics
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pal = $script:EditorCtx.Ui
        $pen = New-Object Drawing.Pen $pal.Accent
        $gp = New-RoundPath 0 0 ([int]$s.Width - 1) ([int]$s.Height - 1) (Px 8)
        $g.DrawPath($pen, $gp)
        $pen.Dispose()
        $gp.Dispose()
        # the box has no border of its own (a native one cannot follow the theme), so the
        # field outline is drawn here, one pixel outside the control
        $st = $script:EditRow
        if ($null -ne $st) {
          $b = $st.Box
          $edge = New-Object Drawing.Pen $pal.Border
          $g.DrawRectangle($edge, ([int]$b.Left - 1), ([int]$b.Top - 1), ([int]$b.Width + 1), ([int]$b.Height + 1))
          $edge.Dispose()
        }
      } catch { }
    })

  $title = New-Object Windows.Forms.Label
  $title.Text = 'Editing entry'
  $title.Font = $script:FSmall
  $title.ForeColor = $ctx.Ui.Text
  $title.BackColor = $ctx.Ui.Surface
  $title.SetBounds($pad, (Px 16), (Px 200), (Px 20))

  $stat = New-Object Windows.Forms.Label
  $stat.Font = $script:FTiny
  $stat.ForeColor = $ctx.Ui.Dim
  $stat.BackColor = $ctx.Ui.Surface
  $stat.TextAlign = 'MiddleRight'
  $stat.SetBounds(($cw - $pad - (Px 320)), (Px 16), (Px 302), (Px 20))

  $box = New-Object Windows.Forms.TextBox
  $box.Multiline = $true
  $box.AcceptsReturn = $true
  $box.AcceptsTab = $false
  $box.WordWrap = $true
  $box.BorderStyle = 'None'
  # no native scrollbar: it cannot be themed and a light grey bar on a dark card reads as a
  # foreign control; the wheel and the arrow keys still scroll, and the status line says how
  # long the text is
  $box.ScrollBars = 'None'
  $box.Font = $ctx.Font
  $box.BackColor = $ctx.Ui.Field
  $box.ForeColor = $ctx.Ui.Text
  $box.SetBounds($pad, (Px 48), ($cw - (2 * $pad)), ($ch - (Px 48) - (Px 78)))
  $box.Text = $payload
  $box.AccessibleName = 'Edit the text of this entry'
  $box.Add_KeyDown({
      param($s, $e)
      if ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) {
        $e.Handled = $true; $e.SuppressKeyPress = $true
        Request-RowEdit $false $s
      } elseif ($e.KeyCode -eq [Windows.Forms.Keys]::Enter) {
        if ($e.Shift -or $e.Control) {
          # a line break of its own: the box inserts it, the panel must not see the key
          $e.SuppressKeyPress = $true
          $s.SelectedText = [Environment]::NewLine
        } else {
          $e.Handled = $true; $e.SuppressKeyPress = $true
          Request-RowEdit $true $s
        }
      }
    })

  # the error line only speaks when a save was refused, and typing clears it again
  $err = New-Object Windows.Forms.Label
  $err.Font = $script:FTiny
  $err.ForeColor = $ctx.Ui.Warn
  $err.BackColor = $ctx.Ui.Surface
  $err.SetBounds($pad, ($ch - (Px 74)), ($cw - (2 * $pad) - (Px 200)), (Px 18))

  # the footer is covered, so the keys are spelled out here instead
  $hint = New-Object Windows.Forms.Label
  $hint.Font = $script:FTiny
  $hint.ForeColor = $ctx.Ui.Dim
  $hint.BackColor = $ctx.Ui.Surface
  $hint.SetBounds($pad, ($ch - (Px 46)), ($cw - (2 * $pad) - (Px 200)), (Px 18))
  if ([string]::IsNullOrEmpty([string]$rec.Rich)) {
    $hint.Text = 'Enter saves   Shift+Enter newline   Esc cancels'
  } else {
    $hint.Text = 'Plain text only: saving drops the formatting   Enter saves   Esc cancels'
  }

  $save = New-EditAction 'Save' $true (Px 76) (Px 26)
  $save.SetBounds(($cw - $pad - (Px 76)), ($ch - (Px 46)), (Px 76), (Px 26))
  $save.Add_Click({ if ($null -ne $script:EditRow) { Request-RowEdit $true $script:EditRow.Box } })
  $cancel = New-EditAction 'Cancel' $false (Px 76) (Px 26)
  $cancel.SetBounds(($cw - $pad - (Px 76) - (Px 8) - (Px 76)), ($ch - (Px 46)), (Px 76), (Px 26))
  $cancel.Add_Click({ if ($null -ne $script:EditRow) { Request-RowEdit $false $script:EditRow.Box } })

  $card.Controls.Add($title)
  $card.Controls.Add($stat)
  $card.Controls.Add($box)
  $card.Controls.Add($err)
  $card.Controls.Add($hint)
  $card.Controls.Add($save)
  $card.Controls.Add($cancel)
  $ctx.Form.Controls.Add($card)
  $card.BringToFront()
  try { $card.Region = New-RoundRegion $card.Width $card.Height (Px 8) } catch { }
  $script:EditRow = @{ Rec = $rec; Box = $box; Card = $card; Stat = $stat; Err = $err; Payload = $payload }
  $script:HookTargetBox = $box
  $box.Add_TextChanged({
      $script:EditArm = ''
      if ($null -ne $script:EditRow) { $script:EditRow.Err.Text = '' }
      Update-EditStatus
    })
  $box.Add_KeyUp({ Update-EditStatus })
  $box.Add_Click({ Update-EditStatus })
  Update-EditStatus
  # without a hook the box can take the real focus; under the hook it cannot, and the caret
  # stays invisible exactly like the search field's
  try { $box.Focus(); $box.SelectionStart = $box.TextLength; $box.ScrollToCaret() } catch { }
  # the card keeps the keyboard from now on; the footer is covered, so nothing is reported
  # there while the editor is open
}

# Esc and Enter both ask once before they throw something away: cancelling typed text, or
# saving a formatted entry as plain text. Any other keystroke disarms them again.
function Request-RowEdit([bool]$save, $box) {
  $ctx = $script:EditorCtx
  if ($null -eq $ctx -or $null -eq $script:EditRow) { return }
  $rec = $script:EditRow.Rec
  $changed = ([string]$box.Text -cne [string]$rec.Payload)
  if (-not $save) {
    if ((-not $changed) -or ($script:EditArm -eq 'cancel')) { Invoke-RowEditLater $false; return }
    $script:EditArm = 'cancel'
    & $ctx.Note 'Press Esc again to discard the change' ([int]$script:Timing['FootShort'])
    return
  }
  $hasRich = -not [string]::IsNullOrEmpty([string]$rec.Rich)
  if ($changed -and $hasRich -and ($script:EditArm -ne 'save')) {
    $script:EditArm = 'save'
    & $ctx.Note 'Saving drops the formatting: press Enter again to save' ([int]$script:Timing['FootWarn'])
    return
  }
  Invoke-RowEditLater $true
}

# An event handler must not dispose the control it belongs to, so the finish is posted to the
# panel's message loop. With no loop left (the panel is closing) it happens right here.
function Invoke-RowEditLater([bool]$save) {
  $ctx = $script:EditorCtx
  if ($null -eq $ctx) { return }
  $script:EditSave = $save
  try {
    $act = [Windows.Forms.MethodInvoker]{ Complete-RowEdit ([bool]$script:EditSave) }
    [void]$ctx.Form.BeginInvoke($act)
  } catch {
    Complete-RowEdit $save
  }
}

# $true = keep what the box says, $false = throw it away
function Complete-RowEdit([bool]$save) {
  if ($null -eq $script:EditRow) { return }
  $ctx = $script:EditorCtx
  $state = $script:EditRow
  $text = [string]$state.Box.Text
  $payload = [string]$state.Payload
  $hadRich = -not [string]::IsNullOrEmpty([string]$state.Rec.Rich)
  $changed = ($text -cne $payload)
  if (-not $save) {
    Close-RowEdit
    & $ctx.Note 'Edit cancelled' ([int]$script:Timing['FootShort'])
    return
  }
  # a refused save keeps the card open: what the user typed must not be thrown away, and the
  # reason goes on the card's own error line instead of the footer
  $res = Update-RecordText $payload $text
  if (-not $res.Ok) {
    try { $state.Err.Text = 'not saved: ' + [string]$res.Error } catch { }
    & $ctx.Note ('[!] ' + [string]$res.Error) ([int]$script:Timing['FootWarn'])
    return
  }
  Close-RowEdit
  $script:Entries = @(Get-Records)
  & $ctx.Refresh ([string]$ctx.Box.Text)
  # Put the cursor back on the row that was edited: it may sit outside the visible window, or
  # have dropped out of the search results because its new text no longer matches.
  $hit = -1
  $rows = @($script:Filtered)
  for ($i = 0; $i -lt $rows.Count; $i++) {
    if ([string]$rows[$i].Payload -ceq $text) { $hit = $i; break }
  }
  if ($hit -ge 0) {
    try {
      $ctx.List.SelectedIndex = $hit
      $vis = Get-VisibleRowCount $ctx.List.ClientSize.Height $ctx.List.ItemHeight
      $top = [int]$ctx.List.TopIndex
      if ($hit -lt $top) { $ctx.List.TopIndex = $hit }
      elseif ($vis -gt 0 -and $hit -ge ($top + $vis)) { $ctx.List.TopIndex = ($hit - $vis + 1) }
    } catch { }
  }
  if ($hit -lt 0) { & $ctx.Note 'Saved, but it no longer matches the search' ([int]$script:Timing['FootInfo']) }
  elseif ($hadRich -and $changed) { & $ctx.Note 'Saved as plain text' ([int]$script:Timing['FootInfo']) }
  else { & $ctx.Note 'Saved' ([int]$script:Timing['FootInfo']) }
}

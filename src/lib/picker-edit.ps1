# lib/picker-edit.ps1 - fix an entry without pasting it first.
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

# Show-Picker calls this once, with the panel it built: the editor lays its box into that
# form, refreshes the list through that callback and reports in that footer. A panel that
# opens fresh starts with no edit in progress - a closed panel never cleans up after itself.
function Set-PickerEditHost($form, $lst, $txt, $ui, $font, $refresh, $note) {
  $script:EditRow = $null
  $script:HookTargetBox = $null
  $script:EditorCtx = @{ Form = $form; List = $lst; Box = $txt; Ui = $ui; Font = $font; Refresh = $refresh; Note = $note }
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
  $box = New-Object Windows.Forms.TextBox
  $box.Multiline = $true
  $box.AcceptsReturn = $true
  $box.AcceptsTab = $false
  $box.WordWrap = $true
  $box.BorderStyle = 'FixedSingle'
  $box.ScrollBars = 'Vertical'
  $box.Font = $ctx.Font
  $box.BackColor = $ctx.Ui.Field
  $box.ForeColor = $ctx.Ui.Text
  # over the whole list, not over one row: the text an entry holds rarely fits a row
  $box.SetBounds([int]$lst.Left, [int]$lst.Top, [int]$lst.Width, [int]$lst.Height)
  $box.Text = $payload
  $box.AccessibleName = 'Edit the text of this entry'
  $box.Add_KeyDown({
      param($s, $e)
      if ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) {
        $e.Handled = $true; $e.SuppressKeyPress = $true
        Invoke-RowEditLater $false
      } elseif ($e.KeyCode -eq [Windows.Forms.Keys]::Enter) {
        if ($e.Shift -or $e.Control) {
          # a line break of its own: the box inserts it, the panel must not see the key
          $e.SuppressKeyPress = $true
          $s.SelectedText = [Environment]::NewLine
        } else {
          $e.Handled = $true; $e.SuppressKeyPress = $true
          Invoke-RowEditLater $true
        }
      }
    })
  $ctx.Form.Controls.Add($box)
  $box.BringToFront()
  $script:EditRow = @{ Rec = $rec; Box = $box }
  $script:HookTargetBox = $box
  # without a hook the box can take the real focus; under the hook it cannot, and the caret
  # stays invisible exactly like the search field's
  try { $box.Focus(); $box.SelectionStart = $box.TextLength; $box.ScrollToCaret() } catch { }
  & $ctx.Note 'Enter saves, Shift+Enter adds a line, Esc cancels'
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
  $script:EditRow = $null
  $script:HookTargetBox = $null
  try {
    $ctx.Form.Controls.Remove($state.Box)
    $state.Box.Dispose()
  } catch { }
  if (-not $save) { & $ctx.Note 'Edit cancelled'; return }
  $res = Update-RecordText ([string]$state.Rec.Payload) $text
  if (-not $res.Ok) { & $ctx.Note ('not saved: ' + [string]$res.Error); return }
  $script:Entries = @(Get-Records)
  & $ctx.Refresh ([string]$ctx.Box.Text)
  & $ctx.Note 'Saved'
}

# renderer\src\store\history-store.ps1 - the history as one shared piece of state.
#
# The panel reads it on every refresh and the clipboard commands write to it; both go through
# this store instead of each keeping its own copy. The rows themselves come from the channel
# table (Invoke-Ipc 'list'), so where they are stored stays lib\store's business and this file
# only says what a window may see.
#
#   $history = Use-UiStore 'history'
#   $rows = $history.Refresh()     # reads the channel, keeps the result, answers it
#   $history.Rows                  # the same array, until the next refresh replaces it
#   $history.Count                 # how many there are, computed when read
#
# Rows is a ScriptProperty over the state bag, not a copy: the panel compares one read with the
# next by reference to decide whether its query caches still apply, and a copy would make every
# keystroke rebuild them.

Define-UiStore 'history' {
  param($ctx)

  $ctx.State.Rows = @()

  & $ctx.Getter 'Count' { param($s) @($s.Context.State.Rows).Count }
  # an empty history draws a hint instead of a list; a window asks rather than counting itself
  & $ctx.Getter 'IsEmpty' { param($s) @($s.Context.State.Rows).Count -eq 0 }

  # Read the channel and keep what it answered. The rows come back as well, so a caller that
  # only wants them once does not have to read the property afterwards.
  & $ctx.Action 'Refresh' {
    param($s)
    $rows = @(Invoke-Ipc 'list')
    $s.Context.State.Rows = $rows
    Invoke-UiStoreChange $s.Context @('Rows')
    return $rows
  }

  # Forget what was read: the next Refresh fills it again. A test or a shutdown uses this, and
  # it is the one write that is not a refresh.
  & $ctx.Action 'Clear' {
    param($s)
    $s.Context.State.Rows = @()
    Invoke-UiStoreChange $s.Context @('Rows')
  }
}

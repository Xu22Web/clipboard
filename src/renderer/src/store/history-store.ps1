# renderer\src\store\history-store.ps1 - the history as one shared piece of state.
#
# The panel reads it on every refresh and the clipboard commands write to it; both go through
# this store instead of each keeping its own copy. The rows themselves come from the channel
# table (Invoke-Ipc 'list'), so where they are stored stays lib\store's business and this file
# only says what a window may see.
#
#   $history = Use-UiStore 'history'
#   $rows = $history.Refresh()     # reads the channel, keeps the result, answers it
#   $history.Rows                  # what the last write left, until the next refresh
#   $history.Count                 # how many there are, computed when read
#
# Rows reads the state bag, so it is never stale - but each read is a fresh array, because a
# ScriptProperty hands its value back through the pipeline. A caller that wants to compare one
# read with the next keeps the array it was given: the panel holds it in one variable and
# replaces it on refresh, which is what its query caches compare by reference.

# the definition returns the store; nothing here reads it, and a module that is dot-sourced must
# not answer anything, or every command that pulls the window layer would print it
$null = Define-UiStore 'history' {
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

  # Delete one entry and keep the rows honest. The channel answers what happened - 'removed',
  # or 'protected:<mark>' when a plugin keeps the row - and only a real delete re-reads, so a
  # refused one costs nothing.
  & $ctx.Action 'Remove' {
    param($s, $payload)
    $result = [string](Invoke-Ipc 'del' ([string]$payload))
    if ($result -eq 'removed') {
      $s.Context.State.Rows = @(Invoke-Ipc 'list')
      Invoke-UiStoreChange $s.Context @('Rows')
    }
    return $result
  }
}

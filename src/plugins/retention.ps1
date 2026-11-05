# retention - delete entries older than N days.
#
# Rows carrying a protected mark (its plugin declares Protected, e.g. a star) are never
# touched. With KeepPinned=1 the rows carrying the sort mark (what pinning declares) are
# kept too, so this file never has to know which mark that is.
#
# Settings: retention.MaxAgeDays / retention.SweepMinutes / retention.KeepPinned, described
# in schema\plugins\retention.ps1 and merged into the settings schema when this file loads.
#
# The sweep is one shared block: the resident Tick calls it silently, `sweep force` runs
# it on demand and reports. Tick.Seconds is a scriptblock, so the interval follows
# SweepMinutes without the plugin keeping state of its own.
@{
  Name        = 'retention'
  Description = 'Delete entries older than N days; protected entries are always kept'
  CommandHelp = @{
    'sweep' = 'run the expiry sweep now ("sweep force" reports what it did)'
  }
  # returns the number of rows removed; one write for the whole list
  Sweep       = {
    $maxAge = [int](Get-PluginSetting 'retention' 'MaxAgeDays')
    if ($maxAge -le 0) { return 0 }
    $protected = @(Get-ProtectedMarks)
    $keepSorted = ((Get-PluginSetting 'retention' 'KeepPinned') -eq '1')
    $sortMark = Get-SortMark
    $cutoff = (Get-Epoch) - ($maxAge * 86400)
    # GetNewClosure keeps the values above visible inside the block that Update-Records
    # runs, whatever scope it is invoked from
    $body = {
      param($list)
      $gone = 0
      for ($i = $list.Count - 1; $i -ge 0; $i--) {
        $r = $list[$i]
        if (Test-AnyMark $r $protected) { continue }
        if ($keepSorted -and $sortMark -and (Test-Mark $r $sortMark)) { continue }
        if ([long]$r.Time -le 0 -or [long]$r.Time -ge $cutoff) { continue }
        $list.RemoveAt($i)
        $gone++
      }
      return $gone
    }.GetNewClosure()
    return [int](Update-Records $body)
  }
  Commands    = @{
    'sweep' = {
      param($value)
      $maxAge = [int](Get-PluginSetting 'retention' 'MaxAgeDays')
      if ($maxAge -le 0) { Write-Host '[i] retention is off (retention.MaxAgeDays=0)'; return }
      $dropped = [int](& (Get-PluginData 'retention' 'Sweep'))
      if ($value -eq 'force') {
        if ($dropped -gt 0) { Write-Host ('[ok] retention: removed ' + $dropped + ' entries older than ' + $maxAge + ' days') }
        else { Write-Host ('[ok] retention: nothing older than ' + $maxAge + ' days') }
      } elseif ($dropped -gt 0) {
        Write-Log ('retention: removed ' + $dropped + ' entries older than ' + $maxAge + ' days')
      }
    }
  }
  Tick        = @{
    # follow SweepMinutes: the base throttles on this value, so no timer state is needed
    Seconds = {
      $m = [int](Get-PluginSetting 'retention' 'SweepMinutes')
      if ($m -lt 1) { $m = 30 }
      return ($m * 60)
    }
    Action  = {
      param($now)
      [void](& (Get-PluginData 'retention' 'Sweep'))
    }
  }
}

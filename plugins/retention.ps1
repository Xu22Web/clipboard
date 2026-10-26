# retention - delete entries older than N days.
#
# Starred entries are never touched, pinned ones can be kept too. The sweep runs in the
# resident loop; `clipboard sweep force` runs it once on demand.
#
# Settings: retention.MaxAgeDays / retention.SweepMinutes / retention.KeepPinned
#
# Scriptblocks must be self-contained: they may call base helpers, but must not read
# variables created in this file's scope (that scope is gone when they run).
@{
  Name        = 'retention'
  Description = 'Delete entries older than N days; starred entries are always kept'
  CommandHelp = @{
    'sweep' = 'run the expiry sweep now ("sweep force" ignores the interval)'
  }
  Settings    = [ordered]@{
    MaxAgeDays   = @{ Kind = 'int'; Min = 0; Max = 3650; Default = 0; Desc = 'delete entries older than this many days, 0 = keep forever' }
    SweepMinutes = @{ Kind = 'int'; Min = 1; Max = 1440; Default = 30; Desc = 'how often the sweep may run, in minutes' }
    KeepPinned   = @{ Kind = 'bool'; Default = 1; Desc = '1 = never expire pinned entries' }
  }
  Commands    = @{
    'sweep' = {
      param($value)
      $maxAge = [int](Get-PluginSetting 'retention' 'MaxAgeDays')
      if ($maxAge -le 0) {
        if ($value -eq 'force') { Write-Host '[i] retention is off (retention.MaxAgeDays=0)' }
        return
      }
      $now = Get-Epoch
      if ($value -ne 'force') {
        # the resident calls this every minute; only sweep when the interval has passed
        $every = [int](Get-PluginSetting 'retention' 'SweepMinutes')
        if ($every -lt 1) { $every = 30 }
        if ($now -lt [long]$script:RetentionNext) { return }
        $script:RetentionNext = $now + ($every * 60)
      }
      $keepPinned = (Get-PluginSetting 'retention' 'KeepPinned') -eq '1'
      $cutoff = $now - ($maxAge * 86400)
      $dropped = Use-StoreLock {
        $keep = New-Object System.Collections.Generic.List[object]
        $gone = 0
        foreach ($r in @(Get-Records)) {
          $protected = [bool]$r.Starred -or ($keepPinned -and [bool]$r.Pinned)
          if (-not $protected -and [long]$r.Time -gt 0 -and [long]$r.Time -lt $cutoff) { $gone++; continue }
          $keep.Add($r)
        }
        if ($gone -gt 0) { Save-Records $keep.ToArray() }
        return $gone
      }
      $script:RetentionNext = $now + (([int](Get-PluginSetting 'retention' 'SweepMinutes')) * 60)
      if ($value -eq 'force') {
        if ($dropped -gt 0) { Write-Host ('[ok] retention: removed ' + $dropped + ' entries older than ' + $maxAge + ' days') }
        else { Write-Host ('[ok] retention: nothing older than ' + $maxAge + ' days') }
      } elseif ($dropped -gt 0) {
        Write-Log ('retention: removed ' + $dropped + ' entries older than ' + $maxAge + ' days')
      }
    }
  }
  Tick        = @{
    Seconds = 60
    Action  = {
      param($now)
      $sweep = Get-PluginCommand 'sweep'
      if ($sweep) { & $sweep 'auto' }
    }
  }
}

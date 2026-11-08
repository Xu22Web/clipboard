# schema/plugins/retention.ps1 - the keys the retention plugin adds.
#
# Properties -> clipboard.ini keys, merged into the settings schema as retention.<Key> when
#               the plugin loads. This plugin restyles nothing, so it declares no theme keys.
@{
  Name       = 'retention'
  File       = 'clipboard.ini'
  Version    = 1
  Properties = [ordered]@{
    MaxAgeDays   = @{ Type = 'int'; Minimum = 0; Maximum = 3650; Default = 0; Description = 'delete entries older than this many days, 0 = keep forever' }
    SweepMinutes = @{ Type = 'int'; Minimum = 1; Maximum = 1440; Default = 30; Description = 'how often the sweep may run, in minutes' }
    KeepPinned   = @{ Type = 'bool'; Default = 1; Description = '1 = never expire the row carrying the sort mark (a pinned entry)' }
  }
}

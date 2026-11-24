# retention — expiry

[← back to the main document](../../../README.md) · [plugin contract](../../../README.md#plugins)

Deletes old entries by age, keeping the history at a size you can predict. A row protected by a mark (a starred one by default) is **never** cleaned, and a row carrying the sort mark (a pinned one by default) can be kept.

## Enabling it

```ini
# clipboard.ini - the plugin is already listed by default; removing the name turns it off
Plugins=entry-actions,item-marks,retention,transform
# to actually start deleting, set a number of days above 0
retention.MaxAgeDays=30
```

While it is not loaded nothing is deleted automatically and `sweep` is an unknown command.

> The plugin is loaded by default, but `MaxAgeDays` defaults to `0` (never expire), so nothing is deleted until you set a number of days.

## Commands

| Command | Effect |
|---|---|
| `clipboard sweep force` | clean once now, ignoring the interval (prints how many entries went) |
| `clipboard sweep` | clean only when the interval has passed (the resident calls it every minute, so running it by hand is rarely needed) |

```
$ clipboard sweep force
[ok] retention: removed 12 entries older than 30 days

$ clipboard sweep force
[i] retention is off (retention.MaxAgeDays=0)
```

## Settings (`clipboard.ini`)

The keys are declared in `shared\schema\plugins\retention.ps1` and merged into the settings on load; in the file they live in the `[retention]` section, and `config set` uses `<plugin>.<Key>`:

| Key | Default | Meaning |
|---|---|---|
| `retention.MaxAgeDays` | `0` | delete anything older than this many days (0–3650); `0` = never |
| `retention.SweepMinutes` | `30` | smallest interval between two sweeps (minutes, 1–1440) |
| `retention.KeepPinned` | `1` | `1` = never expire a row with the sort mark (a pinned entry), `0` = let it expire too |

```powershell
clipboard config set retention.MaxAgeDays 30
clipboard config set retention.SweepMinutes 60
clipboard config set retention.KeepPinned 0
```

## Notes

- **A protected row is never deleted**: the mark is declared protected by its plugin (`item-marks` marks a starred row `Protected`), so it survives even with `KeepPinned=0`.
- **How a pinned row is recognised**: the plugin never hard-codes a mark letter; it asks the base layer which mark sorts first (`SortMark`). Without a plugin declaring one, `KeepPinned` has no effect.
- Sweeping rides the resident's (`clipboard serve`) `Tick` hook and follows `SweepMinutes` directly; the plugin keeps no clock of its own. Without a resident nothing is deleted automatically, but `sweep force` still works by hand.
- Only the capture time of an entry is looked at: the order and the pin state of everything else stay as they are.
- When the number removed is not zero, one line goes to `data/clipboard.log`.

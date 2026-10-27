# retention —— 过期清理

[← 回到主说明](../README.md) · [插件契约](../README.md#插件)

按时间自动删除旧条目，把历史控制在一个可预期的规模。受标记保护的行（默认是收藏）**永远不会**被清理，带排序标记的行（默认是置顶）可以选择保留。

## 启用

```ini
# clipboard.ini
Plugins=retention
retention.MaxAgeDays=30
```

不启用时不会发生任何自动删除；`sweep` 是未知命令。

> 只启用插件但 `MaxAgeDays` 仍然是默认值 `0` 时，清理处于关闭状态：插件什么也不做。

## 命令

| 命令 | 作用 |
|---|---|
| `clipboard sweep force` | 立刻按 `MaxAgeDays` 清理一次，忽略间隔限制（会打印删除了多少条） |
| `clipboard sweep` | 到了间隔才清理（常驻进程内部每分钟调用一次，通常不需要手动跑） |

```
$ clipboard sweep force
[ok] retention: removed 12 entries older than 30 days

$ clipboard sweep force
[i] retention is off (retention.MaxAgeDays=0)
```

## 设置项（`clipboard.ini`）

| 键 | 默认 | 说明 |
|---|---|---|
| `retention.MaxAgeDays` | `0` | 超过多少天就删除（0–3650）；`0` = 永不清理 |
| `retention.SweepMinutes` | `30` | 两次清理的最小间隔（分钟，1–1440） |
| `retention.KeepPinned` | `1` | `1` = 不清理带排序标记的行（即置顶条目），`0` = 同样过期 |

```powershell
clipboard config set retention.MaxAgeDays 30
clipboard config set retention.SweepMinutes 60
clipboard config set retention.KeepPinned 0
```

## 说明

- **受保护的行永不删除**：由标记的插件声明（`item-marks` 把收藏声明为 `Protected`），即使 `KeepPinned=0` 也不会被清理。
- **置顶怎么认出来**：插件不写死标记字符，只问基础层“哪个标记排在最前”（`SortMark`）；没有插件声明时 `KeepPinned` 不生效。
- 定时清理靠常驻进程（`clipboard serve`）的 `Tick` 钩子，间隔直接跟随 `SweepMinutes`（插件不自己记时间）；常驻没在跑时不会自动清理，但 `sweep force` 仍然可以手动立即执行一次。
- 清理只按条目的捕获时间判断，不改变其余条目的顺序与置顶状态。
- 删除条数不为 0 时会写一行日志到 `data/clipboard.log`。

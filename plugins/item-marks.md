# item-marks —— 置顶 / 收藏 / 高亮

[← 回到主说明](../README.md) · [插件契约](../README.md#插件)

三个互相独立的行为，一个插件承载：

| 行为 | 做什么 | 命令 / 按键 | 颜色 |
|---|---|---|---|
| **置顶** | 浮到列表最前，不受条数 / 容量裁剪 | `pin N` / `unpin N`，`Ctrl+P`，右键 | `PinColor` |
| **收藏** | `clear` 与裁剪永不删除，删除前必须先取消收藏 | `star N` / `unstar N`，`Ctrl+S`，右键 | `StarGlyph` / `StarColor` |
| **高亮** | 在行左侧画一条强调色竖条 | — | `BarColor` / `PinnedBarColor` |

三者可以同时存在：一条条目可以既置顶又收藏，并且带强调色竖条。它们各管各的——收藏一条非置顶的条目不会让它浮到顶部，置顶一条未收藏的条目也不会让它免于 `clear`。

## 启用

```ini
# clipboard.ini
Plugins=item-marks
```

不启用时：`pin` / `unpin` / `star` / `unstar` 是未知命令，面板没有 `Ctrl+P` / `Ctrl+S`，右键菜单没有置顶与星标项，行上也没有星标与竖条。记录格式里的 `p` / `s` 标记仍能正确读出，只是没有入口去设置它们。

## 命令

| 命令 | 作用 |
|---|---|
| `clipboard pin N` | 把第 N 条置顶（置顶条目浮到列表最前，`list` 里前面带 `*`） |
| `clipboard unpin N` | 取消第 N 条的置顶 |
| `clipboard star N` | 收藏第 N 条：`clear` 与自动裁剪永不删除它 |
| `clipboard unstar N` | 取消收藏（取消后才能 `del`） |
| `clipboard marks` | 打印当前星标字形、颜色与强调条开关，用于排查样式 |

```
$ clipboard star 2
starred: https://example.com/doc   clear and trimming keep it

$ clipboard list
  1  2m    * https://example.com/doc
  2  5m      hello world
```

## 面板

| 位置 | 行为 |
|---|---|
| `Ctrl+P` | 置顶 / 取消置顶 |
| `Ctrl+S` | 收藏 / 取消收藏 |
| 右键菜单 | `Pin to top`（已置顶时变成 `Remove pin`）、`Star`（已收藏时变成 `Remove star`），带快捷键提示 |
| 行样式 | 收藏的行在保留列显示星标；置顶的行显示图钉；星标 / 置顶的行左侧有竖条（一行最多一条，两者都满足时用星标那条） |

删除一个已收藏的条目时，会提示先取消收藏：`[!] starred entry, unstar it first: clipboard unstar 1`。

## 设置项（`clipboard.ini`）

| 键 | 默认 | 说明 |
|---|---|---|
| `item-marks.MaxPins` | `50` | 置顶条数上限，超出时自动取消最旧的置顶（`0` = 不限） |
| `item-marks.ClearKeepsPinned` | `1` | `1` = `clear` 与面板“清空”、托盘菜单保留置顶条目；`0` = 一并清掉 |

```powershell
clipboard config set item-marks.MaxPins 10
```

## 主题项（`themes/<name>.ini` 的 `[item-marks]` 段）

这些**不是** `clipboard.ini` 的键，只有主题文件能改：

| 键 | 默认 | 说明 |
|---|---|---|
| `StarGlyph` | `U+E735` | 收藏行的星标字形 |
| `StarColor` | `#FFC86E` | 星标颜色 |
| `PinColor` | 空 | 置顶标记颜色，空 = 用主题的 `Pin` 色 |
| `BarColor` | 空 | 收藏行的竖条颜色，空 = 用主题的 `Accent` 色 |
| `PinnedBarColor` | 空 | 置顶行的竖条颜色，空 = 用主题的 `Accent` 色 |

```ini
# themes/win11-light.ini
[item-marks]
StarColor=#9D5D00
```

## 数据层约定（不属于本插件，但由它触发）

- 记录标记里的 `s` 位由基础工具保存，`clear` / 裁剪 / 删除都认它：**收藏条目永远不会被自动删掉**。
- `item-marks.ClearKeepsPinned=1` 时 `clear` 保留置顶条目；`item-marks.MaxPins` 限制置顶数量。
- 这两个开关由插件读取（`ClearKeepsPinned` 通过插件钩子交给基础层），插件没启用时不产生任何效果。

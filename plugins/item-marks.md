# item-marks —— 置顶 / 收藏 / 高亮

[← 回到主说明](../README.md) · [插件契约](../README.md#插件)

三个互相独立的标记，一个插件承载：

| 标记 | 做什么 | 设置入口 | 行上的表现 |
|---|---|---|---|
| **置顶** `p` | 浮到列表最前，不受条数 / 容量裁剪 | `pin N` / `unpin N`、`Ctrl+P`、右键 | 行尾图钉字形（`PinColor`） |
| **收藏** `s` | `clear` 与裁剪永不删除，删除前必须先取消收藏 | `star N` / `unstar N`、`Ctrl+S`、右键 | 行尾星标字形（`StarGlyph` / `StarColor`） |
| **高亮** `h` | 只是把这一行画得显眼 | `highlight N` / `unhighlight N`、`Ctrl+H`、右键 | 文字换成高亮色、整行加高亮底色 |

三者可以同时存在，一条条目可以既置顶又收藏又高亮。它们各管各的：收藏不会让条目浮到顶部，置顶也不会让它免于 `clear`，高亮不保护任何东西——`del`、裁剪与 `clear` 把它当普通行处理。

> 行左侧那条强调色竖条是**选中指示**（当前用键盘操作的那一行），不是标记，也不是高亮；插件不画它，主题的 `Accent` 决定它的颜色。高亮走的是文字与背景色，与竖条无关。

## 启用

```ini
# clipboard.ini
Plugins=item-marks
```

不启用时：上面七个命令都不存在，面板没有 `Ctrl+P` / `Ctrl+S` / `Ctrl+H`，右键菜单没有这三项，行上也没有图钉、星标与高亮。记录里已存的 `p` / `s` / `h` 仍在（`clipboard list` 的 `*`、`status` 的计数读不出来，因为没有声明），只是没有入口去改它们。

## 命令

| 命令 | 作用 |
|---|---|
| `clipboard pin N` | 把第 N 条置顶（浮到列表最前，`list` 里前面带 `*`） |
| `clipboard unpin N` | 取消第 N 条的置顶 |
| `clipboard star N` | 收藏第 N 条：`clear` 与自动裁剪永不删除它 |
| `clipboard unstar N` | 取消收藏（取消后才能 `del`） |
| `clipboard highlight N` | 把第 N 条标记为高亮 |
| `clipboard unhighlight N` | 取消高亮 |
| `clipboard marks` | 打印当前字形、颜色与各部分的含义，用于排查样式 |

```
$ clipboard star 2
starred: https://example.com/doc   clear and trimming keep it

$ clipboard highlight 2
highlighted: https://example.com/doc

$ clipboard list
  1  2m    * https://example.com/doc
  2  5m      hello world
```

## 面板

| 位置 | 行为 |
|---|---|
| `Ctrl+P` | 置顶 / 取消置顶 |
| `Ctrl+S` | 收藏 / 取消收藏 |
| `Ctrl+H` | 高亮 / 取消高亮 |
| 右键菜单 | `Pin to top`（已置顶时变 `Remove pin`）、`Star`（已收藏时变 `Remove star`）、`Highlight`（已高亮时变 `Clear highlight`），都带快捷键提示 |
| 行样式 | 置顶与收藏各占一个右侧固定槽位（图钉在右、星标在其左），高亮改整行文字与背景色 |

删除受保护的条目时会提示由谁来解除：

```
$ clipboard del 1
[!] starred entry, unstar it first: clipboard unstar 1
```

面板里同样的操作显示为底部提示：`Starred entry. Press Ctrl+S to unstar it first`。

## 设置项（`clipboard.ini`）

| 键 | 默认 | 说明 |
|---|---|---|
| `item-marks.MaxPins` | `50` | 置顶条数上限，超出时自动取消最旧的置顶（`0` = 不限） |
| `item-marks.ClearKeepsPinned` | `1` | `1` = `clear` 与面板“清空”、托盘菜单保留置顶条目；`0` = 一并清掉（收藏条目仍然保留） |
| `item-marks.HighlightColor` | 空 | 高亮行的文字颜色；**空 = 跟随主题** `[item-marks]` 段的 `EmphasisInk` |
| `item-marks.HighlightBg` | 空 | 高亮行的背景色（带 alpha 才不盖住选中效果）；**空 = 跟随主题**的 `EmphasisFill`（主题里也为空则不加底色） |

```powershell
clipboard config set item-marks.MaxPins 10
clipboard config set item-marks.HighlightColor '#7FD3FF'   # 只改自己的高亮色，不动主题
```

## 高亮颜色的来源

高亮是插件的设置；主题里的 `EmphasisInk` / `EmphasisFill` 是**外部默认**（主题不叫“高亮”，它描述的是“被强调的行”）。两边键名各自独立，优先级从高到低：

| 层次 | 写在哪 | 键名 | 谁改 |
|---|---|---|---|
| 用户设置 | `clipboard.ini` | `item-marks.HighlightColor` / `HighlightBg` | 你（`config set`） |
| 主题默认 | `themes/<name>.ini` | `[item-marks]` 段的 `EmphasisInk` / `EmphasisFill` | 主题作者 |
| 插件默认 | 插件代码 | `#9FDDFF` / `#3360CDFF` | 不需要改 |

所以：ini 里留空就跟着主题走（换主题时颜色一起换）；填了值就只改自己的，主题继续按自己的值渲染别的用户。`clipboard marks` 会打印当前生效值与它来自 `ini` 还是 `theme`。

## 主题项（`themes/<name>.ini` 的 `[item-marks]` 段）

这些是主题侧的默认值（不是 `clipboard.ini` 的键），命名上只描述“被强调的行”，不提具体功能；`EmphasisInk` / `EmphasisFill` 可被 `clipboard.ini` 的 `item-marks.HighlightColor` / `HighlightBg` 覆盖，其余只能由主题改：

| 键 | 默认 | 说明 |
|---|---|---|
| `StarGlyph` | `U+E735` | 收藏行的星标字形 |
| `StarColor` | `#FFC86E` | 星标颜色 |
| `PinColor` | 空 | 图钉颜色，空 = 用主题的 `Mark` 色 |
| `EmphasisInk` | `#9FDDFF` | 强调行的文字色（主题强调色的浅色；可被 `item-marks.HighlightColor` 覆盖） |
| `EmphasisFill` | `#3360CDFF` | 强调行的底色（带 alpha 才不盖住选中效果；可被 `item-marks.HighlightBg` 覆盖） |

```ini
# themes/win11-light.ini
[item-marks]
StarColor=#9D5D00
EmphasisInk=#005FB8
EmphasisFill=#24005FB8
```

> 强调行用**主题强调色系**（深色主题是浅蓝字 + 20% 蓝底，浅色主题是蓝色字 + 14% 蓝底），与星标/图钉的琥珀色分开；不满意蓝色时改这两个键，或用 `item-marks.HighlightColor` 只改自己。

## 它向基础层声明了什么

基础层不认识 `p` / `s` / `h`，规则全部来自插件哈希表里的声明：

| 键 | 值 | 基础层据此做什么 |
|---|---|---|
| `Marks` | `p` 不保护、`s` 保护、`h` 不保护 | 存标记、算 `status` 计数、生成 `clear` / `del` 文案 |
| `SortMark` | `p` | 带 `p` 的行排到列表最前 |
| `ClearKeeps` | `ClearKeepsPinned=1` 时 `@('p')` | `clear` 默认保留置顶行（`-All` 忽略它，`s` 仍然保留） |

也就是说：删掉这个插件，基础层连“置顶”这个概念都不存在；换成别的插件声明别的字符同样成立。

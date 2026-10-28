# item-marks —— 置顶 / 收藏 / 高亮

[← 回到主说明](../../README.md) · [插件契约](../../README.md#插件)

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
# clipboard.ini — 默认已经包含本插件；删掉这一名字才会关闭
Plugins=entry-actions,item-marks,retention,transform
```

不加载时：上面七个命令都不存在，面板没有 `Ctrl+P` / `Ctrl+S` / `Ctrl+H`，右键菜单没有这三项，行上也没有图钉、星标与高亮。记录里已存的 `p` / `s` / `h` 仍在（`clipboard list` 的 `*`、`status` 的计数读不出来，因为没有声明），只是没有入口去改它们。

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
| `item-marks.StickyPins` | `0` | `1` = 搜索时置顶条目**粘在顶部**不参与过滤；`0` = 搜索也把它们过滤掉（默认） |
| `item-marks.StickyRows` | `3` | 搜索时置顶最多占几行；`0` = 能占多少占多少 |

```powershell
clipboard config set item-marks.MaxPins 10
clipboard config set item-marks.ClearKeepsPinned 0
clipboard config set item-marks.StickyPins 1
clipboard config set item-marks.StickyRows 3
```

### 粘性置顶怎么避免“盖住结果”

置顶条目在最前面，粘住之后如果数量一多，可见区域就会被它们占满，搜索出来的东西反而看不见。所以行数上限是**两层**的：

1. `StickyRows` 是你声明的上限；
2. 面板再把它压到 `可见行数 - 1`，**永远留一行给搜索结果自己**。

被挤掉的那几条不会默默消失：底部计数会变成 `10 of 15   3 pinned hidden`，告诉你有 3 条置顶因为放不下而没显示（剩下的仍可滚动看到，取消粘性或滚到底部即可）。

另外，**匹配关键词的置顶条目不受这个上限限制**：它本来就是搜索结果，必须显示。上限只约束“不匹配但被粘住”的那些行。

> 粘性只在**有搜索词时**生效。没有搜索时列表本来就能滚动，所有置顶行照常显示在最前面，不会被隐藏。

高亮行的文字色与底色**不在这里**：它们是外观，归主题管（见下节），`clipboard.ini` 里没有对应键，写进去也会被忽略。

## 主题项（`themes/<name>.ini` 的 `[item-marks]` 段）

这些是主题侧的默认值（不是 `clipboard.ini` 的键），命名上只描述“被强调的行”，不提具体功能；换主题时颜色跟着换，想单改就复制一份主题。

| 键 | 默认 | 说明 |
|---|---|---|
| `StarGlyph` | `U+E735` | 收藏行的星标字形 |
| `StarColor` | `#FFC86E` | 星标颜色 |
| `PinColor` | 空 | 图钉颜色，空 = 用主题的 `Mark` 色 |
| `EmphasisInk` | `#9FDDFF` | 高亮行的文字色（主题强调色的浅色） |
| `EmphasisFill` | `#3360CDFF` | 高亮行的底色（带 alpha 才不盖住选中效果；留空 = 不加底色） |

```ini
# themes/win11-light.ini
[item-marks]
StarColor=#9D5D00
EmphasisInk=#005FB8
EmphasisFill=#24005FB8
```

> 高亮行用**主题强调色系**（深色主题是浅蓝字 + 20% 蓝底，浅色主题是蓝色字 + 14% 蓝底），与星标/图钉的琥珀色分开；不满意蓝色时改这两个主题键。`clipboard marks` 会打印当前生效值与它们来自哪个主题键。

## 它向基础层声明了什么

基础层不认识 `p` / `s` / `h`，规则全部来自插件哈希表里的声明：

| 键 | 值 | 基础层据此做什么 |
|---|---|---|
| `Marks` | `p` 不保护、`s` 保护、`h` 不保护 | 存标记、算 `status` 计数、生成 `clear` / `del` 文案 |
| `SortMark` | `p` | 带 `p` 的行排到列表最前 |
| `StickyMark` | `p` | 搜索时带 `p` 的行留在顶部（`StickyPins=0` 时不生效） |
| `StickyRows` | `StickyPins=1` 时读设置，`0` 变成 `-1` | 声明置顶最多占几行（`-1` = 由面板按可见行数决定） |
| `ClearKeeps` | `ClearKeepsPinned=1` 时 `@('p')` | `clear` 默认保留置顶行（`-All` 忽略它，`s` 仍然保留） |

也就是说：删掉这个插件，基础层连“置顶”这个概念都不存在；换成别的插件声明别的字符同样成立。

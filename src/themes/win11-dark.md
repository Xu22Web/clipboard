# win11-dark —— Windows 11 Fluent 深色（默认）

[← 主说明](../../README.md) · [主题格式](../../README.md#主题)

默认主题，也是界面的**参考布局**：行高、栏高、字体与圆角都以它为准，其余主题在它之上换色。

## 启用

```ini
# clipboard.ini
Theme=win11-dark
```

`Theme` 不写、写空或写错名字时都会回退到这里。

## 这套主题的取值

| 组 | 取值 |
|---|---|
| `Surface` / `Field` | `#202020` / `#2D2D2D` |
| `Text` / `Dim` / `Faint` | `#FFFFFF` / `#AAAAAA` / `#8A8A8A` |
| `Accent` / `AccentSoft` | `#60CDFF` / `#1E60CDFF`（带 alpha） |
| `Border` / `SelBg` / `HoverBg` | `#16FFFFFF` / `#1AFFFFFF` / `#12FFFFFF` |
| `BadgeBg` / `BadgeText` | `#10FFFFFF` / `#C8C8C8` |
| `KeyCapBg` / `KeyCapBorder` | `#0CFFFFFF` / `#1CFFFFFF` |
| `Mark` / `Warn` | `#FFC86E` / `#FF99A4` |
| 字体族 | 空 = 自动（`Segoe UI Variable Text` → `Segoe UI`；图标 `Segoe Fluent Icons` → `Segoe MDL2 Assets`） |
| 字号 | Body 10.5 / Small 9 / Tiny 9 / Title 13 / Icon 12 / IconSmall 10 / IconBig 24 |
| `[item-marks]` | `StarColor=#FFC86E`（星标与默认标记色一致）、`EmphasisInk=#9FDDFF` / `EmphasisFill=#3360CDFF`（强调色浅色 + 20% 蓝底） |

叠层色（`SelBg` / `HoverBg` / `Border` / `BadgeBg` / `AccentSoft` / `KeyCapBorder`）都是带 alpha 的半透明白，面板把它们叠在 `Surface` 上做层次。

## 想改它

- 只想换一两个颜色：复制 `themes/win11-dark.ini` 为 `themes/<你的名字>.ini`，改 `name=` 与对应 token，再把 `Theme=` 指过去（别直接改默认主题，升级时容易被覆盖）。
- token 名单、`[fonts]` / `[metrics]` / `[<插件名>]` 段的写法：见 [主说明的主题一节](../../README.md#主题)。
- 切换后需重启常驻进程生效（`clipboard config set Theme <name>` 会自动重启）。

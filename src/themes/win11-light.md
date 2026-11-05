# win11-light —— Windows 11 Fluent 浅色

[← 主说明](../../README.md) · [主题格式](../../README.md#主题)

与 [`win11-dark`](win11-dark.md) 使用同一套布局，仅将底色与文字反相。

## 启用

```ini
# clipboard.ini
Theme=win11-light
```

```powershell
clipboard config set Theme win11-light    # 主题名 = 文件名，不接受别名
```

## 这套主题的取值

| 组 | 取值 |
|---|---|
| `Surface` / `Field` | `#F3F3F3` / `#FFFFFF` |
| `Text` / `Dim` / `Faint` | `#1A1A1A` / `#5D5D5D` / `#8A8A8A` |
| `Accent` / `AccentSoft` | `#005FB8` / `#1A005FB8`（带 alpha） |
| `Border` / `SelBg` / `HoverBg` | `#12000000` / `#16000000` / `#0D000000` |
| `BadgeBg` / `BadgeText` | `#0E000000` / `#5D5D5D` |
| `KeyCapBg` / `KeyCapBorder` | `#FFFFFF` / `#1A000000` |
| `Mark` / `Warn` | `#9D5D00` / `#C42B1C` |
| 字体族 | 空 = 自动（同 `win11-dark`） |
| 字号 | Body 10.5 / Small 9 / Tiny 9 / Title 13 / Icon 12 / IconSmall 10 / IconBig 24 |
| `[item-marks]` | `StarColor=#9D5D00`、`EmphasisInk=#005FB8` / `EmphasisFill=#24005FB8`（强调色本身 + 14% 蓝底） |

浅色主题的叠层色是带 alpha 的**黑**，叠加在近白的 `Surface` 上形成层次。

## 修改方式

- 调整颜色：复制为 `themes\<名称>.ini`，修改 `name=` 与 token，再把 `Theme=` 指向新文件。
- token 名单与各段写法：见 [主说明的主题一节](../../README.md#主题)。
- 浅色主题中 `Mark` / `Warn` / 星标等彩色小字需压暗，直接使用深色主题的亮色会降低可读性。

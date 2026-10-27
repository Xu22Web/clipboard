# win11-light —— Windows 11 Fluent 浅色

[← 主说明](../README.md) · [主题格式](../README.md#主题)

和 [`win11-dark`](win11-dark.md) 是同一套布局，只把底色与文字反相：白天或亮屏环境更省眼。

## 启用

```ini
# clipboard.ini
Theme=win11-light
```

```powershell
clipboard config set Theme light    # dark / light 是别名，会写成完整主题名
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
| `[item-marks]` | `StarColor=#9D5D00`、`HighlightColor=#7A3E00` / `HighlightBg=#33FFB84D`（浅底上用更深的琥珀色才看得清） |

浅色主题的叠层色是带 alpha 的**黑**，压在近白的 `Surface` 上形成同样的层次感。

## 想改它

- 换一两个颜色：复制成 `themes/<你的名字>.ini`，改 `name=` 与 token，再把 `Theme=` 指过去。
- token 名单与各段写法：见 [主说明的主题一节](../README.md#主题)。
- 浅色主题里请特别注意 `Mark` / `Warn` / 星标这类"彩色小字"：在 `#F3F3F3` 上要压暗，直接用深色主题的亮色会看不清。

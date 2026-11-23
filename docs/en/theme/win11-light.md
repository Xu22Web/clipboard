# win11-light — Windows 11 Fluent light

[← back to the main document](../../../README.md) · [theme format](../../../README.md#themes)

The same layout as [`win11-dark`](win11-dark.md), with the background and the ink inverted.

## Enabling it

```ini
# clipboard.ini
Theme=win11-light
```

```powershell
clipboard config set Theme win11-light    # the name is the file name; aliases are not accepted
```

## Values of this theme

| Group | Value |
|---|---|
| `Surface` / `Field` | `#F3F3F3` / `#FFFFFF` |
| `Text` / `Dim` / `Faint` | `#1A1A1A` / `#5D5D5D` / `#8A8A8A` |
| `Accent` / `AccentSoft` | `#005FB8` / `#1A005FB8` (with alpha) |
| `Border` / `SelBg` / `HoverBg` | `#12000000` / `#16000000` / `#0D000000` |
| `BadgeBg` / `BadgeText` | `#0E000000` / `#5D5D5D` |
| `KeyCapBg` / `KeyCapBorder` | `#FFFFFF` / `#1A000000` |
| `Mark` / `Warn` | `#9D5D00` / `#C42B1C` |
| font family | empty = automatic (as in `win11-dark`) |
| point sizes | Body 10.5 / Small 9 / Tiny 9 / Title 13 / Icon 12 / IconSmall 10 / IconBig 24 |
| `[item-marks]` | `StarColor=#9D5D00`, `EmphasisInk=#005FB8` / `EmphasisFill=#24005FB8` (the accent itself on a 14 % blue fill) |

The overlay colours of a light theme are **black** with alpha, laid over the near-white `Surface` to build depth.

## Changing it

- To adjust colours, copy the file to `themes\<name>.ini`, change `name=` and the tokens, then point `Theme=` at it.
- The token list and the sections are described in [the themes section of the main document](../../../README.md#themes).
- On a light surface the small coloured words (`Mark` / `Warn` / the star) have to be darker; reusing the bright values of the dark theme costs readability.

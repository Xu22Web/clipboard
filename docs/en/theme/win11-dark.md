# win11-dark — Windows 11 Fluent dark (default)

[← back to the main document](../../../README.md) · [theme format](../../../README.md#themes)

The default theme and the **reference layout** of the interface: row height, bar heights, fonts and radii follow it, and every other theme changes the colours on top of it.

## Enabling it

```ini
# clipboard.ini
Theme=win11-dark
```

A missing, empty or misspelled `Theme` falls back here.

## Values of this theme

| Group | Value |
|---|---|
| `Surface` / `Field` | `#202020` / `#2D2D2D` |
| `Text` / `Dim` / `Faint` | `#FFFFFF` / `#AAAAAA` / `#8A8A8A` |
| `Accent` / `AccentSoft` | `#60CDFF` / `#1E60CDFF` (with alpha) |
| `Border` / `SelBg` / `HoverBg` | `#16FFFFFF` / `#1AFFFFFF` / `#12FFFFFF` |
| `BadgeBg` / `BadgeText` | `#10FFFFFF` / `#C8C8C8` |
| `KeyCapBg` / `KeyCapBorder` | `#0CFFFFFF` / `#1CFFFFFF` |
| `Mark` / `Warn` | `#FFC86E` / `#FF99A4` |
| font family | empty = the language file's family, then automatic (`Segoe UI Variable Text` → `Segoe UI`; icons `Segoe Fluent Icons` → `Segoe MDL2 Assets`) |
| point sizes | Body 10.5 / Small 9 / Tiny 9 / Title 13 / Icon 12 / IconSmall 10 / IconBig 24 |
| `[item-marks]` | `StarColor=#FFC86E` (the star matches the default mark colour), `EmphasisInk=#9FDDFF` / `EmphasisFill=#3360CDFF` (a light accent ink on a 20 % blue fill) |

The overlay colours (`SelBg` / `HoverBg` / `Border` / `BadgeBg` / `AccentSoft` / `KeyCapBorder`) are translucent white with alpha, which the panel lays over `Surface` to build depth.

## Changing it

- To adjust a few colours, copy `themes\win11-dark.ini` to `themes\<name>.ini`, change `name=` and the tokens, then point `Theme=` at the new file. Editing the default theme in place is not recommended: an upgrade overwrites it.
- The token list and the `[fonts]` / `[metrics]` / `[<plugin>]` sections are described in [the themes section of the main document](../../../README.md#themes).
- A theme switch takes effect after the resident restarts (`clipboard config set Theme <name>` does it).

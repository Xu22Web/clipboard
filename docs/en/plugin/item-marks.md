# item-marks — pin / star / highlight

[← back to the main document](../../../README.md) · [plugin contract](../../../README.md#plugins)

Three independent marks carried by one plugin:

| Mark | What it does | Where to set it | On the row |
|---|---|---|---|
| **pin** `p` | floats to the top and is exempt from trimming | `pin N` / `unpin N`, `Ctrl+P`, context menu | a pin glyph at the end (`PinColor`) |
| **star** `s` | `clear` and trimming never remove it, and `del` needs it removed first | `star N` / `unstar N`, `Ctrl+S`, context menu | a star glyph at the end (`StarGlyph` / `StarColor`) |
| **highlight** `h` | only draws the row more prominently | `highlight N` / `unhighlight N`, `Ctrl+H`, context menu | the ink and the background change |

All three can be on at once, and each one does its own thing: a star does not float a row to the top, a pin does not save it from `clear`, and a highlight protects nothing — `del`, trimming and `clear` treat it as an ordinary row.

> The accent bar on the left of a row is the **selection indicator** (the row the keyboard acts on), not a mark and not a highlight: it comes from the theme's `Accent` and the plugin never draws it. A highlight only changes the ink and the fill.

## Enabling it

```ini
# clipboard.ini - listed by default; removing the name turns it off
Plugins=entry-actions,item-marks,retention,transform
```

Without it none of the seven commands exist, the panel has no `Ctrl+P` / `Ctrl+S` / `Ctrl+H`, the context menu has no such rows, and no pin, star or highlight is drawn. Marks already stored in the history stay (the `*` in `clipboard list` and the counts in `status` cannot be read, because nothing declares them), but nothing can change them any more.

## Commands

| Command | Effect |
|---|---|
| `clipboard pin N` | pin entry N (to the top, with `*` in `list`) |
| `clipboard unpin N` | remove the pin |
| `clipboard star N` | star entry N: neither `clear` nor trimming will remove it |
| `clipboard unstar N` | remove the star (only then does `del` work) |
| `clipboard highlight N` | mark entry N as highlighted |
| `clipboard unhighlight N` | remove the highlight |
| `clipboard marks` | print the glyphs, the colours and what each part means, to check the styling |

```
$ clipboard star 2
starred: https://example.com/doc   clear and trimming keep it

$ clipboard highlight 2
highlighted: https://example.com/doc

$ clipboard list
  1  2m    * https://example.com/doc
  2  5m      hello world
```

## Panel

| Where | Behaviour |
|---|---|
| `Ctrl+P` | pin / unpin |
| `Ctrl+S` | star / unstar |
| `Ctrl+H` | highlight / clear the highlight |
| context menu | `Pin to top` (`Remove pin` when pinned), `Star` (`Remove star`), `Highlight` (`Clear highlight`), each with its key hint |
| row style | a pin and a star each take a fixed slot on the right (pin rightmost, star beside it); a highlight changes the whole row's ink and fill |

Deleting a protected entry says who has to release it:

```
$ clipboard del 1
[!] starred entry, unstar it first: clipboard unstar 1
```

The same action in the panel reads `Starred entry. Press Ctrl+S to unstar it first` in the footer.

## Settings (`clipboard.ini`)

The four keys are declared in `shared\schema\plugins\item-marks.ps1` and merged into the settings on load; in the file they live in the `[item-marks]` section, and `config set` uses `<plugin>.<Key>`:

| Key | Default | Meaning |
|---|---|---|
| `item-marks.MaxPins` | `50` | pinned-entry cap; over it the oldest pin is dropped automatically (`0` = no cap) |
| `item-marks.ClearKeepsPinned` | `1` | `1` = `clear`, the panel's clear and the tray row keep pinned entries; `0` = drop them too (a starred entry still stays) |
| `item-marks.StickyPins` | `1` | `1` = pinned rows **freeze** on top and do not scroll; `0` = they scroll away like any other row |
| `item-marks.StickyRows` | `3` | how many rows the frozen pins may take; `0` = as many as fit (visible rows − 1) |

```powershell
clipboard config set item-marks.MaxPins 10
clipboard config set item-marks.ClearKeepsPinned 0
clipboard config set item-marks.StickyPins 0
clipboard config set item-marks.StickyRows 3
```

### Frozen pins and the pin limit

With stickiness on, **every pinned row freezes on top** and does not scroll. How many fit is the smaller of:

1. `item-marks.StickyRows` (the rows the plugin declares);
2. visible rows − 1: the panel caps it again and **always leaves one row for the list below**.

So the pins cannot outnumber that limit, or the whole list would be fixed and nothing below would show. Pinning once the limit is reached is refused with the reason:

```
$ clipboard pin 8
[!] sticky pins already take 9 of 9 rows - unpin one first
    raise Rows or item-marks.StickyRows for more room, or turn StickyPins off
```

`Ctrl+P` and the context menu's "Pin to top" refuse the same way and say so in the footer. There are three ways to make room: raise `Rows`, raise `item-marks.StickyRows` (up to `Rows - 1`), or set `item-marks.StickyPins` to `0` (no stickiness, and then no pin limit).

The frozen count shows in the footer count: `10 of 15   3 pinned`. Lowering `Rows` does not delete the extra pins; they scroll with the list.

The highlight ink and fill are **not** here: they are appearance and belong to the theme (next section). `clipboard.ini` has no such keys, and writing them is ignored.

## Theme keys (the `[item-marks]` section of `themes/<name>.ini`)

These are the theme-side defaults (not `clipboard.ini` keys), named after "the emphasised row" rather than the feature; they follow the theme, and copying a theme is how you change one.

| Key | Default | Meaning |
|---|---|---|
| `StarGlyph` | `U+E735` | the star glyph on a starred row |
| `StarColor` | `#FFC86E` | the star's colour |
| `PinColor` | empty | the pin's colour; empty = the theme's `Mark` |
| `EmphasisInk` | `#9FDDFF` | the ink of a highlighted row (a light accent) |
| `EmphasisFill` | `#3360CDFF` | the fill of a highlighted row (it needs alpha so the selection still shows; empty = no fill) |

```ini
# themes/win11-light.ini
[item-marks]
StarColor=#9D5D00
EmphasisInk=#005FB8
EmphasisFill=#24005FB8
```

> A highlighted row uses the **theme accent family** (light blue ink on a 20 % blue fill in the dark theme, blue ink on 14 % in the light one), which keeps it apart from the amber of the star and the pin. `clipboard marks` prints the values in effect and the theme key they came from.

## What it declares to the base layer

The base layer knows nothing of `p` / `s` / `h`; every rule comes from the plugin's hashtable:

| Key | Value | What the base layer does with it |
|---|---|---|
| `Marks` | `p` unprotected, `s` protected, `h` unprotected | stores the marks, counts them for `status`, writes the `clear` / `del` wording |
| `SortMark` | `p` | rows with `p` go to the top |
| `StickyMark` | `p` | rows with `p` freeze on top (inactive while `StickyPins=0`) |
| `StickyRows` | the setting while `StickyPins=1`, `0` becomes `-1` | how many rows the pins may take (`-1` = the panel decides from the visible rows); a pin action should check the remaining quota with `Get-PluginStickyCap` |
| `ClearKeeps` | `@('p')` while `ClearKeepsPinned=1` | `clear` keeps pinned rows by default (`-All` ignores it; `s` stays anyway) |

In other words: remove this plugin and the base layer has no notion of a pin at all; another plugin declaring other letters works just as well.

# entry-actions — type analysis and opening

[← back to the main document](../../../README.md) · [plugin contract](../../../README.md#plugins)

Judging a type and acting on it are one flow: **decide what an entry is, then act on that**.

- **Judging**: `kind` reports the type, the size, a broken-down target (host / path / mail / file list / picture size) and the formats it sniffs (JSON, XML, Base64, colour, IP, UUID, hash…); `kinds` counts how the whole history is distributed.
- **Acting**: `open` opens by type — a link goes to the browser, a file path is revealed in Explorer, a file list opens its first file, a picture goes to the default viewer.

## Enabling it

```ini
# clipboard.ini - listed by default; removing the name turns it off
Plugins=entry-actions,item-marks,retention,transform
```

Without it `kind` / `kinds` / `open` are unknown commands, the panel has no `Ctrl+O` and the context menu has no `Open link or path`.

## Commands

### `clipboard kind N` — analyse one entry

```
$ clipboard kind 3
entry 3   kind link
  size    : 41 chars   1 line(s)   3 word(s)
  target  : https   example.com   /docs/start   ?q=1
  format  : (none)
  state   : pinned, age 4m
  preview : https://example.com/docs/start?q=1
```

The `target` line changes with the type:

| Type | `target` contents |
|---|---|
| `link` | scheme, host, path, query |
| `mail` | `user` / `domain` |
| `path` | file name, extension, folder, whether it exists |
| `files` | how many files, plus the first five names |
| `image` | size, format, bytes, where it lives in `data\media\` (a missing file is flagged) |
| `code` | a language guess (C / C# / Python / PowerShell / JavaScript / Java / Go / SQL) |

The `format` line stacks several sniffers, for example `json, colour #FF6600, rgb(255,102,0)`, `base64 128 bytes`, `hash sha256`, `uuid`, `ipv4`, `date`, `version`, `number 1234.5`, `yaml-like`.

### `clipboard kinds` — the overall distribution

```
$ clipboard kinds
kinds in 42 entries:
  link     12    29%
  path      5    12%
  files     3     7%
  code      2     5%
  multi     6    14%
  text     14    33%
  1 pinned   1 starred   chars 18422
```

### `clipboard open N` — open by type

| Entry type | Action |
|---|---|
| link (`http` / `https` / `ftp` / `file`) | open it in the browser named by `Browser`, or the system default when empty |
| file path | with `Reveal=1` reveal it in Explorer, with `0` run it |
| file list (from a multi-select copy in Explorer) | take the first file, then as above |
| picture | open the matching PNG in `data\media\` with the default viewer |
| anything else | hand it to the shell with `Start-Process` |

```
$ clipboard open 4
opened: https://example.com/docs/start
```

## Row icons

With this plugin loaded the rows start with a type icon (`Segoe Fluent Icons`, `Segoe MDL2 Assets` on Win10; without an icon font the plugin draws none):

| Type | Icon |
|---|---|
| `link` | link |
| `mail` | mail |
| `path` / `files` | folder |
| `image` | picture |
| `code` | code |
| `multi` | multiple lines |
| `text` | document |

The icon comes from `TypeGlyph` and `ShowTypeIcon=0` turns it off; without this plugin a row has no icon at all and the text starts at the left edge.

## Panel and context menu

| Where | Behaviour |
|---|---|
| `Ctrl+O` | open the selected link / path / picture (silently does nothing for the kinds it cannot open) |
| context menu `Open link or path` | the same, shown for links / paths / file lists / pictures |

`Ctrl+O` and the context-menu row share one decision and one action. Both call the blocks the plugin exports:

| Block | Purpose |
|---|---|
| `KindOf` | entry → type (used by the command, the menu, the key and the `kinds` count) |
| `CanOpen` | whether this row can be opened (the `Test` of the row and of `Ctrl+O`) |
| `OpenPayload` | perform the open (the command, the row and `Ctrl+O` all call it) |
| `Sniff` | format sniffing (the result only, no formatting) |

## Settings (`clipboard.ini`)

The keys are declared in `shared\schema\plugins\entry-actions.ps1` and merged into the settings on load; in the file they live in the `[entry-actions]` section, and `config set` uses `<plugin>.<Key>`:

| Key | Default | Meaning |
|---|---|---|
| `entry-actions.Detail` | `full` | the shape of `kind`: `short` = one summary line, `full` = the whole block |
| `entry-actions.PreviewChars` | `100` | characters kept in the `kind` preview (20–400) |
| `entry-actions.Detect` | `json,xml,yaml,base64,color,ip,uuid,number,version,date,hash` | the sniffers to run, comma separated; an unknown name is ignored |
| `entry-actions.ShowTargets` | `1` | `1` = print the `target` line (links / paths / mail / file lists broken down) |
| `entry-actions.Browser` | empty | the browser exe used for http(s) links, empty = the system default |
| `entry-actions.Reveal` | `1` | `1` = reveal a file in Explorer, `0` = run it |

```powershell
clipboard config set entry-actions.Detail short
clipboard config set entry-actions.Detect json,base64,hash
clipboard config set entry-actions.Reveal 0
```

## Notes

- The base tool tells only **text / file list / picture** apart (`Get-EntryKind`, used for storage and the paste round trip) and **draws no row icon of its own**: every icon comes from this plugin's `TypeGlyph`. The command, the menu and `Ctrl+O` share one classifier (`KindOf`), so the rules exist once.
- The marks on an entry (pin / star / highlight) are not part of this plugin: the `state` line of `kind` asks the base layer for the mark words (`Get-RecordMarkWords`) and the last line of `kinds` uses the same counts, with or without `item-marks`.
- Sniffing reads the first 8000 characters, so a large body cannot slow the output down; `json` is really parsed with `ConvertFrom-Json`, and a failure shows as `json-like (invalid)`.
- Sniffing reads the content and writes nothing; the history is never modified.

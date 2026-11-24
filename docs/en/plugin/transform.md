# transform — rewrite text before pasting

[← back to the main document](../../../README.md) · [plugin contract](../../../README.md#plugins)

When a selected entry is pasted with `Enter`, its content is rewritten in the chosen mode first: plain text, upper case, lower case, camel, snake, kebab or title. It exists to paste the same content where the format differs (an IDE, a terminal, a database).

## Enabling it

```ini
# clipboard.ini - listed by default; removing the name turns it off
Plugins=entry-actions,item-marks,retention,transform
```

Without it, pasting uses the raw text and `transform` is an unknown command.

## Commands

| Command | Effect |
|---|---|
| `clipboard transform N` | rewrite entry N in the configured `Mode` and write the clipboard |
| `clipboard transform "N mode"` | pick a mode for this call only (quote the whole argument) |

```
$ clipboard transform 1 upper
[upper] HELLO WORLD DEMO

$ clipboard transform "1 snake"
[snake] hello_world_demo
```

## Modes

| `Mode` | Effect | Example (input `Hello World demo`) |
|---|---|---|
| `keep` | no rewrite (the default) | `Hello World demo` |
| `text` | plain text: line breaks and runs of spaces become one space | `Hello World demo` |
| `upper` | all upper case | `HELLO WORLD DEMO` |
| `lower` | all lower case | `hello world demo` |
| `camel` | camel case | `helloWorldDemo` |
| `snake` | snake case | `hello_world_demo` |
| `kebab` | kebab case | `hello-world-demo` |
| `title` | title case | `Hello World Demo` |

Camel, snake, kebab and title split on spaces, underscores, hyphens and the lower-to-upper boundary first, then join in the target shape.

## Context menu

Every configured mode is one row in the context menu: `Transform as snake_case`, `Transform as UPPER`, and so on. Choosing one rewrites the entry in that mode, writes the clipboard, pastes it into the window you came from and records it in the history. `transform.Modes` decides how many rows there are:

```ini
# clipboard.ini: three rows on the context menu, in this order
transform.Modes=snake,kebab,upper
```

- `transform.Modes` defaults to **all seven modes**; an empty value means the default.
- Names are case-insensitive and spaces or commas separate them; a duplicate is dropped, and a misspelled name puts the whole value back to the default with a line in `clipboard config` / `status`.
- A file-list entry shows no rows (its paste path is untouched), and neither does an empty entry.
- `Mode` only decides what **pasting** does; `Modes` only decides what the **menu** lists. They do not affect each other, so `Mode=keep` with `Modes=snake,upper` is a sensible pair.
- The rows are declared by the plugin itself (`ContextMenu` as a script block that computes them); the base layer groups plugin rows, one caption per plugin and a separator between groups.

## Settings (`clipboard.ini`)

The keys are declared in `shared\schema\plugins\transform.ps1` and merged into the settings on load; in the file they live in the `[transform]` section, and `config set` uses `<plugin>.<Key>`:

| Key | Default | Meaning |
|---|---|---|
| `transform.Mode` | `keep` | the mode pasting uses (`keep` / `text` / `upper` / `lower` / `camel` / `snake` / `kebab` / `title`) |
| `transform.Modes` | `text,upper,lower,camel,snake,kebab,title` | the modes listed in the context menu, comma separated; only the seven above are accepted |
| `transform.Trim` | `1` | `1` = strip leading and trailing whitespace from the result |

```powershell
clipboard config set transform.Mode snake
clipboard config set transform.Modes 'snake,kebab,upper'
clipboard config set transform.Trim 0
```

## Notes

- There is one rewrite rule: the paste hook, the `transform` command and the context-menu rows all call the plugin's `Apply` / `CopyAs` blocks; the command line adds only "take entry N, write the clipboard, record it".
- **File-list and picture entries are never rewritten**: one is a set of paths, the other a picture description, and a rewrite would break both.
- The rewrite happens on the **paste path** only; `clipboard get` / `clipboard put` and what the history holds stay as they were.
- With the resident running, `config set transform.Mode ...` restarts it so the value takes effect.
- A one-off mode (`clipboard transform "3 upper"`) changes no setting and affects that call only.

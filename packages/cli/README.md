# cli

The command layer of the tooling, shaped like electron-vite. It reads `builder.cli.config.ps1`,
applies the presets and the defaults, and calls `packages\bundler` for a bundle or
`packages\builder` for a release.

| Path | What it holds |
|---|---|
| `bin/cli.ps1` | the command itself: loads the packages and dispatches `build` / `release` / `bundle` / `dev` / `test` |
| `index.ps1` | the entry; exports `Invoke-CliCommand` |
| `config.ps1` | reads the target table, applies presets, and holds the tooling's defaults |
| `bundle.ps1` | `cli bundle`: one target, or `-All` with one process per target |
| `build.ps1` | `cli build`: every shipped target, then the release |
| `watch.ps1` | `cli dev`: watch the file list, rebuild, restart the resident |
| `assembly.ps1`, `client.ps1` | the two C# products |
| `bench.ps1`, `shot.ps1` | measurement and screenshots |
| `plugins/presets.ps1` | the named chains a target can start from |
| `schema/` | the shape `cli.ini` and the config file are checked against |
| `utils/` | this package's copies of console, ini, schema, globs, minify and the compiler helper |

The defaults of the whole tooling live in `config.ps1` - `Minify`, `Rename`, `Treeshake`,
`Workers`, and the dev poll interval. A `Bundler` or `Watch` section in `builder.cli.config.ps1`
only overrides one, the way a `vite.config.ts` writes `build.minify` only when it is not the
default.

Requires `bundler` and `builder`; the release layer is loaded only by `cli build`.

`bin/cli.ps1` is the command. `builder.cli.ps1` at the repository root is a launcher for the
paths `package.ini` already uses, the way vite's package ships `bin/vite.js` and the project
keeps its own script name.

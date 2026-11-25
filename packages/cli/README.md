# cli

The command layer of the tooling, shaped like electron-vite. It reads `builder.cli.config.ps1`,
applies the presets and the defaults, and calls `packages\bundler` for a bundle or
`packages\builder` for a release.

| Path | What it holds |
|---|---|
| `bin/cli.ps1` | the command itself: loads the packages and dispatches `build` / `release` / `bundle` / `dev` |
| `index.ps1` | the entry; exports `Invoke-CliCommand` |
| `config.ps1` | reads the target table, applies presets, and holds the tooling's defaults |
| `bundle.ps1` | `run bundle`: one target, or `-All` with one process per target |
| `build.ps1` | `run build`: every shipped target, then the release |
| `watch.ps1` | `run dev`: watch the file list, rebuild, restart the resident |
| `assembly.ps1`, `client.ps1` | the two C# products, run as plain scripts |
| `bench.ps1`, `shot.ps1` | measurement and screenshots, run as plain scripts |
| `plugins/presets.ps1` | the named chains a target can start from |
| `schema/` | the shape `cli.ini` and the config file are checked against |
| `utils/` | this package's copies of console, ini, schema, globs, minify and the compiler helper |

The defaults of the whole tooling live in `config.ps1` - `Minify`, `Rename`, `Treeshake`,
`Workers`, and the dev poll interval. A `Bundler` or `Watch` section in `builder.cli.config.ps1`
only overrides one, the way a `vite.config.ts` writes `build.minify` only when it is not the
default.

Requires `bundler`, `builder` and `test`; the release layer is loaded only by `run build`, and
`test` only by `run release`, which checks the folder it wrote.

`package.ini` registers the command as `builder-cli` (`Bin=builder-cli=bin/cli.ps1`), the way a
package.json may name an executable differently from its package. `run.ps1` at the repository
root is the runner that resolves that name for the lines of `package.ini [scripts]`; the suite
and the four auxiliary scripts are not behind this command: `test` registers `builder-test`, and
`client`, `assembly`, `bench` and `shot` are run by path.

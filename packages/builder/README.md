# builder

The release writer, shaped like electron-builder. It is handed the finished outputs and the file
list in `builder.ini`, stages the package folder, writes the resolved configuration beside it,
and - on `cli release` - archives the folder and runs the suite against the copy.

| Path | What it holds |
|---|---|
| `index.ps1` | the entry; exports `Invoke-Package` and `Invoke-BuilderArchive` |
| `package.ps1` | staging, packing, `builder-effective-config.ini`, the leak list |
| `assets.ps1`, `assets/` | one handler per kind of file: script, batch, ini, copy |
| `plugins/files.ps1` | the file list, in electron-builder's minimatch order |
| `schema/builder.ps1` | the keys `builder.ini` may carry |
| `utils/` | this package's copies of console, ini, schema, globs and minify |

`builder.ini` is the project's `electron-builder.yml`: `Compression`, `directories.Output`,
`directories.BaseUrl` and `files.Files`. The resolved result is written to
`directories.Output\builder-effective-config.ini`, the same idea as electron-builder's
`builder-effective-config.yaml`.

It never builds a target and never reads `builder.cli.config.ps1`: what it packs arrives as a
list of paths from `packages\cli`.

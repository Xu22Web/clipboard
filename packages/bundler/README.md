# bundler

The engine behind `run bundle` and `run build`. It is handed one resolved target and returns
file paths: it reads the modules the entry reaches through the call graph and the `#@use` edges,
marks the definitions a load-time path can reach, groups the modules by the entries that reach
them, writes one chunk per group plus `manifest.ini`, and verifies every chunk against the
modules it was built from.

| Path | What it holds |
|---|---|
| `index.ps1` | the entry; exports `Invoke-BundleTarget` and `Get-BundlerRoot` |
| `bundler.ps1` | reads the target document, splits the chunks, writes them, writes the manifest |
| `lib/ast.ps1` | parser helpers: function names, command names, strings, `#@use` / `#@export` |
| `lib/chunk.ps1` | reachability grouping, the content hash, the output templates |
| `lib/graph.ps1` | which definitions a load-time path reaches |
| `lib/emit.ps1`, `lib/surface.ps1` | statement emission, the import and export report |
| `plugins/` | one file per stage: resolve, treeshake, merge, render, C# part, C# compile, verify |
| `utils/` | this package's copies of console, ini, schema, globs and minify |

It reads no configuration file. `packages\cli` resolves the target table and hands this package
`{ Root, OutDir, Workers, Targets }`; the stage chain is the target's `Plugins=` list.

Requires nothing. `package.ini` names the entry, what it exports, and the PowerShell version it
runs on.

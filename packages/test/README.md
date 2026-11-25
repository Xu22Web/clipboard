# test

The test runner, shaped like vitest. It reads `test.config.ps1`, starts the parts that config
allows (one Windows PowerShell process per part), and reports one row per check with a live
window while the run is going.

| Path | What it holds |
|---|---|
| `index.ps1` | the entry; exports `Invoke-Test` and `Get-TestConfig` |
| `config.ps1` | the groups, exclusions, worker count and reporter `test.config.ps1` declares |
| `utils/` | the driver, the reporter and this package's copies of console and ini |

The parts themselves live under `tests\` in the repository - a test is a file of the project, not
of the tool that runs it. `builder.ini` naming `Verify=1` is this package being asked for by name:
a release that fails its own suite is removed before it is reported as done.

Requires nothing, so a release can check itself with the same package that a developer runs.

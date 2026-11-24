# test.config.ps1 - how the suite runs, shaped like vitest.config.ts.
#
# The file is a PowerShell expression that returns one ordered table. dot-sourcing it gives the
# shape back, and packages\test\config.ps1 checks that shape before a run starts: a key the
# loader does not know is a broken file, not a default.
#
#   Groups     the groups a plain `cli test` covers     vitest: the projects a plain run builds
#   Exclude    a part whose path matches one never runs  vitest: exclude
#   Workers    parts that may run side by side, 0 = one per logical processor
#                                                       vitest: maxWorkers
#   Reporter   default | verbose                        vitest: reporters
#   Bail       stop starting parts after the first failure
#                                                       vitest: bail
#   Serial     one part at a time                       vitest: fileParallelism: false
#
# The three groups are what the parts are: unit runs in process, integration drives the command
# line, e2e drives the resident and the machine clipboard (and must run alone).

[ordered]@{
  Test = [ordered]@{
    Groups   = @('unit', 'integration', 'e2e')
    Exclude  = @()
    Workers  = 0
    Reporter = 'default'
    Bail     = $false
    Serial   = $false
  }
}

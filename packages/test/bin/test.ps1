#Requires -Version 5.1
<#
  packages\test\bin\test.ps1 - the builder-test command. Assemble the packages, then run the suite.

      builder-test                   run every part
      builder-test -Unit             one group, by name
      builder-test -Part cli,history several parts, by name
      builder-test -Source <dir>     the command line parts against a packaged copy

  It sits in the package the way vitest's bin\vitest.mjs does: the suite is a tool of its own,
  not a subcommand of the build tool. Every argument belongs to the suite, so the whole command
  line is handed over as it arrives.
#>

$ErrorActionPreference = 'Stop'
# bin -> test -> packages -> the repository
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))

# the suite's public surface, imported the way a script imports a module
. (Use-Module '../index.ps1' $PSCommandPath)

Set-Location -LiteralPath $root
exit (Invoke-Test -Arguments $args)

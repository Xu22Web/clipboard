#Requires -Version 5.1
<#
  packages\cli\bin\cli.ps1 - the command itself. Assemble the packages, then run one of them.

      cli                  list what this tooling can do
      cli build            build every target and write the release
      cli bundle -All      build targets without packing (one target by -Entry)
      cli bundle -Inspect  say which modules a bundle cannot inline
      cli dev              watch the tree and restart the development copy
      cli test -Part unit  run the suite

  It sits in the package the way vite's bin\vite.js does; the repository root keeps a launcher
  (builder.cli.ps1) for the paths its package.ini commands already use.

      bundler   the engine: resolve, treeshake, merge, render, verify, cs-part, cs-compile
                nothing in it knows what an "electron main process" is
      cli       the shapes and the loop: the electron presets in plugins\, the resolve step,
                build, the watcher, and the auxiliary commands (test, shot, bench, client,
                assembly)
      builder   the release: the files list, the staging pass, the archive, the check run

  Each package declares Main, Exports and Requires in its own package.ini. This file loads what
  they export and calls it; a package never loads another one by itself, so the arrows only ever
  point out of packages\cli towards bundler and builder, and this file is where they are drawn.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = '',
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
# bin -> cli -> packages -> the repository
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
$cliMain = Join-Path $root 'packages\cli\index.ps1'
if (-not (Test-Path -LiteralPath $cliMain)) {
  Write-Host ('[x] missing: ' + $cliMain)
  exit 1
}

# packages\cli first: it carries the logger, the config reader and the command table, and every
# other package is loaded on top of it
. $cliMain

# the other packages, loaded through the declaration in their own package.ini
$refs = @{}
foreach ($name in @('bundler', 'builder', 'test')) {
  $refs[$name] = Get-CliPackageRef $name
}

$wanted = $Command.ToLower()
if (-not $wanted -or @('help', '-h', '--help', '-?', '/?') -contains $wanted) {
  Write-Title 'cli'
  Write-Host ''
  Write-Note 'usage: cli <command> [args]'
  Write-Host ''
  $width = 8
  foreach ($pair in @(
      @('build', 'build every target, then stage and pack the release')
      @('release', 'build, then run the suite against the package and drop it when the suite fails')
      @('bundle', 'build one target or all of them; -Inspect lists what cannot be inlined')
      @('dev', 'watch the tree and restart the development copy')
      @('test', 'run the suite: -Unit, -Integration, -E2E, -Part <name>')
    )) {
    Write-Pair ([string]$pair[0]) ([string]$pair[1]) $width
  }
  Write-Host ''
  Write-Note ('packages  ' + ((@($refs.Keys) | ForEach-Object { $_ + ' (' + (($refs[$_].Exports) -join ', ') + ')' }) -join '   '))
  exit 0
}

# every command below runs at the repository root, the same way `cli` runs one
Set-Location -LiteralPath $root

switch ($wanted) {
  'build' {
    . $refs['bundler'].MainPath
    . $refs['builder'].MainPath
    . (Join-Path $root 'packages\cli\build.ps1')
    $bound = ConvertTo-ArgumentTable $Rest
    exit (Invoke-CliBuild @bound).Code
  }
  'release' {
    # the two steps the release flow keeps apart: write the folder, then check the folder. Packing
    # never deletes its own output on a test failure - that decision belongs here.
    . $refs['bundler'].MainPath
    . $refs['builder'].MainPath
    . (Join-Path $root 'packages\cli\build.ps1')
    . $refs['test'].MainPath
    $bound = ConvertTo-ArgumentTable $Rest
    $built = Invoke-CliBuild @bound
    if ($built.Code -ne 0) { exit $built.Code }
    if (-not $built.Package) { Write-Fail 'no package path; nothing to check'; exit 1 }
    $code = Invoke-Test -Arguments @('-Integration', '-Source', $built.Package, '-Serial')
    if ($code -ne 0) {
      Remove-Item -LiteralPath $built.Package -Recurse -Force -ErrorAction SilentlyContinue
      Write-Fail 'the package failed its own suite; output removed'
      exit $code
    }
    # the archive is release output, not build output: the folder is already written and checked
    $zip = Invoke-BuilderArchive -PackageDir $built.Package
    $size = [Math]::Round((Get-Item -LiteralPath $zip).Length / 1KB, 1)
    Write-Note ('release checked: ' + $built.Package)
    Write-Note ('archive          ' + $zip + '   ' + $size + ' KB')
    exit 0
  }
  'bundle' {
    . $refs['bundler'].MainPath
    . (Join-Path $root 'packages\cli\bundle.ps1')
    $bound = ConvertTo-ArgumentTable $Rest
    exit (Invoke-CliBundle @bound)
  }
  'dev' {
    $watcher = Join-Path $root 'packages\cli\watch.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File $watcher @Rest
    exit $LASTEXITCODE
  }
  'test' {
    . $refs['test'].MainPath
    exit (Invoke-Test -Arguments $Rest)
  }
  default {
    Write-Fail ('unknown command: ' + $Command)
    Write-Note 'cli build | bundle | dev | test'
    exit 1
  }
}

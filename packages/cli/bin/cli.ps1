#Requires -Version 5.1
<#
  packages\cli\bin\cli.ps1 - the builder-cli command. Assemble the packages, then run one.

      builder-cli                  list what this tooling can do
      builder-cli build            build every target and write the release
      builder-cli bundle -All      build targets without packing (one target by -Entry)
      builder-cli bundle -Inspect  say which modules a bundle cannot inline
      builder-cli dev              watch the tree and restart the development copy

  Only the build pipeline is behind this command. The suite is builder-test, and client,
  assembly, bench and shot are plain scripts package.ini runs as files.

  It sits in the package the way vite's bin\vite.js does; run.ps1 at the repository root is
  the launcher that resolves the name for package.ini's command lines.

      bundler   the engine: resolve, treeshake, merge, render, verify, cs-part, cs-compile
                nothing in it knows what an "electron main process" is
      cli       the shapes and the loop: the electron presets in plugins\, the resolve step,
                build, and the watcher
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
$moduleBin = Join-Path $root 'packages\module\bin\module.ps1'

# packages\cli first: it carries the logger, the config reader and the command table, and every
# other package is imported on top of it
. (Use-Module '../index.ps1' $PSCommandPath)

# the other packages, loaded through the declaration in their own package.ini
$refs = @{}
foreach ($name in @('bundler', 'builder', 'test')) {
  $refs[$name] = Get-CliPackageRef $name
}

$wanted = $Command.ToLower()
if (-not $wanted -or @('help', '-h', '--help', '-?', '/?') -contains $wanted) {
  Write-Title 'builder-cli'
  Write-Host ''
  Write-Note 'usage: builder-cli <command> [args]'
  Write-Host ''
  $width = 8
  foreach ($pair in @(
      @('build', 'build every target, then stage and pack the release')
      @('release', 'build, then run the suite against the package and drop it when the suite fails')
      @('bundle', 'build one target or all of them; -Inspect lists what cannot be inlined')
      @('dev', 'watch the tree and restart the development copy')
    )) {
    Write-Pair ([string]$pair[0]) ([string]$pair[1]) $width
  }
  Write-Host ''
  Write-Note ('packages  ' + ((@($refs.Keys) | ForEach-Object { $_ + ' (' + (($refs[$_].Exports) -join ', ') + ')' }) -join '   '))
  exit 0
}

# every command below runs at the repository root, the same way `run` runs one
Set-Location -LiteralPath $root

switch ($wanted) {
  'build' {
    . (Use-Module 'bundler' $PSCommandPath)
    . (Use-Module 'builder' $PSCommandPath)
    . (Use-Module '../build.ps1' $PSCommandPath)
    $bound = ConvertTo-ArgumentTable $Rest
    exit (Invoke-CliBuild @bound).Code
  }
  'release' {
    # the two steps the release flow keeps apart: write the folder, then check the folder. Packing
    # never deletes its own output on a test failure - that decision belongs here.
    . (Use-Module 'bundler' $PSCommandPath)
    . (Use-Module 'builder' $PSCommandPath)
    . (Use-Module '../build.ps1' $PSCommandPath)
    . (Use-Module 'test' $PSCommandPath)
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
    . (Use-Module 'bundler' $PSCommandPath)
    . (Use-Module '../bundle.ps1' $PSCommandPath)
    $bound = ConvertTo-ArgumentTable $Rest
    exit (Invoke-CliBundle @bound)
  }
  'dev' {
    $watcher = Join-Path $root 'packages\cli\watch.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File $moduleBin $watcher @Rest
    exit $LASTEXITCODE
  }
  default {
    Write-Fail ('unknown command: ' + $Command)
    Write-Note 'builder-cli build | release | bundle | dev'
    exit 1
  }
}

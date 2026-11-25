# packages\cli\index.ps1 - the cli package's public surface, and the command runner.
#
# This package is the electron-vite half of the tooling: it reads the target file (cli.ini),
# builds every target through packages\bundler, and hands the result to packages\builder. It is
# also the runner the builder-cli binary starts, so the command table in package.ini and the two
# config files are read here and nowhere else.
#
# What is visible from outside is package.ini's Exports list and nothing else: the modules under
# utils\, config.ps1 and the command scripts stay behind this file.
$script:CliHome = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:CliHome) { throw 'cli: cannot locate the package folder' }
$script:PackagesRoot = Split-Path -Parent $script:CliHome
$script:RepoRoot = Split-Path -Parent $script:PackagesRoot

. (Join-Path $script:CliHome 'utils\console.ps1')
. (Join-Path $script:CliHome 'utils\ini.ps1')
. (Join-Path $script:CliHome 'utils\schema.ps1')

# the extension plugins this package brings: target shapes the config can name with Preset=. They
# are loaded here, at the package's own scope, so a config sees them all.
$pluginDir = Join-Path $script:CliHome 'plugins'
if (Test-Path -LiteralPath $pluginDir) {
  foreach ($pluginFile in @(Get-ChildItem -LiteralPath $pluginDir -File -Filter '*.ps1' | Sort-Object Name)) {
    . $pluginFile.FullName
  }
}

. (Join-Path $script:CliHome 'config.ps1')

function Get-CliHome { return $script:CliHome }
function Get-RepoRoot { return $script:RepoRoot }

# Load one of the packages beside this one: check what it declares and hand its module path
# back. The CALLER dot-sources it - a dot-source inside a function defines the package's
# functions in that function's scope, and PowerShell 5.1 loses them when it returns.
#
#     $ref = Get-CliPackageRef 'bundler'
#     . $ref.MainPath
function Get-CliPackageRef([string]$name) {
  $path = Join-Path $script:PackagesRoot ($name + '\package.ini')
  $pkg = Read-PackageFile $path
  foreach ($need in @($pkg.Requires -split ',')) {
    $one = $need.Trim()
    if (-not $one) { continue }
    $theirPath = Join-Path $script:PackagesRoot ($one + '\package.ini')
    if (-not (Test-Path -LiteralPath $theirPath)) { throw ($pkg.Name + ': Requires names no package: ' + $one) }
  }
  $allowed = New-Object System.Collections.Generic.List[string]
  foreach ($one in @($pkg.Exports -split ',')) {
    $exported = $one.Trim()
    if (-not $exported) { continue }
    $allowed.Add($exported)
  }
  return @{ Package = $pkg; Exports = $allowed.ToArray(); MainPath = $pkg.MainPath }
}

# ---------------------------------------------------------------- the command table
# package.ini is the npm script table: one Key=Value per cli command. A mistyped section or a
# command with no command line is a broken file, not "no such command".
$script:Pkg = $null
$script:PkgDoc = $null

function Read-CliPackageTable {
  if ($null -ne $script:Pkg) { return }
  $path = Join-Path $script:RepoRoot 'package.ini'
  if (-not (Test-Path -LiteralPath $path)) { throw ('missing: ' + $path) }
  $schemaPath = Join-Path $script:CliHome 'schema\root.ps1'
  $script:PkgDoc = Read-IniDoc ([IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8))
  $script:Pkg = $script:PkgDoc.Map
  $problems = @(Test-ToolConfigMap (Import-ToolSchema $schemaPath) $script:Pkg 'package.ini')
  if ($problems.Count -gt 0) { throw ($problems -join [Environment]::NewLine) }
}

function Get-PkgValue([string]$name) {
  Read-CliPackageTable
  if ($script:Pkg.ContainsKey('package.' + $name)) { return [string]$script:Pkg['package.' + $name] }
  if ($script:Pkg.ContainsKey($name)) { return [string]$script:Pkg[$name] }
  return ''
}

function Get-CommandOrder {
  Read-CliPackageTable
  $order = New-Object System.Collections.Generic.List[string]
  foreach ($k in @($script:PkgDoc.Keys)) {
    if ($k -like 'scripts.*') { $order.Add($k.Substring(8)) }
  }
  return $order.ToArray()
}

function Get-CommandLine([string]$name) {
  Read-CliPackageTable
  return [string]$script:Pkg['scripts.' + $name]
}

# The commands the packages register: Bin= in a package.ini, the way package.json's bin names an
# executable. A script line may start with one of these names, so the line reads "builder-cli
# build" instead of a path to a file - npm puts node_modules\.bin on PATH for the same reason.
# A line may also name the interpreter and the file, as "node tools/shot.js" does.
$script:PkgBins = $null

function Get-PackageBins {
  if ($null -ne $script:PkgBins) { return $script:PkgBins }
  $bins = @{}
  foreach ($dir in @(Get-ChildItem -LiteralPath $script:PackagesRoot -Directory -ErrorAction SilentlyContinue)) {
    $file = Join-Path $dir.FullName 'package.ini'
    if (-not (Test-Path -LiteralPath $file)) { continue }
    $pkg = Read-PackageFile $file
    if (-not $pkg.Bin) { continue }
    # Bin= is "name=path" or just "path": npm's bin names an executable that may differ from the
    # package name, the way electron-vite ships "electron-vite" as the command of its own package
    $binName = [string]$pkg.Name
    $binRel = [string]$pkg.Bin
    $eq = $binRel.IndexOf('=')
    if ($eq -gt 0) {
      $binName = $binRel.Substring(0, $eq).Trim()
      $binRel = $binRel.Substring($eq + 1).Trim()
    }
    $path = Join-Path $dir.FullName ($binRel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path)) { throw ($pkg.Name + ': Bin= names no file: ' + $binRel) }
    $bins[$binName.ToLowerInvariant()] = $path
  }
  $script:PkgBins = $bins
  return $bins
}

function Show-Commands {
  $name = Get-PkgValue 'name'
  $version = Get-PkgValue 'version'
  $order = @(Get-CommandOrder)
  $title = $name
  if ($version) { $title = $title + '@' + $version }
  if ($title) { Write-Title $title }
  Write-Host ''
  if ($order.Count -eq 0) {
    Write-Note 'no scripts.<name>= lines in package.ini'
    return
  }
  Write-Note 'usage: run <command> [args]'
  Write-Host ''
  $width = 8
  foreach ($one in $order) { if ($one.Length -gt $width) { $width = $one.Length } }
  foreach ($one in $order) {
    Write-Pair $one.ToLowerInvariant() (Get-CommandLine $one) $width
  }
}

# A mistyped command is worth one line: the closest declared name is almost always the one that
# was meant. Two shared leading characters is a typo; one is noise.
function Get-CommandSuggestion([string]$typed) {
  $best = ''
  $bestScore = 0
  foreach ($name in @(Get-CommandOrder)) {
    $lower = $name.ToLowerInvariant()
    if ($lower -eq $typed) { return $lower }
    $score = 0
    $n = [Math]::Min($lower.Length, $typed.Length)
    for ($i = 0; $i -lt $n; $i++) {
      if ($lower[$i] -ne $typed[$i]) { break }
      $score++
    }
    if ($score -gt $bestScore) { $bestScore = $score; $best = $lower }
  }
  if ($bestScore -ge 2) { return $best }
  return ''
}

# Run one command of the table. The script gets a PowerShell of its own, and the two lines npm
# prints before a script runs say what is about to happen and what will actually be executed.
function Invoke-CliCommand {
  param(
    [string]$Command = '',
    [string[]]$Rest = @()
  )
  $wanted = $Command.ToLower()
  if (-not $wanted -or @('help', '-h', '--help', '-?', '/?') -contains $wanted) {
    Show-Commands
    return 0
  }
  $line = Get-CommandLine $wanted
  if (-not $line) {
    Write-Fail ('unknown command: ' + $Command)
    $suggest = Get-CommandSuggestion $wanted
    if ($suggest) { Write-Note ('did you mean ' + $suggest + '?') }
    Write-Host ''
    Show-Commands
    return 1
  }
  if ($Rest -and $Rest.Count -gt 0) { $line = $line + ' ' + ($Rest -join ' ') }
  $shown = $wanted
  if ($Rest -and $Rest.Count -gt 0) { $shown = $shown + ' ' + ($Rest -join ' ') }
  $pkgName = Get-PkgValue 'name'
  $pkgVersion = Get-PkgValue 'version'
  $title = $pkgName
  if ($pkgVersion) { $title = $title + '@' + $pkgVersion }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  # A quiet flag belongs to the script, which receives it on its own command line; the two lines
  # below belong to the runner and follow the same flag.
  foreach ($a in @($Rest)) {
    $flag = ([string]$a).ToLowerInvariant()
    if ($flag -eq '-q' -or $flag -eq '-quiet' -or $flag -eq '--quiet') { Set-LogLevel 'warn' }
    elseif ($flag -eq '-silent' -or $flag -eq '--silent') { Set-LogLevel 'silent' }
  }
  # the line may start with a tool; the tool is a file a package registered in Bin=. Resolving the
  # name here is the runner's half of npm: npm puts node_modules\.bin on PATH, this hands the file
  # to PowerShell instead. A line that starts with anything else runs as written.
  $binPath = ''
  $binArgs = @()
  $tokens = @($line.Trim() -split '\s+')
  if ($tokens.Count -gt 0) {
    $head = ([string]$tokens[0]).Trim('"', "'")
    $bins = Get-PackageBins
    if ($bins.ContainsKey($head.ToLowerInvariant())) {
      $binPath = $bins[$head.ToLowerInvariant()]
      if ($tokens.Count -gt 1) { $binArgs = @($tokens[1..($tokens.Count - 1)]) }
    }
  }
  Write-Command $title $shown $line
  $global:LASTEXITCODE = 0
  Set-Location -LiteralPath $script:RepoRoot
  # the output goes straight to the host: a function hands its caller whatever it printed, and
  # this one has to hand back the exit code only
  if ($binPath) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File $binPath @binArgs | Out-Host
  } else {
    Invoke-Expression $line | Out-Host
  }
  $sw.Stop()
  $code = $LASTEXITCODE
  if ($null -eq $code) { $code = 0 }
  if ($code -ne 0) {
    Write-Fail ($shown + ' exited with code ' + $code + ' after ' + (Format-Duration $sw.Elapsed.TotalMilliseconds))
  }
  return $code
}

# ---------------------------------------------------------------- resolve, build, watch
# The three entry points the command scripts call. Each one resolves the same config, so a run of
# one never disagrees with a run of the other about what a target is.

function Resolve-CliSession {
  param([string]$ConfigFile = '')
  return Resolve-CliConfig -Root $script:RepoRoot -ConfigFile $ConfigFile
}

# "-Entry renderer -All" as a table a function can be splatted with: an array of words cannot be
# splatted onto named parameters, and every command below takes named ones
function ConvertTo-ArgumentTable([string[]]$Arguments) {
  $table = @{}
  $i = 0
  while ($i -lt @($Arguments).Count) {
    $a = ([string]$Arguments[$i]).Trim()
    $i++
    if (-not $a.StartsWith('-')) { continue }
    $name = $a.Substring(1)
    if ($i -lt @($Arguments).Count) {
      $next = [string]$Arguments[$i]
      if (-not $next.StartsWith('-')) { $table[$name] = $next; $i++; continue }
    }
    $table[$name] = $true
  }
  return $table
}

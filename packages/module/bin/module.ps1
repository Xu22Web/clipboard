#Requires -Version 5.1
<#
  packages\module\bin\module.ps1 - run one script with import and export statements live.

      module <entry.ps1> [args]    run the entry, the statement forms in effect
      module -Check <entry.ps1>    report what the entry would break, run nothing
      module -List <entry.ps1>     print the order the entry's modules load in

  An entry states its edges in code, the way a JavaScript file does:

      . (Use-Module './b' $PSCommandPath)
      $sum = Add-Numbers 3 4
      'sum = ' + $sum

  and the file it names defines and declares what it offers:

      function Add-Numbers($x, $y) { $x + $y }
      Export-Function Add-Numbers

  Two things make that work instead of being a comment. A dot-source runs the file in the scope
  that writes it, so `Use-Module` only has to answer a path and b's function lands beside a's
  code. And the two statement names are real functions for the length of a run, defined here in
  the scope the entry is started from: `Use-Module` resolves its argument, `Export-Function`
  declares. The declarations are also read from the syntax tree before anything runs, so a
  missing module or an export naming nothing is reported instead of half-executed.

  Everything after the entry belongs to the entry, including arguments that start with "-".
#>

$ErrorActionPreference = 'Stop'
# bin -> module -> packages -> the repository
$packageHome = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$moduleMain = Join-Path $packageHome 'index.ps1'
if (-not (Test-Path -LiteralPath $moduleMain)) {
  Write-Host ('[x] missing: ' + $moduleMain)
  exit 1
}
. $moduleMain

# ---- the command line: switches up to the entry, the rest handed over untouched --------------
$argv = @($args)
$check = $false
$list = $false
$noCheck = $false
$entry = ''
$rest = New-Object System.Collections.Generic.List[string]
$i = 0
while ($i -lt $argv.Count) {
  $one = [string]$argv[$i]
  $i++
  if (-not $entry) {
    if ($one -eq '--') {
      if ($i -lt $argv.Count) { $entry = [string]$argv[$i]; $i++ }
      continue
    }
    if ($one -eq '-Check' -or $one -eq '--check') { $check = $true; continue }
    if ($one -eq '-List' -or $one -eq '--list') { $list = $true; continue }
    if ($one -eq '-NoCheck' -or $one -eq '--no-check') { $noCheck = $true; continue }
    if ($one -eq '-h' -or $one -eq '-Help' -or $one -eq '--help') {
      Write-Host 'module <entry.ps1> [args]  run the entry with Use-Module / Export-Function live'
      Write-Host 'module -Check <entry.ps1>  report what the entry would break'
      Write-Host 'module -List <entry.ps1>   print the load order'
      exit 0
    }
    if ($one.StartsWith('-') -and $one.Length -gt 1) {
      Write-Host ('[x] unknown switch: ' + $one)
      exit 2
    }
    $entry = $one
    continue
  }
  $rest.Add($one)
}

if (-not $entry) {
  Write-Host 'usage: module <entry.ps1> [args]'
  exit 2
}
$entryPath = $entry
if (-not [IO.Path]::IsPathRooted($entryPath)) { $entryPath = Join-Path (Get-Location).Path $entryPath }
if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
  Write-Host ('[x] no such entry: ' + $entry)
  exit 2
}
$entryPath = [IO.Path]::GetFullPath($entryPath)

# The root answers the package and id specifier forms. It is the OUTERMOST folder that has a
# package.ini on the way up: every package declares one of its own, and stopping at the first
# would answer 'bundler' with packages\cli\packages\bundler. An entry outside a repository has
# none, and its relative imports still resolve.
$root = ''
$probe = Split-Path -Parent $entryPath
while ($probe) {
  if (Test-Path -LiteralPath (Join-Path $probe 'package.ini')) { $root = $probe }
  $up = Split-Path -Parent $probe
  if (-not $up -or $up -eq $probe) { break }
  $probe = $up
}

# ---- what the entry would report before a line of it runs -----------------------------------
$problems = @(Get-ModuleDiagnostics $entryPath $root)
if ($list) {
  $n = 0
  $entryDir = Split-Path -Parent $entryPath
  foreach ($file in @((Get-ModuleGraph $entryPath $root).Order)) {
    $n++
    $shown = [string]$file
    if ($shown.StartsWith($entryDir, [StringComparison]::OrdinalIgnoreCase)) {
      $shown = $shown.Substring($entryDir.Length).TrimStart([char]'/', [char]92)
    }
    Write-Host (('{0}  {1}' -f $n, $shown))
  }
  if ($problems.Count -gt 0) { Write-Host ('[!] ' + $problems.Count.ToString() + ' problem(s): ' + ($problems -join '; ')) }
  exit 0
}
if ($check -or (-not $noCheck)) {
  foreach ($one in $problems) { Write-Host ('[x] ' + $one) }
  if ($check) {
    if ($problems.Count -eq 0) { Write-Host ('[ok] ' + (Split-Path -Leaf $entryPath)) }
    exit $(if ($problems.Count -eq 0) { 0 } else { 1 })
  }
}

# ---- the two statements, live for the length of this run ------------------------------------
# host.ps1 defines Use-Module and Export-Function in this script's own scope, which is what the
# entry sees: a dot-source runs a file in the scope that writes the line, so an import only needs
# a path back.
$ModuleHostRoot = $root
. (Join-Path $packageHome 'lib\host.ps1')

# ---- the entry runs here ----------------------------------------------------------------------
# An argument list cannot be handed over as an array: splatting an array binds by position, so
# '-Part module' arrives as one name and one stray word. The line is rebuilt instead, a switch left
# bare and everything else quoted, which is what the command line already meant.
#
# The entry runs in this script's own scope, the way a dot-source would. For a tool that is what
# makes it a single layer - the command file, the packages it imports and its $script: state are
# one process. It is not what every script wants: a file that keeps its own $script: records (the
# test parts, tests\run.ps1) must run as a script file of its own, and those bootstrap the module
# layer from their own first line instead of being started from here.
function Format-ModuleArgument([string]$one) {
  if ($one -match '^--?[A-Za-z]') { return $one }
  if ($one -eq '') { return "''" }
  if ($one -match "[^\w./\\:=+-]") { return "'" + ($one -replace "'", "''") + "'" }
  return $one
}

$commandLine = '& ' + "'" + ($entryPath -replace "'", "''") + "'"
foreach ($one in $rest) { $commandLine += ' ' + (Format-ModuleArgument ([string]$one)) }

try {
  Invoke-Expression $commandLine
} catch {
  Write-Host ('[x] ' + $_.Exception.Message)
  Write-Host ('    at ' + (Split-Path -Leaf $entryPath))
  Remove-Item -LiteralPath $ModuleStub -Force -ErrorAction SilentlyContinue
  exit 1
}
Remove-Item -LiteralPath $ModuleStub -Force -ErrorAction SilentlyContinue
exit 0

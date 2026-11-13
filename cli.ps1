#Requires -Version 5.1
<#
  cli.ps1 - run a command declared in package.ini.

      cli                 list the commands
      cli <command> ...   run scripts.<command>, passing the remaining arguments on

  cli.cmd and cli (Git Bash / MSYS) call this file; all three read the same package.ini.
  The working directory is set to the project root first, so the command lines in
  package.ini may use paths relative to that folder.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = '',
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
Set-Location -LiteralPath $root
$pkgPath = Join-Path $root 'package.ini'
$tools = Join-Path $root 'tools'

# the logger is shared with every tool script, so a command prints its steps and this file
# prints its own lines the same way
. (Join-Path $tools 'utils\console.ps1')

if (-not (Test-Path -LiteralPath $pkgPath)) {
  Write-Fail ('missing: ' + $pkgPath)
  exit 1
}
foreach ($tool in @('utils\ini.ps1', 'utils\schema.ps1', 'schema\package.ps1')) {
  $toolPath = Join-Path $tools $tool
  if (-not (Test-Path -LiteralPath $toolPath)) {
    Write-Fail ('missing: ' + $toolPath)
    exit 1
  }
}
# the tooling has its own ini layer (tools\utils\ini.ps1, the same rules as the program's) and
# its own schemas (tools\schema), so no tool script loads a module out of src\
. (Join-Path $tools 'utils\ini.ps1')
. (Join-Path $tools 'utils\schema.ps1')
$pkgDoc = Read-IniDoc ([IO.File]::ReadAllLines($pkgPath, [Text.Encoding]::UTF8))
$pkg = $pkgDoc.Map
# package.ini describes the tooling itself, so it is checked before a command runs: a mistyped
# section or a command with no command line is a broken file, not "no such command"
$pkgProblems = @(Test-ToolConfigMap (Import-ToolSchema (Join-Path $tools 'schema\package.ps1')) $pkg 'package.ini')
if ($pkgProblems.Count -gt 0) {
  foreach ($p in $pkgProblems) { Write-Fail $p }
  exit 1
}
$order = New-Object System.Collections.Generic.List[string]
foreach ($k in @($pkgDoc.Keys)) {
  if ($k -like 'scripts.*') { $order.Add($k.Substring(8)) }
}

# a key may be written inside its section or with the dotted name at the top level
function PkgValue([string]$name) {
  if ($pkg.ContainsKey('package.' + $name)) { return [string]$pkg['package.' + $name] }
  if ($pkg.ContainsKey($name)) { return [string]$pkg[$name] }
  return ''
}$pkgName = PkgValue 'name'
$pkgVersion = PkgValue 'version'

function Show-Commands {
  $title = $pkgName
  if ($pkgVersion) { $title = $title + '@' + $pkgVersion }
  if ($title) { Write-Title $title }
  Write-Host ''
  if ($order.Count -eq 0) {
    Write-Note 'no scripts.<name>= lines in package.ini'
    return
  }
  Write-Note 'usage: cli <command> [args]'
  Write-Host ''
  # one width for the whole list, so the command lines start in the same column whatever the
  # longest name is; a name is typed in any case and shown in lower case
  $width = 8
  foreach ($name in $order) {
    if ($name.Length -gt $width) { $width = $name.Length }
  }
  foreach ($name in $order) {
    Write-Pair $name.ToLowerInvariant() ([string]$pkg['scripts.' + $name]) $width
  }
}

# A mistyped command is worth one line: the closest declared name is almost always the one that
# was meant, and the list below is long enough that finding it by eye is not free. Two shared
# leading characters is a typo; one is noise.
function Get-CommandSuggestion([string]$typed) {
  $best = ''
  $bestScore = 0
  foreach ($name in $order) {
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

$wanted = $Command.ToLower()
if (-not $wanted -or @('help', '-h', '--help', '-?', '/?') -contains $wanted) {
  Show-Commands
  exit 0
}

$line = [string]$pkg['scripts.' + $wanted]
if (-not $line) {
  Write-Fail ('unknown command: ' + $Command)
  $suggest = Get-CommandSuggestion $wanted
  if ($suggest) { Write-Note ('did you mean ' + $suggest + '?') }
  Write-Host ''
  Show-Commands
  exit 1
}

if ($Rest -and $Rest.Count -gt 0) { $line = $line + ' ' + ($Rest -join ' ') }
# The script gets a PowerShell of its own, and that start plus its first output is a second
# or two of blank terminal. The two lines npm prints before a script runs say what is about to
# happen and what will actually be executed, so the wait is never unexplained; a non-zero exit
# gets a closing line as well, because the script's own output may not make it obvious.
$shown = $wanted
if ($Rest -and $Rest.Count -gt 0) { $shown = $shown + ' ' + ($Rest -join ' ') }
$title = $pkgName
if ($pkgVersion) { $title = $title + '@' + $pkgVersion }
$sw = [Diagnostics.Stopwatch]::StartNew()
# The same two lines npm prints, then a blank line: the header stays quiet and the colour only
# marks the command name, so what the script prints is what the eye lands on.
Write-Command $title $shown $line
$global:LASTEXITCODE = 0
Invoke-Expression $line
$sw.Stop()
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }
if ($code -ne 0) {
  Write-Fail ($shown + ' exited with code ' + $code + ' after ' + (Format-Duration $sw.Elapsed.TotalMilliseconds))
}
exit $code

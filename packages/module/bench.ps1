#Requires -Version 5.1
<#
  packages\module\bench.ps1 - time the module layer's resolution and graph reading.

      run modulebench                the table
      run modulebench -Quick         a small shape, for the edit-run loop
      run modulebench -Json          the same numbers as JSON
      run modulebench -Out base.json JSON to a file, for a before/after diff
      run modulebench -Depth 80      a longer single chain
      run modulebench -Width 8 -FanDepth 6   a wider, deeper fan

  Two shapes are measured, because they cost different things:

    single chain, short   one import per file, one function per file. The cost is per module:
                          a resolver call, a parse, a node in the graph.
    single chain, long    the same chain, with -Functions functions in every file. The graph is
                          the same size, so anything this adds is the parser reading function
                          bodies it never runs.
    mixed fan            layers of modules that each import the whole next layer - the diamond
                          shape a real package has - with short and long files side by side.

  Every file is generated under %TEMP%, so the repository is never touched and the numbers do not
  depend on what the source tree happens to look like today. The module layer is dot-sourced here
  rather than started through the launcher: this file is a script of its own, and the measurement
  should include nothing but the calls below.
#>
[CmdletBinding()]
param(
  # files in the single chain, and layers in the fan
  [int]$Depth = 40,
  [int]$Width = 6,
  [int]$FanDepth = 5,
  # functions in a "long" file; a "short" file has one
  [int]$Functions = 80,
  # how many times one resolver call is repeated
  [int]$Resolves = 2000,
  # best of this many runs per row
  [int]$Runs = 5,
  # a small shape at two runs: the row that moved, without the wait
  [switch]$Quick,
  [switch]$Json,
  [string]$Out = ''
)

# -Quick only fills in what the caller left at its default, so -Quick -Depth 80 is a longer quick run
if ($Quick) {
  if ($Depth -eq 40) { $Depth = 20 }
  if ($Width -eq 6) { $Width = 4 }
  if ($FanDepth -eq 5) { $FanDepth = 3 }
  if ($Functions -eq 80) { $Functions = 20 }
  if ($Runs -eq 5) { $Runs = 2 }
  if ($Resolves -eq 2000) { $Resolves = 500 }
}

$ErrorActionPreference = 'Stop'
$moduleHome = $PSScriptRoot
$moduleMain = Join-Path $moduleHome 'index.ps1'
if (-not (Test-Path -LiteralPath $moduleMain)) {
  Write-Host ('[x] missing: ' + $moduleMain)
  exit 1
}
. $moduleMain
$repoRoot = Split-Path -Parent (Split-Path -Parent $moduleHome)

# the best of several runs: one untimed call first, because the first call into a function pays
# the JIT, and counting it would report the compiler rather than the path
function Get-Best([scriptblock]$body, [int]$runs = 5) {
  & $body
  $best = [double]::MaxValue
  for ($i = 0; $i -lt $runs; $i++) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $body
    $sw.Stop()
    if ($sw.Elapsed.TotalMilliseconds -lt $best) { $best = $sw.Elapsed.TotalMilliseconds }
  }
  return [Math]::Round($best, 2)
}

# One generated module: the imports it writes at its top, then the functions it defines. A long
# file is the same shape with more bodies - which is exactly what the parser has to read.
function New-ModuleFile([string]$path, [string[]]$imports, [int]$functions) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($one in @($imports)) {
    [void]$sb.AppendLine(". (Use-Module '" + $one + "' `$PSCommandPath)")
  }
  for ($i = 0; $i -lt $functions; $i++) {
    [void]$sb.AppendLine('function Get-Value' + $i + ' {')
    [void]$sb.AppendLine('  param([int]$a, [int]$b)')
    [void]$sb.AppendLine('  $sum = $a + $b + ' + $i)
    [void]$sb.AppendLine('  if ($sum -gt 100) { return $sum }')
    [void]$sb.AppendLine('  return ($sum * 2)')
    [void]$sb.AppendLine('}')
  }
  [IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
  $text = $sb.ToString()
  return @{ Path = $path; Lines = ([regex]::Matches($text, "`n")).Count }
}

$stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('module-bench-' + $stamp)
$rows = [ordered]@{}
$sizes = [ordered]@{}
try {
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null

  # ---------------------------------------------------------------- single chain, short files
  $shortDir = Join-Path $tmp 'chain-short'
  New-Item -ItemType Directory -Path $shortDir -Force | Out-Null
  $shortLines = 0
  for ($i = $Depth - 1; $i -ge 0; $i--) {
    $imports = @()
    if ($i -lt ($Depth - 1)) { $imports = @('./m' + ($i + 1) + '.ps1') }
    $one = New-ModuleFile (Join-Path $shortDir ('m' + $i + '.ps1')) $imports 1
    $shortLines += $one.Lines
  }
  $shortEntry = Join-Path $shortDir 'm0.ps1'
  $sizes['chain short'] = @{ Files = $Depth; Lines = $shortLines }

  # ---------------------------------------------------------------- single chain, long files
  $longDir = Join-Path $tmp 'chain-long'
  New-Item -ItemType Directory -Path $longDir -Force | Out-Null
  $longLines = 0
  for ($i = $Depth - 1; $i -ge 0; $i--) {
    $imports = @()
    if ($i -lt ($Depth - 1)) { $imports = @('./m' + ($i + 1) + '.ps1') }
    $one = New-ModuleFile (Join-Path $longDir ('m' + $i + '.ps1')) $imports $Functions
    $longLines += $one.Lines
  }
  $longEntry = Join-Path $longDir 'm0.ps1'
  $sizes['chain long'] = @{ Files = $Depth; Lines = $longLines }

  # ---------------------------------------------------------------- mixed fan
  # every module of a layer imports the whole next layer, so one file is reached from several
  # places (a diamond); odd files carry -Functions bodies, even ones carry a single body
  $fanDir = Join-Path $tmp 'fan'
  New-Item -ItemType Directory -Path $fanDir -Force | Out-Null
  $fanLines = 0
  $fanFiles = 0
  for ($layer = $FanDepth - 1; $layer -ge 0; $layer--) {
    for ($n = 0; $n -lt $Width; $n++) {
      $imports = @()
      if ($layer -lt ($FanDepth - 1)) {
        for ($c = 0; $c -lt $Width; $c++) { $imports += ('./l' + ($layer + 1) + '-n' + $c + '.ps1') }
      }
      $count = if ($n % 2 -eq 0) { 1 } else { $Functions }
      $one = New-ModuleFile (Join-Path $fanDir ('l' + $layer + '-n' + $n + '.ps1')) $imports $count
      $fanLines += $one.Lines
      $fanFiles++
    }
  }
  $fanEntry = Join-Path $fanDir 'l0-n0.ps1'
  $sizes['mixed fan'] = @{ Files = $fanFiles; Lines = $fanLines }

  # ---------------------------------------------------------------- the measurements
  # one resolver call, repeated: the per-import cost with nothing else in the way
  $caller = $shortEntry
  $probeSpec = './m' + [Math]::Max(1, [int]($Depth / 2)) + '.ps1'
  $rows['resolve ' + $Resolves + ' specs'] = Get-Best {
    for ($i = 0; $i -lt $Resolves; $i++) { [void](Resolve-ModuleSpecifier $probeSpec $caller $repoRoot) }
  } $Runs

  $rows['graph chain short'] = Get-Best { [void](Get-ModuleGraph $shortEntry $repoRoot) } $Runs
  $rows['graph chain long'] = Get-Best { [void](Get-ModuleGraph $longEntry $repoRoot) } $Runs
  $rows['graph mixed fan'] = Get-Best { [void](Get-ModuleGraph $fanEntry $repoRoot) } $Runs

  # order, cold: the graph is built from scratch every time (-NoCache)
  $rows['order chain short (cold)'] = Get-Best { [void](Get-ModuleOrder $shortEntry $repoRoot -NoCache) } $Runs
  # order, warm: the entry's write time is unchanged, so the cached graph answers
  [void](Get-ModuleOrder $shortEntry $repoRoot -NoCache)
  [void](Get-ModuleOrder $shortEntry $repoRoot)
  $rows['order chain short (warm)'] = Get-Best { [void](Get-ModuleOrder $shortEntry $repoRoot) } $Runs
  $rows['order mixed fan (cold)'] = Get-Best { [void](Get-ModuleOrder $fanEntry $repoRoot -NoCache) } $Runs

  # diagnostics reads the syntax tree a second time for every module (to check the names an
  # Export-Function line claims), so it is the row a long file is expected to move most
  $rows['diagnostics chain short'] = Get-Best { [void](Get-ModuleDiagnostics $shortEntry $repoRoot) } $Runs
  $rows['diagnostics chain long'] = Get-Best { [void](Get-ModuleDiagnostics $longEntry $repoRoot) } $Runs
  $rows['diagnostics mixed fan'] = Get-Best { [void](Get-ModuleDiagnostics $fanEntry $repoRoot) } $Runs

  $report = [ordered]@{
    measured = $stamp
    shape    = [ordered]@{
      depth     = $Depth
      width     = $Width
      fanDepth  = $FanDepth
      functions = $Functions
      resolves  = $Resolves
      runs      = $Runs
    }
    sizes    = $sizes
    milliseconds = $rows
  }

  if ($Json) {
    Write-Output ($report | ConvertTo-Json -Depth 6)
  } else {
    Write-Host ('module bench   depth=' + $Depth + ' width=' + $Width + ' fan=' + $FanDepth + ' functions=' + $Functions + '   ' + $stamp)
    Write-Host ''
    Write-Host ('  {0,-26} {1,6} {2,8} {3,8} {4,9}' -f 'path', 'files', 'lines', 'ms', 'ms/file')
    foreach ($k in @($report.sizes.Keys)) {
      $size = $report.sizes[$k]
      $ms = $rows['graph ' + $k]
      $per = 0
      if ($size.Files -gt 0 -and $null -ne $ms) { $per = [Math]::Round($ms / $size.Files, 3) }
      Write-Host ('  {0,-26} {1,6} {2,8} {3,8} {4,9}' -f ('graph ' + $k), $size.Files, $size.Lines, $ms, $per)
    }
    Write-Host ''
    foreach ($k in @($rows.Keys)) {
      if ($k -like 'graph *') { continue }
      Write-Host ('  {0,-26} {1,8:N2} ms' -f $k, $rows[$k])
    }
  }
  if ($Out) {
    $jsonText = $report | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($Out, $jsonText + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    if (-not $Json) { Write-Host ('  written: ' + $Out) }
  }
} catch {
  Write-Host ('[x] ' + $_.Exception.Message)
  exit 1
} finally {
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
exit 0

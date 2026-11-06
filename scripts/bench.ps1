#Requires -Version 5.1
<#
  scripts\bench.ps1 - time the paths that run on every capture, save, and keystroke.

      cli bench                     the table
      cli bench -Json               the same numbers as JSON
      cli bench -Out base.json      JSON to a file, for a before/after diff
      cli bench -Records 600        a bigger store

  Everything runs against a throwaway copy under %TEMP%, with its own data folder, so the
  real history is never touched and a running resident does not interfere. The panel is not
  measured here: opening it needs a desktop, so those numbers come from a manual probe.
#>
[CmdletBinding()]
param(
  [switch]$Json,
  [int]$Records = 300,
  [int]$Media = 50,
  [int]$MaxItems = 0,
  [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$source = Join-Path $root 'src'
if (-not (Test-Path -LiteralPath (Join-Path $source 'clipboard.ps1'))) {
  Write-Host ('[x] missing: ' + (Join-Path $source 'clipboard.ps1'))
  exit 1
}

$stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('clipboard-bench-' + $stamp)
$sandboxSrc = Join-Path $sandbox 'src'
$sandboxData = Join-Path $sandbox 'data'
$fail = $false
try {
  New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
  New-Item -ItemType Directory -Path $sandboxData -Force | Out-Null
  # the folder itself, so the copy lands as <sandbox>\src
  Copy-Item -LiteralPath $source -Destination $sandbox -Recurse -Force
  # the development build reads its version from build.ini one level up
  $buildIni = Join-Path $root 'build.ini'
  if (Test-Path -LiteralPath $buildIni) { Copy-Item -LiteralPath $buildIni -Destination (Join-Path $sandbox 'build.ini') -Force }
  # a data folder of its own: the history, media and blobs of this run live here
  $ini = 'DataDir=' + $sandboxData
  [IO.File]::WriteAllText((Join-Path $sandboxSrc 'clipboard.ini'), $ini + "`r`n", (New-Object Text.UTF8Encoding $false))

  # The measurement itself has to run in its own process: the modules are dot-sourced into
  # one scope, and a fresh scope is the only honest way to time the parse.
  $entry = Join-Path $sandboxSrc 'clipboard.ps1'
  $body = @'
$ErrorActionPreference = 'Stop'
. '__ENTRY__' -Library
# One untimed run first: the first call into a function pays the JIT, and counting it would
# report the compiler rather than the path. The answer is then the best of several runs.
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
# a store shaped like a real one: text rows, plus picture rows so the media folder is not
# empty and dropping the reclaim scans is worth something. The seed is written in one save:
# building it with Add-Item would measure the growth of the store, not the steady state.
if (__MAX__ -gt 0) { $script:MaxItems = __MAX__ } else { $script:MaxItems = (__RECORDS__ + __MEDIA__ + 64) }
$seed = New-Object System.Collections.Generic.List[object]
$base = Get-Epoch
for ($i = 0; $i -lt __RECORDS__; $i++) { $seed.Add((New-Record ('seed row ' + $i + ' ' + ('z' * 60)) ($base - $i) '')) }
for ($i = 0; $i -lt __MEDIA__; $i++) {
  $chunk = [Text.Encoding]::ASCII.GetBytes('picture-' + $i)
  $pay = New-ImagePayload $chunk 1 1 'PNG'
  [void](Write-ImageMedia $pay $chunk)
  $seed.Add((New-Record $pay ($base - $i) ''))
}
Save-Records $seed.ToArray()
$script:RecCache = $null
$small = ('x' * 2000)
$big = ('y' * 200000)
# every run has to capture a payload the store has not seen, or it would be measuring the
# "this is already on top" shortcut instead of a real capture
$out = [ordered]@{}
$out.capture2k = Get-Best { Add-Item ($small + [Guid]::NewGuid().ToString('N')) } 8
$out.capture200k = Get-Best { Add-Item ($big + [Guid]::NewGuid().ToString('N')) } 5
$out.save = Get-Best { Save-Records @(Get-Records) } 5
$out.read = Get-Best { $script:RecCache = $null; [void](Get-Records) } 5
$out.filter = Get-Best { [void](Select-QueryRows @(Get-Records) @('seed')) } 8
$out.records = @(Get-Records).Count
$out.media = @(Get-ChildItem -LiteralPath (Get-MediaDir) -Filter '*.png' -ErrorAction SilentlyContinue).Count
foreach ($k in @($out.Keys)) { Write-Output ([string]$k + '=' + [string]$out[$k]) }
'@
  $body = $body.Replace('__ENTRY__', $entry).Replace('__RECORDS__', [string]$Records).Replace('__MEDIA__', [string]$Media).Replace('__MAX__', [string]$MaxItems)
  # the measurement runs as a file of its own: dot-sourcing the entry needs a script path,
  # which a command string does not have
  $inner = Join-Path $sandbox 'bench-inner.ps1'
  [IO.File]::WriteAllText($inner, $body, (New-Object Text.UTF8Encoding $false))
  # a failing child writes to stderr, and with Stop in force that would look like an error here
  $ErrorActionPreference = 'Continue'
  $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File $inner 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  if ($code -ne 0) {
    Write-Host (($raw | Out-String).Trim())
    throw ('the measurement run failed (exit ' + $code + ')')
  }
  $values = [ordered]@{}
  foreach ($line in @($raw)) {
    $s = [string]$line
    if ($s -match '^([a-z0-9]+)=(-?\d+(\.\d+)?)$') { $values[$Matches[1]] = [double]$Matches[2] }
  }
  foreach ($need in @('capture2k', 'capture200k', 'save', 'read', 'filter')) {
    if (-not $values.Contains($need)) { throw ('missing measurement: ' + $need) }
  }
  # a CLI start is its own cost: the module parse happens before the first line of output
  $cliEntry = $entry
  $cold = @()
  foreach ($verb in @('status', 'list')) {
    $best = [double]::MaxValue
    for ($i = 0; $i -lt 3; $i++) {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File $cliEntry $verb | Out-Null
      $sw.Stop()
      if ($sw.Elapsed.TotalMilliseconds -lt $best) { $best = $sw.Elapsed.TotalMilliseconds }
    }
    $cold += [Math]::Round($best, 1)
  }
  $values['cli.status'] = $cold[0]
  $values['cli.list'] = $cold[1]

  # which build was measured: package.ini owns the version
  $version = ''
  foreach ($line in @(Get-Content -LiteralPath (Join-Path $root 'package.ini') -ErrorAction SilentlyContinue)) {
    if ($line -match '^\s*Version\s*=\s*(.+)$') { $version = $Matches[1].Trim(); break }
  }

  $report = [ordered]@{
    version    = $version
    records    = [int]$values['records']
    media      = [int]$values['media']
    measured   = $stamp
    milliseconds = [ordered]@{
      'cli status (cold)'    = $values['cli.status']
      'cli list (cold)'      = $values['cli.list']
      'capture 2 KB text'    = $values['capture2k']
      'capture 200 KB text'  = $values['capture200k']
      'save the store'       = $values['save']
      'parse the store'      = $values['read']
      'filter one token'     = $values['filter']
    }
  }

  if ($Json) {
    $text = $report | ConvertTo-Json -Depth 4
  } else {
    Write-Host ('clipboard bench   records=' + $report.records + '   media=' + $report.media + '   ' + $stamp)
    Write-Host ''
    Write-Host ('  {0,-22} {1,8}' -f 'path', 'ms')
    foreach ($k in @($report.milliseconds.Keys)) {
      Write-Host ('  {0,-22} {1,8:N1}' -f $k, $report.milliseconds[$k])
    }
    $text = ''
  }
  if ($text) { Write-Output $text }
  if ($Out) {
    $jsonText = $report | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($Out, $jsonText + "`r`n", (New-Object Text.UTF8Encoding $false))
    if (-not $Json) { Write-Host ('' + '  written: ' + $Out) }
  }
} catch {
  Write-Host ('[x] ' + $_.Exception.Message)
  $fail = $true
} finally {
  if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($fail) { exit 1 }
exit 0

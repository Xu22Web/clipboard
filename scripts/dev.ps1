#Requires -Version 5.1
<#
  scripts\dev.ps1 - run the development copy from src\.

      cli dev           start the resident, restart it whenever a watched file changes

  "dev" always watches what the program reads - the entry point, the modules it loads
  from lib\ and utils\, the theme files, the plugins and package.ini (the version) - and
  there is no second mode. A file that appears or disappears counts as a change as well, so
  a new lib\foo.ps1 is picked up together with the line that loads it. The loop first stops
  a resident left over from an earlier run, starts src\clipboard.ps1 serve, and after a
  change stops it through its normal stop event and starts it again, so the history, the
  hotkey and the tray icon behave exactly as in a real run; a start that does not come up is
  reported. Ctrl+C ends the loop and leaves the resident running.
#>
[CmdletBinding()]
param(
  # dev has one mode; the parameter only makes "cli dev <something>" explain itself
  [Parameter(Position = 0)][string]$Action = '',
  # how often the watcher looks at the source tree, in ms
  [int]$Interval = 600
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$entry = Join-Path $root 'src\clipboard.ps1'
$srcDir = Join-Path $root 'src'
if (-not (Test-Path -LiteralPath $entry)) {
  Write-Host ('[x] missing: ' + $entry)
  exit 1
}

function Invoke-Cli([string[]]$cliArgs) {
  & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $entry @cliArgs
  return $LASTEXITCODE
}

# Folders that are watched whole, so a file that appears or disappears needs no manifest:
# every module (lib\ and utils\), the plugins, the theme files, the batch launcher and the
# version file. The user's clipboard.ini is deliberately left out - the resident writes to it
# (window size, window position) and watching it would restart the tool on its own writes.
$watchRoots = @(
  @{ Dir = $srcDir;                        Pattern = '*.ps1'; Deep = $true },
  @{ Dir = (Join-Path $srcDir 'themes');   Pattern = '*.ini'; Deep = $false },
  @{ Dir = $srcDir;                        Pattern = '*.cmd'; Deep = $false },
  @{ Dir = $root;                          Pattern = 'package.ini'; Deep = $false }
)

# The entry point builds every module path from $libDir, so its dot-source lines resolve to
# real files: following them gives the exact load list, the way a bundler follows imports.
function Get-DotSourceTargets([string]$file) {
  $out = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path -LiteralPath $file)) { return $out }
  $here = Split-Path -Parent $file
  $bind = @{
    'PSScriptRoot' = $here
    'Root'         = $here
    'libDir'       = (Join-Path $here 'lib')
  }
  foreach ($line in [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)) {
    $t = $line.Trim()
    if ($t.Length -lt 2 -or $t[0] -ne '.') { continue }
    # . (Join-Path $libDir 'values.ps1')
    $m = [regex]::Match($t, '^\.\s*\(?\s*Join-Path\s+\$(\w+)\s+''([^'']+)''')
    if ($m.Success) {
      $base = $bind[$m.Groups[1].Value]
      if ($base) { $out.Add((Join-Path $base $m.Groups[2].Value)) }
      continue
    }
    # . "$PSScriptRoot\lib\values.ps1"
    $m = [regex]::Match($t, '^\.\s*"\$(\w+)\\([^"]+)"')
    if ($m.Success) {
      $base = $bind[$m.Groups[1].Value]
      if ($base) { $out.Add((Join-Path $base $m.Groups[2].Value)) }
    }
  }
  return $out
}

# What the resident reads: the watched folders plus every file the dot-source lines reach.
# A reference that does not resolve is collected too - it is a broken edit, not a no-op.
function Get-WatchSet {
  $files = @{}
  foreach ($spec in $watchRoots) {
    if (-not (Test-Path -LiteralPath $spec['Dir'])) { continue }
    $items = @(Get-ChildItem -LiteralPath $spec['Dir'] -Filter $spec['Pattern'] -File -Recurse:$spec['Deep'] -ErrorAction SilentlyContinue)
    foreach ($f in $items) { $files[$f.FullName] = $true }
  }
  $missing = New-Object System.Collections.Generic.List[string]
  $seen = @{}
  $queue = New-Object System.Collections.Generic.Queue[string]
  $queue.Enqueue($entry)
  while ($queue.Count -gt 0) {
    $file = $queue.Dequeue()
    if ($seen.ContainsKey($file)) { continue }
    $seen[$file] = $true
    foreach ($target in @(Get-DotSourceTargets $file)) {
      if (Test-Path -LiteralPath $target) {
        $files[$target] = $true
        $queue.Enqueue($target)
      } elseif ($missing -notcontains $target) {
        $missing.Add($target)
      }
    }
  }
  return @{ Files = $files; Missing = $missing.ToArray() }
}

# size plus write time per file: cheap enough to take on every poll, exact enough to catch a
# save that keeps the length of the file
function Get-WatchStamps($files) {
  $h = @{}
  foreach ($p in @($files.Keys)) {
    $stamp = 'unreadable'
    try {
      $fi = New-Object IO.FileInfo $p
      $stamp = [string]$fi.Length + '|' + [string]$fi.LastWriteTimeUtc.Ticks
    } catch { }
    $h[$p] = $stamp
  }
  return $h
}

function Format-WatchPath([string]$path) {
  if ($path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    return $path.Substring($root.Length).TrimStart([char]92, [char]47)
  }
  return $path
}

# added, removed and modified files between two snapshots
function Compare-WatchStamps($before, $after) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($p in @($after.Keys | Sort-Object)) {
    if (-not $before.ContainsKey($p)) { $out.Add('  [+] ' + (Format-WatchPath $p)) }
    elseif ($before[$p] -ne $after[$p]) { $out.Add('  [~] ' + (Format-WatchPath $p)) }
  }
  foreach ($p in @($before.Keys | Sort-Object)) {
    if (-not $after.ContainsKey($p)) { $out.Add('  [-] ' + (Format-WatchPath $p)) }
  }
  return $out
}

# the resident holds Local\clipboard.daemon for as long as it runs
function Test-ResidentUp {
  $up = $false
  try {
    $m = New-Object System.Threading.Mutex($false, 'Local\clipboard.daemon')
    if ($m.WaitOne(0)) { $m.ReleaseMutex() } else { $up = $true }
    $m.Dispose()
  } catch { }
  return $up
}

function Stop-Resident {
  [void](Invoke-Cli @('stop'))
  # the resident releases its mutex on the way out; wait for that before starting again
  for ($i = 0; $i -lt 40; $i++) {
    if (-not (Test-ResidentUp)) { return }
    Start-Sleep -Milliseconds 250
  }
}

# returns $false when the new resident never came up, so the loop can say so
function Start-Resident {
  Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $entry, 'serve') | Out-Null
  # a cold PowerShell needs a second or two before the resident takes its mutex, so the wait
  # is generous: a short one reported a restart as failed while it was still starting
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    if (Test-ResidentUp) { return $true }
  }
  return $false
}

# cli dev starts the resident, watches what it reads and starts it again after a change,
# so every edit lands in a running copy without a second command.
function Start-DevLoop {
  if ($Interval -lt 100) { $Interval = 100 }
  Stop-Resident
  $started = Start-Resident
  $set = Get-WatchSet
  $stamps = Get-WatchStamps $set.Files
  if ($started) {
    Write-Host ('[..] resident started from ' + $srcDir)
  } else {
    Write-Host '[x] the resident did not start - run src\clipboard.ps1 serve to see the error, the next change retries'
  }
  Write-Host ('     watching ' + $stamps.Count + ' file(s), poll ' + $Interval + ' ms - Ctrl+C ends the loop')
  $reported = @{}
  while ($true) {
    Start-Sleep -Milliseconds $Interval
    $set = Get-WatchSet
    foreach ($m in @($set.Missing)) {
      if ($reported.ContainsKey($m)) { continue }
      $reported[$m] = $true
      Write-Host ('  [!] missing: ' + (Format-WatchPath $m) + ' - a dot-source line points at it')
    }
    $next = Get-WatchStamps $set.Files
    if (@(Compare-WatchStamps $stamps $next).Count -eq 0) { continue }
    # an editor writes a file in more than one step: let it settle, then report what changed
    Start-Sleep -Milliseconds 200
    $set = Get-WatchSet
    $next = Get-WatchStamps $set.Files
    $changes = @(Compare-WatchStamps $stamps $next)
    $stamps = $next
    $reported = @{}
    foreach ($c in $changes) { Write-Host $c }
    Write-Host ('[..] ' + (Get-Date).ToString('HH:mm:ss') + ' restarting (' + $changes.Count + ' change(s))')
    Stop-Resident
    if (-not (Start-Resident)) {
      Write-Host '[x] the resident did not start - the next change tries again'
    }
  }
}

# one mode only: refuse an argument instead of starting a loop the caller did not ask for
if ($Action -and $Action.ToLower() -ne 'watch') {
  Write-Host ('[!] unknown argument: ' + $Action)
  Write-Host '    dev always watches - run cli dev with no argument'
  exit 1
}
Start-DevLoop

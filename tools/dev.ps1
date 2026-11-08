#Requires -Version 5.1
<#
  tools\dev.ps1 - run the development copy from src\.

      cli dev           start the resident, restart it whenever a watched file changes

  "dev" always watches what the program reads - the entry point, the modules it loads
  from lib\ and utils\, the theme files, the plugins and package.ini (the version) - and
  there is no second mode. A file that appears or disappears counts as a change as well, so
  a new lib\foo.ps1 is picked up together with the line that loads it. The loop first stops
  a resident left over from an earlier run, starts src\clipboard.ps1 serve, and after a
  change - once the tree has been quiet for a whole poll interval - stops it through its
  normal stop event and starts it again, so the history, the
  hotkey and the tray icon behave exactly as in a real run; a start that does not come up is
  reported. Ctrl+C ends the loop and stops the resident with it; closing the resident from
  outside (tray exit, `clipboard stop`) ends the loop as well, so dev never outlives the
  process it is watching.
#>
[CmdletBinding()]
param(
  # dev has one mode; the parameter only makes "cli dev <something>" explain itself
  [Parameter(Position = 0)][string]$Action = '',
  # how often the watcher looks at the source tree, in ms; 0 = cli.ini [dev] Interval
  [int]$Interval = 0
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

# ---------------------------------------------------------------- settings
# cli.ini [dev] holds Interval, Includes, Excludes and Rebuild. It is read with the tooling's
# own ini parser, so a tool script never loads a module out of src\.
. (Join-Path $root 'tools\utils\ini.ps1')
. (Join-Path $root 'tools\utils\globs.ps1')
$cfgFile = Join-Path $root 'cli.ini'
if (-not (Test-Path -LiteralPath $cfgFile)) {
  Write-Host ('[x] missing settings file: ' + $cfgFile)
  exit 1
}
$cfg = Import-IniMap $cfgFile

# cli.ini is the only place a dev setting may live: a missing key is a broken file, not a
# default to fall back on. An empty Excludes= is valid and means "exclude nothing".
$requiredKeys = @('Interval', 'Includes', 'Excludes', 'Rebuild')
$missingKeys = @()
foreach ($key in $requiredKeys) {
  if (-not $cfg.ContainsKey('dev.' + $key) -and -not $cfg.ContainsKey($key)) { $missingKeys += $key }
}
if ($missingKeys.Count -gt 0) {
  Write-Host ('[x] cli.ini [dev] is missing: ' + ($missingKeys -join ', '))
  exit 1
}

function Cfg([string]$key) {
  # a dev key may be written inside [dev] or with its dotted name at the top level
  foreach ($candidate in @(('dev.' + $key), $key)) {
    if ($cfg.ContainsKey($candidate)) { return [string]$cfg[$candidate] }
  }
  return ''
}

function Split-GlobList([string]$value) {
  return @($value -split '[,;\s]+' | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}

# -Interval overrides the file for a single run; without the switch the file decides
if ($Interval -le 0) {
  $rawInterval = Cfg 'Interval'
  if ($rawInterval -notmatch '^\d+$' -or [int]$rawInterval -le 0) {
    Write-Host ('[x] cli.ini [dev] Interval is not a positive number of milliseconds: ' + $rawInterval)
    exit 1
  }
  $Interval = [int]$rawInterval
}
$rebuild = @('1', 'true', 'yes', 'on') -contains (Cfg 'Rebuild').ToLowerInvariant()

# What the loop watches: the include globs minus the exclude globs. Both are written relative
# to src\ and read again on every poll, so a file that appears or disappears counts as a
# change. The user's clipboard.ini is deliberately absent - the resident writes to it (window
# size, window position) and watching it would restart the tool on its own writes.
$includeGlobs = Split-GlobList (Cfg 'Includes')
$excludeGlobs = Split-GlobList (Cfg 'Excludes')
if ($includeGlobs.Count -eq 0) {
  Write-Host '[x] cli.ini [dev] Includes lists nothing to watch'
  exit 1
}

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

# What the resident reads: the include globs minus the exclude globs, plus every file the
# dot-source lines reach. A reference that does not resolve is collected too - it is a broken
# edit, not a no-op.
function Get-WatchSet {
  $files = @{}
  foreach ($f in @(Expand-GlobList $srcDir $includeGlobs $excludeGlobs)) { $files[$f] = $true }
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

# The process this loop started, which the mutex alone cannot tell apart from another
# instance: an outside exit (tray Exit, clipboard stop) kills it and nothing takes its place,
# so its own process id answers "gone" at once instead of after the restart grace below.
$script:ResidentPid = 0
function Test-ResidentProcess {
  if ($script:ResidentPid -le 0) { return $false }
  return ($null -ne (Get-Process -Id $script:ResidentPid -ErrorAction SilentlyContinue))
}

function Stop-Resident {
  # nothing to stop: asking the cli would start a whole PowerShell just to find that out
  if (-not (Test-ResidentUp)) { $script:ResidentPid = 0; return }
  # The resident waits on its own stop event (base.ps1: $StopName). Setting it here skips a
  # cold PowerShell start, which matters twice: a restart is quicker, and the finally block
  # that Ctrl+C runs can stop the resident with plain .NET calls only.
  $sent = $false
  try {
    $se = [System.Threading.EventWaitHandle]::OpenExisting('Local\clipboard.stop')
    [void]$se.Set()
    $se.Dispose()
    $sent = $true
  } catch { }
  if (-not $sent) { [void](Invoke-Cli @('stop')) }
  # the resident releases its mutex on the way out; wait for that before starting again
  for ($i = 0; $i -lt 100; $i++) {
    if (-not (Test-ResidentUp)) { $script:ResidentPid = 0; return }
    Start-Sleep -Milliseconds 100
  }
  $script:ResidentPid = 0
}

# returns $false when the new resident never came up, so the loop can say so
function Start-Resident {
  $script:ResidentPid = 0
  $proc = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $entry, 'serve')
  if ($null -ne $proc) { $script:ResidentPid = [int]$proc.Id }
  # a cold PowerShell needs a second or two before the resident takes its mutex, so the wait
  # is generous: a short one reported a restart as failed while it was still starting
  for ($i = 0; $i -lt 100; $i++) {
    Start-Sleep -Milliseconds 100
    if (Test-ResidentUp) { return $true }
  }
  return $false
}

# cli dev starts the resident, watches what it reads and starts it again after a change,
# so every edit lands in a running copy without a second command.
function Start-DevLoop {
  if ($Interval -lt 100) { $Interval = 100 }
  Stop-Resident
  $set = Get-WatchSet
  $stamps = Get-WatchStamps $set.Files
  $started = Start-Resident
  if (-not $started) {
    Write-Host '[x] the resident did not start - run src\clipboard.ps1 serve to see the error, the next change retries'
  }
  Write-Host ('     watching ' + $stamps.Count + ' file(s), poll ' + $Interval + ' ms - Ctrl+C ends the loop and the resident')
  $reported = @{}
  # Did the resident ever come up? A resident that has been up and stays gone was closed
  # from outside (tray exit, `clipboard stop`), so there is nothing left to restart and dev
  # ends with it. A start that failed before is not that case: it keeps retrying on the next
  # change, which is what the message above says it does.
  $sawUp = $started
  $goneAt = $null
  while ($true) {
    Start-Sleep -Milliseconds $Interval
    if (Test-ResidentUp) {
      $sawUp = $true
      $goneAt = $null
    } elseif ($sawUp) {
      # The process this loop started is gone and no other instance took the mutex: that is an
      # outside exit (tray Exit, `clipboard stop`), so leave at once. Only a restart from
      # another console - which leaves the mutex free for a moment while the new instance
      # starts - still needs the grace period below.
      if (-not (Test-ResidentProcess)) {
        Write-Host '[..] the resident exited - leaving dev'
        return
      }
      # `config set` restarts the resident from another console, and a restart drops the
      # mutex for a second or two too: only a resident that stays gone counts as an exit
      if ($null -eq $goneAt) {
        $goneAt = Get-Date
      } elseif (((Get-Date) - $goneAt).TotalSeconds -ge 5) {
        Write-Host '[..] the resident exited - leaving dev'
        return
      }
    }
    $set = Get-WatchSet
    foreach ($m in @($set.Missing)) {
      if ($reported.ContainsKey($m)) { continue }
      $reported[$m] = $true
      Write-Host ('  [!] missing: ' + (Format-WatchPath $m) + ' - a dot-source line points at it')
    }
    $next = Get-WatchStamps $set.Files
    if (@(Compare-WatchStamps $stamps $next).Count -eq 0) { continue }
    # Strict debounce: an editor writes a file in more than one step, and a batch of saves can
    # land a few hundred ms apart. Restart only after a whole poll interval with no further
    # change, so one save - however many writes it takes - costs exactly one restart.
    while ($true) {
      Start-Sleep -Milliseconds $Interval
      if ($sawUp -and -not (Test-ResidentUp)) {
        Write-Host '[..] the resident exited - leaving dev'
        return
      }
      $set = Get-WatchSet
      $after = Get-WatchStamps $set.Files
      if (@(Compare-WatchStamps $next $after).Count -eq 0) { break }
      $next = $after
    }
    $changes = @(Compare-WatchStamps $stamps $next)
    $stamps = $next
    $reported = @{}
    foreach ($c in $changes) { Write-Host $c }
    Write-Host ('[..] ' + (Get-Date).ToString('HH:mm:ss') + ' restarting (' + $changes.Count + ' change(s))')
    # The resident holds lib\assembly\clipboard.dll open while it runs, so it has to be gone
    # before the assembly can be rewritten: stop first, compile, then start again.
    Stop-Resident
    # The C# lives in src\lib\assembly. A dev run loads the assembly when it is newer than the
    # source, so a C# edit has to recompile it before the restart; otherwise the restart
    # compiles it in-process, which costs about a second per start.
    if ($rebuild -and @($changes | Where-Object { $_ -match '\.cs$' }).Count -gt 0) {
      $assemblyScript = Join-Path $root 'scripts\build-assembly.ps1'
      if (Test-Path -LiteralPath $assemblyScript) {
        Write-Host '[..] the C# changed - rebuilding lib\assembly\clipboard.dll'
        $log = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $assemblyScript -Out (Join-Path $srcDir 'lib\assembly\clipboard.dll') 2>&1
        foreach ($line in @($log)) { Write-Host ('    ' + ([string]$line).Trim()) }
      }
    }
    $goneAt = $null
    if (Start-Resident) {
      $sawUp = $true
    } else {
      # a restart that failed is not an outside exit: report it and retry on the next change
      $sawUp = $false
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
# The resident belongs to the loop: when dev ends - Ctrl+C, a crash in the loop, or an error -
# it goes with it. Ctrl+C reaches the finally block, so a half-stopped resident is not left
# capturing into a history nobody is watching. The one case this cannot cover is the terminal
# itself being killed, which terminates the process before any cleanup runs.
try {
  Start-DevLoop
} finally {
  if (Test-ResidentUp) {
    Stop-Resident
    Write-Host '[..] resident stopped'
  }
}

#Requires -Version 5.1
<#
  packages\cli\watch.ps1 - run the development copy from src\.

      cli dev           start the resident, restart it whenever a watched file changes

  "dev" always watches the file list builder.ini declares - the same globs a package is built
  from: the file list builder.ini declares, the entry point, the theme files, the
  plugins, the C# sources and package.ini (the version) - plus packages\**, builder.ini and
  builder.cli.config.ps1, and there is no second mode. A file that appears or disappears
  counts as a change as well, so a new module is picked up together with the line that
  loads it. The loop first stops a resident left over from an earlier run, starts the entry's
  serve command, and after a change - once the tree has been quiet for a whole poll interval -
  stops it through its normal stop event and starts it again, so the history, the hotkey and
  the tray icon behave exactly as in a real run; a start that does not come up is reported.
  Ctrl+C ends the loop and stops the resident with it; closing the resident from outside (tray
  exit, the program's stop command) ends the loop as well, so dev never outlives the process it
  is watching.
#>
[CmdletBinding()]
param(
  # dev has one mode; the parameter only makes "cli dev <something>" explain itself
  [Parameter(Position = 0)][string]$Action = '',
  # how often the watcher looks at the source tree, in ms; 0 = cli.ini [global] WatchInterval
  [int]$Interval = 0,
  # quiet keeps warnings and failures, silent keeps failures only
  [switch]$Quiet,
  [switch]$Silent,
  # a loop runs for hours: a stamp on every line is what makes two restarts comparable
  [switch]$Timestamp
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
# the same logger every tool prints through: [..] for a step, [ok] for a finished one, [x] for
# a failure
. (Join-Path $root 'packages\cli\utils\console.ps1')
Set-LogLevelFrom -Quiet:$Quiet -Silent:$Silent
if ($Timestamp) { Enable-LogTimestamp }
$srcDir = Join-Path $root 'src'
# package.ini owns the program name, and the name owns the entry: nothing here spells it out
. (Join-Path $root 'packages\cli\utils\ini.ps1')
$pkg = Import-IniMap (Join-Path $root 'package.ini')
$app = ''
foreach ($candidate in @('package.Name', 'Name')) {
  if ($pkg.ContainsKey($candidate) -and [string]$pkg[$candidate]) { $app = ([string]$pkg[$candidate]).Trim(); break }
}
if (-not $app) { Fail 'no Name= in package.ini' }
$entry = Join-Path $srcDir ($app + '.ps1')
if (-not (Test-Path -LiteralPath $entry)) { Fail ('missing: ' + $entry) }

function Invoke-Cli([string[]]$cliArgs) {
  & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $entry @cliArgs
  return $LASTEXITCODE
}

# ---------------------------------------------------------------- settings
# What the loop watches is the file list a package is built from (builder.ini [files]) and the
# poll interval is this package's own default (packages\cli\package.ini [watch]). Both are read
# with the tooling's own parser, so a tool script never loads a module out of src\.
. (Join-Path $root 'packages\cli\utils\globs.ps1')
$cfgFile = Join-Path $root 'builder.ini'
if (-not (Test-Path -LiteralPath $cfgFile)) { Fail ('missing settings file: ' + $cfgFile) }
$cfg = Import-IniMap $cfgFile
$selfCfg = Import-IniMap (Join-Path $root 'packages\cli\package.ini')

# One list, two halves: builder.ini writes electron-builder's patterns, where a leading "!" is an
# exclusion. dev watches exactly that set, so a folder added under src\ is picked up without
# touching this file.
$includeGlobs = New-Object System.Collections.Generic.List[string]
$excludeGlobs = New-Object System.Collections.Generic.List[string]
$fileList = ''
foreach ($candidate in @('files.Files', 'Files')) {
  if ($cfg.ContainsKey($candidate)) { $fileList = [string]$cfg[$candidate]; break }
}
foreach ($one in @($fileList -split ',')) {
  $pattern = $one.Trim()
  if (-not $pattern) { continue }
  if ($pattern.StartsWith('!')) { $excludeGlobs.Add($pattern.Substring(1).Trim()) }
  else { $includeGlobs.Add($pattern) }
}

# -Interval overrides the file for a single run; without the switch the package decides
if ($Interval -le 0) {
  $Interval = 600
  foreach ($candidate in @('watch.Interval', 'Interval')) {
    if ($selfCfg.ContainsKey($candidate)) { [void][int]::TryParse(([string]$selfCfg[$candidate]).Trim(), [ref]$Interval); break }
  }
  if ($Interval -le 0) { $Interval = 600 }
}

# Both compiled products come from src\. A .cs file in the list is a promise: the loop builds
# its products before the first start and again after every save, so the file the program runs
# never outlives the source.

# The two C# products are rebuilt through the same entry points a release uses, so dev and
# `cli build` cannot disagree about a compiler, a flag or where the product lands.
function Invoke-DevBuild {
  foreach ($tool in @('assembly.ps1', 'client.ps1')) {
    $script = Join-Path $root ('packages\cli\' + $tool)
    if (-not (Test-Path -LiteralPath $script)) { Fail ('missing: ' + $script) }
    $swProduct = Start-Step
    $log = & powershell -NoProfile -ExecutionPolicy Bypass -File $script 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    foreach ($line in @($log)) {
      $text = ([string]$line).Trim()
      if (-not $text -or $text.StartsWith('[ok]')) { continue }
      Write-Note $text
    }
    if ($ok) { Write-Done $swProduct ('compiled ' + $tool) }
  }
}

# What the loop watches: the include globs minus the exclude globs, both straight out of
# builder.ini and read again on every poll, so a file that appears or disappears counts as a
# change. The user's clipboard.ini is deliberately absent - the resident writes to it (window
# size, window position) and watching it would restart the tool on its own writes.
$baseSetting = ''
foreach ($candidate in @('directories.BaseUrl', 'BaseUrl')) {
  if ($cfg.ContainsKey($candidate)) { $baseSetting = ([string]$cfg[$candidate]).Trim(); break }
}
if (-not $baseSetting) { $baseSetting = '.' }
$baseDir = Resolve-BaseDir $root $baseSetting
if (-not (Test-Path -LiteralPath $baseDir)) { Fail ('builder.ini [directories] BaseUrl does not exist: ' + $baseSetting) }
$watched = @(Expand-GlobList $baseDir $includeGlobs.ToArray() $excludeGlobs.ToArray())
if ($watched.Count -eq 0) { Fail 'builder.ini [files] Files reaches no file' }
# the tooling is part of the loop as well: a saved tool script or a rewritten build file changes
# the program being run, so it is watched on top of the file list
foreach ($one in @('packages\**\*.ps1', 'builder.ini', 'builder.cli.config.ps1', 'package.ini')) {
  foreach ($hit in @(Expand-Glob $root $one)) {
    if ($watched -notcontains $hit) { $watched += $hit }
  }
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
  foreach ($f in @(Expand-GlobList $baseDir $includeGlobs $excludeGlobs)) { $files[$f] = $true }
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

# added, removed and modified files between two snapshots, each with what happened to it: the
# word is what the line says, and Write-Note gives it the indent and the colour of a detail
function Compare-WatchStamps($before, $after) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($p in @($after.Keys | Sort-Object)) {
    if (-not $before.ContainsKey($p)) { $out.Add('added   ' + (Format-WatchPath $p)) }
    elseif ($before[$p] -ne $after[$p]) { $out.Add('changed ' + (Format-WatchPath $p)) }
  }
  foreach ($p in @($before.Keys | Sort-Object)) {
    if (-not $after.ContainsKey($p)) { $out.Add('removed ' + (Format-WatchPath $p)) }
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
  # compile ahead of the first start: the resident holds the dll open, so this runs after it
  # is gone and before anything loads the files
  Invoke-DevBuild
  $set = Get-WatchSet
  $stamps = Get-WatchStamps $set.Files
  $started = Start-Resident
  if (-not $started) {
    Write-Warn ('the resident did not start - run ' + (Format-WatchPath $entry) + ' serve to see the error, the next change retries')
  }
  Write-Step ('watching ' + $stamps.Count + ' files, poll ' + $Interval + ' ms - Ctrl+C ends the loop and the resident')
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
        Write-Step 'the resident exited - leaving dev'
        return
      }
      # `config set` restarts the resident from another console, and a restart drops the
      # mutex for a second or two too: only a resident that stays gone counts as an exit
      if ($null -eq $goneAt) {
        $goneAt = Get-Date
      } elseif (((Get-Date) - $goneAt).TotalSeconds -ge 5) {
        Write-Step 'the resident exited - leaving dev'
        return
      }
    }
    $set = Get-WatchSet
    foreach ($m in @($set.Missing)) {
      if ($reported.ContainsKey($m)) { continue }
      $reported[$m] = $true
      Write-Warn ('missing: ' + (Format-WatchPath $m) + ' - a dot-source line points at it')
    }
    $next = Get-WatchStamps $set.Files
    if (@(Compare-WatchStamps $stamps $next).Count -eq 0) { continue }
    # Strict debounce: an editor writes a file in more than one step, and a batch of saves can
    # land a few hundred ms apart. Restart only after a whole poll interval with no further
    # change, so one save - however many writes it takes - costs exactly one restart.
    while ($true) {
      Start-Sleep -Milliseconds $Interval
      if ($sawUp -and -not (Test-ResidentUp)) {
        Write-Step 'the resident exited - leaving dev'
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
    $swRestart = Start-Step
    Write-Step ('restarting (' + $changes.Count + ' change(s))')
    # the files come under the step they explain: printed before it, they landed after the line
    # that ended the previous restart and read as if they belonged to that one
    foreach ($c in $changes) { Write-Note $c }
    # The resident holds main\clipboard.dll open while it runs, so it has to be gone
    # before the assembly can be rewritten: stop first, compile, then start again.
    Stop-Resident
    # A C# edit has to reach its product before the restart. Both products are rebuilt: the
    # compiler decides what is stale (a source newer than its dll), so this stays one command.
    $csChanges = @($changes | Where-Object { $_ -match '\.cs$' })
    if ($csChanges.Count -gt 0) { Invoke-DevBuild }
    $goneAt = $null
    if (Start-Resident) {
      $sawUp = $true
      Write-Done $swRestart 'the resident is up'
    } else {
      # a restart that failed is not an outside exit: report it and retry on the next change
      $sawUp = $false
      Write-Warn 'the resident did not start - the next change tries again'
    }
  }
}

# one mode only: refuse an argument instead of starting a loop the caller did not ask for
if ($Action -and $Action.ToLower() -ne 'watch') {
  Write-Fail ('unknown argument: ' + $Action)
  Write-Note 'dev always watches - run cli dev with no argument'
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
    Write-Note 'resident stopped'
  }
}

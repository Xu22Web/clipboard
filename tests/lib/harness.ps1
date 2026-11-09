#Requires -Version 5.1
<#
  tests\lib\harness.ps1 - what every test part needs: a result list, a sandbox, and a way to
  call the command line.

  A part is one file that runs on its own, in its own process, with its own sandbox:

      . "$PSScriptRoot\..\lib\harness.ps1"     (from tests\cli\*.ps1)
      Start-TestPart -Source $Source -Quiet:$Quiet
      ...checks...
      Complete-TestPart -ResultFile $ResultFile

  That is what lets several parts run at the same time: no shared store, no shared clipboard
  (each sandbox carries tests\lib\fake-clip.ps1), no shared console.
#>

$script:Results = New-Object System.Collections.Generic.List[object]
$script:Harness = @{ Timings = (New-Object System.Collections.Generic.List[object]) }

# loaded here rather than by every part: Check and Skip print through it, and so does the
# summary a part prints when it is run by hand
. (Join-Path $PSScriptRoot 'reporter.ps1')

# what the progress line reads while the part runs; a quiet part only writes this file, the
# part that started it owns the console
$script:Harness.Progress = @{ Pass = 0; Fail = 0; Skip = 0; Total = 0; Last = ''; At = [DateTime]::MinValue }

function Write-TestProgressFile {
  $file = [string]$script:Harness.ProgressFile
  if (-not $file) { return }
  $now = Get-Date
  # five writes a second is enough for a progress line and keeps a 579 check part cheap
  if (($now - $script:Harness.Progress.At).TotalMilliseconds -lt 200) { return }
  $script:Harness.Progress.At = $now
  $p = $script:Harness.Progress
  $line = [string]$p['Pass'] + ' ' + [string]$p['Fail'] + ' ' + [string]$p['Skip'] + ' ' + [string]$p['Total'] + ' ' + [string]$p['Last']
  try { [IO.File]::WriteAllText($file, $line, $script:Harness.Utf8) } catch { }
}

# The number of checks this part will run, written as soon as the block tree is built: the
# reader over this file shows "completed/total" while the rows are still running.
function Set-TestPartTotal([int]$Total) {
  $p = $script:Harness.Progress
  $p['Total'] = $Total
  $file = [string]$script:Harness.ProgressFile
  if (-not $file) { return }
  $line = [string]$p['Pass'] + ' ' + [string]$p['Fail'] + ' ' + [string]$p['Skip'] + ' ' + [string]$Total + ' ' + [string]$p['Last']
  try { [IO.File]::WriteAllText($file, $line, $script:Harness.Utf8) } catch { }
}

function Add-TestTiming([string]$what, [long]$ms) {
  if ($null -eq $script:Harness.Timings) { return }
  $script:Harness.Timings.Add([pscustomobject]@{ What = $what; Ms = $ms })
}

# Milliseconds are the time since the previous check: the work before a check is the setup it
# needed (a command line call, a sandbox copy), which is what a slow part spends its time on.
#
# Printing never decides whether a result exists: a reporter that throws loses its line, not the
# row, and the reason goes to %TEMP%\clipboard-tests-error.log instead of vanishing.
function Add-TestResult([string]$group, [string]$name, [string]$result, [string]$detail) {
  $now = Get-Date
  $ms = 0
  try {
    if ($null -ne $script:TestReport.LastMark) { $ms = [int](($now - $script:TestReport.LastMark).TotalMilliseconds) }
    $script:TestReport.LastMark = $now
    $script:Results.Add([pscustomobject]@{ Group = $group; Test = $name; Result = $result; Detail = $detail; Ms = $ms })
    $p = $script:Harness.Progress
    if ($result -eq 'PASS') { $p['Pass'] = [int]$p['Pass'] + 1 }
    elseif ($result -eq 'FAIL') { $p['Fail'] = [int]$p['Fail'] + 1 }
    elseif ($result -eq 'SKIP') { $p['Skip'] = [int]$p['Skip'] + 1 }
    $p['Last'] = $name
    Write-TestCheck ($script:Harness.Part + '.ps1') ($group + ' > ' + $name) $result $detail $ms
    Write-TestProgressFile
  } catch {
    if (-not ($script:Results | Where-Object { $_.Test -eq $name -and $_.Group -eq $group })) {
      $script:Results.Add([pscustomobject]@{ Group = $group; Test = $name; Result = $result; Detail = $detail; Ms = 0 })
    }
    try {
      $log = Join-Path $env:TEMP 'clipboard-tests-error.log'
      [IO.File]::AppendAllText($log, ((Get-Date).ToString('HH:mm:ss') + '  reporter: ' + $_.Exception.Message + "`r`n"))
    } catch { }
  }
}

function Check([string]$group, [string]$name, [bool]$ok, [string]$detail) {
  Add-TestResult $group $name $(if ($ok) { 'PASS' } else { 'FAIL' }) $detail
}

function Skip([string]$group, [string]$name, [string]$why) {
  Add-TestResult $group $name 'SKIP' $why
}

# ---------------------------------------------------------------- describe / it
# The shape vitest reports in: describes nest, an it is one check, and the assertions inside it
# record what was looked at. Each it runs as soon as it is reached, so a part keeps the order
# its setup was written in. Check and Skip stay for a part that has not been moved yet.
$script:Harness.Describes = New-Object System.Collections.Generic.List[string]
$script:Harness.Frames = New-Object System.Collections.Generic.List[object]
$script:Harness.Asserts = $null
$script:Harness.ExpectCount = -1
$script:Harness.ExpectSome = $false
# Two phases, the way vitest collects before it runs: a part reaches its rows first (that is
# when the total is known and written out), then the rows are executed in the order written.
$script:Harness.Phase = 'collect'
$script:Harness.Queue = New-Object System.Collections.Generic.List[object]

function Get-TestGroupPath {
  if ($script:Harness.Describes.Count -eq 0) { return '' }
  return ($script:Harness.Describes -join ' > ')
}

# hook errors never decide a result on their own: the log keeps them, the rows stay honest
function Add-TestHookError($ErrorRecord) {
  try {
    $log = Join-Path $env:TEMP 'clipboard-tests-error.log'
    [IO.File]::AppendAllText($log, ((Get-Date).ToString('HH:mm:ss') + '  hook: ' + $ErrorRecord.Exception.Message + "`r`n"))
  } catch { }
}

function Describe([string]$Name, [scriptblock]$Body) {
  $frame = @{
    After      = New-Object System.Collections.Generic.List[object]
    BeforeEach = New-Object System.Collections.Generic.List[object]
    AfterEach  = New-Object System.Collections.Generic.List[object]
  }
  $script:Harness.Describes.Add($Name)
  $script:Harness.Frames.Add($frame)
  try {
    & $Body
  } finally {
    $script:Harness.Frames.RemoveAt($script:Harness.Frames.Count - 1)
    $script:Harness.Describes.RemoveAt($script:Harness.Describes.Count - 1)
    # a block's cleanup belongs after the rows it collected, and it runs even when one of them
    # failed or threw
    if ($script:Harness.Phase -eq 'collect') {
      foreach ($hook in $frame.After) { $script:Harness.Queue.Add(@{ Hook = $hook }) }
    } else {
      foreach ($hook in $frame.After) {
        try { & $hook } catch { Add-TestHookError $_ }
      }
    }
  }
}

# Runs before the first row that follows it, so the order a part writes its setup in is kept:
# while collecting it takes a place in the queue instead of running.
function BeforeAll([scriptblock]$Body) {
  if ($script:Harness.Phase -eq 'collect') { $script:Harness.Queue.Add(@{ Hook = $Body }); return }
  & $Body
}

function AfterAll([scriptblock]$Body) {
  if ($script:Harness.Frames.Count -eq 0) { throw 'AfterAll has to be inside a Describe block' }
  $script:Harness.Frames[$script:Harness.Frames.Count - 1].After.Add($Body)
}

function BeforeEach([scriptblock]$Body) {
  if ($script:Harness.Frames.Count -eq 0) { throw 'BeforeEach has to be inside a Describe block' }
  $script:Harness.Frames[$script:Harness.Frames.Count - 1].BeforeEach.Add($Body)
}

function AfterEach([scriptblock]$Body) {
  if ($script:Harness.Frames.Count -eq 0) { throw 'AfterEach has to be inside a Describe block' }
  $script:Harness.Frames[$script:Harness.Frames.Count - 1].AfterEach.Add($Body)
}

function Get-TestHooks([string]$Kind, [switch]$Reverse) {
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($frame in $script:Harness.Frames) {
    foreach ($hook in $frame[$Kind]) { $list.Add($hook) }
  }
  if ($Reverse) { $list.Reverse() }
  return $list
}

# vi.waitFor: poll a condition, then answer whether it held; the caller asserts the answer
function Wait-Until([scriptblock]$Condition, [int]$Timeout = 5000, [int]$Interval = 100) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    try { if (& $Condition) { return $true } } catch { }
    if ($watch.ElapsedMilliseconds -ge $Timeout) { return $false }
    Start-Sleep -Milliseconds $Interval
  }
}

# '%s' in the name is filled with the case, so one row is reported per case
function Format-TestCaseName([string]$Name, $Case) {
  $result = $Name
  foreach ($value in @($Case)) {
    $at = $result.IndexOf('%s')
    if ($at -ge 0) { $result = $result.Substring(0, $at) + [string]$value + $result.Substring($at + 2) }
    else { $result = $result + ' ' + [string]$value }
  }
  return $result
}

function It([string]$Name, [scriptblock]$Body, [string]$Skip = '', [object[]]$Cases = @()) {
  if ($script:Harness.Phase -eq 'collect') {
    $group = Get-TestGroupPath
    if (-not $group) { $group = [string]$script:Harness.Part }
    # the hooks are captured with the row: the block frames are gone by the time it runs
    $before = @(Get-TestHooks 'BeforeEach')
    $after = @(Get-TestHooks 'AfterEach' -Reverse)
    if ($Cases.Count -eq 0) {
      $script:Harness.Queue.Add(@{ Group = $group; Name = $Name; Body = $Body; Args = @(); Skip = $Skip; Before = $before; After = $after })
    } else {
      foreach ($case in $Cases) {
        $script:Harness.Queue.Add(@{ Group = $group; Name = (Format-TestCaseName $Name $case); Body = $Body; Args = @($case); Skip = $Skip; Before = $before; After = $after })
      }
    }
    return
  }
  if ($Cases.Count -eq 0) { Invoke-TestIt $Name $Body @() '' $Skip; return }
  foreach ($case in $Cases) { Invoke-TestIt (Format-TestCaseName $Name $case) $Body @($case) '' $Skip }
}

# The queue is what the collect phase produced: report its size, run the one-off hooks, then
# every row in the order it was written.
function Invoke-TestQueue {
  if ($script:Harness.Phase -ne 'collect') { return }
  $script:Harness.Phase = 'run'
  $total = 0
  foreach ($item in $script:Harness.Queue) { if ($null -eq $item.Hook) { $total = $total + 1 } }
  Set-TestPartTotal $total
  foreach ($item in $script:Harness.Queue) {
    if ($null -ne $item.Hook) {
      try { & $item.Hook } catch { Add-TestHookError $_ }
      continue
    }
    Invoke-TestIt ([string]$item.Name) ($item.Body) @($item.Args) ([string]$item.Group) ([string]$item.Skip) $item.Before $item.After
  }
}

function Invoke-TestIt([string]$Name, [scriptblock]$Body, [object[]]$Arguments = @(), [string]$Group = '', [string]$Skip = '', [object[]]$Before = $null, [object[]]$After = $null) {
  if (-not $Group) {
    $Group = Get-TestGroupPath
    if (-not $Group) { $Group = [string]$script:Harness.Part }
  }
  if ($Skip) { Add-TestResult $Group $Name 'SKIP' $Skip; return }
  if ($null -eq $Before -and $script:Harness.Frames.Count -gt 0) {
    $Before = @(Get-TestHooks 'BeforeEach')
    $After = @(Get-TestHooks 'AfterEach' -Reverse)
  }
  $group = $Group
  $outer = $script:Harness.Asserts
  $outerCount = $script:Harness.ExpectCount
  $outerSome = $script:Harness.ExpectSome
  $asserts = New-Object System.Collections.Generic.List[object]
  $script:Harness.Asserts = $asserts
  $script:Harness.ExpectCount = -1
  $script:Harness.ExpectSome = $false
  $failure = ''
  foreach ($hook in @($Before)) {
    try { & $hook } catch { $failure = 'before each: ' + $_.Exception.Message; break }
  }
  if (-not $failure) {
    try { & $Body @Arguments } catch { $failure = $_.Exception.Message }
  }
  foreach ($hook in @($After)) {
    try { & $hook } catch { Add-TestHookError $_ }
  }
  $wanted = $script:Harness.ExpectCount
  $some = $script:Harness.ExpectSome
  $script:Harness.Asserts = $outer
  $script:Harness.ExpectCount = $outerCount
  $script:Harness.ExpectSome = $outerSome
  if ($failure) { Add-TestResult $group $Name 'FAIL' $failure; return }
  $recorded = $asserts.Count
  if ($some -and $recorded -eq 0) { Add-TestResult $group $Name 'FAIL' 'expected at least one assertion, the block made none'; return }
  if ($wanted -ge 0 -and $recorded -ne $wanted) {
    Add-TestResult $group $Name 'FAIL' ('expected ' + [string]$wanted + ' assertions, the block made ' + [string]$recorded)
    return
  }
  $failed = 0
  $first = ''
  foreach ($a in $asserts) {
    if (-not $a.Ok) {
      $failed = $failed + 1
      if (-not $first) { $first = [string]$a.Detail }
    }
  }
  if ($failed -gt 0) {
    if ($failed -gt 1) { $first = $first + ' (' + [string]$failed + ' assertions failed)' }
    Add-TestResult $group $Name 'FAIL' $first
    return
  }
  Add-TestResult $group $Name 'PASS' ''
}

# one assertion: the message is what a failure prints
function Expect([bool]$Ok, [string]$Message = '') {
  if ($null -eq $script:Harness.Asserts) {
    $group = Get-TestGroupPath
    if (-not $group) { $group = [string]$script:Harness.Part }
    if (-not $Message) { $Message = 'assertion' }
    Add-TestResult $group $Message $(if ($Ok) { 'PASS' } else { 'FAIL' }) ''
    return
  }
  $script:Harness.Asserts.Add(@{ Ok = $Ok; Detail = $Message })
}

function Expect-Match([string]$Text, [string]$Pattern, [string]$Message = '') {
  $ok = [string]$Text -match $Pattern
  if (-not $Message) { $Message = 'expected a match for ' + $Pattern + ', got: ' + ([string]$Text).Trim() }
  Expect $ok $Message
}

function Expect-Equal($Actual, $Expected, [string]$Message = '') {
  if (-not $Message) { $Message = 'expected <' + [string]$Expected + '>, got <' + [string]$Actual + '>' }
  Expect ([string]$Actual -eq [string]$Expected) $Message
}

function Expect-Contains([string]$Text, [string]$Part, [string]$Message = '') {
  if (-not $Message) { $Message = 'expected to find <' + $Part + '>, got: ' + ([string]$Text).Trim() }
  Expect (([string]$Text).Contains($Part)) $Message
}

# the block has to throw; with a pattern the error message has to match it
function Expect-Throws([scriptblock]$Block, [string]$Pattern = '', [string]$Message = '') {
  $thrown = ''
  try { & $Block } catch { $thrown = $_.Exception.Message }
  if (-not $thrown) {
    if (-not $Message) { $Message = 'expected the block to throw, but it returned' }
    Expect $false $Message
    return
  }
  if (-not $Pattern) { Expect $true ''; return }
  if (-not $Message) { $Message = 'expected the error to match ' + $Pattern + ', got: ' + $thrown }
  Expect ([string]$thrown -match $Pattern) $Message
}

# guards against a block that lost its assertions and would otherwise pass by doing nothing
function Expect-HasAssertions {
  $script:Harness.ExpectSome = $true
}

function Expect-Assertions([int]$Count) {
  $script:Harness.ExpectCount = $Count
}

function Expect-Greater($Actual, $Expected, [string]$Message = '') {
  if (-not $Message) { $Message = 'expected <' + [string]$Actual + '> to be greater than <' + [string]$Expected + '>' }
  Expect ([double]$Actual -gt [double]$Expected) $Message
}

function Expect-Not([bool]$Ok, [string]$Message = '') {
  Expect (-not $Ok) $Message
}

# the drawing helpers take a Graphics plus plain values, so a part can paint them onto a bitmap
function Use-Drawing {
  foreach ($a in @('System.Drawing', 'System.Windows.Forms')) {
    try { Add-Type -AssemblyName $a -ErrorAction Stop } catch { }
  }
}

function New-Sandbox([string]$name) {
  $dir = Join-Path $script:Harness.TmpRoot $name
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Copy-Item -LiteralPath $script:Harness.ClipPs1 -Destination $dir -Force
  foreach ($sub in @('lib', 'utils', 'schema', 'plugins', 'themes')) {
    $src = Join-Path $script:Harness.SrcRoot $sub
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dir -Recurse -Force }
  }
  # the version lives in package.ini, one level above src\ in the repository and beside the
  # script in a sandbox - copying it keeps the sandbox reporting the real number
  $pkgIni = Join-Path $script:Harness.RepoRoot 'package.ini'
  if (Test-Path -LiteralPath $pkgIni) { Copy-Item -LiteralPath $pkgIni -Destination $dir -Force }
  return $dir
}

# a sandbox whose clipboard is a file instead of the machine's (tests\lib\fake-clip.ps1): two
# parts can then run side by side, and the user's clipboard is never touched
function New-FakeSandbox([string]$name) {
  $dir = New-Sandbox $name
  $fake = Join-Path $script:Harness.RepoRoot 'tests\lib\fake-clip.ps1'
  if ($script:Harness.IsPackaged) { return $dir }
  if (Test-Path -LiteralPath $fake) {
    Copy-Item -LiteralPath $fake -Destination (Join-Path $dir 'lib\clip.ps1') -Force
  }
  return $dir
}

# The compiled client (lib\client\client.cs) is optional, so a part that wants to exercise it asks
# for one here: a package carries its own copy, a source checkout gets one built into %TEMP%
# once per run, and an empty string means "no compiler here" - the caller skips instead of
# failing.
function Get-ClientExe {
  if ($null -ne $script:Harness.ClientExe) { return $script:Harness.ClientExe }
  $script:Harness.ClientExe = ''
  $beside = Join-Path $script:Harness.SrcRoot 'client.exe'
  if (Test-Path -LiteralPath $beside) { $script:Harness.ClientExe = $beside; return $beside }
  $builder = Join-Path $script:Harness.RepoRoot 'tools\build-client.ps1'
  $source = Join-Path $script:Harness.SrcRoot 'lib\client\client.cs'
  if (-not (Test-Path -LiteralPath $builder) -or -not (Test-Path -LiteralPath $source)) { return '' }
  # Content addressed and outside the per-run temp folder: recompiling a client that did not
  # change used to cost every run of the suite a csc call, in the parts that exercise it.
  $cache = Join-Path $env:TEMP 'clipboard-tests-cache'
  if (-not (Test-Path -LiteralPath $cache)) { New-Item -ItemType Directory -Path $cache -Force | Out-Null }
  $stamp = (Get-FileHash -LiteralPath $source -Algorithm SHA1).Hash.Substring(0, 12)
  $exe = Join-Path $cache ('client-' + $stamp + '.exe')
  if (-not (Test-Path -LiteralPath $exe)) {
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder -Source $source -Out $exe 2>&1
  }
  if (Test-Path -LiteralPath $exe) { $script:Harness.ClientExe = $exe }
  return $script:Harness.ClientExe
}

# one CLI call in its own process: a command starts from nothing, the way the user's shell does
function Clip([string]$sandbox, [string[]]$cliArgs) {
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', (Join-Path $sandbox 'clipboard.ps1')) + $cliArgs
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $out = (& powershell @a 2>&1 | Out-String)
  $watch.Stop()
  Add-TestTiming (($cliArgs -join ' ')) $watch.ElapsedMilliseconds
  return $out
}

# A part that makes many calls can keep one runner (tests\lib\cli-runner.ps1) instead: the
# interpreter start and the module load happen once, and every request still runs in a
# runspace of its own. A command that reaches a plugin has to say -Cold and is run as a real
# child process, because a plugin's script block does not survive a runspace that was not the
# one the tool was dot-sourced into.
$script:Harness.Runners = New-Object System.Collections.Generic.List[object]

function Start-CliRunner([string]$Sandbox) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  # stderr is left alone on purpose: a pipe nobody reads deadlocks, and a runner that dies
  # should still be visible in the console the part was started from
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Sta -File "' + (Join-Path $PSScriptRoot 'cli-runner.ps1') + '" -Sandbox "' + $Sandbox + '"'
  $p = [System.Diagnostics.Process]::Start($psi)
  $state = @{ Process = $p; Sandbox = $Sandbox }
  $script:Harness.Runners.Add($state)
  return $state
}

function Invoke-CliRunner($Runner, [string[]]$CliArgs, [switch]$Cold) {
  if ($null -eq $Runner -or $Runner.Process.HasExited) { return '' }
  $req = @{ Args = @($CliArgs); Cold = [bool]$Cold } | ConvertTo-Json -Compress
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $Runner.Process.StandardInput.WriteLine($req)
  $Runner.Process.StandardInput.Flush()
  $line = $Runner.Process.StandardOutput.ReadLine()
  $watch.Stop()
  Add-TestTiming (($CliArgs -join ' ') + $(if ($Cold) { ' [cold]' } else { ' [warm]' })) $watch.ElapsedMilliseconds
  if ([string]::IsNullOrEmpty($line)) { return '' }
  try { return [string](($line | ConvertFrom-Json).Text) } catch { return $line }
}

function Stop-CliRunner($Runner) {
  if ($null -eq $Runner) { return }
  try { $Runner.Process.StandardInput.Close() } catch { }
  try { if (-not $Runner.Process.WaitForExit(5000)) { $Runner.Process.Kill() } } catch { }
  try { $Runner.Process.Dispose() } catch { }
  [void]$script:Harness.Runners.Remove($Runner)
}
# One command per process, never a batch: `-Media` and the plugin verbs are read from the real
# command line, and `& clipboard.ps1 ...` inside a warm process does not answer the same way.

function Test-MutexFree([string]$name) {
  try {
    $m = New-Object System.Threading.Mutex($false, $name)
    $free = $m.WaitOne(0)
    if ($free) { $m.ReleaseMutex() }
    $m.Dispose()
    return $free
  } catch { return $true }
}

# the resident polls the clipboard, so a write can lose the race - retry a few times
function Set-Clip([string]$value) {
  for ($i = 0; $i -lt 6; $i++) {
    try { Set-Clipboard -Value $value -ErrorAction Stop; return $true } catch { Start-Sleep -Milliseconds 150 }
  }
  return $false
}

function Start-TestPart([string]$Source = '', [switch]$ClipShared, [switch]$Quiet, [string]$ProgressFile = '') {
  $here = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
  $repoRoot = Split-Path -Parent $here
  $defaultSource = Join-Path $repoRoot 'src'
  if (-not $Source) { $Source = $defaultSource }
  if (-not (Test-Path -LiteralPath $Source)) { Write-Error ('no such -Source: ' + $Source); exit 2 }
  $script:Harness.RepoRoot = $repoRoot
  $script:Harness.DefaultSource = $defaultSource
  $script:Harness.SrcRoot = (Resolve-Path -LiteralPath $Source).Path
  # a packaged copy has minified function names, so tests\lib\fake-clip.ps1 cannot stand in for lib\clip.ps1
  $script:Harness.IsPackaged = ($script:Harness.SrcRoot -ne (Resolve-Path -LiteralPath $defaultSource).Path)
  $script:Harness.ClipPs1 = Join-Path $script:Harness.SrcRoot 'clipboard.ps1'
  if (-not (Test-Path -LiteralPath $script:Harness.ClipPs1)) { Write-Error ('cannot find ' + $script:Harness.ClipPs1); exit 2 }
  $script:Harness.TmpRoot = Join-Path $env:TEMP ('clipboard-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  # run.ps1 passes this when another part of the same run drives the real clipboard
  $script:Harness.ClipShared = [bool]$ClipShared
  $script:clipShared = [bool]$ClipShared
  New-Item -ItemType Directory -Path $script:Harness.TmpRoot -Force | Out-Null
  $script:Harness.Utf8 = New-Object System.Text.UTF8Encoding $false
  # tests\run.ps1 names the file the progress line reads back; a part started by hand has none
  $script:Harness.ProgressFile = $ProgressFile
  Initialize-TestReporter -Mode 'verbose' -Quiet:$Quiet
  # the number package.ini declares; a package carries it as a constant, so both agree
  $script:Harness.ProgramVersion = ''
  $verFile = Join-Path $repoRoot 'package.ini'
  if (Test-Path -LiteralPath $verFile) {
    $m = [regex]::Match([IO.File]::ReadAllText($verFile), '(?mi)^\s*version\s*=\s*(\S+)\s*$')
    if ($m.Success) { $script:Harness.ProgramVersion = $m.Groups[1].Value }
  }
  # names the blocks use while they run
  $script:repoRoot = $repoRoot
  $script:defaultSource = $defaultSource
  $script:srcRoot = $script:Harness.SrcRoot
  $script:clipPs1 = $script:Harness.ClipPs1
  $script:tmpRoot = $script:Harness.TmpRoot
  $script:Utf8 = $script:Harness.Utf8
  $script:programVersion = $script:Harness.ProgramVersion
  $script:Harness.Started = Get-Date
  # a part started by hand prints what a run prints, one file at a time
  if (-not $Quiet) { Write-TestBanner $script:Harness.ProgramVersion $script:Harness.SrcRoot }
}

function Complete-TestPart([string]$ResultFile = '', [switch]$Quiet) {
  # a part that collected its rows runs them now; the ones still on the old Check form have an
  # empty queue and are already done
  Invoke-TestQueue
  # walking the runner list directly: @($list) over a List[object] throws in 5.1
  foreach ($r in $script:Harness.Runners) { Stop-CliRunner $r }
  $fail = @($script:Results | Where-Object { $_.Result -eq 'FAIL' }).Count
  if ($ResultFile) {
    # ToArray, not @($list): wrapping a List[object] throws "Argument types do not match" in 5.1
    $payload = @{
      Part = $script:Harness.Part; Source = $script:Harness.SrcRoot
      Results = $script:Results.ToArray(); Timings = $script:Harness.Timings.ToArray()
    }
    try {
      [IO.File]::WriteAllText($ResultFile, ($payload | ConvertTo-Json -Depth 4), $script:Harness.Utf8)
    } catch { Write-Output ('[!] cannot write ' + $ResultFile + ': ' + $_.Exception.Message) }
  }
  if (-not $Quiet) {
    $label = $script:Harness.Part + '.ps1'
    $seconds = ((Get-Date) - $script:Harness.Started).TotalSeconds
    Write-TestPartReport $label $script:Results $seconds $script:Harness.Started
  }
  try { Remove-Item -LiteralPath $script:Harness.TmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  if ($fail -gt 0) { exit 1 }
  exit 0
}

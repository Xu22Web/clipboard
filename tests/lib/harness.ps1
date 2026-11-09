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
$script:Harness.Progress = @{ Pass = 0; Fail = 0; Skip = 0; Last = ''; At = [DateTime]::MinValue }

function Write-TestProgressFile {
  $file = [string]$script:Harness.ProgressFile
  if (-not $file) { return }
  $now = Get-Date
  # five writes a second is enough for a progress line and keeps a 579 check part cheap
  if (($now - $script:Harness.Progress.At).TotalMilliseconds -lt 200) { return }
  $script:Harness.Progress.At = $now
  $p = $script:Harness.Progress
  $line = [string]$p['Pass'] + ' ' + [string]$p['Fail'] + ' ' + [string]$p['Skip'] + ' ' + [string]$p['Last']
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
    $pass = @($script:Results | Where-Object { $_.Result -eq 'PASS' }).Count
    $skipped = @($script:Results | Where-Object { $_.Result -eq 'SKIP' }).Count
    $label = $script:Harness.Part + '.ps1'
    $items = @()
    foreach ($r in $script:Results) {
      if ($r.Result -ne 'FAIL') { continue }
      $items += @{ Name = ($label + ' > ' + [string]$r.Group + ' > ' + [string]$r.Test); Detail = [string]$r.Detail }
    }
    $seconds = ((Get-Date) - $script:Harness.Started).TotalSeconds
    Write-TestPartReport $label $pass $fail $skipped $seconds $script:Harness.Started $items
  }
  try { Remove-Item -LiteralPath $script:Harness.TmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  if ($fail -gt 0) { exit 1 }
  exit 0
}

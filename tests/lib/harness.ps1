#Requires -Version 5.1
<#
  tests\lib\harness.ps1 - what every test part needs: a result list, a sandbox, and a way to
  call the command line.

  A part is one file that runs on its own, in its own process, with its own sandbox:

      . "$PSScriptRoot\..\lib\harness.ps1"     (from tests\cli\*.ps1)
      Start-TestPart -Source $Source
      ...checks...
      Complete-TestPart -ResultFile $ResultFile

  That is what lets several parts run at the same time: no shared store, no shared clipboard
  (each sandbox carries tests\lib\fake-clip.ps1), no shared console.
#>

$script:Results = New-Object System.Collections.Generic.List[object]
$script:Harness = @{}

function Add-TestResult([string]$group, [string]$name, [string]$result, [string]$detail) {
  $script:Results.Add([pscustomobject]@{ Group = $group; Test = $name; Result = $result; Detail = $detail })
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

# The compiled client (lib\cbx.cs) is optional, so a part that wants to exercise it asks for
# one here: a package carries its own copy, a source checkout gets one built into %TEMP% once
# per run, and an empty string means "no compiler here" - the caller skips instead of failing.
function Get-CbxExe {
  if ($null -ne $script:Harness.CbxExe) { return $script:Harness.CbxExe }
  $script:Harness.CbxExe = ''
  $beside = Join-Path $script:Harness.SrcRoot 'cbx.exe'
  if (Test-Path -LiteralPath $beside) { $script:Harness.CbxExe = $beside; return $beside }
  $builder = Join-Path $script:Harness.RepoRoot 'scripts\build-cbx.ps1'
  $source = Join-Path $script:Harness.SrcRoot 'lib\cbx.cs'
  if (-not (Test-Path -LiteralPath $builder) -or -not (Test-Path -LiteralPath $source)) { return '' }
  $cache = Join-Path $script:Harness.TmpRoot 'cbx'
  if (-not (Test-Path -LiteralPath $cache)) { New-Item -ItemType Directory -Path $cache -Force | Out-Null }
  $exe = Join-Path $cache 'cbx.exe'
  $stale = $true
  if (Test-Path -LiteralPath $exe) {
    $stale = (Get-Item -LiteralPath $exe).LastWriteTime -lt (Get-Item -LiteralPath $source).LastWriteTime
  }
  if ($stale) {
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder -Source $source -Out $exe 2>&1
  }
  if (Test-Path -LiteralPath $exe) { $script:Harness.CbxExe = $exe }
  return $script:Harness.CbxExe
}

# one CLI call in its own process: a command starts from nothing, the way the user's shell does
function Clip([string]$sandbox, [string[]]$cliArgs) {
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', (Join-Path $sandbox 'clipboard.ps1')) + $cliArgs
  return (& powershell @a 2>&1 | Out-String)
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

function Start-TestPart([string]$Source = '', [switch]$ClipShared) {
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
}

function Complete-TestPart([string]$ResultFile = '', [switch]$Quiet) {
  $fail = @($script:Results | Where-Object { $_.Result -eq 'FAIL' }).Count
  if ($ResultFile) {
    # ToArray, not @($list): wrapping a List[object] throws "Argument types do not match" in 5.1
    $payload = @{ Part = $script:Harness.Part; Source = $script:Harness.SrcRoot; Results = $script:Results.ToArray() }
    try {
      [IO.File]::WriteAllText($ResultFile, ($payload | ConvertTo-Json -Depth 4), $script:Harness.Utf8)
    } catch { Write-Output ('[!] cannot write ' + $ResultFile + ': ' + $_.Exception.Message) }
  }
  if (-not $Quiet) {
    $script:Results | Format-Table -AutoSize -Wrap | Out-String -Width 160 | Write-Output
    $pass = @($script:Results | Where-Object { $_.Result -eq 'PASS' }).Count
    $skipped = @($script:Results | Where-Object { $_.Result -eq 'SKIP' }).Count
    Write-Output ('TOTAL ' + $script:Results.Count + '   PASS ' + $pass + '   FAIL ' + $fail + '   SKIP ' + $skipped)
  }
  try { Remove-Item -LiteralPath $script:Harness.TmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  if ($fail -gt 0) { exit 1 }
  exit 0
}

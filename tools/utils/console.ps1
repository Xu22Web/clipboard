# tools\utils\console.ps1 - one logger for every tool script.
#
# A tool prints five kinds of line, and every tool prints them the same way: a step that is
# starting, a step that finished (with how long it took), a note that explains the step above
# it, a warning that stops nothing, and a failure that does. The bracketed mark stays in front
# of the text whatever the console does, so a redirected log is still greppable, and colour is
# only added on top of it.
#
# Colour is decided once, from what only the console knows: a redirected stream and NO_COLOR
# turn it off, FORCE_COLOR turns it on for a log rendered somewhere else, and an escape
# sequence is used only when the host understands one - otherwise the same line goes out
# through Write-Host -ForegroundColor, which every Windows console has always understood.

$script:Con = @{ Ready = $false; Color = $false; Ansi = $false; Off = $false }

# Windows 10 consoles ignore escape sequences until the mode says otherwise, and Windows
# PowerShell 5.1 has no $PSStyle to ask: kernel32 knows. Any failure here means "no escapes",
# never an error - the same line still prints.
function Test-ConsoleAnsi {
  try {
    if (-not ('CbTool.Vt' -as [type])) {
      Add-Type -Namespace CbTool -Name Vt -ErrorAction Stop -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr h, uint mode);
'@
    }
    $handle = [CbTool.Vt]::GetStdHandle(-11)
    $mode = [uint32]0
    if (-not [CbTool.Vt]::GetConsoleMode($handle, [ref]$mode)) { return $false }
    if (($mode -band 0x0004) -eq 0) { return [bool][CbTool.Vt]::SetConsoleMode($handle, ($mode -bor 0x0004)) }
    return $true
  } catch { return $false }
}

# Once per process: the probe costs an Add-Type the first time and nothing afterwards.
function Initialize-Console {
  if ($script:Con.Ready) { return }
  $script:Con.Ready = $true
  $redirected = $false
  try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $true }
  $forced = ($env:FORCE_COLOR -and $env:FORCE_COLOR -ne '0')
  if ($env:NO_COLOR) { $script:Con.Off = $true }
  if ($script:Con.Off) { return }
  if ($redirected -and -not $forced) { return }
  $script:Con.Color = $true
  $script:Con.Ansi = $forced -or (Test-ConsoleAnsi)
}

# The one place a line is written. $code is the ANSI colour, $fallback the ConsoleColor used
# when the host has no escape sequences; both name the same colour, so only the mechanism
# differs and a console that takes neither still gets the plain mark.
function Write-Line([string]$mark, [string]$text, [int]$code, [string]$fallback) {
  Initialize-Console
  if (-not $script:Con.Color) {
    if ($mark) { Write-Host ($mark + ' ' + $text) } else { Write-Host $text }
    return
  }
  if ($script:Con.Ansi) {
    $e = [char]27
    if ($mark) { Write-Host ($e + '[' + $code + 'm' + $mark + $e + '[0m ' + $text) }
    else { Write-Host ($e + '[' + $code + 'm' + $text + $e + '[0m') }
    return
  }
  if ($mark) { Write-Host ($mark + ' ' + $text) -ForegroundColor $fallback }
  else { Write-Host $text -ForegroundColor $fallback }
}

function Write-Step([string]$text) { Write-Line '[..]' $text 36 'Cyan' }
function Write-Ok([string]$text) { Write-Line '[ok]' $text 32 'Green' }
function Write-Warn([string]$text) { Write-Line '[!]' $text 33 'Yellow' }
function Write-Fail([string]$text) { Write-Line '[x]' $text 31 'Red' }
# a note is dim and indented: it belongs to the step above it, not to the run
function Write-Note([string]$text) { Write-Line '' ('  ' + $text) 90 'DarkGray' }
# a heading: the tool name and its version, in the accent colour
function Write-Title([string]$text) { Write-Line '' $text 36 'Cyan' }
# plain text: a table, or a line the caller already shaped
function Write-Text([string]$text) { Write-Host $text }

# A cyan key and a plain value on one line, padded to $width so a list of them lines up.
function Write-Pair([string]$key, [string]$value, [int]$width) {
  Initialize-Console
  if ($width -lt $key.Length) { $width = $key.Length }
  $pad = $key + (' ' * ($width - $key.Length)) + ' '
  if (-not $script:Con.Color) { Write-Host ('  ' + $pad + $value); return }
  if ($script:Con.Ansi) {
    $e = [char]27
    Write-Host ('  ' + $e + '[36m' + $pad + $e + '[0m' + $value)
    return
  }
  Write-Host ('  ' + $pad) -NoNewline -ForegroundColor Cyan
  Write-Host $value
}

# "840 ms" / "1.23 s": a step that took under a second reads in milliseconds, so a short one
# never rounds down to "0 s" and a long one never prints five decimals.
function Format-Duration([double]$ms) {
  if ($ms -lt 0) { $ms = 0 }
  if ($ms -lt 1000) { return ([string][int][Math]::Round($ms) + ' ms') }
  return ([string][Math]::Round($ms / 1000, 2) + ' s')
}

function Start-Step { return [Diagnostics.Stopwatch]::StartNew() }

# A finished step keeps the mark of a success and gains the time on the right, the way a build
# tool ends every row. A missing stopwatch is a step with nothing to measure.
function Write-Done($sw, [string]$text) {
  if ($null -eq $sw) { Write-Ok $text; return }
  try { $sw.Stop() } catch { }
  Write-Ok ($text + '   ' + (Format-Duration $sw.Elapsed.TotalMilliseconds))
}

# The two lines a package runner prints before a script starts: what is about to run and what
# will actually be executed. The wait for a fresh PowerShell then has an explanation.
function Write-Command([string]$title, [string]$shown, [string]$line) {
  Initialize-Console
  if (-not $script:Con.Color) {
    Write-Host ('> ' + $title + ' ' + $shown)
    Write-Host ('> ' + $line)
    Write-Host ''
    return
  }
  if ($script:Con.Ansi) {
    $e = [char]27
    Write-Host ($e + '[90m> ' + $e + '[0m' + $title + ' ' + $e + '[36m' + $shown + $e + '[0m')
    Write-Host ($e + '[90m> ' + $line + $e + '[0m')
    Write-Host ''
    return
  }
  Write-Host '> ' -NoNewline -ForegroundColor DarkGray
  Write-Host ($title + ' ' + $shown) -ForegroundColor Cyan
  Write-Host ('> ' + $line) -ForegroundColor DarkGray
  Write-Host ''
}

function Fail([string]$text) { Write-Fail $text; exit 1 }

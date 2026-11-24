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
#
# Every line also has a level, and one threshold decides what reaches the console: a tool that
# was asked to be quiet still prints the things that went wrong, and nothing else. A stamp is
# off by default and turned on by the one tool that runs for a long time.

# silent < error < warn < info, the same ladder a bundler's logger has: a line is printed when
# its own level is at or below the threshold
$script:LogLevels = @{ silent = 0; error = 1; warn = 2; info = 3 }

$script:Con = @{
  Ready     = $false
  Color     = $false
  Ansi      = $false
  Off       = $false
  Level     = 3          # info
  Timestamp = $false
}

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

# The threshold: 'silent', 'error', 'warn' or 'info'. An unknown value is ignored, so a typo
# in an environment variable cannot silence the tool.
function Set-LogLevel([string]$Level) {
  $name = ([string]$Level).Trim().ToLowerInvariant()
  if (-not $name -or -not $script:LogLevels.ContainsKey($name)) { return }
  $script:Con.Level = [int]$script:LogLevels[$name]
}

# What a tool starts with: CLIPBOARD_LOG_LEVEL for a whole shell, then its own switches, which
# win. One call at the top of a tool is enough for both.
function Set-LogLevelFrom([switch]$Silent, [switch]$Quiet) {
  if ($env:CLIPBOARD_LOG_LEVEL) { Set-LogLevel $env:CLIPBOARD_LOG_LEVEL }
  if ($Silent) { Set-LogLevel 'silent' }
  elseif ($Quiet) { Set-LogLevel 'warn' }
}

function Test-LogEnabled([string]$type) {
  if (-not $script:LogLevels.ContainsKey($type)) { return $true }
  return ($script:Con.Level -ge [int]$script:LogLevels[$type])
}

# A stamp belongs to a tool that keeps running (dev), not to a build that takes twenty seconds.
function Enable-LogTimestamp([switch]$On) {
  if ($PSBoundParameters.ContainsKey('On')) { $script:Con.Timestamp = [bool]$On; return }
  $script:Con.Timestamp = $true
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
function Write-Line([string]$type, [string]$mark, [string]$text, [int]$code, [string]$fallback) {
  Initialize-Console
  if (-not (Test-LogEnabled $type)) { return }
  $stamp = ''
  if ($script:Con.Timestamp) { $stamp = (Get-Date).ToString('HH:mm:ss') + ' ' }
  if (-not $script:Con.Color) {
    if ($mark) { Write-Host ($stamp + $mark + ' ' + $text) } else { Write-Host ($stamp + $text) }
    return
  }
  if ($script:Con.Ansi) {
    $e = [char]27
    $head = ''
    if ($stamp) { $head = $e + '[90m' + $stamp.TrimEnd() + $e + '[0m ' }
    if ($mark) { Write-Host ($head + $e + '[' + $code + 'm' + $mark + $e + '[0m ' + $text) }
    else { Write-Host ($head + $e + '[' + $code + 'm' + $text + $e + '[0m') }
    return
  }
  if ($stamp) { Write-Host $stamp -NoNewline -ForegroundColor DarkGray }
  if ($mark) { Write-Host ($mark + ' ' + $text) -ForegroundColor $fallback }
  else { Write-Host $text -ForegroundColor $fallback }
}

function Write-Step([string]$text) { Write-Line 'info' '[..]' $text 36 'Cyan' }
function Write-Ok([string]$text) { Write-Line 'info' '[ok]' $text 32 'Green' }
function Write-Warn([string]$text) { Write-Line 'warn' '[!]' $text 33 'Yellow' }
function Write-Fail([string]$text) { Write-Line 'error' '[x]' $text 31 'Red' }
# a note is dim and indented: it belongs to the step above it, not to the run
function Write-Note([string]$text) { Write-Line 'info' '' ('  ' + $text) 90 'DarkGray' }
# a heading: the tool name and its version, in the accent colour
function Write-Title([string]$text) { Write-Line 'info' '' $text 36 'Cyan' }
# A data line: a table or a heading the tool shaped itself. It belongs to the run, so -Quiet
# takes it away with the steps it belongs to.
function Write-Text([string]$text) {
  Initialize-Console
  if (-not (Test-LogEnabled 'info')) { return }
  Write-Host $text
}

# Raw text a tool passes on unchanged, such as the output of the program it measured: not a log
# line of this tool, and never dropped because this tool was asked to be quiet.
function Write-Raw([string]$text) { Write-Host $text }

# A cyan key and a plain value on one line, padded to $width so a list of them lines up.
function Write-Pair([string]$key, [string]$value, [int]$width) {
  Initialize-Console
  if (-not (Test-LogEnabled 'info')) { return }
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
  if (-not (Test-LogEnabled 'info')) { return }
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

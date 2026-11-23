#Requires -Version 5.1
<#
  tools\shot.ps1 - refresh the screenshots in docs\\.

      cli shot                          every surface
      cli shot -Part panel              only the history panel, both themes
      cli shot -Part tray,settings      two surfaces
      cli shot -Theme light -Part panel one theme
      cli shot -Select 7                row to leave selected (1 = first row)
      cli shot -PreviewRow 5            row the hover card is taken from
      cli shot -Language zh-CN          a language: docs\zh-cn\, and Chinese example rows
      cli shot -KeepBox                 keep the temporary sandbox for inspection

  Every shot is taken from a throw-away copy of src\: the store is seeded with example rows
  (fixed ages, one pinned row, one starred row), the copy carries its own named objects
  (Local\clipboard.shot.*) and lives under %PUBLIC%, so a resident that is already running
  neither blocks it nor can be photographed by it. Only windows of the copy's own processes
  are captured. The real data folder, clipboard.ini and the real clipboard are never read.

  Files: screenshot-dark.png / screenshot-light.png (history panel), screenshot-compact.png,
  screenshot-preview.png (hover card), screenshot-tray.png, screenshot-settings.png. English
  writes them to docs\, any other language to docs\<code>\ - the two sets are what the two
  READMEs show.
#>
[CmdletBinding()]
param(
  [ValidateSet('dark', 'light', 'both')][string]$Theme = 'both',
  # a comma separated list: -File hands the arguments over as plain strings
  [string]$Part = 'all',
  [int]$Select = 7,
  [int]$PreviewRow = 5,
  # a language code from src\lang; empty keeps the program default (en)
  [string]$Language = '',
  [switch]$KeepBox,
  # quiet keeps warnings and failures, silent keeps failures only
  [switch]$Quiet,
  [switch]$Silent
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Shot {
  public delegate bool Cb(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(Cb f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool on);
  [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool altTab);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
'@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'tools\utils\console.ps1')
Set-LogLevelFrom -Quiet:$Quiet -Silent:$Silent
$srcDir = Join-Path $root 'src'
$docsDir = Join-Path $root 'docs'
# a non-English set is its own folder, so a README in that language can point at it and the
# English files keep the names they always had
if ($Language -and $Language -ne 'en') {
  $docsDir = Join-Path $docsDir $Language.ToLowerInvariant()
  if (-not (Test-Path -LiteralPath $docsDir)) { New-Item -ItemType Directory -Path $docsDir -Force | Out-Null }
}
$rsChar = [string][char]30
$usChar = [string][char]31
$utf8 = New-Object System.Text.UTF8Encoding $false
# The copy answers to names of its own: a resident that is already running keeps its windows
# and its hotkey, and this tool cannot photograph the real history by accident. The suffix is
# per run, not per tool: a run that crashed left its resident holding the mutex, and every later
# run then started a copy that saw "already running" and died before its window appeared.
$shotPrefix = 'Local\clipboard.shot.' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.'

$partNames = @('all', 'panel', 'compact', 'preview', 'tray', 'settings')
$parts = @(($Part -split ',') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
foreach ($one in $parts) {
  if ($partNames -notcontains $one) { throw ('unknown part: ' + $one + ' (one of ' + ($partNames -join ', ') + ')') }
}

function Test-Part([string]$name) {
  return (($parts -contains 'all') -or ($parts -contains $name))
}

# The panel is a no-activate window that refuses to open over the taskbar or a shell flyout,
# so the shot needs something ordinary in front of it. This form is that: a plain window with
# a focused edit box, which also gives the compact form the caret it anchors to.
function Wait-Pump([int]$ms) {
  $until = (Get-Date).AddMilliseconds($ms)
  while ((Get-Date) -lt $until) {
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 20
  }
}

function New-ShotHost {
  $form = New-Object Windows.Forms.Form
  $form.Text = 'clipboard shot'
  $form.FormBorderStyle = 'FixedToolWindow'
  $form.StartPosition = 'Manual'
  $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $form.Left = $area.Left + 120
  $form.Top = $area.Top + 140
  $form.ClientSize = New-Object Drawing.Size 380, 150
  $box = New-Object Windows.Forms.TextBox
  $box.Multiline = $true
  $box.SetBounds(16, 16, 340, 110)
  $box.Text = ('The history panel opens beside this window. ' + [Environment]::NewLine + 'Nothing in it is part of the capture.')
  [void]$form.Controls.Add($box)
  $form.Show()
  # The panel refuses to open over the taskbar, and the taskbar is what owns the foreground
  # after the hidden console processes above came and went. SwitchToThisWindow is what Alt-Tab
  # uses, so it hands the foreground over without an input event; SetForegroundWindow alone is
  # rejected by the foreground lock, and attaching to the owning thread does not lift it here.
  [void][Shot]::SwitchToThisWindow($form.Handle, $true)
  Wait-Pump 200
  if ([Shot]::GetForegroundWindow() -ne $form.Handle) {
    $fg = [Shot]::GetForegroundWindow()
    $fgTid = [uint32]0
    if ($fg -ne [IntPtr]::Zero) { [void][Shot]::GetWindowThreadProcessId($fg, [ref]$fgTid) }
    $myTid = [Shot]::GetCurrentThreadId()
    $attached = $false
    if ($fgTid -ne 0 -and $fgTid -ne $myTid) { $attached = [Shot]::AttachThreadInput($myTid, $fgTid, $true) }
    try { [void][Shot]::SetForegroundWindow($form.Handle) }
    finally { if ($attached) { [void][Shot]::AttachThreadInput($myTid, $fgTid, $false) } }
    Wait-Pump 200
  }
  [void]$box.Focus()
  Wait-Pump 300
  if ([Shot]::GetForegroundWindow() -ne $form.Handle) { Write-Warn 'the shot window could not take the foreground' }
  return $form
}

# --- one throw-away copy of the program ------------------------------------------
function New-ShotBox([string]$themeName, [switch]$Compact) {
  # under %PUBLIC% rather than %TEMP%: no screenshot may carry a real user profile in it
  $base = if ($env:PUBLIC) { $env:PUBLIC } else { $env:TEMP }
  $box = Join-Path $base ('clipboard-shot-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
  New-Item -ItemType Directory -Path $box -Force | Out-Null
  foreach ($f in @('clipboard.ps1', 'clipboard.cmd')) {
    Copy-Item -LiteralPath (Join-Path $srcDir $f) -Destination $box -Force
  }
  foreach ($d in @('lib', 'utils', 'schema', 'plugins', 'themes', 'lang')) {
    Copy-Item -LiteralPath (Join-Path $srcDir $d) -Destination $box -Recurse -Force
  }
  # the version comes from package.ini, so the footer of the screenshot shows the real number
  $pkg = Join-Path $root 'package.ini'
  if (Test-Path -LiteralPath $pkg) { Copy-Item -LiteralPath $pkg -Destination $box -Force }
  $basePs = Join-Path $box 'lib\base.ps1'
  $text = [IO.File]::ReadAllText($basePs, $utf8)
  [IO.File]::WriteAllText($basePs, $text.Replace('Local\clipboard.', $shotPrefix), $utf8)
  $ini = "Theme=$themeName`r`nRows=10`r`nWindowWidth=700`r`n"
  if ($Language) { $ini += "Language=$Language`r`n" }
  if ($Compact) { $ini += "CompactMode=1`r`n" }
  [IO.File]::WriteAllText((Join-Path $box 'clipboard.ini'), $ini, $utf8)
  return $box
}

function Remove-ShotBox([string]$box) {
  if ($KeepBox) { Write-Note ('kept ' + $box); return }
  # the copy's processes may still be closing their log file: one delete attempt can leave a
  # folder behind, and nothing would ever remove it again
  for ($i = 0; $i -lt 6; $i++) {
    Remove-Item -LiteralPath $box -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $box)) { return }
    Start-Sleep -Milliseconds 400
  }
  Write-Warn ('the sandbox could not be removed: ' + $box)
}

function Invoke-Sandbox([string]$box, [string[]]$cliArgs) {
  $entry = Join-Path $box 'clipboard.ps1'
  return (& powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $entry @cliArgs 2>&1 | Out-String)
}

# --- example history -------------------------------------------------------------
# One `put` first: the record it writes carries the same clock the panel uses for relative
# times, so the seeded ages below are exact.
# The example rows follow the language of the screenshot: a Chinese panel full of English
# sentences reads as a translation nobody checked. The words live in the language file (they are
# not ASCII, so they cannot live here), and "\\n" in one of them is a line break. The same reader
# finds the window titles, so a window is waited for by the name the language gives it.
function Get-LangWord([string]$box, [string]$Section, [string]$key) {
  $code = if ($Language) { $Language } else { 'en' }
  $path = Join-Path (Join-Path $box 'lang') ($code + '.ini')
  if (-not (Test-Path -LiteralPath $path)) { return '' }
  $sec = ''
  foreach ($line in [IO.File]::ReadAllLines($path, $utf8)) {
    $t = $line.Trim()
    if ($t.StartsWith('[')) { $sec = $t.Trim('[', ']'); continue }
    if ($sec -ne $Section -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -lt 1) { continue }
    if ($t.Substring(0, $i).Trim() -ne $key) { continue }
    return ($t.Substring($i + 1).Trim() -replace '\\n', "`n")
  }
  return ''
}

function Set-Seed {
  param([string]$box)
  # the rest - a URL, a path, a command, a JSON line, an address, a colour - is the same in both
  # sets, so only the two prose rows are read from the language file
  $releaseList = Get-LangWord $box 'sample' 'list'
  $aboutText = Get-LangWord $box 'sample' 'about'
  [void](Invoke-Sandbox $box @('put', 'clock probe'))
  $storePath = Join-Path (Join-Path $box 'data') 'history.dat'
  $chunks = @([IO.File]::ReadAllText($storePath, $utf8) -split [regex]::Escape($rsChar))
  $toolNow = [long](@($chunks[2] -split [regex]::Escape($usChar))[1])
  $rows = @(
    @{ Age = 120; Flags = 'tp'; Text = 'https://github.com/PowerShell/PowerShell/releases/tag/v7.4.6' }
    @{ Age = 840; Flags = 't'; Text = 'C:\Users\alex\Documents\release-notes.md' }
    @{ Age = 2220; Flags = 't'; Text = 'Get-ChildItem -Path .\src -Recurse -Filter *.ps1 | Measure-Object' }
    @{ Age = 7200; Flags = 't'; Text = 'npm run build -- --outDir dist' }
    @{ Age = 10800; Flags = 'ts'; Text = $releaseList }
    @{ Age = 18000; Flags = 't'; Text = '{"theme":"win11-dark","rows":10,"width":700}' }
    @{ Age = 28800; Flags = 't'; Text = 'alex@example.com' }
    @{ Age = 39600; Flags = 't'; Text = 'https://learn.microsoft.com/windows/apps/design/style/color' }
    @{ Age = 50400; Flags = 't'; Text = $aboutText }
    @{ Age = 61200; Flags = 't'; Text = '#5AC8FA' }
  )
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('CBHIST').Append($rsChar).Append('1')
  foreach ($row in $rows) {
    [void]$sb.Append($rsChar).Append($row.Flags).Append($usChar)
    [void]$sb.Append([string]($toolNow - $row.Age)).Append($usChar).Append($usChar).Append([string]$row.Text)
  }
  [IO.File]::WriteAllText($storePath, $sb.ToString(), $utf8)
}

# --- windows ---------------------------------------------------------------------
# Only windows of the sandbox's own processes are ever looked at: the name is filtered first,
# the owning process second, so a resident that is already running cannot be photographed.
function Find-Window {
  param([int]$ProcId = 0, [string]$Title = '')
  $script:wantPid = $ProcId
  $script:wantTitle = $Title
  $script:foundWin = [IntPtr]::Zero
  $cb = [Shot+Cb] {
    param($w, $l)
    if (-not [Shot]::IsWindowVisible($w)) { return $true }
    if ($script:wantPid -ne 0) {
      $owner = [uint32]0
      [void][Shot]::GetWindowThreadProcessId($w, [ref]$owner)
      if ([int]$owner -ne $script:wantPid) { return $true }
    }
    $sb = New-Object System.Text.StringBuilder 256
    [void][Shot]::GetWindowText($w, $sb, 256)
    if ($sb.ToString() -ceq $script:wantTitle) { $script:foundWin = $w; return $false }
    return $true
  }
  [void][Shot]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:foundWin
}

function Wait-Window {
  param([int]$ProcId = 0, [string]$Title = '', [int]$Tries = 60, [int]$Step = 200)
  for ($i = 0; $i -lt $Tries; $i++) {
    $h = Find-Window -ProcId $ProcId -Title $Title
    if ($h -ne [IntPtr]::Zero) { return $h }
    Wait-Pump $Step
  }
  return [IntPtr]::Zero
}

function Get-WindowRect([IntPtr]$Handle) {
  $rect = New-Object Shot+RECT
  [void][Shot]::GetWindowRect($Handle, [ref]$rect)
  return $rect
}

# The card measures itself from its content, and that content arrives from a background job: the
# window exists some frames before it has the size it will keep, so the shot waits for it to
# stop changing rather than capturing whichever stage the timer landed on.
function Wait-StableWindow([IntPtr]$Handle, [int]$Tries = 25, [int]$Step = 200) {
  $last = [int64]-1
  $same = 0
  for ($i = 0; $i -lt $Tries; $i++) {
    $rect = Get-WindowRect $Handle
    $sig = [int64]($rect.Right - $rect.Left) * 10000 + [int64]($rect.Bottom - $rect.Top)
    if ($sig -eq $last) { $same++ } else { $same = 0; $last = $sig }
    if ($same -ge 3) { return $rect }
    Wait-Pump $Step
  }
  return (Get-WindowRect $Handle)
}

function Save-Window([IntPtr]$Handle, [string]$Name) {
  $rect = Get-WindowRect $Handle
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  if ($width -le 0 -or $height -le 0) { throw ('no window rect for ' + $Name) }
  $bmp = New-Object Drawing.Bitmap $width, $height
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
  $g.Dispose()
  $out = Join-Path $docsDir $Name
  $bmp.Save($out, [Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Ok ($out + '   ' + $width + 'x' + $height)
}

# --- resident + panel ------------------------------------------------------------
function Start-Resident([string]$box) {
  $child = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', (Join-Path $box 'clipboard.ps1'), 'serve')
  $up = $false
  for ($i = 0; $i -lt 40 -and -not $up; $i++) {
    Start-Sleep -Milliseconds 400
    if ((Invoke-Sandbox $box @('status')) -match 'resident    : running') { $up = $true }
  }
  if (-not $up) { throw 'the resident did not start' }
  return $child
}

function Stop-Resident([string]$box, $child) {
  [void](Invoke-Sandbox $box @('stop'))
  for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Milliseconds 300
    if ((Invoke-Sandbox $box @('status')) -match 'resident    : not running') { break }
  }
  if ($null -ne $child -and -not $child.HasExited) { try { $child.Kill() } catch { } }
}

function Show-Panel($box, $child) {
  $shown = $false
  for ($i = 0; $i -lt 30 -and -not $shown; $i++) {
    try {
      $e = [System.Threading.EventWaitHandle]::OpenExisting($shotPrefix + 'show')
      [void]$e.Set()
      $e.Dispose()
      $shown = $true
    } catch { Wait-Pump 200 }
  }
  if (-not $shown) { throw 'the show event never appeared' }
  $panelTitle = Get-LangWord $box 'panel' 'title'
  if (-not $panelTitle) { $panelTitle = 'Clipboard history' }
  $handle = Wait-Window -ProcId $child.Id -Title $panelTitle
  if ($handle -eq [IntPtr]::Zero) {
    # the log says why the panel refused to open, which is the only place that says it
    $tail = ''
    $logPath = Join-Path (Join-Path $box 'data') 'clipboard.log'
    if (Test-Path -LiteralPath $logPath) {
      $tail = ((Get-Content -LiteralPath $logPath -Tail 6) -join [Environment]::NewLine)
    }
    throw ('the panel never appeared' + [Environment]::NewLine + $tail)
  }
  Wait-Pump 900
  return $handle
}

# select a row with a real click: injected arrow keys would go through the panel's key hook
# and can leave characters in the search box
function Click-Row([IntPtr]$Handle, [int]$Row) {
  if ($Row -le 1) { return }
  $rect = Get-WindowRect $Handle
  [void][Shot]::SetCursorPos(($rect.Left + 200), ($rect.Top + 68 + (40 * ($Row - 1)) + 20))
  Wait-Pump 120
  [Shot]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Wait-Pump 60
  [Shot]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Wait-Pump 500
}

function Close-Panel {
  [Shot]::keybd_event(0x1B, 0, 0, [IntPtr]::Zero)
  Wait-Pump 60
  [Shot]::keybd_event(0x1B, 0, 2, [IntPtr]::Zero)
  Wait-Pump 600
}

# park the pointer off the panel: a row under it would paint the hover state into the shot
function Park-Cursor([IntPtr]$Handle) {
  $rect = Get-WindowRect $Handle
  [void][Shot]::SetCursorPos(($rect.Right + 60), ($rect.Top + 40))
  Wait-Pump 400
}

# --- one shot per surface --------------------------------------------------------
function Save-PanelShot([string]$themeName) {
  $box = New-ShotBox ('win11-' + $themeName)
  try {
    Set-Seed $box
    $child = Start-Resident $box
    $hostForm = $null
    try {
      $hostForm = New-ShotHost
      $handle = Show-Panel $box $child
      Click-Row $handle $Select
      Park-Cursor $handle
      Save-Window $handle ('screenshot-' + $themeName + '.png')
      Close-Panel
    } finally {
      Stop-Resident $box $child
      if ($null -ne $hostForm) { try { $hostForm.Close(); $hostForm.Dispose() } catch { } }
    }
  } finally { Remove-ShotBox $box }
}

function Save-CompactShot {
  $box = New-ShotBox 'win11-dark' -Compact
  try {
    Set-Seed $box
    $child = Start-Resident $box
    $hostForm = $null
    try {
      $hostForm = New-ShotHost
      $handle = Show-Panel $box $child
      Park-Cursor $handle
      Save-Window $handle 'screenshot-compact.png'
      Close-Panel
    } finally {
      Stop-Resident $box $child
      if ($null -ne $hostForm) { try { $hostForm.Close(); $hostForm.Dispose() } catch { } }
    }
  } finally { Remove-ShotBox $box }
}

function Save-PreviewShot {
  $box = New-ShotBox 'win11-dark'
  try {
    Set-Seed $box
    $child = Start-Resident $box
    $hostForm = $null
    try {
      $hostForm = New-ShotHost
      $handle = Show-Panel $box $child
      $rect = Get-WindowRect $handle
      # the card follows a pointer that stops: no click, only the hover
      [void][Shot]::SetCursorPos(($rect.Left + 200), ($rect.Top + 68 + (40 * ($PreviewRow - 1)) + 20))
      $cardTitle = Get-LangWord $box 'panel' 'preview.title'
      if (-not $cardTitle) { $cardTitle = 'clipboard preview' }
      $card = Wait-Window -ProcId $child.Id -Title $cardTitle -Tries 40
      if ($card -eq [IntPtr]::Zero) { Write-Warn 'the hover card did not appear' }
      else {
        [void](Wait-StableWindow $card)
        Wait-Pump 300
        Save-Window $card 'screenshot-preview.png'
      }
      Park-Cursor $handle
      Close-Panel
    } finally {
      Stop-Resident $box $child
      if ($null -ne $hostForm) { try { $hostForm.Close(); $hostForm.Dispose() } catch { } }
    }
  } finally { Remove-ShotBox $box }
}

function Save-TrayShot {
  $box = New-ShotBox 'win11-dark'
  try {
    # the store is seeded so the header carries a count; no resident is needed for the menu
    Set-Seed $box
    $hostScript = Join-Path $box 'shot-menu.ps1'
    [IO.File]::WriteAllText($hostScript, $trayHost, $utf8)
    $out = Join-Path $docsDir 'screenshot-tray.png'
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $hostScript $out | Out-Null
    if (-not (Test-Path -LiteralPath $out)) { Write-Warn 'the tray menu was not captured'; return }
    Write-Ok ($out + '   ' + (Get-Item -LiteralPath $out).Length + ' bytes')
  } finally { Remove-ShotBox $box }
}

function Save-SettingsShot {
  $box = New-ShotBox 'win11-dark'
  try {
    $child = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', (Join-Path $box 'clipboard.ps1'), 'settings', 'Clipboard')
    $setTitle = Get-LangWord $box 'settings' 'window.title'
    if (-not $setTitle) { $setTitle = 'Settings' }
    $handle = Wait-Window -ProcId $child.Id -Title $setTitle -Tries 60 -Step 250
    if ($handle -eq [IntPtr]::Zero) { throw 'the settings window never appeared' }
    Start-Sleep -Milliseconds 900
    # CopyFromScreen reads whatever is on top, and a window that opened behind the editor would be
    # photographed as the editor. SwitchToThisWindow alone is refused by the foreground lock when
    # the click that started this came from elsewhere, so a click on the window's own header does
    # the lifting - the same thing the panel shot does.
    for ($k = 0; $k -lt 4; $k++) {
      if ([Shot]::GetForegroundWindow() -eq $handle) { break }
      $wr = Get-WindowRect $handle
      [void][Shot]::SetCursorPos(($wr.Left + 40), ($wr.Top + 12))
      Wait-Pump 80
      [Shot]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
      Wait-Pump 60
      [Shot]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
      Wait-Pump 300
      [void][Shot]::SwitchToThisWindow($handle, $true)
      Wait-Pump 300
    }
    Start-Sleep -Milliseconds 400
    Save-Window $handle 'screenshot-settings.png'
    [void][Shot]::PostMessage($handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    for ($i = 0; $i -lt 20; $i++) {
      Start-Sleep -Milliseconds 250
      if ($child.HasExited) { break }
    }
    if (-not $child.HasExited) { try { $child.Kill() } catch { } }
  } finally { Remove-ShotBox $box }
}

# The menu is shown by the copy itself: a drop-down has no title to find it by, and its own
# bounds are the only rect that matters. Run as a child process so this script keeps one
# message loop of its own.
$trayHost = @'
param([string]$Out)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $PSScriptRoot 'clipboard.ps1') -Library
Load-Forms
Add-Native
Initialize-Dpi
Apply-Theme
$dm = New-TrayMenu (New-TrayMenuSkin)
Update-TrayMenu $dm -Entries @(Get-Records).Count -Hotkey 'Ctrl+Alt+V' -Paused $false -Compact $false
$dm.Menu.Show(300, 260)
for ($i = 0; $i -lt 15; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }
$b = $dm.Menu.Bounds
$bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
$g = [Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
$g.Dispose()
$bmp.Save($Out, [Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
$dm.Menu.Close()
'@

$cursor = New-Object Shot+POINT
[void][Shot]::GetCursorPos([ref]$cursor)
try {
  if (Test-Part 'tray') { Save-TrayShot }
  if (Test-Part 'settings') { Save-SettingsShot }
  if (Test-Part 'compact') { Save-CompactShot }
  if (Test-Part 'preview') { Save-PreviewShot }
  if (Test-Part 'panel') {
    $themes = @()
    if ($Theme -eq 'both') { $themes = @('dark', 'light') } else { $themes = @($Theme) }
    foreach ($t in $themes) { Save-PanelShot $t }
  }
} finally {
  # the shots move the real pointer; it goes back where the user left it
  [void][Shot]::SetCursorPos($cursor.X, $cursor.Y)
}

#Requires -Version 5.1
<#
  scripts\shot.ps1 - refresh docs\screenshot-dark.png and screenshot-light.png.

      xpm shot                 both themes
      xpm shot -Theme light    one theme
      xpm shot -Select 7       row to leave selected (1 = first row)
      xpm shot -KeepBox        keep the temporary sandbox for inspection

  The shot is taken from a throw-away copy of src\ in %TEMP%: the store is seeded with
  example rows (fixed ages, one pinned row, one starred row), the resident is started from
  that copy, the panel is opened through its show event and the window is captured with
  CopyFromScreen. The real data folder and clipboard.ini are never touched.
#>
[CmdletBinding()]
param(
  [ValidateSet('dark', 'light', 'both')][string]$Theme = 'both',
  [int]$Select = 7,
  [switch]$KeepBox
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
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$srcDir = Join-Path $root 'src'
$docsDir = Join-Path $root 'docs'
$rsChar = [string][char]30
$usChar = [string][char]31
$utf8 = New-Object System.Text.UTF8Encoding $false

# --- one throw-away copy of the program ------------------------------------------
function New-ShotBox([string]$themeName) {
  $box = Join-Path $env:TEMP ('clipboard-shot-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
  New-Item -ItemType Directory -Path $box -Force | Out-Null
  foreach ($f in @('clipboard.ps1', 'clipboard.cmd')) {
    Copy-Item -LiteralPath (Join-Path $srcDir $f) -Destination $box -Force
  }
  foreach ($d in @('lib', 'utils', 'schema', 'plugins', 'themes')) {
    Copy-Item -LiteralPath (Join-Path $srcDir $d) -Destination $box -Recurse -Force
  }
  # the version comes from package.ini, so the footer of the screenshot shows the real number
  $pkg = Join-Path $root 'package.ini'
  if (Test-Path -LiteralPath $pkg) { Copy-Item -LiteralPath $pkg -Destination $box -Force }
  [IO.File]::WriteAllText((Join-Path $box 'clipboard.ini'), ("Theme=$themeName`r`nRows=10`r`nWindowWidth=700`r`n"), $utf8)
  return $box
}

function Invoke-Sandbox([string]$box, [string[]]$cliArgs) {
  $entry = Join-Path $box 'clipboard.ps1'
  return (& powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $entry @cliArgs 2>&1 | Out-String)
}

# --- example history -------------------------------------------------------------
# One `put` first: the record it writes carries the same clock the panel uses for relative
# times, so the seeded ages below are exact.
function Set-Seed {
  param([string]$box)
  [void](Invoke-Sandbox $box @('put', 'clock probe'))
  $storePath = Join-Path (Join-Path $box 'data') 'history.dat'
  $chunks = @([IO.File]::ReadAllText($storePath, $utf8) -split [regex]::Escape($rsChar))
  $toolNow = [long](@($chunks[2] -split [regex]::Escape($usChar))[1])
  $rows = @(
    @{ Age = 120; Flags = 'tp'; Text = 'https://github.com/PowerShell/PowerShell/releases/tag/v7.4.6' }
    @{ Age = 840; Flags = 't'; Text = 'C:\Users\alex\Documents\release-notes.md' }
    @{ Age = 2220; Flags = 't'; Text = 'Get-ChildItem -Path .\src -Recurse -Filter *.ps1 | Measure-Object' }
    @{ Age = 7200; Flags = 't'; Text = 'npm run build -- --outDir dist' }
    @{ Age = 10800; Flags = 'ts'; Text = "release checklist`n- bump the version`n- run the full test suite`n- tag the release" }
    @{ Age = 18000; Flags = 't'; Text = '{"theme":"win11-dark","rows":10,"width":700}' }
    @{ Age = 28800; Flags = 't'; Text = 'alex@example.com' }
    @{ Age = 39600; Flags = 't'; Text = 'https://learn.microsoft.com/windows/apps/design/style/color' }
    @{ Age = 50400; Flags = 't'; Text = 'Text, file lists, pictures and formatted text are captured from the clipboard.' }
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

# --- resident + panel ------------------------------------------------------------
function Find-Panel {
  $script:panel = [IntPtr]::Zero
  $cb = [Shot+Cb] {
    param($w, $l)
    if (-not [Shot]::IsWindowVisible($w)) { return $true }
    $sb = New-Object System.Text.StringBuilder 256
    [void][Shot]::GetWindowText($w, $sb, 256)
    if ($sb.ToString() -ceq 'Clipboard history') { $script:panel = $w; return $false }
    return $true
  }
  [void][Shot]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:panel
}

function Save-Shot {
  param([string]$box, [string]$themeName, [int]$row)
  [void](Invoke-Sandbox $box @('status'))   # keep the resident alive check honest
  $child = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', (Join-Path $box 'clipboard.ps1'), 'serve')
  $up = $false
  for ($i = 0; $i -lt 40 -and -not $up; $i++) {
    Start-Sleep -Milliseconds 400
    if ((Invoke-Sandbox $box @('status')) -match 'resident    : running') { $up = $true }
  }
  if (-not $up) { throw 'the resident did not start' }

  $shown = $false
  for ($i = 0; $i -lt 30 -and -not $shown; $i++) {
    try {
      $e = [System.Threading.EventWaitHandle]::OpenExisting('Local\clipboard.show')
      [void]$e.Set()
      $e.Dispose()
      $shown = $true
    } catch { Start-Sleep -Milliseconds 200 }
  }
  if (-not $shown) { throw 'the show event never appeared' }

  $handle = [IntPtr]::Zero
  for ($i = 0; $i -lt 60 -and $handle -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 200
    $handle = Find-Panel
  }
  if ($handle -eq [IntPtr]::Zero) { throw 'the panel never appeared' }
  Start-Sleep -Milliseconds 900

  # select a row with a real click: injected arrow keys would go through the panel's key
  # hook and can leave characters in the search box
  $rect = New-Object Shot+RECT
  [void][Shot]::GetWindowRect($handle, [ref]$rect)
  if ($row -gt 1) {
    $cx = $rect.Left + 200
    $cy = $rect.Top + 68 + (40 * ($row - 1)) + 20
    [void][Shot]::SetCursorPos($cx, $cy)
    Start-Sleep -Milliseconds 120
    [Shot]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [Shot]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    [void][Shot]::SetCursorPos(($rect.Right + 40), ($rect.Top + 40))
    Start-Sleep -Milliseconds 400
  }

  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  $bmp = New-Object Drawing.Bitmap $width, $height
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
  $g.Dispose()
  $out = Join-Path $docsDir ('screenshot-' + $themeName + '.png')
  $bmp.Save($out, [Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Host ('[ok] ' + $out + '   ' + $width + 'x' + $height)

  [Shot]::keybd_event(0x1B, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [Shot]::keybd_event(0x1B, 0, 2, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 600
  [void](Invoke-Sandbox $box @('stop'))
  for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Milliseconds 300
    if ((Invoke-Sandbox $box @('status')) -match 'resident    : not running') { break }
  }
  if (-not $child.HasExited) { try { $child.Kill() } catch { } }
}

$themes = @()
if ($Theme -eq 'both') { $themes = @('dark', 'light') } else { $themes = @($Theme) }
foreach ($t in $themes) {
  $box = New-ShotBox ('win11-' + $t)
  try {
    Set-Seed $box
    Save-Shot $box $t $Select
  } finally {
    if ($KeepBox) { Write-Host ('[..] kept ' + $box) }
    else { Remove-Item -LiteralPath $box -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

# preload/utils/hotkey-record.ps1 - handing the registered hotkey to the window that is recording one.
#
# RegisterHotKey is what eats the chord: once the resident holds Ctrl+Alt+V, no window sees that
# key, and a settings window asked to record it would wait forever. So the resident hands the
# chord over instead: the window writes a request, the resident answers with the chord it holds,
# and the window reads it back. Two files in the folder the two processes already share, one
# request and one answer, and the protocol lives here so neither side spells it again.
#
# Nothing here knows about windows, keys or settings: every function takes the folder and a
# string, so the whole handshake is testable without a desktop.

# A request older than this belongs to a window that is gone - a crash must not leave the
# resident handing chords to nobody.
$script:HotkeyRecordAgeSeconds = 60

function Get-HotkeyRecordRequest([string]$Dir) {
  if (-not $Dir) { return '' }
  return (Join-Path $Dir 'record.req')
}

function Get-HotkeyRecordAnswer([string]$Dir) {
  if (-not $Dir) { return '' }
  return (Join-Path $Dir 'record.chord')
}

# the window opens a recording: the request is what tells the resident to answer
function Start-HotkeyRecord([string]$Dir) {
  $req = Get-HotkeyRecordRequest $Dir
  if (-not $req) { return $false }
  try {
    if (-not (Test-Path -LiteralPath $Dir)) { [void][IO.Directory]::CreateDirectory($Dir) }
    # an answer left from an earlier recording would be read as if it had just been pressed
    $ans = Get-HotkeyRecordAnswer $Dir
    if ($ans -and (Test-Path -LiteralPath $ans)) { Remove-Item -LiteralPath $ans -Force -ErrorAction SilentlyContinue }
    [IO.File]::WriteAllText($req, '1', (New-Object Text.UTF8Encoding $false))
    return $true
  } catch {
    return $false
  }
}

# the chord the resident handed over, or '' when nothing arrived yet
function Read-HotkeyRecord([string]$Dir) {
  if (-not (Test-HotkeyRecordRequested $Dir)) { return '' }
  $ans = Get-HotkeyRecordAnswer $Dir
  if (-not $ans) { return '' }
  try {
    if (-not (Test-Path -LiteralPath $ans)) { return '' }
    return ([IO.File]::ReadAllText($ans)).Trim()
  } catch {
    return ''
  }
}

# whether a window is waiting right now: the resident answers a request and ignores a stale one
function Test-HotkeyRecordRequested([string]$Dir) {
  $req = Get-HotkeyRecordRequest $Dir
  if (-not $req) { return $false }
  try {
    if (-not (Test-Path -LiteralPath $req)) { return $false }
    $age = ((Get-Date) - (Get-Item -LiteralPath $req).LastWriteTime).TotalSeconds
    if ($age -gt $script:HotkeyRecordAgeSeconds) {
      Stop-HotkeyRecord $Dir
      return $false
    }
    return $true
  } catch {
    return $false
  }
}

# the resident's half: give the chord to the waiting window, or answer $false and let the caller
# open the panel
function Send-HotkeyRecord([string]$Dir, [string]$Chord) {
  if (-not $Chord) { return $false }
  if (-not (Test-HotkeyRecordRequested $Dir)) { return $false }
  $ans = Get-HotkeyRecordAnswer $Dir
  if (-not $ans) { return $false }
  try {
    [IO.File]::WriteAllText($ans, $Chord, (New-Object Text.UTF8Encoding $false))
    return $true
  } catch {
    return $false
  }
}

# both files go, whichever side is done with the recording
function Stop-HotkeyRecord([string]$Dir) {
  if (-not $Dir) { return }
  foreach ($p in @((Get-HotkeyRecordRequest $Dir), (Get-HotkeyRecordAnswer $Dir))) {
    if (-not $p) { continue }
    try { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } } catch { }
  }
}

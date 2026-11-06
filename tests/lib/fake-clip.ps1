# tests/lib/fake-clip.ps1 - a drop-in replacement for lib/clip.ps1 inside a sandbox.
#
# The real file is the only place that talks to the Windows clipboard, so replacing that one
# file gives a sandbox its own clipboard: text, a file list, a picture or formatted text, kept
# in the sandbox instead of on the machine. Two things follow from that:
#
#   * a test run never reads or writes the user's clipboard, so it cannot clobber it and does
#     not need to save and restore it;
#   * two sandboxes can run at the same time, which is what makes a parallel run possible at
#     all - every CLI test would otherwise fight over the one system clipboard.
#
# It keeps the same function names and return shapes as the real thing (Text / Rich / Image,
# See Get-ClipCapture in lib/clip.ps1), and it reuses the real media layer for the parts that
# are not about Windows: a rich reference and an image descriptor are written and read with
# the same functions the program uses, so the bytes on the way back are the bytes that went in.

# where the sandbox keeps its clipboard
function Get-FakeClipDir {
  $dir = Join-Path $StoreDir '_fakeclip'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return $dir
}

function Read-FakeClipValue([string]$name) {
  $p = Join-Path (Get-FakeClipDir) $name
  if (-not (Test-Path -LiteralPath $p)) { return '' }
  try { return [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) } catch { return '' }
}

function Write-FakeClipValue([string]$name, [string]$value) {
  $p = Join-Path (Get-FakeClipDir) $name
  try { [IO.File]::WriteAllText($p, [string]$value, (New-Object Text.UTF8Encoding $false)); return $true } catch { return $false }
}

function Clear-FakeClip {
  foreach ($n in @('payload.txt', 'rich.ref')) {
    $p = Join-Path (Get-FakeClipDir) $n
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
  }
}

# the text the clipboard holds; a picture has none, which is what the real Clipboard reports too
function Get-Text {
  $p = Read-FakeClipValue 'payload.txt'
  if (-not $p) { return '' }
  if (Test-ImagePayload $p) { return '' }
  if ($p.Length -gt 0 -and $p[0] -eq [char]1) { return $p.Substring(1) }
  return $p
}

function Set-Text([string]$t) {
  Clear-FakeClip
  return (Write-FakeClipValue 'payload.txt' ([string]$t))
}

# the panel and `pick` register their own write so the daemon does not capture it again; the
# row also moves to the top, exactly like the real file does
function Set-LastCapture([string]$payload) {
  $script:LastText = [string]$payload
  try { $script:LastSeq = [long]0 } catch { }
  if (Get-Command Touch-Record -ErrorAction SilentlyContinue) { [void](Touch-Record ([string]$payload)) }
}

# One snapshot in the shape the rest of the tool expects:
#   Text  - payload ('' when the clipboard holds a picture)
#   Rich  - @{ Html = byte[]; Rtf = byte[]; Blocks = @(@{ Tag; Data }) } or $null
#   Image - @{ Png = byte[]; W; H; Fmt } or $null
function Get-ClipCapture {
  $p = Read-FakeClipValue 'payload.txt'
  if (-not $p) { return @{ Text = ''; Rich = $null; Image = $null } }
  if (Test-ImagePayload $p) {
    $ref = Get-ImageRef $p
    $png = $null
    if ($null -ne $ref) { $png = Read-ImageBytes $ref.Sha1 }
    if ($null -eq $ref) { return @{ Text = ''; Rich = $null; Image = $null } }
    return @{ Text = ''; Rich = $null; Image = @{ Png = $png; W = $ref.W; H = $ref.H; Fmt = $ref.Fmt } }
  }
  $rich = $null
  if ($script:CaptureRich) { $rich = Get-RichCapture }
  return @{ Text = $p; Rich = $rich; Image = $null }
}

# the formatted side of the snapshot, rebuilt from the reference the entry carries
function Get-RichCapture {
  $ref = Read-FakeClipValue 'rich.ref'
  if (-not $ref) { return $null }
  $r = Get-RichRef $ref
  if ($null -eq $r) { return $null }
  $html = $null
  $rtf = $null
  try { $html = Read-RichHtml $ref } catch { $html = $null }
  try { $rtf = Read-RichRtfBytes $ref } catch { $rtf = $null }
  $blocks = New-Object System.Collections.Generic.List[object]
  foreach ($b in @($r.Blocks)) {
    if ($b.Tag -cne 'P' -and $b.Tag -cne 'D' -and $b.Tag -cne 'E') { continue }
    $data = $null
    try { $data = Read-RichBlock $ref $b.Tag } catch { $data = $null }
    if ($null -ne $data) { $blocks.Add(@{ Tag = $b.Tag; Data = $data }) }
  }
  return @{ Html = $html; Rtf = $rtf; Blocks = $blocks.ToArray() }
}

function Get-ImageCapture {
  $p = Read-FakeClipValue 'payload.txt'
  if (-not (Test-ImagePayload $p)) { return $null }
  $ref = Get-ImageRef $p
  if ($null -eq $ref) { return $null }
  $png = Read-ImageBytes $ref.Sha1
  if ($null -eq $png) { return $null }
  return @{ Png = $png; W = $ref.W; H = $ref.H; Fmt = $ref.Fmt }
}

function Get-ClipItem {
  $p = Read-FakeClipValue 'payload.txt'
  if (-not $p) { return $null }
  return $p
}

# putting an entry back: the payload and, when the entry has one, the reference to its
# formatted blocks - which is all the real file needs to hand a target every flavor
function Set-ClipItem([string]$entry, [string]$rich = '') {
  Clear-FakeClip
  if (-not (Write-FakeClipValue 'payload.txt' ([string]$entry))) { return $false }
  if ($rich) { [void](Write-FakeClipValue 'rich.ref' ([string]$rich)) }
  return $true
}

# utils/inifile.ps1 - getting a file in and out, with the parse cache.
#
# This is the module system of the ini layer: a path is parsed once and the same doc is
# handed out until the file changes on disk, so a second reader never pays for a second
# pass. The cache key is the path; the entry is dropped when the file's size or write time
# moves, and the writers below drop it explicitly after they rewrite the file. A missing file
# reads as an empty doc, so a caller never has to test for the file first.
#
# Only .ini files are imported for now: the cache is keyed by path and validated by the file
# stamp, so adding another format means another reader, not another cache.

$script:IniImports = @{}

# One file, parsed once. Returns the doc that utils/ini.ps1 works on.
#
# The cache entry keeps the FileInfo it validated with and refreshes that object, so a
# repeated import costs one stat and no allocations - Apply-Config and `config` both walk
# dozens of keys, and each of them imports the file.
function Import-Ini([string]$path) {
  $full = $path
  try { $full = [IO.Path]::GetFullPath($path) } catch { }
  $hit = $script:IniImports[$full]
  $info = $null
  if ($null -ne $hit) {
    $info = $hit.Info
    try { $info.Refresh() } catch { $info = $null }
  }
  if ($null -eq $info) {
    try { $info = [IO.FileInfo]::new($full) } catch { $info = $null }
  }
  $stamp = 'unreadable'
  if ($null -ne $info) {
    if (-not $info.Exists) { $stamp = 'missing' }
    else { $stamp = ([string]$info.Length + '|' + [string]$info.LastWriteTimeUtc.Ticks) }
  }
  if ($null -ne $hit -and $hit.Stamp -eq $stamp) { return $hit.Doc }
  $doc = New-IniDoc
  if ($stamp -ne 'missing' -and $stamp -ne 'unreadable') {
    try {
      $doc = Read-IniDoc ([IO.File]::ReadAllLines($full, [Text.Encoding]::UTF8))
    } catch {
      # an unreadable file behaves like an empty one: the callers fall back to defaults
      if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log ('ini read failed: ' + $full + ' - ' + $_.Exception.Message) }
    }
  }
  $script:IniImports[$full] = @{ Stamp = $stamp; Info = $info; Doc = $doc }
  return $doc
}

# one value of one file, "" when the key is absent
function Import-IniValue([string]$path, [string]$key) {
  return (Get-IniDocValue (Import-Ini $path) $key)
}

# Where the store lives: DataDir= from clipboard.ini, else <root>\data. A relative DataDir
# resolves against the tool root and a bare drive ("D:") is completed to "D:\".
#
# $null means DataDir is not a usable path - the caller decides what to say about it. The
# entry and lib/proxy.ps1 both need this exact answer (the proxy names its pipe after it), so
# it is written once, here, instead of being spelled out in each of them.
function Resolve-StoreDir([string]$root, $iniMap) {
  $raw = ''
  if ($iniMap -and $iniMap.ContainsKey('DataDir')) { $raw = ([string]$iniMap['DataDir']).Trim() }
  if (-not $raw) { return (Join-Path $root 'data') }
  $path = $raw
  if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $root $path }
  try {
    $path = [IO.Path]::GetFullPath($path).TrimEnd([char]92, [char]47)
    if ($path -match '^[A-Za-z]:$') { $path += '\' }
  } catch { return $null }
  return $path
}

# forget a parse; called by the writer below, and usable after a file was rewritten by
# something other than this module
function Clear-IniImport([string]$path) {
  if (-not $path) { $script:IniImports = @{}; return }
  $full = $path
  try { $full = [IO.Path]::GetFullPath($path) } catch { }
  $script:IniImports.Remove($full)
}

# Write a whole document back. The caller owns what is in it (a rebuilt file, a merged one);
# this function owns the encoding and the temp-then-move, so no reader ever sees half a file.
function Save-IniDoc([string]$path, $doc) {
  if ($null -eq $doc) { return $false }
  return (Save-IniLines $path @(ConvertTo-IniText $doc))
}

# Write a set of lines as a fresh file. A template is not a doc yet - it is the text this
# version wants - so it gets its own entry point instead of being parsed and rebuilt.
function Save-IniLines([string]$path, [string[]]$lines) {
  $full = $path
  try { $full = [IO.Path]::GetFullPath($path) } catch { }
  $dir = Split-Path -Parent $full
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $text = ((@($lines) -join [Environment]::NewLine) + [Environment]::NewLine)
  $tmp = $full + '.tmp'
  $utf8 = [System.Text.UTF8Encoding]::new($false)
  [IO.File]::WriteAllText($tmp, $text, $utf8)
  Move-Item -LiteralPath $tmp -Destination $full -Force
  Clear-IniImport $full
  return $true
}

# Rewrite one key in place: comments, order and every other line stay as they are.
# A grouped key ("item-marks.MaxPins") is updated in the spelling the file already uses -
# flat, or as a leaf inside its [section] - and appended flat when it is new.
function Export-IniValue([string]$path, [string]$key, [string]$value) {
  $lines = @()
  if (Test-Path -LiteralPath $path) { $lines = [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8) }
  # where the key goes - its own line, its [section] block, or a header at the end - is the
  # document's business (utils/ini.ps1); this function only owns the file around it
  $doc = Read-IniDoc $lines
  [void](Set-IniDocValue $doc $key $value)
  [void](Save-IniDoc $path $doc)
  return $true
}

# utils/inifile.ps1 - getting a file in and out, with the parse cache.
#
# This is the module system of the ini layer: a path is parsed once and the same doc is
# handed out until the file changes on disk, so a second reader never pays for a second
# pass. The cache key is the path; the entry is dropped when the file's size or write time
# moves, and Export-IniValue drops it explicitly after it rewrites a line. A missing file
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
    try { $info = New-Object IO.FileInfo $full } catch { $info = $null }
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

# the flat key map of one file, which is all a plain reader wants
function Import-IniMap([string]$path) {
  return (Import-Ini $path).Map
}

# one value of one file, "" when the key is absent
function Import-IniValue([string]$path, [string]$key) {
  return (Get-IniDocValue (Import-Ini $path) $key)
}

# forget a parse; called by the writer below, and usable after a file was rewritten by
# something other than this module
function Clear-IniImport([string]$path) {
  if (-not $path) { $script:IniImports = @{}; return }
  $full = $path
  try { $full = [IO.Path]::GetFullPath($path) } catch { }
  $script:IniImports.Remove($full)
}

# Rewrite one key in place: comments, order and every other line stay as they are.
# A grouped key ("item-marks.MaxPins") is updated in the spelling the file already uses -
# flat, or as a leaf inside its [section] - and appended flat when it is new.
function Export-IniValue([string]$path, [string]$key, [string]$value) {
  $full = $path
  try { $full = [IO.Path]::GetFullPath($path) } catch { }
  $dir = Split-Path -Parent $full
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $lines = New-Object System.Collections.Generic.List[string]
  if (Test-Path -LiteralPath $full) {
    foreach ($l in [IO.File]::ReadAllLines($full, [Text.Encoding]::UTF8)) { $lines.Add($l) }
  }
  $leaf = $key
  $group = ''
  $dot = $key.LastIndexOf('.')
  if ($dot -gt 0) {
    $group = $key.Substring(0, $dot)
    $leaf = $key.Substring($dot + 1)
  }
  $flatPattern = '^\s*' + [regex]::Escape($key) + '\s*='
  $leafPattern = '^\s*' + [regex]::Escape($leaf) + '\s*='
  $done = $false
  $section = ''
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -match '^\s*\[(.+)\]\s*$') {
      $section = $Matches[1].Trim()
      continue
    }
    if ($line -match $flatPattern) {
      $lines[$i] = $key + '=' + $value
      $done = $true
      continue
    }
    if ($group -and $section -ieq $group -and $line -match $leafPattern) {
      $lines[$i] = $leaf + '=' + $value
      $done = $true
    }
  }
  if (-not $done) {
    if ($group) {
      # keep the file in its sectioned shape: a new plugin key joins its [group] block, and
      # the block is created at the end when the file does not have one yet
      $head = -1
      $last = -1
      for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[(.+)\]\s*$') {
          if ($head -ge 0) { break }
          if ($Matches[1].Trim() -ieq $group) { $head = $i; $last = $i }
          continue
        }
        if ($head -ge 0 -and $lines[$i].Trim()) { $last = $i }
      }
      if ($head -ge 0) {
        $lines.Insert($last + 1, $leaf + '=' + $value)
      } else {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim()) { $lines.Add('') }
        $lines.Add('[' + $group + ']')
        $lines.Add($leaf + '=' + $value)
      }
    } else {
      $lines.Add($key + '=' + $value)
    }
  }
  $tmp = $full + '.tmp'
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [IO.File]::WriteAllText($tmp, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), $utf8)
  Move-Item -LiteralPath $tmp -Destination $full -Force
  Clear-IniImport $full
  return $true
}

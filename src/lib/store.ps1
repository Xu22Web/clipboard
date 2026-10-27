# lib/store.ps1 - the history file: CBHIST2 records, locking, marks, trimming and the short
# labels used by `list` and the panel.
#
# The base stores one character per mark and asks the plugin layer what those marks mean
# (protected / sorts first / kept on clear / printed word), so adding a mark needs no
# change here - see Marks in lib/plugins.ps1.

# One record: <flags> US <epoch seconds> US <payload>
#   flags = one type char - 't' (text) or 'f' (file list) - followed by mark chars
# A mark is one character owned by a plugin. The base stores it, keeps the list order and
# enforces the rules the plugin declares (protected / sorts first / kept on clear), but it
# never knows what a mark means. A flag string such as "tps" is therefore read as "text
# entry, marks p and s".
# Only this format is read. A file without the CBHIST2 tag is ignored as unknown.
function New-Record([string]$payload, [long]$time, [string]$marks = '') {
  return [pscustomobject]@{ Payload = $payload; Time = $time; Marks = $marks }
}

# does this record carry the mark?
function Test-Mark($record, [string]$mark) {
  if ($null -eq $record -or -not $mark) { return $false }
  return (([string]$record.Marks).IndexOf($mark) -ge 0)
}

# any of these marks? (an empty list answers $false, so an unprotected row is deletable)
function Test-AnyMark($record, [string[]]$marks) {
  foreach ($m in @($marks)) { if (Test-Mark $record $m) { return $true } }
  return $false
}

# set or clear one mark in memory; returns $true when the record actually changed
function Set-RecordMark($record, [string]$mark, [bool]$on) {
  if ($null -eq $record -or -not $mark) { return $false }
  $cur = [string]$record.Marks
  if (($cur.IndexOf($mark) -ge 0) -eq $on) { return $false }
  if ($on) { $record.Marks = $cur + $mark } else { $record.Marks = $cur.Replace($mark, '') }
  return $true
}

# mark declarations come from the plugin layer; without plugins every list is empty, so
# nothing is protected, nothing sorts first and nothing can be marked at all
function Get-MarkNames {
  if (Get-Command Get-PluginMarkNames -ErrorAction SilentlyContinue) {
    try { return @(Get-PluginMarkNames) } catch { }
  }
  return @()
}

function Get-MarkInfo([string]$mark) {
  if (-not $mark) { return $null }
  if (Get-Command Get-PluginMarkInfo -ErrorAction SilentlyContinue) {
    try { return (Get-PluginMarkInfo $mark) } catch { }
  }
  return $null
}

# the word the owner uses for the mark, else the raw character
function Get-MarkWord([string]$mark) {
  $info = Get-MarkInfo $mark
  if ($info -and $info.Word) { return [string]$info.Word }
  return $mark
}

function Get-ProtectedMarks {
  if (Get-Command Get-PluginProtectedMarks -ErrorAction SilentlyContinue) {
    try { return @(Get-PluginProtectedMarks) } catch { }
  }
  return @()
}

# the mark whose rows float to the top of the list (plugins declare at most one)
function Get-SortMark {
  if (Get-Command Get-PluginSortMark -ErrorAction SilentlyContinue) {
    try { return [string](Get-PluginSortMark) } catch { }
  }
  return ''
}

# marks `clear` keeps: protected ones always, the ones a plugin asks for unless -All.
# The result follows the declaration order, so messages read the same everywhere.
function Get-ClearKeepMarks([switch]$All) {
  $prot = @(Get-ProtectedMarks)
  $extra = @()
  if (-not $All.IsPresent -and (Get-Command Get-PluginClearKeeps -ErrorAction SilentlyContinue)) {
    try { $extra = @(Get-PluginClearKeeps) } catch { }
  }
  $keep = @()
  foreach ($m in @(Get-MarkNames)) {
    if (($prot -contains $m) -or ($extra -contains $m)) { $keep += $m }
  }
  # a plugin may ask to keep a mark it never declares: honour the request
  foreach ($m in $extra) { if ($m -and ($keep -notcontains $m)) { $keep += $m } }
  return $keep
}

# the first protected mark this record carries; empty = the row may be deleted
function Get-ProtectorMark($record) {
  foreach ($m in @(Get-ProtectedMarks)) { if (Test-Mark $record $m) { return $m } }
  return ''
}

# words of the marks a record carries, in declaration order (for CLI output)
function Get-RecordMarkWords($record) {
  $words = @()
  foreach ($m in @(Get-MarkNames)) { if (Test-Mark $record $m) { $words += (Get-MarkWord $m) } }
  return $words
}

# '1 starred', '2 pinned' ... one entry per mark that occurs in the list
function Get-MarkCountWords($records) {
  $src = @($records)
  $out = @()
  foreach ($m in @(Get-MarkNames)) {
    $c = 0
    foreach ($r in $src) { if (Test-Mark $r $m) { $c++ } }
    if ($c -gt 0) { $out += ($c.ToString() + ' ' + (Get-MarkWord $m)) }
  }
  return $out
}

function Get-Records {
  # Parsing the whole store is the hottest path (panel open, filter, delete, undo all
  # need it), so the result is cached against the file stamp. Any writer - this process
  # or another one - changes length or last-write time and invalidates it.
  $fi = $null
  try { $fi = Get-Item -LiteralPath $StoreFile -ErrorAction Stop } catch { $script:RecCache = $null; return @() }
  $stamp = [string]$fi.Length + ':' + [string]$fi.LastWriteTimeUtc.Ticks
  if ($null -ne $script:RecCache -and $script:RecCache.Stamp -eq $stamp) { return $script:RecCache.Records }
  $raw = $null
  try { $raw = [IO.File]::ReadAllText($StoreFile, [Text.Encoding]::UTF8) } catch { return @() }
  if ([string]::IsNullOrEmpty($raw)) { $script:RecCache = @{ Stamp = $stamp; Records = @() }; return @() }
  $out = New-Object System.Collections.Generic.List[object]
  try {
    $chunks = @($raw -split [regex]::Escape($RS))
    if ($chunks.Count -eq 0 -or $chunks[0] -cne $V2TAG) {
      if (-not $script:StoreFormatWarned) {
        $script:StoreFormatWarned = $true
        Write-Log ('store ignored: unknown format, only ' + $V2TAG + ' is supported')
      }
      $script:RecCache = @{ Stamp = $stamp; Records = @() }
      return @()
    }
    for ($i = 1; $i -lt $chunks.Count; $i++) {
      $rec = $chunks[$i]
      if ($rec.Length -eq 0) { continue }
      $a = $rec.IndexOf($US)
      if ($a -lt 1) { continue }
      $b = $rec.IndexOf($US, $a + 1)
      if ($b -lt 0) { continue }
      $flags = $rec.Substring(0, $a)
      $tick = [long]0
      [void][long]::TryParse($rec.Substring($a + 1, $b - $a - 1), [ref]$tick)
      $payload = $rec.Substring($b + 1)
      if ($payload.Length -eq 0) { continue }
      $out.Add((New-Record $payload $tick $flags.Substring(1)))
    }
  } catch { return @() }
  $script:RecCache = @{ Stamp = $stamp; Records = $out.ToArray() }
  return $script:RecCache.Records
}

function Save-Records($records) {
  Ensure-Dir
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append($V2TAG)
  if ($records) {
    foreach ($r in $records) {
      $flags = 't'
      if ($r.Payload.Length -gt 0 -and $r.Payload[0] -eq [char]1) { $flags = 'f' }
      [void]$sb.Append($RS).Append($flags + [string]$r.Marks).Append($US).Append([string][long]$r.Time).Append($US).Append($r.Payload)
    }
  }
  $tmp = $StoreFile + '.tmp'
  [IO.File]::WriteAllText($tmp, $sb.ToString(), $Utf8)
  Move-Item -LiteralPath $tmp -Destination $StoreFile -Force
  $script:RecCache = $null
}

function Use-StoreLock([scriptblock]$body) {
  $m = New-Object System.Threading.Mutex($false, $StoreLock)
  $held = $false
  try {
    try { $held = $m.WaitOne(3000) } catch { $held = $true }
    & $body
  } finally {
    if ($held) { try { $m.ReleaseMutex() } catch { } }
    $m.Dispose()
  }
}

# rows carrying the sort mark float to the top, each block keeps its own order
function Sort-Records($list) {
  $sm = Get-SortMark
  if (-not $sm) { return ,$list }
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($r in $list) { if (Test-Mark $r $sm) { $out.Add($r) } }
  foreach ($r in $list) { if (-not (Test-Mark $r $sm)) { $out.Add($r) } }
  return ,$out
}

# enforce MaxItems / MaxTotal in place; rows carrying a protected mark are never dropped
function Trim-Records($list) {
  $protected = @(Get-ProtectedMarks)
  if ($list.Count -gt $MaxItems) {
    $over = $list.Count - $MaxItems
    $drop = New-Object System.Collections.Generic.List[object]
    for ($i = $list.Count - 1; $i -ge 0 -and $drop.Count -lt $over; $i--) {
      if (-not (Test-AnyMark $list[$i] $protected)) { $drop.Add($list[$i]) }
    }
    foreach ($d in $drop) { [void]$list.Remove($d) }
  }
  $total = 0
  $cut = $false
  $keep = New-Object System.Collections.Generic.List[object]
  foreach ($r in $list) {
    $prot = Test-AnyMark $r $protected
    if ($cut) { if ($prot) { $keep.Add($r) }; continue }
    $total += $Utf8.GetByteCount($r.Payload)
    if ($total -gt $MaxTotal -and -not $prot) { $cut = $true; continue }
    $keep.Add($r)
  }
  $list.Clear()
  foreach ($r in $keep) { $list.Add($r) }
}

function Add-Item([string]$text) {
  if ([string]::IsNullOrWhiteSpace($text)) { return }
  if ($script:ExcludePattern) {
    try { if ($text -match $script:ExcludePattern) { Write-Log 'skip (exclude pattern)'; return } } catch { }
  }
  if ($Utf8.GetByteCount($text) -gt $MaxBytes) { Write-Log ('skip oversize ' + $text.Length); return }
  # RS / US are the record delimiters: a payload carrying them would corrupt the store
  if (($text.IndexOf([char]30) -ge 0) -or ($text.IndexOf([char]31) -ge 0)) {
    $text = $text.Replace([char]30, ' ').Replace([char]31, ' ')
    Write-Log 'sanitized record separators in captured text'
  }
  Use-StoreLock {
    $recs = @(Get-Records)
    if ($recs.Count -gt 0 -and $recs[0].Payload -ceq $text) { return }
    # a re-captured payload keeps the marks it already had
    $prevMarks = ''
    foreach ($r in $recs) {
      if ($r.Payload -ceq $text) { $prevMarks = [string]$r.Marks; break }
    }
    $list = New-Object System.Collections.Generic.List[object]
    $list.Add((New-Record $text (Get-Epoch) $prevMarks))
    foreach ($r in $recs) { if ($r.Payload -cne $text) { $list.Add($r) } }
    $list = Sort-Records $list
    Trim-Records $list
    Save-Records $list.ToArray()
  }
}

# a row carrying a protected mark is kept: the verb that removes the mark belongs to the
# plugin that declared it, so the base only reports which mark blocked the delete
function Remove-Record([string]$payload, [switch]$Force) {
  $r = Use-StoreLock {
    $keep = New-Object System.Collections.Generic.List[object]
    $removed = $false
    $blocked = ''
    foreach ($rec in @(Get-Records)) {
      if (-not $removed -and $rec.Payload -ceq $payload) {
        if (-not $Force.IsPresent) {
          $pm = Get-ProtectorMark $rec
          if ($pm) { $blocked = $pm; $keep.Add($rec); continue }
        }
        $removed = $true
        continue
      }
      $keep.Add($rec)
    }
    if ($removed) { Save-Records $keep.ToArray() }
    if ($blocked) { return ('protected:' + $blocked) }
    if ($removed) { return 'removed' }
    return 'missing'
  }
  return [string]$r
}

function Restore-Record($record, [int]$index) {
  Use-StoreLock {
    $recs = New-Object System.Collections.Generic.List[object]
    foreach ($r in @(Get-Records)) {
      if ($r.Payload -ceq $record.Payload) { return }
      $recs.Add($r)
    }
    if ($index -lt 0) { $index = 0 }
    if ($index -gt $recs.Count) { $index = $recs.Count }
    $recs.Insert($index, $record)
    $recs = Sort-Records $recs
    Save-Records $recs.ToArray()
  }
}

# toggle one mark on the entry that carries this payload; the record list is re-sorted so
# a mark that sorts first takes effect immediately
function Set-Mark([string]$payload, [string]$mark, [bool]$on) {
  $r = Use-StoreLock {
    $recs = @(Get-Records)
    $target = $null
    foreach ($rec in $recs) { if ($rec.Payload -ceq $payload) { $target = $rec; break } }
    if ($null -eq $target) { return $false }
    if (-not (Set-RecordMark $target $mark $on)) { return $false }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($rec in $recs) { $list.Add($rec) }
    $list = Sort-Records $list
    Save-Records $list.ToArray()
    return $true
  }
  return [bool]$r
}

# mutate the record list under the store lock. A plugin needs this when one change spans
# several rows (a cap on its own mark, for example) and must stay a single write.
# The parameter is deliberately not called $body: Use-StoreLock uses that name, and a
# scriptblock would resolve it to the lock's own copy and call itself forever.
function Update-Records([scriptblock]$mutate) {
  return Use-StoreLock {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($r in @(Get-Records)) { $rows.Add($r) }
    $out = & $mutate $rows
    $rows = Sort-Records $rows
    Save-Records $rows.ToArray()
    return $out
  }
}

# keep the rows carrying any of these marks; the caller decides which marks those are
function Clear-Store([string[]]$keepMarks = @()) {
  Use-StoreLock {
    $keep = New-Object System.Collections.Generic.List[object]
    foreach ($rec in @(Get-Records)) {
      if (Test-AnyMark $rec $keepMarks) { $keep.Add($rec) }
    }
    Save-Records $keep.ToArray()
  }
}

# one context-menu action's caption for a row: a scriptblock label is evaluated, a plain
# string is used as is, and anything else falls back to a neutral caption
function Get-ActionText($action, $record) {
  $label = $null
  if ($action -is [hashtable] -and $action.ContainsKey('Label')) { $label = $action['Label'] }
  if ($label -is [scriptblock]) {
    try {
      $text = [string](& $label $record)
      if ($text) { return $text }
    } catch { }
    return 'Plugin action'
  }
  if ($label) { return [string]$label }
  return 'Plugin action'
}

# single-line display text for one payload (picker rows and CLI listings)
function Get-ItemLabel([string]$t, [bool]$nlMarker = $true) {
  $one = $t
  if ($one.Length -gt 0 -and $one[0] -eq [char]1) {
    $names = @($one.Substring(1) -split "`n" | Where-Object { $_ } | ForEach-Object { Split-Path -Leaf $_ })
    if ($names.Count -gt 3) { $one = '[files] ' + (($names[0..2]) -join ', ') + ' (+' + ($names.Count - 3) + ')' }
    else { $one = '[files] ' + ($names -join ', ') }
  } else {
    # only the head of a large payload is ever shown, so skip the cleanup work on the
    # rest of a 200 KB entry on every keystroke
    if ($one.Length -gt 4000) { $one = $one.Substring(0, 4000) }
    $one = $one -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ' '
    if ($nlMarker) { $one = $one -replace '\r?\n', ' <NL> ' } else { $one = $one -replace '\r?\n', ' ' }
    $one = $one -replace '\t', ' '
    $one = $one -replace ' {2,}', ' '
    $one = $one.Trim()
  }
  if ($one.Length -gt 2000) { $one = $one.Substring(0, 2000) }
  return $one
}

function Format-Item([string]$t, [int]$max) {
  $one = Get-ItemLabel $t $true
  if ($one.Length -gt $max) { $one = $one.Substring(0, $max) + '...' }
  return $one
}

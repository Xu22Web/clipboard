# lib/store.ps1 - the history file: what is on disk, how it is parsed, locked, marked,
# trimmed, and the short labels used by `list` and the panel.
#
# The base stores one character per mark and asks the plugin layer what those marks mean
# (protected / sorts first / kept on clear / printed word), so adding a mark needs no
# change here - see Marks in lib/plugins.ps1.

# File layout: CBHIST RS <data version> RS <record> RS <record> ...
#   record = <flags> US <epoch seconds> US <extra> US <payload>
#   flags  = one type char - 't' (text), 'f' (file list) or 'i' (image) - plus mark chars
#   extra  = '' or 'R:<sha1>:<bytes>', the formatted-text sidecar of a text entry
# A mark is one character owned by a plugin. The base stores it, keeps the list order and
# enforces the rules the plugin declares (protected / sorts first / kept on clear), but it
# never knows what a mark means. A flag string such as "tps" is therefore read as "text
# entry, marks p and s".
# Only the current layout version is parsed; an older file is upgraded by lib/migrate.ps1.
#
# Key is not stored: it numbers the records of one parse, so caches can key on a small int.
function New-Record([string]$payload, [long]$time, [string]$marks = '') {
  return [pscustomobject]@{ Payload = $payload; Time = $time; Marks = $marks; Key = 0; Blob = ''; Rich = '' }
}

# One stat, shared by the read cache and the write gate: the size and the write time are the
# whole identity of the file for this process.
function Get-StoreStamp {
  try {
    $fi = Get-Item -LiteralPath $StoreFile -ErrorAction Stop
    return ([string]$fi.Length + ':' + [string]$fi.LastWriteTimeUtc.Ticks)
  } catch { return 'none' }
}

# The UTF-8 size of a payload.
function Get-RecordBytes($record) {
  if ($null -eq $record) { return [long]0 }
  try { return [long]$Utf8.GetByteCount([string]$record.Payload) } catch { return [long]0 }
}

# ---- blobs ------------------------------------------------------------------
# One file per big payload, named after its sha1: the same text captured twice reuses it.
function Get-BlobDir { return (Join-Path $StoreDir 'blobs') }

function Save-Blob([string]$text) {
  $sha = [Security.Cryptography.SHA1]::Create()
  try { $hex = ([BitConverter]::ToString($sha.ComputeHash($Utf8.GetBytes($text))) -replace '-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
  $dir = Get-BlobDir
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $path = Join-Path $dir ($hex + '.txt')
  if (-not (Test-Path -LiteralPath $path)) { [IO.File]::WriteAllText($path, $text, $Utf8) }
  return $hex
}

function Read-Blob([string]$ref) {
  $hex = $ref.Substring(([string]$script:BlobMark).Length)
  try { return [IO.File]::ReadAllText((Join-Path (Get-BlobDir) ($hex + '.txt')), [Text.Encoding]::UTF8) } catch { return $null }
}

# drop the blobs no record points at any more (a delete, a trim, a clear)
function Remove-OrphanBlobs($records) {
  $dir = Get-BlobDir
  if (-not (Test-Path -LiteralPath $dir)) { return }
  $keep = @{}
  foreach ($r in @($records)) { if ([string]$r.Blob) { $keep[[string]$r.Blob] = 1 } }
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.txt' -ErrorAction SilentlyContinue)) {
    if (-not $keep.ContainsKey([string]$f.BaseName)) { try { Remove-Item -LiteralPath $f.FullName -Force } catch { } }
  }
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
  # Parsing the whole store is the hottest path (panel open, filter, delete, undo), so the
  # result is cached against the file stamp: any writer changes size or write time.
  $stamp = Get-StoreStamp
  if ($stamp -eq 'none') { $script:RecCache = $null; return @() }
  if ($null -ne $script:RecCache -and $script:RecCache.Stamp -eq $stamp) { return $script:RecCache.Records }
  $raw = $null
  try { $raw = [IO.File]::ReadAllText($StoreFile, [Text.Encoding]::UTF8) } catch { return @() }
  if ([string]::IsNullOrEmpty($raw)) { $script:RecCache = @{ Stamp = $stamp; Records = @() }; return @() }
  $out = New-Object System.Collections.Generic.List[object]
  try {
    $chunks = @($raw -split [regex]::Escape($RS))
    $fileVersion = -1
    if ($chunks.Count -ge 2 -and $chunks[0] -ceq $TAG) { [void][int]::TryParse($chunks[1], [ref]$fileVersion) }
    if ($fileVersion -ne $script:DataVersion) {
      # one line per process: the reader never guesses at another layout
      if (-not $script:StoreFormatWarned) {
        $script:StoreFormatWarned = $true
        $sv = Get-StoreVersion
        Write-Log ('store not read: ' + $sv.Label + '   ' + $sv.Hint)
      }
      $script:RecCache = @{ Stamp = $stamp; Records = @() }
      return @()
    }
    for ($i = 2; $i -lt $chunks.Count; $i++) {
      $rec = $chunks[$i]
      if ($rec.Length -eq 0) { continue }
      $a = $rec.IndexOf($US)
      if ($a -lt 1) { continue }
      $b = $rec.IndexOf($US, $a + 1)
      if ($b -lt 0) { continue }
      $flags = $rec.Substring(0, $a)
      $tick = [long]0
      [void][long]::TryParse($rec.Substring($a + 1, $b - $a - 1), [ref]$tick)
      $c = $rec.IndexOf($US, $b + 1)
      if ($c -lt 0) { continue }
      $extra = $rec.Substring($b + 1, $c - $b - 1)
      $payload = $rec.Substring($c + 1)
      if ($payload.Length -eq 0) { continue }
      # a blob reference is STX + 'B:' + 40 hex chars; anything else is the text itself
      if ($payload.Length -eq 43 -and $payload[0] -eq [char]2) {
        $full = Read-Blob $payload
        if ($null -eq $full) { continue }   # the blob is gone: the row goes with it
        $one = New-Record $full $tick $flags.Substring(1)
        $one.Blob = $payload.Substring(3)
      } else {
        $one = New-Record $payload $tick $flags.Substring(1)
      }
      # a reference we cannot parse is dropped rather than carried along
      if ($extra -and $null -ne (Get-RichRef $extra)) { $one.Rich = $extra }
      $one.Key = [int](++$script:RecKey)
      $out.Add($one)
    }
  } catch { return @() }
  $script:RecCache = @{ Stamp = $stamp; Records = $out.ToArray() }
  return $script:RecCache.Records
}

# What the file on disk carries, read from its first bytes only (the tag and the version
# field are the first two RS-separated fields, so this stays cheap on a 4 MB store).
#   Kind    none (no file) | current | old | newer | unknown
#   Version the layout version, -1 when the file is unrecognised
# Only `migrate` acts on Kind; the reader refuses anything but current.
function Get-StoreVersion {
  $o = [pscustomobject]@{ Kind = 'none'; Version = -1; Label = 'no history file'; Hint = '' }
  # Every save asks this, and the answer can only change when the file does.
  $stamp = Get-StoreStamp
  if ($null -ne $script:GateCache -and $script:GateCache.Stamp -eq $stamp) { return $script:GateCache.Value }
  if (-not (Test-Path -LiteralPath $StoreFile)) {
    $script:GateCache = @{ Stamp = $stamp; Value = $o }
    return $o
  }
  $head = ''
  try {
    $fs = [IO.File]::Open($StoreFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
      # fill the buffer: a single Read is allowed to come back short, and half a tag would be
      # read as "unrecognised layout" - which makes every later save refuse to write
      $buf = New-Object byte[] 64
      $n = 0
      while ($n -lt $buf.Length) {
        $got = $fs.Read($buf, $n, $buf.Length - $n)
        if ($got -le 0) { break }
        $n += $got
      }
      if ($n -gt 0) { $head = [Text.Encoding]::UTF8.GetString($buf, 0, $n) }
    } finally { $fs.Dispose() }
  } catch { return $o }
  # an empty file holds no data, so it is free to write - not an unknown layout
  if ([string]::IsNullOrEmpty($head)) { $o.Label = 'empty file'; return $o }
  $ver = -1
  $cut = $head.IndexOf($RS)
  if ($cut -gt 0 -and $head.Substring(0, $cut) -ceq $TAG) {
    # a store with no records ends right after the version, so the field has no closing RS
    $rest = $head.Substring($cut + 1)
    $cut2 = $rest.IndexOf($RS)
    $digits = if ($cut2 -ge 0) { $rest.Substring(0, $cut2) } else { $rest }
    $parsed = 0
    if ($digits -match '^\d+$' -and [int]::TryParse($digits, [ref]$parsed)) { $ver = $parsed }
  }
  $o.Version = $ver
  if ($ver -eq $script:DataVersion) {
    $o.Kind = 'current'
    $o.Label = 'CBHIST v' + $ver
  } elseif ($ver -gt $script:DataVersion) {
    $o.Kind = 'newer'
    $o.Label = 'CBHIST v' + $ver
    $o.Hint = 'written by a newer build - update this copy'
  } elseif ($ver -ge 0) {
    $o.Kind = 'old'
    $o.Label = 'CBHIST v' + $ver
    if (Test-MigrationPath $ver) { $o.Hint = 'run: clipboard migrate' }
    else { $o.Hint = 'no migration path in this build - clipboard migrate -Purge archives it' }
  } else {
    $o.Kind = 'unknown'
    $o.Label = 'unrecognised layout'
    $o.Hint = 'clipboard migrate -Purge archives it'
  }
  $script:GateCache = @{ Stamp = $stamp; Value = $o }
  return $o
}

# Removing the blobs and media files no record points at any more walks two directories. It
# stays the default, because every caller that drops rows wants it; the capture path - which
# only ever appends - says -SkipReclaim and saves itself the scans.
function Save-Records($records, [switch]$SkipReclaim) {
  Ensure-Dir
  # Never replace a file this build cannot read: the first capture after replacing the
  # program would otherwise drop the whole history. The upgrade belongs to `migrate`.
  $sv = Get-StoreVersion
  if (@('old', 'newer', 'unknown') -contains $sv.Kind) {
    Write-Log ('store not written: ' + $sv.Label + '   ' + $sv.Hint)
    return
  }
  $script:StoreFormatWarned = $false
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append($TAG).Append($RS).Append([string]$script:DataVersion)
  if ($records) {
    foreach ($r in $records) {
      $flags = 't'
      if (Test-FilePayload ([string]$r.Payload)) { $flags = 'f' }
      elseif (Test-ImagePayload ([string]$r.Payload)) { $flags = 'i' }
      $body = [string]$r.Payload
      # a big payload lives in its own file, so the rewrite a capture costs is a few KB of
      # history instead of the whole store
      if ($body.Length -gt $script:BlobChars) {
        $r.Blob = Save-Blob $body
        $body = [string]$script:BlobMark + [string]$r.Blob
      } elseif ($r.Blob) { $r.Blob = '' }
      $extra = [string]$r.Rich
      [void]$sb.Append($RS).Append($flags + [string]$r.Marks).Append($US).Append([string][long]$r.Time).Append($US).Append($extra).Append($US).Append($body)
    }
  }
  $tmp = $StoreFile + '.tmp'
  [IO.File]::WriteAllText($tmp, $sb.ToString(), $Utf8)
  Move-Item -LiteralPath $tmp -Destination $StoreFile -Force
  # The caller already holds the records it just wrote, so hand them to the read cache: the
  # next Get-Records would parse the whole file again (114 ms on a 4 MB store) after every
  # capture. Records that have never been parsed get their number here.
  $script:RecCache = $null
  try {
    $arr = @($records)
    foreach ($r in $arr) { if ([int]$r.Key -le 0) { $r.Key = [int](++$script:RecKey) } }
    $fi = Get-Item -LiteralPath $StoreFile -ErrorAction Stop
    $stamp = [string]$fi.Length + ':' + [string]$fi.LastWriteTimeUtc.Ticks
    $script:RecCache = @{ Stamp = $stamp; Records = $arr }
    # the file just written is the layout this build reads, so the next save can skip the
    # header read instead of opening the file to learn what it already knows
    $script:GateCache = @{ Stamp = $stamp; Value = [pscustomobject]@{ Kind = 'current'; Version = $script:DataVersion; Label = ('CBHIST v' + $script:DataVersion); Hint = '' } }
  } catch { }
  if ($SkipReclaim.IsPresent) { return }
  Remove-OrphanBlobs $records
  Remove-OrphanMedia $records
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

# The sticky-pin cap a visible area of that size allows: one row always stays for the
# rows the query actually found, otherwise a long pin list would push the results out of
# sight. Declared 0 = feature off, a negative value = as many as fit.
function Get-StickyRowCap([int]$rows) {
  $room = $rows - 1
  if ($room -lt 1) { return 0 }
  return $room
}

# How many leading rows a sticky mark may take inside the visible area.
function Get-StickyRowLimit([int]$rows, [int]$declared) {
  if ($declared -eq 0) { return 0 }
  $room = Get-StickyRowCap $rows
  if ($room -lt 1) { return 0 }
  if ($declared -lt 0 -or $declared -gt $room) { return $room }
  return $declared
}

# What the panel needs to know about the sticky mark: which mark sticks, and how many rows
# it may take for a visible area of that size. An empty mark means nothing sticks - either
# no plugin asks for it or the feature is switched off.
function Get-StickyPlan([int]$rows) {
  $mark = ''
  $max = 0
  if (Get-Command Get-PluginStickyMark -ErrorAction SilentlyContinue) {
    try {
      $mark = [string](Get-PluginStickyMark)
      if ($mark) { $max = Get-StickyRowLimit $rows ([int](Get-PluginStickyRows)) }
    } catch { $mark = '' }
  }
  return @{ Mark = $mark; Max = $max }
}

# How many leading rows stay frozen while the list scrolls. Pins sort first (SortMark), so
# this is the unbroken run of sticky rows at the top of the result set, capped by the same
# rule the exclusive-through-search version used: a long pin list can never fill the whole
# view, one row always stays for the rows below it.
function Get-StickyTopRows($rows, [string]$stickyMark, [int]$stickyMax) {
  if (-not $stickyMark -or $stickyMax -le 0) { return 0 }
  $n = 0
  foreach ($rec in @($rows)) {
    if ($n -ge $stickyMax) { break }
    if (-not (Test-Mark $rec $stickyMark)) { break }
    $n++
  }
  return $n
}

# The rows the panel shows for one query. The meaning of the words lives in lib/query.ps1;
# this name stays for the callers that already hand in a plain token list.
function Select-QueryRows($entries, [string[]]$tokens) {
  return (Invoke-Query $entries (New-Query -Tokens @($tokens)))
}

# enforce MaxItems / MaxTotal / MaxMediaTotal in place; rows carrying a protected mark are
# never dropped. Media sizes travel inside the payload and the reference, so this never
# touches the disk. TrimDropped tells a caller whether the write that follows has orphaned
# files worth reclaiming.
function Trim-Records($list) {
  $protected = @(Get-ProtectedMarks)
  $before = $list.Count
  if ($list.Count -gt $MaxItems) {
    $over = $list.Count - $MaxItems
    $drop = New-Object System.Collections.Generic.List[object]
    for ($i = $list.Count - 1; $i -ge 0 -and $drop.Count -lt $over; $i--) {
      if (-not (Test-AnyMark $list[$i] $protected)) { $drop.Add($list[$i]) }
    }
    foreach ($d in $drop) { [void]$list.Remove($d) }
  }
  $total = 0
  $media = [long]0
  $cut = $false
  $keep = New-Object System.Collections.Generic.List[object]
  foreach ($r in $list) {
    $prot = Test-AnyMark $r $protected
    if ($cut) { if ($prot) { $keep.Add($r) }; continue }
    $total += (Get-RecordBytes $r)
    if ($total -gt $MaxTotal -and -not $prot) { $cut = $true; continue }
    # images and sidecars have their own budget: a screenshot must not evict every text row.
    # Only a row that can carry media is measured - a plain text row would answer 0 anyway,
    # and the call is a parse of the payload reference.
    $mb = [long]0
    if ($script:MaxMediaTotal -gt 0 -and ((Test-ImagePayload ([string]$r.Payload)) -or [string]$r.Rich)) {
      if (Get-Command Get-RecordMediaBytes -ErrorAction SilentlyContinue) { $mb = [long](Get-RecordMediaBytes $r) }
    }
    if ($mb -gt 0 -and ($media + $mb) -gt $script:MaxMediaTotal -and -not $prot) { continue }
    $media += $mb
    $keep.Add($r)
  }
  $list.Clear()
  foreach ($r in $keep) { $list.Add($r) }
  $script:TrimDropped = [int]($before - $keep.Count)
}

function Add-Item([string]$text, $capture = $null) {
  if ([string]::IsNullOrWhiteSpace($text)) { return }
  if ($script:ExcludePattern) {
    try { if ($text -match $script:ExcludePattern) { Write-Log 'skip (exclude pattern)'; return } } catch { }
  }
  $size = [long]0
  try { $size = [long]$Utf8.GetByteCount($text) } catch { $size = 0 }
  if ($size -gt $MaxBytes) { Write-Log ('skip oversize ' + $text.Length); return }
  # RS / US are the record delimiters: a payload carrying them would corrupt the store
  if (($text.IndexOf([char]30) -ge 0) -or ($text.IndexOf([char]31) -ge 0)) {
    $text = $text.Replace([char]30, ' ').Replace([char]31, ' ')
    Write-Log 'sanitized record separators in captured text'
  }
  # Media goes to disk first: the file is named after its content, so writing it twice is a
  # no-op and a record that is about to be deduplicated still points at the same bytes.
  $rich = ''
  if ($null -ne $capture) {
    if ($null -ne $capture.Image) { [void](Write-ImageMedia $text $capture.Image.Png) }
    if ($null -ne $capture.Rich) { $rich = New-RichRef $capture.Rich }
    if ($rich) { [void](Write-RichMedia $rich $capture.Rich) }
  }
  Use-StoreLock {
    $recs = @(Get-Records)
    if ($recs.Count -gt 0 -and $recs[0].Payload -ceq $text -and [string]$recs[0].Rich -ceq $rich) { return }
    # One pass keeps the marks of a payload that is already in the store and drops the older
    # copies of it. Comparing the payload is cheaper than hashing it: two strings that differ
    # answer on length or on the first character, and a long one is never copied.
    $prevMarks = ''
    $seen = $false
    $list = New-Object System.Collections.Generic.List[object]
    $fresh = New-Record $text (Get-Epoch) ''
    $fresh.Rich = $rich
    $list.Add($fresh)
    foreach ($r in $recs) {
      if ($r.Payload -ceq $text) {
        if (-not $seen) { $prevMarks = [string]$r.Marks; $seen = $true }
        continue
      }
      $list.Add($r)
    }
    $fresh.Marks = $prevMarks
    $list = Sort-Records $list
    Trim-Records $list
    # only a trim that dropped rows, or a payload that was already there, can have left media
    # or blobs behind: the two directory scans are for those cases
    Save-Records $list.ToArray() -SkipReclaim:([int]$script:TrimDropped -eq 0 -and -not $seen)
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

# Drop several payloads in one write. A batch delete would otherwise rewrite the whole store
# once per row. Protected rows stay and are reported, so the caller can say what was kept.
#   -> @{ Removed = n; Blocked = @(mark, ...) }
function Remove-Records([string[]]$payloads, [switch]$Force) {
  $r = Use-StoreLock {
    $drop = @{}
    foreach ($p in @($payloads)) { $drop[[string]$p] = 1 }
    $keep = New-Object System.Collections.Generic.List[object]
    $gone = 0
    $blocked = New-Object System.Collections.Generic.List[string]
    foreach ($rec in @(Get-Records)) {
      if (-not $drop.ContainsKey([string]$rec.Payload)) { $keep.Add($rec); continue }
      if (-not $Force.IsPresent) {
        $pm = Get-ProtectorMark $rec
        if ($pm) { $blocked.Add($pm); $keep.Add($rec); continue }
      }
      $gone++
    }
    if ($gone -gt 0) { Save-Records $keep.ToArray() }
    return @{ Removed = $gone; Blocked = $blocked.ToArray() }
  }
  return $r
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

# Replace the text of one entry: a typo fix, a trimmed path, a rewritten command. The row
# keeps its place, its time and its marks, because editing is not a new capture. Two things
# do change: the formatted sidecar goes (it described the old text, and pasting the old
# formatting over new words is worse than pasting none), and the key is bumped so the row
# and label caches redraw instead of serving the text they remember.
#   @{ Ok; Payload; Text; Error }
function Update-RecordText([string]$payload, [string]$text) {
  $res = @{ Ok = $false; Payload = $payload; Text = $text; Error = '' }
  if ([string]::IsNullOrWhiteSpace($text)) { $res.Error = 'the text is empty'; return $res }
  if ([string]$text -ceq $payload) { $res.Ok = $true; return $res }
  $verdict = Use-StoreLock {
    $recs = @(Get-Records)
    $target = $null
    foreach ($rec in $recs) { if ($rec.Payload -ceq $payload) { $target = $rec; break } }
    if ($null -eq $target) { return 'that entry is gone' }
    # payload is identity: a second row with the same text could never be told apart
    foreach ($rec in $recs) { if ($rec.Payload -ceq $text) { return 'another entry already says that' } }
    $target.Payload = [string]$text
    $target.Rich = ''
    $target.Blob = ''          # the save path decides again, by the new length
    $target.Key = [int](++$script:RecKey)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($rec in $recs) { $list.Add($rec) }
    Save-Records $list.ToArray() | Out-Null
    return ''
  }
  if ($verdict) { $res.Error = [string]$verdict; return $res }
  $res.Ok = $true
  return $res
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

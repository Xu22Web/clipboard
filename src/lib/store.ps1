# lib/store.ps1 - the history file: what is on disk, how it is parsed, locked, marked,
# trimmed, and the short labels used by `list` and the panel.
#
# The base stores one character per mark and asks the plugin layer what those marks mean
# (protected / sorts first / kept on clear / printed word), so adding a mark needs no
# change here - see Marks in lib/plugin/plugins.ps1.

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
  return [pscustomobject]@{ Payload = $payload; Time = $time; Marks = $marks; Key = 0; Blob = ''; Rich = ''; Gone = $false }
}

# The UTF-8 size of a payload.
function Get-RecordBytes($record) {
  if ($null -eq $record) { return [long]0 }
  try { return [long]$Utf8.GetByteCount([string]$record.Payload) } catch { return [long]0 }
}

# ---- blobs ------------------------------------------------------------------
# A payload past BlobChars is a file of its own: lib/blobs.ps1 owns Save-Blob, Read-Blob and
# the reclaim pass, and the line below only carries the reference it returns.

# Drop both caches. A caller that replaces the file behind the reader's back - a migration,
# a restore from a snapshot - says so through here instead of writing the cache variables,
# which are this module's own business and will change shape before they change meaning.
function Clear-RecordCache {
  $script:RecCache = $null
  $script:GateCache = $null
}

function Get-Records {
  # Parsing the whole store is the hottest path (panel open, filter, delete, undo), so the
  # result is cached against the file stamp: any writer changes size or write time.
  $stamp = Get-StoreFileStamp $StoreFile
  if ($stamp -eq 'none') { $script:RecCache = $null; return @() }
  if ($null -ne $script:RecCache -and $script:RecCache.Stamp -eq $stamp) { return $script:RecCache.Records }
  $raw = Read-StoreFileText $StoreFile
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
        Write-Log ('store not read: ' + $sv.Label)
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
      # 'x' is the type byte a delete appends: the line names the payload and nothing else,
      # and the list built below drops every line for that payload
      $isGone = ($flags.Length -gt 0 -and $flags[0] -ceq 'x')
      $marks = ''
      if (-not $isGone) { $marks = $flags.Substring(1) }
      # a blob reference is STX + 'B:' + 40 hex chars; anything else is the text itself
      if ($payload.Length -eq 43 -and $payload[0] -eq [char]2) {
        $full = Read-Blob $payload
        if ($null -eq $full) { continue }   # the blob is gone: the row goes with it
        $one = New-Record $full $tick $marks
        $one.Blob = $payload.Substring(3)
      } else {
        $one = New-Record $payload $tick $marks
      }
      # a reference we cannot parse is dropped rather than carried along
      if ((-not $isGone) -and $extra -and $null -ne (Get-RichRef $extra)) { $one.Rich = $extra }
      $one.Gone = $isGone
      $one.Key = [int](++$script:RecKey)
      $out.Add($one)
    }
  } catch { return @() }
  # Newest first, rebuilt from the ticks: a row that was appended again (a mark toggled, the
  # same text captured twice) carries its own time, so file order alone no longer says where
  # it goes. Sorting two int arrays is the cheap way to do it - a Comparison delegate over the
  # same 365 rows measured 26 ms.
  $script:RecLines = $out.Count
  $order = New-Object int[] $out.Count
  if ($out.Count -gt 1) {
    $keys = New-Object long[] $out.Count
    for ($i = 0; $i -lt $out.Count; $i++) {
      # ascending keys, so the sort yields newest first; the negated index keeps the later
    # line of two equal ticks in front, which is what makes an update win. The factor has to
    # exceed any row count the file can reach, or the index would outrank a second of time:
    # the fold threshold is twice MaxItems, and MaxItems tops out at 100000.
    $keys[$i] = ([long]$out[$i].Time * -1048576) - $i
      $order[$i] = $i
    }
    [Array]::Sort($keys, $order)
  } elseif ($out.Count -eq 1) { $order[0] = 0 }
  # The first line seen for a payload decides its fate: a tombstone means the payload is gone,
  # anything else is the row - and every older line for the same payload is dropped, because a
  # payload appears once whatever it was captured or deleted how many times.
  $seen = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::Ordinal)
  $rows = New-Object System.Collections.Generic.List[object]
  $goneCount = 0
  for ($k = 0; $k -lt $order.Length; $k++) {
    $one = $out[$order[$k]]
    $p = [string]$one.Payload
    if (-not $seen.Add($p)) { continue }
    if ($one.Gone) { $goneCount++; continue }
    $rows.Add($one)
  }
  $script:RecGone = $goneCount
  $rows = Sort-Records $rows
  # the file may carry rows the history no longer shows (an older copy of a payload, a row the
  # append log has not folded away yet): the list a caller gets is cut here
  $rows = Limit-Records $rows
  $script:RecCache = @{ Stamp = $stamp; Records = $rows.ToArray() }
  return $script:RecCache.Records
}

# At most MaxItems rows, cut from the tail, never dropping a row a plugin protects - the same
# rule Trim-Records applies when it rewrites the file. The file itself may hold more (it is an
# append log); this is where the difference between "on disk" and "in the panel" is made up.
function Limit-Records($rows) {
  if ($null -eq $rows -or $rows.Count -le $script:MaxItems) { return ,$rows }
  $over = $rows.Count - $script:MaxItems
  for ($i = $rows.Count - 1; $i -ge 0 -and $over -gt 0; $i--) {
    $proto = ''
    try { $proto = [string](Get-ProtectorMark $rows[$i]) } catch { $proto = '' }
    if ($proto) { continue }
    $rows.RemoveAt($i)
    $over--
  }
  # the comma keeps the list one object: a plain return would be unrolled into its rows
  return ,$rows
}

# What the file on disk carries, read from its first bytes only (the tag and the version
# field are the first two RS-separated fields, so this stays cheap on a 4 MB store).
#   Kind    none (no file) | current | old | newer | unknown
#   Version the layout version, -1 when the file is unrecognised
#   Hint    only what this module can state on its own; what to do about it belongs to
#           lib/migrate.ps1 (Get-StoreAdvice), which is the only place that knows the graph
# A reader refuses anything but current; `migrate` acts on the rest.
function Get-StoreVersion {
  $o = [pscustomobject]@{ Kind = 'none'; Version = -1; Label = 'no history file'; Hint = '' }
  # Every save asks this, and the answer can only change when the file does.
  $stamp = Get-StoreFileStamp $StoreFile
  if ($null -ne $script:GateCache -and $script:GateCache.Stamp -eq $stamp) { return $script:GateCache.Value }
  if (-not (Test-StoreFilePath $StoreFile)) {
    $script:GateCache = @{ Stamp = $stamp; Value = $o }
    return $o
  }
  $head = Read-StoreFileHead $StoreFile 64
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
  } else {
    $o.Kind = 'unknown'
    $o.Label = 'unrecognised layout'
  }
  $script:GateCache = @{ Stamp = $stamp; Value = $o }
  return $o
}

# One line of the store: flags US tick US extra US body, with a big payload swapped for its
# blob. Shared by the full rewrite and by the append a capture does, so both spell a row the
# same way.
function Get-RecordLine($r) {
  $body = [string]$r.Payload
  # a big payload lives in its own file, so a line is a few KB of history at most
  if ($body.Length -gt $script:BlobChars) {
    $r.Blob = Save-Blob $body
    $body = [string]$script:BlobMark + [string]$r.Blob
  } elseif ($r.Blob) { $r.Blob = '' }
  # 'x' is the type byte a delete appends: the line names the payload and nothing else, and
  # the read side drops every line for that payload. No marks, no sidecar - a tombstone is not
  # an entry, it is the newest statement about one.
  if ($r.Gone) { return ('x' + $US + [string][long]$r.Time + $US + $US + $body) }
  $flags = 't'
  if (Test-FilePayload ([string]$r.Payload)) { $flags = 'f' }
  elseif (Test-ImagePayload ([string]$r.Payload)) { $flags = 'i' }
  return ($flags + [string]$r.Marks + $US + [string][long]$r.Time + $US + [string]$r.Rich + $US + $body)
}

# A tick is the sort key, so writing one has to keep it growing: a burst of captures inside
# one second, or a wall clock that steps back, would otherwise file a row behind the tombstone
# or behind the older copy it is meant to replace. The list a caller holds is newest first, so
# the head carries the largest tick and the check costs one comparison.
function Get-NextTick($rows) {
  $tick = [long](Get-Epoch)
  foreach ($r in $rows) {
    if ($null -ne $r) {
      $head = [long]$r.Time
      if ($head -ge $tick) { $tick = $head + 1 }
    }
    break
  }
  return $tick
}

# One line at the end of the store. The file carries its rows oldest first, so a capture costs
# an append instead of a rewrite of the whole history; a read reverses the list and keeps the
# last line of each payload. Returns $false when the file cannot be appended to, and the caller
# falls back to a rewrite.
function Append-Record($record, [switch]$InPlace) {
  Ensure-Dir
  $sv = Get-StoreVersion
  if (@('old', 'newer', 'unknown') -contains $sv.Kind) {
    Write-Log ('store not appended: ' + $sv.Label)
    return $false
  }
  $line = Get-RecordLine $record
  $head = $TAG + $RS + [string]$script:DataVersion + $RS
  # the file separates its records with RS, so an append starts with one; a fresh file does
  # not, and the tool layer writes the header in that case
  if (-not (Append-StoreFileText $StoreFile ([string]$RS + $line) $head)) {
    Write-Log 'append failed'
    return $false
  }
  $script:RecLines = [int]$script:RecLines + 1
  if ($record.Gone) { $script:RecGone = [int]$script:RecGone + 1 }
  # A record that never went through the parser still has to get its number before it reaches
  # the read cache: key 0 is the "not numbered yet" value, so a capture appended here would
  # share it with every other appended row, and the panel caches its row text by that number -
  # every row then painted the label of the newest capture until the next full parse.
  if ([int]$record.Key -le 0) { $record.Key = [int](++$script:RecKey) }
  # The caller usually holds the parsed list, so keep it in step instead of re-parsing the
  # file: a capture goes in front, an updated row replaces itself where it was, and a
  # tombstone drops its payload.
  try {
    if ($null -ne $script:RecCache) {
      $list = New-Object System.Collections.Generic.List[object]
      $found = $false
      $front = ((-not $InPlace.IsPresent) -and (-not $record.Gone))
      if ($front) { $list.Add($record) }
      foreach ($r in @($script:RecCache.Records)) {
        if ([string]$r.Payload -cne [string]$record.Payload) { $list.Add($r); continue }
        $found = $true
        if ($InPlace.IsPresent -and (-not $record.Gone)) { $list.Add($record) }
      }
      if ((-not $front) -and (-not $found) -and (-not $record.Gone)) { $list.Add($record) }
      # a capture goes in front, so the list can now be one row too long
      if ($front) { $list = Limit-Records $list }
      $stamp = Get-StoreFileStamp $StoreFile
      $script:RecCache = @{ Stamp = $stamp; Records = $list.ToArray() }
      $script:GateCache = @{ Stamp = $stamp; Value = [pscustomobject]@{ Kind = 'current'; Version = $script:DataVersion; Label = ('CBHIST v' + $script:DataVersion); Hint = '' } }
    }
  } catch { }
  return $true
}

# The file grows while a delete leaves a tombstone behind and a mark change appends a new
# version of one row. Twice the rows the history may show, a third of the file being
# tombstones, or twice the text budget is where the list is folded back into a clean file -
# the only place that trims, reclaims orphan media and rewrites.
function Test-StoreFold {
  try {
    if ([int]$script:RecLines -gt ([int]$script:MaxItems * 2)) { return $true }
    if ([int]$script:RecGone -gt 0 -and (([int]$script:RecGone * 3) -ge [int]$script:RecLines)) { return $true }
    if ($script:MaxTextTotalBytes -gt 0) {
      $size = Get-StoreFileSize $StoreFile
      if ($size -gt ([long]$script:MaxTextTotalBytes * 2)) { return $true }
    }
  } catch { }
  return $false
}

# call with the store lock already held: read the rows back, trim them and write a clean file
function Save-FoldedStore {
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($r in @(Get-Records)) { $list.Add($r) }
  $list = Sort-Records $list
  Trim-Records $list
  $t0 = Get-Date
  Save-Records $list.ToArray()
  # a fold rewrites the whole file and reclaims what nobody points at; when a capture feels
  # slow this is the line that accounts for it
  Write-Log ('store: folded to ' + [string]$list.Count + ' rows in ' + [string]([int]((Get-Date) - $t0).TotalMilliseconds) + ' ms')
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
    Write-Log ('store not written: ' + $sv.Label)
    return
  }
  $script:StoreFormatWarned = $false
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append($TAG).Append($RS).Append([string]$script:DataVersion)
  if ($records) {
    # The file keeps its rows oldest first, so a capture can append and a read only has to
    # reverse the list. The caller hands rows newest first (or pinned first), so the order is
    # rebuilt here; the index rides along in the key to keep equal ticks stable.
    $ordered = @($records)
    $n = $ordered.Count
    if ($n -gt 1) {
      # Sort(keys, items) over two int arrays: handing it an object[] let PowerShell pick a
      # different overload, and the file came out in the order the caller happened to use
      $keys = New-Object long[] $n
      $idx = New-Object int[] $n
      for ($i = 0; $i -lt $n; $i++) { $keys[$i] = ([long]$ordered[$i].Time * 1048576) + $i; $idx[$i] = $i }
      [Array]::Sort($keys, $idx)
      $sorted = New-Object System.Collections.Generic.List[object]
      for ($i = 0; $i -lt $n; $i++) { $sorted.Add($ordered[$idx[$i]]) }
      $ordered = $sorted
    }
    foreach ($r in $ordered) {
      # spelled out rather than calling Get-RecordLine: one PowerShell call per row measured
      # 30 ms on a 365 row store, and this is the path a fold back from the append log takes
      $flags = 't'
      if (Test-FilePayload ([string]$r.Payload)) { $flags = 'f' }
      elseif (Test-ImagePayload ([string]$r.Payload)) { $flags = 'i' }
      $body = [string]$r.Payload
      if ($body.Length -gt $script:BlobChars) {
        $r.Blob = Save-Blob $body
        $body = [string]$script:BlobMark + [string]$r.Blob
      } elseif ($r.Blob) { $r.Blob = '' }
      [void]$sb.Append($RS).Append($flags + [string]$r.Marks).Append($US).Append([string][long]$r.Time).Append($US).Append([string]$r.Rich).Append($US).Append($body)
    }
  }
  if (-not (Write-StoreFileText $StoreFile $sb.ToString())) {
    Write-Log 'store write failed'
    return
  }
  # a rewrite drops every tombstone and every stale line, so the counters start over
  $script:RecGone = 0
  # The caller already holds the records it just wrote, so hand them to the read cache: the
  # next Get-Records would parse the whole file again after every write. Records that have
  # never been parsed get their number here.
  $script:RecCache = $null
  try {
    $arr = @($records)
    foreach ($r in $arr) { if ([int]$r.Key -le 0) { $r.Key = [int](++$script:RecKey) } }
    $stamp = Get-StoreFileStamp $StoreFile
    $script:RecLines = $arr.Count
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

# rows carrying the sort mark float to the top, and how many stay frozen: lib/ordering.ps1
# owns both rules, because the panel and a plugin ask the same questions.

# The rows the panel shows for one query. The meaning of the words lives in lib/query.ps1;
# this name stays for the callers that already hand in a plain token list.
function Select-QueryRows($entries, [string[]]$tokens) {
  return (Invoke-Query $entries (New-Query -Tokens @($tokens)))
}

# enforce MaxItems / MaxTextTotalBytes / MaxMediaTotalBytes in place; rows carrying a
# protected mark are never dropped. Media sizes travel inside the payload and the reference, so this never
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
    if ($total -gt $script:MaxTextTotalBytes -and -not $prot) { $cut = $true; continue }
    # images and sidecars have their own budget: a screenshot must not evict every text row.
    # Only a row that can carry media is measured - a plain text row would answer 0 anyway,
    # and the call is a parse of the payload reference.
    $mb = [long]0
    if ($script:MaxMediaTotalBytes -gt 0 -and ((Test-ImagePayload ([string]$r.Payload)) -or [string]$r.Rich)) {
      if (Get-Command Get-RecordMediaBytes -ErrorAction SilentlyContinue) { $mb = [long](Get-RecordMediaBytes $r) }
    }
    if ($mb -gt 0 -and ($media + $mb) -gt $script:MaxMediaTotalBytes -and -not $prot) { continue }
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
  if ($size -gt $script:MaxTextBytes) { Write-Log ('skip oversize ' + $text.Length); return }
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
    # a payload already in the store keeps its marks when it is captured again
    $prevMarks = ''
    foreach ($r in $recs) {
      if ($r.Payload -ceq $text) { $prevMarks = [string]$r.Marks; break }
    }
    $fresh = New-Record $text (Get-NextTick $recs) $prevMarks
    $fresh.Rich = $rich
    # The capture path is the hot one, so it appends one line instead of rewriting the whole
    # history. The file may then carry rows the panel already hides - a payload captured twice,
    # or one past MaxItems - so once it is big enough the list is folded into a clean file.
    if (Append-Record $fresh) {
      if (Test-StoreFold) { Save-FoldedStore }
      return
    }
    # the file refused the append (a layout this build does not write, a locked file): rewrite
    $list = New-Object System.Collections.Generic.List[object]
    $list.Add($fresh)
    foreach ($r in $recs) {
      if ($r.Payload -cne $text) { $list.Add($r) }
    }
    $list = Sort-Records $list
    Trim-Records $list
    Save-Records $list.ToArray()
  }
}

# Move an entry to the top without touching what it holds. Pasting something is how a user
# says "this one again", so the next panel should show it first: the marks, the rich sidecar
# and the blob reference all travel with it, only the time changes. Unlike Add-Item this never
# re-derives the media, which is what used to turn a formatted entry into a plain one.
function Touch-Record([string]$payload) {
  $moved = Use-StoreLock {
    $recs = @(Get-Records)
    if ($recs.Count -eq 0) { return $false }
    if ([string]$recs[0].Payload -ceq $payload) { return $false }
    $hit = $null
    foreach ($r in $recs) {
      if ([string]$r.Payload -ceq $payload) { $hit = $r; break }
    }
    if ($null -eq $hit) { return $false }
    $fresh = New-Record ([string]$hit.Payload) (Get-NextTick $recs) ([string]$hit.Marks)
    $fresh.Rich = [string]$hit.Rich
    $fresh.Blob = [string]$hit.Blob
    # the trick a capture uses: a newer line is enough, because the read side keeps the last
    # line of each payload and the older copies fall away
    if (Append-Record $fresh) { return $true }
    $list = New-Object System.Collections.Generic.List[object]
    $list.Add($fresh)
    # one payload is one row: the older copies of the same text go with the move
    foreach ($r in $recs) {
      if ([string]$r.Payload -ceq $payload) { continue }
      $list.Add($r)
    }
    $list = Sort-Records $list
    Save-Records $list.ToArray() -SkipReclaim
    return $true
  }
  return $moved
}

# a row carrying a protected mark is kept: the verb that removes the mark belongs to the
# plugin that declared it, so the base only reports which mark blocked the delete
function Remove-Record([string]$payload, [switch]$Force) {
  $r = Use-StoreLock {
    $target = $null
    foreach ($rec in @(Get-Records)) {
      if ([string]$rec.Payload -ceq $payload) { $target = $rec; break }
    }
    if ($null -eq $target) { return 'missing' }
    if (-not $Force.IsPresent) {
      $pm = Get-ProtectorMark $target
      if ($pm) { return ('protected:' + $pm) }
    }
    # A delete is one appended line, not a rewrite: the tombstone names the payload and the
    # read side drops every line for it. Its tick is the row's own, so an undo can append the
    # row again at the same tick and win by being the later line - a tombstone stamped with
    # the delete time would outrank it forever. The row's media is reclaimed when the log is
    # folded.
    $gone = New-Record ([string]$target.Payload) ([long]$target.Time) ''
    $gone.Gone = $true
    if (Append-Record $gone) {
      if (Test-StoreFold) { Save-FoldedStore }
      return 'removed'
    }
    # the file refused the append (a foreign layout, a locked file): lift it out by rewriting
    $keep = New-Object System.Collections.Generic.List[object]
    foreach ($rec in @(Get-Records)) {
      if ([string]$rec.Payload -cne $payload) { $keep.Add($rec) }
    }
    Save-Records $keep.ToArray()
    return 'removed'
  }
  return [string]$r
}

# A tick is the only sort key, and two rows sharing one are ordered by which line came last.
# Appending a row would therefore put it in front of the others in its own second, which is
# wrong for an edit or an undo (the row has to stay where it was). Callers ask here first: a
# row alone in its second can be appended, otherwise the rewrite keeps the order.
function Test-TickAlone($rows, [long]$tick, [string]$skipPayload) {
  $n = 0
  # walk the sequence as it arrives: wrapping a List[object] in @() and binding it back to an
  # untyped parameter answered "Argument types do not match" on this build
  foreach ($r in $rows) {
    if ($null -eq $r) { continue }
    if ([long]$r.Time -ne $tick) { continue }
    if ($skipPayload -and ([string]$r.Payload -ceq $skipPayload)) { continue }
    $n++
  }
  return ($n -eq 0)
}

function Restore-Record($record, [int]$index) {
  Use-StoreLock {
    if ($null -eq $record) { return $false }
    $recs = New-Object System.Collections.Generic.List[object]
    foreach ($r in @(Get-Records)) {
      if ($r.Payload -ceq $record.Payload) { return $false }
      $recs.Add($r)
    }
    # the row comes back as one appended line carrying its own tick: the read side keeps the
    # newest statement about a payload, so the tombstone that removed it needs no rewrite
    if (Test-TickAlone $recs ([long]$record.Time) '') {
      $fresh = New-Record ([string]$record.Payload) ([long]$record.Time) ([string]$record.Marks)
      $fresh.Rich = [string]$record.Rich
      $fresh.Blob = [string]$record.Blob
      $fresh.Key = [int](++$script:RecKey)
      if (Append-Record $fresh) {
        # the append keeps the row at the end of the list it updated, so drop the cache and
        # let the next read put it back where its tick says it belongs
        Clear-RecordCache
        if (Test-StoreFold) { Save-FoldedStore }
        return $true
      }
    }
    if ($index -lt 0) { $index = 0 }
    if ($index -gt $recs.Count) { $index = $recs.Count }
    $recs.Insert($index, $record)
    $recs = Sort-Records $recs
    Save-Records $recs.ToArray()
    return $true
  }
}

# Drop several payloads in one write. A batch delete would otherwise rewrite the whole store
# once per row. Protected rows stay and are reported, so the caller can say what was kept.
#   -> @{ Removed = n; Blocked = @(mark, ...) }
function Remove-Records([string[]]$payloads, [switch]$Force) {
  $r = Use-StoreLock {
    $drop = @{}
    foreach ($p in @($payloads)) { $drop[[string]$p] = 1 }
    $victims = New-Object System.Collections.Generic.List[object]
    $blocked = New-Object System.Collections.Generic.List[string]
    foreach ($rec in @(Get-Records)) {
      if (-not $drop.ContainsKey([string]$rec.Payload)) { continue }
      if (-not $Force.IsPresent) {
        $pm = Get-ProtectorMark $rec
        if ($pm) { $blocked.Add($pm); continue }
      }
      $victims.Add($rec)
    }
    # one tombstone per row, and one fold check for the batch: a delete is an append, not a
    # rewrite, which is what made a batch delete cost one rewrite per row before
    $wrote = $true
    foreach ($rec in $victims) {
      # the row's own tick, for the same reason as a single delete: an undo appends at that
      # tick and has to win
      $gone = New-Record ([string]$rec.Payload) ([long]$rec.Time) ''
      $gone.Gone = $true
      if (-not (Append-Record $gone)) { $wrote = $false; break }
    }
    if (-not $wrote) {
      $keep = New-Object System.Collections.Generic.List[object]
      foreach ($rec in @(Get-Records)) {
        if (-not $drop.ContainsKey([string]$rec.Payload)) { $keep.Add($rec); continue }
        if ($blocked.Count -gt 0 -and (Get-ProtectorMark $rec)) { $keep.Add($rec) }
      }
      Save-Records $keep.ToArray()
    } elseif (Test-StoreFold) { Save-FoldedStore }
    return @{ Removed = $victims.Count; Blocked = $blocked.ToArray() }
  }
  return $r
}

# Toggle one mark on the entry that carries this payload. The row is appended again with the
# same payload and time and its new marks: the read side keeps the newest line for a payload,
# and the unchanged time keeps the row where it was. That makes pinning a row an append
# instead of a rewrite of the whole history.
function Set-Mark([string]$payload, [string]$mark, [bool]$on) {
  $r = Use-StoreLock {
    $target = $null
    foreach ($rec in @(Get-Records)) { if ($rec.Payload -ceq $payload) { $target = $rec; break } }
    if ($null -eq $target) { return $false }
    if (-not (Set-RecordMark $target $mark $on)) { return $false }
    if (Append-Record $target -InPlace) {
      if (Test-StoreFold) { Save-FoldedStore }
      return $true
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($rec in @(Get-Records)) { $list.Add($rec) }
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
    $tick = [long]$target.Time
    # An edit writes two lines instead of the whole file: a tombstone for the old text, then
    # the row under its new text with the same tick and marks. The tombstone comes first
    # because the later line wins at an equal tick. A row that shares its tick is rewritten
    # instead, since appending would also move it in front of the others in its second.
    if (Test-TickAlone $recs $tick $payload) {
      $gone = New-Record ([string]$payload) $tick ''
      $gone.Gone = $true
      $fresh = New-Record ([string]$text) $tick ([string]$target.Marks)
      $fresh.Key = [int](++$script:RecKey)
      if ((Append-Record $gone) -and (Append-Record $fresh)) {
        Clear-RecordCache
        if (Test-StoreFold) { Save-FoldedStore }
        # the formatted sidecar described the old text, and the old blob belongs to nobody now
        try { Remove-OrphanBlobs @(Get-Records) } catch { }
        return ''
      }
    }
    # the fallback writes the snapshot this lock started from: reading the file again here
    # would lose the row when the tombstone landed and the replacement did not
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

# Mutate the record list under the store lock. A plugin needs this when one change spans
# several rows (a cap on its own mark, for example) and must stay a single write.
#
# Only the rows the hook actually changed are appended again, so flipping one mark costs one
# line instead of a rewrite. A row whose *payload* changed cannot be expressed that way - the
# old text would still be a line of its own - so that case, which is an edit rather than a
# mark change, still rewrites the file.
# The parameter is deliberately not called $body: Use-StoreLock uses that name, and a
# scriptblock would resolve it to the lock's own copy and call itself forever.
function Update-Records([scriptblock]$mutate) {
  return Use-StoreLock {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($r in @(Get-Records)) { $rows.Add($r) }
    $beforePayload = New-Object System.Collections.Generic.List[string]
    $beforeState = New-Object System.Collections.Generic.List[string]
    foreach ($r in $rows) {
      $beforePayload.Add([string]$r.Payload)
      $beforeState.Add(([string]$r.Marks + [string][char]31 + [string]$r.Rich + [string][char]31 + [string]$r.Time))
    }
    $out = & $mutate $rows
    $changed = New-Object System.Collections.Generic.List[object]
    $renamed = $false
    for ($i = 0; $i -lt $rows.Count; $i++) {
      # a new payload means the old text would survive as a line of its own: that is an edit,
      # not a mark change, and it still needs the rewrite
      if ([string]$rows[$i].Payload -cne $beforePayload[$i]) { $renamed = $true; continue }
      $state = ([string]$rows[$i].Marks + [string][char]31 + [string]$rows[$i].Rich + [string][char]31 + [string]$rows[$i].Time)
      if ($state -ceq $beforeState[$i]) { continue }
      $changed.Add($rows[$i])
    }
    if ($renamed) {
      # A renamed row is an edit too: a tombstone for the old payload and the row again under
      # the new one, which costs two lines instead of the file. The rows only line up with the
      # input when none was added or dropped, and a row sharing its tick has to keep its place
      # - both cases fall back to the rewrite below.
      $appendable = ($rows.Count -eq $beforePayload.Count)
      if ($appendable) {
        for ($i = 0; $i -lt $rows.Count; $i++) {
          if ([string]$rows[$i].Payload -ceq $beforePayload[$i]) { continue }
          if (-not (Test-TickAlone $rows ([long]$rows[$i].Time) ([string]$rows[$i].Payload))) { $appendable = $false; break }
        }
      }
      if ($appendable) {
        $wrote = $true
        for ($i = 0; $i -lt $rows.Count; $i++) {
          if ([string]$rows[$i].Payload -ceq $beforePayload[$i]) { continue }
          $gone = New-Record $beforePayload[$i] ([long]$rows[$i].Time) ''
          $gone.Gone = $true
          if (-not (Append-Record $gone)) { $wrote = $false; break }
          if (-not (Append-Record $rows[$i])) { $wrote = $false; break }
        }
        if ($wrote) {
          Clear-RecordCache
          if (Test-StoreFold) { Save-FoldedStore }
          return $out
        }
      }
      $rows = Sort-Records $rows
      Save-Records $rows.ToArray()
      return $out
    }
    if ($changed.Count -eq 0) { return $out }
    $failed = $false
    foreach ($r in $changed) { if (-not (Append-Record $r -InPlace)) { $failed = $true; break } }
    if ($failed) {
      $rows = Sort-Records $rows
      Save-Records $rows.ToArray()
    } elseif (Test-StoreFold) { Save-FoldedStore }
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

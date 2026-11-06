# lib/transfer.ps1 - taking the history out and putting it back.
#
# An export is a small text document (utils/transfer.ps1 owns the shapes); this file turns
# records into those rows, reads media off the disk when asked, and on import writes media
# back under the name its own bytes hash to - an incoming reference is never trusted, because
# a hand-edited file could point anywhere in data\media.
#
# Merge keeps what the store already has: an entry that is already there stays exactly as it
# is, marks included. Replace swaps the whole history after a backup this build can undo.
#
# `backup` zips history, media and blobs into data\backup; `restore` puts one of those zips
# back (and takes a fresh snapshot of what it replaces first). Both need Compress-Archive /
# Expand-Archive, which every supported Windows has - a machine without them gets a one-line
# "not available here" instead of an exception.

function Get-ExportFormat([string]$path) {
  $ext = [IO.Path]::GetExtension($path)
  if (-not $ext) { return 'json' }
  $name = $ext.TrimStart('.').ToLowerInvariant()
  switch ($name) {
    'json' { return 'json' }
    'csv' { return 'csv' }
    'txt' { return 'txt' }
  }
  return ''
}

# one record -> one transfer row; media is read off the disk only when it is wanted
function Get-TransferRow($record, [switch]$Media) {
  $row = @{ Text = [string]$record.Payload; Time = [long]$record.Time; Marks = [string]$record.Marks; Media = $null }
  if (-not $Media.IsPresent) { return $row }
  $media = [ordered]@{}
  $payload = [string]$record.Payload
  if (Test-ImagePayload $payload) {
    $ref = Get-ImageRef $payload
    if ($null -ne $ref) {
      $bytes = Read-ImageBytes $ref.Sha1
      if ($null -ne $bytes) { $media['image'] = @{ ext = $ref.Fmt.ToLowerInvariant(); data = (ConvertTo-TransferBase64 $bytes) } }
    }
  }
  $rich = [string]$record.Rich
  if ($rich) {
    $blocks = New-Object System.Collections.Generic.List[object]
    $r = Get-RichRef $rich
    if ($null -ne $r) {
      foreach ($b in $r.Blocks) {
        $bytes = Read-RichBlock $rich $b.Tag
        if ($null -eq $bytes) { continue }
        $blocks.Add(@{ tag = [string]$b.Tag; ext = [string]$b.Ext; data = (ConvertTo-TransferBase64 $bytes) })
      }
    }
    if ($blocks.Count -gt 0) { $media['rich'] = $blocks.ToArray() }
  }
  if ($media.Count -gt 0) { $row.Media = $media }
  return $row
}

# Write the history to a file. Returns the number of entries and the path.
function Invoke-Export([string]$path, [switch]$Media) {
  if (-not $path) { return @{ Ok = $false; Message = 'export needs a path' } }
  $format = Get-ExportFormat $path
  if (-not $format) { return @{ Ok = $false; Message = 'export writes .json, .csv or .txt' } }
  if ($format -ne 'json' -and $Media.IsPresent) {
    return @{ Ok = $false; Message = ('-Media needs a .json file: ' + $format + ' cannot carry pictures') }
  }
  $records = @(Get-Records)
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($rec in $records) { $rows.Add((Get-TransferRow $rec -Media:$Media)) }
  $body = ''
  switch ($format) {
    'json' { $body = ConvertTo-TransferJson $rows.ToArray() }
    'csv' { $body = ConvertTo-TransferCsv $rows.ToArray() }
    'txt' { $body = ConvertTo-TransferText $rows.ToArray() }
  }
  try { [IO.File]::WriteAllText($path, $body, $Utf8) } catch {
    return @{ Ok = $false; Message = ('cannot write ' + $path + ': ' + $_.Exception.Message) }
  }
  return @{ Ok = $true; Message = ('exported ' + $records.Count + ' entries to ' + $path); Count = $records.Count }
}

# Rebuild the payload and sidecar of one imported row from the media blocks it carries. The
# names come from the bytes, so the store stays content-addressed whatever the file said.
function Restore-TransferMedia($row) {
  $text = [string]$row.Text
  $rich = ''
  $media = $row.Media
  if ($null -eq $media) { return @{ Text = $text; Rich = '' } }
  if ($null -ne $media.image) {
    $bytes = ConvertFrom-TransferBase64 ([string]$media.image.data)
    if ($null -ne $bytes) {
      $fmt = [string]$media.image.ext
      if (-not $fmt) { $fmt = 'png' }
      $w = 0
      $h = 0
      try {
        Load-Forms
        $ms = New-Object IO.MemoryStream
        $ms.Write($bytes, 0, $bytes.Length)
        $ms.Position = 0
        $img = [Drawing.Image]::FromStream($ms)
        $w = $img.Width
        $h = $img.Height
        $img.Dispose()
      } catch { }
      if ($w -gt 0 -and $h -gt 0) {
        $text = New-ImagePayload $bytes $w $h $fmt
        [void](Write-ImageMedia $text $bytes)
      }
    }
  }
  if ($null -ne $media.rich) {
    $html = $null
    $rtf = $null
    $extra = @{}
    foreach ($b in @($media.rich)) {
      $bytes = ConvertFrom-TransferBase64 ([string]$b.data)
      if ($null -eq $bytes) { continue }
      $tag = ([string]$b.tag).ToUpperInvariant()
      switch ($tag) {
        'H' { $html = $bytes }
        'T' { $rtf = $bytes }
        default { $extra[$tag] = $bytes }
      }
    }
    if ($null -ne $html -or $null -ne $rtf -or $extra.Count -gt 0) {
      # the sidecar takes html and rtf under their own keys and every picture in Blocks, so
      # the reference is rebuilt from the bytes rather than from the file's strings
      $blocks = @()
      foreach ($k in @($extra.Keys)) { $blocks += @{ Tag = [string]$k; Data = $extra[$k] } }
      $sidecar = @{ Html = $html; Rtf = $rtf; Blocks = $blocks }
      $rich = New-RichRef $sidecar
      if ($rich) { [void](Write-RichMedia $rich $sidecar) }
    }
  }
  return @{ Text = $text; Rich = $rich }
}

# Read a document back into rows. $null means "this file is not one of ours".
function Read-TransferFile([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $raw = $null
  try { $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) } catch { return $null }
  if (-not $raw) { return $null }
  $format = Get-ExportFormat $path
  if ($format -eq 'json') { return (ConvertFrom-TransferJson $raw) }
  if ($format -eq 'csv') { return (ConvertFrom-TransferCsv $raw) }
  return $null
}

# Put a document into the store. Merge keeps an entry the store already has untouched; replace
# swaps everything, after a backup, in one write.
function Invoke-Import([string]$path, [switch]$Replace) {
  if (-not $path) { return @{ Ok = $false; Message = 'import needs a path' } }
  $doc = Read-TransferFile $path
  if ($null -eq $doc) { return @{ Ok = $false; Message = ('not a history export this build can read: ' + $path) } }
  $rows = @($doc.Rows)
  if ($Replace.IsPresent) {
    $snap = Save-Snapshot
    if (-not $snap.Ok) { return @{ Ok = $false; Message = ('cannot back up the current history: ' + $snap.Message) } }
  }
  $result = Use-StoreLock {
    $have = @(Get-Records)
    $list = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    if (-not $Replace.IsPresent) {
      foreach ($rec in $have) {
        $list.Add($rec)
        $seen[[string]$rec.Payload] = 1
      }
    }
    $added = 0
    $kept = 0
    foreach ($row in $rows) {
      $restored = Restore-TransferMedia $row
      $text = [string]$restored.Text
      if ([string]::IsNullOrEmpty($text)) { continue }
      if ($seen.ContainsKey($text)) { $kept++; continue }
      $seen[$text] = 1
      $rec = New-Record $text ([long]$row.Time) ([string]$row.Marks)
      $rec.Rich = [string]$restored.Rich
      $list.Add($rec)
      $added++
    }
    $sorted = Sort-Records $list
    Trim-Records $sorted
    Save-Records $sorted.ToArray()
    return @{ Added = $added; Kept = $kept }
  }
  $msg = 'imported ' + [int]$result.Added + ' entries'
  if ([int]$result.Kept -gt 0) { $msg = $msg + ', ' + [int]$result.Kept + ' already there' }
  return @{ Ok = $true; Message = $msg; Added = [int]$result.Added; Kept = [int]$result.Kept }
}

# A zip of the whole data folder: history, media and blobs travel together, which is the only
# way a picture entry survives a restore.
# A snapshot is a zip of the whole data folder. Compress-Archive ships with PowerShell 5.1 on
# a machine that has .NET 4.5 or newer; when it is missing the command says so instead of
# throwing, because nothing else in the tool needs it.
function Test-ArchiveSupport([string]$cmd) {
  if (Get-Command $cmd -ErrorAction SilentlyContinue) { return '' }
  return ('this system has no ' + $cmd + ' (PowerShell 5.1 with .NET 4.5 or newer is required)')
}

function Save-Snapshot([string]$Name = '') {
  Ensure-Dir
  $gap = Test-ArchiveSupport 'Compress-Archive'
  if ($gap) { return @{ Ok = $false; Message = $gap } }
  $dir = Join-Path $StoreDir 'backup'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
  $leaf = 'clipboard-' + $stamp
  if ($Name) { $leaf = $leaf + '-' + ($Name -replace '[^\w\-]', '') }
  $zip = Join-Path $dir ($leaf + '.zip')
  try {
    $items = @()
    foreach ($n in @('history.dat', 'media', 'blobs')) {
      $p = Join-Path $StoreDir $n
      if (Test-Path -LiteralPath $p) { $items += $p }
    }
    if ($items.Count -eq 0) { return @{ Ok = $false; Message = 'there is nothing to back up yet' } }
    Compress-Archive -LiteralPath $items -DestinationPath $zip -CompressionLevel Optimal -Force
  } catch {
    return @{ Ok = $false; Message = ('cannot write ' + $zip + ': ' + $_.Exception.Message) }
  }
  return @{ Ok = $true; Path = $zip; Message = ('backup written: ' + $zip) }
}

function Get-SnapshotList {
  $dir = Join-Path $StoreDir 'backup'
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  $out = @()
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'clipboard-*.zip' -ErrorAction SilentlyContinue)) { $out += $f.FullName }
  return $out
}

# Put a snapshot back. The current history is backed up first, so a wrong pick is undoable.
function Invoke-Restore([string]$Name) {
  $gap = Test-ArchiveSupport 'Expand-Archive'
  if ($gap) { return @{ Ok = $false; Message = $gap } }
  $all = @(Get-SnapshotList)
  if ($all.Count -eq 0) { return @{ Ok = $false; Message = 'no snapshot in data\backup' } }
  $pick = ''
  if (-not $Name) {
    $pick = [string]$all[$all.Count - 1]
  } else {
    foreach ($p in $all) {
      if ([IO.Path]::GetFileNameWithoutExtension($p) -eq $Name) { $pick = $p; break }
    }
    if (-not $pick) {
      foreach ($p in $all) { if ([IO.Path]::GetFileNameWithoutExtension($p) -like ('*' + $Name + '*')) { $pick = $p } }
    }
  }
  if (-not $pick) { return @{ Ok = $false; Message = ('no snapshot matches: ' + $Name) } }
  $snap = Save-Snapshot 'before-restore'
  if (-not $snap.Ok) { return @{ Ok = $false; Message = ('cannot back up the current history: ' + $snap.Message) } }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('clipboard-restore-' + [DateTime]::Now.ToString('yyyyMMddHHmmss'))
  try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Expand-Archive -LiteralPath $pick -DestinationPath $tmp -Force
    foreach ($n in @('history.dat', 'media', 'blobs')) {
      $src = Join-Path $tmp $n
      if (-not (Test-Path -LiteralPath $src)) { continue }
      $dst = Join-Path $StoreDir $n
      if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
      Move-Item -LiteralPath $src -Destination $dst -Force
    }
  } catch {
    return @{ Ok = $false; Message = ('cannot restore ' + $pick + ': ' + $_.Exception.Message) }
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  }
  # the file was replaced behind the store's back, so both caches have to go: the parsed
  # records and the layout gate, or the next save would judge a file it never read
  Clear-RecordCache
  return @{ Ok = $true; Message = ('restored ' + [IO.Path]::GetFileName($pick) + ' (' + @(Get-Records).Count + ' entries)') }
}

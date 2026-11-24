# utils/log.ps1 - the log file and the directory it lives in.
#
# The only place in the tool that appends to disk on its own: Write-Log never throws, so a
# caller can log from a catch block without masking the original failure. The store
# directory is created on demand because the log is written before anything else runs.

function Ensure-Dir {
  if (-not (Test-Path -LiteralPath $StoreDir)) { New-Item -ItemType Directory -Path $StoreDir -Force | Out-Null }
}

# capped at 64 KB: the log is a debugging aid, not an archive. Past the cap the newest half
# is kept - a fault is usually the last thing that happened, and starting again from an empty
# file threw that away exactly when it was needed.
$script:LogMaxBytes = 65536
# A line used to cost about seven milliseconds, five of them for the directory test and the
# size of the file, and the panel writes several lines per open - a tenth of the time it took
# to appear. The directory is looked at once per process instead, and the size is looked at
# again only after this many bytes were written here, which holds the cap to within that much
# (a line is under two hundred bytes).
$script:LogCheckEvery = 4096
$script:LogPending = -1
$script:LogDirReady = $false

function Write-Log([string]$msg) {
  try {
    if (-not $script:LogDirReady) {
      Ensure-Dir
      $script:LogDirReady = $true
    }
    $line = (Get-Date -Format 'MM-dd HH:mm:ss') + ' ' + $msg + [Environment]::NewLine
    if ($script:LogPending -lt 0 -or $script:LogPending -ge $script:LogCheckEvery) {
      $script:LogPending = 0
      $len = 0
      # -ErrorAction SilentlyContinue: a missing log file is the normal first run, and a
      # non-terminating error would print over whatever the user asked for
      try { $len = [long](Get-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue).Length } catch { $len = 0 }
      $script:LogSize = $len
    }
    if ($script:LogSize -gt $script:LogMaxBytes) {
      $keep = [int]($script:LogMaxBytes / 2)
      $tail = ''
      try {
        $all = ''
        if (Test-Path -LiteralPath $LogFile) { $all = [IO.File]::ReadAllText($LogFile, $Utf8) }
        if ($all.Length -gt $keep) { $tail = $all.Substring($all.Length - $keep) }
        # start on a line boundary, so the first line is not a fragment of one
        $nl = $tail.IndexOf([char]10)
        if ($nl -ge 0) { $tail = $tail.Substring($nl + 1) }
      } catch { $tail = '' }
      [IO.File]::WriteAllText($LogFile, $tail, $Utf8)
      # the truncation itself is an event: without a line for it the reader cannot tell a log
      # that starts here from one whose older half was thrown away. Only what this file already
      # has is used - log.ps1 loads before the formatters do.
      [IO.File]::AppendAllText($LogFile, ((Get-Date -Format 'MM-dd HH:mm:ss') + ' log rotated (kept the last ' + [string]$keep + ' bytes)' + [Environment]::NewLine), $Utf8)
      # what is there now, so the next line does not truncate the file again
      try { $script:LogSize = [long](Get-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue).Length } catch { $script:LogSize = 0 }
    }
    [IO.File]::AppendAllText($LogFile, $line, $Utf8)
    $bytes = $Utf8.GetByteCount($line)
    $script:LogSize += $bytes
    $script:LogPending += $bytes
  } catch { $script:LogDirReady = $false }
}

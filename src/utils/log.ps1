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

function Write-Log([string]$msg) {
  try {
    Ensure-Dir
    if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt $script:LogMaxBytes) {
      $keep = [int]($script:LogMaxBytes / 2)
      $tail = ''
      try {
        $all = [IO.File]::ReadAllText($LogFile, $Utf8)
        if ($all.Length -gt $keep) { $tail = $all.Substring($all.Length - $keep) }
        # start on a line boundary, so the first line is not a fragment of one
        $nl = $tail.IndexOf([char]10)
        if ($nl -ge 0) { $tail = $tail.Substring($nl + 1) }
      } catch { $tail = '' }
      [IO.File]::WriteAllText($LogFile, $tail, $Utf8)
    }
    [IO.File]::AppendAllText($LogFile, ((Get-Date -Format 'MM-dd HH:mm:ss') + ' ' + $msg + [Environment]::NewLine), $Utf8)
  } catch { }
}

# utils/log.ps1 - the log file and the directory it lives in.
#
# The only place in the tool that appends to disk on its own: Write-Log never throws, so a
# caller can log from a catch block without masking the original failure. The store
# directory is created on demand because the log is written before anything else runs.

function Ensure-Dir {
  if (-not (Test-Path -LiteralPath $StoreDir)) { New-Item -ItemType Directory -Path $StoreDir -Force | Out-Null }
}

# capped at 64 KB: the log is a debugging aid, not an archive
function Write-Log([string]$msg) {
  try {
    Ensure-Dir
    if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 65536) {
      Remove-Item -LiteralPath $LogFile -Force
    }
    [IO.File]::AppendAllText($LogFile, ((Get-Date -Format 'MM-dd HH:mm:ss') + ' ' + $msg + [Environment]::NewLine), $Utf8)
  } catch { }
}

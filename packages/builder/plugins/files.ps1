# packages\builder\plugins\files.ps1 - the file list, expanded.
#
# This is this package's extension plugin for the config: electron-builder keeps "files" as a
# glob list in which "!pattern" removes, and so does builder.ini. One expansion for both, through
# the same splitter the rest of the tooling uses, so a glob means the same thing everywhere.
function Get-BuilderFileList {
  param(
    [Parameter(Mandatory = $true)]$Config,
    [Parameter(Mandatory = $true)][string]$BaseDir,
    [string]$Setting = 'files.Files'
  )
  $all = @(Split-GlobList ([string]$Config[$Setting]))
  if ($all.Count -eq 0) { throw ('builder.ini [' + $Setting + '] is empty') }
  $include = @($all | Where-Object { -not $_.StartsWith('!') })
  $exclude = @($all | Where-Object { $_.StartsWith('!') } | ForEach-Object { $_.Substring(1) })
  if ($include.Count -eq 0) { throw ('builder.ini [' + $Setting + '] lists only exclusions') }
  $files = @(Expand-GlobList $BaseDir $include $exclude)
  if ($files.Count -eq 0) { throw ('builder.ini [' + $Setting + '] reaches no file') }
  return @{
    Include = $include
    Exclude = $exclude
    Files   = $files
    Dropped = (@(Expand-GlobList $BaseDir $include @()).Count - $files.Count)
  }
}

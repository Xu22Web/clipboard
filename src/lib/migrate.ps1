# lib/migrate.ps1 - the data upgrade: `clipboard migrate` (and install.bat) brings a history
# file written by an older build up to the layout this build reads.
#
# The file carries its layout version in the header, so a release that changes the records
# bumps $script:DataVersion in base.ps1 and adds exactly one step here:
#
#   base.ps1   $script:DataVersion = 2
#   this file  '1' = @{ From = 'text and marks as v1'; Apply = { param($ctx) ... } }
#
# A step upgrades one version in place. It receives a context and writes the result back:
#
#   $ctx.Text      the whole file; assign the next version's text back to it
#   $ctx.From      the version it upgrades from
#   $ctx.To        $ctx.From + 1 - the version the result must carry
#   $ctx.StoreDir  the data folder, for a step that also has to rewrite media\ or blobs\
#
# A step never touches the disk, so it is a pure transform and can be tested on its own. The
# engine re-reads the header after each migration, so a step that forgets the version field
# fails loudly instead of leaving a file the reader refuses.
#
# The table holds one step per version transition. No layout has been released yet, so it is
# empty: a file that cannot be upgraded is archived by `migrate -Purge`, never guessed at.
$script:MigrationSteps = [ordered]@{
}

# Is there a complete chain of steps from $from up to the version this build reads?
function Test-MigrationPath([int]$from) {
  if ($from -lt 0 -or $from -ge $script:DataVersion) { return $false }
  for ($v = $from; $v -lt $script:DataVersion; $v++) {
    if (-not $script:MigrationSteps.Contains([string]$v)) { return $false }
  }
  return $true
}

# What to tell the user about a file this build does not read. Get-StoreVersion reports the
# facts (kind, version, label) and knows nothing about upgrade paths, so the advice lives
# here, next to the table that decides it.
function Get-StoreAdvice($sv) {
  if ($null -eq $sv) { return '' }
  if ($sv.Hint) { return [string]$sv.Hint }
  if ($sv.Kind -eq 'old') {
    if (Test-MigrationPath ([int]$sv.Version)) { return 'run: clipboard migrate' }
    return 'no migration path in this build - clipboard migrate -Purge archives it'
  }
  if ($sv.Kind -eq 'unknown') { return 'clipboard migrate -Purge archives it' }
  return ''
}

# Keep the file as it was, next to the store, so a migration can be undone by hand.
function Save-StoreBackup([int]$from) {
  $dir = Join-Path $StoreDir 'backup'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $path = Join-Path $dir ('history-v' + $from + '-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.dat')
  Copy-Item -LiteralPath $StoreFile -Destination $path -Force
  return $path
}

# Upgrade history.dat in place and return a report. Nothing is written when the file is
# already current, newer than this build, or has no migration path - the caller prints the
# message. -Purge archives a file that cannot be migrated instead of refusing.
function Invoke-DataMigration {
  param([switch]$Purge)
  $o = [pscustomobject]@{
    From = -1; To = $script:DataVersion; Steps = 0; Backup = ''; Changed = $false; Message = ''
  }
  $sv = Get-StoreVersion
  $o.From = $sv.Version
  if ($sv.Kind -eq 'none') { $o.Message = 'no history file, nothing to migrate'; return $o }
  if ($sv.Kind -eq 'current') { $o.Message = ('already ' + $sv.Label + ', nothing to migrate'); return $o }
  if ($sv.Kind -eq 'newer') { $o.Message = ('[!] ' + $sv.Label + ' is newer than this build (v' + $script:DataVersion + '), ' + (Get-StoreAdvice $sv)); return $o }
  if (-not (Test-MigrationPath $sv.Version)) {
    if (-not $Purge) { $o.Message = ('[!] ' + $sv.Label + ' cannot be upgraded, ' + (Get-StoreAdvice $sv)); return $o }
    $o.Backup = Save-StoreBackup $sv.Version
    Remove-Item -LiteralPath $StoreFile -Force
    Clear-RecordCache
    $script:StoreFormatWarned = $false
    $o.Changed = $true
    $o.Message = ('archived ' + $sv.Label + ' to ' + $o.Backup)
    Write-Log ('migration: ' + $o.Message)
    return $o
  }
  $raw = ''
  try { $raw = [IO.File]::ReadAllText($StoreFile, [Text.Encoding]::UTF8) } catch { $o.Message = ('[!] cannot read ' + $StoreFile); return $o }
  $o.Backup = Save-StoreBackup $sv.Version
  $ctx = @{ Text = $raw; From = $sv.Version; To = $sv.Version; StoreDir = $StoreDir }
  for ($v = $sv.Version; $v -lt $script:DataVersion; $v++) {
    $step = $script:MigrationSteps[[string]$v]
    $ctx.From = $v
    $ctx.To = $v + 1
    & $step['Apply'] $ctx
    $o.Steps++
  }
  $tmp = $StoreFile + '.tmp'
  [IO.File]::WriteAllText($tmp, [string]$ctx.Text, $Utf8)
  Move-Item -LiteralPath $tmp -Destination $StoreFile -Force
  Clear-RecordCache
  $script:StoreFormatWarned = $false
  $check = Get-StoreVersion
  $o.To = $check.Version
  $o.Changed = $true
  if ($check.Kind -ne 'current') { $o.Message = ('[!] ' + $sv.Label + ' left as ' + $check.Label + ', backup: ' + $o.Backup) }
  else { $o.Message = ('migrated ' + $sv.Label + ' to ' + $check.Label + ', backup: ' + $o.Backup) }
  Write-Log ('migration: ' + $o.Message)
  return $o
}

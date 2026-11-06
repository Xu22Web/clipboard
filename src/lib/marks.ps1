# lib/marks.ps1 - reading and changing the single-character marks a record carries.
#
# A record stores its marks as one string of characters ("tps" = text row, pinned, starred)
# and the base never knows what any of them mean: the plugin that declares a mark owns its
# meaning, and lib/plugin-marks.ps1 answers the questions about it. This file is the thin
# layer in between - is the mark set, set it, which marks protect a row, what does a row call
# them - and it touches no file. Writing the result back is lib/store.ps1's job, so a mark
# can be inspected, tested and reasoned about without a history file.
#
# Without a plugin layer every list here is empty: nothing is protected, nothing sorts first
# and nothing can be marked at all.

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

# mark declarations come from the plugin layer; without plugins the list is empty
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

# lib/plugin-marks.ps1 - what the marks a plugin declares actually mean.
#
# The base stores one character per mark and asks this file for the rules: is the row
# protected, does it sort first, which marks survive `clear`, and what word is printed.
# That is why adding a mark never needs a change in lib/store.ps1.
#
# Loaded right after lib/plugins.ps1 and only when that file exists.


# Mark registry. A mark is one character in the record flags; the plugin that declares it
# owns its meaning, so the base can store, sort, protect and describe marks it has never
# heard of. Declaration shape inside a plugin hash table:
#
#   Marks = [ordered]@{
#     p = @{ Set = 'pin'; Unset = 'unpin'; Word = 'pinned'; Hint = 'Ctrl+P'; Protected = $false }
#   }
#   SortMark   = 'p'                 # rows with this mark float to the top
#   ClearKeeps = @('p')              # marks `clear` keeps by default (array or scriptblock)
#
# $true Protected means the base refuses to trim, clear or delete such a row: only the
# verb named in Unset may remove the mark first.

# mark -> @{ Mark; Set; Unset; Word; Hint; Protected; Plugin }; the first declaration wins
function Get-PluginMarks {
  $out = [ordered]@{}
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('Marks')) { continue }
    $decl = $p['Marks']
    if ($decl -isnot [System.Collections.IDictionary]) { continue }
    foreach ($k in @($decl.Keys)) {
      $m = [string]$k
      if ($m.Length -ne 1 -or $out.Contains($m)) { continue }
      $spec = $decl[$k]
      if ($spec -isnot [System.Collections.IDictionary]) { continue }
      $out[$m] = @{
        Mark      = $m
        Set       = [string]$spec['Set']
        Unset     = [string]$spec['Unset']
        Word      = [string]$spec['Word']
        Hint      = [string]$spec['Hint']
        Protected = [bool]$spec['Protected']
        Plugin    = [string]$p['Name']
      }
    }
  }
  return $out
}


function Get-PluginMarkNames {
  $all = Get-PluginMarks
  return @($all.Keys)
}


function Get-PluginMarkInfo([string]$mark) {
  if (-not $mark) { return $null }
  $all = Get-PluginMarks
  if ($all.Contains($mark)) { return $all[$mark] }
  return $null
}


function Get-PluginProtectedMarks {
  $all = Get-PluginMarks
  $out = @()
  foreach ($k in @($all.Keys)) { if ($all[$k].Protected) { $out += [string]$k } }
  return $out
}


# the mark whose rows sort first; ignored when the mark is not declared
function Get-PluginSortMark {
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('SortMark')) { continue }
    $m = [string]$p['SortMark']
    if ($m -and (Get-PluginMarkInfo $m)) { return $m }
  }
  return ''
}


# how many rows the sticky mark may keep on screen while a search runs. 0 turns the feature
# off, a negative value means "as many as fit" - the panel works out how many that is.
function Get-PluginStickyRows {
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('StickyRows')) { continue }
    $v = $p['StickyRows']
    try { if ($v -is [scriptblock]) { $v = & $v } } catch {
      Write-Log ('plugin sticky policy failed (' + [string]$p['Name'] + '): ' + $_.Exception.Message)
      continue
    }
    $n = 0
    if ([int]::TryParse([string]$v, [ref]$n)) { return $n }
  }
  return 0
}


# The most rows pinned entries may take while sticky pins are on. A frozen block taller
# than this would leave nothing scrollable, so `pin` refuses instead of quietly pushing
# the rows below out of reach. The cap is the smaller of the declared sticky rows and
# what Rows leaves (always one row short of the whole list).
# 0 means the feature is off, so nothing is capped and the caller allows the mark.
# $rows is the visible row count; 0 asks for the configured one (the panel passes its own).
function Get-PluginStickyCap([int]$rows = 0) {
  $declared = 0
  $d = @(Get-PluginStickyRows)
  if ($d.Count -gt 0 -and $null -ne $d[0]) { $declared = [int]$d[0] }
  if ($declared -eq 0) { return 0 }
  if ($rows -le 0) {
    if (Get-Command Get-CfgValue -ErrorAction SilentlyContinue) {
      try {
        $raw = @(Get-CfgValue 'Rows')
        if ($raw.Count -gt 0 -and $null -ne $raw[0]) { $rows = [int]$raw[0] }
      } catch { $rows = 0 }
    }
    if ($rows -le 0) { $rows = [int]$script:Rows }
  }
  if ($rows -lt 2) { return 0 }
  return (Get-StickyRowLimit $rows $declared)
}


# The mark whose rows stay visible while searching ("sticky pins"); '' = nothing sticks
function Get-PluginStickyMark {
  if ((Get-PluginStickyRows) -eq 0) { return '' }
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('StickyMark')) { continue }
    $m = [string]$p['StickyMark']
    if ($m -and (Get-PluginMarkInfo $m)) { return $m }
  }
  return ''
}


# marks `clear` keeps without -All
function Get-PluginClearKeeps {
  $out = @()
  foreach ($p in @($script:Plugins)) {
    if (-not $p.ContainsKey('ClearKeeps')) { continue }
    $v = $p['ClearKeeps']
    try { if ($v -is [scriptblock]) { $v = & $v } } catch {
      Write-Log ('plugin clear policy failed (' + [string]$p['Name'] + '): ' + $_.Exception.Message)
      continue
    }
    foreach ($m in @($v)) {
      $s = [string]$m
      if ($s -and ($out -notcontains $s)) { $out += $s }
    }
  }
  return $out
}

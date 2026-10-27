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

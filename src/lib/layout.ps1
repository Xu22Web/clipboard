# lib/layout.ps1 - where a row goes: which rows float to the top, and how many of them the
# panel may freeze while everything else scrolls.
#
# Pure arithmetic over a record list: nothing here opens the store, and nothing draws. The
# store sorts after every write, the panel asks how many rows stay still, and a plugin asks
# how many pins it may still take - three callers, one rule, so the numbers cannot disagree.
#
# What "sticky" and "sorts first" mean is declared by a plugin and read through
# lib/plugin-marks.ps1; this file only applies it.

# rows carrying the sort mark float to the top, each block keeps its own order
function Sort-Records($list) {
  $sm = Get-SortMark
  if (-not $sm) { return ,$list }
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($r in $list) { if (Test-Mark $r $sm) { $out.Add($r) } }
  foreach ($r in $list) { if (-not (Test-Mark $r $sm)) { $out.Add($r) } }
  return ,$out
}

# The sticky-pin cap a visible area of that size allows: one row always stays for the
# rows the query actually found, otherwise a long pin list would push the results out of
# sight. Declared 0 = feature off, a negative value = as many as fit.
function Get-StickyRowCap([int]$rows) {
  $room = $rows - 1
  if ($room -lt 1) { return 0 }
  return $room
}

# How many leading rows a sticky mark may take inside the visible area.
function Get-StickyRowLimit([int]$rows, [int]$declared) {
  if ($declared -eq 0) { return 0 }
  $room = Get-StickyRowCap $rows
  if ($room -lt 1) { return 0 }
  if ($declared -lt 0 -or $declared -gt $room) { return $room }
  return $declared
}

# What the panel needs to know about the sticky mark: which mark sticks, and how many rows
# it may take for a visible area of that size. An empty mark means nothing sticks. The two
# inputs come from the caller, so this file never has to ask the plugin layer - that is the
# one direction that would make marks <-> layout a cycle again.
function Get-StickyPlan([int]$rows, [string]$stickyMark = '', [int]$declared = 0) {
  if (-not $stickyMark -or $declared -eq 0) { return @{ Mark = ''; Max = 0 } }
  return @{ Mark = $stickyMark; Max = (Get-StickyRowLimit $rows $declared) }
}

# How many leading rows stay frozen while the list scrolls. Pins sort first (SortMark), so
# this is the unbroken run of sticky rows at the top of the result set, capped by the same
# rule the exclusive-through-search version used: a long pin list can never fill the whole
# view, one row always stays for the rows below it.
function Get-StickyTopRows($rows, [string]$stickyMark, [int]$stickyMax) {
  if (-not $stickyMark -or $stickyMax -le 0) { return 0 }
  $n = 0
  foreach ($rec in @($rows)) {
    if ($n -ge $stickyMax) { break }
    if (-not (Test-Mark $rec $stickyMark)) { break }
    $n++
  }
  return $n
}

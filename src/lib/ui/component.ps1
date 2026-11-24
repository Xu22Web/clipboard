# lib/ui/component.ps1 - components, their lifecycle, and the store behind them.
#
# Both drawn windows are one form each, so a "component" here is not a control: it is a record
# that owns a box, a state table and the scriptblocks that draw and hit-test it. What this file
# adds is the runtime a tree of those records needs and a single window does not - a mount and
# an unmount to hang resources on, a handler that passes a change up to the parent, a cache that
# keeps a built surface alive between opens, and a slot that can be drawn before its content
# arrives. Nothing here draws, and nothing here creates a handle.

# ------------------------------------------------------------------ the store
# One table and one revision. A write that changes a value bumps the revision, so a reader that
# remembers the revision it built from can tell stale from fresh without being told what changed.
# A value is compared as a string: the settings window and the panel only store scalars.

function Copy-UiTable($table) {
  $next = @{}
  if ($null -ne $table) {
    foreach ($k in @($table.Keys)) { $next[[string]$k] = $table[$k] }
  }
  return $next
}

function New-UiStore($state = $null) {
  return @{ State = (Copy-UiTable $state); Revision = 1; Watchers = (New-Object System.Collections.Generic.List[object]) }
}

function Get-UiState($store, [string]$key, $default = $null) {
  if ($null -eq $store) { return $default }
  if (-not $store.State.ContainsKey($key)) { return $default }
  return $store.State[$key]
}

# True when the value moved. A write of what is already there leaves the revision alone, which
# is what keeps a repaint from being asked for by an edit that changed nothing.
function Set-UiState($store, [string]$key, $value) {
  if ($null -eq $store -or -not $key) { return $false }
  if ($store.State.ContainsKey($key) -and ([string]$store.State[$key] -ceq [string]$value)) { return $false }
  $store.State[$key] = $value
  $store.Revision = [int]$store.Revision + 1
  # ToArray, not @(list): wrapping a generic list throws "Argument types do not match" in 5.1
  foreach ($w in $store.Watchers.ToArray()) {
    if ($null -eq $w) { continue }
    try { & $w $key $value } catch { }
  }
  return $true
}

function Add-UiWatcher($store, [scriptblock]$fn) {
  if ($null -eq $store -or $null -eq $fn) { return }
  $store.Watchers.Add($fn)
}

# ------------------------------------------------------------------ a slot that arrives later
# The card of the hover preview is built in a runspace of its own; a page of settings could be
# built on an idle tick. Whichever does the work, the window has to draw something before it is
# ready, and this is what it draws from.

function New-UiAsync([string]$key = '') {
  return @{ Key = $key; Pending = $true; Value = $null; Failed = $false; Note = '' }
}

function Set-UiAsyncResult($slot, $value) {
  if ($null -eq $slot) { return $null }
  $slot.Pending = $false
  $slot.Failed = $false
  $slot.Value = $value
  return $slot
}

function Set-UiAsyncFailed($slot, [string]$note) {
  if ($null -eq $slot) { return $null }
  $slot.Pending = $false
  $slot.Failed = $true
  $slot.Note = $note
  return $slot
}

function Test-UiAsyncPending($slot) {
  if ($null -eq $slot) { return $false }
  return [bool]$slot.Pending
}

# ------------------------------------------------------------------ a cache that outlives an open
# The settings window and the panel are built, thrown away and built again; the ScriptBlocks of
# a function defined inside the window are compiled on their first call, which is where most of
# an open's millisecond budget goes. Keeping a built surface here means the next open starts
# from something that already exists, and a stale predicate says when the theme, the language
# or the schema has moved far enough that it has to be built again.

function New-UiKeepAlive([int]$capacity = 4, [scriptblock]$release = $null) {
  if ($capacity -lt 1) { $capacity = 1 }
  return @{
    Items = @{}; Order = (New-Object System.Collections.Generic.List[string])
    Max = $capacity; Release = $release; Hits = 0; Misses = 0
  }
}

function Remove-UiKeepAlive($cache, [string]$key) {
  if ($null -eq $cache -or -not $key) { return }
  if (-not $cache.Items.ContainsKey($key)) { return }
  $held = $cache.Items[$key]
  [void]$cache.Items.Remove($key)
  [void]$cache.Order.Remove($key)
  if ($null -ne $cache.Release -and $null -ne $held) {
    try { & $cache.Release $held.Value } catch { }
  }
}

function Clear-UiKeepAlive($cache) {
  if ($null -eq $cache) { return }
  foreach ($k in @($cache.Order.ToArray())) { Remove-UiKeepAlive $cache ([string]$k) }
}

function Test-UiKeepAliveHeld($cache, [string]$key) {
  if ($null -eq $cache -or -not $key) { return $false }
  return $cache.Items.ContainsKey($key)
}

# Store a value the caller built itself - a diff of what was already there, say - without going
# through the build script: the cache is then warm for the next caller that asks for it.
function Set-UiKeepAliveValue($cache, [string]$key, $value) {
  if ($null -eq $cache -or -not $key) { return }
  $cache.Items[$key] = @{ Value = $value }
  [void]$cache.Order.Remove($key)
  $cache.Order.Add($key)
  while ($cache.Order.Count -gt [int]$cache.Max) {
    Remove-UiKeepAlive $cache ([string]$cache.Order[0])
  }
}

# The value for a key, built once. A stale entry is released and built again; the oldest entry
# goes when the cache is over its capacity, so a window that keeps growing cannot pile up.
function Get-UiKeepAlive($cache, [string]$key, [scriptblock]$build, [scriptblock]$stale = $null) {
  if ($null -eq $cache -or -not $key -or $null -eq $build) { return $null }
  if ($cache.Items.ContainsKey($key)) {
    $held = $cache.Items[$key]
    $isStale = $false
    if ($null -ne $stale) {
      try { $isStale = [bool](& $stale $held.Value) } catch { $isStale = $true }
    }
    if (-not $isStale) {
      $cache.Hits = [int]$cache.Hits + 1
      [void]$cache.Order.Remove($key)
      $cache.Order.Add($key)
      return $held.Value
    }
    Remove-UiKeepAlive $cache $key
  }
  $cache.Misses = [int]$cache.Misses + 1
  $value = & $build
  Set-UiKeepAliveValue $cache $key $value
  return $value
}

# ------------------------------------------------------------------ a component
# Draw, hit and measure stay with the caller: this is the record those three are registered on,
# plus what has to happen when it appears, changes or goes away. The unmount is the one that
# matters for a drawn window - brushes, regions, timers and runspaces are released there instead
# of being left to a finalizer.

function New-UiComponent([string]$type, $props = $null) {
  return @{
    Type = $type; Key = ''; Props = (Copy-UiTable $props); State = @{}
    Children = (New-Object System.Collections.Generic.List[object])
    Resources = (New-Object System.Collections.Generic.List[object])
    Box = $null; Alive = $false; Hooks = @{}; On = @{}
  }
}

# Anything a component opens and has to hand back: a brush, a path, a region, a timer, a
# runspace. Kept on the record so the unmount can release it, which is what a drawn window
# needs - a handle left to the finalizer is a handle that is still there on the hundredth open.
function Add-UiResource($c, $item) {
  if ($null -eq $c -or $null -eq $item) { return }
  $c.Resources.Add($item)
}

function Add-UiHook($c, [string]$name, [scriptblock]$fn) {
  if ($null -eq $c -or -not $name -or $null -eq $fn) { return }
  $c.Hooks[$name] = $fn
}

# Handlers a child raises upward: the parent names the event, the child only says it happened.
function Add-UiHandler($c, [string]$event, [scriptblock]$fn) {
  if ($null -eq $c -or -not $event -or $null -eq $fn) { return }
  $c.On[$event] = $fn
}

function Add-UiChild($parent, $child) {
  if ($null -eq $parent -or $null -eq $child) { return $null }
  $parent.Children.Add($child)
  return $child
}

# True when a handler answered: a parent that does not listen to an event is not an error.
function Invoke-UiEmit($c, [string]$event, $payload = $null) {
  if ($null -eq $c -or -not $event) { return $false }
  if (-not $c.On.ContainsKey($event)) { return $false }
  $fn = $c.On[$event]
  if ($null -eq $fn) { return $false }
  try { & $fn $payload } catch { }
  return $true
}

function Invoke-UiHook($c, [string]$name, $arg = $null) {
  if ($null -eq $c -or -not $name) { return $null }
  if (-not $c.Hooks.ContainsKey($name)) { return $null }
  $fn = $c.Hooks[$name]
  if ($null -eq $fn) { return $null }
  try { return (& $fn $c $arg) } catch { return $null }
}

function Mount-UiComponent($c, $box = $null) {
  if ($null -eq $c) { return $null }
  $c.Box = $box
  $c.Alive = $true
  foreach ($child in $c.Children.ToArray()) { [void](Mount-UiComponent $child $null) }
  [void](Invoke-UiHook $c 'mounted' $null)
  return $c
}

# A new box for a component that is already up. False means nothing moved, so nothing is drawn
# again; the hook only runs when the answer is true.
function Update-UiComponent($c, $box) {
  if ($null -eq $c -or -not $c.Alive) { return $false }
  $old = $c.Box
  if ($null -eq $box -and $null -eq $old) { return $false }
  if ($null -ne $box -and $null -ne $old) {
    if ([int]$box.Left -eq [int]$old.Left -and [int]$box.Top -eq [int]$old.Top -and
      [int]$box.Width -eq [int]$old.Width -and [int]$box.Height -eq [int]$old.Height) { return $false }
  }
  $c.Box = $box
  [void](Invoke-UiHook $c 'updated' $null)
  return $true
}

# Children go before the parent, and in the reverse order they were added: a surface that draws
# over another is released first. What each of them opened goes last, in the reverse order it
# was opened.
function Unmount-UiComponent($c) {
  if ($null -eq $c -or -not $c.Alive) { return }
  $kids = $c.Children.ToArray()
  for ($i = $kids.Count - 1; $i -ge 0; $i--) { Unmount-UiComponent $kids[$i] }
  [void](Invoke-UiHook $c 'unmounted' $null)
  $res = $c.Resources.ToArray()
  for ($i = $res.Count - 1; $i -ge 0; $i--) {
    $item = $res[$i]
    if ($null -eq $item) { continue }
    if ($item -is [System.IDisposable]) { try { $item.Dispose() } catch { } }
  }
  $c.Resources.Clear()
  $c.Alive = $false
}

function Test-UiComponentAlive($c) {
  if ($null -eq $c) { return $false }
  return [bool]$c.Alive
}

# The children of a list, patched the way a keyed diff patches a list of nodes: a key that is
# still there keeps its component - brushes, regions, a cached page - and is only moved; a key
# that left is unmounted; a key that is new is created and mounted. Rebuilding the whole list on
# every filter or page change is what makes a drawn surface flicker and what a cache cannot fix,
# because the objects it cached are no longer the ones on screen.
#
#   specs     what the list should hold, in order
#   keyOf     spec -> its key ('' means "no key": the component is built, never matched)
#   create    spec -> a new component, unmounted
function Sync-UiChildren($parent, $specs, [scriptblock]$keyOf, [scriptblock]$create) {
  $answer = @{ Reused = 0; Created = 0; Unmounted = 0; Children = @() }
  if ($null -eq $parent -or $null -eq $keyOf -or $null -eq $create) { return $answer }
  $held = @{}
  foreach ($old in $parent.Children.ToArray()) {
    $k = [string]$old.Key
    if ($k) { $held[$k] = $old }
  }
  $order = New-Object System.Collections.Generic.List[object]
  $list = @()
  if ($null -ne $specs) { $list = @($specs) }
  foreach ($spec in $list) {
    $k = [string](& $keyOf $spec)
    if ($k -and $held.ContainsKey($k)) {
      $kept = $held[$k]
      [void]$held.Remove($k)
      $answer.Reused++
      $order.Add($kept)
      continue
    }
    $child = & $create $spec
    if ($null -eq $child) { continue }
    $child.Key = $k
    [void](Mount-UiComponent $child $null)
    $answer.Created++
    $order.Add($child)
  }
  # whatever is still held left the list
  foreach ($k in @($held.Keys)) {
    Unmount-UiComponent $held[$k]
    $answer.Unmounted++
  }
  # the order is the caller's, not the order they happened to be built in
  $parent.Children.Clear()
  foreach ($child in $order.ToArray()) { $parent.Children.Add($child) }
  $answer.Children = $order.ToArray()
  return $answer
}

# lib/ui/framework.ps1 - the tree a surface is written as, and the patch that keeps it.
#
# A surface here is a tree of nodes: a node carries a type, a key, the values it was built from
# (Props), the box it was given and its children. What this file adds to the runtime in
# component.ps1 is the part every surface does the same way and no surface should write again:
#
#   Sync-UiTree     compare the tree a surface wants with the tree it is showing and change only
#                   what differs - a key that is still there keeps its node (and whatever that
#                   node cached), a key with new values is updated in place, a key that left is
#                   unmounted, and the order is the caller's
#   Render-UiTree   walk the tree and hand each live node to the surface's painter, depth first
#   Get-UiTreeStats what the last patch did, for a log line and for the tests
#
# It is the same idea as a keyed virtual DOM: the surface says what should be on screen, this
# decides what actually changes, and nothing is rebuilt to change one value.

# The fingerprint of a node's values. Two nodes with the same fingerprint draw the same way, so
# a patch can keep the node: the values are compared as a sorted string, which is enough for the
# rows, cards and menu items these windows hold (numbers, words, flags).
function Get-UiPropsKey($props) {
  if ($null -eq $props) { return '' }
  if (-not ($props -is [System.Collections.IDictionary])) { return [string]$props }
  $keys = @($props.Keys | ForEach-Object { [string]$_ } | Sort-Object)
  $parts = @()
  foreach ($k in $keys) { $parts += ($k + '=' + [string]$props[$k]) }
  return ($parts -join "`n")
}

function Test-UiNodeStale($node, $props) {
  if ($null -eq $node) { return $true }
  return ((Get-UiPropsKey $node.Props) -cne (Get-UiPropsKey $props))
}

# The whole tree under a parent, patched: children are matched by key, kept nodes are updated
# when their values moved, and every kept node has its own children patched in turn.
#
#   specs    what the tree should hold: an array of @{ Key; Props; Children }
#   keyOf    spec -> its key ('' means "no key": built every time and never matched)
#   create   spec -> a new node, unmounted; the surface decides its type and how it draws
function Sync-UiTree($parent, $specs, [scriptblock]$keyOf, [scriptblock]$create) {
  $answer = @{ Reused = 0; Created = 0; Updated = 0; Unmounted = 0; Children = @() }
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
    $node = $null
    if ($k -and $held.ContainsKey($k)) {
      $node = $held[$k]
      [void]$held.Remove($k)
      $answer.Reused++
      $props = $null
      if ($spec -is [System.Collections.IDictionary] -and $spec.Contains('Props')) { $props = $spec['Props'] }
      if (Test-UiNodeStale $node $props) {
        $node.Props = Copy-UiTable $props
        [void](Invoke-UiHook $node 'updated' $null)
        $answer.Updated++
      }
    } else {
      $node = & $create $spec
      if ($null -eq $node) { continue }
      $node.Key = $k
      [void](Mount-UiComponent $node $null)
      $answer.Created++
    }
    # the node's own children, patched the same way
    $kids = $null
    if ($spec -is [System.Collections.IDictionary] -and $spec.Contains('Children')) { $kids = $spec['Children'] }
    if ($null -ne $kids) {
      $sub = Sync-UiTree $node $kids $keyOf $create
      $answer.Reused += [int]$sub.Reused
      $answer.Created += [int]$sub.Created
      $answer.Updated += [int]$sub.Updated
      $answer.Unmounted += [int]$sub.Unmounted
    }
    $order.Add($node)
  }
  # whatever is still held left the tree: children first, then the nodes themselves
  foreach ($k in @($held.Keys)) {
    Unmount-UiComponent $held[$k]
    $answer.Unmounted++
  }
  $parent.Children.Clear()
  foreach ($node in $order.ToArray()) { $parent.Children.Add($node) }
  $answer.Children = $order.ToArray()
  return $answer
}

# Draw the tree: depth first, the parent before its children, so a card draws over its page.
# The painter is the surface's own function; it is handed a node and draws what the node says.
function Render-UiTree($node, [scriptblock]$draw) {
  if ($null -eq $node -or -not $node.Alive) { return 0 }
  $drawn = 0
  if ($null -ne $draw) {
    & $draw $node
    $drawn++
  }
  foreach ($child in $node.Children.ToArray()) { $drawn += (Render-UiTree $child $draw) }
  return $drawn
}

function Get-UiTreeStats($patch) {
  if ($null -eq $patch) { return @{ Reused = 0; Created = 0; Updated = 0; Unmounted = 0 } }
  return @{
    Reused = [int]$patch.Reused; Created = [int]$patch.Created
    Updated = [int]$patch.Updated; Unmounted = [int]$patch.Unmounted
  }
}

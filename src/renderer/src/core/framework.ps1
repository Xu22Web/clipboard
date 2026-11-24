#@use renderer/src/core/component
#@export Get-UiPropsKey, Test-UiNodeStale, Sync-UiTree, Render-UiTree, Get-UiNodeValues
# renderer\src\core\framework.ps1 - the tree a surface is written as, and the patch that keeps it.
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
# when their values moved, and every kept node has its own children patched in turn. It is the
# keyed list diff a surface needs: a key still in the tree keeps its node, wherever it moved to,
# a key whose values moved is updated in place, a key that left is unmounted, and a key that
# arrived is mounted where the caller put it. A spec the caller leaves out is gone - that is
# what "if" means here, since a node that is not wanted is a node whose resources have to go.
#
#   specs       what the tree should hold: an array of @{ Key; Props; Children }
#   keyOf       spec -> its key ('' means "no key": built every time and never matched)
#   create      spec -> a new node, unmounted; the surface decides its type and how it draws
#   fingerprint a node's values -> a string that is equal exactly when the node draws the same
#               way. A surface whose values are large, or only partly relevant, passes one: a
#               settings row is compared by its value, whether it is staged and whether it is
#               lit, and nothing else it carries can change between two paints.
function Sync-UiTree($parent, $specs, [scriptblock]$keyOf, [scriptblock]$create, [scriptblock]$fingerprint = $null) {
  $answer = @{ Reused = 0; Created = 0; Updated = 0; Unmounted = 0; Children = @() }
  if ($null -eq $parent -or $null -eq $keyOf -or $null -eq $create) { return $answer }
  $held = @{}
  foreach ($old in $parent.Children.ToArray()) {
    $k = [string]$old.Key
    if ($k) { $held[$k] = $old }
  }
  # a key that appears twice in one list cannot name one node: the second one is built fresh,
  # with no key, rather than stealing the first one's node. A surface that forgot an index in a
  # key gets a right answer and a node per refresh instead of two children sharing one.
  $seen = @{}
  $order = New-Object System.Collections.Generic.List[object]
  $list = @()
  if ($null -ne $specs) { $list = @($specs) }
  foreach ($spec in $list) {
    $k = [string](& $keyOf $spec)
    if ($k) {
      if ($seen.ContainsKey($k)) { $k = '' } else { $seen[$k] = $true }
    }
    $node = $null
    if ($k -and $held.ContainsKey($k)) {
      $node = $held[$k]
      [void]$held.Remove($k)
      $answer.Reused++
      $props = $null
      if ($spec -is [System.Collections.IDictionary] -and $spec.Contains('Props')) { $props = $spec['Props'] }
      $stale = $true
      if ($null -ne $fingerprint) {
        $stale = ((& $fingerprint $props) -cne (& $fingerprint $node.Props))
      } else {
        $stale = Test-UiNodeStale $node $props
      }
      if ($stale) {
        # the hook runs after the values are in place and is handed what they replaced, which is
        # what makes it a watch: the node already carries the new state when it is called
        $oldProps = $node.Props
        $node.Props = Copy-UiTable $props
        [void](Invoke-UiHook $node 'updated' $oldProps)
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
      $sub = Sync-UiTree $node $kids $keyOf $create $fingerprint
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

# The values of a parent's children, in the order they are in: what a surface hands to the code
# that draws and hit-tests, and what it passes back on the next patch.
function Get-UiNodeValues($parent) {
  $out = New-Object System.Collections.Generic.List[object]
  if ($null -eq $parent) { return $out.ToArray() }
  foreach ($child in $parent.Children.ToArray()) { $out.Add($child.Props) }
  return $out.ToArray()
}

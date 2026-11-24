# lib/ui/views.ps1 - a control as a record: what it is, what it holds, where it is, how it draws.
#
# component.ps1 gives a node a lifecycle, framework.ps1 gives a tree of them a patch. What was
# still written out at every call site is the control itself: a rectangle, a hot flag, an edge
# test and a draw call, in that order and by hand, once per button and once per icon. That is
# three places to keep in step for one control, and the panel and the settings window had been
# keeping two sets of them.
#
# Here a control is a node whose Type names a kind registered below, whose Props are what it is
# drawn from (a label, a glyph, whether it can be pressed), whose Box is where the layout put it,
# and whose State is how it happens to be right now (hover, press). Three functions then do the
# work for every kind: Draw-UiView paints one node, Hit-UiViewList says which node is under a
# point, and Update-UiViewHot moves the hover on and answers the rectangle that has to be
# repainted - so a pointer crossing a footer button costs its own 90 x 26, not the window.
#
# A kind is data, not a class: Register-UiView takes a draw function and, when the control is not
# a plain rectangle, a hit function. The two kinds the drawn windows use today are registered at
# the end of this file; a switch, a field or a chip is added the same way, when a surface draws
# through it.

$script:UiViewKinds = @{}

#   draw     (g, pal, node, box) -> paints the node in its box
#   measure  (node, ctx) -> @{ Width; Height } for a control that sizes itself to its words
#   hit      (node, box, x, y) -> whether the point is on the control; omitted means the box
function Register-UiView([string]$kind, [scriptblock]$draw, [scriptblock]$measure = $null, [scriptblock]$hit = $null) {
  if (-not $kind -or $null -eq $draw) { return }
  $script:UiViewKinds[$kind] = @{ Draw = $draw; Measure = $measure; Hit = $hit }
}

function Get-UiViewKind([string]$kind) {
  if (-not $kind) { return $null }
  if (-not $script:UiViewKinds.ContainsKey($kind)) { return $null }
  return $script:UiViewKinds[$kind]
}

function Test-UiViewKind([string]$kind) {
  if (-not $kind) { return $false }
  return $script:UiViewKinds.ContainsKey($kind)
}

# A control, mounted and ready to be placed. The key is what a patch matches on, so the same
# button survives a page change, a language change and a save.
function New-UiView([string]$kind, [string]$key, $props = $null) {
  $c = New-UiComponent $kind $props
  $c.Key = [string]$key
  $c.State['Hot'] = $false
  $c.State['Pressed'] = $false
  return $c
}

# A control states whether it can be pressed; one that says nothing can.
function Test-UiViewEnabled($node) {
  if ($null -eq $node) { return $false }
  $props = $node.Props
  if ($props -is [System.Collections.IDictionary] -and $props.Contains('Enabled')) { return [bool]$props['Enabled'] }
  return $true
}

function Get-UiViewProp($node, [string]$name, $default = $null) {
  if ($null -eq $node) { return $default }
  $props = $node.Props
  if ($props -is [System.Collections.IDictionary] -and $props.Contains($name)) { return $props[$name] }
  return $default
}

# A write to the control's own state, with the same contract as Set-UiState: false means the
# value was already there, so nothing has to be drawn again.
function Set-UiViewState($node, [string]$name, $value) {
  if ($null -eq $node -or -not $name) { return $false }
  if ($node.State.ContainsKey($name) -and ([string]$node.State[$name] -ceq [string]$value)) { return $false }
  $node.State[$name] = $value
  return $true
}

function Test-UiViewState($node, [string]$name) {
  if ($null -eq $node) { return $false }
  if (-not $node.State.ContainsKey($name)) { return $false }
  return [bool]$node.State[$name]
}

# One control, in the box the layout gave it. A node with no box is not on screen yet.
function Draw-UiView($g, $pal, $node) {
  if ($null -eq $g -or $null -eq $pal -or $null -eq $node -or $null -eq $node.Box) { return $false }
  $kind = Get-UiViewKind $node.Type
  if ($null -eq $kind) { return $false }
  & $kind.Draw $g $pal $node $node.Box
  return $true
}

# The control under a point, or nothing. Later in the list is drawn later, so it wins: the same
# rule the tree paints by, which is what makes a button on top of a bar behave like one.
function Hit-UiViewList($nodes, [int]$x, [int]$y, [bool]$onlyEnabled = $false) {
  $list = @($nodes)
  for ($i = $list.Count - 1; $i -ge 0; $i--) {
    $n = $list[$i]
    if ($null -eq $n -or $null -eq $n.Box) { continue }
    if ($onlyEnabled -and -not (Test-UiViewEnabled $n)) { continue }
    $kind = Get-UiViewKind $n.Type
    if ($null -ne $kind -and $null -ne $kind.Hit) {
      if ([bool](& $kind.Hit $n $n.Box $x $y)) { return $n }
      continue
    }
    $b = $n.Box
    if ($x -ge [int]$b.Left -and $x -le ([int]$b.Left + [int]$b.Width) -and
      $y -ge [int]$b.Top -and $y -le ([int]$b.Top + [int]$b.Height)) { return $n }
  }
  return $null
}

function Get-UiViewRect($node) {
  if ($null -eq $node -or $null -eq $node.Box) { return [Drawing.Rectangle]::Empty }
  $b = $node.Box
  return (New-Object Drawing.Rectangle -ArgumentList @(
      [int]$b.Left, [int]$b.Top, [int]$b.Width, [int]$b.Height))
}

# Hover as a diff: the controls under the point hold it, the rest let it go, and the answer is
# the union of the boxes that actually changed - an empty rectangle when the pointer moved
# without crossing a control. Repainting that rectangle instead of the window is what makes a
# footer button cost a footer button.
function Update-UiViewHot($nodes, [int]$x, [int]$y) {
  $list = @($nodes)
  $over = Hit-UiViewList $list $x $y
  $overKey = ''
  if ($null -ne $over) { $overKey = [string]$over.Key }
  $dirty = [Drawing.Rectangle]::Empty
  foreach ($n in $list) {
    if ($null -eq $n -or $null -eq $n.Box) { continue }
    if (-not (Set-UiViewState $n 'Hot' ([string]$n.Key -ceq $overKey))) { continue }
    $one = Get-UiViewRect $n
    if ($dirty.IsEmpty) { $dirty = $one } else { $dirty = [Drawing.Rectangle]::Union($dirty, $one) }
  }
  return $dirty
}

# The same diff for the pressed state, so a control can be drawn held down while the button is
# still on it and released when the pointer leaves.
function Update-UiViewPress($nodes, [int]$x, [int]$y, [bool]$down) {
  $list = @($nodes)
  $over = $null
  if ($down) { $over = Hit-UiViewList $list $x $y $true }
  $overKey = ''
  if ($null -ne $over) { $overKey = [string]$over.Key }
  $dirty = [Drawing.Rectangle]::Empty
  foreach ($n in $list) {
    if ($null -eq $n -or $null -eq $n.Box) { continue }
    if (-not (Set-UiViewState $n 'Pressed' ([string]$n.Key -ceq $overKey))) { continue }
    $one = Get-UiViewRect $n
    if ($dirty.IsEmpty) { $dirty = $one } else { $dirty = [Drawing.Rectangle]::Union($dirty, $one) }
  }
  return $dirty
}

# A list of controls as one parent node, so the framework's patch keeps them: keys that stayed
# keep their node and its hover, the ones whose words or state moved are updated in place, and
# the ones that left are unmounted. This is what a surface calls instead of rebuilding buttons.
$script:UiViewKeyOf = { param($spec) [string]$spec['Key'] }
$script:UiViewMake = { param($spec) New-UiView ([string]$spec['Type']) ([string]$spec['Key']) $spec['Props'] }

function Sync-UiViews($parent, $specs) {
  return (Sync-UiTree $parent $specs $script:UiViewKeyOf $script:UiViewMake)
}

# ------------------------------------------------------------------ the kinds in use
# A footer or dialog button: a fill, a hairline and a centred label, with the hover wash the
# settings window and the panel's own card already used.
Register-UiView 'button' {
  param($g, $pal, $node, $box)
  Draw-UiButton $g $pal $box (([string](Get-UiViewProp $node 'Label' ''))) ([bool](Get-UiViewProp $node 'Primary' $false)) (Test-UiViewEnabled $node) (Test-UiViewState $node 'Hot')
}

# A caption button: one glyph on its own, with the hover fill a title bar puts under the pointer.
Register-UiView 'icon' {
  param($g, $pal, $node, $box)
  Draw-UiIconButton $g $pal $box ([string](Get-UiViewProp $node 'Glyph' 'close')) (Test-UiViewEnabled $node) (Test-UiViewState $node 'Hot')
}

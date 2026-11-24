#@use renderer/src/core/component, renderer/src/core/views
#@export Get-UiSetupState, Get-UiSetupContext, Merge-UiSetupProps, Add-UiSetupHook, Use-UiSlot, Invoke-UiSlot, New-UiSetupView, Get-UiSetupContextOf
# renderer\src\core\setup.ps1 - a component declared the way <script setup> declares one.
#
# A component here is still a node (renderer\src\core\views.ps1) whose kind decides how it draws. What was
# missing is how the node is *declared*: props in, one function that builds what it needs, and the
# lifecycle hooks it registers while that function runs - instead of the caller hunting the node
# afterwards to attach them.
#
#   $chrome = New-UiSetupView 'chrome' @{ Density = 1 } {
#     param($ctx)
#     $density = Use-UiProp $ctx 'Density' 1        # props, with the component's own defaults
#     On-UiMounted { param($node) Add-UiResource $node (New-Brush $density) }
#     On-UiUnmounted { param($node) Write-Log 'chrome gone' }
#     return @{ Density = $density }                 # the bindings, kept on the node
#   }
#
# The hooks are ambient, the way onMounted is ambient inside setup(): a composable called from
# setup can register one without being handed a context. A hook registered outside any setup is
# dropped rather than kept for a component that is not there - there is no current instance to
# attach it to.
#
# What a setup function returns is kept in the node's State under 'Bindings', so a surface that
# needs a value the component computed reads it from the node instead of calling the function
# again: what setup returned is what the component is, for as long as the node lives.

# The stack of setups that are running. It is a global, not a $script: variable, because a hook
# runs from inside a ScriptBlock: $script: resolves against the scope that *invokes* the block,
# which for a component created by a window is the window, not this file. One dictionary, created
# on first use, is the only way every caller sees the same stack.
function Get-UiSetupState {
  if ($null -eq $global:UiSetupState) {
    $global:UiSetupState = @{
      Stack = (New-Object System.Collections.Generic.List[object])
      Count = 0
    }
  }
  return $global:UiSetupState
}

# The innermost setup, or nothing outside one.
function Get-UiSetupContext {
  $state = Get-UiSetupState
  if ($state.Stack.Count -eq 0) { return $null }
  return $state.Stack[$state.Stack.Count - 1]
}

# Props are the component's defaults with the caller's values laid over them, so a component says
# what it needs once and a caller only passes what it changes.
function Merge-UiSetupProps($defaults, $given) {
  $props = @{}
  foreach ($k in @($defaults.Keys)) { $props[[string]$k] = $defaults[$k] }
  if ($given -is [System.Collections.IDictionary]) {
    foreach ($k in @($given.Keys)) { $props[[string]$k] = $given[$k] }
  }
  return $props
}

function Use-UiProp($ctx, [string]$name, $default = $null) {
  if ($null -eq $ctx -or $null -eq $ctx.Props) { return $default }
  if (-not $ctx.Props.ContainsKey($name)) { return $default }
  return $ctx.Props[$name]
}

# A hook on the innermost setup. Outside one there is no component to attach it to, so it is
# dropped: a stray registration is a mistake, not a feature.
function Add-UiSetupHook([string]$name, [scriptblock]$fn) {
  $ctx = Get-UiSetupContext
  if ($null -eq $ctx -or -not $name -or $null -eq $fn) { return $false }
  if (-not $ctx.Hooks.ContainsKey($name)) {
    $ctx.Hooks[$name] = (New-Object System.Collections.Generic.List[object])
  }
  $ctx.Hooks[$name].Add($fn)
  return $true
}

function On-UiMounted([scriptblock]$fn) { return (Add-UiSetupHook 'mounted' $fn) }
function On-UiUpdated([scriptblock]$fn) { return (Add-UiSetupHook 'updated' $fn) }
function On-UiUnmounted([scriptblock]$fn) { return (Add-UiSetupHook 'unmounted' $fn) }

# What the component raises upward. The node exists once setup has returned, so this is for the
# handlers setup hands back, not for setup itself.
function Use-UiEmit($ctx, [string]$event, $payload = $null) {
  if ($null -eq $ctx -or $null -eq $ctx.Node) { return $false }
  return (Invoke-UiEmit $ctx.Node $event $payload)
}

# A scoped slot: the child asks its owner for content and says what the content may know about.
# The owner registers a ScriptBlock; the child invokes it with its own scope, so the content is
# written where the state lives and drawn where the space is.
function Use-UiSlot($ctx, [string]$name) {
  if ($null -eq $ctx -or -not $name) { return $null }
  if (-not $ctx.Slots.ContainsKey($name)) { return $null }
  return $ctx.Slots[$name]
}

function Invoke-UiSlot($ctx, [string]$name, $scope = $null, $fallback = $null) {
  $fn = Use-UiSlot $ctx $name
  if ($null -eq $fn) { return $fallback }
  return (& $fn $scope)
}

# A component factory: what Sync-UiTree's create wants, built from a declaration. Calling it for a
# spec runs the setup with that spec's props and answers the node, hooks attached.
function New-UiSetupView([string]$kind, $defaults, [scriptblock]$setup) {
  $dflt = @{}
  if ($defaults -is [System.Collections.IDictionary]) {
    foreach ($k in @($defaults.Keys)) { $dflt[[string]$k] = $defaults[$k] }
  }
  $decl = {
    param($spec)
    $given = $null
    if ($spec -is [System.Collections.IDictionary] -and $spec.Contains('Props')) { $given = $spec['Props'] }
    $props = Merge-UiSetupProps $dflt $given
    $key = ''
    if ($spec -is [System.Collections.IDictionary] -and $spec.Contains('Key')) { $key = [string]$spec['Key'] }
    $slots = @{}
    if ($spec -is [System.Collections.IDictionary] -and $spec.Contains('Slots')) { $slots = $spec['Slots'] }
    $ctx = @{ Props = $props; Hooks = @{}; Slots = $slots; Node = $null; Kind = $kind; Key = $key }
    $state = Get-UiSetupState
    $state.Count++
    $state.Stack.Add($ctx)
    $bindings = $null
    try {
      if ($null -ne $setup) { $bindings = & $setup $ctx }
    } finally {
      [void]$state.Stack.RemoveAt($state.Stack.Count - 1)
    }
    $node = New-UiView $kind $key $props
    $node.State['Bindings'] = $bindings
    # the context stays on the node: a slot is invoked later, from a refresh, and that is where
    # the component's props and hooks have to be found
    $node.State['Context'] = $ctx
    $ctx.Node = $node
    foreach ($name in @($ctx.Hooks.Keys)) {
      $list = $ctx.Hooks[$name]
      # one hook per name on the node: several registrations are chained in the order they came
      $chained = $null
      foreach ($fn in $list.ToArray()) {
        $one = $fn
        $prev = $chained
        $chained = {
          param($nodeArg, $arg)
          if ($null -ne $prev) { & $prev $nodeArg $arg }
          & $one $nodeArg $arg
        }.GetNewClosure()
      }
      Add-UiHook $node $name $chained
    }
    return $node
  }
  # A closure, not a plain ScriptBlock: the declaration's own values (the defaults, the kind, the
  # setup function) are locals of this call, and a plain block would resolve them against whatever
  # scope invokes it - null, since a window is not where the component was declared.
  return $decl.GetNewClosure()
}

# The bindings a setup returned, for whoever needs a value the component computed.
function Get-UiSetupBindings($node) {
  if ($null -eq $node -or $null -eq $node.State) { return $null }
  if (-not $node.State.ContainsKey('Bindings')) { return $null }
  return $node.State['Bindings']
}

# The context of a node a setup built, for invoking its slots later.
function Get-UiSetupContextOf($node) {
  if ($null -eq $node -or $null -eq $node.State) { return $null }
  if (-not $node.State.ContainsKey('Context')) { return $null }
  return $node.State['Context']
}

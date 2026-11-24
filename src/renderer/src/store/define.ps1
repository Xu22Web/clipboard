# renderer\src\store\define.ps1 - one place that owns a piece of state, and one way to reach it.
#
# A panel and a settings window both need the history; a tray item and a window both need the
# settings. Before this file each of them read what it needed when it needed it, which works
# until two of them disagree. A store is the pinia shape:
#
#     Define-UiStore 'history' {
#       param($ctx)
#       $ctx.State.Rows = @()
#       $ctx.Getter('Count') { @($ctx.State.Rows).Count }
#       $ctx.Action('Refresh', { param($s) $s.State.Rows = @(Invoke-Ipc 'list') })
#     }
#
#     $history = Use-UiStore 'history'
#     $history.Refresh()
#     $history.Rows       # state, read as a property
#     $history.Count      # getter, computed from the state when it is read
#     $history.Patch(@{ Rows = @() })   # several keys, one notification
#     $history.Reset()                  # back to what the store was defined with
#     Get-UiStoreRefs $history          # storeToRefs: the names a view binds to
#
# Everything below is bookkeeping around that shape: a registry so two callers get the same
# object, a state bag so a write is visible to both, and a hook list so a window can be told a
# value moved. The state is plain PowerShell - a hashtable - because that is what the rest of
# this program already passes around; nothing here is reactive on its own.
#
# There is exactly one host per process: New-UiStoreHost stands in for createPinia, and
# Reset-UiStores drops every store a test made.

$script:UiStores = @{}
$script:UiStoreOrder = New-Object System.Collections.Generic.List[string]

# A store object: state and watchers in its context, getters as script properties, actions as
# script methods. A property is what makes `$s.Count` read like a field while still being
# computed (pinia's getters), and a method is what an action is.
function New-UiStoreContext([string]$Name) {
  return @{
    Name    = $Name
    State   = @{}
    Initial = @{}
    Getters = @{}
    Actions = @{}
    Watchers = New-Object System.Collections.Generic.List[object]
  }
}

# Tell the watchers what moved. A watcher takes one argument: the names that changed, or '*'
# for a wholesale replacement.
#
# The list is copied with ToArray(): @() over a generic List throws "Argument types do not
# match" on this PowerShell, which is why the rest of the program copies lists the same way.
function Invoke-UiStoreChange($Context, $Changed) {
  foreach ($w in $Context.Watchers.ToArray()) {
    try { & $w $Changed } catch { }
  }
}

# Build the object the caller holds. A getter is a ScriptProperty over its own context, an
# action a ScriptMethod, so a store reads like an object rather than a table of scriptblocks.
#
# Both are handed the store itself as their first argument, and reach the state through its
# Context property. `$this` is bound only while the property machinery runs the outer block,
# not inside a block this file invokes itself, so nothing below relies on it.
function New-UiStoreObject($Context) {
  $store = New-Object PSObject
  # the bag and the watchers, for a getter, an action, or a caller that wants to diff it
  $store | Add-Member -MemberType ScriptProperty -Name Context -Value { $Context }.GetNewClosure()
  $store | Add-Member -MemberType ScriptProperty -Name State -Value { $Context.State }.GetNewClosure()
  # State is readable as a property, the way pinia exposes it: a window asks for Rows instead of
  # for the bag. Read only, because a write has to go through an action so the watchers hear it;
  # the key set is fixed at definition time, which is why it is read here and not in the getter
  # loop. -Force lets a getter below reuse a name it computes from the state.
  foreach ($key in @($Context.State.Keys)) {
    $name = [string]$key
    $store | Add-Member -MemberType ScriptProperty -Name $name -Value { $Context.State[$name] }.GetNewClosure() -Force
  }
  foreach ($key in @($Context.Getters.Keys)) {
    $name = [string]$key
    $getter = $Context.Getters[$key]
    $store | Add-Member -MemberType ScriptProperty -Name $name -Value { & $getter $this }.GetNewClosure() -Force
  }
  foreach ($key in @($Context.Actions.Keys)) {
    $name = [string]$key
    $action = $Context.Actions[$key]
    $store | Add-Member -MemberType ScriptMethod -Name $name -Value { param($a1, $a2, $a3) & $action $this $a1 $a2 $a3 }.GetNewClosure()
  }
  # a watcher hears every change an action reports, one call per action
  $store | Add-Member -MemberType ScriptMethod -Name Subscribe -Value { param($hook) $Context.Watchers.Add($hook); return $hook }.GetNewClosure()
  # Patch and Reset are pinia's $patch and $reset, minus the dollar sign: PowerShell cannot call
  # a member whose name starts with one ($store.$patch does not parse), and a name that needs
  # quoting everywhere is worse than a name that reads like the rest of this program.
  #
  # Patch writes several keys and notifies once, because a view that hears three times redraws
  # three times. A key the store never declared is refused rather than added: the properties a
  # view reads are fixed when the store is defined, so a new key would be written and never seen.
  $store | Add-Member -MemberType ScriptMethod -Name Patch -Value {
    param($partial)
    if ($null -eq $partial) { return }
    if ($partial -is [scriptblock]) { & $partial $Context.State }
    else {
      foreach ($k in @($partial.Keys)) {
        $key = [string]$k
        if (-not $Context.State.ContainsKey($key)) { throw ('no state named ' + $key + ' in store ' + $Context.Name) }
        $Context.State[$key] = $partial[$k]
      }
    }
    Invoke-UiStoreChange $Context '*'
  }.GetNewClosure()
  # back to the state the store was defined with, for a window that is opened again or a test
  # that runs twice; the key set comes back too, so a key Patch refused cannot appear here
  $store | Add-Member -MemberType ScriptMethod -Name Reset -Value {
    param()
    $Context.State.Clear()
    foreach ($k in @($Context.Initial.Keys)) { $Context.State[[string]$k] = $Context.Initial[$k] }
    Invoke-UiStoreChange $Context '*'
  }.GetNewClosure()
  return $store
}

# storeToRefs: what a view binds to, read once - the state keys and the getters, both by their
# current value. A view is told when something moved and re-reads, so handing out live boxes
# here would only hide which read it got.
function Get-UiStoreRefs($Store) {
  $refs = @{}
  foreach ($k in @($Store.State.Keys)) { $refs[[string]$k] = $Store.State[[string]$k] }
  foreach ($k in @($Store.Context.Getters.Keys)) {
    $name = [string]$k
    $prop = $Store.PSObject.Properties[$name]
    if ($null -ne $prop) { $refs[$name] = $prop.Value }
  }
  return $refs
}

# Define one store. The body is called once, with a context it fills in; defining a name twice
# keeps the first store, because a second definition would silently hand out a second copy of
# the same state.
function Define-UiStore([string]$Name, [scriptblock]$Body) {
  if ($script:UiStores.ContainsKey($Name)) { return $script:UiStores[$Name] }
  $ctx = New-UiStoreContext $Name
  $ctx.Getter = { param($key, $fn) $ctx.Getters[$key] = $fn }
  $ctx.Action = { param($key, $fn) $ctx.Actions[$key] = $fn }
  # an action that writes state says so, so the watchers hear one change per action
  $ctx.Set = { param($key, $value) $ctx.State[$key] = $value; Invoke-UiStoreChange $ctx @($key) }
  [void](& $Body $ctx)
  # what Reset goes back to: the keys the body declared, at the values it declared them with
  foreach ($k in @($ctx.State.Keys)) { $ctx.Initial[[string]$k] = $ctx.State[$k] }
  $store = New-UiStoreObject $ctx
  $script:UiStores[$Name] = $store
  [void]$script:UiStoreOrder.Add($Name)
  return $store
}

# The store by that name. A name nobody defined is a programming mistake, not a runtime
# condition: it throws here instead of handing back an empty object that fails later.
function Use-UiStore([string]$Name) {
  if (-not $script:UiStores.ContainsKey($Name)) { throw ('no store named ' + [string]$Name) }
  return $script:UiStores[$Name]
}

# the names in the order they were defined, for a caller that wants to reset or persist them all
function Get-UiStoreNames {
  return $script:UiStoreOrder.ToArray()
}

# New-UiStoreHost is createPinia: one host per process, and every store defined after it joins
# that host. It returns the same registry the module keeps, so a caller can pass it around.
function New-UiStoreHost {
  return @{ Stores = $script:UiStores; Order = $script:UiStoreOrder }
}

# Drop every store. Tests define stores of their own and a second run would otherwise inherit
# the first one's state.
function Reset-UiStores {
  $script:UiStores = @{}
  $script:UiStoreOrder = New-Object System.Collections.Generic.List[string]
}

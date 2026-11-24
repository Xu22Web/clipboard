#@use main/utils/native
#@export Initialize-UiReactive, New-UiReactive, Get-UiReactive, Set-UiReactive, Add-UiRender, Remove-UiRender, New-UiComputed, Invoke-UiFlush, Test-UiFlushPending, New-UiApp, Test-UiAppOpen, Set-UiAppSignal, Get-UiAppSignal, Add-UiAppEffect, Close-UiApp
# renderer\src\core\reactive.ps1 - the data half of the framework: a value you can watch, and an update that
# is batched.
#
# The traps live in C# (Cb.ReactiveBag in main\reactivity\reactive-bag.cs): PowerShell has no property
# traps, so a hashtable cannot be made to tell anyone it changed, while a DynamicObject can. What
# this file adds is the vocabulary a surface uses, and the three rules that keep it from leaking:
#
#   New-UiReactive      a bag of signals. A write of the value already there is not a write.
#   Add-UiRender        an effect: it runs now, and again after any signal it read has changed.
#                       It does not run where the write happens - the write queues it, and one
#                       Invoke-UiFlush runs it once, however many writes came before.
#   New-UiComputed      a value derived from the signals an effect read, recomputed on access and
#                       only when one of them moved.
#
# Everything an effect reads is tracked; everything else is not. The handle Add-UiRender answers
# is what a window keeps: a stopped effect lets go of its ScriptBlock, and a ScriptBlock that is
# still registered holds the form it was created in. Clear-UiRender is the whole-window version.
#
# Where each of these sits next to the Composition API it comes from - the correspondence is kept
# here so a reader coming from Vue does not have to guess, and so a later change has one place to
# correct:
#
#   reactive(obj)        New-UiReactive $table        the bag is the proxy; a write of the same
#                                                     value is not a write
#   computed(getter)     New-UiComputed { ... }       .Value, lazy, marked dirty on trigger
#   watchEffect(fn)      Add-UiRender { ... }         the effect is the watcher
#   effectScope()        New-UiApp / Close-UiApp      the scope owns its effects and cells
#   nextTick()           Invoke-UiFlush               run now, not on a promise: the flush is what
#                                                     a posted window message or a paint calls
#   provide / inject     the app record itself        a window hands what it owns through it,
#                                                     because there is one window per app here
#   props                node Props + fingerprints    a node is patched only when its values move
#   emits                Add-UiHandler / Invoke-UiEmit
#   onMounted/onUnmounted Add-UiHook 'mounted' / 'unmounted'
#   v-for/:key, v-if     Sync-UiTree                  a key kept is a node kept, a spec absent is a
#                                                     node unmounted
#   v-memo               the fingerprint a surface passes to Sync-UiTree
#
# There is deliberately no ref(): a bag with one key is the same thing without a second object,
# and nothing here needs a value that crosses a function boundary by reference. There is no
# watch(source, cb) either: every change this program reacts to is a signal an effect reads, and
# the (new, old) pair a watcher would report is what the node's own `updated` hook already gets.


# The traps are C# types, so nothing here works until the assembly is up: a command that only
# touches a signal must load it, the same way a window does before it draws.
function Initialize-UiReactive {
  if ($script:UiReactiveReady) { return }
  if ($null -eq ('Cb.Reactive' -as [type])) { Add-Native }
  $script:UiReactiveReady = $true
}

function New-UiReactive($state = $null) {
  Initialize-UiReactive
  if ($null -eq $state) { return (New-Object Cb.ReactiveBag) }
  return (New-Object Cb.ReactiveBag $state)
}

# A read that tracks, for the code that wants the call shape rather than the member one.
function Get-UiReactive($bag, [string]$key, $default = $null) {
  if ($null -eq $bag) { return $default }
  if (-not $bag.Has($key)) { return $default }
  $value = $bag.Get($key)
  if ($null -eq $value) { return $default }
  return $value
}

# A write. True means the value moved, so whatever reads it has been queued.
function Set-UiReactive($bag, [string]$key, $value) {
  if ($null -eq $bag) { return $false }
  return [bool]$bag.Set($key, $value)
}

# An effect: runs immediately, then once per flush after any signal it read has moved. The
# ScriptBlock is converted to a delegate here, which is what lets C# call it without PowerShell
# in the loop for every tracked read.
function Add-UiRender([scriptblock]$fn) {
  if ($null -eq $fn) { return 0 }
  Initialize-UiReactive
  $action = [Action]$fn
  return [int][Cb.Reactive]::Effect($action)
}

function Remove-UiRender([int]$id) {
  if ($id -le 0) { return }
  Initialize-UiReactive
  [Cb.Reactive]::Stop($id)
}

# Every effect this process started. A window calls it on the way out, so opening the window a
# hundred times does not leave a hundred effects holding a hundred disposed forms.
function Clear-UiRender {
  Initialize-UiReactive
  [Cb.Reactive]::StopAll()
}

# A derived value. Recomputes when read after something it read has moved, and not otherwise.
function New-UiComputed([scriptblock]$fn) {
  if ($null -eq $fn) { return $null }
  Initialize-UiReactive
  $func = [Func[object]]$fn
  return (New-Object Cb.ComputedCell $func)
}

# Runs what the writes queued: one pass, each effect once. False means there was nothing to do,
# which is what a paint checks before it invalidates anything.
function Invoke-UiFlush {
  Initialize-UiReactive
  return ([int][Cb.Reactive]::Flush() -gt 0)
}

function Test-UiFlushPending {
  Initialize-UiReactive
  return ([int][Cb.Reactive]::Pending -gt 0)
}

# What the runtime is holding, for a log line and for the tests that guard against a leak.
function Get-UiReactiveStats {
  Initialize-UiReactive
  return @{
    Effects = [int][Cb.Reactive]::Count
    Targets = [int][Cb.Reactive]::Targets
    Pending = [int][Cb.Reactive]::Pending
    Flushes = [int][Cb.Reactive]::Flushes
    Runs    = [int][Cb.Reactive]::Runs
  }
}

# ------------------------------------------------------------------ the outermost scope
# What a window owns, in one record: its signals, the effects it started, the derived values it
# holds, and the one call that gives all of it back. A surface that opens an app cannot leave an
# effect or a cell behind by forgetting a line - the effects hold ScriptBlocks, and a ScriptBlock
# holds the form it was made in.

function New-UiApp($state = $null) {
  Initialize-UiReactive
  return @{
    Bag     = (New-UiReactive $state)
    Effects = (New-Object System.Collections.Generic.List[int])
    Cells   = (New-Object System.Collections.Generic.List[object])
    Closed  = $false
  }
}

function Test-UiAppOpen($app) {
  if ($null -eq $app) { return $false }
  if ($app.Closed) { return $false }
  return $true
}

# A signal write on the app's bag. False means the app is closed or the value did not move.
function Set-UiAppSignal($app, [string]$key, $value) {
  if (-not (Test-UiAppOpen $app)) { return $false }
  return (Set-UiReactive $app.Bag $key $value)
}

function Get-UiAppSignal($app, [string]$key, $default = $null) {
  if (-not (Test-UiAppOpen $app)) { return $default }
  return (Get-UiReactive $app.Bag $key $default)
}

# An effect owned by the app: stopped with it, without the surface keeping its id.
function Add-UiAppEffect($app, [scriptblock]$fn) {
  if (-not (Test-UiAppOpen $app) -or $null -eq $fn) { return 0 }
  $id = Add-UiRender $fn
  $app.Effects.Add($id)
  return $id
}

function Add-UiAppComputed($app, [scriptblock]$fn) {
  if (-not (Test-UiAppOpen $app) -or $null -eq $fn) { return $null }
  $cell = New-UiComputed $fn
  $app.Cells.Add($cell)
  return $cell
}

# Everything the app started, in the order that lets go cleanly: the derived values first (each
# of them owns an effect of its own), then the effects, then the bag.
function Close-UiApp($app) {
  if ($null -eq $app) { return }
  if ($app.Closed) { return }
  $app.Closed = $true
  foreach ($cell in $app.Cells) {
    if ($null -eq $cell) { continue }
    try { $cell.Dispose() } catch { }
  }
  $app.Cells.Clear()
  foreach ($id in $app.Effects) { Remove-UiRender ([int]$id) }
  $app.Effects.Clear()
  $app.Bag = $null
}

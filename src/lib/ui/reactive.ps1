# lib/ui/reactive.ps1 - the data half of the framework: a value you can watch, and an update that
# is batched.
#
# The traps live in C# (Cb.ReactiveBag in lib\assembly\cb.native.cs): PowerShell has no property
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

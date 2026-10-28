# lib/anim.ps1 - the panel's few transitions, as plain numbers.
#
# Every animated value eases toward a target and the panel only reads them while drawing,
# so switching animations off costs exactly one frame (the step becomes 1.0 and everything
# lands on its target immediately).
#
# Nothing here touches a window on purpose. An Opacity below 1 would turn the form into a
# layered window and change how it activates, which is exactly what the picker's
# no-activate model cannot afford; instead the transitions are drawn as alpha ramps inside
# the existing controls, driven by the picker's own message loop.

# the values that can be in flight: rows fade in and out, the scrollbar and grip grow on
# hover, the search underline slides in when the box is active
$script:AnimKeys = @('Hover', 'Sel', 'PrevSel', 'Sb', 'Grip', 'Field')

# which repaint each key needs, as a bit mask the picker turns into Invalidate calls:
# 1 = the list, 2 = the scrollbar, 4 = the resize grip, 8 = the search field
$script:AnimPaint = @{ Hover = 1; Sel = 1; PrevSel = 1; Sb = 2; Grip = 4; Field = 8 }

function New-AnimState {
  $s = @{ HoverIndex = -1; SelIndex = -1; PrevSelIndex = -1 }
  foreach ($k in @($script:AnimKeys)) {
    $s[$k] = 0.0
    $s[$k + 'Target'] = 0.0
  }
  return $s
}

# point one value at its destination; the frame step does the easing
function Set-AnimTarget($state, [string]$key, [double]$value) {
  $state[$key + 'Target'] = $value
}

# the pointer entered a row, or left every row (-1)
function Set-AnimHover($state, [int]$index) {
  $state['HoverIndex'] = $index
  Set-AnimTarget $state 'Hover' $(if ($index -ge 0) { 1.0 } else { 0.0 })
}

# the selection moved: the old row fades out while the new one fades in, so stepping
# through the list never blinks from one filled row to another
function Set-AnimSelection($state, [int]$index) {
  if ($index -eq $state['SelIndex']) { return }
  $state['PrevSelIndex'] = $state['SelIndex']
  $state['PrevSel'] = [double]$state['Sel']
  Set-AnimTarget $state 'PrevSel' 0.0
  $state['SelIndex'] = $index
  $state['Sel'] = 0.0
  Set-AnimTarget $state 'Sel' 1.0
}

# One frame: ease every value toward its target and report what has to be repainted. The
# step is the fraction of the remaining distance, not a fixed amount: a linear ramp moves at
# one speed and stops dead, while this covers most of the gap immediately and lands softly.
# Step 1 snaps to the target in a single frame, which is how the switch disables the effect.
function Invoke-AnimFrame($state, [double]$step) {
  $mask = 0
  foreach ($k in @($script:AnimKeys)) {
    $now = [double]$state[$k]
    $want = [double]$state[$k + 'Target']
    $next = $now + (($want - $now) * $step)
    if ([Math]::Abs($want - $next) -lt 0.015) { $next = $want }
    if ($next -eq $now) { continue }
    $state[$k] = $next
    $mask = $mask -bor [int]$script:AnimPaint[$k]
  }
  return $mask
}

# the same colour at a fraction of its own alpha: a transition fades, it never recolours
function Scale-Alpha($color, [double]$k) {
  if ($null -eq $color) { return [Drawing.Color]::FromArgb(0, 0, 0, 0) }
  if ($k -le 0) { return [Drawing.Color]::FromArgb(0, $color.R, $color.G, $color.B) }
  if ($k -ge 1) { return $color }
  return [Drawing.Color]::FromArgb([int][Math]::Round([double]$color.A * $k), $color.R, $color.G, $color.B)
}

# lib/ui/layout.ps1 - boxes: the arithmetic both drawn windows share.
#
# A window's furniture is placed by cutting rectangles: a header off the top, a footer off the
# bottom, a lane off the right, then rows down whatever is left. The history panel and the
# settings window had each written their own version of that cutting, and both scrollbars are
# the same three numbers in different words. Nothing here touches a Graphics or a form - a box
# in, boxes out - so the numbers can be checked without a window existing.
#
# A box is a plain table (Left, Top, Width, Height, Right, Bottom) for the same reason: the
# unit tests build them without System.Drawing loaded.

function New-UiBox([int]$left, [int]$top, [int]$width, [int]$height) {
  if ($width -lt 0) { $width = 0 }
  if ($height -lt 0) { $height = 0 }
  return @{
    Left = $left; Top = $top; Width = $width; Height = $height
    Right = ($left + $width); Bottom = ($top + $height)
  }
}

# The box with its edges moved in. The right and bottom edges take the left and top when they
# are left out, which is what a box padded on all sides asks for.
function Get-UiInset($box, [int]$left, [int]$top = -1, [int]$right = -1, [int]$bottom = -1) {
  if ($null -eq $box) { return $null }
  if ($top -lt 0) { $top = $left }
  if ($right -lt 0) { $right = $left }
  if ($bottom -lt 0) { $bottom = $top }
  return (New-UiBox ([int]$box.Left + $left) ([int]$box.Top + $top) `
    ([int]$box.Width - $left - $right) ([int]$box.Height - $top - $bottom))
}

# The box cut into rows, top to bottom, each as wide as the box. A negative height means "what
# is left", so a header and a footer can be named in pixels and the list between them in -1.
function Get-UiStack($box, [int[]]$heights) {
  $out = @()
  if ($null -eq $box -or $null -eq $heights) { return $out }
  $top = [int]$box.Top
  foreach ($one in $heights) {
    $h = [int]$one
    if ($h -lt 0) { $h = [Math]::Max(0, [int]$box.Bottom - $top) }
    $h = [Math]::Min($h, [Math]::Max(0, [int]$box.Bottom - $top))
    $out += (New-UiBox ([int]$box.Left) $top ([int]$box.Width) $h)
    $top += $h
  }
  return $out
}

# The box cut into columns, left to right, each as tall as the box. A negative width means
# "what is left", the same way a height does in Get-UiStack.
function Get-UiColumns($box, [int[]]$widths) {
  $out = @()
  if ($null -eq $box -or $null -eq $widths) { return $out }
  $left = [int]$box.Left
  foreach ($one in $widths) {
    $w = [int]$one
    if ($w -lt 0) { $w = [Math]::Max(0, [int]$box.Right - $left) }
    $w = [Math]::Min($w, [Math]::Max(0, [int]$box.Right - $left))
    $out += (New-UiBox $left ([int]$box.Top) $w ([int]$box.Height))
    $left += $w
  }
  return $out
}

# The thumb of a scrollbar: how long it is, and how far down the lane it sits.
#
#   trackLen      the lane a thumb may travel, in pixels
#   ratio         the visible part over the whole content (0.25 = a quarter of it is shown)
#   offsetPx      how far the content is scrolled, and how far it can be scrolled at most
#   scrollablePx
#   minLen        the shortest thumb worth grabbing
#
# Nothing is answered when the content fits: a scrollbar with a full-length thumb says the list
# is short, and a window that is not scrolled has nothing to show.
function Get-UiScrollMetrics([int]$trackLen, [double]$ratio, [double]$offsetPx, [double]$scrollablePx, [int]$minLen = 24) {
  if ($trackLen -le 0 -or $ratio -le 0 -or $ratio -ge 1) { return $null }
  $len = [int]($trackLen * $ratio)
  if ($len -lt $minLen) { $len = $minLen }
  if ($len -gt $trackLen) { $len = $trackLen }
  $room = $trackLen - $len
  $frac = 0.0
  if ($scrollablePx -gt 0) { $frac = $offsetPx / $scrollablePx }
  if ($frac -lt 0) { $frac = 0.0 }
  if ($frac -gt 1) { $frac = 1.0 }
  return @{ Len = $len; Room = $room; Top = [int][Math]::Round($room * $frac); Fraction = $frac }
}

# ---------------------------------------------------------------- the box model
#
# A style is the part of CSS these windows need, in pixels already scaled by the caller (Px),
# and with no cascade: a widget is given one style and a child never inherits from its parent.
# What is here is the arithmetic CSS defines - the four nested boxes, min and max, a gap, and
# one axis of flow - so a settings row and a block of a hover card are placed by one set of
# rules.
#
#   Margin / Border / Padding   one number, two (vertical, horizontal) or four (top, right,
#                               bottom, left): the shorthands CSS accepts, in the same order
#   Width / Height              -1 is auto: along the flow the auto children share what is
#                               left, across it the child stretches to the box
#   MinWidth / MaxWidth / MinHeight / MaxHeight   0 means no limit
#   Flow                        'column' (default) or 'row'
#   Gap                         pixels between two children
#   Align                       across the flow: start / center / end
#   Justify                     along the flow: start / center / end / space-between

# A number out of a description table, with a fallback: a child that never named its height is
# asking for the automatic one, not for zero.
function Get-UiNumber($table, [string]$key, [int]$fallback = 0) {
  if ($null -eq $table) { return $fallback }
  if (-not ($table -is [System.Collections.IDictionary])) { return $fallback }
  if (-not $table.Contains($key)) { return $fallback }
  return [int]$table[$key]
}

function Get-UiEdges($value) {
  if ($null -eq $value) { return @(0, 0, 0, 0) }
  $a = @($value)
  if ($a.Count -eq 1) { return @([int]$a[0], [int]$a[0], [int]$a[0], [int]$a[0]) }
  if ($a.Count -eq 2) { return @([int]$a[0], [int]$a[1], [int]$a[0], [int]$a[1]) }
  if ($a.Count -eq 3) { return @([int]$a[0], [int]$a[1], [int]$a[2], [int]$a[1]) }
  return @([int]$a[0], [int]$a[1], [int]$a[2], [int]$a[3])
}

function New-UiStyle($spec = $null) {
  $st = @{
    Margin = @(0, 0, 0, 0); Border = @(0, 0, 0, 0); Padding = @(0, 0, 0, 0)
    Width = -1; Height = -1
    MinWidth = 0; MaxWidth = 0; MinHeight = 0; MaxHeight = 0
    Gap = 0; Flow = 'column'; Align = 'start'; Justify = 'start'
  }
  if ($null -eq $spec) { return $st }
  foreach ($k in @($spec.Keys)) {
    $name = [string]$k
    if ($name -ceq 'Margin' -or $name -ceq 'Border' -or $name -ceq 'Padding') {
      $st[$name] = (Get-UiEdges $spec[$k])
      continue
    }
    $st[$name] = $spec[$k]
  }
  return $st
}

# The four boxes CSS defines, from the outside in: the slot a parent hands out is the margin
# box, and a border is drawn between the border box and the padding box.
function Get-UiBoxModel($slot, $style) {
  if ($null -eq $slot) { return $null }
  $m = Get-UiEdges $style.Margin
  $b = Get-UiEdges $style.Border
  $p = Get-UiEdges $style.Padding
  $border = New-UiBox ([int]$slot.Left + $m[3]) ([int]$slot.Top + $m[0]) `
    ([int]$slot.Width - $m[1] - $m[3]) ([int]$slot.Height - $m[0] - $m[2])
  $padding = New-UiBox ([int]$border.Left + $b[3]) ([int]$border.Top + $b[0]) `
    ([int]$border.Width - $b[1] - $b[3]) ([int]$border.Height - $b[0] - $b[2])
  $content = New-UiBox ([int]$padding.Left + $p[3]) ([int]$padding.Top + $p[0]) `
    ([int]$padding.Width - $p[1] - $p[3]) ([int]$padding.Height - $p[0] - $p[2])
  return @{ Slot = $slot; Border = $border; Padding = $padding; Content = $content }
}

# Children placed inside a box, one axis at a time. Each child is laid out by its own style and
# the answer is its border box - where it is drawn, and what a hit test compares against.
function Get-UiFlow($box, $style, $children) {
  $out = @()
  if ($null -eq $box -or $null -eq $style -or $null -eq $children) { return $out }
  $items = @($children)
  if ($items.Count -eq 0) { return $out }
  $content = (Get-UiBoxModel $box $style).Content
  $row = ([string]$style.Flow -ceq 'row')
  $gap = [int]$style.Gap
  $mainLen = $(if ($row) { [int]$content.Width } else { [int]$content.Height })
  $crossLen = $(if ($row) { [int]$content.Height } else { [int]$content.Width })
  $n = $items.Count

  # what the fixed children take along the flow, and how many share the rest
  $fixed = 0
  $autos = 0
  foreach ($it in $items) {
    $m = Get-UiEdges $it.Margin
    $given = Get-UiNumber $it $(if ($row) { 'Width' } else { 'Height' }) -1
    if ($given -lt 0) { $autos++ } else { $fixed += $given }
    if ($row) { $fixed += ($m[1] + $m[3]) } else { $fixed += ($m[0] + $m[2]) }
  }
  $autoSize = 0
  if ($autos -gt 0) {
    $autoSize = [int][Math]::Floor(($mainLen - ($gap * ($n - 1)) - $fixed) / $autos)
    if ($autoSize -lt 0) { $autoSize = 0 }
  }
  # justify: what is left over once everybody has taken its size
  $leftover = $mainLen - ($gap * ($n - 1)) - $fixed - ($autoSize * $autos)
  if ($leftover -lt 0) { $leftover = 0 }
  $cursor = 0
  $extra = 0
  switch ([string]$style.Justify) {
    'center' { $cursor = [int][Math]::Floor($leftover / 2) }
    'end' { $cursor = $leftover }
    'space-between' { if ($n -gt 1) { $extra = [int][Math]::Floor($leftover / ($n - 1)) } }
  }

  foreach ($it in $items) {
    $m = Get-UiEdges $it.Margin
    # along the flow
    $mainSize = Get-UiNumber $it $(if ($row) { 'Width' } else { 'Height' }) -1
    if ($mainSize -lt 0) { $mainSize = $autoSize }
    $minMain = Get-UiNumber $it $(if ($row) { 'MinWidth' } else { 'MinHeight' })
    $maxMain = Get-UiNumber $it $(if ($row) { 'MaxWidth' } else { 'MaxHeight' })
    if ($minMain -gt 0 -and $mainSize -lt $minMain) { $mainSize = $minMain }
    if ($maxMain -gt 0 -and $mainSize -gt $maxMain) { $mainSize = $maxMain }
    # across the flow
    $crossMarginA = $(if ($row) { $m[0] } else { $m[1] })
    $crossMarginB = $(if ($row) { $m[2] } else { $m[3] })
    $crossSize = Get-UiNumber $it $(if ($row) { 'Height' } else { 'Width' }) -1
    if ($crossSize -lt 0) { $crossSize = $crossLen - $crossMarginA - $crossMarginB }
    $minCross = Get-UiNumber $it $(if ($row) { 'MinHeight' } else { 'MinWidth' })
    $maxCross = Get-UiNumber $it $(if ($row) { 'MaxHeight' } else { 'MaxWidth' })
    if ($minCross -gt 0 -and $crossSize -lt $minCross) { $crossSize = $minCross }
    if ($maxCross -gt 0 -and $crossSize -gt $maxCross) { $crossSize = $maxCross }
    $crossOff = $crossMarginA
    switch ([string]$style.Align) {
      'center' { $crossOff = [int][Math]::Floor(($crossLen - $crossSize - $crossMarginA - $crossMarginB) / 2) + $crossMarginA }
      'end' { $crossOff = $crossLen - $crossSize - $crossMarginB }
    }
    if ($crossOff -lt 0) { $crossOff = 0 }
    if ($row) {
      $out += (New-UiBox ([int]$content.Left + $cursor + $m[3]) ([int]$content.Top + $crossOff) $mainSize $crossSize)
      $cursor += $m[1] + $mainSize + $m[3] + $gap + $extra
    } else {
      $out += (New-UiBox ([int]$content.Left + $crossOff) ([int]$content.Top + $cursor + $m[0]) $crossSize $mainSize)
      $cursor += $m[0] + $mainSize + $m[2] + $gap + $extra
    }
  }
  return $out
}

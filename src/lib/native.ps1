# lib/native.ps1 - the platform layer: the Win32 entry points, the WinForms types the panel
# needs, the assembly loading, the font probe and the DPI factor.
#
# Everything here touches the machine (Add-Type, RegisterHotKey, the installed fonts), which
# is why it is not in utils\: that folder holds the pure helpers - log, time, format, draw.
# No clipboard, no settings and no panel state beyond the DPI factor, so a command, the
# picker and the resident loop can all call into this file.

# The C# lives in lib\assembly (cb.native.cs) and can be compiled ahead of time into
# lib\assembly\clipboard.dll by tools\build-assembly.ps1: a cold panel open takes 850 ms with
# the assembly against 1050 ms compiling the source (measured, three runs each). A development
# copy that never ran the build keeps the source path: no assembly, compile the .cs.
function Test-NativeAssembly {
  if ($script:NativeAssemblyChecked) { return $script:NativeAssemblyOk }
  $script:NativeAssemblyChecked = $true
  $script:NativeAssemblyOk = $false
  try {
    $asmPath = Join-Path $Root 'lib\assembly\clipboard.dll'
    if (-not (Test-Path -LiteralPath $asmPath)) { return $false }
    # source newer than the assembly means the file is stale: compile the source instead of
    # running C# that no longer matches this copy of the module
    $asmTime = (Get-Item -LiteralPath $asmPath).LastWriteTimeUtc
    $csDir = Join-Path $Root 'lib\assembly'
    if (Test-Path -LiteralPath $csDir) {
      foreach ($f in @(Get-ChildItem -LiteralPath $csDir -Filter '*.cs' -File)) {
        if ($f.LastWriteTimeUtc -gt $asmTime) { return $false }
      }
    }
    [void][Reflection.Assembly]::LoadFrom($asmPath)
    $script:NativeAssemblyOk = [bool]('Cb.Win' -as [type])
  } catch {
    $script:NativeAssemblyOk = $false
  }
  return $script:NativeAssemblyOk
}

function Add-Native {
  if ($script:NativeReady) { return }
  if (Test-NativeAssembly) { $script:NativeReady = $true; return }
  # The C# lives in lib\assembly. A packaged copy ships without it and runs from
  # lib\assembly\clipboard.dll, so empty source here means the assembly went missing: say so
  # instead of handing Add-Type "".
  $cs = ''
  $csPath = Join-Path $Root 'lib\assembly\cb.native.cs'
  if (Test-Path -LiteralPath $csPath) { $cs = [IO.File]::ReadAllText($csPath) }
  if (-not $cs) { throw 'lib\assembly\clipboard.dll is missing and this copy carries no C# source' }
  Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
  $script:NativeReady = $true
}

function Load-Forms {
  if ($script:FormsReady) { return }
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
  $script:FormsReady = $true
}

function Test-Font([string]$name) {
  # Enumerating the installed families costs ~50 ms and the picker asks three to six times
  # on every show, so the list is read once per process and kept as a set.
  if ($null -eq $script:FontNames) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try {
      foreach ($f in (New-Object Drawing.Text.InstalledFontCollection).Families) { [void]$set.Add($f.Name) }
    } catch { }
    $script:FontNames = $set
  }
  return $script:FontNames.Contains($name)
}

function Use-Drawing {
  if ($script:DrawingReady) { return }
  try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch { Write-Log ('System.Drawing unavailable: ' + $_.Exception.Message) }
  $script:DrawingReady = $true
}

function Initialize-Dpi {
  if ($script:DpiReady) { return }
  $script:DpiReady = $true
  $script:UiScale = 1.0
  try {
    if (-not $script:DpiAware) { return }
    Add-Native
    [void][Cb.Win]::SetProcessDPIAware()
    try {
      $d = [int][Cb.Win]::GetDpiForSystem()
      if ($d -ge 96 -and $d -le 480) { $script:SysDpi = $d; $script:UiScale = [double]$d / 96.0 }
    } catch { }
  } catch { $script:UiScale = 1.0 }
}

# ---- where the keyboard is ---------------------------------------------------------
# The panel wants the spot the user is typing at, and no single API covers the field:
#
#   caret     - GUITHREADINFO.rcCaret, filled only by controls that use the old Win32 caret
#   msaa      - the OBJID_CARET object, for a control that draws its own caret
#   uia       - UI Automation's TextPattern selection, which is what Electron, browsers,
#               RichEdit and UWP report instead of a caret
#   msaa-box  - the rectangle accessibility reports for the focused element, for a provider
#               that keeps no caret object but still knows what is being typed in
#   control   - the focused control's own rectangle, the last thing that always exists
#
# The exact sources answer for most applications; the box sources keep a meaningless
# rectangle from being used as if it were a caret. UI Automation is loaded once (~150 ms) and
# answers in single-digit milliseconds afterwards, which is why the panel's warm-up runs this
# path too. Both accessibility tiers call accLocation through a declared interface: the
# late-bound call reads back zeros and never produced a rectangle at all.
function Initialize-CaretLookup {
  if ($null -ne $script:CaretUiaReady) { return $script:CaretUiaReady }
  $script:CaretUiaReady = $false
  try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $script:CaretUiaReady = $true
  } catch { Write-Log ('uia unavailable: ' + $_.Exception.Message) }
  return $script:CaretUiaReady
}

# The caret rectangle of the focused text element, or Empty. Both the process check and the
# responsiveness check matter: FocusedElement can belong to another application, and a window
# that hangs turns the accessibility call into a blocking wait.
function Get-UiaCaretRect([IntPtr]$hwnd) {
  if ($hwnd -eq [IntPtr]::Zero) { return [Drawing.Rectangle]::Empty }
  if (-not (Initialize-CaretLookup)) { return [Drawing.Rectangle]::Empty }
  try { if (-not [Cb.Win]::IsResponsive($hwnd, 40)) { return [Drawing.Rectangle]::Empty } } catch { }
  $el = $null
  try { $el = [Windows.Automation.AutomationElement]::FocusedElement } catch { return [Drawing.Rectangle]::Empty }
  if ($null -eq $el) { return [Drawing.Rectangle]::Empty }
  $targetPid = [uint32]0
  try { [void][Cb.Win]::GetWindowOwnerProcessId($hwnd, [ref]$targetPid) } catch { return [Drawing.Rectangle]::Empty }
  if ([int]$targetPid -le 0 -or [int]$el.Current.ProcessId -ne [int]$targetPid) { return [Drawing.Rectangle]::Empty }
  $pattern = $null
  try {
    foreach ($p in @($el.GetSupportedPatterns())) {
      if ($p.ProgrammaticName -eq 'TextPatternIdentifiers.Pattern') { $pattern = $p; break }
    }
  } catch { return [Drawing.Rectangle]::Empty }
  if ($null -eq $pattern) { return [Drawing.Rectangle]::Empty }
  try {
    $tp = $el.GetCurrentPattern($pattern)
    $range = $null
    foreach ($rg in $tp.GetSelection()) { $range = $rg; break }
    if ($null -eq $range) { return [Drawing.Rectangle]::Empty }
    # The rectangles come back as an array that PowerShell hands over as one object, and the
    # framework converts each entry to System.Windows.Rect: the four numbers are read from the
    # first rectangle, whichever of the two shapes it arrives in.
    $vals = New-Object System.Collections.Generic.List[double]
    foreach ($v in $range.GetBoundingRectangles()) {
      if ($null -ne $v -and $null -ne $v.PSObject.Properties['Left']) {
        $vals.Add([double]$v.Left); $vals.Add([double]$v.Top)
        $vals.Add([double]$v.Width); $vals.Add([double]$v.Height)
        break
      }
      $vals.Add([double]$v)
      if ($vals.Count -ge 4) { break }
    }
    if ($vals.Count -lt 4) { return [Drawing.Rectangle]::Empty }
    $x = [int][Math]::Round($vals[0])
    $y = [int][Math]::Round($vals[1])
    $w = [int][Math]::Round($vals[2])
    $h = [int][Math]::Round($vals[3])
    # an editor may report the whole line for a collapsed selection: the height still marks
    # the line, and the left edge is where that line starts
    if ($h -le 0) { $h = [int][Math]::Max(1, [int]$script:Metric['RowHeight'] / 2) }
    if ($w -le 0) { $w = 1 }
    # A caret is inside the element that owns it. A provider answering from a stale node
    # reports a rectangle somewhere else on screen, which is worse than no answer at all.
    $inside = $true
    try {
      $b = $el.Current.BoundingRectangle
      $bx = [double]$b.Left; $by = [double]$b.Top
      $bw = [double]$b.Width; $bh = [double]$b.Height
      if (-not [double]::IsInfinity($bw) -and -not [double]::IsInfinity($bh) -and $bw -gt 0 -and $bh -gt 0) {
        $tol = 4
        $inside = ($x -ge ($bx - $tol)) -and ($y -ge ($by - $tol)) -and
          (($x + $w) -le ($bx + $bw + $tol)) -and (($y + $h) -le ($by + $bh + $tol))
      }
    } catch { $inside = $true }
    if (-not $inside) { return [Drawing.Rectangle]::Empty }
    return New-Object Drawing.Rectangle -ArgumentList @($x, $y, $w, $h)
  } catch {
    Write-Log ('uia caret: ' + $_.Exception.Message)
    return [Drawing.Rectangle]::Empty
  }
}

# The caret of a text element as UI Automation reports it, cloned so it can be put back later.
# The panel has to take the foreground to be used, and some editors answer that by dropping
# their selection: the paste then lands at the start of the field while the caret was at the
# end (measured on a page that resets its selection on blur). Windows that keep their own
# caret need none of this, and a provider without a text pattern returns nothing at all.
#
# Two sources, because the field kinds differ: UI Automation answers for the browsers and for
# every control that publishes a text pattern, while a plain Win32 edit control - Notepad, a
# WinForms TextBox, several chat clients - publishes none and answers EM_GETSEL instead. The
# focus handle is what decides which one is asked, and it is also what the second path needs.
function Save-UiaSelection([IntPtr]$hwnd, [IntPtr]$focus = [IntPtr]::Zero) {
  if ($hwnd -eq [IntPtr]::Zero) { return @() }
  if ($focus -ne [IntPtr]::Zero) {
    $isEdit = $false
    try { Add-Native; $isEdit = [Cb.Win]::IsEditControl($focus) } catch { $isEdit = $false }
    if ($isEdit) {
      $s = 0
      $e = 0
      try {
        if ([Cb.Win]::GetEditSelection($focus, [ref]$s, [ref]$e)) {
          return @(@{ Kind = 'edit'; Hwnd = $focus; Start = [int]$s; End = [int]$e })
        }
      } catch { }
    }
  }
  if (-not (Initialize-CaretLookup)) { return @() }
  try { if (-not [Cb.Win]::IsResponsive($hwnd, 40)) { return @() } } catch { return @() }
  $el = $null
  try { $el = [Windows.Automation.AutomationElement]::FocusedElement } catch { return @() }
  if ($null -eq $el) { return @() }
  $targetPid = [uint32]0
  try { [void][Cb.Win]::GetWindowOwnerProcessId($hwnd, [ref]$targetPid) } catch { return @() }
  if ([int]$targetPid -le 0 -or [int]$el.Current.ProcessId -ne [int]$targetPid) { return @() }
  $pattern = $null
  try {
    foreach ($p in @($el.GetSupportedPatterns())) {
      if ($p.ProgrammaticName -eq 'TextPatternIdentifiers.Pattern') { $pattern = $p; break }
    }
  } catch { return @() }
  if ($null -eq $pattern) { return @() }
  $saved = New-Object System.Collections.Generic.List[object]
  try {
    $tp = $el.GetCurrentPattern($pattern)
    foreach ($rg in @($tp.GetSelection())) {
      if ($null -ne $rg) { $saved.Add(@{ Kind = 'uia'; Range = $rg.Clone() }) }
    }
  } catch { return @() }
  return , $saved.ToArray()
}

# Put those selections back, which is also what places the caret again. Returns how many were
# restored; an entry whose element or window is gone throws and is skipped.
function Restore-UiaSelection($ranges) {
  $done = 0
  foreach ($item in @($ranges)) {
    if ($null -eq $item) { continue }
    try {
      if ($item -is [hashtable] -and $item.Kind -eq 'edit') {
        if ([Cb.Win]::SetEditSelection($item.Hwnd, [int]$item.Start, [int]$item.End)) { $done++ }
      } elseif ($item -is [hashtable] -and $null -ne $item.Range) {
        $item.Range.Select()
        $done++
      }
    } catch { }
  }
  return $done
}

# A rectangle the panel may be anchored to. Two kinds are refused: the one a provider reports
# when it knows nothing (0,0 and no size), and the one that covers the whole window - an editor
# filling its client area says no more than the window does, and anchoring to it puts the panel
# in a screen corner instead of near the typing.
function Test-AnchorRect($rect, $window) {
  if ($null -eq $rect) { return $false }
  $w = [int]$rect.Width
  $h = [int]$rect.Height
  if ($w -le 0 -and $h -le 0) { return $false }
  if ([int]$rect.Left -eq 0 -and [int]$rect.Top -eq 0) { return $false }
  if ($null -ne $window -and [int]$window.Width -gt 0 -and [int]$window.Height -gt 0) {
    if ($w -ge [int]([int]$window.Width * 0.9) -and $h -ge [int]([int]$window.Height * 0.9)) { return $false }
  }
  return $true
}

# The box of the focused element, for elements that expose no text selection: a palette row or
# a plain text field still says where the typing goes. Empty when it cannot be read.
function Get-UiaBoxRect([IntPtr]$hwnd) {
  if ($hwnd -eq [IntPtr]::Zero) { return [Drawing.Rectangle]::Empty }
  if (-not (Initialize-CaretLookup)) { return [Drawing.Rectangle]::Empty }
  try { if (-not [Cb.Win]::IsResponsive($hwnd, 40)) { return [Drawing.Rectangle]::Empty } } catch { return [Drawing.Rectangle]::Empty }
  $el = $null
  try { $el = [Windows.Automation.AutomationElement]::FocusedElement } catch { return [Drawing.Rectangle]::Empty }
  if ($null -eq $el) { return [Drawing.Rectangle]::Empty }
  $targetPid = [uint32]0
  try { [void][Cb.Win]::GetWindowOwnerProcessId($hwnd, [ref]$targetPid) } catch { return [Drawing.Rectangle]::Empty }
  if ([int]$targetPid -le 0 -or [int]$el.Current.ProcessId -ne [int]$targetPid) { return [Drawing.Rectangle]::Empty }
  try {
    $b = $el.Current.BoundingRectangle
    $w = [double]$b.Width
    $h = [double]$b.Height
    if ([double]::IsInfinity($w) -or [double]::IsInfinity($h) -or $w -le 0 -or $h -le 0) { return [Drawing.Rectangle]::Empty }
    # an element that small is a button, a status-bar item or an icon: it is where the focus
    # happens to be, not where text is typed, and anchoring to it is worse than centring
    if ($w -lt 120 -or $h -lt 16) { return [Drawing.Rectangle]::Empty }
    return New-Object Drawing.Rectangle -ArgumentList @(
      [int][Math]::Round([double]$b.Left), [int][Math]::Round([double]$b.Top),
      [int][Math]::Round($w), [int][Math]::Round($h))
  } catch { return [Drawing.Rectangle]::Empty }
}

# The height of one line of text, for the sources that report a point and no box (GetCaretPos).
# 18 px is one line of the interface font at 96 dpi before scaling: the value only has to say
# where the caret's line ends, not how tall the target's font is.
function Get-CaretLineHeight {
  $h = [int][Math]::Round(18 * [double]$script:UiScale)
  if ($h -lt 12) { $h = 12 }
  return $h
}

# UI Automation answers in the physical pixels of the provider's monitor, while this process
# lays out in the system DPI space: on a screen with another scale the two do not agree, and
# the panel lands beside the caret instead of on it. The window's DPI over the system DPI is
# the ratio that brings the rectangle back (0 when the system does not answer - older than
# Windows 10 1607 - and then the rectangle is kept as it is).
function Convert-UiaRect($rect, [IntPtr]$hwnd) {
  if ($null -eq $rect) { return $rect }
  $rd = 0
  try { $rd = [int][Cb.Win]::WindowDpi($hwnd) } catch { $rd = 0 }
  if ($rd -le 0 -or $rd -eq [int]$script:SysDpi) { return $rect }
  $k = [double]$script:SysDpi / [double]$rd
  return New-Object Drawing.Rectangle -ArgumentList @(
    [int][Math]::Round([double]$rect.Left * $k),
    [int][Math]::Round([double]$rect.Top * $k),
    [int][Math]::Max(1, [int][Math]::Round([double]$rect.Width * $k)),
    [int][Math]::Max(1, [int][Math]::Round([double]$rect.Height * $k)))
}

# The anchor the panel is placed against, and the name of the source that answered, so the log
# says why a position was chosen. Empty means nothing is known and the monitor decides.
#
# The order follows what the field reports: rcCaret is what a Win32 edit control keeps, the
# attached caret is what the input queue knows, MSAA is what older controls expose (Ditto asks
# it first for that reason), UI Automation is what browsers, Electron, RichEdit and UWP report,
# the accessibility box is what an application without a caret object still knows, and the
# focused control is the last thing that always exists.
function Get-CaretAnchor([IntPtr]$hwnd) {
  $script:CaretSource = 'none'
  if ($hwnd -eq [IntPtr]::Zero) { return [Drawing.Rectangle]::Empty }
  # a cloaked store application, a shell surface or a tool window reports itself as the window
  # in front but types nothing; anchoring to one puts the panel on the desktop
  try {
    if (-not [Cb.Win]::IsUsableTarget($hwnd)) { $script:CaretSource = 'no-target'; return [Drawing.Rectangle]::Empty }
  } catch { }
  $window = $null
  try { $window = [Cb.Win]::WindowBounds($hwnd) } catch { $window = $null }
  try {
    $r = [Cb.Win]::CaretOfWindow($hwnd)
    if ($r.Height -gt 0 -and (Test-AnchorRect $r $window)) { $script:CaretSource = 'caret'; return $r }
  } catch { }
  # The caret the input queue knows, for a control that draws its own and reports no rcCaret:
  # a point and no height, so one line of text is what turns it into an anchor.
  try {
    $r = [Cb.Win]::AttachedCaret($hwnd)
    if ($r.Width -gt 0 -and $r.Height -le 0) {
      $r = New-Object Drawing.Rectangle -ArgumentList @([int]$r.Left, [int]$r.Top, [int]$r.Width, (Get-CaretLineHeight))
    }
    if ($r.Height -gt 0 -and (Test-AnchorRect $r $window)) { $script:CaretSource = 'caret-pos'; return $r }
  } catch { }
  # The line a plain edit control types at, read from its selection instead of from the caret it
  # draws: a WinForms TextBox publishes no UI Automation text pattern and a control that draws no
  # caret reports no rcCaret, so without this layer the panel only had the whole box and answered
  # with fewer rows because the box looked full. RichEdit answers nothing here on purpose.
  try {
    $r = [Cb.Win]::EditCaretRect($hwnd)
    if ($r.Height -gt 0 -and (Test-AnchorRect $r $window)) { $script:CaretSource = 'caret-line'; return $r }
  } catch { }
  try {
    $r = [Cb.Win]::MsaaCaret($hwnd)
    if ($r.Width -gt 0 -and $r.Height -le 0) {
      $r = New-Object Drawing.Rectangle -ArgumentList @([int]$r.Left, [int]$r.Top, [int]$r.Width, (Get-CaretLineHeight))
    }
    if ($r.Height -gt 0 -and (Test-AnchorRect $r $window)) { $script:CaretSource = 'msaa'; return $r }
  } catch { }
  try {
    $r = Convert-UiaRect (Get-UiaCaretRect $hwnd) $hwnd
    if ($r.Height -gt 0 -and (Test-AnchorRect $r $window)) { $script:CaretSource = 'uia'; return $r }
  } catch { }
  try {
    $r = Convert-UiaRect (Get-UiaBoxRect $hwnd) $hwnd
    if ($r.Height -gt 0 -and (Test-AnchorRect $r $window)) { $script:CaretSource = 'uia-box'; return $r }
  } catch { }
  # The field being typed in, for a provider whose caret object is empty: Chromium answers no
  # rcCaret, no GetCaretPos and no OBJID_CARET for a page, but its accessibility object still
  # says which element holds the keyboard and where that element is.
  try {
    $r = [Cb.Win]::MsaaFocusRect($hwnd)
    if ($r.Height -gt 0 -and (Test-AnchorRect $r $window)) { $script:CaretSource = 'msaa-box'; return $r }
  } catch { }
  try {
    $r = [Cb.Win]::FocusControlBounds($hwnd)
    if ($r.Height -gt 0 -and (Test-AnchorRect $r $window)) { $script:CaretSource = 'control'; return $r }
  } catch { }
  return [Drawing.Rectangle]::Empty
}

# Whether the shell's own clipboard history (Win+V) is usable here. This tool keeps its own
# history, so the answer is only ever a hint - but it is the one thing the user cannot work
# out from the tool: the switch is a registry value, the block is a policy, and the service
# is a per-user instance of the cbdhsvc template. '' means nothing to report.
function Get-WinVState {
  $on = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Clipboard' -Name EnableClipboardHistory -ErrorAction SilentlyContinue).EnableClipboardHistory
  if ($null -eq $on -or [int]$on -ne 1) { return 'off (HKCU EnableClipboardHistory is not 1)' }
  $pol = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name AllowClipboardHistory -ErrorAction SilentlyContinue).AllowClipboardHistory
  if ($null -ne $pol -and [int]$pol -eq 0) { return 'blocked by policy AllowClipboardHistory=0' }
  $svc = @(Get-Service -Name 'cbdhsvc*' -ErrorAction SilentlyContinue)
  if ($svc.Count -eq 0) {
    if (-not (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\cbdhsvc')) { return 'not available on this Windows build' }
    return 'the per-user service instance is missing'
  }
  return ''
}

# The paste chord read as a SendKeys string: modifiers plus one key. SendKeys builds its
# modifier from a virtual key with no scan code, and an input method can answer that with
# VK_PROCESSKEY: the target then sees a bare letter and nothing is pasted (measured on
# Chromium 76, once in about ten opens). A chord that goes out through SendInput with the
# scan code avoids that, so one is recognised here; anything else - a key sequence, a repeat,
# a name this does not know - answers $null and stays with SendKeys.
$script:SendKeysVk = @{
  '{ENTER}' = 0x0D; '{TAB}' = 0x09; '{ESC}' = 0x1B; '{BACKSPACE}' = 0x08; '{DELETE}' = 0x2E
  '{INSERT}' = 0x2D; '{HOME}' = 0x24; '{END}' = 0x23; '{PGUP}' = 0x21; '{PGDN}' = 0x22
  '{LEFT}' = 0x25; '{UP}' = 0x26; '{RIGHT}' = 0x27; '{DOWN}' = 0x28; '{SPACE}' = 0x20
}

function ConvertFrom-SendKeysChord([string]$keys) {
  if ([string]::IsNullOrEmpty($keys)) { return $null }
  $ctrl = $false
  $alt = $false
  $shift = $false
  $at = 0
  while ($at -lt $keys.Length) {
    $c = $keys[$at]
    if ($c -eq '^') { $ctrl = $true; $at++; continue }
    if ($c -eq '%') { $alt = $true; $at++; continue }
    if ($c -eq '+') { $shift = $true; $at++; continue }
    break
  }
  $rest = $keys.Substring($at)
  if ($rest.Length -eq 0) { return $null }
  $vk = 0
  $upper = $rest.ToUpperInvariant()
  if ($rest.Length -eq 1) {
    # a letter or a digit: its upper case code is the virtual key
    $ch = [char]::ToUpperInvariant($rest[0])
    if (($ch -ge 'A' -and $ch -le 'Z') -or ($ch -ge '0' -and $ch -le '9')) { $vk = [int]$ch }
  } elseif ($script:SendKeysVk.ContainsKey($upper)) {
    $vk = [int]$script:SendKeysVk[$upper]
  } elseif ($upper -match '^\{F([1-9]|1[0-9]|2[0-4])\}$') {
    $vk = 0x70 + [int]$Matches[1] - 1
  }
  if ($vk -le 0) { return $null }
  return @{ Vk = [uint16]$vk; Ctrl = $ctrl; Alt = $alt; Shift = $shift }
}

# The first key a window receives after it comes up is handed to the input method and answered
# with VK_PROCESSKEY, so the chord behind it lands as a bare letter (measured on Chromium 76:
# one open in three while the browser was starting, never once it had been up for a while).
# The modifier is pressed and released on its own first, so the key that gets spent is that one.
$script:PasteWarmMs = 60

# $false means "not one chord" - the caller keeps SendKeys for the rest
function Send-PasteChord([string]$keys) {
  $chord = ConvertFrom-SendKeysChord $keys
  if ($null -eq $chord) { return $false }
  try {
    Add-Native
    # only Ctrl: a bare Alt opens the menu bar and a bare Shift switches the input method
    if ($chord.Ctrl) {
      [void][Cb.Win]::SendChord(0x11, $false, $false, $false)
      Start-Sleep -Milliseconds $script:PasteWarmMs
    }
    return [Cb.Win]::SendChord([uint16]$chord.Vk, [bool]$chord.Ctrl, [bool]$chord.Alt, [bool]$chord.Shift)
  } catch { return $false }
}

# Is the resident that holds the machine-wide mutex serving *this* store? A second copy of the
# tool - another install, a test sandbox - keeps its own data folder, so the mutex alone says
# nothing: the hotkey file the resident writes into its own data\ is what tells them apart,
# and '(stopped)' is what its supervisor leaves behind on the way out.
function Test-ResidentOwnsStore {
  $alive = $false
  try {
    $probe = New-Object System.Threading.Mutex($false, $MutexName)
    if ($probe.WaitOne(0)) { $probe.ReleaseMutex() } else { $alive = $true }
    $probe.Dispose()
  } catch { }
  if (-not $alive) { return $false }
  $marker = Join-Path $StoreDir 'hotkey.txt'
  if (-not (Test-Path -LiteralPath $marker)) { return $false }
  try { return (([IO.File]::ReadAllText($marker)).Trim() -ne '(stopped)') } catch { return $false }
}

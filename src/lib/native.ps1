# lib/native.ps1 - the platform layer: the Win32 entry points, the WinForms types the panel
# needs, the assembly loading, the font probe and the DPI factor.
#
# Everything here touches the machine (Add-Type, RegisterHotKey, the installed fonts), which
# is why it is not in utils\: that folder holds the pure helpers - log, time, format, draw.
# No clipboard, no settings and no panel state beyond the DPI factor, so a command, the
# picker and the resident loop can all call into this file.

# The C# lives in lib\assembly - cb.native.cs here, cb.keyhook.cs for lib\panel\keyhook.ps1 -
# and can be compiled ahead of time into lib\assembly\clipboard.dll by tools\build-assembly.ps1:
# a cold panel open takes 850 ms with the assembly against 1050 ms compiling the source
# (measured, three runs each). A development copy that never ran the build keeps the source
# path: no assembly, compile the .cs.
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
      if ($d -ge 96 -and $d -le 480) { $script:UiScale = [double]$d / 96.0 }
    } catch { }
  } catch { $script:UiScale = 1.0 }
}

# ---- where the keyboard is ---------------------------------------------------------
# The panel wants the spot the user is typing at, and no single API covers the field:
#
#   caret   - GUITHREADINFO.rcCaret, filled only by controls that use the old Win32 caret
#   uia     - UI Automation's TextPattern selection, which is what Electron, browsers,
#             RichEdit and UWP report instead of a caret
#   control - the focused control's own rectangle, the last thing that always exists
#
# The first two answer for most applications; the third keeps a meaningless rectangle from
# being used as if it were a caret. UI Automation is loaded once (~150 ms) and answers in
# single-digit milliseconds afterwards, which is why the panel's warm-up runs this path too.
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

# The anchor the panel is placed against, and the name of the source that answered, so the log
# says why a position was chosen. Empty means nothing is known and the monitor decides.
# The height of one line of text where the caret is, for the sources that report a point and no
# box (GetCaretPos). Unscaled 18 px is one line of the interface font at 96 dpi; the panel only
# needs it to know where the line ends, so the value is the length of a caret rather than a
# measurement of the target's font.
function Get-CaretLineHeight {
  $h = [int][Math]::Round(18 * [double]$script:UiScale)
  if ($h -lt 12) { $h = 12 }
  return $h
}

function Get-CaretAnchor([IntPtr]$hwnd) {
  $script:CaretSource = 'none'
  if ($hwnd -eq [IntPtr]::Zero) { return [Drawing.Rectangle]::Empty }
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
  try {
    $r = Get-UiaCaretRect $hwnd
    if ($r.Height -gt 0 -and (Test-AnchorRect $r $window)) { $script:CaretSource = 'uia'; return $r }
  } catch { }
  try {
    $r = Get-UiaBoxRect $hwnd
    if ($r.Height -gt 0 -and (Test-AnchorRect $r $window)) { $script:CaretSource = 'uia-box'; return $r }
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

# Is the resident that holds the machine-wide mutex serving *this* store? A second copy of the
# tool - another install, a test sandbox - keeps its own data folder, so the mutex alone says
# nothing: the hotkey file the resident writes into its own data\ is what tells them apart,
# and '(stopped)' is what its supervisor leaves behind on the way out.
function Test-ResidentOwnsStore {
  $alive = $false
  try {
    $m = New-Object System.Threading.Mutex($false, $MutexName)
    if ($m.WaitOne(0)) { $m.ReleaseMutex() } else { $alive = $true }
    $m.Dispose()
  } catch { }
  if (-not $alive) { return $false }
  $marker = Join-Path $StoreDir 'hotkey.txt'
  if (-not (Test-Path -LiteralPath $marker)) { return $false }
  try { return (([IO.File]::ReadAllText($marker)).Trim() -ne '(stopped)') } catch { return $false }
}

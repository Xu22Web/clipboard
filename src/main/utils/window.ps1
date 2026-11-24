# src\main\utils\window.ps1 - one place that makes a window and knows what it can be asked.
#
# The shape follows Electron's BrowserWindow, because the windows of this program are the same
# thing the windows of an Electron app are: a frame the program owns, its lifetime, and the events
# it raises. A window is named once and referred to by that name afterwards.
#
#   Electron                        here
#   new BrowserWindow(options)      New-AppWindow -Name 'settings' -Width 520 -Height 640
#   win.loadFile / loadURL          Set-AppWindowContent -Name 'settings' -Paint { param($g, $e) ... }
#   win.on('closed', fn)            Register-AppWindowEvent -Name 'settings' -Event Closed -Handler { ... }
#   win.on('close', fn)             Register-AppWindowEvent -Name 'settings' -Event Closing -Handler { ... }
#   win.on('show' / 'focus' / 'blur')  Register-AppWindowEvent -Event Shown / Activated / Deactivate
#   win.show() / win.hide()         Show-AppWindow / Hide-AppWindow
#   win.close()                     Close-AppWindow
#   win.isVisible()                 Test-AppWindowVisible
#   win.setTitle / setSize / move   Set-AppWindowTitle / Set-AppWindowSize / Set-AppWindowPosition
#   win.isDestroyed()               Test-AppWindowAlive
#   BrowserWindow.getAllWindows()   Get-AppWindowNames
#   win.webContents.send            Request-Window (src\preload\utils\window-host.ps1)
#
# Creating a name that already exists returns the frame that exists: a second click on "settings"
# raises the window instead of opening a second one. That is what getFocusedWindow does, and it is
# the reason a caller never has to track a handle.
$script:AppWindows = @{}

# A window as this file keeps it: the frame, the handlers a caller registered, and the paint block
# the frame draws with. Keeping the paint block here (instead of in a closure) is what lets a
# window be created, then filled in later - the settings window knows its layout only after its
# model exists.
function Get-AppWindowRecord([string]$Name) {
  $key = [string]$Name
  if (-not $script:AppWindows.ContainsKey($key)) { return $null }
  return $script:AppWindows[$key]
}

function Get-AppWindow([string]$Name) {
  $record = Get-AppWindowRecord $Name
  if ($null -eq $record) { return $null }
  return $record.Form
}

function Get-AppWindowNames {
  return @($script:AppWindows.Keys)
}

function Test-AppWindowAlive([string]$Name) {
  $form = Get-AppWindow $Name
  if ($null -eq $form) { return $false }
  return -not $form.IsDisposed
}

function Test-AppWindowVisible([string]$Name) {
  $form = Get-AppWindow $Name
  if ($null -eq $form) { return $false }
  if ($form.IsDisposed) { return $false }
  return [bool]$form.Visible
}

# The frame a window is: everything here is what every window in this program needs and none of
# them should have to write twice - double buffering, the DPI scale, no taskbar entry, a fixed
# border style, and the closed handler that forgets the name.
function New-AppWindow {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [int]$Width = 0,
    [int]$Height = 0,
    [string]$Frame = '',
    [switch]$Borderless,
    [switch]$TopMost,
    [switch]$NoTaskbar,
    [switch]$Center,
    [switch]$Resizable,
    [string]$Title = ''
  )
  $existing = Get-AppWindow $Name
  if ($null -ne $existing -and -not $existing.IsDisposed) { return $existing }

  # the frame is the one thing a window may bring of its own: the panel and the settings window
  # draw their own edge (Cb.FluentForm), a plain window takes the framework's
  $form = $null
  if ($Frame) { $form = New-Object $Frame } else { $form = New-Object System.Windows.Forms.Form }
  $form.Text = $Title
  $form.ShowInTaskbar = (-not $NoTaskbar)
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  if ($Center) { $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen }
  if ($Borderless) { $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None }
  elseif ($Resizable) { $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable }
  else { $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle }
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.TopMost = [bool]$TopMost
  # Double buffering and the three paint styles are protected members of Control, which
  # PowerShell cannot set on an instance - Cb.FluentForm sets them in its constructor
  # (src\main\ui\fluent-form.cs). A window built on a plain Form draws without them.
  if ($Width -gt 0) { $form.Width = $Width }
  if ($Height -gt 0) { $form.Height = $Height }

  $script:AppWindows[[string]$Name] = @{ Form = $form; Handlers = @{}; Wired = @{}; Paint = $null }
  return $form
}

# What the window draws. Replacing the block replaces the painting; the frame keeps working.
#
# The block handed to WinForms outlives this call, so nothing inside it may read a local variable:
# the name is copied into a closure of its own and the record is looked up when Paint runs.
function Set-AppWindowContent {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Paint
  )
  $record = Get-AppWindowRecord $Name
  if ($null -eq $record) { throw ('no window named ' + $Name) }
  $record.Paint = $Paint
  $form = $record.Form
  $name = [string]$Name
  $paint = {
    param($sender, $e)
    $rec = Get-AppWindowRecord $name
    if ($null -eq $rec) { return }
    $block = $rec.Paint
    if ($null -eq $block) { return }
    & $block $e.Graphics $e
  }.GetNewClosure()
  $form.Add_Paint($paint)
}

# One event, one handler. "Closed" also forgets the name, so a window can be created again.
#
# A handler is called through the record, not through a captured hashtable: the dispatch block
# below outlives this call, and a reference to a local variable is empty by the time the event
# fires (that is what made the first open fail with "cannot index into a null array").
function Register-AppWindowEvent {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][ValidateSet('Closed', 'Closing', 'Shown', 'Activated', 'Resize', 'KeyDown', 'Deactivate')][string]$Event,
    [Parameter(Mandatory = $true)][scriptblock]$Handler
  )
  $record = Get-AppWindowRecord $Name
  if ($null -eq $record) { throw ('no window named ' + $Name) }
  $form = $record.Form
  $record.Handlers[[string]$Event] = $Handler
  # A window that is opened again keeps its frame: the handler is replaced, the event is not
  # attached twice, or one Deactivate would fire the block once per opening.
  if ($record.Wired.ContainsKey([string]$Event)) { return }
  $record.Wired[[string]$Event] = $true
  $name = [string]$Name
  $eventName = [string]$Event
  $dispatch = {
    param($sender, $e)
    $rec = Get-AppWindowRecord $name
    if ($null -eq $rec) { return }
    $block = $rec.Handlers[$eventName]
    if ($eventName -eq 'Closed') { $script:AppWindows.Remove($name) }
    if ($null -eq $block) { return }
    & $block $e
  }.GetNewClosure()
  switch ($Event) {
    'Closed' { $form.Add_FormClosed($dispatch) }
    'Closing' { $form.Add_FormClosing($dispatch) }
    'Shown' { $form.Add_Shown($dispatch) }
    'Activated' { $form.Add_Activated($dispatch) }
    'Resize' { $form.Add_Resize($dispatch) }
    'KeyDown' { $form.Add_KeyDown($dispatch) }
    'Deactivate' { $form.Add_Deactivate($dispatch) }
  }
}

function Set-AppWindowTitle([string]$Name, [string]$Title) {
  $form = Get-AppWindow $Name
  if ($null -eq $form) { return }
  $form.Text = $Title
}

function Set-AppWindowSize([string]$Name, [int]$Width, [int]$Height) {
  $form = Get-AppWindow $Name
  if ($null -eq $form) { return }
  if ($Width -gt 0) { $form.Width = $Width }
  if ($Height -gt 0) { $form.Height = $Height }
}

function Set-AppWindowPosition([string]$Name, [int]$X, [int]$Y) {
  $form = Get-AppWindow $Name
  if ($null -eq $form) { return }
  $form.Location = New-Object System.Drawing.Point($X, $Y)
}

function Show-AppWindow([string]$Name, [switch]$NoActivate) {
  $form = Get-AppWindow $Name
  if ($null -eq $form) { return $false }
  if ($form.IsDisposed) { return $false }
  $form.Show()
  # a window that takes the foreground itself asks for this: the panel raises itself with
  # SetWindowPos right after Show, and an Activate() here would be a second activation
  if (-not $NoActivate) { $form.Activate() }
  return $true
}

function Hide-AppWindow([string]$Name) {
  $form = Get-AppWindow $Name
  if ($null -eq $form) { return $false }
  if ($form.IsDisposed) { return $false }
  $form.Hide()
  return $true
}

function Close-AppWindow([string]$Name) {
  $form = Get-AppWindow $Name
  if ($null -eq $form) { return }
  if ($form.IsDisposed) { $script:AppWindows.Remove([string]$Name); return }
  $form.Close()
  # Close() disposes a non-modal form; the name goes with it so a later New-AppWindow makes a
  # fresh frame instead of comparing against a dead one
  if ($form.IsDisposed) { $script:AppWindows.Remove([string]$Name) }
}

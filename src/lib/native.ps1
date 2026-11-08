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

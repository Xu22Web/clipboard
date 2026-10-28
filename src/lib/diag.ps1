# lib/diag.ps1 - `clipboard diag` (environment and state report) and `clipboard restore`
# (put a history entry back on the clipboard).

function Invoke-Diag {
  $o = New-Object System.Collections.Generic.List[object]
  function Row([string]$n, $v, [string]$h) { $o.Add([pscustomobject]@{ Check = $n; Result = $v; Hint = $h }) }
  $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
  $svc = @(Get-Service -Name 'cbdhsvc*' -ErrorAction SilentlyContinue)
  $grp = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SVCHOST' -ErrorAction SilentlyContinue).ClipboardSvcGroup
  $cbs = @(Get-ChildItem "$env:SystemRoot\SystemApps" -Filter '*Client.CBS*' -ErrorAction SilentlyContinue)
  Row 'OS' ($cv.ProductName + ' ' + $cv.DisplayVersion + ' build ' + $cv.CurrentBuild) ''
  Row 'PowerShell' $PSVersionTable.PSVersion.ToString() ''
  Row 'Apartment' ([Threading.Thread]::CurrentThread.GetApartmentState()) 'STA required; start via clipboard.cmd'
  # the three fixed value sets: base keys, the theme name, the values a list setting allows
  $cp = @($script:ConfigProblems)
  Row 'clipboard.ini' ($(if ($cp.Count -eq 0) { 'OK' } else { $cp.Count.ToString() + ' value(s) need attention' })) 'shown by clipboard config'
  foreach ($p in $cp) { Row '  ini' $p '' }
  try { Load-Forms; Add-Native; Row 'WinForms/Add-Type' 'OK' '' } catch { Row 'WinForms/Add-Type' ('FAIL: ' + $_.Exception.Message) 'picker off, CLI only' }
  Row 'clip.exe' (Test-Path "$env:SystemRoot\System32\clip.exe") 'not needed: clipboard put / Set-Clipboard'
  Row 'Set-Clipboard' ([bool](Get-Command Set-Clipboard -ErrorAction SilentlyContinue)) ''
  Row 'cbdhsvc instance' ($(if ($svc) { ($svc | ForEach-Object { $_.Name + ':' + $_.Status }) -join ',' } else { 'absent' })) 'absent -> clipboard restore'
  Row 'cbdhsvc template' (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\cbdhsvc') 'absent -> component restore'
  Row 'ClipboardSvcGroup' ($(if ($grp) { $grp -join ',' } else { 'absent' })) ''
  Row 'EnableClipboardHistory' (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Clipboard' -Name EnableClipboardHistory -ErrorAction SilentlyContinue).EnableClipboardHistory 'must be 1'
  Row 'Policy AllowClipboardHistory' (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name AllowClipboardHistory -ErrorAction SilentlyContinue).AllowClipboardHistory '0 disables history'
  Row 'SystemApps Client.CBS' ($(if ($cbs) { $cbs[0].Name } else { 'absent' })) 'Win+V panel host'
  Row 'TextInputHost.exe' ([bool](Get-ChildItem "$env:SystemRoot\SystemApps" -Recurse -Filter 'TextInputHost.exe' -ErrorAction SilentlyContinue)) ''
  Row 'Clipboard data dir' (Test-Path "$env:LOCALAPPDATA\Microsoft\Windows\Clipboard") ''
  if ($script:FormsReady) {
    # Never clobber the clipboard just to prove a point: skip when a resident would record
    # the probe text into history, or when the clipboard holds no text to restore.
    $bak = Get-Text
    $residentUp = $false
    try {
      $hm = New-Object System.Threading.Mutex($false, $MutexName)
      if ($hm.WaitOne(0)) { $hm.ReleaseMutex() } else { $residentUp = $true }
      $hm.Dispose()
    } catch { }
    if ($residentUp) {
      Row 'Clipboard write' 'skipped' 'resident is running - the probe would land in the history'
      Row 'Clipboard roundtrip' 'skipped' ''
    } elseif ([string]::IsNullOrEmpty($bak)) {
      Row 'Clipboard write' 'skipped' 'clipboard holds no text - the probe would clobber it'
      Row 'Clipboard roundtrip' 'skipped' ''
    } else {
      $wr = $false; $rt = $false
      try { $wr = Set-Text 'cb-selftest' } catch { }
      if ($wr) { try { $rt = ((Get-Text) -ceq 'cb-selftest') } catch { } }
      try { [void](Set-Text $bak) } catch { }
      Row 'Clipboard write' $wr 'False -> Win32 clipboard gone'
      Row 'Clipboard roundtrip' $rt ''
    }
  }
  foreach ($x in $o) { Write-Host ('[ ] ' + $x.Check + ' = ' + [string]$x.Result + $(if ($x.Hint) { '   <- ' + $x.Hint } else { '' })) }
  Write-Host ''
  Write-Host 'Next: switches missing -> clipboard restore | files missing -> DISM from same-build ISO | else: clipboard install && clipboard serve'
}

function Invoke-Restore {
  $hk = 'HKCU:\SOFTWARE\Microsoft\Clipboard'
  if (-not (Test-Path $hk)) { New-Item -Path $hk -Force | Out-Null }
  New-ItemProperty -Path $hk -Name 'EnableClipboardHistory' -Value 1 -PropertyType DWord -Force | Out-Null
  Write-Host '[ok] EnableClipboardHistory = 1'
  $pp = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
  if (Test-Path $pp) {
    $v = (Get-ItemProperty $pp -Name AllowClipboardHistory -ErrorAction SilentlyContinue).AllowClipboardHistory
    if ($null -ne $v -and $v -eq 0) {
      try { Remove-ItemProperty $pp -Name AllowClipboardHistory -Force -ErrorAction Stop; Write-Host '[ok] policy removed' }
      catch { Write-Host '[!] policy=0 needs admin to remove' }
    }
  }
  $svc = @(Get-Service -Name 'cbdhsvc*' -ErrorAction SilentlyContinue)
  if ($svc) {
    foreach ($s in $svc) {
      try { Set-Service -Name $s.Name -StartupType Manual -ErrorAction Stop; Start-Service -Name $s.Name -ErrorAction Stop; Write-Host ('[ok] ' + $s.Name + ' started') }
      catch { Write-Host ('[!] ' + $s.Name + ': ' + $_.Exception.Message) }
    }
  } else {
    Write-Host ('[x] no cbdhsvc_* instance; template present=' + (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\cbdhsvc'))
  }
  Write-Host 'Now press Win+V; if nothing happens run: clipboard diag'
}

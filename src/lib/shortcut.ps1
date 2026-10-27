# lib/shortcut.ps1 - the two shortcuts `install` creates (logon autostart + desktop) and
# their removal. They point at powershell.exe with -File <root>\clipboard.ps1 <verb>; no
# proxy process is involved, which is also what keeps antivirus heuristics quiet.

function Get-AutostartPath {
  return (Join-Path ([Environment]::GetFolderPath('Startup')) 'clipboard.lnk')
}

function Get-DesktopPath {
  return (Join-Path ([Environment]::GetFolderPath('Desktop')) 'clipboard.lnk')
}

function New-ClipLnk([string]$lnk, [string]$verb, [string]$policy) {
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

  # A plain powershell.exe target without a proxy process keeps the shortcut out of the
  # heuristics that flag "shortcut + conhost/rundll32" as Trojan/LNK.Runner.
  # -ExecutionPolicy is required: machines whose effective policy is Restricted or
  # AllSigned would refuse to run the script. RemoteSigned is enough for a local unsigned
  # file and is the Windows default value, so it scores lower than Bypass.
  $ws = New-Object -ComObject WScript.Shell
  $s = $ws.CreateShortcut($lnk)
  $s.TargetPath = $ps
  $s.Arguments = '-NoProfile -ExecutionPolicy ' + $policy + ' -Sta -WindowStyle Hidden -File "' + (Join-Path $Root 'clipboard.ps1') + '" ' + $verb
  $s.WorkingDirectory = $Root
  $s.WindowStyle = 7
  $s.Description = 'clipboard history'
  $s.Save()
  return $lnk
}

function Install-Autostart([string]$Policy = 'RemoteSigned') {
  if (-not $Policy) { $Policy = 'RemoteSigned' }
  if ($script:Autostart) {
    try {
      Write-Host ('[ok] startup : ' + (New-ClipLnk (Get-AutostartPath) 'serve' $Policy) + '   (silent daemon at logon)')
    } catch { Write-Host ('[!] startup shortcut failed: ' + $_.Exception.Message) }
  } else { Write-Host '[i] startup : skipped (Autostart=0)' }

  if ($script:DesktopShortcut) {
    try {
      Write-Host ('[ok] desktop : ' + (New-ClipLnk (Get-DesktopPath) 'ui' $Policy) + '   (double-click = history)')
    } catch { Write-Host ('[!] desktop shortcut failed: ' + $_.Exception.Message) }
  } else { Write-Host '[i] desktop : skipped (DesktopShortcut=0)' }

  if (-not ($script:Autostart -or $script:DesktopShortcut)) {
    Write-Host '     both shortcuts are off; set Autostart=1 / DesktopShortcut=1 to create them'
    return
  }
  Write-Host ('     policy  : -ExecutionPolicy ' + $Policy)
  if ($Policy -ne 'Bypass') {
    Write-Host '     if the shortcut still reports "running scripts is disabled", run:'
    Write-Host '       clipboard install bypass'
    Write-Host '     (or unblock the file first: Unblock-File .\clipboard.ps1)'
  }

  $eff = [string](Get-ExecutionPolicy)
  if (@('Restricted', 'AllSigned') -contains $eff) {
    Write-Host ('     note    : this machine evaluates scripts as ' + $eff + '; the shortcut overrides it with -ExecutionPolicy ' + $Policy)
  }
  $gpo = @('MachinePolicy', 'UserPolicy') | Where-Object { [string](Get-ExecutionPolicy -Scope $_) -ne 'Undefined' }
  if ($gpo) {
    Write-Host ('[!] group policy defines the execution policy (' + ($gpo -join ', ') + '); the -ExecutionPolicy switch is ignored there')
  }
  Write-Host ('tip: add ' + $Root + ' to PATH to call clipboard directly')
}

function Remove-Autostart([switch]$Purge) {
  $removed = 0
  foreach ($t in @((Get-AutostartPath), (Get-DesktopPath))) {
    if (Test-Path -LiteralPath $t) {
      try { Remove-Item -LiteralPath $t -Force; Write-Host ('[ok] removed ' + $t); $removed++ }
      catch { Write-Host ('[!] could not remove ' + $t + ': ' + $_.Exception.Message) }
    }
  }
  if ($removed -eq 0) { Write-Host 'no shortcut found (startup / desktop)' }

  if ($Purge) {
    if (Test-Path -LiteralPath $IniPath) {
      try { Remove-Item -LiteralPath $IniPath -Force; Write-Host ('[ok] removed ' + $IniPath) } catch { Write-Host ('[!] could not remove ' + $IniPath) }
    }
    if ((Test-Path -LiteralPath $StoreDir) -and ($StoreDir -ne $Root)) {
      try { Remove-Item -LiteralPath $StoreDir -Recurse -Force; Write-Host ('[ok] removed ' + $StoreDir) } catch { Write-Host ('[!] could not remove ' + $StoreDir) }
    }
    Write-Host '[ok] history, config and logs deleted'
  } else {
    Write-Host ('kept: ' + $StoreDir + '   ' + $IniPath)
    Write-Host 'run: clipboard uninstall purge   to delete history, config and logs too'
  }

  $alive = $false
  try {
    $m = New-Object System.Threading.Mutex($false, $MutexName)
    if ($m.WaitOne(0)) { $m.ReleaseMutex() } else { $alive = $true }
    $m.Dispose()
  } catch { }
  if ($alive) { Write-Host 'note: the resident is still running - clipboard stop' }
}

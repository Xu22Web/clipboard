#Requires -Version 5.1
<#
  template.ps1 - the settings template: `config init` writes it, `config reset` restores it,
  and neither may create or destroy anything on its own

  One part of the self tests: it runs alone, in its own process, with its own sandbox and its
  own clipboard (tests\lib\fake-clip.ps1). tests\run.ps1 starts several of these at once.
#>
[CmdletBinding()]
param(
  [string]$Source = '',
  [string]$ResultFile = '',
  [string]$ProgressFile = '',
  [switch]$Quiet,
  # set by tests\run.ps1 when another part of the same run drives the real clipboard
  [switch]$ClipShared
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'lib\harness.ps1')
$script:Harness.Part = 'template'
Start-TestPart -Source $Source -ClipShared:$ClipShared -Quiet:$Quiet -ProgressFile $ProgressFile
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'


    # ------------------------------------------- settings are never created silently
    $roDir = New-FakeSandbox 'readonly'
    $roIni = Join-Path $roDir 'clipboard.ini'
    $cli = Start-CliRunner $roDir
    function Run([string[]]$cliArgs, [switch]$Cold) { return (Invoke-CliRunner $cli $cliArgs -Cold:$Cold) }
    foreach ($cmd in @(@('status'), @('config'), @('config', 'get', 'Theme'), @('themes'))) {
      [void](Run $cmd)
    }
    [void](Run @('list') -Cold)
    Check 'int' 'no ini created by read-only commands' (-not (Test-Path -LiteralPath $roIni)) $roIni
    $o = Run @('status')
    Check 'int' 'status labels missing ini' ($o -match 'missing, defaults in effect') $o.Trim()
    $o = Run @('config')
    Check 'int' 'config labels defaults' ($o -match '<- default') ''
    $schemaKeys = New-Object System.Collections.Generic.List[string]
    $inBase = $false
    foreach ($ln in @($o -split "`n")) {
      if ($ln -match '^\s+\[base\]') { $inBase = $true; continue }
      if ($ln -match '^\s+\[plugin:') { $inBase = $false; continue }
      if ($inBase -and $ln -match '^\s+([A-Za-z0-9_]+)\s+=') { $schemaKeys.Add($matches[1]) }
    }
    $o = Run @('config', 'init')
    Check 'int' 'config init creates template' ((Test-Path -LiteralPath $roIni) -and ($o -match 'key\(s\) added')) $o.Trim()
    $iniTpl = [IO.File]::ReadAllText($roIni)
    $missing = @($schemaKeys | Where-Object { $iniTpl -notmatch ('(?m)^' + $_ + '=') })
    Check 'int' 'template has every schema key' ($schemaKeys.Count -gt 20 -and $missing.Count -eq 0) (($missing -join ','))
    # the template writes the numbers the schema declares, so the value a user reads in the
    # comment and the value the program falls back to cannot drift apart (the schema variable
    # itself is renamed in a package, so a packaged copy skips this comparison)
    if (($script:IniSchema -is [System.Collections.IDictionary]) -and (@($script:IniSchema.Keys).Count -gt 20)) {
      $tplDrift = @()
      foreach ($k in @($script:IniSchema.Keys)) {
        $spec = $script:IniSchema[$k]
        if (-not $spec.Contains('Ref')) { continue }
        $m = [regex]::Match($iniTpl, '(?m)^' + $k + '=(.*)$')
        if (-not $m.Success) { continue }
        $want = [string]$spec['Default']
        $got = $m.Groups[1].Value.Trim()
        if ($got -ne $want) { $tplDrift += ($k + '=' + $got + '/' + $want) }
      }
      Check 'int' 'the template writes the schema defaults' ($tplDrift.Count -eq 0) (($tplDrift | Select-Object -First 4) -join '; ')
    }
    Check 'int' 'template lists every plugin by name' (($iniTpl -match '(?m)^Plugins=entry-actions,item-marks,retention,transform\r?$') -and (-not ($iniTpl -match 'PluginDisabled'))) ''
    # every plugin key is documented in its own [section], and none is written flat
    Check 'int' 'config init documents every plugin key' (($iniTpl -match '(?m)^\[item-marks\]\r?$') -and ($iniTpl -match '(?m)^MaxPins=50\r?$') -and ($iniTpl -match '(?m)^StickyPins=1\r?$') -and ($iniTpl -match '(?m)^\[entry-actions\]\r?$') -and ($iniTpl -match '(?m)^Reveal=1\r?$') -and (-not ($iniTpl -match '(?m)^item-marks\.')) -and (-not ($iniTpl -match '(?m)^entry-actions\.'))) ''

    # init must never overwrite a value the user set - only reset may throw settings away
    [IO.File]::WriteAllText($roIni, ("Theme=win11-light`r`nRows=7`r`nMaxItems=42`r`n"), $Utf8)
    $o = Run @('config', 'init')
    $iniTpl = [IO.File]::ReadAllText($roIni)
    Check 'int' 'config init keeps existing values' (($iniTpl -match '(?m)^Theme=win11-light\r?$') -and ($iniTpl -match '(?m)^Rows=7\r?$') -and ($iniTpl -match '(?m)^MaxItems=42\r?$')) $o.Trim()
    Check 'int' 'config init still fills the gaps' ($iniTpl -match '(?m)^Hotkey=') ''
    Check 'int' 'config init reports what it did' ($o -match 'key\(s\) added, \d+ unknown key') $o.Trim()
    # a key this version does not know is commented out, not silently kept or dropped
    [IO.File]::WriteAllText($roIni, ("Nonsense=1`r`nRows=7`r`n"), $Utf8)
    $o = Run @('config', 'init')
    $iniTpl = [IO.File]::ReadAllText($roIni)
    Check 'int' 'config init comments out unknown keys' (($iniTpl -match '(?m)^#\s*\[unknown\]\s*Nonsense=1\r?$') -and (-not ($iniTpl -match '(?m)^Nonsense='))) $o.Trim()
    Check 'int' 'the pruned key keeps its value' ($iniTpl -match '\[unknown\]\s*Nonsense=1') ''
    Check 'int' 'pruning does not touch a known value' ($iniTpl -match '(?m)^Rows=7\r?$') ''
    $o = Run @('config', 'reset')
    $iniTpl = [IO.File]::ReadAllText($roIni)
    Check 'int' 'config reset restores the defaults' (($iniTpl -match '(?m)^Theme=win11-dark\r?$') -and ($iniTpl -match '(?m)^Rows=10\r?$') -and ($iniTpl -match '(?m)^Animations=1\r?$')) $o.Trim()


Stop-CliRunner $cli
Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

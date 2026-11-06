#Requires -Version 5.1
<#
  config.ps1 - settings, the template, plugin commands and themes

  One part of the self tests: it runs alone, in its own process, with its own sandbox and its
  own clipboard (tests\lib\fake-clip.ps1). tests\run.ps1 starts several of these at once.
#>
[CmdletBinding()]
param(
  [string]$Source = '',
  [string]$ResultFile = '',
  [switch]$Quiet
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'lib\harness.ps1')
$script:Harness.Part = 'config'
Start-TestPart -Source $Source
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'


    # ------------------------------------------- settings are never created silently
    $roDir = New-FakeSandbox 'readonly'
    $roIni = Join-Path $roDir 'clipboard.ini'
    foreach ($args in @(@('status'), @('config'), @('config', 'get', 'Theme'), @('list'), @('themes'))) {
      [void](Clip $roDir $args)
    }
    Check 'int' 'no ini created by read-only commands' (-not (Test-Path -LiteralPath $roIni)) $roIni
    $o = Clip $roDir @('status')
    Check 'int' 'status labels missing ini' ($o -match 'missing, defaults in effect') $o.Trim()
    $o = Clip $roDir @('config')
    Check 'int' 'config labels defaults' ($o -match '<- default') ''
    $schemaKeys = New-Object System.Collections.Generic.List[string]
    $inBase = $false
    foreach ($ln in @($o -split "`n")) {
      if ($ln -match '^\s+\[base\]') { $inBase = $true; continue }
      if ($ln -match '^\s+\[plugin:') { $inBase = $false; continue }
      if ($inBase -and $ln -match '^\s+([A-Za-z0-9_]+)\s+=') { $schemaKeys.Add($matches[1]) }
    }
    $o = Clip $roDir @('config', 'init')
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
    $o = Clip $roDir @('config', 'init')
    $iniTpl = [IO.File]::ReadAllText($roIni)
    Check 'int' 'config init keeps existing values' (($iniTpl -match '(?m)^Theme=win11-light\r?$') -and ($iniTpl -match '(?m)^Rows=7\r?$') -and ($iniTpl -match '(?m)^MaxItems=42\r?$')) $o.Trim()
    Check 'int' 'config init still fills the gaps' ($iniTpl -match '(?m)^Hotkey=') ''
    Check 'int' 'config init reports what it did' ($o -match 'key\(s\) added, \d+ unknown key') $o.Trim()
    # a key this version does not know is commented out, not silently kept or dropped
    [IO.File]::WriteAllText($roIni, ("Nonsense=1`r`nRows=7`r`n"), $Utf8)
    $o = Clip $roDir @('config', 'init')
    $iniTpl = [IO.File]::ReadAllText($roIni)
    Check 'int' 'config init comments out unknown keys' (($iniTpl -match '(?m)^#\s*\[unknown\]\s*Nonsense=1\r?$') -and (-not ($iniTpl -match '(?m)^Nonsense='))) $o.Trim()
    Check 'int' 'the pruned key keeps its value' ($iniTpl -match '\[unknown\]\s*Nonsense=1') ''
    Check 'int' 'pruning does not touch a known value' ($iniTpl -match '(?m)^Rows=7\r?$') ''
    $o = Clip $roDir @('config', 'reset')
    $iniTpl = [IO.File]::ReadAllText($roIni)
    Check 'int' 'config reset restores the defaults' (($iniTpl -match '(?m)^Theme=win11-dark\r?$') -and ($iniTpl -match '(?m)^Rows=10\r?$') -and ($iniTpl -match '(?m)^Animations=1\r?$')) $o.Trim()

    # --------------------------------------- plugin commands (loaded by default)
    [void](Clip $intDir @('clear', '-All'))
    [void](Clip $intDir @('put', 'https://example.com/hello'))
    Remove-Item -LiteralPath $cfg2 -Force -ErrorAction SilentlyContinue
    $o = Clip $intDir @('kind', '1')
    Check 'int' 'kind is available by default' ($o -match 'link') $o.Trim()
    $o = Clip $intDir @('open', '99')
    Check 'int' 'open reports a bad index' ($o -match 'index out of range') $o.Trim()
    $o = Clip $intDir @('config')
    Check 'int' 'config lists every loaded plugin' (($o -match 'plugins     : loaded') -and ($o -match 'item-marks') -and ($o -match 'entry-actions') -and ($o -match 'retention') -and ($o -match 'transform')) $o.Trim()
    $o = Clip $intDir @('status')
    Check 'int' 'status lists every loaded plugin' ($o -match 'plugins     : entry-actions, item-marks, retention, transform') $o.Trim()
    $o = Clip $intDir @('help')
    Check 'int' 'help has the plugin groups by default' (($o -match '\[plugin: item-marks\]') -and ($o -match '(?m)^    pin\s')) ''
    Check 'int' 'help lists the plugin panel keys' ($o -match 'Ctrl\+S\s+star.*\(item-marks\)') ''

    # a shorter list narrows it: a plugin that is not named never runs
    [IO.File]::WriteAllLines($cfg2, @('Plugins=entry-actions'), $Utf8)
    $o = Clip $intDir @('star', '1')
    Check 'int' 'a shorter list turns the other plugins off' ($o -match 'unknown command') $o.Trim()
    $o = Clip $intDir @('open', '99')
    Check 'int' 'Plugins= enables the plugin' ($o -match 'index out of range') $o.Trim()
    $o = Clip $intDir @('config')
    Check 'int' 'config lists the loaded plugin' ($o -match 'plugins     : loaded entry-actions') $o.Trim()
    $o = Clip $intDir @('status')
    Check 'int' 'status lists the loaded plugin' ($o -match 'plugins     : entry-actions') $o.Trim()
    $o = Clip $intDir @('help')
    Check 'int' 'help groups base commands' (($o -match '\[history\]') -and ($o -match '(?m)^    del N\s')) ''
    Check 'int' 'help groups plugin commands' (($o -match '\[plugin: entry-actions\]') -and ($o -match '(?m)^    open\s')) ''
    Check 'int' 'help lists plugin panel keys' ($o -match 'Ctrl\+O\s+open link or path\s+\(entry-actions\)') ''

    $o = Clip $intDir @('config', 'get', 'entry-actions.Browser')
    Check 'int' 'plugin setting is visible' ($o -match 'entry-actions\.Browser') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'entry-actions.Reveal', '0')
    $iniPlugin = [IO.File]::ReadAllText($cfg2)
    # a plugin key lands in its own section, which is created when the file has none yet
    Check 'int' 'plugin setting is writable' (($o -match 'entry-actions\.Reveal') -and ($iniPlugin -match '(?m)^\[entry-actions\]\r?$') -and ($iniPlugin -match '(?m)^Reveal=0\r?$')) $o.Trim()
    $o = Clip $intDir @('config', 'set', 'entry-actions.Reveal', 'maybe')
    Check 'int' 'plugin setting rejects bad value' ($o -match '0 or 1') $o.Trim()
    $o = Clip $intDir @('config', 'init')
    $tplText = [IO.File]::ReadAllText($cfg2)
    # the missing plugin key is added inside the existing section, the one the user set to 0
    # keeps its value, and the section header is not duplicated
    Check 'int' 'config init fills plugin settings only' (($tplText -match '(?m)^Browser=\r?$') -and ($tplText -match '(?m)^Reveal=0\r?$') -and (([regex]::Matches($tplText, '(?m)^\[entry-actions\]\r?$')).Count -eq 1)) ''
    [IO.File]::WriteAllLines($cfg2, @('Plugins=entry-actions'), $Utf8)

    [IO.File]::WriteAllLines($cfg2, @('Plugins=nosuch'), $Utf8)
    $o = Clip $intDir @('status')
    Check 'int' 'unknown plugin name is reported' ($o -match 'not found: nosuch') $o.Trim()
    $o = Clip $intDir @('help')
    Check 'int' 'help reports unknown plugin' ($o -match 'plugin not found: nosuch') ''
    $o = Clip $intDir @('list')
    Check 'int' 'data commands stay clean' (-not ($o -match 'plugin')) $o.Trim()
    $o = Clip $intDir @('list')
    Check 'int' 'base commands survive a bad plugin name' ($o -match 'example\.com/hello') $o.Trim()
    $o = Clip $intDir @('config', 'get', 'Plugins')
    Check 'int' 'config get Plugins' ($o -match 'Plugins = nosuch') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Plugins', 'entry-actions')
    Check 'int' 'config set accepts a plugin list' ($o -match 'entry-actions') $o.Trim()


Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

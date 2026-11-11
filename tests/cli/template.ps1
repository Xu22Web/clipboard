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


# settings are never created silently: the sandbox has no ini at all
$roDir = New-FakeSandbox 'readonly'
$roIni = Join-Path $roDir 'clipboard.ini'
$cli = Start-CliRunner $roDir
function Run([string[]]$cliArgs, [switch]$Cold) { return (Invoke-CliRunner $cli $cliArgs -Cold:$Cold) }

Describe 'int' {
  AfterAll { Stop-CliRunner $cli }

  Describe 'read-only commands' {
    BeforeAll {
      foreach ($cmd in @(@('status'), @('config'), @('config', 'get', 'Theme'), @('themes'))) {
        [void](Run $cmd)
      }
      [void](Run @('list') -Cold)
    }
    It 'no ini created by read-only commands' {
      Expect (-not (Test-Path -LiteralPath $roIni)) $roIni
    }
    It 'status labels missing ini' {
      $o = Run @('status')
      Expect-Match $o 'missing, defaults in effect' $o.Trim()
    }
    It 'config labels defaults' {
      $o = Run @('config')
      Expect-Match $o '<- default' 'every key of a missing ini is a default'
    }
  }

  Describe 'config init' {
    BeforeAll {
      # the keys the config view prints under [base], collected once for the template check
      $script:schemaKeys = New-Object System.Collections.Generic.List[string]
      $o = Run @('config')
      $inBase = $false
      foreach ($ln in @($o -split "`n")) {
        if ($ln -match '^\s+\[base\]') { $inBase = $true; continue }
        if ($ln -match '^\s+\[plugin:') { $inBase = $false; continue }
        if ($inBase -and $ln -match '^\s+([A-Za-z0-9_]+)\s+=') { $script:schemaKeys.Add($matches[1]) }
      }
    }
    It 'config init creates template' {
      $o = Run @('config', 'init')
      Expect ((Test-Path -LiteralPath $roIni) -and ($o -match 'key\(s\) added')) $o.Trim()
    }
    It 'template has every schema key' {
      $iniTpl = [IO.File]::ReadAllText($roIni)
      $missing = @($script:schemaKeys | Where-Object { $iniTpl -notmatch ('(?m)^' + $_ + '=') })
      Expect ($script:schemaKeys.Count -gt 20 -and $missing.Count -eq 0) ($missing -join ',')
    }
    It 'template lists every plugin by name' {
      $iniTpl = [IO.File]::ReadAllText($roIni)
      Expect (($iniTpl -match '(?m)^Plugins=entry-actions,item-marks,retention,transform\r?$') -and (-not ($iniTpl -match 'PluginDisabled'))) 'the template should name every plugin once'
    }
    # every plugin key is documented in its own [section], and none is written flat
    It 'config init documents every plugin key' {
      $iniTpl = [IO.File]::ReadAllText($roIni)
      Expect (($iniTpl -match '(?m)^\[item-marks\]\r?$') -and ($iniTpl -match '(?m)^MaxPins=50\r?$') -and ($iniTpl -match '(?m)^StickyPins=1\r?$') -and ($iniTpl -match '(?m)^\[entry-actions\]\r?$') -and ($iniTpl -match '(?m)^Reveal=1\r?$') -and (-not ($iniTpl -match '(?m)^item-marks\.')) -and (-not ($iniTpl -match '(?m)^entry-actions\.'))) 'plugin keys belong in their own section'
    }
  }

  # the template writes the numbers the schema declares, so the value a user reads in the
  # comment and the value the program falls back to cannot drift apart (the schema variable
  # itself is renamed in a package, so a packaged copy skips this comparison)
  if (($script:IniSchema -is [System.Collections.IDictionary]) -and (@($script:IniSchema.Keys).Count -gt 20)) {
    Describe 'template defaults' {
      It 'the template writes the schema defaults' {
        $iniTpl = [IO.File]::ReadAllText($roIni)
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
        Expect ($tplDrift.Count -eq 0) (($tplDrift | Select-Object -First 4) -join '; ')
      }
    }
  }

  # init must never overwrite a value the user set - only reset may throw settings away
  Describe 'config init keeps what the user set' {
    BeforeAll { [IO.File]::WriteAllText($roIni, ("Theme=win11-light`r`nRows=7`r`nMaxItems=42`r`n"), $Utf8) }
    It 'config init keeps existing values' {
      $o = Run @('config', 'init')
      $iniTpl = [IO.File]::ReadAllText($roIni)
      Expect (($iniTpl -match '(?m)^Theme=win11-light\r?$') -and ($iniTpl -match '(?m)^Rows=7\r?$') -and ($iniTpl -match '(?m)^MaxItems=42\r?$')) $o.Trim()
    }
    It 'config init still fills the gaps' {
      $iniTpl = [IO.File]::ReadAllText($roIni)
      Expect-Match $iniTpl '(?m)^Hotkey=' 'a missing key should be filled in'
    }
    It 'config init reports what it did' {
      $o = Run @('config', 'init')
      Expect-Match $o 'key\(s\) added, \d+ unknown key' $o.Trim()
    }
  }

  # a key this version does not know is commented out, not silently kept or dropped
  Describe 'unknown keys' {
    BeforeAll { [IO.File]::WriteAllText($roIni, ("Nonsense=1`r`nRows=7`r`n"), $Utf8) }
    It 'config init comments out unknown keys' {
      $o = Run @('config', 'init')
      $iniTpl = [IO.File]::ReadAllText($roIni)
      Expect (($iniTpl -match '(?m)^#\s*\[unknown\]\s*Nonsense=1\r?$') -and (-not ($iniTpl -match '(?m)^Nonsense='))) $o.Trim()
    }
    It 'the pruned key keeps its value' {
      $iniTpl = [IO.File]::ReadAllText($roIni)
      Expect-Match $iniTpl '\[unknown\]\s*Nonsense=1' 'the pruned line should keep its value'
    }
    It 'pruning does not touch a known value' {
      $iniTpl = [IO.File]::ReadAllText($roIni)
      Expect-Match $iniTpl '(?m)^Rows=7\r?$' 'a known value must survive the prune'
    }
  }

  # a filled-in key belongs where the template puts it: appending at the end of the file would
  # drop a base key into whichever [section] happens to be last
  Describe 'new keys land in their own block' {
    BeforeAll { [IO.File]::WriteAllText($roIni, ("Rows=7`r`n`r`n[transform]`r`nMode=upper`r`n"), $Utf8) }
    It 'a key without a section is written before the first section' {
      $o = Run @('config', 'init')
      $iniTpl = [IO.File]::ReadAllText($roIni)
      $firstSection = $iniTpl.IndexOf('[transform]')
      $added = $iniTpl.IndexOf('Hotkey=')
      Expect (($firstSection -gt 0) -and ($added -ge 0) -and ($added -lt $firstSection)) ('at=' + [string]$added + ' section=' + [string]$firstSection)
    }
    It 'the added key is not read back as a plugin key' {
      $o = Run @('config')
      Expect (-not ($o -match 'unknown key: transform\.Hotkey')) $o.Trim()
    }
  }

  # `config init` rewrites the file from the template, so the result is the same file every
  # time: one comment per key, no blank line inside a block, no key twice in one section
  Describe 'config init keeps the file regular' {
    BeforeAll {
      # a file an older build left behind: a stray blank line inside a block, a key written
      # twice, and a comment whose key is gone
      [IO.File]::WriteAllText($roIni, ("Rows=7`r`n`r`n`r`nMaxItems=42`r`nMaxItems=44`r`n# a comment left behind`r`n`r`n[transform]`r`nMode=upper`r`n"), $Utf8)
    }
    It 'config init writes the template shape back' {
      $o = Run @('config', 'init')
      $txt = [IO.File]::ReadAllText($roIni)
      $lines = @($txt -split "`r?`n")
      $blanks = 0
      $run = 0
      $dups = @()
      $seen = @{}
      $section = ''
      foreach ($ln in $lines) {
        $t = $ln.Trim()
        if ($t -eq '') { $run++; if ($run -gt 1) { $blanks++ }; continue }
        $run = 0
        if ($t -match '^\[(.+)\]$') { $section = $Matches[1]; continue }
        if ($t -notmatch '^([A-Za-z0-9_.-]+)\s*=') { continue }
        $full = $Matches[1]
        if ($section) { $full = $section + '.' + $full }
        if ($seen.ContainsKey($full)) { $dups += $full } else { $seen[$full] = $true }
      }
      Expect (($blanks -eq 0) -and ($dups.Count -eq 0)) ('blank runs=' + $blanks + ' duplicates=' + ($dups -join ','))
      Expect (-not ($txt -match 'a comment left behind')) 'a comment without its key should be gone'
    }
    It 'the values of the old file survive the rewrite' {
      $txt = [IO.File]::ReadAllText($roIni)
      Expect (($txt -match '(?m)^Rows=7\r?$') -and ($txt -match '(?m)^MaxItems=44\r?$') -and ($txt -match '(?m)^Mode=upper\r?$')) 'the last value wins and nothing is reset'
    }
    It 'a second run changes nothing' {
      $first = [IO.File]::ReadAllText($roIni)
      $o = Run @('config', 'init')
      $second = [IO.File]::ReadAllText($roIni)
      Expect (($first -ceq $second) -and ($o -match '0 key\(s\) added')) $o.Trim()
    }
  }

  Describe 'config reset' {
    It 'config reset restores the defaults' {
      $o = Run @('config', 'reset')
      $iniTpl = [IO.File]::ReadAllText($roIni)
      Expect (($iniTpl -match '(?m)^Theme=win11-dark\r?$') -and ($iniTpl -match '(?m)^Rows=10\r?$') -and ($iniTpl -match '(?m)^Animations=1\r?$')) $o.Trim()
    }
  }
}

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

#Requires -Version 5.1
<#
  Self tests for clipboard.ps1.

  No external framework: Pester 3.4 is the only one shipped with Windows and its
  syntax is legacy, while this project deliberately stays dependency free.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -Sta -File tests\run-tests.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -Sta -File tests\run-tests.ps1 -Unit
    powershell -NoProfile -ExecutionPolicy Bypass -Sta -File tests\run-tests.ps1 -Integration
    powershell -NoProfile -ExecutionPolicy Bypass -Sta -File tests\run-tests.ps1 -E2E

  -Sta is required: clipboard.ps1 uses System.Windows.Forms.
  Every group runs inside a sandbox copy of the tool under %TEMP%, so the store and
  clipboard.ini in the repo are never touched. The real clipboard is saved and
  restored around the run. Exit code is 1 when any check fails.
#>
[CmdletBinding()]
param(
  [switch]$Unit,
  [switch]$Integration,
  [switch]$E2E
)

$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$clipPs1 = Join-Path $repoRoot 'clipboard.ps1'
if (-not (Test-Path -LiteralPath $clipPs1)) { Write-Error ('cannot find ' + $clipPs1); exit 2 }

if (-not ($Unit -or $Integration -or $E2E)) { $Unit = $true; $Integration = $true; $E2E = $true }

$script:results = New-Object System.Collections.Generic.List[object]

function Check([string]$group, [string]$name, [bool]$ok, [string]$detail) {
  $script:results.Add([pscustomobject]@{
      Group  = $group
      Test   = $name
      Result = $(if ($ok) { 'PASS' } else { 'FAIL' })
      Detail = $detail
    })
}

function Skip([string]$group, [string]$name, [string]$why) {
  $script:results.Add([pscustomobject]@{ Group = $group; Test = $name; Result = 'SKIP'; Detail = $why })
}

# A sandbox is a throw-away copy of the tool (script + lib + plugins + themes): the
# settings file sits next to the script, so DataDir= and the store stay inside the sandbox.
function New-Sandbox([string]$name) {
  $dir = Join-Path $tmpRoot $name
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Copy-Item -LiteralPath $clipPs1 -Destination $dir -Force
  foreach ($sub in @('lib', 'plugins', 'themes')) {
    $src = Join-Path $repoRoot $sub
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dir -Recurse -Force }
  }
  return $dir
}

# run one CLI call in a child process against a sandbox
function Clip([string]$sandbox, [string[]]$cliArgs) {
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', (Join-Path $sandbox 'clipboard.ps1')) + $cliArgs
  return (& powershell @a 2>&1 | Out-String)
}

function Test-MutexFree([string]$name) {
  try {
    $m = New-Object System.Threading.Mutex($false, $name)
    $free = $m.WaitOne(0)
    if ($free) { $m.ReleaseMutex() }
    $m.Dispose()
    return $free
  } catch { return $true }
}

# the resident polls the clipboard, so a write can lose the race - retry a few times
function Set-Clip([string]$value) {
  for ($i = 0; $i -lt 6; $i++) {
    try { Set-Clipboard -Value $value -ErrorAction Stop; return $true } catch { Start-Sleep -Milliseconds 150 }
  }
  return $false
}

$tmpRoot = Join-Path $env:TEMP ('clipboard-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$unitDir = New-Sandbox 'unit'
$intDir = New-Sandbox 'integration'
$e2eDir = New-Sandbox 'e2e'

$clipBak = ''
try { $clipBak = (Get-Clipboard -Raw -ErrorAction Stop) } catch { }

# A running resident records every clipboard write the tests make, so pause it for the
# duration of the run and resume it afterwards - the real history stays untouched.
$wePaused = $false
if (-not (Test-MutexFree 'Local\clipboard.daemon')) {
  $st = & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $clipPs1 status 2>&1 | Out-String
  if ($st -match 'capture     : paused') {
    Write-Output 'resident is already paused - leaving it paused'
  }
  else {
    [void](& powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $clipPs1 pause 2>&1)
    $wePaused = $true
    Write-Output 'resident paused for the run (resumed at the end)'
  }
}

try {

  # ---------------------------------------------------------------- unit tests
  if ($Unit) {
    . (Join-Path $unitDir 'clipboard.ps1') -Library
    $ErrorActionPreference = 'Continue'   # the dot-sourced script sets Stop

    # the store has a single API (records); tests only care about the payloads
    function Payloads {
      $o = New-Object System.Collections.Generic.List[string]
      foreach ($r in @(Get-Records)) { $o.Add($r.Payload) }
      return $o.ToArray()
    }

    $h = Parse-Hotkey 'Ctrl+Alt+V'
    Check 'unit' 'Parse-Hotkey mods ctrl+alt' ($h.Mods -eq 3) ('mods=0x' + $h.Mods.ToString('X2'))
    Check 'unit' 'Parse-Hotkey vk V' ($h.Vk -eq 0x56) ('vk=0x' + $h.Vk.ToString('X2'))

    $h = Parse-Hotkey 'Win+Shift+V'
    Check 'unit' 'Parse-Hotkey mods win+shift' ($h.Mods -eq 0x0C) ('mods=0x' + $h.Mods.ToString('X2'))

    $h = Parse-Hotkey 'ctrl + alt + f9'
    Check 'unit' 'Parse-Hotkey F9 case/space' ($h.Vk -eq 0x78 -and $h.Mods -eq 3) ('vk=0x' + $h.Vk.ToString('X2'))

    $h = Parse-Hotkey 'Ctrl+Alt+`'
    Check 'unit' 'Parse-Hotkey backtick' ($h.Vk -eq 0x60) ('vk=0x' + $h.Vk.ToString('X2'))

    Check 'unit' 'Parse-Hotkey unknown key' ((Parse-Hotkey 'Ctrl+Nope').Vk -eq 0) ''

    Check 'unit' 'Format-Item newlines' ((Format-Item "a`r`nb" 40) -eq 'a <NL> b') ''

    $files = ([string][char]1) + "C:\x\a.txt`nD:\y\b.txt"
    Check 'unit' 'Format-Item file drop' ((Format-Item $files 80) -eq '[files] a.txt, b.txt') (Format-Item $files 80)

    $cut = Format-Item ('x' * 50) 10
    Check 'unit' 'Format-Item truncates' ($cut.Length -eq 13 -and $cut.EndsWith('...')) $cut

    # config file
    $cfg = Join-Path $unitDir 'clipboard.ini'
    if (Test-Path -LiteralPath $cfg) { Remove-Item -LiteralPath $cfg -Force }
    $written = Write-IniTemplate
    Check 'unit' 'Write-IniTemplate creates file' (Test-Path -LiteralPath $written) $written
    $template = [IO.File]::ReadAllText($written)
    Check 'unit' 'template has defaults' (($template -match 'Hotkey=Ctrl\+Alt\+V') -and ($template -match 'MaxItems=300')) ''

    $lines = @('# hash comment', '; semi comment', '[section]', 'Hotkey=Ctrl+Shift+F9', 'Theme = light ', 'Quoted="a b"', 'Garbage', 'MaxItems=7')
    [IO.File]::WriteAllLines($cfg, $lines, $Utf8)
    $kv = Read-Ini
    Check 'unit' 'Read-Ini skips comments' (-not $kv.ContainsKey('# hash comment')) ''
    Check 'unit' 'Read-Ini trims value' ($kv['Theme'] -eq 'light') ('Theme=' + $kv['Theme'])
    Check 'unit' 'Read-Ini strips quotes' ($kv['Quoted'] -eq 'a b') ('Quoted=' + $kv['Quoted'])
    Check 'unit' 'Read-Ini skips malformed' (-not $kv.ContainsKey('Garbage')) ''
    Check 'unit' 'Read-Ini keeps number' ($kv['MaxItems'] -eq '7') ('MaxItems=' + $kv['MaxItems'])
    Check 'unit' 'Read-Ini reads hotkey' ($kv['Hotkey'] -eq 'Ctrl+Shift+F9') ('Hotkey=' + $kv['Hotkey'])

    # Apply-Config must pick up the paste timings and the fallback list
    [IO.File]::WriteAllLines($cfg, @('ModReleaseTimeout=1500', 'PasteSettle=250', 'HotkeyFallbacks=Alt+Q;Alt+W'), $Utf8)
    Apply-Config
    Check 'unit' 'Apply-Config ModReleaseTimeout' ($script:ModReleaseTimeout -eq 1500) ('value=' + $script:ModReleaseTimeout)
    Check 'unit' 'Apply-Config PasteSettle' ($script:PasteSettle -eq 250) ('value=' + $script:PasteSettle)
    Check 'unit' 'Apply-Config HotkeyFallbacks' ($script:HotkeyFallbacks -eq 'Alt+Q;Alt+W') ('value=' + $script:HotkeyFallbacks)

    # store (records only - there is no payload-only view any more)
    Save-Records @()
    Check 'unit' 'store empty at start' (@(Get-Records).Count -eq 0) ''

    Add-Item 'one'; Add-Item 'two'; Add-Item 'three'
    $items = Payloads
    Check 'unit' 'store newest first' ($items.Count -eq 3 -and $items[0] -eq 'three') ($items -join '|')

    Add-Item 'one'
    $items = Payloads
    Check 'unit' 'store dedupe moves to top' ($items.Count -eq 3 -and $items[0] -eq 'one') ($items -join '|')

    Add-Item 'one'
    $items = Payloads
    Check 'unit' 'store dedupe keeps count' ($items.Count -eq 3) ($items -join '|')

    $savedMax = $MaxItems
    $MaxItems = 2
    Add-Item 'four'
    $items = Payloads
    Check 'unit' 'store trims to MaxItems' ($items.Count -eq 2) ($items -join '|')
    $MaxItems = $savedMax

    $savedBytes = $MaxBytes
    $MaxBytes = 3
    $before = @(Get-Records).Count
    Add-Item 'toolong'
    Check 'unit' 'store skips oversize entry' (@(Get-Records).Count -eq $before) ''
    $MaxBytes = $savedBytes

    $before = @(Get-Records).Count
    $script:ExcludePattern = '^SECRET'
    Add-Item 'SECRET token'
    Check 'unit' 'store honours exclude pattern' (@(Get-Records).Count -eq $before) ''
    $script:ExcludePattern = ''

    $before = @(Get-Records).Count
    Add-Item '   '
    Check 'unit' 'store ignores blank input' (@(Get-Records).Count -eq $before) ''

    # ------------------------------------------------------------- record store
    Check 'unit' 'v2 tag written' (([IO.File]::ReadAllText($StoreFile)).StartsWith($V2TAG)) ''

    # ------------------------------------------- generic marks (base owns no mark meaning)
    $markPlugin = @{
      Name       = 'marks'
      Marks      = [ordered]@{
        p = @{ Set = 'pin'; Unset = 'unpin'; Word = 'pinned'; Hint = 'Ctrl+P'; Protected = $false }
        s = @{ Set = 'star'; Unset = 'unstar'; Word = 'starred'; Hint = 'Ctrl+S'; Protected = $true }
      }
      SortMark   = 'p'
      ClearKeeps = @('p')
    }
    $script:Plugins = @($markPlugin)
    Check 'unit' 'mark names come from the declaration' ((@(Get-MarkNames) -join ',') -eq 'p,s') (@(Get-MarkNames) -join ',')
    Check 'unit' 'mark word lookup' ((Get-MarkWord 's') -eq 'starred') (Get-MarkWord 's')
    Check 'unit' 'undeclared mark falls back to its character' ((Get-MarkWord 'z') -eq 'z') (Get-MarkWord 'z')
    Check 'unit' 'protected marks come from the declaration' ((@(Get-ProtectedMarks) -join ',') -eq 's') (@(Get-ProtectedMarks) -join ',')
    Check 'unit' 'sort mark comes from the declaration' ((Get-SortMark) -eq 'p') (Get-SortMark)
    Check 'unit' 'clear keeps the declared marks' ((@(Get-ClearKeepMarks) -join ',') -eq 'p,s') (@(Get-ClearKeepMarks) -join ',')
    Check 'unit' 'clear -All keeps only protected marks' ((@(Get-ClearKeepMarks -All) -join ',') -eq 's') (@(Get-ClearKeepMarks -All) -join ',')

    $now = Get-Epoch
    $recList = New-Object System.Collections.Generic.List[object]
    $recList.Add((New-Record 'alpha' ($now - 60) 'p'))
    $recList.Add((New-Record 'beta' ($now - 30) ''))
    Save-Records $recList.ToArray()
    $r2 = @(Get-Records)
    Check 'unit' 'records roundtrip payloads' (((Payloads) -join '|') -eq 'alpha|beta') ((Payloads) -join '|')
    Check 'unit' 'record roundtrip time' (($r2[0].Time -eq ($now - 60)) -and ($r2[1].Time -eq ($now - 30))) ($r2[0].Time -as [string])
    Check 'unit' 'record roundtrip marks' ((Test-Mark $r2[0] 'p') -and (-not (Test-Mark $r2[1] 'p'))) ''
    Check 'unit' 'record keeps a mark the base never heard of' ((Test-Mark (New-Record 'x' 0 'zq') 'z') -and (Test-Mark (New-Record 'x' 0 'zq') 'q')) ''

    # no legacy format support: a store without the CBHIST2 tag is ignored
    [IO.File]::WriteAllText($StoreFile, ('alpha' + $RS + 'beta'), $Utf8)
    Check 'unit' 'unknown store format ignored' (@(Get-Records).Count -eq 0) ('count=' + @(Get-Records).Count)
    Check 'unit' 'unknown format is not backed up' (-not (Test-Path -LiteralPath (Join-Path $unitDir 'history.v1.bak'))) ''

    Save-Records $recList.ToArray()
    Add-Item 'alpha'
    $r3 = @(Get-Records)
    Check 'unit' 'sorted mark stays on top after add' ($r3[0].Payload -eq 'alpha') $r3[0].Payload
    [void](Set-Mark 'beta' 'p' $true)
    Add-Item 'beta'
    $stillMarked = $false
    foreach ($r in @(Get-Records)) { if ($r.Payload -ceq 'beta' -and (Test-Mark $r 'p')) { $stillMarked = $true } }
    Check 'unit' 'dedupe keeps the marks' $stillMarked ''

    $savedItems = $MaxItems
    $MaxItems = 2
    Save-Records @()
    Add-Item 'p1'
    [void](Set-Mark 'p1' 's' $true)
    foreach ($t in @('n1', 'n2', 'n3', 'n4')) { Add-Item $t }
    $r5 = @(Get-Records)
    $hasMark = $false
    foreach ($r in $r5) { if ($r.Payload -ceq 'p1' -and (Test-Mark $r 's')) { $hasMark = $true } }
    Check 'unit' 'trim keeps a protected mark' ($r5.Count -eq 2 -and $hasMark) (($r5.Count -as [string]) + ' ' + ((Payloads) -join '|'))
    $MaxItems = $savedItems

    # a plugin that limits its own mark needs one pass over the whole list
    Save-Records @()
    Add-Item 'a1'
    Add-Item 'a2'
    [void](Set-Mark 'a1' 'p' $true)
    [void](Set-Mark 'a2' 'p' $true)
    $cleared = Update-Records {
      param($list)
      $n = 0
      foreach ($r in $list) { if (Test-Mark $r 'p') { [void](Set-RecordMark $r 'p' $false); $n++ } }
      return $n
    }
    Check 'unit' 'Update-Records returns the body result' ($cleared -eq 2) ($cleared -as [string])
    Check 'unit' 'Update-Records saved in one write' (-not (@(Get-Records) | Where-Object { Test-Mark $_ 'p' })) ''

    Save-Records @()
    Add-Item 'c1'
    Add-Item 'c2'
    [void](Set-Mark 'c1' 'p' $true)
    Clear-Store (Get-ClearKeepMarks)
    $afterKeep = @(Get-Records)
    Check 'unit' 'clear keeps marked rows' ($afterKeep.Count -eq 1 -and $afterKeep[0].Payload -eq 'c1') ((Payloads) -join '|')
    Clear-Store (Get-ClearKeepMarks -All)
    Check 'unit' 'clear -All drops an unprotected mark' (@(Get-Records).Count -eq 0) ''
    $script:Plugins = @()

    Save-Records @()
    Add-Item 'u1'
    Add-Item 'u2'
    Add-Item 'u3'
    $victim = @(Get-Records)[1]
    [void](Remove-Record $victim.Payload)
    Check 'unit' 'Remove-Record drops one entry' (((Payloads) -join '|') -eq 'u3|u1') ((Payloads) -join '|')
    Restore-Record $victim 1
    Check 'unit' 'Restore-Record puts it back' (((Payloads) -join '|') -eq 'u3|u2|u1') ((Payloads) -join '|')
    Save-Records @()

    # ------------------------------------------------------------ panel helpers
    Check 'unit' 'Get-VisibleRowCount 10 rows' ((Get-VisibleRowCount 340 34) -eq 10) ((Get-VisibleRowCount 340 34) -as [string])
    Check 'unit' 'Get-VisibleRowCount floors' ((Get-VisibleRowCount 100 34) -eq 2) ''
    Check 'unit' 'Get-VisibleRowCount never 0' ((Get-VisibleRowCount 10 40) -eq 1) ''
    Check 'unit' 'QuickKey maps from TopIndex' ((Get-QuickKeyIndex 0 5 20 10) -eq 5) ''
    Check 'unit' 'QuickKey follows scroll' ((Get-QuickKeyIndex 3 7 20 10) -eq 10) ''
    Check 'unit' 'QuickKey past the end' ((Get-QuickKeyIndex 9 15 20 10) -eq -1) ''
    Check 'unit' 'QuickKey beyond visible rows' ((Get-QuickKeyIndex 9 0 20 8) -eq -1) ''
    Check 'unit' 'QuickKey only 0-9' ((Get-QuickKeyIndex 10 0 20 10) -eq -1) ''
    Check 'unit' 'QuickKey label: nine rows read 1-9' (((0..8 | ForEach-Object { Get-QuickKeyLabel $_ }) -join '') -eq '123456789') ((0..8 | ForEach-Object { Get-QuickKeyLabel $_ }) -join '')
    Check 'unit' 'QuickKey label: tenth row reads 0' ((Get-QuickKeyLabel 9) -eq '0') (Get-QuickKeyLabel 9)
    Check 'unit' 'QuickKey label: out of range is empty' ((Get-QuickKeyLabel 10) -eq '') ''
    Check 'unit' 'QuickKey digit maps to the keypad row' (((0..9 | ForEach-Object { Get-QuickKeyOffset $_ }) -join ',') -eq '9,0,1,2,3,4,5,6,7,8') ((0..9 | ForEach-Object { Get-QuickKeyOffset $_ }) -join ',')
    Check 'unit' 'QuickKey digit out of range' ((Get-QuickKeyOffset 12) -eq -1) ''
    Check 'unit' 'QuickKey digit 0 picks the tenth row' ((Get-QuickKeyIndex (Get-QuickKeyOffset 0) 0 20 10) -eq 9) ''
    Check 'unit' 'QuickKey digit 1 picks the first row' ((Get-QuickKeyIndex (Get-QuickKeyOffset 1) 4 20 10) -eq 4) ''

    $areas = @(
      [pscustomobject]@{ Left = 0; Top = 0; Width = 1920; Height = 1080 },
      [pscustomobject]@{ Left = 1920; Top = 0; Width = 1920; Height = 1080 }
    )
    $fbArea = [pscustomobject]@{ Left = 0; Top = 0; Width = 1920; Height = 1080 }
    $b = Get-PickerBounds 660 430 '100' '200' $areas $fbArea
    Check 'unit' 'Get-PickerBounds uses saved position' (($b.Left -eq 100) -and ($b.Top -eq 200) -and (-not $b.Fitted)) (($b.Left -as [string]) + ',' + ($b.Top -as [string]))
    $b = Get-PickerBounds 660 430 '5000' '9000' $areas $fbArea
    Check 'unit' 'Get-PickerBounds off-screen falls back' ($b.Fitted -and ($b.Left -eq 630) -and ($b.Top -eq 217)) (($b.Left -as [string]) + ',' + ($b.Top -as [string]))
    $b = Get-PickerBounds 660 430 '1500' '100' $areas $fbArea
    Check 'unit' 'Get-PickerBounds clamps into the screen' ($b.Left -eq 1260) ($b.Left -as [string])
    $b = Get-PickerBounds 660 430 '' '' $areas $fbArea
    Check 'unit' 'Get-PickerBounds empty = centred' $b.Fitted ''

    $marks = Get-HitMarks 'Hello World' @('wor')
    Check 'unit' 'Get-HitMarks case-insensitive' ($marks[6] -and $marks[7] -and $marks[8] -and (-not $marks[0])) ''

    Check 'unit' 'Get-ItemLabel collapses newlines' ((Get-ItemLabel "a`r`nb" $false) -eq 'a b') (Get-ItemLabel "a`r`nb" $false)
    Check 'unit' 'Get-ItemLabel keeps marker' ((Get-ItemLabel "a`nb" $true) -eq 'a <NL> b') (Get-ItemLabel "a`nb" $true)
    $files5 = ([string][char]1) + "C:\x\a.txt`nC:\x\b.txt`nC:\x\c.txt`nC:\x\d.txt`nC:\x\e.txt"
    Check 'unit' 'Get-ItemLabel file count' ((Get-ItemLabel $files5 $true) -eq '[files] a.txt, b.txt, c.txt (+2)') (Get-ItemLabel $files5 $true)

    # ------------------------------------------------------------ config schema
    Check 'unit' 'Convert-IniValue bool on' ((Convert-IniValue 'ShowTime' 'on').Value -eq '1') ''
    Check 'unit' 'Convert-IniValue bool bad' (-not (Convert-IniValue 'ShowTime' 'maybe').Ok) ''
    Check 'unit' 'Convert-IniValue int ok' ((Convert-IniValue 'WindowHeight' '480').Value -eq '480') ''
    Check 'unit' 'Convert-IniValue int too small' (-not (Convert-IniValue 'WindowHeight' '100').Ok) ''
    Check 'unit' 'Convert-IniValue int too big' (-not (Convert-IniValue 'MaxItems' '999999999').Ok) ''
    Check 'unit' 'Convert-IniValue install flag' ((Convert-IniValue 'Autostart' 'off').Value -eq '0') ''
    Check 'unit' 'Convert-IniValue int not a number' (-not (Convert-IniValue 'MaxItems' 'many').Ok) ''
    Check 'unit' 'Convert-IniValue theme normalises case' ((Convert-IniValue 'Theme' 'LIGHT').Value -eq 'win11-light') ''
    Check 'unit' 'Convert-IniValue enum bad' (-not (Convert-IniValue 'Theme' 'blue').Ok) ''
    Check 'unit' 'Convert-IniValue regex bad' (-not (Convert-IniValue 'ExcludePattern' '(').Ok) ''
    Check 'unit' 'Convert-IniValue hotkey bad' (-not (Convert-IniValue 'Hotkey' 'Ctrl+Nope').Ok) ''
    Check 'unit' 'Convert-IniValue list ok' ((Convert-IniValue 'Plugins' 'item-marks, extra').Value -eq 'item-marks,extra') ''
    Check 'unit' 'Convert-IniValue list rejects bad chars' (-not (Convert-IniValue 'Plugins' 'a b').Ok) ''
    Check 'unit' 'Convert-IniValue unknown key' (-not (Convert-IniValue 'Nope' '1').Ok) ''

    # -------------------------------------------------------------------- themes
    $tn = @(Get-ThemeNames)
    Check 'unit' 'theme files discovered' (($tn -contains 'win11-dark') -and ($tn -contains 'win11-light')) ($tn -join ',')
    Check 'unit' 'theme alias dark' ((Resolve-ThemeName 'dark') -eq 'win11-dark') ''
    Check 'unit' 'theme alias LIGHT' ((Resolve-ThemeName 'LIGHT') -eq 'win11-light') ''
    Check 'unit' 'theme unknown falls back' ((Resolve-ThemeName 'nope') -eq 'win11-dark') ''
    Check 'unit' 'theme colour opaque' ((Convert-ThemeColor '#202020').R -eq 32) ''
    Check 'unit' 'theme colour alpha' ((Convert-ThemeColor '#1CFFFFFF').A -eq 28) ''
    Check 'unit' 'theme colour rejects junk' ($null -eq (Convert-ThemeColor 'red')) ''
    Check 'unit' 'missing theme file is null' ($null -eq (Read-Theme 'nosuch')) ''
    Check 'unit' 'Convert-IniValue theme ok' ((Convert-IniValue 'Theme' 'win11-light').Value -eq 'win11-light') ''
    Check 'unit' 'Convert-IniValue theme alias' ((Convert-IniValue 'Theme' 'light').Value -eq 'win11-light') ''
    Check 'unit' 'Convert-IniValue theme bad' (-not (Convert-IniValue 'Theme' 'nosuch').Ok) ''
    $script:Theme = 'win11-dark'; Apply-Theme
    $pal = Get-UiPalette
    Check 'unit' 'dark surface' ($pal.Surface.ToArgb() -eq [Drawing.Color]::FromArgb(32, 32, 32).ToArgb()) $pal.Surface.ToString()
    Check 'unit' 'dark accent' ($pal.Accent.ToArgb() -eq [Drawing.Color]::FromArgb(96, 205, 255).ToArgb()) $pal.Accent.ToString()
    Check 'unit' 'dark border keeps alpha' ($pal.Border.A -eq 22) ($pal.Border.A -as [string])
    $script:Theme = 'win11-light'; Apply-Theme
    $pal = Get-UiPalette
    Check 'unit' 'light surface' ($pal.Surface.ToArgb() -eq [Drawing.Color]::FromArgb(243, 243, 243).ToArgb()) $pal.Surface.ToString()
    Check 'unit' 'light text' ($pal.Text.ToArgb() -eq [Drawing.Color]::FromArgb(26, 26, 26).ToArgb()) $pal.Text.ToString()
    Check 'unit' 'theme fonts loaded' ($script:ThemeFonts.Count -ge 4) (($script:ThemeFonts.Keys | Sort-Object) -join ',')
    Check 'unit' 'theme keeps base metrics' ($script:Metric['RowHeight'] -eq 40) ($script:Metric['RowHeight'] -as [string])
    $script:Theme = 'nosuch-theme'; Apply-Theme
    Check 'unit' 'unknown theme resolves to default' (($script:Theme -eq 'win11-dark') -and ((Get-UiPalette).Surface.ToArgb() -eq [Drawing.Color]::FromArgb(32, 32, 32).ToArgb())) $script:Theme

    $cfg = Join-Path $unitDir 'clipboard.ini'
    [IO.File]::WriteAllLines($cfg, @('# keep me', 'Theme=dark', 'MaxItems=7'), $Utf8)
    [void](Set-IniKey 'Theme' 'light')
    [void](Set-IniKey 'ShowTime' '0')
    $iniText = [IO.File]::ReadAllText($cfg)
    Check 'unit' 'Set-IniKey replaces' ($iniText -match '(?m)^Theme=light\r?$') ''
    Check 'unit' 'Set-IniKey appends' ($iniText -match '(?m)^ShowTime=0\r?$') ''
    Check 'unit' 'Set-IniKey keeps comments' ($iniText -match '# keep me') ''
    Check 'unit' 'Set-IniKey keeps other keys' ($iniText -match '(?m)^MaxItems=7\r?$') ''
    Check 'unit' 'Get-IniKey reads back' ((Get-IniKey 'Theme') -eq 'light') (Get-IniKey 'Theme')

    Apply-Config
    Check 'unit' 'Apply-Config Theme' ($script:Theme -eq 'win11-light') $script:Theme
    Check 'unit' 'Apply-Config ShowTime=0' (-not $script:ShowTime) ''
    Check 'unit' 'Apply-Config MaxItems' ($MaxItems -eq 7) ($MaxItems -as [string])
    Check 'unit' 'install shortcuts default on' ($script:Autostart -and $script:DesktopShortcut) ''
    [IO.File]::WriteAllLines($cfg, @('WindowHeight=100', 'MaxItems=0', 'Highlight=abc'), $Utf8)
    Apply-Config
    Check 'unit' 'Apply-Config rejects out of range' (($script:WinHeight -eq 510) -and ($MaxItems -eq 300) -and $script:HighlightOn) ('h=' + $script:WinHeight + ' items=' + $MaxItems)

    # ------------------------------------------------------- entry kinds / glyphs
    # the base only separates a file list from text; finer typing is a plugin job
    Check 'unit' 'Get-EntryKind text' ((Get-EntryKind 'plain words') -eq 'text') ''
    Check 'unit' 'Get-EntryKind link is text in base' ((Get-EntryKind 'https://a.b/c') -eq 'text') ''
    Check 'unit' 'Get-EntryKind files' ((Get-EntryKind (([string][char]1) + 'C:\a.txt')) -eq 'files') ''
    Check 'unit' 'Get-EntryKind empty' ((Get-EntryKind '') -eq 'empty') ''

    # no plugin means no row icon at all: typing an entry is a plugin's job
    $script:Plugins = @()
    Check 'unit' 'no plugin means no row icon' ((Get-RowGlyph 'https://a.b/c') -eq '') (Get-RowGlyph 'https://a.b/c')
    Check 'unit' 'no plugin means no icon for a file list' ((Get-RowGlyph (([string][char]1) + 'C:\a.txt')) -eq '') ''

    # ------------------------------------------------- plugin loader (opt-in only)
    $pdir = Join-Path $unitDir 'plugins'
    New-Item -ItemType Directory -Path $pdir -Force | Out-Null
    [IO.File]::WriteAllLines((Join-Path $pdir 'one.ps1'), @(
        "@{ Name = 'one'; Description = 'test'; TypeGlyph = { param(`$p) 'L' };";
        "   Settings = [ordered]@{ Flag = @{ Kind = 'bool'; Default = 0; Desc = 'test flag' };"
        "     Tint = @{ Kind = 'color'; Default = '#000000'; Themeable = `$true; Desc = 'themeable tint' } };"
        "   Commands = @{ 'hi' = { param(`$v) Write-Host ('hi ' + `$v) } };"
        "   Transform = { param(`$p) ('T:' + `$p) };"
        "   RowDecor = { param(`$r) if (`$r.Marks -match 's') { @{ Marks = @( @{ Glyph = 'M'; Color = '#112233' } ); TextColor = '#445566' } } } ;"
        "   Tick = @{ Seconds = 5; Action = { param(`$now) } };"
        "   PanelKeys = @( @{ Key = 'O'; Ctrl = `$true; Label = 'open it'; Test = { param(`$r) `$true }; Invoke = { param(`$r) } } );"
        "   Init = { `$global:cbInitRan = 1 };"
        "   ContextMenu = @( @{ Label = 'Do'; Test = { param(`$r) `$true }; Invoke = { param(`$r) } } ) }"), $Utf8)
    [IO.File]::WriteAllLines((Join-Path $pdir 'two.ps1'), @("@{ Name = 'two' }"), $Utf8)
    [IO.File]::WriteAllLines((Join-Path $pdir 'nameless.ps1'), @("@{ Description = 'x' }"), $Utf8)
    [IO.File]::WriteAllLines((Join-Path $pdir 'boom.ps1'), @('throw "boom"'), $Utf8)

    Check 'unit' 'empty Plugins list loads nothing' (@(Load-Plugins $pdir @()).Count -eq 0) ''
    Check 'unit' 'Plugins list loads one' ((@(Load-Plugins $pdir @('one') | ForEach-Object { $_.Name }) -join ',') -eq 'one') ''
    Check 'unit' 'Plugins match ignores case' (@(Load-Plugins $pdir @('ONE')).Count -eq 1) ''
    Check 'unit' 'Plugins ignores unlisted files' ((@(Load-Plugins $pdir @('two', 'one') | ForEach-Object { $_.Name } | Sort-Object) -join ',') -eq 'one,two') ''
    Check 'unit' 'Plugins order is the list order' ((@(Load-Plugins $pdir @('two', 'one') | ForEach-Object { $_.Name }) -join ',') -eq 'two,one') (@(Load-Plugins $pdir @('two', 'one') | ForEach-Object { $_.Name }) -join ',')
    Check 'unit' 'plugin without Name is ignored' (@(Load-Plugins $pdir @('nameless')).Count -eq 0) ''
    Check 'unit' 'broken plugin does not throw' (@(Load-Plugins $pdir @('boom')).Count -eq 0) ''
    [void](Load-Plugins $pdir @('nosuch', 'one'))
    Check 'unit' 'missing plugin name reported' ((@(Get-PluginMissingNames) -join ',') -eq 'nosuch') (@(Get-PluginMissingNames) -join ',')
    Check 'unit' 'missing folder reports every name' ((@(Load-Plugins (Join-Path $unitDir 'nope') @('x')).Count -eq 0) -and ((@(Get-PluginMissingNames) -join ',') -eq 'x')) ''

    $script:Plugins = @(Load-Plugins $pdir @('one', 'two'))
    $pcmd = Get-PluginCommand 'hi'
    Check 'unit' 'Get-PluginCommand returns scriptblock' ($pcmd -is [scriptblock]) ''
    Check 'unit' 'Get-PluginCommand unknown is null' ($null -eq (Get-PluginCommand 'nope')) ''
    $acts = @(Get-PluginActions)
    Check 'unit' 'Get-PluginActions label' (($acts.Count -eq 1) -and ($acts[0].Label -eq 'Do')) ($acts.Count -as [string])
    $rec = [pscustomobject]@{ Payload = 'https://a.b/c'; Flags = 't'; Time = 0; DelIndex = 0 }
    Check 'unit' 'Test-PluginAction true' (Test-PluginAction $acts[0] $rec) ''
    $keys = @(Get-PluginPanelKeys)
    Check 'unit' 'PanelKeys are collected' (($keys.Count -eq 1) -and ($keys[0].Key -eq 'O') -and $keys[0].Ctrl -and ($keys[0].Plugin -eq 'one')) ($keys.Count -as [string])
    Check 'unit' 'PanelKeys match a key press' ($null -ne (Get-PluginPanelKey 'O' $true $false $false)) ''
    Check 'unit' 'PanelKeys need their modifiers' ($null -eq (Get-PluginPanelKey 'O' $false $false $false)) ''
    Check 'unit' 'PanelKeys ignore other keys' ($null -eq (Get-PluginPanelKey 'Q' $true $false $false)) ''
    $script:PluginInitDone = $false
    $global:cbInitRan = 0
    Invoke-PluginInit
    Check 'unit' 'Init hook runs once' ($global:cbInitRan -eq 1) ([string]$global:cbInitRan)
    $global:cbInitRan = 0
    Invoke-PluginInit
    Check 'unit' 'Init hook does not repeat' ($global:cbInitRan -eq 0) ([string]$global:cbInitRan)
    $global:cbInitRan = 0
    Check 'unit' 'Test-PluginAction non-hashtable' (-not (Test-PluginAction 'x' $rec)) ''
    Check 'unit' 'plugin glyph block wins' ((Get-EntryGlyph 'https://a.b/c') -eq 'L') (Get-EntryGlyph 'https://a.b/c')

    # the base never paints an icon of its own
    $script:Plugins = @()
    Check 'unit' 'base glyph: none for text' ((Get-RowGlyph 'https://a.b/c') -eq '') (Get-RowGlyph 'https://a.b/c')
    Check 'unit' 'base glyph: none for code' ((Get-RowGlyph 'function Foo { 1 }') -eq '') (Get-RowGlyph 'function Foo { 1 }')
    Check 'unit' 'base glyph: none for files' ((Get-RowGlyph (([string][char]1) + 'C:\a.txt')) -eq '') ''

    # the shipped plugin is opt-in and loads by file name
    Check 'unit' 'shipped plugin off by default' (@(Load-Plugins (Join-Path $repoRoot 'plugins') @()).Count -eq 0) ''
    $real = @(Load-Plugins (Join-Path $repoRoot 'plugins') @('entry-actions'))
    Check 'unit' 'shipped plugin loads by name' ((@($real | ForEach-Object { $_.Name }) -join ',') -eq 'entry-actions') (@($real | ForEach-Object { $_.Name }) -join ',')
    $script:Plugins = $real
    Check 'unit' 'shipped command: open' ((Get-PluginCommand 'open') -is [scriptblock]) ''
    Check 'unit' 'shipped command: kind' ((Get-PluginCommand 'kind') -is [scriptblock]) ''
    Check 'unit' 'shipped panel key: Ctrl+O' ($null -ne (Get-PluginPanelKey 'O' $true $false $false)) ''
    Check 'unit' 'entry-actions supplies a row icon' ((Get-RowGlyph 'https://a.b/c') -ne '') (Get-RowGlyph 'https://a.b/c')
    Check 'unit' 'entry-actions types a link before a path' ((Get-RowGlyph 'https://a.b/c') -ne (Get-RowGlyph 'C:\temp\a.txt')) ((Get-RowGlyph 'https://a.b/c') + ' vs ' + (Get-RowGlyph 'C:\temp\a.txt'))

    # -------------------------------------------------- plugin settings (own keys)
    $script:Plugins = @(Load-Plugins $pdir @('one'))
    Register-PluginSettings
    Check 'unit' 'plugin setting joins the schema' ($script:IniSchema.Contains('one.Flag')) ''
    Check 'unit' 'plugin setting validates like a base key' ((Convert-IniValue 'one.Flag' 'on').Value -eq '1') ''
    Check 'unit' 'plugin setting rejects bad value' (-not (Convert-IniValue 'one.Flag' 'maybe').Ok) ''
    [IO.File]::WriteAllLines($cfg, @('one.Flag=1'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'plugin setting reads ini value' ((Get-PluginSetting 'one' 'Flag') -eq '1') (Get-PluginSetting 'one' 'Flag')
    [IO.File]::WriteAllLines($cfg, @('one.Flag=maybe'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'plugin setting falls back on bad value' ((Get-PluginSetting 'one' 'Flag') -eq '0') (Get-PluginSetting 'one' 'Flag')
    Check 'unit' 'unknown plugin setting is empty' ((Get-PluginSetting 'one' 'Nope') -eq '') ''

    $script:Plugins = @(Load-Plugins (Join-Path $repoRoot 'plugins') @('entry-actions'))
    Register-PluginSettings
    [IO.File]::WriteAllLines($cfg, @(), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'shipped plugin declares settings' (($script:IniSchema.Contains('entry-actions.Browser')) -and ($script:IniSchema.Contains('entry-actions.Reveal'))) ''
    Check 'unit' 'shipped setting default' ((Get-PluginSetting 'entry-actions' 'Reveal') -eq '1') (Get-PluginSetting 'entry-actions' 'Reveal')
    Check 'unit' 'shipped setting empty default' ((Get-PluginSetting 'entry-actions' 'Browser') -eq '') ''
    $script:Plugins = @()

    # ------------------------------------------------------ plugin lifecycle hooks
    $script:Plugins = @(Load-Plugins $pdir @('one'))
    $decorRec = [pscustomobject]@{ Payload = 'x'; Time = 0; Marks = 's' }
    $dec = Get-PluginRowDecor $decorRec
    Check 'unit' 'RowDecor marks list' (($dec.Marks.Count -eq 1) -and ($dec.Marks[0].Glyph -eq 'M')) ($dec.Marks.Count -as [string])
    Check 'unit' 'RowDecor mark colour' ($dec.Marks[0].Color -eq '#112233') $dec.Marks[0].Color
    Check 'unit' 'RowDecor text colour' ($dec.TextColor -eq '#445566') $dec.TextColor
    Check 'unit' 'RowDecor has no leading-bar key' (-not $dec.ContainsKey('Emphasis')) ''
    Check 'unit' 'RowDecor empty when nothing applies' (((Get-PluginRowDecor ([pscustomobject]@{ Payload = 'x'; Marks = '' })).Marks).Count -eq 0) ''
    Check 'unit' 'Transform applied' ((Invoke-PluginTransform 'abc') -eq 'T:abc') (Invoke-PluginTransform 'abc')
    $ticks = @(Get-PluginTicks)
    Check 'unit' 'Tick registered' (($ticks.Count -eq 1) -and ($ticks[0].Name -eq 'one') -and ($ticks[0].Seconds -eq 5)) ($ticks.Count -as [string])
    Check 'unit' 'Tick throttles' ($script:PluginTimers.Count -eq 0) ''
    Invoke-PluginTicks
    Check 'unit' 'Tick ran once' ($script:PluginTimers.ContainsKey('tick:one')) ''
    $script:Plugins = @()
    Check 'unit' 'no plugin transform is passthrough' ((Invoke-PluginTransform 'abc') -eq 'abc') ''
    Check 'unit' 'no plugin decor is empty' (((Get-PluginRowDecor $decorRec).Marks).Count -eq 0) ''
    Check 'unit' 'no plugin ticks' (@(Get-PluginTicks).Count -eq 0) ''

    # ------------------------------------------ shipped plugins share their own logic
    # a Tick interval may be computed at runtime, so a plugin needs no timer state
    $script:Plugins = @(@{ Name = 'timed'; Tick = @{ Seconds = { 120 }; Action = { param($now) } } })
    $timed = @(Get-PluginTicks)
    Check 'unit' 'Tick seconds may be a scriptblock' (($timed.Count -eq 1) -and ($timed[0].Seconds -eq 120)) ($timed[0].Seconds -as [string])

    $script:Plugins = @(Load-Plugins (Join-Path $repoRoot 'plugins') @('item-marks'))
    $menuActs = @(Get-PluginActions)
    $allMarks = [pscustomobject]@{ Payload = 'x'; Time = 0; Marks = 'psh' }
    $noMarks = [pscustomobject]@{ Payload = 'x'; Time = 0; Marks = '' }
    Check 'unit' 'menu caption: every action resolves its own text' ((@($menuActs | ForEach-Object { Get-ActionText $_ $allMarks }) -join '|') -eq 'Remove pin|Remove star|Clear highlight') (@($menuActs | ForEach-Object { Get-ActionText $_ $allMarks }) -join '|')
    Check 'unit' 'menu caption: plain labels for an unmarked row' ((@($menuActs | ForEach-Object { Get-ActionText $_ $noMarks }) -join '|') -eq 'Pin to top|Star|Highlight') (@($menuActs | ForEach-Object { Get-ActionText $_ $noMarks }) -join '|')
    Check 'unit' 'menu caption: static label wins over the fallback' ((Get-ActionText @{ Label = 'Open' } $null) -eq 'Open') ''
    Check 'unit' 'menu caption: missing label falls back' ((Get-ActionText @{} $null) -eq 'Plugin action') ''
    Check 'unit' 'menu caption: a throwing label falls back' ((Get-ActionText @{ Label = { throw 'boom' } } $null) -eq 'Plugin action') ''
    Check 'unit' 'menu actions carry their owner' ((@($menuActs | ForEach-Object { $_['Plugin'] } | Select-Object -Unique) -join ',') -eq 'item-marks') (@($menuActs | ForEach-Object { $_['Plugin'] } | Select-Object -Unique) -join ',')

    $script:Plugins = @(Load-Plugins (Join-Path $repoRoot 'plugins') @('transform'))
    Register-PluginSettings
    [IO.File]::WriteAllLines($cfg, @('transform.Mode=snake'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    $apply = Get-PluginData 'transform' 'Apply'
    Check 'unit' 'transform exposes one rewrite block' ($apply -is [scriptblock]) ''
    Check 'unit' 'transform hook uses that block' ((Invoke-PluginTransform 'Hello World') -eq (& $apply 'Hello World' 'snake')) (Invoke-PluginTransform 'Hello World')
    Check 'unit' 'transform leaves file lists alone' ((& $apply (([string][char]1) + 'C:\a.txt') 'upper') -eq (([string][char]1) + 'C:\a.txt')) ''
    Check 'unit' 'transform reports the configured mode' ((& (Get-PluginData 'transform' 'CurrentMode')) -eq 'snake') (& (Get-PluginData 'transform' 'CurrentMode'))
    $tActs = @(Get-PluginActions)
    Check 'unit' 'transform registers one menu entry' (($tActs.Count -eq 1) -and ($tActs[0]['Plugin'] -eq 'transform')) ($tActs.Count -as [string])
    $tMenu = $tActs[0]
    Check 'unit' 'transform menu caption names the mode' ((Get-ActionText $tMenu ([pscustomobject]@{ Payload = 'Hello World'; Marks = '' })) -eq 'Transform as snake') (Get-ActionText $tMenu ([pscustomobject]@{ Payload = 'Hello World'; Marks = '' }))
    Check 'unit' 'transform menu shows for text rows' ((Test-PluginAction $tMenu ([pscustomobject]@{ Payload = 'Hello World'; Marks = '' })) -eq $true) ''
    Check 'unit' 'transform menu hides for file lists' ((Test-PluginAction $tMenu ([pscustomobject]@{ Payload = (([string][char]1) + 'C:\a.txt'); Marks = '' })) -eq $false) ''
    [IO.File]::WriteAllLines($cfg, @('transform.Mode=keep'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'transform menu hides while the mode is keep' ((Test-PluginAction $tMenu ([pscustomobject]@{ Payload = 'Hello World'; Marks = '' })) -eq $false) ''
    [IO.File]::WriteAllLines($cfg, @('transform.Mode=snake'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings

    # two plugins keep their own block, in load order
    $script:Plugins = @(Load-Plugins (Join-Path $repoRoot 'plugins') @('item-marks', 'transform'))
    $owners = @(Get-PluginActions | ForEach-Object { [string]$_['Plugin'] })
    Check 'unit' 'menu keeps one block per plugin' (($owners -join ',') -eq 'item-marks,item-marks,item-marks,transform') ($owners -join ',')

    $script:Plugins = @(Load-Plugins (Join-Path $repoRoot 'plugins') @('transform', 'item-marks'))
    $owners = @(Get-PluginActions | ForEach-Object { [string]$_['Plugin'] })
    Check 'unit' 'load order follows the Plugins list' (($owners -join ',') -eq 'transform,item-marks,item-marks,item-marks') ($owners -join ',')
    $names = @($script:Plugins | ForEach-Object { [string]$_['Name'] })
    Check 'unit' 'plugin list keeps the written order' (($names -join ',') -eq 'transform,item-marks') ($names -join ',')
    $script:Plugins = @()

    $script:Plugins = @(Load-Plugins (Join-Path $repoRoot 'plugins') @('entry-actions'))
    Register-PluginSettings
    [IO.File]::WriteAllLines($cfg, @(), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'entry-actions exposes one open rule' ((& (Get-PluginData 'entry-actions' 'CanOpen') ([pscustomobject]@{ Payload = 'https://a.b/c' })) -eq $true) ''
    Check 'unit' 'open rule rejects plain text' ((& (Get-PluginData 'entry-actions' 'CanOpen') ([pscustomobject]@{ Payload = 'hello world' })) -eq $false) ''
    Check 'unit' 'open rule accepts a file list' ((& (Get-PluginData 'entry-actions' 'CanOpen') ([pscustomobject]@{ Payload = (([string][char]1) + 'C:\a.txt') })) -eq $true) ''
    Check 'unit' 'open rule ignores a null row' ((& (Get-PluginData 'entry-actions' 'CanOpen') $null) -eq $false) ''
    Check 'unit' 'sniffers live in one block' (((& (Get-PluginData 'entry-actions' 'Sniff') '{"a":1}') -join ',') -match 'json') ''

    # retention: protected rows survive, the sort mark can be kept too
    $script:Plugins = @(Load-Plugins (Join-Path $repoRoot 'plugins') @('item-marks', 'retention'))
    Register-PluginSettings
    [IO.File]::WriteAllLines($cfg, @('retention.MaxAgeDays=1', 'retention.KeepPinned=1'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    $now = Get-Epoch
    $old = $now - (3 * 86400)
    $age = New-Object System.Collections.Generic.List[object]
    $age.Add((New-Record 'old-plain' $old ''))
    $age.Add((New-Record 'old-star' $old 's'))
    $age.Add((New-Record 'old-pin' $old 'p'))
    $age.Add((New-Record 'fresh' $now ''))
    Save-Records $age.ToArray()
    $dropped = [int](& (Get-PluginData 'retention' 'Sweep'))
    $leftSet = (@((Get-Records) | ForEach-Object { $_.Payload }) | Sort-Object) -join ','
    Check 'unit' 'retention drops only the unprotected old row' ($dropped -eq 1) ([string]$dropped)
    Check 'unit' 'retention keeps protected and pinned rows' ($leftSet -eq 'fresh,old-pin,old-star') $leftSet
    [IO.File]::WriteAllLines($cfg, @('retention.MaxAgeDays=0'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'retention off removes nothing' ((& (Get-PluginData 'retention' 'Sweep')) -eq 0) ''
    $script:Plugins = @()
    Use-StoreLock { Save-Records @() }

    # ----------------------------------------------- protected marks and the store
    $script:Plugins = @($markPlugin)
    Use-StoreLock { Save-Records @() }
    Add-Item 'star-me'
    $r0 = @(Get-Records)[0]
    Check 'unit' 'record starts unmarked' ([string]$r0.Marks -eq '') ([string]$r0.Marks)
    Check 'unit' 'Set-Mark on' (Set-Mark 'star-me' 's' $true) ''
    Check 'unit' 'mark survives a reload' (Test-Mark @(Get-Records)[0] 's') ''
    Check 'unit' 'Set-Mark is idempotent' (-not (Set-Mark 'star-me' 's' $true)) ''
    Check 'unit' 'delete refuses a protected row' ((Remove-Record 'star-me') -eq 'protected:s') (Remove-Record 'star-me')
    Check 'unit' 'delete -Force removes it' ((Remove-Record 'star-me' -Force) -eq 'removed') ''

    $tl = New-Object System.Collections.Generic.List[object]
    $tl.Add((New-Record 'keep-star' 1 's'))
    $tl.Add((New-Record 'drop-1' 2 ''))
    $tl.Add((New-Record 'drop-2' 3 ''))
    $oldMax = $MaxItems
    $MaxItems = 1
    Trim-Records $tl
    $MaxItems = $oldMax
    Check 'unit' 'trim keeps a protected row' (($tl.Count -eq 1) -and ($tl[0].Payload -eq 'keep-star')) (($tl | ForEach-Object { $_.Payload }) -join ',')

    Use-StoreLock { Save-Records @() }
    Add-Item 'keep-on-clear'
    [void](Set-Mark 'keep-on-clear' 's' $true)
    Add-Item 'drop-on-clear'
    Clear-Store (Get-ClearKeepMarks)
    Check 'unit' 'clear keeps a protected row' (((@(Get-Records) | ForEach-Object { $_.Payload }) -join ',') -eq 'keep-on-clear') (((@(Get-Records) | ForEach-Object { $_.Payload }) -join ','))
    Use-StoreLock { Save-Records @() }

    # a mark nobody protects is stored, printed and dropped like any other row
    Add-Item 'mark-me'
    $h0 = @(Get-Records)[0]
    Check 'unit' 'record starts unhighlighted' (-not (Test-Mark $h0 'h')) ''
    Check 'unit' 'Set-Mark on an undeclared mark' (Set-Mark 'mark-me' 'h' $true) ''
    Check 'unit' 'undeclared mark survives a reload' (Test-Mark @(Get-Records)[0] 'h') ''
    $rawStore = [IO.File]::ReadAllText($StoreFile)
    Check 'unit' 'mark stored in the flag string' ($rawStore.Contains([string][char]30 + 'th' + [string][char]31)) ''
    Check 'unit' 'Set-Mark is idempotent for a display mark' (-not (Set-Mark 'mark-me' 'h' $true)) ''
    Check 'unit' 'unprotected mark does not block a delete' ((Remove-Record 'mark-me') -eq 'removed') ''
    Add-Item 'mark-clear'
    [void](Set-Mark 'mark-clear' 'h' $true)
    Clear-Store (Get-ClearKeepMarks -All)
    Check 'unit' 'clear drops unprotected marks' (@(Get-Records).Count -eq 0) ([string]@(Get-Records).Count)
    $script:Plugins = @()
    Use-StoreLock { Save-Records @() }

    # -------------------------------------- theme is a package, not ini colour knobs
    [IO.File]::WriteAllLines($cfg, @('Theme.Accent=#FF6600'), $Utf8)
    $script:IniCache = $null
    $script:Theme = 'win11-dark'
    Apply-Theme
    Check 'unit' 'theme colours are not ini keys' (-not $script:IniSchema.Contains('Theme.Accent')) ''
    Check 'unit' 'palette ignores unknown Theme.* keys' ((Get-UiPalette).Accent.ToArgb() -eq [Drawing.Color]::FromArgb(96, 205, 255).ToArgb()) (Get-UiPalette).Accent.ToString()
    Check 'unit' 'palette comes from the theme file' ((Get-UiPalette).Surface.ToArgb() -eq [Drawing.Color]::FromArgb(32, 32, 32).ToArgb()) (Get-UiPalette).Surface.ToString()
    [IO.File]::WriteAllLines($cfg, @(), $Utf8)
    $script:IniCache = $null
    Apply-Theme

    $script:Theme = 'win11-light'
    Apply-Theme
    Check 'unit' 'light palette still switches by name' ((Get-UiPalette).Surface.ToArgb() -eq [Drawing.Color]::FromArgb(243, 243, 243).ToArgb()) (Get-UiPalette).Surface.ToString()
    $script:Plugins = @(Load-Plugins (Join-Path $repoRoot 'plugins') @('item-marks'))
    Register-PluginSettings
    Register-PluginThemeSettings
    Apply-PluginSettings
    Apply-PluginTheme
    Check 'unit' 'theme restyles a plugin ThemeSetting' ((Get-PluginTheme 'item-marks' 'StarColor') -eq '#9D5D00') (Get-PluginTheme 'item-marks' 'StarColor')
    Check 'unit' 'theme restyles the emphasis ink' ((Get-PluginTheme 'item-marks' 'EmphasisInk') -eq '#005FB8') (Get-PluginTheme 'item-marks' 'EmphasisInk')
    $hrec = [pscustomobject]@{ Payload = 'hi'; Time = 0; Marks = 'h' }
    $hdec = Get-PluginRowDecor $hrec
    Check 'unit' 'highlight decor paints the text' ($hdec.TextColor -eq '#005FB8') $hdec.TextColor
    Check 'unit' 'highlight decor paints the background' ($hdec.BackColor -eq '#24005FB8') $hdec.BackColor

    # the highlight colours are plugin settings; empty means "follow the theme"
    Check 'unit' 'highlight ink is an ini key' ($script:IniSchema.Contains('item-marks.HighlightColor')) ''
    Check 'unit' 'highlight fill is an ini key' ($script:IniSchema.Contains('item-marks.HighlightBg')) ''
    Check 'unit' 'highlight settings default to empty' ((Get-PluginSetting 'item-marks' 'HighlightColor') -eq '') (Get-PluginSetting 'item-marks' 'HighlightColor')
    [IO.File]::WriteAllLines($cfg, @('item-marks.HighlightColor=#123456', 'item-marks.HighlightBg=#99123456'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    $idec = Get-PluginRowDecor $hrec
    Check 'unit' 'ini highlight ink wins over the theme' ($idec.TextColor -eq '#123456') $idec.TextColor
    Check 'unit' 'ini highlight fill wins over the theme' ($idec.BackColor -eq '#99123456') $idec.BackColor
    Check 'unit' 'theme value stays independent of the ini key' ((Get-PluginTheme 'item-marks' 'EmphasisInk') -eq '#005FB8') (Get-PluginTheme 'item-marks' 'EmphasisInk')
    [IO.File]::WriteAllLines($cfg, @(), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'empty ini key follows the theme again' ((Get-PluginRowDecor $hrec).TextColor -eq '#005FB8') (Get-PluginRowDecor $hrec).TextColor
    $prec = [pscustomobject]@{ Payload = 'hi'; Time = 0; Marks = 'ps' }
    $pdec = Get-PluginRowDecor $prec
    Check 'unit' 'pin and star both become glyph marks' ($pdec.Marks.Count -eq 2) ($pdec.Marks.Count -as [string])
    Check 'unit' 'pin and star draw no leading bar' (-not $pdec.ContainsKey('Emphasis')) ''
    Check 'unit' 'theme leaves plugin Settings alone' (-not $script:IniSchema.Contains('item-marks.StarGlyph')) ''
    Check 'unit' 'plugin ThemeSettings are not ini keys' (-not $script:IniSchema.Contains('item-marks.StarColor')) ''
    $script:Plugins = @()
    $script:Theme = 'win11-dark'
    Apply-Theme

    # ThemeSettings default when the theme has no section for the plugin
    $script:Theme = 'win11-dark'
    Apply-Theme
    $script:ThemeOverrides = @{}
    $script:Plugins = @(Load-Plugins (Join-Path $repoRoot 'plugins') @('item-marks'))
    Register-PluginThemeSettings
    Apply-PluginTheme
    Check 'unit' 'ThemeSettings fall back to the plugin default' ((Get-PluginTheme 'item-marks' 'StarGlyph') -eq [string][char]0xE735) ''
    $script:Plugins = @()

    Save-Records @()
  }

  # --------------------------------------------------------- integration tests
  if ($Integration) {
    $o = Clip $intDir @('help')
    Check 'int' 'help' ($o -match 'Usage: clipboard') ''

    $o = Clip $intDir @('config')
    Check 'int' 'config shows ini path' ($o -match 'clipboard\.ini') ''

    $o = Clip $intDir @('put', 'itest-alpha')
    Check 'int' 'put' ($o -match 'clipboard set') $o.Trim()

    $o = Clip $intDir @('get')
    Check 'int' 'get' ($o -match 'itest-alpha') $o.Trim()

    $o = Clip $intDir @('list', '-Count', '5')
    Check 'int' 'list' ($o -match 'itest-alpha') ''

    $o = Clip $intDir @('pick', '1')
    Check 'int' 'pick' ($o -match 'clipboard set') $o.Trim()
    $o = Clip $intDir @('get')
    Check 'int' 'pick sets clipboard' ($o -match 'itest-alpha') ''

    $o = Clip $intDir @('del', '1')
    Check 'int' 'del' ($o -match 'deleted') $o.Trim()

    $o = Clip $intDir @('clear')
    Check 'int' 'clear' ($o -match 'history cleared') ''
    $o = Clip $intDir @('list')
    Check 'int' 'list empty after clear' ($o -match 'history is empty') ''

    $o = Clip $intDir @('put', 'stdin-like-value')
    $o = Clip $intDir @('del', '9')
    Check 'int' 'del out of range' ($o -match 'index out of range') $o.Trim()

    $o = Clip $intDir @('pick', 'x')
    Check 'int' 'pick bad arg' ($o -match 'usage: clipboard pick') $o.Trim()

    $o = Clip $intDir @('nosuchcommand')
    Check 'int' 'unknown command' ($o -match 'unknown command') ''

    $o = Clip $intDir @('pause')
    $s = Clip $intDir @('status')
    Check 'int' 'pause' (($o -match 'paused') -and ($s -match 'capture     : paused')) ''
    $o = Clip $intDir @('resume')
    $s = Clip $intDir @('status')
    Check 'int' 'resume' ($s -match 'capture     : active') ''

    $o = Clip $intDir @('status')
    Check 'int' 'status fields' (($o -match 'autostart   :') -and ($o -match 'desktop     :') -and ($o -match 'store file')) ''

    $o = Clip $intDir @('diag')
    Check 'int' 'diag roundtrip' ($o -match 'Clipboard roundtrip') ''

    # config precedence: ini MaxItems=2, then the CLI switch must win
    $cfg2 = Join-Path $intDir 'clipboard.ini'
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=2'), $Utf8)
    [void](Clip $intDir @('clear'))
    1..3 | ForEach-Object { [void](Clip $intDir @('put', ('cfg-' + $_))) }
    $o = Clip $intDir @('list')
    Check 'int' 'ini MaxItems respected' (@($o -split "`n" | Where-Object { $_ -match 'cfg-' }).Count -eq 2) $o.Trim()

    [void](Clip $intDir @('clear'))
    # settings are config-only: a setting switch is refused, nothing is silently applied
    [void](Clip $intDir @('put', 'cfg-guard'))
    $bad = & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File (Join-Path $intDir 'clipboard.ps1') put 'cli-override' -MaxItems 5 2>&1
    $badText = ($bad -join ' ')
    Check 'int' 'setting switches are refused' (($badText -match 'MaxItems') -and -not ((Clip $intDir @('get')) -match 'cli-override')) $badText.Trim()
    $o = Clip $intDir @('help')
    Check 'int' 'help advertises no setting switches' ((-not ($o -match 'Options \(override')) -and ($o -match 'clipboard\.ini only') -and (-not ($o -match '-MaxItems'))) ''

    # the sandbox keeps its store next to its own script, never in the repo
    Check 'int' 'data dir isolate' ((Test-Path -LiteralPath (Join-Path $intDir 'data\history.dat')) -and -not (Test-Path -LiteralPath (Join-Path $repoRoot 'data\integration'))) ''

    # DataDir= in clipboard.ini decides the write location
    $altDir = Join-Path $tmpRoot 'alt'
    $cfgRoot = Join-Path $tmpRoot 'cfgroot'
    foreach ($d in @($altDir, $cfgRoot)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item -LiteralPath $clipPs1 -Destination (Join-Path $cfgRoot 'clipboard.ps1')
    [IO.File]::WriteAllLines((Join-Path $cfgRoot 'clipboard.ini'), @('DataDir=' + $altDir), $Utf8)
    & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File (Join-Path $cfgRoot 'clipboard.ps1') put 'ini-datadir' 2>&1 | Out-Null
    Check 'int' 'DataDir from ini' (Test-Path -LiteralPath (Join-Path $altDir 'history.dat')) $altDir

    # pin / unpin / clear / config set  (pin and star are verbs of the item-marks plugin)
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks'), $Utf8)
    [void](Clip $intDir @('clear', '-All'))
    [void](Clip $intDir @('put', 'pin-me'))
    [void](Clip $intDir @('put', 'other-one'))
    $o = Clip $intDir @('pin', '2')
    Check 'int' 'pin' ($o -match 'pinned') $o.Trim()
    $o = Clip $intDir @('list')
    $pinLine = @($o -split "`n" | Where-Object { $_ -match 'pin-me' })
    Check 'int' 'pin floats to the top' ($pinLine.Count -gt 0 -and $pinLine[0] -match '\*') $o.Trim()
    $o = Clip $intDir @('status')
    Check 'int' 'status shows the pin count' ($o -match '1 pinned') $o.Trim()
    $o = Clip $intDir @('clear')
    Check 'int' 'clear keeps the pin mark' ((($o -match 'kept by marks')) -and ((Clip $intDir @('list')) -match 'pin-me')) $o.Trim()
    $o = Clip $intDir @('clear', '-All')
    Check 'int' 'clear -All drops the pin mark' (($o -match 'history cleared')) $o.Trim()
    $o = Clip $intDir @('list')
    Check 'int' 'list empty after clear -All' ($o -match 'history is empty') $o.Trim()

    $o = Clip $intDir @('config', 'get', 'WindowHeight')
    Check 'int' 'config get' ($o -match 'WindowHeight = 510') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'WindowHeight', '480')
    $iniAfter = [IO.File]::ReadAllText($cfg2)
    Check 'int' 'config set writes' (($o -match '510 -> 480') -and ($iniAfter -match '(?m)^WindowHeight=480\r?$')) $o.Trim()
    $o = Clip $intDir @('config', 'set', 'WindowHeight', '10')
    Check 'int' 'config set rejects range' ($o -match 'must be >= 240') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'NopeKey', '1')
    Check 'int' 'config set rejects unknown key' ($o -match 'unknown key') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'DataDir', 'D:\x')
    Check 'int' 'config set rejects DataDir' ($o -match 'DataDir cannot be changed') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Hotkey', 'Ctrl+Nope')
    Check 'int' 'config set rejects bad hotkey' ($o -match 'unknown key name') $o.Trim()

    # ------------------------------------------- settings are never created silently
    $roDir = New-Sandbox 'readonly'
    $roIni = Join-Path $roDir 'clipboard.ini'
    foreach ($args in @(@('status'), @('config'), @('config', 'get', 'Theme'), @('list'), @('diag'))) {
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
    Check 'int' 'config init creates template' ((Test-Path -LiteralPath $roIni) -and $o -match 'template') $o.Trim()
    $iniTpl = [IO.File]::ReadAllText($roIni)
    $missing = @($schemaKeys | Where-Object { $iniTpl -notmatch ('(?m)^' + $_ + '=') })
    Check 'int' 'template has every schema key' ($schemaKeys.Count -gt 20 -and $missing.Count -eq 0) (($missing -join ','))
    Check 'int' 'template ships an empty plugin list' (($iniTpl -match '(?m)^Plugins=\r?$') -and (-not ($iniTpl -match 'PluginDisabled'))) ''

    # --------------------------------------- base commands / opt-in plugin commands
    [void](Clip $intDir @('clear', '-All'))
    [void](Clip $intDir @('put', 'https://example.com/hello'))
    Remove-Item -LiteralPath $cfg2 -Force -ErrorAction SilentlyContinue
    $o = Clip $intDir @('kind', '1')
    Check 'int' 'kind is a plugin command' ($o -match 'unknown command') $o.Trim()
    $o = Clip $intDir @('open', '99')
    Check 'int' 'plugin command off by default' ($o -match 'unknown command') $o.Trim()
    $o = Clip $intDir @('star', '1')
    Check 'int' 'pin and star verbs are plugin commands' ($o -match 'unknown command') $o.Trim()
    $o = Clip $intDir @('config')
    Check 'int' 'config shows base only' ($o -match 'plugins     : none \(base tool only') $o.Trim()
    $o = Clip $intDir @('help')
    Check 'int' 'base help has no kind row' (-not ($o -match '(?m)^    kind N')) ''
    Check 'int' 'base help has no pin or star rows' ((-not ($o -match '(?m)^    (pin|unpin|star|unstar) N\s')) -and (-not ($o -match 'Ctrl\+S'))) ''

    [IO.File]::WriteAllLines($cfg2, @('Plugins=entry-actions'), $Utf8)
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
    Check 'int' 'plugin setting is writable' (($o -match 'entry-actions\.Reveal') -and ($iniPlugin -match '(?m)^entry-actions\.Reveal=0\r?$')) $o.Trim()
    $o = Clip $intDir @('config', 'set', 'entry-actions.Reveal', 'maybe')
    Check 'int' 'plugin setting rejects bad value' ($o -match '0 or 1') $o.Trim()
    $o = Clip $intDir @('config', 'init')
    $tplText = [IO.File]::ReadAllText($cfg2)
    Check 'int' 'template includes plugin settings' (($tplText -match '(?m)^entry-actions\.Browser=\r?$') -and ($tplText -match '(?m)^entry-actions\.Reveal=1\r?$')) ''
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

    # -------------------------------------------------------------------- themes
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300'), $Utf8)
    $o = Clip $intDir @('themes')
    Check 'int' 'themes lists both' (($o -match 'win11-dark') -and ($o -match 'win11-light') -and ($o -match 'active: win11-dark')) $o.Trim()
    $o = Clip $intDir @('config', 'get', 'Theme')
    Check 'int' 'theme default' ($o -match 'Theme = win11-dark') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Theme', 'win11-light')
    Check 'int' 'theme switch writes ini' (($o -match 'win11-dark -> win11-light') -and ([IO.File]::ReadAllText($cfg2) -match '(?m)^Theme=win11-light\r?$')) $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Theme', 'nosuch')
    Check 'int' 'theme rejects unknown' ($o -match 'unknown theme') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Theme', 'dark')
    Check 'int' 'theme alias accepted' (($o -match 'win11-dark') -and ([IO.File]::ReadAllText($cfg2) -match '(?m)^Theme=win11-dark\r?$')) $o.Trim()

    # ------------------------------------------------- starred entries + new plugins
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks'), $Utf8)
    [void](Clip $intDir @('clear', '-All'))
    [void](Clip $intDir @('put', 'star-alpha'))
    [void](Clip $intDir @('put', 'star-beta'))
    $o = Clip $intDir @('star', '1')
    Check 'int' 'star command' ($o -match 'starred:') $o.Trim()
    $o = Clip $intDir @('status')
    Check 'int' 'status counts starred' ($o -match '1 starred') $o.Trim()
    $o = Clip $intDir @('del', '1')
    Check 'int' 'starred entry cannot be deleted' ($o -match 'starred entry, unstar it first') $o.Trim()
    $o = Clip $intDir @('clear', '-All')
    Check 'int' 'clear keeps starred' (($o -match '1 starred kept') -and ((Clip $intDir @('list')) -match 'star-beta')) $o.Trim()
    $o = Clip $intDir @('unstar', '1')
    Check 'int' 'unstar command' ($o -match 'unstarred:') $o.Trim()
    $o = Clip $intDir @('del', '1')
    Check 'int' 'delete works after unstar' ($o -match 'deleted:') $o.Trim()
    [void](Clip $intDir @('put', 'mark-gamma'))
    $o = Clip $intDir @('highlight', '1')
    Check 'int' 'highlight command' ($o -match 'highlighted:') $o.Trim()
    $o = Clip $intDir @('highlight', '1')
    Check 'int' 'highlight is repeatable-safe' ($o -match 'already highlighted') $o.Trim()
    $o = Clip $intDir @('unhighlight', '1')
    Check 'int' 'unhighlight command' ($o -match 'highlight cleared:') $o.Trim()
    $o = Clip $intDir @('unhighlight', '1')
    Check 'int' 'unhighlight reports the empty state' ($o -match 'not highlighted') $o.Trim()

    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=transform,retention,item-marks,entry-actions', 'transform.Mode=snake'), $Utf8)
    [void](Clip $intDir @('clear', '-All'))
    [void](Clip $intDir @('put', 'Hello World Demo'))
    $o = Clip $intDir @('transform', '1 upper')
    Check 'int' 'transform one-off mode' ($o -match '\[upper\] HELLO WORLD DEMO') $o.Trim()
    $o = Clip $intDir @('transform', '1')
    Check 'int' 'transform uses configured mode' ($o -match '\[snake\] hello_world_demo') $o.Trim()
    $o = Clip $intDir @('marks')
    Check 'int' 'marks command' (($o -match 'star glyph') -and ($o -match 'highlight ink')) $o.Trim()
    $o = Clip $intDir @('sweep', 'force')
    Check 'int' 'sweep command' ($o -match 'retention') $o.Trim()
    $o = Clip $intDir @('kind', '1')
    Check 'int' 'kind detail block' (($o -match 'kind text') -and ($o -match '(?m)^  size\s+:') -and ($o -match '(?m)^  preview\s+:')) $o.Trim()
    $o = Clip $intDir @('kind', '0')
    Check 'int' 'kind out of range' ($o -match 'index out of range') $o.Trim()
    $o = Clip $intDir @('kinds')
    Check 'int' 'kinds distribution' (($o -match 'kinds in ') -and ($o -match '(?m)^  text\s')) $o.Trim()
    $o = Clip $intDir @('config')
    Check 'int' 'config groups plugin settings' (($o -match '\[plugin: transform\]') -and ($o -match '(?m)^    Mode\s+=\s+snake')) ''
    Check 'int' 'config groups each enabled plugin' (($o -match '\[plugin: retention\]') -and ($o -match '\[plugin: item-marks\]') -and ($o -match '\[plugin: entry-actions\]')) ''
    Check 'int' 'config has no theme-only keys' (-not ($o -match 'Theme\.(Accent|Surface|Pin)|item-marks\.StarColor')) ''
    $o = Clip $intDir @('help')
    Check 'int' 'help groups every plugin' (($o -match '\[plugin: transform\]') -and ($o -match '\[plugin: retention\]') -and ($o -match 'transform entry N')) ''
    Check 'int' 'help groups pin and star' (($o -match '(?s)\[plugin: item-marks\].*pin\s+pin entry N.*unstar')) ''
    Check 'int' 'help lists the highlight verbs' (($o -match '(?s)\[plugin: item-marks\].*highlight\s+highlight entry N.*unhighlight')) ''
    Check 'int' 'help puts kind under entry-actions' ($o -match '(?s)\[plugin: entry-actions\].*kind\s+analyse entry N.*kinds') ''
    $o = Clip $intDir @('config', 'set', 'transform.Mode', 'kebab')
    Check 'int' 'plugin setting is writable' (($o -match 'transform\.Mode') -and ((Clip $intDir @('config', 'get', 'transform.Mode')) -match 'kebab')) $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Theme.Accent', '#FF6600')
    Check 'int' 'theme colour keys are rejected' ($o -match 'unknown key') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Theme', 'win11-light')
    Check 'int' 'theme name is still settable' ($o -match 'win11-light') $o.Trim()
    Remove-Item -LiteralPath $cfg2 -Force -ErrorAction SilentlyContinue
  }

  # ------------------------------------------------------------------ e2e tests
  if ($E2E) {
    if (-not (Test-MutexFree 'Local\clipboard.daemon')) {
      Skip 'e2e' 'daemon lifecycle' 'a resident is already running - stop it first'
      Skip 'e2e' 'capture pipeline' 'a resident is already running - stop it first'
    }
    else {
      $child = $null
      try {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', (Join-Path $e2eDir 'clipboard.ps1'), 'serve')
        $child = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argList -PassThru

        $up = $false
        for ($i = 0; $i -lt 30 -and -not $up; $i++) {
          Start-Sleep -Milliseconds 500
          if ((Clip $e2eDir @('status')) -match 'resident    : running') { $up = $true }
        }
        Check 'e2e' 'daemon starts' $up ''

        $s = Clip $e2eDir @('status')
        Check 'e2e' 'hotkey registered' ($s -match 'active key  : Ctrl\+Alt\+V') (@($s -split "`n" | Where-Object { $_ -match 'active key' }) -join '')
        Check 'e2e' 'store lives in the sandbox' ($s -match [regex]::Escape((Join-Path $e2eDir 'data'))) ''

        $marker = 'e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        [void](Set-Clip $marker)
        Start-Sleep -Milliseconds 1600
        Check 'e2e' 'capture pipeline' ((Clip $e2eDir @('list', '-Count', '5')) -match [regex]::Escape($marker)) $marker

        [void](Clip $e2eDir @('pause'))
        $marker2 = 'e2e-paused-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        [void](Set-Clip $marker2)
        Start-Sleep -Milliseconds 1600
        Check 'e2e' 'pause stops capture' (-not ((Clip $e2eDir @('list', '-Count', '5')) -match [regex]::Escape($marker2))) $marker2
        [void](Clip $e2eDir @('resume'))

        [void](Clip $e2eDir @('stop'))
        $down = $false
        for ($i = 0; $i -lt 25 -and -not $down; $i++) {
          Start-Sleep -Milliseconds 400
          if ((Clip $e2eDir @('status')) -match 'resident    : not running') { $down = $true }
        }
        Check 'e2e' 'daemon stops' $down ''

        $log = Join-Path $e2eDir 'data\clipboard.log'
        $logText = if (Test-Path -LiteralPath $log) { [IO.File]::ReadAllText($log) } else { '' }
        Check 'e2e' 'clean shutdown logged' (($logText -match 'serve stop \(stop\)') -and ($logText -match 'supervisor exit')) ''
        Check 'e2e' 'no restart loop' (-not ($logText -match 'serve restart #')) ''
      }
      finally {
        if ($child -and -not $child.HasExited) { try { $child.Kill() } catch { } }
      }
    }
  }
}
finally {
  # Restore the clipboard while capture is still paused: whatever is left on the clipboard
  # is recorded by the resident as soon as capture resumes, so it must not be test junk.
  if ($clipBak) { [void](Set-Clip $clipBak) } else { [void](Set-Clip '') }
  if ($wePaused) { [void](& powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $clipPs1 resume 2>&1) }
  try { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

$script:results | Format-Table -AutoSize -Wrap | Out-String -Width 160 | Write-Output

$pass = @($script:results | Where-Object { $_.Result -eq 'PASS' }).Count
$fail = @($script:results | Where-Object { $_.Result -eq 'FAIL' }).Count
$skipped = @($script:results | Where-Object { $_.Result -eq 'SKIP' }).Count
Write-Output ('TOTAL ' + $script:results.Count + '   PASS ' + $pass + '   FAIL ' + $fail + '   SKIP ' + $skipped)
if ($fail -gt 0) { exit 1 }
exit 0

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
  [switch]$E2E,
  # directory holding clipboard.ps1 + lib + plugins + themes; default is this repo.
  # scripts\build.ps1 points it at the packaged copy to prove the minified code still behaves.
  [string]$Source = ''
)

$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$defaultSource = Join-Path $repoRoot 'src'
if (-not $Source) { $Source = $defaultSource }
if (-not (Test-Path -LiteralPath $Source)) { Write-Error ('no such -Source: ' + $Source); exit 2 }
$srcRoot = (Resolve-Path -LiteralPath $Source).Path
$clipPs1 = Join-Path $srcRoot 'clipboard.ps1'
if (-not (Test-Path -LiteralPath $clipPs1)) { Write-Error ('cannot find ' + $clipPs1); exit 2 }

if (-not ($Unit -or $Integration -or $E2E)) { $Unit = $true; $Integration = $true; $E2E = $true }

# A packaged copy has its internal function names minified, so the unit group (which calls
# them by name through -Library) cannot run against it - the CLI groups can.
$isPackaged = -not [string]::Equals($srcRoot.TrimEnd([char]92, [char]47), (Resolve-Path -LiteralPath $defaultSource).Path.TrimEnd([char]92, [char]47), [StringComparison]::OrdinalIgnoreCase)
if ($isPackaged) {
  if ($Unit) { Write-Output 'unit group skipped: a packaged copy has renamed internals' }
  $Unit = $false
  if (-not ($Integration -or $E2E)) { $Integration = $true }
}

$script:results = New-Object System.Collections.Generic.List[object]

# The version lives in package.ini. A development copy reads it at run time, a package
# carries it as a constant, so this is the number both of them have to report.
$programVersion = ''
$verFile = Join-Path $repoRoot 'package.ini'
if (Test-Path -LiteralPath $verFile) {
  # the key is Version=; .NET regex is case-sensitive, so the test reads it either way
  $verMatch = [regex]::Match([IO.File]::ReadAllText($verFile), '(?mi)^\s*version\s*=\s*(\S+)\s*$')
  if ($verMatch.Success) { $programVersion = $verMatch.Groups[1].Value }
}

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

# The drawing helpers take a Graphics plus plain values, so the unit group paints them onto
# a bitmap instead of needing a window. That needs the drawing assemblies loaded.
function Use-Drawing {
  foreach ($a in @('System.Drawing', 'System.Windows.Forms')) {
    try { Add-Type -AssemblyName $a -ErrorAction Stop } catch { }
  }
}

# A sandbox is a throw-away copy of the tool (script + lib + plugins + themes): the
# settings file sits next to the script, so DataDir= and the store stay inside the sandbox.
function New-Sandbox([string]$name) {
  $dir = Join-Path $tmpRoot $name
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Copy-Item -LiteralPath $clipPs1 -Destination $dir -Force
  foreach ($sub in @('lib', 'utils', 'schema', 'plugins', 'themes')) {
    $src = Join-Path $srcRoot $sub
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dir -Recurse -Force }
  }
  # the version lives in package.ini, one level above src\ in the repository and beside the
  # script in a sandbox - copying it keeps the sandbox reporting the real number
  $pkgIni = Join-Path $repoRoot 'package.ini'
  if (Test-Path -LiteralPath $pkgIni) { Copy-Item -LiteralPath $pkgIni -Destination $dir -Force }
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
# -Integration and -E2E run without dot-sourcing the tool, so the encoding the fixtures
# write with has to exist here instead of coming from the main script
$Utf8 = New-Object System.Text.UTF8Encoding $false

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

  # ------------------------------------------------------------ structure guards
  # The program is one entry file plus lib\ modules that are dot-sourced into a single
  # scope. These assertions keep that contract from decaying: a module must not derive
  # paths from its own location, must not take parameters, and must not redefine a name
  # another module already owns. They run for a packaged copy too, where the only extra
  # rule (sizes, the $Root line) would not survive renaming.
  $entryPath = Join-Path $srcRoot 'clipboard.ps1'
  $libPath = Join-Path $srcRoot 'lib'
  $utilsPath = Join-Path $srcRoot 'utils'
  $schemaPath = Join-Path $srcRoot 'schema'
  $libFiles = @()
  if (Test-Path -LiteralPath $libPath) { $libFiles = @(Get-ChildItem -LiteralPath $libPath -Filter '*.ps1' -File | Sort-Object -Property Name) }
  # the pure helpers and the schema files follow the same rules (no param block, no path
  # from their own file, no duplicate name, a line budget), so they are walked as well
  if (Test-Path -LiteralPath $utilsPath) { $libFiles += @(Get-ChildItem -LiteralPath $utilsPath -Filter '*.ps1' -File | Sort-Object -Property Name) }
  if (Test-Path -LiteralPath $schemaPath) { $libFiles += @(Get-ChildItem -LiteralPath $schemaPath -Filter '*.ps1' -File | Sort-Object -Property Name) }

  # the entry file names these by relative path; a package must carry all of them
  $requiredLib = @('lib\base', 'lib\native', 'lib\keyhook', 'lib\theme-stub',
    'lib\media', 'lib\clip', 'lib\store', 'lib\hotkey', 'lib\entry', 'lib\picker-geom', 'lib\anim',
    'lib\picker-draw', 'lib\pinlist', 'lib\preview', 'lib\picker', 'lib\serve', 'lib\diag', 'lib\shortcut',
    'lib\config', 'lib\usage', 'lib\dispatch',
    'utils\ini', 'utils\import', 'utils\schema', 'utils\log', 'utils\time', 'utils\format', 'utils\draw',
    'schema\clipboard', 'schema\theme')
  $missingLib = @()
  foreach ($m in $requiredLib) {
    if (-not (Test-Path -LiteralPath (Join-Path $srcRoot ($m + '.ps1')))) { $missingLib += $m }
  }
  Check 'struct' 'every required module exists' ($missingLib.Count -eq 0) ($missingLib -join ', ')

  # the plugin layer is three files; a package carries all of them or none (plugins.ps1 is
  # the optional one, and the other two mean nothing without it)
  $pluginLayer = @('plugins', 'plugin-settings', 'plugin-marks')
  $pluginPresent = @($pluginLayer | Where-Object { Test-Path -LiteralPath (Join-Path $libPath ($_ + '.ps1')) })
  Check 'struct' 'plugin layer ships complete' (($pluginPresent.Count -eq 0) -or ($pluginPresent.Count -eq $pluginLayer.Count)) ($pluginPresent -join ', ')

  $badParse = @()
  $badParam = @()
  $badPath = @()
  foreach ($f in $libFiles) {
    $tk = $null
    $pe = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tk, [ref]$pe)
    if ($pe.Count -gt 0) { $badParse += ($f.Name + ': ' + $pe[0].Message); continue }
    if ($ast.ParamBlock) { $badParam += $f.Name }
    # $PSScriptRoot inside lib\ points at lib\, so any path built from it is one level
    # deep. Look at the code, not at the prose: the module headers explain this rule.
    $selfPaths = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and [string]$node.VariablePath.UserPath -match '(?i)(^|:)(PSScriptRoot|PSCommandPath)$' }, $true))
    if ($selfPaths.Count -gt 0) { $badPath += $f.Name }
  }
  Check 'struct' 'every module parses' ($badParse.Count -eq 0) ($badParse -join '; ')
  Check 'struct' 'modules declare no param block' ($badParam.Count -eq 0) ($badParam -join ', ')
  Check 'struct' 'modules never derive paths from their own file' ($badPath.Count -eq 0) ($badPath -join ', ')

  # a duplicate top-level name lets one module silently overwrite another (shared scope);
  # theme-stub.ps1 is the documented exception - lib/themes.ps1 replaces its stubs
  $owner = @{}
  $dups = @()
  foreach ($f in @(Get-Item -LiteralPath $entryPath) + $libFiles) {
    $tk = $null
    $pe = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tk, [ref]$pe)
    if ($pe.Count -gt 0 -or -not $ast.EndBlock) { continue }
    foreach ($st in $ast.EndBlock.Statements) {
      if ($st -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
      $fnName = [string]$st.Name
      if (-not $owner.ContainsKey($fnName)) { $owner[$fnName] = $f.Name; continue }
      $prevOwner = [string]$owner[$fnName]
      $both = @($prevOwner, $f.Name)
      if (($both -contains 'theme-stub.ps1') -and ($both -contains 'themes.ps1')) { continue }
      $dups += ($fnName + ' (' + $prevOwner + ', ' + $f.Name + ')')
    }
  }
  Check 'struct' 'no duplicate function names' ($dups.Count -eq 0) ($dups -join ', ')

  # A WH_KEYBOARD_LL hook outlives the panel's own teardown and swallows every key in the
  # system, so it has to be released from a finally block: releasing it after the message
  # loop means one exception on the way out leaves the keyboard dead.
  $pickerText = [IO.File]::ReadAllText((Join-Path $srcRoot 'lib\picker.ps1'))
  Check 'struct' 'no whole-window opacity transition' (-not ($pickerText -match '\$form\.Opacity\s*=')) ''

  # A payload kind is a leading character. Every module asks base.ps1's predicates instead of
  # comparing that character itself, so adding a kind stays a change in two files.
  $prefixFiles = @($libFiles | Where-Object { $_.Name -notin @('base.ps1', 'entry.ps1', 'media.ps1') })
  $prefixFiles += @(Get-ChildItem -LiteralPath (Join-Path $srcRoot 'plugins') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
  $offenders = @()
  foreach ($f in $prefixFiles) {
    if ([IO.File]::ReadAllText($f.FullName) -match '\[char\](1|3)\b') { $offenders += $f.Name }
  }
  Check 'struct' 'payload kinds go through the predicates' ($offenders.Count -eq 0) ($offenders -join ', ')

  # The panel layout and its timers are read from the two tables base.ps1 publishes, so a
  # theme or a tuning pass touches one place. A bare literal creeping back into the draw
  # code is how the row height and the hit test drifted apart before. The table names are
  # renamed in a package, so only the source can be checked.
  if (-not $isPackaged) {
    $metricRefs = [regex]::Matches($pickerText, '\$m\[').Count
    $timingRefs = [regex]::Matches($pickerText, '\$script:Timing\[').Count
    Check 'struct' 'row layout comes from the metric table' ($metricRefs -ge 12) ($metricRefs -as [string])
    Check 'struct' 'panel timers come from the timing table' ($timingRefs -ge 8) ($timingRefs -as [string])
  }
  if (-not $isPackaged) {
    # the packaged copy has its function names minified, so only the source can be checked
    $pickerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $srcRoot 'lib\picker.ps1'), [ref]$null, [ref]$null)
    $finallyText = (@($pickerAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true) |
        ForEach-Object { $_.Finally.Extent.Text }) -join "`n")
    Check 'struct' 'the key hook is released in a finally' ($finallyText -match 'Disable-KeyHook') ''
  }

  # sizes and the single $Root line only make sense in the readable source
  if (-not $isPackaged) {
    $entryLines = @([IO.File]::ReadAllLines($entryPath)).Count
    Check 'struct' 'entry file stays an entry point' ($entryLines -le 200) ([string]$entryLines + ' lines')

    # the tooling lives outside src\: package.ini declares the commands, xpm runs them
    $tooling = @('package.ini', 'xpm.ps1', 'xpm.cmd', 'xpm', 'build.ini',
      'scripts\build.ps1', 'scripts\minify.ps1', 'scripts\dev.ps1', 'scripts\test.ps1', 'scripts\shot.ps1')
    $missingTool = @()
    foreach ($tool in $tooling) {
      if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $tool))) { $missingTool += $tool }
    }
    Check 'struct' 'the tooling ships with the repo' ($missingTool.Count -eq 0) ($missingTool -join ', ')
    $pkgText = ''
    if (Test-Path -LiteralPath (Join-Path $repoRoot 'package.ini')) { $pkgText = [IO.File]::ReadAllText((Join-Path $repoRoot 'package.ini')) }
    # keys are PascalCase: [package] holds Name/Version, [scripts] holds one key per command
    $scriptBlock = ''
    $sm = [regex]::Match($pkgText, '(?ms)^\s*\[scripts\]\s*$(.*?)(?=^\s*\[|\z)')
    if ($sm.Success) { $scriptBlock = $sm.Groups[1].Value }
    $noCmd = @()
    foreach ($cmd in @('Dev', 'Build', 'Test', 'Shot')) {
      if (-not ($scriptBlock -match ('(?m)^' + $cmd + '=\S'))) { $noCmd += $cmd }
    }
    Check 'struct' 'package.ini declares every command' (($pkgText -match '(?m)^Name=\S') -and ($pkgText -match '(?m)^Version=\d+\.\d+\.\d+') -and $noCmd.Count -eq 0) ($noCmd -join ', ')
    # every tracked ini follows the shared convention: lower case section names, PascalCase keys
    $badIni = @()
    foreach ($iniRel in @('package.ini', 'build.ini', 'src\themes\win11-dark.ini', 'src\themes\win11-light.ini')) {
      $iniFile = Join-Path $repoRoot $iniRel
      if (-not (Test-Path -LiteralPath $iniFile)) { $badIni += ($iniRel + ': missing'); continue }
      foreach ($line in [IO.File]::ReadAllLines($iniFile)) {
        $l = $line.Trim()
        if ($l.Length -eq 0 -or $l.StartsWith('#') -or $l.StartsWith(';')) { continue }
        if ($l.StartsWith('[')) {
          if ($l -cnotmatch '^\[[a-z-]+\]$') { $badIni += ($iniRel + ': ' + $l) }
          continue
        }
        if ($l -cnotmatch '^[A-Z][A-Za-z0-9]*=') { $badIni += ($iniRel + ': ' + $l) }
      }
    }
    Check 'struct' 'ini files use lower case sections and PascalCase keys' ($badIni.Count -eq 0) ($badIni -join ', ')
    $huge = @()
    foreach ($f in $libFiles) {
      $count = @([IO.File]::ReadAllLines($f.FullName)).Count
      if ($count -gt 1400) { $huge += ($f.Name + '(' + $count + ')') }
    }
    Check 'struct' 'no module grows past 1400 lines' ($huge.Count -eq 0) ($huge -join ', ')
    $rootHits = ([regex]::Matches([IO.File]::ReadAllText($entryPath), '(?m)^\$Root = Split-Path -Parent \$PSCommandPath\s*$')).Count
    Check 'struct' 'tool root is computed once, in the entry' ($rootHits -eq 1) ([string]$rootHits + ' occurrence(s)')

    # The panel must never take the foreground: a low-level keyboard hook feeds its controls
    # instead (lib/keyhook.ps1), so the user's window keeps the focus and the caret. The
    # takeover fallback (no hook, or an IME) still hands the foreground back on close.
    $pickerText = [IO.File]::ReadAllText((Join-Path $libPath 'picker.ps1'))
    Check 'struct' 'panel is shown without ShowDialog' (-not ($pickerText -match '\$form\.ShowDialog\(')) 'form.ShowDialog found'
    $topHits = ([regex]::Matches($pickerText, '(?m)^\s*\$form\.TopMost\s*=')).Count
    Check 'struct' 'panel is raised without the TopMost property' ($topHits -eq 0) ([string]$topHits + ' assignment(s)')
    $showHits = ([regex]::Matches($pickerText, '(?m)^\s*\$form\.Show\(\)\s*$')).Count
    Check 'struct' 'panel is shown once, non-modally' ($showHits -eq 1) ([string]$showHits + ' call(s)')
    $winText = [IO.File]::ReadAllText((Join-Path $libPath 'native.ps1'))
    Check 'struct' 'the panel form never activates' (($winText -match 'ShowWithoutActivation') -and ($winText -match '0x08000000')) 'no-activate override missing'
    Check 'struct' 'panel hands the foreground back when it closes' ($pickerText -match 'SetForegroundWindow\(\$prev\)') 'restore call missing'
    Check 'struct' 'panel installs and removes the key hook' (($pickerText -match 'Enable-KeyHook') -and ($pickerText -match 'Disable-KeyHook')) 'hook calls missing'
    # the rows are painted by Cb.PinList, which has no Items collection: a leftover
    # $lst.Items.Count silently reads 0 and the row never repaints
    Check 'struct' 'panel reads the list through its own members' (-not ($pickerText -match '\$lst\.Items\b')) '$lst.Items found'
    Check 'struct' 'paste releases the key hook before injecting' (($pickerText -match '(?s)function Paste-Clip\s*\{.{0,400}Disable-KeyHook')) 'Disable-KeyHook missing before SendKeys'
    # A drop-down that outlives the panel keeps the menu filter WinForms installed for it,
    # and that filter eats every later click of the process: whichever path closes the panel
    # has to close the menu first, and a click on the open menu is never a click outside.
    Check 'struct' 'panel closes the menu before it closes itself' ($pickerText -match '(?s)Add_FormClosing\(\{.{0,600}\$cm\.Close\(\)') 'menu not closed in FormClosing'
    Check 'struct' 'an open menu never counts as a click outside' ($pickerText -match '\$cm\.Visible[^\r\n]*-and -not \$form\.Bounds') 'outside-click check ignores the menu'
    # per-open GDI handles: the group heading font and the rounded region the form paints with
    Check 'struct' 'panel releases its menu font and form region' (($pickerText -match 'groupFont\.Dispose\(\)') -and ($pickerText -match 'function Set-RoundRegion')) 'GDI handles released nowhere'
    # hover is a card that waits and is prepared once, not a tooltip rebuilt on every move
    Check 'struct' 'hover shows a card, not a tooltip' (-not ($pickerText -match 'Windows\.Forms\.ToolTip')) 'ToolTip found in the picker'
    # an activating popup deactivates the window the user came from; Explorer's address bar and
    # search box collapse then, and the paste that follows lands nowhere
    Check 'struct' 'the context menu never takes the foreground' ($pickerText -match '(?s)\[void\]\$cm\.Handle.{0,200}0x08000000') 'menu activation guard missing'
    Check 'struct' 'the card waits for the cursor to rest' ($pickerText -match 'PvIdx[^\r\n]*PvAt') 'no hover rest timer'

    # the Shown handler must go through Focus-Search: taking the real focus there would
    # activate the panel and defeat the hook model
    $tk = $null
    $pe = $null
    $pickerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $libPath 'picker.ps1'), [ref]$tk, [ref]$pe)
    $shownBlocks = @($pickerAst.FindAll({
          param($node)
          $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
          [string]$node.Member.Value -eq 'Add_Shown' -and $node.Arguments.Count -gt 0
        }, $true))
    $shownFocus = 0
    $shownPaint = 0
    $shownHelper = 0
    foreach ($b in $shownBlocks) {
      $text = $b.Arguments[0].Extent.Text
      if ($text -match '\.Focus\(') { $shownFocus++ }
      if ($text -match 'SearchFocus\s*=\s*\$true') { $shownPaint++ }
      if ($text -match 'Focus-Search') { $shownHelper++ }
    }
    Check 'struct' 'the Shown handler never takes the real focus' ($shownBlocks.Count -eq 1 -and $shownFocus -eq 0) ([string]$shownBlocks.Count + ' handler(s), ' + [string]$shownFocus + ' Focus call(s)')
    Check 'struct' 'the Shown handler asks Focus-Search' ($shownHelper -eq 1) ([string]$shownHelper + ' call(s)')
    Check 'struct' 'the Shown handler paints the search box active' ($shownPaint -eq 1) ([string]$shownPaint + ' mark(s)')
  }

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

    # hover preview: the payload is clamped before it is split, so the card costs the same
    # whatever the size of the entry is
    $pvLines = Get-PreviewLines ((('line ' + [Environment]::NewLine) * 4000)) 40 6
    Check 'unit' 'preview fills the card and marks the rest' ($pvLines.Count -eq 6 -and $pvLines[5] -eq '...') ([string]$pvLines.Count + ' lines, last=' + $pvLines[5])
    $pvCut = Get-PreviewLines ('x' * 500) 20 2
    Check 'unit' 'preview cuts a long line to the card width' ($pvCut.Count -eq 1 -and $pvCut[0].Length -eq 20 -and $pvCut[0].EndsWith('...')) ([string]$pvCut[0].Length)
    $pvInfo = Get-PreviewInfo ('a' * 9000)
    Check 'unit' 'preview counts the clamped head' ($pvInfo -match '6000\+ chars') $pvInfo
    # PreviewChars is a setting now, so the card really reads only that much
    $savedChars = $script:PreviewChars
    $script:PreviewChars = 200
    $pvSmall = Get-PreviewLines ('y' * 900) 60 4
    Check 'unit' 'PreviewChars bounds what the card reads' ($pvSmall.Count -eq 1 -and $pvSmall[0].Length -eq 60 -and $pvSmall[0].EndsWith('...')) ([string]$pvSmall.Count)
    $script:PreviewChars = $savedChars
    $pvFiles = Get-PreviewLines $files 60 3
    Check 'unit' 'preview names the files of a file list' ($pvFiles[0] -match '\[files\]' -and $pvFiles[0] -match 'a.txt') $pvFiles[0]

    # config file
    $cfg = Join-Path $unitDir 'clipboard.ini'
    if (Test-Path -LiteralPath $cfg) { Remove-Item -LiteralPath $cfg -Force }
    $written = Write-IniTemplate
    Check 'unit' 'Write-IniTemplate creates file' (Test-Path -LiteralPath $written) $written
    $template = [IO.File]::ReadAllText($written)
    Check 'unit' 'template has defaults' (($template -match 'Hotkey=Ctrl\+Alt\+V') -and ($template -match 'MaxItems=300')) ''

    $lines = @('# hash comment', '; semi comment', 'Hotkey=Ctrl+Shift+F9', 'Theme = light ', 'Quoted="a b"', 'Garbage', 'MaxItems=7')
    [IO.File]::WriteAllLines($cfg, $lines, $Utf8)
    $kv = Read-Ini
    Check 'unit' 'Read-Ini skips comments' (-not $kv.ContainsKey('# hash comment')) ''
    Check 'unit' 'Read-Ini trims value' ($kv['Theme'] -eq 'light') ('Theme=' + $kv['Theme'])
    Check 'unit' 'Read-Ini strips quotes' ($kv['Quoted'] -eq 'a b') ('Quoted=' + $kv['Quoted'])
    Check 'unit' 'Read-Ini skips malformed' (-not $kv.ContainsKey('Garbage')) ''
    Check 'unit' 'Read-Ini keeps number' ($kv['MaxItems'] -eq '7') ('MaxItems=' + $kv['MaxItems'])
    Check 'unit' 'Read-Ini reads hotkey' ($kv['Hotkey'] -eq 'Ctrl+Shift+F9') ('Hotkey=' + $kv['Hotkey'])

    # every .ini follows one rule: "[a]" + "b=1" is the same key as "a.b=1", written flat
    [IO.File]::WriteAllLines($cfg, @('Theme=win11-dark', '[item-marks]', 'MaxPins=50', 'StickyPins=1'), $Utf8)
    $kv = Read-Ini
    Check 'unit' 'a section prefixes the keys that follow' (($kv['item-marks.MaxPins'] -eq '50') -and ($kv['item-marks.StickyPins'] -eq '1') -and ($kv['Theme'] -eq 'win11-dark')) ($kv['item-marks.MaxPins'])
    [void](Set-IniKey 'item-marks.MaxPins' '7')
    $secText = [IO.File]::ReadAllText($cfg)
    Check 'unit' 'a grouped key is rewritten inside its section' (($secText -match '(?m)^\[item-marks\]\r?$') -and ($secText -match '(?m)^MaxPins=7\r?$') -and (-not ($secText -match '(?m)^item-marks\.MaxPins='))) $secText.Trim()
    $kv = Read-Ini
    Check 'unit' 'the rewritten key reads back' ($kv['item-marks.MaxPins'] -eq '7') ($kv['item-marks.MaxPins'])

    # one engine for every .ini: a parse is cached per file and re-used until the file changes
    [IO.File]::WriteAllLines($cfg, @('MaxItems=11'), $Utf8)
    $firstRead = Read-Ini
    $secondRead = Read-Ini
    Check 'unit' 'an unchanged file is parsed once' ([object]::ReferenceEquals($firstRead, $secondRead)) ''
    # the length is the same as the value below, so only the write time tells them apart
    [IO.File]::WriteAllLines($cfg, @('MaxItems=12'), $Utf8)
    $external = Read-Ini
    Check 'unit' 'an external rewrite is noticed' ($external['MaxItems'] -eq '12') ('MaxItems=' + $external['MaxItems'])
    [void](Set-IniKey 'MaxItems' '13')
    $afterWrite = Read-Ini
    Check 'unit' 'a write through the engine is noticed' ($afterWrite['MaxItems'] -eq '13') ('MaxItems=' + $afterWrite['MaxItems'])
    # a repeated key keeps the last value; the file order is what the command list is drawn from
    $parsed = Read-IniDoc @('[pkg]', 'B=1', 'A=2', 'B=3')
    Check 'unit' 'a repeated key keeps the last value' ($parsed.Map['pkg.B'] -eq '3') ('B=' + $parsed.Map['pkg.B'])
    Check 'unit' 'the key order follows the file' (($parsed.Keys -join ',') -eq 'pkg.B,pkg.A') ($parsed.Keys -join ',')

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
    $rawHead = [IO.File]::ReadAllText($StoreFile)
    Check 'unit' 'the store starts with the tag and its layout version' ($rawHead.StartsWith($TAG + $RS + [string]$script:DataVersion)) ($rawHead.Substring(0, [Math]::Min(9, $rawHead.Length)) -replace [string][char]30, '<RS>')

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

    # a payload above BlobChars lives in its own file: the history keeps a reference, so the
    # rewrite a capture costs stays small, and the record still comes back whole
    $bigText = ('big line ' + [Environment]::NewLine) * 5000
    $blobList = New-Object System.Collections.Generic.List[object]
    $blobList.Add((New-Record $bigText $now 'p'))
    $blobList.Add((New-Record 'small tail' $now ''))
    Save-Records $blobList.ToArray()
    $rawStore = [IO.File]::ReadAllText($StoreFile, $Utf8)
    $blobFiles = @(Get-ChildItem -LiteralPath (Get-BlobDir) -Filter '*.txt' -ErrorAction SilentlyContinue)
    Check 'unit' 'a big payload leaves the history file' ((-not $rawStore.Contains('big line')) -and $blobFiles.Count -eq 1) ([string]$blobFiles.Count + ' blob(s), store ' + $rawStore.Length + ' chars')
    $back = @(Get-Records)
    Check 'unit' 'a big payload comes back whole' (($back.Count -eq 2) -and ($back[0].Payload -ceq $bigText) -and [string]$back[0].Blob) ([string]$back[0].Payload.Length)
    Save-Records @($back[1])
    $leftBlobs = @(Get-ChildItem -LiteralPath (Get-BlobDir) -Filter '*.txt' -ErrorAction SilentlyContinue)
    Check 'unit' 'a dropped record takes its blob with it' ($leftBlobs.Count -eq 0) ([string]$leftBlobs.Count + ' left')
    # BlobThreshold is a setting: 0 means every payload stays inline
    $savedBlob = $script:BlobChars
    $script:BlobChars = 100
    $inlineList = New-Object System.Collections.Generic.List[object]
    $inlineList.Add((New-Record ('z' * 400) $now ''))
    Save-Records $inlineList.ToArray()
    $inlineRaw = [IO.File]::ReadAllText($StoreFile, $Utf8)
    $inlineBlobs = @(Get-ChildItem -LiteralPath (Get-BlobDir) -Filter '*.txt' -ErrorAction SilentlyContinue)
    Check 'unit' 'BlobThreshold decides what leaves the file' ((-not $inlineRaw.Contains('zzzz')) -and $inlineBlobs.Count -eq 1) ([string]$inlineBlobs.Count + ' blob(s)')
    $script:BlobChars = $savedBlob
    # the four new settings are real schema entries with the shipped defaults
    $sch = $script:IniSchema
    Check 'unit' 'preview and blob settings carry defaults' (($sch['PreviewHover'].Default -eq 1) -and ($sch['PreviewDelay'].Default -eq 350) -and ($sch['PreviewChars'].Default -eq 6000) -and ($sch['BlobThreshold'].Default -eq 32768)) ''
    Check 'unit' 'media settings carry defaults' (($sch['CaptureImages'].Default -eq 1) -and ($sch['MaxImageBytes'].Default -eq 8388608) -and ($sch['CaptureRich'].Default -eq 1) -and ($sch['MaxRichBytes'].Default -eq 524288) -and ($sch['PasteRich'].Default -eq 1) -and ($sch['MaxMediaTotal'].Default -eq 67108864)) ''

    # ------------------------------------------------------- images and rich text
    # 1x1 transparent PNG: the bytes are what makes the identity, so any picture works
    $png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')
    $p1 = New-ImagePayload $png 1 1 'PNG'
    $p2 = New-ImagePayload $png 1 1 'PNG'
    Check 'unit' 'an image payload is derived from its bytes' ($p1.Length -gt 0 -and $p1[0] -eq [char]3 -and $p1 -ceq $p2) $p1
    $iref = Get-ImageRef $p1
    Check 'unit' 'an image payload parses back' (($null -ne $iref) -and $iref.W -eq 1 -and $iref.H -eq 1 -and $iref.Bytes -eq $png.Length -and $iref.Sha1.Length -eq 40) ''
    Check 'unit' 'a text payload is not an image' (-not (Test-ImagePayload 'hello')) ''
    Check 'unit' 'an image row says what it is' ((Get-ItemLabel $p1 $true) -like '[[]image] 1x1*PNG*') (Get-ItemLabel $p1 $true)
    Check 'unit' 'an image entry has its own kind' ((Get-EntryKind $p1) -eq 'image') (Get-EntryKind $p1)
    Check 'unit' 'byte sizes read like sizes' (((Format-Size 512) -eq '512 B') -and ((Format-Size 2048) -eq '2 KB') -and ((Format-Size 2411724) -eq '2.3 MB')) (Format-Size 2411724)

    [void](Write-ImageMedia $p1 $png)
    Check 'unit' 'an image lands in the media folder' (Test-Path -LiteralPath (Get-MediaPath $iref.Sha1 'png')) ''
    [void](Write-ImageMedia $p1 $png)
    Check 'unit' 'the same picture is stored once' (@(Get-ChildItem -LiteralPath (Get-MediaDir) -Filter '*.png').Count -eq 1) ([string]@(Get-ChildItem -LiteralPath (Get-MediaDir) -Filter '*.png').Count)
    $imgRec = New-Record $p1 $now ''
    Check 'unit' 'a record knows its media weight' ((Get-RecordMediaBytes $imgRec) -eq $png.Length) ([string](Get-RecordMediaBytes $imgRec))

    $richRtf = '{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Segoe UI;}}\f0\fs24\b bold title\b0\par second line\par third line\par}'
    $richCap = @{ Html = $Utf8.GetBytes('<html><body><p>hi</p></body></html>'); Rtf = $richRtf }
    $rref = New-RichRef $richCap
    Check 'unit' 'a rich reference is stable' (($rref -ceq (New-RichRef $richCap)) -and $rref.StartsWith('R:')) $rref
    $rr = Get-RichRef $rref
    Check 'unit' 'a rich reference parses back' (($null -ne $rr) -and $rr.Bytes -gt 0) $rref
    [void](Write-RichMedia $rref $richCap)
    Check 'unit' 'formatted text comes back as stored' (((Read-RichRtf $rref) -eq $richRtf) -and ((Read-RichHtml $rref).Length -eq $richCap.Html.Length)) ''
    # the card draws the document into a bitmap: an empty one would mean the layout never ran
    $renderFont = New-Object Drawing.Font 'Segoe UI', 10.5
    $richBmp = Get-RichPreviewBitmap $rref 380 200 $renderFont ([Drawing.Color]::White)
    $richInk = 0
    if ($null -ne $richBmp) { $richInk = Get-InkBottom $richBmp ([Drawing.Color]::White) }
    Check 'unit' 'formatted text paints into the card' (($null -ne $richBmp) -and ($richBmp.Width -eq 380) -and ($richInk -gt 20) -and ($richInk -le 200)) ([string]$richInk + ' px of ink')
    $richAgain = Get-RichPreviewBitmap $rref 380 200 $renderFont ([Drawing.Color]::White)
    Check 'unit' 'a painted page is reused' ([object]::ReferenceEquals($richBmp, $richAgain)) ''
    Clear-MediaCache
    $richRec = New-Record 'hi there' $now ''
    $richRec.Rich = $rref
    Check 'unit' 'a formatted row says so' ((Get-RecordLabel $richRec $true) -eq '[rich] hi there') (Get-RecordLabel $richRec $true)

    # the card knows all three kinds, and a missing media file degrades to a message
    $pcImg = Get-PreviewContent $imgRec 40 6
    Check 'unit' 'the card knows an image' ($pcImg.Kind -eq 'image' -and $pcImg.Ref -and ($pcImg.Head -like 'image - 1x1*')) ([string]$pcImg.Kind + ' / ' + [string]$pcImg.Head)
    $pcRich = Get-PreviewContent $richRec 40 6
    Check 'unit' 'the card knows formatted text' ($pcRich.Kind -eq 'rich' -and ($pcRich.Head -like 'formatted -*') -and $pcRich.Lines.Count -gt 0) ([string]$pcRich.Head)
    $pcText = Get-PreviewContent (New-Record 'plain body' $now '') 40 6
    Check 'unit' 'the card still knows plain text' ($pcText.Kind -eq 'text' -and $pcText.Lines.Count -eq 1) ([string]$pcText.Kind)

    # CF_HTML keeps byte offsets into its own buffer: the fragment has to come out exactly
    $fragText = '<p>inside</p>'
    $fragBytes = [Text.Encoding]::UTF8.GetBytes($fragText)
    $stub = 'Version:0.9' + "`r`n" + 'StartHTML:0000000000' + "`r`n" + 'EndHTML:0000000000' + "`r`n" + 'StartFragment:0000000000' + "`r`n" + 'EndFragment:0000000000' + "`r`n"
    $fragAt = $Utf8.GetByteCount($stub)
    $fragEnd = $fragAt + $fragBytes.Length
    $cfHtml = 'Version:0.9' + "`r`n" + ('StartHTML:' + ([string]$fragAt).PadLeft(10, [char]48)) + "`r`n" + ('EndHTML:' + ([string]$fragEnd).PadLeft(10, [char]48)) + "`r`n" + ('StartFragment:' + ([string]$fragAt).PadLeft(10, [char]48)) + "`r`n" + ('EndFragment:' + ([string]$fragEnd).PadLeft(10, [char]48)) + "`r`n" + $fragText
    Check 'unit' 'cf_html offsets select the fragment' ((Get-HtmlText ($Utf8.GetBytes($cfHtml))) -eq 'inside') (Get-HtmlText ($Utf8.GetBytes($cfHtml)))
    Check 'unit' 'html is read as words when there is no rtf' ((Get-HtmlText ($Utf8.GetBytes('<p>a &amp; b</p><p>c</p>'))) -eq ("a & b`nc")) (Get-HtmlText ($Utf8.GetBytes('<p>a &amp; b</p><p>c</p>')))

    # store round trip: the extra field carries the reference, the bytes stay out of the file
    $mixList = New-Object System.Collections.Generic.List[object]
    $mixList.Add($imgRec)
    $mixList.Add($richRec)
    $mixList.Add((New-Record 'plain' $now ''))
    Save-Records $mixList.ToArray()
    $mixBack = @(Get-Records)
    Check 'unit' 'an image record survives a save' (($mixBack.Count -eq 3) -and ([string]$mixBack[0].Payload -ceq $p1)) ([string]$mixBack.Count)
    Check 'unit' 'a rich reference survives a save' ([string]$mixBack[1].Rich -ceq $rref) ([string]$mixBack[1].Rich)
    Check 'unit' 'a plain record has no rich reference' (-not [string]$mixBack[2].Rich) ([string]$mixBack[2].Rich)
    Check 'unit' 'the image type letter is written' (([IO.File]::ReadAllText($StoreFile)).Contains($RS + 'i')) ''
    Check 'unit' 'pixels never enter the history file' (-not ([IO.File]::ReadAllText($StoreFile)).Contains('PNG' + [string][char]1)) ''

    # the clipboard itself: an image goes back as an image, formatted text keeps its formats
    if (Set-ClipItem $p1) {
      $hasImage = $false
      try { $hasImage = [Windows.Forms.Clipboard]::ContainsImage() } catch { }
      Check 'unit' 'an image goes back to the clipboard' $hasImage ''
      $capBack = Get-ClipCapture
      $sameImage = ($null -ne $capBack.Image) -and ((New-ImagePayload $capBack.Image.Png $capBack.Image.W $capBack.Image.H $capBack.Image.Fmt) -ceq $p1)
      Check 'unit' 'a captured image is the same picture' $sameImage ''
    } else {
      Check 'unit' 'an image goes back to the clipboard' $false 'set image failed'
    }
    if (Set-ClipItem 'hi there' $rref) {
      $capRich = Get-ClipCapture
      Check 'unit' 'formatted text keeps its formats on the clipboard' (($null -ne $capRich.Rich) -and [string]$capRich.Text -eq 'hi there') ''
    } else {
      Check 'unit' 'formatted text keeps its formats on the clipboard' $false 'set formatted text failed'
    }

    # a big picture: the card scales it down once and keeps a small copy beside it
    $bigBmp = New-Object Drawing.Bitmap 1600, 900
    $bgfx = [Drawing.Graphics]::FromImage($bigBmp)
    $bgfx.Clear([Drawing.Color]::Teal)
    $bgfx.Dispose()
    $bmStream = New-Object IO.MemoryStream
    $bigBmp.Save($bmStream, [Drawing.Imaging.ImageFormat]::Png)
    $bigBmp.Dispose()
    $bigPng = $bmStream.ToArray()
    $bigPay = New-ImagePayload $bigPng 1600 900 'PNG'
    [void](Write-ImageMedia $bigPay $bigPng)
    $bigRef = Get-ImageRef $bigPay
    Clear-MediaCache
    $card = Get-ImagePreviewBitmap $bigRef.Sha1 380 200
    $cardW = 0
    $cardH = 0
    if ($null -ne $card) { $cardW = $card.Width; $cardH = $card.Height }
    Check 'unit' 'a big picture is scaled into the card' (($null -ne $card) -and ($cardW -le 380) -and ($cardH -le 200) -and ($cardH -gt 100)) ([string]$cardW + 'x' + [string]$cardH)
    Check 'unit' 'the card leaves a small copy behind' (Test-Path -LiteralPath (Get-ImageThumbPath $bigRef.Sha1)) ''
    Clear-MediaCache
    $fromThumb = Get-ImagePreviewBitmap $bigRef.Sha1 380 200
    Check 'unit' 'the small copy renders the same picture' (($null -ne $fromThumb) -and ($fromThumb.Width -eq $cardW) -and ($fromThumb.Height -eq $cardH)) ''
    Clear-MediaCache
    $bigList = New-Object System.Collections.Generic.List[object]
    $bigList.Add((New-Record $bigPay $now ''))
    Save-Records $bigList.ToArray()
    Check 'unit' 'a thumbnail lives while its picture is referenced' (Test-Path -LiteralPath (Get-ImageThumbPath $bigRef.Sha1)) ''
    Save-Records @()
    Check 'unit' 'a thumbnail goes with its picture' ((-not (Test-Path -LiteralPath (Get-ImageThumbPath $bigRef.Sha1))) -and (-not (Test-Path -LiteralPath (Get-MediaPath $bigRef.Sha1 'png')))) ''

    # media is dropped with the record it belongs to
    Save-Records @($mixBack[2])
    Check 'unit' 'dropping an image removes its file' (-not (Test-Path -LiteralPath (Get-MediaPath $iref.Sha1 'png'))) ''
    $rSha = (Get-RichRef $rref).Sha1
    Check 'unit' 'dropping formatted text removes both sidecars' ((-not (Test-Path -LiteralPath (Get-MediaPath $rSha 'html'))) -and (-not (Test-Path -LiteralPath (Get-MediaPath $rSha 'rtf')))) ''

    # the media budget is counted apart from MaxTotal: pictures go first, text rows never do
    $savedMediaTotal = $script:MaxMediaTotal
    [void](Write-ImageMedia $p1 $png)
    $script:MaxMediaTotal = [long]10
    $budget = New-Object System.Collections.Generic.List[object]
    $budget.Add($imgRec)
    $budget.Add((New-Record 'a' $now ''))
    Trim-Records $budget
    Check 'unit' 'the media budget drops a picture over the cap' (($budget.Count -eq 1) -and ([string]$budget[0].Payload -eq 'a')) ([string]$budget.Count)
    $script:MaxMediaTotal = [long]($png.Length + 10)
    $budget2 = New-Object System.Collections.Generic.List[object]
    $budget2.Add($imgRec)
    $budget2.Add((New-Record 'a' $now ''))
    Trim-Records $budget2
    Check 'unit' 'the media budget keeps a picture under the cap' ($budget2.Count -eq 2) ([string]$budget2.Count)
    $script:MaxMediaTotal = $savedMediaTotal

    # a file whose header is not the current layout is not parsed, not overwritten and not
    # backed up by the reader: `migrate` is the only thing that may touch it
    [IO.File]::WriteAllText($StoreFile, ('CBHIST' + $RS + '0' + $RS + 't' + $US + [string]$now + $US + $US + 'old text'), $Utf8)
    $sv = Get-StoreVersion
    Check 'unit' 'an older layout is recognised, not read' (($sv.Kind -eq 'old') -and ($sv.Version -eq 0) -and (@(Get-Records).Count -eq 0)) ($sv.Kind + ' v' + $sv.Version)
    Add-Item 'must not overwrite'
    Check 'unit' 'an older layout is never overwritten' (([IO.File]::ReadAllText($StoreFile)).Contains('old text')) ''
    # the version is one constant, and it is what the panel and the CLI report
    Check 'unit' 'the program carries one version' ([string]$script:Version -match '^\d+\.\d+\.\d+$') ([string]$script:Version)

    # no other format support: a file without the CBHIST tag is ignored and left alone
    [IO.File]::WriteAllText($StoreFile, ('alpha' + $RS + 'beta'), $Utf8)
    $uv = Get-StoreVersion
    Check 'unit' 'unknown store format ignored' ((@(Get-Records).Count -eq 0) -and ($uv.Kind -eq 'unknown') -and ($uv.Version -eq -1)) ($uv.Kind + ' v' + $uv.Version)
    Check 'unit' 'unknown format is not backed up' (-not (Test-Path -LiteralPath (Join-Path $unitDir 'history.v1.bak'))) ''
    # a file that is newer than this build is reported, never downgraded
    [IO.File]::WriteAllText($StoreFile, ('CBHIST' + $RS + '9' + $RS + 't' + $US + [string]$now + $US + $US + 'future'), $Utf8)
    $nv = Get-StoreVersion
    Check 'unit' 'a newer layout is reported as newer' (($nv.Kind -eq 'newer') -and ($nv.Version -eq 9)) ($nv.Kind + ' v' + $nv.Version)
    [IO.File]::WriteAllText($StoreFile, '', $Utf8)

    # ---------------------------------------------------------------- migration
    Check 'unit' 'no file needs no migration' ((Invoke-DataMigration).Message -like 'no history file*') ''
    Save-Records @()
    Check 'unit' 'a current file needs no migration' ((Invoke-DataMigration).Message -like 'already CBHIST v*') (Invoke-DataMigration).Message
    # an older file with no step for it is refused, and -Purge archives it instead of guessing
    [IO.File]::WriteAllText($StoreFile, ('CBHIST' + $RS + '0' + $RS + 't' + $US + [string]$now + $US + $US + 'old text'), $Utf8)
    $mr = Invoke-DataMigration
    Check 'unit' 'a version with no step is refused' ((-not $mr.Changed) -and $mr.Message.StartsWith('[!]')) $mr.Message
    Check 'unit' 'a refused migration leaves the file' (([IO.File]::ReadAllText($StoreFile)).Contains('old text')) ''
    $mp = Invoke-DataMigration -Purge
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $unitDir 'data\backup') -Filter '*.dat' -ErrorAction SilentlyContinue)
    Check 'unit' 'purge archives an unreadable file' ($mp.Changed -and $backups.Count -eq 1 -and -not (Test-Path -LiteralPath $StoreFile)) ([string]$backups.Count + ' backup(s)')
    Check 'unit' 'the archived copy keeps the old bytes' (([IO.File]::ReadAllText($backups[0].FullName)).Contains('old text')) ''
    Save-Records @()
    Check 'unit' 'the store is writable again after a purge' (([IO.File]::ReadAllText($StoreFile)).StartsWith($TAG)) ''
    # a newer file is never touched, not even by -Purge
    [IO.File]::WriteAllText($StoreFile, ('CBHIST' + $RS + '9' + $RS + 't' + $US + [string]$now + $US + $US + 'future'), $Utf8)
    $mn = Invoke-DataMigration -Purge
    Check 'unit' 'a newer file is never touched' ((-not $mn.Changed) -and (([IO.File]::ReadAllText($StoreFile)).Contains('future'))) $mn.Message
    [IO.File]::WriteAllText($StoreFile, '', $Utf8)

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

    # ---------------------------------------------------------------- transitions
    $st = New-AnimState
    Check 'unit' 'anim starts at rest' (($st.Hover -eq 0) -and ($st.HoverTarget -eq 0) -and ($st.HoverIndex -eq -1)) ''
    Set-AnimHover $st 3
    Check 'unit' 'anim hover targets one row' (($st.HoverIndex -eq 3) -and ($st.HoverTarget -eq 1)) ''
    # a separate state, so the eased Hover value below still starts from rest
    $st2 = New-AnimState
    Set-AnimHover $st2 3
    Set-AnimHover $st2 4
    Check 'unit' 'anim hover remembers the row it left' (($st2.HoverIndex -eq 4) -and ($st2.PrevHoverIndex -eq 3)) ($st2.PrevHoverIndex -as [string])
    Set-AnimHover $st2 4
    Check 'unit' 'anim hover ignores a repeat' ($st2.PrevHoverIndex -eq 3) ''
    Set-AnimHover $st2 -1
    Check 'unit' 'leaving the list repaints the last row' (($st2.HoverIndex -eq -1) -and ($st2.PrevHoverIndex -eq 4)) ($st2.PrevHoverIndex -as [string])
    $mask = Invoke-AnimFrame $st 0.5
    Check 'unit' 'anim frame eases by a fraction' ((($mask -band 1) -ne 0) -and ($st.Hover -eq 0.5)) ($mask -as [string])
    $null = Invoke-AnimFrame $st 1.0
    Check 'unit' 'anim frame settles and then idles' (($st.Hover -eq 1) -and ((Invoke-AnimFrame $st 0.5) -eq 0)) ''
    Set-AnimTarget $st 'Hover' 0.0
    $null = Invoke-AnimFrame $st 0.995
    Check 'unit' 'anim frame snaps to the target when close' (($st.Hover -eq 0) -and ((Invoke-AnimFrame $st 0.5) -eq 0)) ($st.Hover -as [string])
    Set-AnimSelection $st 2
    Check 'unit' 'anim selection starts empty' (($st.SelIndex -eq 2) -and ($st.PrevSelIndex -eq -1) -and ($st.Sel -eq 0)) ''
    Set-AnimSelection $st 5
    Check 'unit' 'anim selection remembers the previous row' (($st.PrevSelIndex -eq 2) -and ($st.SelIndex -eq 5) -and ($st.Sel -eq 0)) ''
    Set-AnimSelection $st 5
    Check 'unit' 'anim selection ignores a repeat' ($st.PrevSelIndex -eq 2) ''
    $ac = Scale-Alpha ([Drawing.Color]::FromArgb(200, 10, 20, 30)) 0.5
    Check 'unit' 'Scale-Alpha halves the alpha' (($ac.A -eq 100) -and ($ac.R -eq 10) -and ($ac.B -eq 30)) ($ac.A -as [string])
    Check 'unit' 'Scale-Alpha keeps full strength' ((Scale-Alpha ([Drawing.Color]::FromArgb(200, 10, 20, 30)) 1.0).A -eq 200) ''
    Check 'unit' 'Scale-Alpha fades to nothing' ((Scale-Alpha ([Drawing.Color]::FromArgb(200, 10, 20, 30)) 0).A -eq 0) ''
    $abmp = New-Object Drawing.Bitmap 120, 40
    $agr = [Drawing.Graphics]::FromImage($abmp)
    try {
      $asel = [Drawing.Color]::FromArgb(60, 96, 205, 255)
      $ahov = [Drawing.Color]::FromArgb(30, 255, 255, 255)
      Draw-RowBackdrop $agr 0 0 120 40 4 $null $asel $ahov 0.0 0.0
      Check 'unit' 'row backdrop draws nothing at rest' ($abmp.GetPixel(60, 20).A -eq 0) $abmp.GetPixel(60, 20).ToString()
      Draw-RowBackdrop $agr 0 0 120 40 4 $null $asel $ahov 1.0 0.0
      Check 'unit' 'row backdrop draws the selection' (($abmp.GetPixel(60, 20).A -gt 0) -and ($abmp.GetPixel(60, 20).B -eq 255)) $abmp.GetPixel(60, 20).ToString()
      $tbmp = New-Object Drawing.Bitmap 60, 40
      $tgr = [Drawing.Graphics]::FromImage($tbmp)
      try {
        Draw-RowBackdrop $tgr 0 0 60 40 4 ([Drawing.Color]::FromArgb(255, 0, 255, 0)) $asel $ahov 0.0 0.0
        Check 'unit' 'row backdrop draws a tint' (($tbmp.GetPixel(30, 20).G -eq 255) -and ($tbmp.GetPixel(30, 20).R -eq 0)) $tbmp.GetPixel(30, 20).ToString()
      } finally { $tgr.Dispose(); $tbmp.Dispose() }
    } finally { $agr.Dispose(); $abmp.Dispose() }
    # the height is always chrome + whole rows, so raising the row count can never cut a row
    Check 'unit' 'Get-PanelHeight adds the chrome' ((Get-PanelHeight 10 40 110) -eq 510) ((Get-PanelHeight 10 40 110) -as [string])
    Check 'unit' 'Get-PanelHeight never trims below one row' ((Get-PanelHeight 0 40 110) -eq 150) ''
    Check 'unit' 'Get-RowFit floors the rows' ((Get-RowFit 510 40 110) -eq 10) ((Get-RowFit 510 40 110) -as [string])
    Check 'unit' 'Get-RowFit keeps one row in a tiny area' ((Get-RowFit 100 40 110) -eq 1) ''
    Check 'unit' 'Get-RowsForScreen caps by the screen' ((Get-RowsForScreen 50 510 40 110 3) -eq 10) ((Get-RowsForScreen 50 510 40 110 3) -as [string])
    Check 'unit' 'Get-RowsForScreen keeps the request when it fits' ((Get-RowsForScreen 5 510 40 110 3) -eq 5) ''
    Check 'unit' 'Get-RowsForScreen never goes below the floor' ((Get-RowsForScreen 50 200 40 110 3) -eq 3) ''
    Check 'unit' 'Get-RowsForScreen unknown screen keeps the rows' ((Get-RowsForScreen 7 0 40 110 3) -eq 7) ''
    Check 'unit' 'panel chrome is the header plus the footer' ((Get-PanelChrome) -eq ($script:Metric['HeadHeight'] + $script:Metric['FootHeight'] + 2)) ((Get-PanelChrome) -as [string])
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

    # ------------------------------------------------------------ sticky pins
    Check 'unit' 'StickyRowLimit honours the declared cap' ((Get-StickyRowLimit 10 3) -eq 3) ((Get-StickyRowLimit 10 3) -as [string])
    Check 'unit' 'StickyRowLimit 0 turns the feature off' ((Get-StickyRowLimit 10 0) -eq 0) ''
    Check 'unit' 'StickyRowLimit keeps one row for the results' ((Get-StickyRowLimit 10 -1) -eq 9) ((Get-StickyRowLimit 10 -1) -as [string])
    Check 'unit' 'StickyRowLimit clamps a cap larger than the area' ((Get-StickyRowLimit 2 5) -eq 1) ((Get-StickyRowLimit 2 5) -as [string])
    Check 'unit' 'StickyRowLimit needs room for a result row' ((Get-StickyRowLimit 1 3) -eq 0) ''
    # the same cap drives `config set`: it is what Rows leaves after one row for the results
    Check 'unit' 'StickyRowCap leaves one row for results' ((Get-StickyRowCap 10) -eq 9) ((Get-StickyRowCap 10) -as [string])
    Check 'unit' 'StickyRowCap has no room in a single row' ((Get-StickyRowCap 1) -eq 0) ''

    $stickyRows = @(
      (New-Record 'pinned one' 100 'p'),
      (New-Record 'pinned two' 99 'p'),
      (New-Record 'pinned three' 98 'p'),
      (New-Record 'alpha' 97 ''),
      (New-Record 'beta' 96 '')
    )
    # the search is a plain match: a pin that does not match is hidden like any other row
    $rows = @(Select-QueryRows $stickyRows @('alpha'))
    Check 'unit' 'the search hides an unmatched pin' (((@($rows) | ForEach-Object { $_.Payload }) -join '|') -eq 'alpha') ((@($rows) | ForEach-Object { $_.Payload }) -join '|')
    $rows = @(Select-QueryRows $stickyRows @())
    Check 'unit' 'no query shows every row' (@($rows).Count -eq 5) (@($rows).Count -as [string])
    # freezing is a scrolling behaviour: the leading run of pins is what stays put
    Check 'unit' 'sticky top counts the leading pins' ((Get-StickyTopRows $stickyRows 'p' 5) -eq 3) ((Get-StickyTopRows $stickyRows 'p' 5) -as [string])
    Check 'unit' 'sticky top obeys the declared cap' ((Get-StickyTopRows $stickyRows 'p' 2) -eq 2) ((Get-StickyTopRows $stickyRows 'p' 2) -as [string])
    Check 'unit' 'sticky top stops at the first plain row' ((Get-StickyTopRows @($stickyRows[0], $stickyRows[3], $stickyRows[1]) 'p' 5) -eq 1) ((Get-StickyTopRows @($stickyRows[0], $stickyRows[3], $stickyRows[1]) 'p' 5) -as [string])
    Check 'unit' 'sticky top is off without a mark' ((Get-StickyTopRows $stickyRows '' 5) -eq 0) ''
    Check 'unit' 'sticky top is off with a zero cap' ((Get-StickyTopRows $stickyRows 'p' 0) -eq 0) ''
    # the pin guard reads the same cap: the smaller of the sticky rows and what Rows leaves
    $stickyProbe = @{
      Name       = 'sticky-probe'
      Marks      = [ordered]@{ p = @{ Set = 'pin'; Unset = 'unpin'; Word = 'pinned'; Protected = $false } }
      SortMark   = 'p'
      StickyMark = 'p'
      StickyRows = 3
    }
    $script:Plugins = @($stickyProbe)
    Check 'unit' 'sticky cap is the declared sticky rows' ((Get-PluginStickyCap 10) -eq 3) ([string](Get-PluginStickyCap 10))
    Check 'unit' 'sticky cap shrinks with the visible rows' ((Get-PluginStickyCap 2) -eq 1) ([string](Get-PluginStickyCap 2))
    $stickyProbe['StickyRows'] = -1
    Check 'unit' 'a negative cap means every row but one' ((Get-PluginStickyCap 10) -eq 9) ([string](Get-PluginStickyCap 10))
    $stickyProbe['StickyRows'] = 0
    Check 'unit' 'sticky cap is off when the feature is off' ((Get-PluginStickyCap 10) -eq 0) ([string](Get-PluginStickyCap 10))
    $script:Plugins = @($markPlugin)
    $plan = Get-StickyPlan 10
    Check 'unit' 'sticky plan is off without plugins' (($plan.Mark -eq '') -and ($plan.Max -eq 0)) (($plan.Mark -as [string]) + '/' + ($plan.Max -as [string]))

    Check 'unit' 'Get-ItemLabel collapses newlines' ((Get-ItemLabel "a`r`nb" $false) -eq 'a b') (Get-ItemLabel "a`r`nb" $false)
    Check 'unit' 'Get-ItemLabel keeps marker' ((Get-ItemLabel "a`nb" $true) -eq 'a <NL> b') (Get-ItemLabel "a`nb" $true)
    $files5 = ([string][char]1) + "C:\x\a.txt`nC:\x\b.txt`nC:\x\c.txt`nC:\x\d.txt`nC:\x\e.txt"
    Check 'unit' 'Get-ItemLabel file count' ((Get-ItemLabel $files5 $true) -eq '[files] a.txt, b.txt, c.txt (+2)') (Get-ItemLabel $files5 $true)

    # ------------------------------------------------------------ config schema
    Check 'unit' 'Convert-IniValue bool on' ((Convert-IniValue 'ShowTime' 'on').Value -eq '1') ''
    Check 'unit' 'Convert-IniValue bool bad' (-not (Convert-IniValue 'ShowTime' 'maybe').Ok) ''
    Check 'unit' 'Convert-IniValue int ok' ((Convert-IniValue 'Rows' '12').Value -eq '12') ''
    Check 'unit' 'Convert-IniValue int too small' (-not (Convert-IniValue 'Rows' '1').Ok) ''
    Check 'unit' 'Convert-IniValue int too big' (-not (Convert-IniValue 'MaxItems' '999999999').Ok) ''
    Check 'unit' 'Convert-IniValue install flag' ((Convert-IniValue 'Autostart' 'off').Value -eq '0') ''
    Check 'unit' 'Convert-IniValue int not a number' (-not (Convert-IniValue 'MaxItems' 'many').Ok) ''
    Check 'unit' 'Convert-IniValue theme normalises case' ((Convert-IniValue 'Theme' 'WIN11-LIGHT').Value -eq 'win11-light') ''
    Check 'unit' 'Convert-IniValue enum bad' (-not (Convert-IniValue 'Theme' 'blue').Ok) ''
    Check 'unit' 'Convert-IniValue regex bad' (-not (Convert-IniValue 'ExcludePattern' '(').Ok) ''
    Check 'unit' 'Convert-IniValue hotkey bad' (-not (Convert-IniValue 'Hotkey' 'Ctrl+Nope').Ok) ''
    Check 'unit' 'Convert-IniValue list ok' ((Convert-IniValue 'Plugins' 'item-marks, extra').Value -eq 'item-marks,extra') ''
    Check 'unit' 'Convert-IniValue list rejects bad chars' (-not (Convert-IniValue 'Plugins' 'a b').Ok) ''
    Check 'unit' 'animations default on' ([string]$script:IniSchema['Animations'].Default -eq '1') ([string]$script:IniSchema['Animations'].Default)
    Check 'unit' 'Convert-IniValue unknown key' (-not (Convert-IniValue 'Nope' '1').Ok) ''

    # -------------------------------------------------------------------- themes
    $tn = @(Get-ThemeNames)
    Check 'unit' 'theme files discovered' (($tn -contains 'win11-dark') -and ($tn -contains 'win11-light')) ($tn -join ',')
    Check 'unit' 'theme matches by file name' ((Resolve-ThemeName 'win11-light') -eq 'win11-light') ''
    Check 'unit' 'theme name is case-insensitive' ((Resolve-ThemeName 'WIN11-DARK') -eq 'win11-dark') ''
    Check 'unit' 'theme alias is rejected' (-not (Convert-IniValue 'Theme' 'dark').Ok) ((Convert-IniValue 'Theme' 'dark').Error)
    Check 'unit' 'theme unknown falls back' ((Resolve-ThemeName 'nope') -eq 'win11-dark') ''
    Check 'unit' 'theme colour opaque' ((Convert-ThemeColor '#202020').R -eq 32) ''
    Check 'unit' 'theme colour alpha' ((Convert-ThemeColor '#1CFFFFFF').A -eq 28) ''
    Check 'unit' 'theme colour rejects junk' ($null -eq (Convert-ThemeColor 'red')) ''
    Check 'unit' 'missing theme file is null' ($null -eq (Read-Theme 'nosuch')) ''
    Check 'unit' 'Convert-IniValue theme ok' ((Convert-IniValue 'Theme' 'win11-light').Value -eq 'win11-light') ''
    Check 'unit' 'Convert-IniValue theme alias is rejected' (-not (Convert-IniValue 'Theme' 'light').Ok) ((Convert-IniValue 'Theme' 'light').Error)
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

    # [metrics] in a theme restyles the rows; the next theme starts from the built-in table
    # again, so an override cannot leak from one theme into another
    $probeTheme = Join-Path $unitDir 'themes\probe-metrics.ini'
    [IO.File]::WriteAllLines($probeTheme, @('name = probe-metrics', '[metrics]', 'TimeWidth = 60', 'RowGap = 4'), $Utf8)
    $script:Theme = 'probe-metrics'
    Apply-Theme
    Check 'unit' 'a theme can restyle row metrics' (($script:Metric['TimeWidth'] -eq 60) -and ($script:Metric['RowGap'] -eq 4)) ($script:Metric['TimeWidth'] -as [string])
    $script:Theme = 'win11-light'
    Apply-Theme
    $leaked = @()
    foreach ($k in @($script:MetricDefault.Keys)) {
      if ([int]$script:Metric[$k] -ne [int]$script:MetricDefault[$k]) { $leaked += $k }
    }
    Check 'unit' 'a theme without metrics restores the built-ins' ($leaked.Count -eq 0) ($leaked -join ', ')
    Remove-Item -LiteralPath $probeTheme -Force -ErrorAction SilentlyContinue
    $script:Theme = 'nosuch-theme'; Apply-Theme
    Check 'unit' 'unknown theme resolves to default' (($script:Theme -eq 'win11-dark') -and ((Get-UiPalette).Surface.ToArgb() -eq [Drawing.Color]::FromArgb(32, 32, 32).ToArgb())) $script:Theme

    $cfg = Join-Path $unitDir 'clipboard.ini'
    [IO.File]::WriteAllLines($cfg, @('# keep me', 'Theme=dark', 'MaxItems=7'), $Utf8)
    [void](Set-IniKey 'Theme' 'win11-light')
    [void](Set-IniKey 'ShowTime' '0')
    $iniText = [IO.File]::ReadAllText($cfg)
    Check 'unit' 'Set-IniKey replaces' ($iniText -match '(?m)^Theme=win11-light\r?$') ''
    Check 'unit' 'Set-IniKey appends' ($iniText -match '(?m)^ShowTime=0\r?$') ''
    Check 'unit' 'Set-IniKey keeps comments' ($iniText -match '# keep me') ''
    Check 'unit' 'Set-IniKey keeps other keys' ($iniText -match '(?m)^MaxItems=7\r?$') ''
    Check 'unit' 'Get-IniKey reads back' ((Get-IniKey 'Theme') -eq 'win11-light') (Get-IniKey 'Theme')

    Apply-Config
    Check 'unit' 'Apply-Config Theme' ($script:Theme -eq 'win11-light') $script:Theme
    Check 'unit' 'Apply-Config ShowTime=0' (-not $script:ShowTime) ''
    Check 'unit' 'Apply-Config MaxItems' ($MaxItems -eq 7) ($MaxItems -as [string])
    Check 'unit' 'install shortcuts default on' ($script:Autostart -and $script:DesktopShortcut) ''
    [IO.File]::WriteAllLines($cfg, @('Rows=1', 'MaxItems=0', 'Highlight=abc'), $Utf8)
    Apply-Config
    Check 'unit' 'Apply-Config rejects out of range' (($script:Rows -eq 10) -and ($MaxItems -eq 300) -and $script:HighlightOn) ('rows=' + $script:Rows + ' items=' + $MaxItems)

    # Apply-Config walks the schema, so a key with a Ref needs a Default and the variable it
    # points at has to end up holding that default whenever the file says nothing
    $noRef = @()
    $drifting = @()
    foreach ($k in @($script:IniSchema.Keys)) {
      $spec = $script:IniSchema[$k]
      if (-not $spec.Contains('Ref')) { continue }
      $slot = $spec['Ref']
      if (-not ($slot -is [System.Management.Automation.PSReference])) { $noRef += $k; continue }
      $def = $spec['Default']
      if ([string]$spec['Type'] -eq 'bool') { $def = ([int]$def -ne 0) }
      elseif ([string]$spec['Type'] -eq 'int' -and [string]$def -ne '') { $def = [int]$def }
      if ([string]$slot.Value -ne [string]$def) { $drifting += ($k + '=' + $slot.Value + '/' + $def) }
    }
    Check 'unit' 'every schema key points at a live variable' ($noRef.Count -eq 0) ($noRef -join ', ')
    Check 'unit' 'the applied values are the schema defaults' ($drifting.Count -eq 0) (($drifting | Select-Object -First 4) -join '; ')

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
    # a plugin's keys live in its own schema file: the sandbox root carries the real schema
    # folder, so this test plugin only adds one file to schema\plugins
    [IO.File]::WriteAllLines((Join-Path $unitDir 'schema\plugins\one.ps1'), @(
        "@{ Name = 'one'; File = 'clipboard.ini'; Description = 'test';",
        "   Properties = [ordered]@{ Flag = @{ Type = 'bool'; Default = 0; Description = 'test flag' } };",
        "   ThemeProperties = [ordered]@{ Tint = @{ Type = 'color'; Default = '#000000'; Description = 'themeable tint' } } }"), $Utf8)
    # a plugin's keys live in its own schema file: the sandbox root carries the real schema
    # folder, so this test plugin only adds one file to schema\plugins
    [IO.File]::WriteAllLines((Join-Path $unitDir 'schema\plugins\one.ps1'), @(
        "@{ Name = 'one'; File = 'clipboard.ini'; Description = 'test';";
        "   Properties = [ordered]@{ Flag = @{ Type = 'bool'; Default = 0; Description = 'test flag' } };";
        "   ThemeProperties = [ordered]@{ Tint = @{ Type = 'color'; Default = '#000000'; Description = 'themeable tint' } } }"), $Utf8)

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
    Check 'unit' 'shipped plugin off by default' (@(Load-Plugins (Join-Path $srcRoot 'plugins') @()).Count -eq 0) ''
    $real = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('entry-actions'))
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

    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('entry-actions'))
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

    # a plugin may build its menu items at load time, so one setting can produce several
    $script:Plugins = @(@{
        Name        = 'dyn'
        ContextMenu = { @(@{ Label = 'A'; Invoke = { param($r) } }, @{ Label = 'B'; Invoke = { param($r) } }) }
      })
    $dyn = @(Get-PluginActions)
    Check 'unit' 'ContextMenu may be a scriptblock' (($dyn.Count -eq 2) -and ($dyn[0]['Label'] -eq 'A') -and ($dyn[1]['Plugin'] -eq 'dyn')) ($dyn.Count -as [string])
    $script:Plugins = @(@{ Name = 'boom'; ContextMenu = { throw 'boom' } })
    Check 'unit' 'a broken menu scriptblock is skipped' (@(Get-PluginActions).Count -eq 0) ''
    $script:Plugins = @()

    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('item-marks'))
    $menuActs = @(Get-PluginActions)
    $allMarks = [pscustomobject]@{ Payload = 'x'; Time = 0; Marks = 'psh' }
    $noMarks = [pscustomobject]@{ Payload = 'x'; Time = 0; Marks = '' }
    Check 'unit' 'menu caption: every action resolves its own text' ((@($menuActs | ForEach-Object { Get-ActionText $_ $allMarks }) -join '|') -eq 'Remove pin|Remove star|Clear highlight') (@($menuActs | ForEach-Object { Get-ActionText $_ $allMarks }) -join '|')
    Check 'unit' 'menu caption: plain labels for an unmarked row' ((@($menuActs | ForEach-Object { Get-ActionText $_ $noMarks }) -join '|') -eq 'Pin to top|Star|Highlight') (@($menuActs | ForEach-Object { Get-ActionText $_ $noMarks }) -join '|')
    Check 'unit' 'menu caption: static label wins over the fallback' ((Get-ActionText @{ Label = 'Open' } $null) -eq 'Open') ''
    Check 'unit' 'menu caption: missing label falls back' ((Get-ActionText @{} $null) -eq 'Plugin action') ''
    Check 'unit' 'menu caption: a throwing label falls back' ((Get-ActionText @{ Label = { throw 'boom' } } $null) -eq 'Plugin action') ''
    Check 'unit' 'menu actions carry their owner' ((@($menuActs | ForEach-Object { $_['Plugin'] } | Select-Object -Unique) -join ',') -eq 'item-marks') (@($menuActs | ForEach-Object { $_['Plugin'] } | Select-Object -Unique) -join ',')

    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('transform'))
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
    Check 'unit' 'transform lists every mode by default' (($tActs.Count -eq 7) -and ($tActs[0]['Plugin'] -eq 'transform')) ($tActs.Count -as [string])
    $tMenu = $tActs[0]
    Check 'unit' 'transform menu caption names the mode' ((Get-ActionText $tMenu ([pscustomobject]@{ Payload = 'Hello World'; Marks = '' })) -eq 'Transform as plain text') (Get-ActionText $tMenu ([pscustomobject]@{ Payload = 'Hello World'; Marks = '' }))
    Check 'unit' 'transform menu shows for text rows' ((Test-PluginAction $tMenu ([pscustomobject]@{ Payload = 'Hello World'; Marks = '' })) -eq $true) ''
    Check 'unit' 'transform menu hides for file lists' ((Test-PluginAction $tMenu ([pscustomobject]@{ Payload = (([string][char]1) + 'C:\a.txt'); Marks = '' })) -eq $false) ''
    Check 'unit' 'transform menu hides an empty row' ((Test-PluginAction $tMenu ([pscustomobject]@{ Payload = ''; Marks = '' })) -eq $false) ''
    Check 'unit' 'transform menu skips a null row' ((Test-PluginAction $tMenu $null) -eq $false) ''

    # transform.Modes decides how many entries the menu gets, in the written order
    $tRow = [pscustomobject]@{ Payload = 'Hello World demo'; Marks = '' }
    [IO.File]::WriteAllLines($cfg, @('transform.Mode=keep', 'transform.Modes=upper, kebab ,snake'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    $tActs = @(Get-PluginActions)
    Check 'unit' 'Modes lists one entry per mode' ($tActs.Count -eq 3) ($tActs.Count -as [string])
    Check 'unit' 'Modes keeps the written order' ((@($tActs | ForEach-Object { Get-ActionText $_ $tRow }) -join '|') -eq 'Transform as UPPER|Transform as kebab-case|Transform as snake_case') (@($tActs | ForEach-Object { Get-ActionText $_ $tRow }) -join '|')
    Check 'unit' 'Modes works while the paste mode stays keep' ((Test-PluginAction $tActs[0] $tRow) -eq $true) ''
    [void](& $tActs[1]['Invoke'] $tRow)
    Check 'unit' 'each Modes entry rewrites with its own mode' ([string](@(Get-Records)[0].Payload) -eq 'hello-world-demo') ([string](@(Get-Records)[0].Payload))

    [IO.File]::WriteAllLines($cfg, @('transform.Mode=snake', 'transform.Modes=foo,snake'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'unknown Modes value falls back and is reported' ((@(Get-PluginActions).Count -eq 7) -and (@(Get-ConfigProblems).Count -ge 1)) (@(Get-PluginActions).Count -as [string])

    [IO.File]::WriteAllLines($cfg, @('transform.Mode=keep', 'transform.Modes=keep'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    Check 'unit' 'invalid Modes is reported once' (@(Get-ConfigProblems | Where-Object { $_ -match '^transform\.Modes=' }).Count -eq 1) (@(Get-ConfigProblems) -join ';')
    Check 'unit' 'invalid Modes keeps the default list' (@(Get-PluginActions).Count -eq 7) (@(Get-PluginActions).Count -as [string])
    [IO.File]::WriteAllLines($cfg, @('transform.Mode=snake', 'transform.Modes=snake'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings

    # several items from one plugin stay one block: a setting changes the count, the
    # grouping follows the plugin, and the plugins follow the load order
    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('item-marks', 'transform'))
    Register-PluginSettings
    [IO.File]::WriteAllLines($cfg, @('transform.Modes=upper,snake,kebab'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    $owners = @(Get-PluginActions | ForEach-Object { [string]$_['Plugin'] })
    Check 'unit' 'menu keeps one block per plugin' (($owners -join ',') -eq 'item-marks,item-marks,item-marks,transform,transform,transform') ($owners -join ',')
    Check 'unit' 'a plugin block stays contiguous' ((@($owners | Select-Object -Unique) -join ',') -eq 'item-marks,transform') (@($owners | Select-Object -Unique) -join ',')

    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('transform', 'item-marks'))
    Register-PluginSettings
    [IO.File]::WriteAllLines($cfg, @('transform.Mode=snake'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    $owners = @(Get-PluginActions | ForEach-Object { [string]$_['Plugin'] })
    $blocks = @()
    foreach ($o in $owners) { if ($blocks.Count -eq 0 -or $blocks[-1] -ne $o) { $blocks += $o } }
    Check 'unit' 'load order follows the Plugins list' (($blocks -join ',') -eq 'transform,item-marks') ($blocks -join ',')
    $names = @($script:Plugins | ForEach-Object { [string]$_['Name'] })
    Check 'unit' 'plugin list keeps the written order' (($names -join ',') -eq 'transform,item-marks') ($names -join ',')
    $script:Plugins = @()

    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('entry-actions'))
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
    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('item-marks', 'retention'))
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
    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('item-marks'))
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

    # the highlight colours are theme items: no ini key may override them
    Check 'unit' 'highlight ink is not an ini key' (-not $script:IniSchema.Contains('item-marks.HighlightColor')) ''
    Check 'unit' 'highlight fill is not an ini key' (-not $script:IniSchema.Contains('item-marks.HighlightBg')) ''
    Check 'unit' 'highlight colours are theme settings' (($script:PluginThemeValues.ContainsKey('item-marks.EmphasisInk')) -and ($script:PluginThemeValues.ContainsKey('item-marks.EmphasisFill'))) ''
    Check 'unit' 'highlight ink comes from the theme' ($hdec.TextColor -eq (Get-PluginTheme 'item-marks' 'EmphasisInk')) $hdec.TextColor
    Check 'unit' 'highlight fill comes from the theme' ($hdec.BackColor -eq (Get-PluginTheme 'item-marks' 'EmphasisFill')) $hdec.BackColor
    # an ini line with the old key is ignored, the theme keeps painting the row
    [IO.File]::WriteAllLines($cfg, @('item-marks.HighlightColor=#123456', 'item-marks.HighlightBg=#99123456'), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
    $idec = Get-PluginRowDecor $hrec
    Check 'unit' 'a stale ini highlight key is ignored' (($idec.TextColor -eq $hdec.TextColor) -and ($idec.BackColor -eq $hdec.BackColor)) ($idec.TextColor + ' / ' + $idec.BackColor)
    [IO.File]::WriteAllLines($cfg, @(), $Utf8)
    $script:IniCache = $null
    Apply-PluginSettings
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
    $script:Plugins = @(Load-Plugins (Join-Path $srcRoot 'plugins') @('item-marks'))
    Register-PluginThemeSettings
    Apply-PluginTheme
    Check 'unit' 'ThemeSettings fall back to the plugin default' ((Get-PluginTheme 'item-marks' 'StarGlyph') -eq [string][char]0xE735) ''
    $script:Plugins = @()

    Save-Records @()
  }

    # the drawing helpers live in lib/picker-draw.ps1 and take a Graphics plus plain values,
    # so they can be exercised without a window - that is what "no form state" buys.
    # Unit only (the helpers come from the -Library load) and source only: a packaged copy
    # has renamed internals, so the names do not exist there.
    if ($Unit -and -not $isPackaged) {
      Use-Drawing
      $script:FBody = New-Object Drawing.Font('Tahoma', [single]10)
      $script:FSmall = New-Object Drawing.Font('Tahoma', [single]9)
      $drawOk = $true
      $drawErr = ''
      $bmp = New-Object Drawing.Bitmap 240, 48
      $gfx = [Drawing.Graphics]::FromImage($bmp)
      try {
        Draw-KeyChips $gfx 4 18 @(@('Enter', 'Paste'), @('Esc', 'Close')) ([Drawing.Color]::Gray) ([Drawing.Color]::DimGray) 240
        Draw-Highlight $gfx 'hello world' (New-Object Drawing.RectangleF 0, 0, 120, 20) @('wor') ([Drawing.Brushes]::White) ([Drawing.Brushes]::Yellow)
      }
      catch {
        $drawOk = $false
        $drawErr = $_.Exception.Message
      }
      finally {
        $gfx.Dispose()
        $bmp.Dispose()
      }
      Check 'unit' 'drawing helpers run on a plain bitmap' $drawOk $drawErr

      # one hint pair reaches the function flattened by PowerShell's list handling; it must
      # still be drawn as [Esc] Close instead of three single-character chips
      $flatOk = $true
      $flatErr = ''
      $bmp2 = New-Object Drawing.Bitmap 240, 48
      $gfx2 = [Drawing.Graphics]::FromImage($bmp2)
      try {
        Draw-KeyChips $gfx2 4 18 @('Esc', 'Close') ([Drawing.Color]::Gray) ([Drawing.Color]::DimGray) 240
        $col = $bmp2.GetPixel(8, 18)
        if ($col.R -eq 0 -and $col.G -eq 0 -and $col.B -eq 0) { throw 'nothing was drawn' }
      }
      catch {
        $flatOk = $false
        $flatErr = $_.Exception.Message
      }
      finally {
        $gfx2.Dispose()
        $bmp2.Dispose()
      }
      Check 'unit' 'a flattened single hint pair still draws a chip' $flatOk $flatErr

      # The self-painted list freezes its first rows. 10 visible rows of 10px, 3 frozen, so
      # the scrollable window is 7 rows tall and TopIndex can never drop below 3.
      Add-PinList
      $pl = New-Object Cb.PinList
      $pl.ItemHeight = 10
      $pl.SetBounds(0, 0, 200, 100)
      $pl.ItemCount = 30
      $pl.PinnedCount = 3
      $pl.TopIndex = 3
      Check 'unit' 'the scrollable part starts under the frozen block' ($pl.TopIndex -eq 3) ([string]$pl.TopIndex)
      $pl.ScrollBy(-5)
      Check 'unit' 'scrolling up never drags a pin away' ($pl.TopIndex -eq 3) ([string]$pl.TopIndex)
      Check 'unit' 'a frozen row keeps its place' ($pl.GetItemRectangle(0).Y -eq 0) ([string]$pl.GetItemRectangle(0).Y)
      $before = $pl.GetItemRectangle(3).Y
      $pl.ScrollBy(2)
      Check 'unit' 'a scrollable row moves with the list' ($pl.GetItemRectangle(3).Y -eq ($before - 20)) ([string]$pl.GetItemRectangle(3).Y)
      Check 'unit' 'the frozen block stays put while scrolling' ($pl.GetItemRectangle(0).Y -eq 0) ([string]$pl.GetItemRectangle(0).Y)
      $pl.ScrollTo(999)
      Check 'unit' 'the last row can reach the bottom edge' (($pl.MaxTop -eq 23) -and ($pl.TopIndex -eq 23)) ([string]$pl.TopIndex + '/' + [string]$pl.MaxTop)
      # the control keeps a row count only: the labels stay with the caller
      Check 'unit' 'the list stores a row count, not the labels' (-not ($pl.PSObject.Properties.Name -contains 'Items')) ''
      # a Control that only syncs the scrollbar leaves the wheel dead: the list scrolls itself
      $pl.WheelRows = 2
      $pl.ScrollTo(3)
      # the panel moves its scrollbar thumb from this event, so a scroll has to report it
      $script:plScrolls = 0
      $pl.Add_ScrollChanged({ $script:plScrolls = $script:plScrolls + 1 })
      $wheelM = $pl.GetType().GetMethod('OnMouseWheel', [System.Reflection.BindingFlags]'Instance,NonPublic')
      $wheelArg = New-Object 'object[]' 1
      $wheelArg[0] = [Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::None, 0, 10, 10, -120)
      [void]$wheelM.Invoke($pl, $wheelArg)
      Check 'unit' 'the wheel scrolls the list itself' ($pl.TopIndex -eq 5) ([string]$pl.TopIndex)
      Check 'unit' 'a scroll tells the panel to move the thumb' ($script:plScrolls -gt 0) ([string]$script:plScrolls)
      $pl.ScrollTo(999)
      [void]$wheelM.Invoke($pl, $wheelArg)
      Check 'unit' 'the wheel never scrolls past the last row' (($pl.TopIndex -eq $pl.MaxTop) -and ($pl.TopIndex + $pl.VisibleRows - $pl.PinnedCount - 1 -eq ($pl.ItemCount - 1))) ([string]$pl.TopIndex + '/' + [string]$pl.MaxTop)
      $pl.Dispose()
    }

  # --------------------------------------------------------- integration tests
  if ($Integration) {
    $o = Clip $intDir @('help')
    Check 'int' 'help' ($o -match 'Usage: clipboard') ''

    $o = Clip $intDir @('version')
    Check 'int' 'version prints the program and data version' ($o -match ('clipboard ' + [regex]::Escape($programVersion) + '\s+data v\d+')) $o.Trim()

    $o = Clip $intDir @('migrate')
    Check 'int' 'migrate reports a store it does not need to touch' ($o -match 'nothing to migrate|migrated') $o.Trim()

    # xpm reads package.ini and runs the command line it finds there
    $xpm = Join-Path $repoRoot 'xpm.ps1'
    if (Test-Path -LiteralPath $xpm) {
      $o = (& powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $xpm 2>&1 | Out-String)
      Check 'int' 'xpm lists the declared commands' (($o -match '\bdev\b') -and ($o -match '\bbuild\b') -and ($o -match '\btest\b') -and ($o -match '\bshot\b')) $o.Trim()
      $o = (& powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $xpm 'nosuchcmd' 2>&1 | Out-String)
      Check 'int' 'xpm reports an unknown command' (($o -match 'unknown command') -and ($o -match '\bdev\b')) $o.Trim()
      $o = (& powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $xpm 'dev' 'nosuch' 2>&1 | Out-String)
      Check 'int' 'xpm runs a script through its command line' ($o -match 'dev always watches') $o.Trim()
    } else {
      Check 'int' 'xpm lists the declared commands' $false 'no xpm.ps1'
    }

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
    Check 'int' 'data dir isolate' ((Test-Path -LiteralPath (Join-Path $intDir 'data\history.dat')) -and -not (Test-Path -LiteralPath (Join-Path $srcRoot 'data\integration'))) ''

    # DataDir= in clipboard.ini decides the write location
    $altDir = Join-Path $tmpRoot 'alt'
    $cfgRoot = Join-Path $tmpRoot 'cfgroot'
    foreach ($d in @($altDir, $cfgRoot)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item -LiteralPath $clipPs1 -Destination (Join-Path $cfgRoot 'clipboard.ps1')
    # the program is entry file + lib\ + utils\ + schema\: a lone clipboard.ps1 cannot start
    foreach ($d in @('lib', 'utils', 'schema')) { Copy-Item -LiteralPath (Join-Path $srcRoot $d) -Destination $cfgRoot -Recurse -Force }
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

    # with sticky pins on, the frozen block may never fill the list: the third pin is
    # refused instead of pushing the rows below out of reach
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks', 'item-marks.StickyPins=1', 'item-marks.StickyRows=2'), $Utf8)
    [void](Clip $intDir @('clear', '-All'))
    [void](Clip $intDir @('put', 'cap-one'))
    [void](Clip $intDir @('put', 'cap-two'))
    [void](Clip $intDir @('put', 'cap-three'))
    $o = Clip $intDir @('pin', '1')
    Check 'int' 'pin fits under the sticky cap' ($o -match 'pinned') $o.Trim()
    [void](Clip $intDir @('pin', '2'))
    $o = Clip $intDir @('pin', '3')
    Check 'int' 'pin refused when the sticky cap is full' (($o -match '\[!\]') -and ($o -match 'unpin one first') -and ($o -match 'raise Rows')) $o.Trim()
    $o = Clip $intDir @('list')
    $capLine = @($o -split "`n" | Where-Object { $_ -match 'cap-one' })
    Check 'int' 'refused pin leaves the row unmarked' ($capLine.Count -gt 0 -and $capLine[0] -notmatch '\*') ($capLine -join '/')
    # turning the feature off drops the cap, so the same pin goes through
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks', 'item-marks.StickyPins=0', 'item-marks.StickyRows=2'), $Utf8)
    $o = Clip $intDir @('pin', '3')
    Check 'int' 'no cap while sticky pins are off' ($o -match 'pinned') $o.Trim()
    [void](Clip $intDir @('clear', '-All'))
    [IO.File]::WriteAllLines($cfg2, @('MaxItems=300', 'Plugins=item-marks'), $Utf8)

    $o = Clip $intDir @('config', 'get', 'Rows')
    Check 'int' 'config get' ($o -match 'Rows = 10') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Rows', '12')
    $iniAfter = [IO.File]::ReadAllText($cfg2)
    Check 'int' 'config set writes' (($o -match '10 -> 12') -and ($iniAfter -match '(?m)^Rows=12\r?$')) $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Rows', '1')
    Check 'int' 'config set rejects range' ($o -match 'must be >= 3') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'NopeKey', '1')
    Check 'int' 'config set rejects unknown key' ($o -match 'unknown key') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'DataDir', 'D:\x')
    Check 'int' 'config set rejects DataDir' ($o -match 'DataDir cannot be changed') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'Hotkey', 'Ctrl+Nope')
    Check 'int' 'config set rejects bad hotkey' ($o -match 'unknown key name') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'PreviewDelay', '900')
    Check 'int' 'a preview setting is writable' ($o -match '350 -> 900') $o.Trim()
    $o = Clip $intDir @('config', 'set', 'PreviewDelay', '350')
    Check 'int' 'a preview setting is restorable' ($o -match '900 -> 350') $o.Trim()

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
    Check 'int' 'theme alias is rejected' (($o -match 'unknown theme') -and ([IO.File]::ReadAllText($cfg2) -match '(?m)^Theme=win11-light\r?$')) $o.Trim()

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

    # scripts\build.ps1 is driven by a settings file and rewrites the scripts from their
    # syntax tree, never packing the history
    $pkgOut = Join-Path $tmpRoot 'pkg'
    $build = Join-Path $repoRoot 'scripts\build.ps1'
    $buildCfg = Join-Path $tmpRoot 'build-test.ini'
    Check 'int' 'build script ships under scripts\\' (Test-Path -LiteralPath $build) ''
    Check 'int' 'build options ship with the repo' (Test-Path -LiteralPath (Join-Path $repoRoot 'build.ini')) ''
    Check 'int' 'minifier ships under scripts\\' (Test-Path -LiteralPath (Join-Path $repoRoot 'scripts\minify.ps1')) ''
    Check 'int' 'package.ini ships with the repo' (Test-Path -LiteralPath (Join-Path $repoRoot 'package.ini')) ''
    [IO.File]::WriteAllLines($buildCfg, @(('OutDir=' + $pkgOut), 'Verify=0', 'Minify=1', 'Rename=1', 'IncludeDocs=1', 'Overwrite=1'), $Utf8)
    # the package folder is named after the version package.ini declares
    Check 'int' 'package.ini carries the version for the package name' ($programVersion -match '^\d+\.\d+\.\d+$') ([string]$programVersion)
    $bout = & powershell -NoProfile -ExecutionPolicy Bypass -File $build -Config $buildCfg 2>&1
    $pkgDir = Join-Path $pkgOut ('clipboard-' + $programVersion)
    Check 'int' 'build.ps1 writes a folder named after the program version' (Test-Path -LiteralPath $pkgDir) (($bout | Select-Object -Last 1) -as [string])
    if (Test-Path -LiteralPath $pkgDir) {
      $names = @(Get-ChildItem -LiteralPath $pkgDir -Recurse -File | ForEach-Object { $_.FullName.Substring($pkgDir.Length) })
      Check 'int' 'package keeps the program files' ((Test-Path -LiteralPath (Join-Path $pkgDir 'clipboard.ps1')) -and (Test-Path -LiteralPath (Join-Path $pkgDir 'clipboard.cmd')) -and (Test-Path -LiteralPath (Join-Path $pkgDir 'lib\plugins.ps1'))) ''
      # a packaged copy is installed from the folder: the two batch files sit next to
      # clipboard.ps1 and only call commands the program has
      $installBat = Join-Path $pkgDir 'install.bat'
      $uninstallBat = Join-Path $pkgDir 'uninstall.bat'
      $instText = ''
      $uninstText = ''
      $instHigh = 0
      $uninstHigh = 0
      if (Test-Path -LiteralPath $installBat) {
        $instText = [IO.File]::ReadAllText($installBat)
        $instHigh = @([IO.File]::ReadAllBytes($installBat) | Where-Object { $_ -gt 127 }).Count
      }
      if (Test-Path -LiteralPath $uninstallBat) {
        $uninstText = [IO.File]::ReadAllText($uninstallBat)
        $uninstHigh = @([IO.File]::ReadAllBytes($uninstallBat) | Where-Object { $_ -gt 127 }).Count
      }
      Check 'int' 'package ships install and uninstall scripts' ((Test-Path -LiteralPath $installBat) -and (Test-Path -LiteralPath $uninstallBat)) ''
      Check 'int' 'install script sets up the ini, migrates and installs' (($instText -match 'config init') -and ($instText -match '\bmigrate\b') -and ($instText -match '\binstall\b') -and ($instText -match 'clipboard\.ps1')) ''
      Check 'int' 'uninstall script purges the data folder' (($uninstText -match 'uninstall purge') -and ($uninstText -match '\bstop\b') -and ($uninstText -match 'clipboard\.ps1')) ''
      Check 'int' 'the batch scripts stay plain ASCII' (($instHigh -eq 0) -and ($uninstHigh -eq 0)) ([string]$instHigh + '/' + [string]$uninstHigh)
      Check 'int' 'package keeps plugins and themes' ((Test-Path -LiteralPath (Join-Path $pkgDir 'plugins\item-marks.ps1')) -and (Test-Path -LiteralPath (Join-Path $pkgDir 'themes\win11-dark.ini'))) ''
      Check 'int' 'package leaves history, tooling and metadata out' ((@($names | Where-Object { $_ -match '(^[\\/])(data|clipboard\.ini|tests|scripts)([\\/]|$)' }).Count -eq 0) -and -not (Test-Path -LiteralPath (Join-Path $pkgDir 'build.ini')) -and -not (Test-Path -LiteralPath (Join-Path $pkgDir 'package.ini'))) (@($names | Where-Object { $_ -match '(^[\\/])(data|clipboard\.ini|tests|scripts)' }) -join ', ')

      # the point of the build: same scripts, smaller, still parsing
      # (compare against the repository sources, not $srcRoot: with -Source the latter is
      # the package under test and both sides would be the same minified file)
      $srcText = [IO.File]::ReadAllText((Join-Path $defaultSource 'clipboard.ps1'))
      $outText = [IO.File]::ReadAllText((Join-Path $pkgDir 'clipboard.ps1'))
      Check 'int' 'minified script is smaller' ($outText.Length -lt $srcText.Length) (([string]$srcText.Length) + ' -> ' + ([string]$outText.Length))
      # ask the tokenizer instead of searching for a sentence: the same words also live in
      # the --help strings, which are data and have to survive
      $pkgTokens = $null
      $pkgParseErrors = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $pkgDir 'clipboard.ps1'), [ref]$pkgTokens, [ref]$pkgParseErrors)
      $leftComments = @($pkgTokens | Where-Object { [string]$_.Kind -eq 'Comment' -and $_.Text -notmatch '(?i)^\s*#requires' })
      Check 'int' 'minified script drops comments' ($leftComments.Count -eq 0) (($leftComments | Select-Object -First 1 | ForEach-Object { $_.Text }) -as [string])
      Check 'int' 'minified script renames internals' ((-not ($outText -match 'function Get-Record\b')) -and (-not ($outText -match 'function Show-Usage\b'))) ''
      $pe = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $pkgDir 'clipboard.ps1'), [ref]$null, [ref]$pe)
      Check 'int' 'minified script still parses' ($pe.Count -eq 0) (($pe | Select-Object -First 1 | ForEach-Object { $_.Message }) -as [string])
      Check 'int' 'minified script keeps the requires line' ($outText -match '(?m)^#Requires -Version 5\.1') ''
      Check 'int' 'minified script keeps cli parameter names' (($outText -match '\[string\]\$Command') -and ($outText -match '\$Library')) ''
      $o2 = & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File (Join-Path $pkgDir 'clipboard.ps1') status 2>&1
      Check 'int' 'packaged copy runs' ((($o2 -join ' ') -match 'plugins\s+:') -and -not (($o2 -join ' ') -match 'not recognized')) ((@($o2) | Select-Object -First 1) -as [string])
      # the version is a constant in a package: same number, no package.ini to read
      $pkgBase = [IO.File]::ReadAllText((Join-Path $pkgDir 'lib\base.ps1'))
      Check 'int' 'a package carries the version as a constant' ((-not ($pkgBase -match 'package\.ini')) -and ($pkgBase -match [regex]::Escape($programVersion))) ''
      $o3 = & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File (Join-Path $pkgDir 'clipboard.ps1') version 2>&1
      Check 'int' 'a package reports the package.ini version' (($o3 -join ' ') -match ('clipboard\s+' + [regex]::Escape($programVersion))) (($o3 -join ' ') -as [string]).Trim()
    }
    # Overwrite=0 refuses to replace an existing package
    [IO.File]::WriteAllLines($buildCfg, @(('OutDir=' + $pkgOut), 'Verify=0', 'Overwrite=0'), $Utf8)
    $bout = & powershell -NoProfile -ExecutionPolicy Bypass -File $build -Config $buildCfg 2>&1
    Check 'int' 'Overwrite=0 keeps the existing folder' (($bout -join ' ') -match 'already exists') (($bout | Select-Object -Last 1) -as [string])

    # Plugins= / Themes= trim the package; an unknown name stops the build
    $pkgOut2 = Join-Path $tmpRoot 'pkg2'
    [IO.File]::WriteAllLines($buildCfg, @(('OutDir=' + $pkgOut2), 'Verify=0', 'IncludeDocs=0', 'Plugins=transform', 'Themes=win11-light'), $Utf8)
    $bout = & powershell -NoProfile -ExecutionPolicy Bypass -File $build -Config $buildCfg 2>&1
    $pkgDir2 = Join-Path $pkgOut2 ('clipboard-' + $programVersion)
    if (Test-Path -LiteralPath $pkgDir2) {
      Check 'int' 'Plugins= ships only the listed plugin' ((Test-Path -LiteralPath (Join-Path $pkgDir2 'plugins\transform.ps1')) -and -not (Test-Path -LiteralPath (Join-Path $pkgDir2 'plugins\item-marks.ps1'))) ''
      Check 'int' 'Themes= ships only the listed theme' ((Test-Path -LiteralPath (Join-Path $pkgDir2 'themes\win11-light.ini')) -and -not (Test-Path -LiteralPath (Join-Path $pkgDir2 'themes\win11-dark.ini'))) ''
      Check 'int' 'IncludeDocs=0 drops the readme' (-not (Test-Path -LiteralPath (Join-Path $pkgDir2 'README.md'))) ''
      Check 'int' 'plugin page travels with its plugin' (Test-Path -LiteralPath (Join-Path $pkgDir2 'plugins\transform.md')) ''
    } else {
      Check 'int' 'Plugins= ships only the listed plugin' $false (($bout | Select-Object -Last 1) -as [string])
    }
    [IO.File]::WriteAllLines($buildCfg, @(('OutDir=' + $pkgOut2), 'Verify=0', 'Plugins=nosuchplugin'), $Utf8)
    $bout = & powershell -NoProfile -ExecutionPolicy Bypass -File $build -Config $buildCfg 2>&1
    Check 'int' 'unknown plugin name stops the build' (($bout -join ' ') -match 'nosuchplugin') (($bout | Select-Object -Last 1) -as [string])
    Remove-Item -LiteralPath $pkgOut -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pkgOut2 -Recurse -Force -ErrorAction SilentlyContinue
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
catch {
  # an unexpected exception used to skip every remaining group and still exit 0, which
  # reads as a green run; report it as a failure instead
  Check 'harness' 'run finished without an exception' $false $_.Exception.Message
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

#Requires -Version 5.1
<#
  build.ps1 - packaging: what the build writes and what it leaves out

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
$script:Harness.Part = 'build'
Start-TestPart -Source $Source
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'


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
      Check 'int' 'package keeps the program files' ((Test-Path -LiteralPath (Join-Path $pkgDir 'clipboard.ps1')) -and (Test-Path -LiteralPath (Join-Path $pkgDir 'clipboard.cmd')) -and (Test-Path -LiteralPath (Join-Path $pkgDir 'lib\plugin\plugins.ps1')) -and (Test-Path -LiteralPath (Join-Path $pkgDir 'lib\panel\picker.ps1'))) ''
      # the launcher tries the compiled client before it starts PowerShell; the executable
      # itself is optional, so a machine without a compiler is a skip, not a failure
      $launcher = Join-Path $pkgDir 'clipboard.cmd'
      $launcherText = ''
      if (Test-Path -LiteralPath $launcher) { $launcherText = [IO.File]::ReadAllText($launcher) }
      Check 'int' 'the launcher tries the compiled client first' ($launcherText -match 'cbx\.exe') $launcherText.Trim()
      $cbxFile = Join-Path $pkgDir 'cbx.exe'
      if (Test-Path -LiteralPath $cbxFile) {
        $null = (& $cbxFile $pkgDir 'version' 2>&1)
        $cbxRc = $LASTEXITCODE
        # no resident is listening for this package, so "not proxied" is the right answer
        Check 'int' 'the compiled client in the package runs' ($cbxRc -eq 100) ('exit ' + [string]$cbxRc)
      } else {
        Skip 'int' 'the compiled client in the package runs' 'no C# compiler on this machine'
      }
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
      # the pages are documentation: they travel with docs\, not with the plugin folder
      Check 'int' 'package ships the plugin and theme pages under docs' ((Test-Path -LiteralPath (Join-Path $pkgDir 'docs\plugin\item-marks.md')) -and (Test-Path -LiteralPath (Join-Path $pkgDir 'docs\theme\win11-dark.md'))) ''
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

    # Plugins= / Themes= trim the package; an unknown name stops the build.
    # Minify=0 and Cbx=0: these builds are only about which files travelled, so the rewrite
    # and the compiler would each cost more than the whole check
    $pkgOut2 = Join-Path $tmpRoot 'pkg2'
    [IO.File]::WriteAllLines($buildCfg, @(('OutDir=' + $pkgOut2), 'Verify=0', 'Minify=0', 'Cbx=0', 'IncludeDocs=0', 'Plugins=transform', 'Themes=win11-light'), $Utf8)
    $bout = & powershell -NoProfile -ExecutionPolicy Bypass -File $build -Config $buildCfg 2>&1
    $pkgDir2 = Join-Path $pkgOut2 ('clipboard-' + $programVersion)
    if (Test-Path -LiteralPath $pkgDir2) {
      Check 'int' 'Plugins= ships only the listed plugin' ((Test-Path -LiteralPath (Join-Path $pkgDir2 'plugins\transform.ps1')) -and -not (Test-Path -LiteralPath (Join-Path $pkgDir2 'plugins\item-marks.ps1'))) ''
      Check 'int' 'Themes= ships only the listed theme' ((Test-Path -LiteralPath (Join-Path $pkgDir2 'themes\win11-light.ini')) -and -not (Test-Path -LiteralPath (Join-Path $pkgDir2 'themes\win11-dark.ini'))) ''
      Check 'int' 'IncludeDocs=0 drops the readme' (-not (Test-Path -LiteralPath (Join-Path $pkgDir2 'README.md'))) ''
      Check 'int' 'IncludeDocs=0 drops the docs folder' (-not (Test-Path -LiteralPath (Join-Path $pkgDir2 'docs'))) ''
    } else {
      Check 'int' 'Plugins= ships only the listed plugin' $false (($bout | Select-Object -Last 1) -as [string])
    }
    [IO.File]::WriteAllLines($buildCfg, @(('OutDir=' + $pkgOut2), 'Verify=0', 'Plugins=nosuchplugin'), $Utf8)
    $bout = & powershell -NoProfile -ExecutionPolicy Bypass -File $build -Config $buildCfg 2>&1
    Check 'int' 'unknown plugin name stops the build' (($bout -join ' ') -match 'nosuchplugin') (($bout | Select-Object -Last 1) -as [string])

    # a page documents one plugin or one theme: with Plugins= / Themes= set, docs\ carries
    # only the pages of what the package can run. Again no rewrite and no compiler
    $pkgOut3 = Join-Path $tmpRoot 'pkg3'
    [IO.File]::WriteAllLines($buildCfg, @(('OutDir=' + $pkgOut3), 'Verify=0', 'Minify=0', 'Cbx=0', 'IncludeDocs=1', 'Plugins=transform', 'Themes=win11-light'), $Utf8)
    $bout = & powershell -NoProfile -ExecutionPolicy Bypass -File $build -Config $buildCfg 2>&1
    $pkgDir3 = Join-Path $pkgOut3 ('clipboard-' + $programVersion)
    if (Test-Path -LiteralPath $pkgDir3) {
      Check 'int' 'a shipped plugin keeps its page under docs' (Test-Path -LiteralPath (Join-Path $pkgDir3 'docs\plugin\transform.md')) ''
      Check 'int' 'an unshipped plugin leaves its page out' (-not (Test-Path -LiteralPath (Join-Path $pkgDir3 'docs\plugin\item-marks.md'))) ''
      Check 'int' 'a shipped theme keeps its page under docs' (Test-Path -LiteralPath (Join-Path $pkgDir3 'docs\theme\win11-light.md')) ''
      Check 'int' 'an unshipped theme leaves its page out' (-not (Test-Path -LiteralPath (Join-Path $pkgDir3 'docs\theme\win11-dark.md'))) ''
      Check 'int' 'the pictures stay with a trimmed package' (Test-Path -LiteralPath (Join-Path $pkgDir3 'docs\screenshot-dark.png')) ''
    } else {
      Check 'int' 'a shipped plugin keeps its page under docs' $false (($bout | Select-Object -Last 1) -as [string])
    }
    Remove-Item -LiteralPath $pkgOut3 -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pkgOut -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pkgOut2 -Recurse -Force -ErrorAction SilentlyContinue

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

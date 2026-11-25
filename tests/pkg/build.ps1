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
  [string]$ProgressFile = '',
  [switch]$Quiet
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'lib\harness.ps1')
$script:Harness.Part = 'build'
Start-TestPart -Source $Source -Quiet:$Quiet -ProgressFile $ProgressFile
$intDir = New-FakeSandbox 'cli'
$cfg2 = Join-Path $intDir 'clipboard.ini'


# packages\builder\package.ps1 is driven by a settings file and rewrites the scripts from their syntax tree,
# never packing the history
$pkgOut = Join-Path $tmpRoot 'pkg'
$build = Join-Path $repoRoot 'packages\cli\bin\cli.ps1'
# builder-cli is started by the module layer, like every tool: the command file carries imports
$moduleBin = Join-Path $repoRoot 'packages\module\bin\module.ps1'
$buildCfg = Join-Path $tmpRoot 'build-test.ini'

# Every case below runs a real build, and a build compiles src\main\clipboard.dll. A resident
# process holds that file, so a machine with the panel running would fail every case with
# CS0016 ("the file is in use") - the suite asks it to stop first, the way `cli dev` does
# before it recompiles, and says so once instead of once per row.
$stopCmd = Join-Path $repoRoot 'src\clipboard.cmd'
if (Test-Path -LiteralPath $stopCmd) {
  & $stopCmd stop 2>&1 | Out-Null
  Start-Sleep -Milliseconds 600
}
# every [directories] and [files] key has to be present: the builder reads builder.ini and refuses
# to invent a default, so each case starts from the whole file and overrides the key it tests.
#
# The file list itself is READ from builder.ini instead of being written again here. It is the one
# fact that says what a package is, and a copy of it drifts the moment a folder moves.
. (Use-Module '../../packages/cli/utils/ini.ps1' $PSCommandPath -Named Import-IniMap)
$repoFiles = [string](Import-IniMap (Join-Path $repoRoot 'builder.ini'))['files.Files']
if (-not $repoFiles) { throw 'builder.ini has no [files] Files to test against' }
# the client stays out of the default list so most cases skip a compile; builder.ini carries it
$allFiles = 'Files=' + (@(($repoFiles -split ',') | Where-Object { $_ -notlike 'src/preload/*' }) -join ',')
$withClient = 'Files=' + $repoFiles
function Write-BuildCfg([string]$outDir, [string[]]$override) {
  # a key belongs to the section it is read from: the output folder to [directories], the list to
  # [files], compression at the top. All three start whole, and an override replaces the key it
  # names.
  $compression = 'maximum'
  $dir = @(('Output=' + $outDir), 'BaseUrl=.')
  $files = @($allFiles)
  foreach ($line in @($override)) {
    $key = $line.Split('=')[0]
    if (@('Output', 'BaseUrl') -contains $key) {
      $dir = @(@($dir | Where-Object { -not $_.StartsWith($key + '=') }) + @($line))
    } elseif ($key -eq 'Files') {
      $files = @($line)
    } elseif ($key -eq 'Compression') {
      $compression = $line.Split('=')[1]
    }
  }
  $lines = @(('Compression=' + $compression), '', '[directories]') + $dir + @('', '[files]') + $files
  [IO.File]::WriteAllLines($buildCfg, $lines, $Utf8)
}

# The rows below need the package to exist: a build that failed says so once per row instead of
# leaving the rest of the part looking green.
function Test-Built([string]$dir, $output) {
  if (Test-Path -LiteralPath $dir) { return $true }
  Expect $false ('the package was not built: ' + [string](($output | Select-Object -Last 1)))
  return $false
}

Describe 'int' {
  AfterAll {
    Remove-Item -LiteralPath $pkgOut -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $tmpRoot 'pkg2') -Recurse -Force -ErrorAction SilentlyContinue
  }

  Describe 'repo tooling' {
    It 'build script ships under packages\builder\' {
      Expect (Test-Path -LiteralPath $build) 'packages\builder\package.ps1 has to ship with the repo'
    }
    It 'build options ship with the repo' {
      Expect (Test-Path -LiteralPath (Join-Path $repoRoot 'builder.ini')) 'builder.ini has to ship with the repo'
    }
    It 'minifier ships under packages\builder\utils\' {
      Expect (Test-Path -LiteralPath (Join-Path $repoRoot 'packages\cli\utils\minify.ps1')) 'the minifier has to ship'
    }
    It 'package.ini ships with the repo' {
      Expect (Test-Path -LiteralPath (Join-Path $repoRoot 'package.ini')) 'package.ini has to ship with the repo'
    }
  }

  Describe 'the package' {
    BeforeAll {
      # a chunk's name carries its hash, so a name an earlier build left in out\ has to be gone
      # after the next one: every build owns the folder its Output= names
      $staleDir = Join-Path (Join-Path $repoRoot 'out') 'renderer'
      if (-not (Test-Path -LiteralPath $staleDir)) { New-Item -ItemType Directory -Path $staleDir -Force | Out-Null }
      $script:stale = Join-Path $staleDir '__stale.ps1'
      [IO.File]::WriteAllText($script:stale, '# left by an earlier build', $Utf8)
      Write-BuildCfg $pkgOut @($withClient)
      $script:bout = & powershell -NoProfile -ExecutionPolicy Bypass -File $moduleBin $build build -BuilderConfig $buildCfg 2>&1
      # the package folder is named after the version package.ini declares
      $script:pkgDir = Join-Path $pkgOut ('clipboard-' + $programVersion)
      $script:names = @()
      if (Test-Path -LiteralPath $script:pkgDir) {
        $script:names = @(Get-ChildItem -LiteralPath $script:pkgDir -Recurse -File | ForEach-Object { $_.FullName.Substring($script:pkgDir.Length) })
      }
    }
    It 'package.ini carries the version for the package name' {
      Expect-Match $programVersion '^\d+\.\d+\.\d+$' ([string]$programVersion)
    }
    It 'build.ps1 writes a folder named after the program version' {
      Expect (Test-Path -LiteralPath $script:pkgDir) (($script:bout | Select-Object -Last 1) -as [string])
    }
    It 'out is rebuilt on every build' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      Expect (-not (Test-Path -LiteralPath $script:stale)) 'a file left in out\ by an earlier run has to be gone'
    }
    It 'the resolved configuration is written beside the package' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $effective = Join-Path $pkgOut 'builder-effective-config.ini'
      $effectiveText = ''
      if (Test-Path -LiteralPath $effective) { $effectiveText = [IO.File]::ReadAllText($effective) }
      Expect (($effectiveText -match ('Version=' + [regex]::Escape($programVersion))) -and ($effectiveText -match 'Packages=')) 'electron-builder writes its resolved config beside the output'
    }
    It 'package keeps the program files' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      Expect ((Test-Path -LiteralPath (Join-Path $script:pkgDir 'clipboard.ps1')) -and (Test-Path -LiteralPath (Join-Path $script:pkgDir 'clipboard.cmd')) -and (Test-Path -LiteralPath (Join-Path $script:pkgDir 'main\utils\plugin\plugins.ps1')) -and (Test-Path -LiteralPath (Join-Path $script:pkgDir 'renderer\manifest.ini'))) 'the entry file, the launcher, the base modules and the chunk manifest have to travel'
    }
    # the modules an entry names do not come along as files as well: the list is read from
      # builder.cli.config.ps1, so a module that moves out of the bundle follows without touching
      # this check
      It 'the window layer ships as chunks, not as the modules it merged' {
        if (-not (Test-Built $script:pkgDir $script:bout)) { return }
        # a window chunk is a file of its own; a shared one lives under assets\; each line says
        # which source files the chunk already carries, and those must not also travel as files
        $manifest = Join-Path $script:pkgDir 'renderer\manifest.ini'
        # the modules the window layer owns come from the entry, so a module a command also loads
        # (picker-geom, for `status`) is not held to this rule
        $windowSet = @{}
        $entryText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\clipboard.ps1'))
        $windowBlock = [regex]::Match($entryText, '\$windowModules\s*=\s*@\(([^\)]*)\)').Groups[1].Value
        foreach ($m in [regex]::Matches($windowBlock, "'([^']+)'")) {
          $windowSet[$m.Groups[1].Value.Replace('\', '/').ToLowerInvariant()] = $true
        }
        $chunks = 0
        $inModules = $false
        $copiedTwice = @()
        foreach ($line in @([IO.File]::ReadAllLines($manifest))) {
          $t = $line.Trim()
          if ($t.StartsWith('[')) { $inModules = ($t -eq '[modules]'); continue }
          if (-not $t) { continue }
          $at = $t.IndexOf('=')
          if ($at -lt 1) { continue }
          if (-not $inModules) { $chunks++; continue }
          foreach ($id in @($t.Substring($at + 1).Split(','))) {
            $one = $id.Trim()
            if (-not $windowSet.ContainsKey($one.ToLowerInvariant())) { continue }
            $rel = $one.Replace('/', '\')
            if (Test-Path -LiteralPath (Join-Path $script:pkgDir ($rel + '.ps1'))) { $copiedTwice += $rel }
          }
        }
        Expect ($chunks -ge 2) ('the manifest lists ' + $chunks + ' chunk(s)')
        Expect ($copiedTwice.Count -eq 0) ('still copied beside its chunk: ' + ($copiedTwice -join ', '))
      }
    # A function named inside a here-string is text the rename pass cannot rewrite: the string
    # keeps the spelling it was written with, so the package has to define that name as well.
    It 'a function named inside a string keeps its name in the package' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $stringNames = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
      foreach ($sf in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src') -Recurse -Filter '*.ps1' -File)) {
        $st = [IO.File]::ReadAllText($sf.FullName)
        foreach ($hm in [regex]::Matches($st, "(?s)@'(.+?)'@")) {
          foreach ($cm in [regex]::Matches($hm.Groups[1].Value, '(?<![A-Za-z0-9_-])[A-Z][A-Za-z0-9]+-[A-Z][A-Za-z0-9]+')) {
            [void]$stringNames.Add($cm.Value)
          }
        }
      }
      $pkgText = (@(Get-ChildItem -LiteralPath $script:pkgDir -Recurse -Filter '*.ps1' -File) | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
      $lostNames = @($stringNames | Where-Object {
          -not ($pkgText -match ('function\s+' + [regex]::Escape($_) + '(?![A-Za-z0-9_-])')) -and -not (Get-Command $_ -ErrorAction SilentlyContinue)
        })
      Expect ($lostNames.Count -eq 0) ($lostNames -join ', ')
    }
    # the launcher tries the compiled client before it starts PowerShell; the executable
    # itself is optional, so a machine without a compiler is a skip, not a failure
    It 'the launcher tries the compiled client first' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $launcher = Join-Path $script:pkgDir 'clipboard.cmd'
      $launcherText = ''
      if (Test-Path -LiteralPath $launcher) { $launcherText = [IO.File]::ReadAllText($launcher) }
      Expect-Match $launcherText 'client\.exe' $launcherText.Trim()
    }
    It 'the compiled client in the package runs' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $clientFile = Join-Path $script:pkgDir 'preload\client.exe'
      if (-not (Test-Path -LiteralPath $clientFile)) {
        Skip-Test 'no C# compiler on this machine'
        return
      }
      $null = (& $clientFile $script:pkgDir 'version' 2>&1)
      $clientRc = $LASTEXITCODE
      # no resident is listening for this package, so "not proxied" is the right answer
      Expect ($clientRc -eq 100) ('exit ' + [string]$clientRc)
    }
    # The type library is either compiled ahead of time or shipped as source, never both and
    # never neither: main\utils\native.ps1 needs one of the two to open the panel.
    It 'package carries the assembly or its source, never both' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $asmDir = Join-Path $script:pkgDir 'main'
      $asmFile = Join-Path $asmDir 'clipboard.dll'
      $asmSource = @(Get-ChildItem -LiteralPath $asmDir -Filter '*.cs' -File -ErrorAction SilentlyContinue)
      $asmBuilt = Test-Path -LiteralPath $asmFile
      Expect ($asmBuilt -xor ($asmSource.Count -gt 0)) ('dll=' + [string]$asmBuilt + ' cs=' + [string]$asmSource.Count)
    }
    # a packaged copy is installed from the folder: the two batch files sit next to
    # clipboard.ps1 and only call commands the program has
    It 'package ships install and uninstall scripts' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      Expect ((Test-Path -LiteralPath (Join-Path $script:pkgDir 'install.bat')) -and (Test-Path -LiteralPath (Join-Path $script:pkgDir 'uninstall.bat'))) 'the install and uninstall scripts have to travel'
    }
    It 'install script sets up the ini, migrates and installs' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $instText = ''
      $installBat = Join-Path $script:pkgDir 'install.bat'
      if (Test-Path -LiteralPath $installBat) { $instText = [IO.File]::ReadAllText($installBat) }
      Expect (($instText -match 'config init') -and ($instText -match '\bmigrate\b') -and ($instText -match '\binstall\b') -and ($instText -match 'clipboard\.ps1')) 'install.bat has to set up the ini, migrate and install'
    }
    It 'uninstall script purges the data folder' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $uninstText = ''
      $uninstallBat = Join-Path $script:pkgDir 'uninstall.bat'
      if (Test-Path -LiteralPath $uninstallBat) { $uninstText = [IO.File]::ReadAllText($uninstallBat) }
      Expect (($uninstText -match 'uninstall purge') -and ($uninstText -match '\bstop\b') -and ($uninstText -match 'clipboard\.ps1')) 'uninstall.bat has to purge the data folder'
    }
    It 'the batch scripts stay plain ASCII' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $instHigh = 0
      $uninstHigh = 0
      $installBat = Join-Path $script:pkgDir 'install.bat'
      $uninstallBat = Join-Path $script:pkgDir 'uninstall.bat'
      if (Test-Path -LiteralPath $installBat) { $instHigh = @([IO.File]::ReadAllBytes($installBat) | Where-Object { $_ -gt 127 }).Count }
      if (Test-Path -LiteralPath $uninstallBat) { $uninstHigh = @([IO.File]::ReadAllBytes($uninstallBat) | Where-Object { $_ -gt 127 }).Count }
      Expect (($instHigh -eq 0) -and ($uninstHigh -eq 0)) ([string]$instHigh + '/' + [string]$uninstHigh)
    }
    It 'package keeps plugins and themes' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      Expect ((Test-Path -LiteralPath (Join-Path $script:pkgDir 'plugins\item-marks.ps1')) -and (Test-Path -LiteralPath (Join-Path $script:pkgDir 'themes\win11-dark.ini'))) 'plugins and themes have to travel'
    }
    # both halves of the command proxy read src\shared\ipc\channels.ini; without it in the package every
    # command still answers, but each one pays the 2.5 s start instead of the pipe
    It 'package keeps the channel table' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $table = Join-Path $script:pkgDir 'shared\ipc\channels.ini'
      if (-not (Test-Path -LiteralPath $table)) { Expect $false 'shared\ipc\channels.ini has to travel'; return }
      $remote = @([IO.File]::ReadAllLines($table) | Where-Object { $_ -match '^\s*Remote\s*=\s*1' })
      Expect ($remote.Count -ge 5) ('channels with Remote=1: ' + [string]$remote.Count)
    }
    # a language file is the one ini whose values are not ASCII: written with the plain encoder
    # it ships a page of "?", which a Chinese window would draw as its own name
    It 'a language file keeps its words in the package' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $langFile = Join-Path $script:pkgDir 'lang\zh-CN.ini'
      if (-not (Test-Path -LiteralPath $langFile)) { Expect $false 'the language file has to travel'; return }
      $name = ''
      foreach ($line in [IO.File]::ReadAllLines($langFile, [Text.Encoding]::UTF8)) {
        if ($line -match '^\s*name\s*=\s*(.+)$') { $name = $Matches[1].Trim() }
      }
      Expect ($name.Length -gt 0 -and $name -notmatch '\?') ('[' + $name + ']')
    }
    It 'package leaves history, tooling and metadata out' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      Expect ((@($script:names | Where-Object { $_ -match '(^[\\/])(data|clipboard\.ini|tests|scripts)([\\/]|$)' }).Count -eq 0) -and -not (Test-Path -LiteralPath (Join-Path $script:pkgDir 'cli.ini')) -and -not (Test-Path -LiteralPath (Join-Path $script:pkgDir 'package.ini'))) (@($script:names | Where-Object { $_ -match '(^[\\/])(data|clipboard\.ini|tests|scripts)' }) -join ', ')
    }
    # documentation is data like any other file, so a list that does not name it ships none -
    # the positive half of that pair is asserted on the docs package below
    It 'the licence and the READMEs travel with the program' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      Expect ((Test-Path -LiteralPath (Join-Path $script:pkgDir 'LICENSE')) -and (Test-Path -LiteralPath (Join-Path $script:pkgDir 'README.md'))) 'a package carries the licence and the READMEs'
    }
    It 'a list without the documentation ships none' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      # the READMEs travel by default, the docs\ pages do not: a list that does not name them
      # must reach no docs folder
      Expect ((Test-Path -LiteralPath (Join-Path $script:pkgDir 'docs')) -eq $false) 'a list that does not name the docs must not ship them'
    }
    # the point of the build: same scripts, smaller, still parsing
    # (compare against the repository sources, not $srcRoot: with -Source the latter is
    # the package under test and both sides would be the same minified file)
    It 'minified script is smaller' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $srcText = [IO.File]::ReadAllText((Join-Path $defaultSource 'clipboard.ps1'))
      $outText = [IO.File]::ReadAllText((Join-Path $script:pkgDir 'clipboard.ps1'))
      Expect ($outText.Length -lt $srcText.Length) (([string]$srcText.Length) + ' -> ' + ([string]$outText.Length))
    }
    It 'minified script drops comments' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      # ask the tokenizer instead of searching for a sentence: the same words also live in
      # the --help strings, which are data and have to survive
      $pkgTokens = $null
      $pkgParseErrors = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:pkgDir 'clipboard.ps1'), [ref]$pkgTokens, [ref]$pkgParseErrors)
      $leftComments = @($pkgTokens | Where-Object { [string]$_.Kind -eq 'Comment' -and $_.Text -notmatch '(?i)^\s*#requires' })
      Expect ($leftComments.Count -eq 0) (($leftComments | Select-Object -First 1 | ForEach-Object { $_.Text }) -as [string])
    }
    It 'minified script renames internals' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $outText = [IO.File]::ReadAllText((Join-Path $script:pkgDir 'clipboard.ps1'))
      Expect ((-not ($outText -match 'function Get-Record\b')) -and (-not ($outText -match 'function Show-Usage\b'))) 'the rename pass has to leave no original internal name behind'
    }
    It 'minified script still parses' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $pe = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:pkgDir 'clipboard.ps1'), [ref]$null, [ref]$pe)
      Expect ($pe.Count -eq 0) (($pe | Select-Object -First 1 | ForEach-Object { $_.Message }) -as [string])
    }
    It 'minified script keeps the requires line' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $outText = [IO.File]::ReadAllText((Join-Path $script:pkgDir 'clipboard.ps1'))
      Expect-Match $outText '(?m)^#Requires -Version 5\.1' 'the #Requires line has to survive the rewrite'
    }
    It 'minified script keeps cli parameter names' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $outText = [IO.File]::ReadAllText((Join-Path $script:pkgDir 'clipboard.ps1'))
      Expect (($outText -match '\[string\]\$Command') -and ($outText -match '\$Library')) 'the cli parameter names are a contract and cannot be renamed'
    }
    It 'packaged copy runs' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $o2 = & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File (Join-Path $script:pkgDir 'clipboard.ps1') status 2>&1
      Expect ((($o2 -join ' ') -match 'plugins\s+:') -and -not (($o2 -join ' ') -match 'not recognized')) ((@($o2) | Select-Object -First 1) -as [string])
    }
    # the version is a constant in a package: same number, no package.ini to read
    It 'a package carries the version as a constant' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $pkgBase = [IO.File]::ReadAllText((Join-Path $script:pkgDir 'main\utils\base.ps1'))
      Expect ((-not ($pkgBase -match 'package\.ini')) -and ($pkgBase -match [regex]::Escape($programVersion))) 'the version has to be a constant in a package'
    }
    It 'a package reports the package.ini version' {
      if (-not (Test-Built $script:pkgDir $script:bout)) { return }
      $o3 = & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File (Join-Path $script:pkgDir 'clipboard.ps1') version 2>&1
      Expect-Match ($o3 -join ' ') ('clipboard\s+' + [regex]::Escape($programVersion)) ($o3 -join ' ')
    }
  }

  # the list is the package: a theme that is not named does not travel, a file named with "!" does
  # not travel, the docs travel only when the list names them. Compression=store: these builds are
  # only about which files travelled. One build answers all of it - a second one would only prove
  # the same copy handler twice.
  Describe 'a trimmed list' {
    BeforeAll {
      $script:pkgOut2 = Join-Path $tmpRoot 'pkg2'
      # one theme instead of the glob, plus the docs: the difference the case is about. The glob in
      # the list is the recursive one, so the replacement names it the same way.
      $oneTheme = ($allFiles -replace [regex]::Escape('src/**/*.ini'), 'src/themes/win11-light.ini') + ',README.md,LICENSE,docs/**/*'
      Write-BuildCfg $script:pkgOut2 @('Compression=store', ($oneTheme + ',!src/plugins/item-marks.ps1'))
      $script:bout2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $moduleBin $build build -BuilderConfig $buildCfg 2>&1
      $script:pkgDir2 = Join-Path $script:pkgOut2 ('clipboard-' + $programVersion)
    }
    It 'a !pattern keeps the plugin out' {
      if (-not (Test-Built $script:pkgDir2 $script:bout2)) { return }
      Expect ((Test-Path -LiteralPath (Join-Path $script:pkgDir2 'plugins\transform.ps1')) -and -not (Test-Path -LiteralPath (Join-Path $script:pkgDir2 'plugins\item-marks.ps1'))) 'a !pattern has to keep the plugin out'
    }
    It 'the list decides which theme ships' {
      if (-not (Test-Built $script:pkgDir2 $script:bout2)) { return }
      Expect ((Test-Path -LiteralPath (Join-Path $script:pkgDir2 'themes\win11-light.ini')) -and -not (Test-Path -LiteralPath (Join-Path $script:pkgDir2 'themes\win11-dark.ini'))) 'only the named theme may travel'
    }
    It 'the list carries the docs it names' {
      if (-not (Test-Built $script:pkgDir2 $script:bout2)) { return }
      Expect ((Test-Path -LiteralPath (Join-Path $script:pkgDir2 'README.md')) -and (Test-Path -LiteralPath (Join-Path $script:pkgDir2 'LICENSE'))) 'the docs the list names have to travel'
    }
    It 'a docs subfolder keeps its layout' {
      if (-not (Test-Built $script:pkgDir2 $script:bout2)) { return }
      Expect ((Test-Path -LiteralPath (Join-Path $script:pkgDir2 'docs\zh-cn\plugin\transform.md')) -and (Test-Path -LiteralPath (Join-Path $script:pkgDir2 'docs\en\screenshot-dark.png'))) 'a docs subfolder has to keep its layout'
    }
  }

  Describe 'a list without the entry point' {
    It 'a list without clipboard.ps1 stops the build' {
      # the entry point is the one glob taken out: everything else still ships, so the build
      # gets far enough to complain about the launcher
      $noEntry = 'Files=' + (@(($repoFiles -split ',') | Where-Object { $_ -ne 'src/**/*.ps1' }) -join ',')
      Write-BuildCfg (Join-Path $tmpRoot 'pkg2') @('Compression=store', $noEntry)
      $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $moduleBin $build build -BuilderConfig $buildCfg 2>&1
      Expect (($out -join ' ') -match 'does not ship clipboard\.ps1') (($out | Select-Object -Last 1) -as [string])
    }
  }
}

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet


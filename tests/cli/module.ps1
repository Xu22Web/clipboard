#Requires -Version 5.1
<#
  module.ps1 - the module layer: a specifier to a file, the graph an entry needs, and the order
  a caller loads it in.

  One part of the self tests: it runs alone, in its own process, against packages\module and the
  repository's own package.ini files. Nothing here drives the clipboard or the resident, so the
  part is quick and never blocks another one.
#>
[CmdletBinding()]
param(
  [string]$Source = '',
  [string]$ResultFile = '',
  [string]$ProgressFile = '',
  [switch]$Quiet,
  [switch]$ClipShared
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'lib\harness.ps1')
$script:Harness.Part = 'module'
Start-TestPart -Source $Source -ClipShared:$ClipShared -Quiet:$Quiet -ProgressFile $ProgressFile

$repoRoot = $script:Harness.RepoRoot
. (Join-Path $repoRoot 'packages\module\index.ps1')
# the second reader of the same comments: the bundler's two library files, loaded without the
# engine so the part stays quick
. (Join-Path $repoRoot 'packages\bundler\lib\ast.ps1')
. (Join-Path $repoRoot 'packages\bundler\lib\surface.ps1')

$modDir = Join-Path $env:TEMP ('cb-part-mod-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $modDir -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $modDir 'leaf.ps1'), "function Get-LeafValue { return 'leaf' }`r`n", $utf8)
[IO.File]::WriteAllText((Join-Path $modDir 'middle.ps1'), "#@use ./leaf`r`nfunction Get-MiddleValue { return (Get-LeafValue) }`r`n", $utf8)
$top = Join-Path $modDir 'top.ps1'
[IO.File]::WriteAllText($top, "#@use ./middle`r`n#@export Get-TopValue`r`nfunction Get-TopValue { return (Get-MiddleValue) }`r`n", $utf8)

Describe 'a specifier' {
  It 'reads the five forms node reads' {
    $rel = Resolve-ModuleSpecifier './middle' $top $repoRoot
    $pkg = Resolve-ModuleSpecifier 'cli' '' $repoRoot
    $exp = Resolve-ModuleSpecifier 'cli#Invoke-CliCommand' '' $repoRoot
    $sub = Resolve-ModuleSpecifier 'bundler/lib/surface' '' $repoRoot
    $id = Resolve-ModuleSpecifier 'shared/utils/format' '' $repoRoot
    $ok = (-not $rel.Problem) -and ($rel.Kind -eq 'local')
    $ok = $ok -and (-not $pkg.Problem) -and ($pkg.Kind -eq 'package')
    $ok = $ok -and (-not $exp.Problem)
    $ok = $ok -and (-not $sub.Problem) -and ($sub.Kind -eq 'package-file')
    $ok = $ok -and (-not $id.Problem) -and ($id.Kind -eq 'id')
    Expect $ok ($rel.Problem + ' ' + $pkg.Problem + ' ' + $exp.Problem + ' ' + $sub.Problem + ' ' + $id.Problem)
  }

  It 'refuses an export the package does not declare' {
    $bad = Resolve-ModuleSpecifier 'cli#NoSuchName' '' $repoRoot
    Expect ($bad.Problem -like '*does not export*') $bad.Problem
  }

  It 'names the file a package Main points at' {
    $pkg = Resolve-ModuleSpecifier 'module' '' $repoRoot
    Expect ((Split-Path -Leaf $pkg.Path) -eq 'index.ps1') $pkg.Path
  }
}

Describe 'the import graph' {
  It 'orders dependencies first and loads at the top level' {
    $order = @(Get-ModuleOrder $top $repoRoot)
    if ($order.Count -gt 0) { foreach ($m in $order) { . $m } }
    $value = ''
    if (Get-Command -Name 'Get-TopValue' -CommandType Function -ErrorAction SilentlyContinue) { $value = Get-TopValue }
    Expect (($order.Count -eq 3) -and ((Split-Path -Leaf $order[0]) -eq 'leaf.ps1') -and ($value -eq 'leaf')) ($order.Count.ToString() + ' ' + (Split-Path -Leaf $order[0]) + ' ' + $value)
  }

  It 'reads the same directives the bundler reads' {
    $mine = Get-ModuleDirectives $top
    $theirs = Get-BundleDirectives (Get-BundleParse ([IO.File]::ReadAllText($top)))
    $same = ((@($mine.Uses) -join ',') -eq (@($theirs.Uses) -join ','))
    $same = $same -and ((@($mine.Exports) -join ',') -eq (@($theirs.Exports) -join ','))
    Expect $same ((@($mine.Uses) -join ',') + ' / ' + (@($theirs.Uses) -join ','))
  }

  It 'reports an export that defines nothing' {
    $bad = Join-Path $modDir 'bad.ps1'
    [IO.File]::WriteAllText($bad, "#@export Get-Missing`r`nfunction Get-Other { return 1 }`r`n", $utf8)
    $problems = @(Test-ModuleSpecifiers $bad $repoRoot)
    $row = @($problems | Where-Object { $_ -like '*Get-Missing*' })
    Expect (($row.Count -eq 1) -and ($row[0] -like 'bad.ps1:1*')) ($problems -join '; ')
  }

  It 'reads a use statement and the line it sits on' {
    $users = Join-Path $modDir 'users.ps1'
    [IO.File]::WriteAllText($users, "function Get-Nothing { return 1 }`r`n. (Use-Module './leaf' `$PSCommandPath)`r`n. (Use-Module './gone' `$PSCommandPath)`r`n", $utf8)
    $statements = Get-ModuleStatements $users
    $rows = @(Test-ModuleSpecifiers $users $repoRoot)
    $ok = (@($statements.Uses).Count -eq 2) -and ($statements.Uses[0].Spec -eq './leaf') -and ($statements.Uses[0].Line -eq 2)
    $ok = $ok -and ($rows -contains 'users.ps1:3 ./gone (no file beside this module: ./gone)')
    Expect $ok ($rows -join '; ')
  }

  It 'tolerates a cycle and still orders every file' {
    $a = Join-Path $modDir 'cyc-a.ps1'
    $b = Join-Path $modDir 'cyc-b.ps1'
    [IO.File]::WriteAllText($a, ". (Use-Module './cyc-b' `$PSCommandPath)`r`n", $utf8)
    [IO.File]::WriteAllText($b, ". (Use-Module './cyc-a' `$PSCommandPath)`r`n", $utf8)
    $order = @(Get-ModuleOrder $a $repoRoot)
    $graph = Get-ModuleGraph $a $repoRoot
    $ok = ($order.Count -eq 2) -and ((Split-Path -Leaf $order[-1]) -eq 'cyc-a.ps1')
    $ok = $ok -and (@($graph.Cycles).Count -eq 1) -and ($graph.Cycles[0] -like 'cyc-b.ps1:1 closes a cycle*')
    Expect $ok ((@($graph.Cycles) -join '; ') + ' / ' + (@($order) -join ','))
  }
}

Describe 'the export set' {
  It 'folds a re-export, an all and a default' {
    $leaf = Join-Path $modDir 'exp-leaf.ps1'
    $mid = Join-Path $modDir 'exp-mid.ps1'
    $topFile = Join-Path $modDir 'exp-top.ps1'
    [IO.File]::WriteAllText($leaf, "function Get-LeafValue { return 'leaf' }`r`nfunction Get-Other { return 'o' }`r`nExport-Function Get-LeafValue, Get-Other`r`n", $utf8)
    [IO.File]::WriteAllText($mid, ". (Use-Module './exp-leaf' `$PSCommandPath)`r`nExport-Function -All -From './exp-leaf'`r`nfunction Get-MidValue { return (Get-LeafValue) }`r`nExport-Function Get-MidValue -Default`r`n", $utf8)
    [IO.File]::WriteAllText($topFile, ". (Use-Module './exp-mid' `$PSCommandPath)`r`nExport-Function Get-LeafValue -From './exp-mid'`r`n", $utf8)

    $graph = Get-ModuleGraph $topFile $repoRoot
    $folded = Resolve-ModuleExports $graph $repoRoot
    $midId = (New-ModuleMeta $mid $repoRoot).Id.ToLowerInvariant()
    $own = @($folded.Own[$midId] | Sort-Object)
    $ok = (($own -join ',') -eq 'Get-LeafValue,Get-MidValue,Get-Other')
    $ok = $ok -and ($folded.Default[$midId] -eq 'Get-MidValue')
    $ok = $ok -and (@($folded.Problems).Count -eq 0)
    $ok = $ok -and $folded.Exported.ContainsKey('Get-MidValue')
    Expect $ok (($own -join ',') + ' / ' + (@($folded.Problems) -join '; '))
  }

  It 'refuses a name the source does not export' {
    $leaf = Join-Path $modDir 'bad-leaf.ps1'
    $topFile = Join-Path $modDir 'bad-re.ps1'
    [IO.File]::WriteAllText($leaf, "function Get-LeafValue { return 'leaf' }`r`nExport-Function Get-LeafValue`r`n", $utf8)
    [IO.File]::WriteAllText($topFile, ". (Use-Module './bad-leaf' `$PSCommandPath)`r`nExport-Function Get-Absent -From './bad-leaf'`r`n", $utf8)
    $rows = @(Get-ModuleDiagnostics $topFile $repoRoot)
    $hit = @($rows | Where-Object { $_ -like 'bad-re.ps1:2*Get-Absent*' })
    Expect ($hit.Count -eq 1) ($rows -join '; ')
  }
}

Describe 'a conditional entry' {
  It 'takes [package.dev] Main when the condition is asked for' {
    $demo = Join-Path $modDir 'packages\demo'
    New-Item -ItemType Directory -Path $demo -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $demo 'package.ini'), "[package]`r`nName=demo`r`nMain=main.ps1`r`nExports=Get-Demo`r`n[package.dev]`r`nMain=dev.ps1`r`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $demo 'main.ps1'), "function Get-Demo { return 1 }`r`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $demo 'dev.ps1'), "function Get-Demo { return 2 }`r`n", $utf8)
    $plain = Resolve-ModuleSpecifier 'demo' '' $modDir
    $dev = Resolve-ModuleSpecifier 'demo' '' $modDir @('dev')
    $named = Resolve-ModuleSpecifier 'demo#Get-Demo' '' $modDir @('dev')
    $ok = ((Split-Path -Leaf $plain.Path) -eq 'main.ps1') -and ((Split-Path -Leaf $dev.Path) -eq 'dev.ps1')
    $ok = $ok -and (-not $named.Problem) -and ((Split-Path -Leaf $named.Path) -eq 'dev.ps1')
    Expect $ok ($plain.Path + ' / ' + $dev.Path + ' / ' + $named.Problem)
  }
}

Describe 'the parse cache' {
  It 'answers the same list twice and follows a file that changes' {
    $entry = Join-Path $modDir 'cache-top.ps1'
    $side = Join-Path $modDir 'cache-side.ps1'
    [IO.File]::WriteAllText($side, "function Get-Side { return 1 }`r`n", $utf8)
    [IO.File]::WriteAllText($entry, ". (Use-Module './cache-side' `$PSCommandPath)`r`n", $utf8)
    $first = @(Get-ModuleOrder $entry $repoRoot)
    $second = @(Get-ModuleOrder $entry $repoRoot)
    $fresh = @(Get-ModuleOrder $entry $repoRoot -NoCache)
    [IO.File]::WriteAllText($entry, ". (Use-Module './cache-side' `$PSCommandPath)`r`n. (Use-Module './leaf' `$PSCommandPath)`r`n", $utf8)
    [IO.File]::SetLastWriteTimeUtc($entry, [DateTime]::UtcNow.AddSeconds(5))
    $grown = @(Get-ModuleOrder $entry $repoRoot)
    $ok = ($first.Count -eq 2) -and ($second.Count -eq 2) -and ($fresh.Count -eq 2)
    $ok = $ok -and (($first -join ',') -eq ($second -join ','))
    $ok = $ok -and ($grown.Count -eq 3)
    Expect $ok ($first.Count.ToString() + ' ' + $second.Count.ToString() + ' ' + $grown.Count.ToString())
  }
}

Describe 'the module command' {
  It 'runs an entry that imports the file beside it' {
    $leaf = Join-Path $modDir 'run-b.ps1'
    $entry = Join-Path $modDir 'run-a.ps1'
    [IO.File]::WriteAllText($leaf, "function Add-Numbers(`$x, `$y) { `$x + `$y }`r`nExport-Function Add-Numbers`r`n", $utf8)
    [IO.File]::WriteAllText($entry, ". (Use-Module './run-b' `$PSCommandPath)`r`n'sum = ' + (Add-Numbers 3 4)`r`n", $utf8)
    $bin = Join-Path $repoRoot 'packages\module\bin\module.ps1'
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bin $entry 2>&1)
    $code = $LASTEXITCODE
    $text = ($out -join ' ')
    Expect (($code -eq 0) -and ($text -like '*sum = 7*')) ($code.ToString() + ' ' + $text)
  }

  It 'reports instead of running when an import names nothing' {
    $entry = Join-Path $modDir 'run-bad.ps1'
    [IO.File]::WriteAllText($entry, ". (Use-Module './nope' `$PSCommandPath)`r`n'ran'`r`n", $utf8)
    $bin = Join-Path $repoRoot 'packages\module\bin\module.ps1'
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bin -Check $entry 2>&1)
    $code = $LASTEXITCODE
    $text = ($out -join ' ')
    Expect (($code -eq 1) -and ($text -like '*run-bad.ps1:1*')) ($code.ToString() + ' ' + $text)
  }
}

Describe 'the module table' {
  It 'names files that exist and imports that resolve' {
    $entry = Join-Path $repoRoot 'src\clipboard.ps1'
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($entry, [ref]$tokens, [ref]$errors)

    # only the three module tables: the file has other strings with a backslash in them (a
    # regex, a message, a path under the package) and none of those is a module
    $names = @{}
    foreach ($a in @($ast.FindAll({
            param($n)
            ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and
            (([string]$n.Left.Extent.Text) -match '(baseModules|windowModules|groupModules)$')
          }, $true))) {
      foreach ($s in @($a.Right.FindAll({
              param($n)
              $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
              ([string]$n.Value) -match '\\'
            }, $true))) {
        $id = ([string]$s.Value) -replace '\\', '/'
        if ($id.ToLowerInvariant().EndsWith('.ps1')) { $id = $id.Substring(0, $id.Length - 4) }
        $names[$id.ToLowerInvariant()] = [string]$s.Value
      }
    }

    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($names.Keys)) {
      $rel = ([string]$names[$key]) -replace '/', '\'
      $file = Join-Path $repoRoot ('src\' + $rel + '.ps1')
      if (-not (Test-Path -LiteralPath $file)) { $problems.Add('the table names a file that is not there: ' + $rel); continue }
      foreach ($use in @((Get-ModuleDirectives $file).Uses)) {
        $ref = Resolve-ModuleSpecifier $use $file $repoRoot
        if ($ref.Problem) { $problems.Add($rel + ': ' + $use + ' (' + $ref.Problem + ')') }
      }
    }
    Expect ($problems.Count -eq 0) (($problems.Count.ToString() + ' of ' + $names.Count.ToString() + ': ') + ($problems -join '; '))
  }
}

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

# the rows above run after every Describe has been collected, so the files they read have to
# outlive the collection: this is the first line that may delete them
Remove-Item -LiteralPath $modDir -Recurse -Force -ErrorAction SilentlyContinue

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
    Expect (($problems.Count -gt 0) -and ($problems[0] -like '*Get-Missing*')) ($problems -join '; ')
  }
}

Complete-TestPart -ResultFile $ResultFile -Quiet:$Quiet

# the rows above run after every Describe has been collected, so the files they read have to
# outlive the collection: this is the first line that may delete them
Remove-Item -LiteralPath $modDir -Recurse -Force -ErrorAction SilentlyContinue

#Requires -Version 5.1
<#
  tools\bundler\lib\emit.ps1 - one text out of many modules, and the proof that it is the same
  program.

  A bundle is built by taking each module's top-level statements, in module order, and reading
  each one through its own extent. Nothing is sliced by hand, nothing is searched for: the
  offsets come from the parser, so a "#region" line, a file header comment or an odd blank line
  cannot end up in the middle of a statement or be cut out of one.

  Get-BundleFingerprint then reads the finished text back and describes it the same way, so
  Compare-BundleFingerprint can say "this bundle is the modules the list named, in that order"
  instead of the weaker "it ran without throwing".
#>

# The text of one module body: every top-level statement through its extent. A definition that
# the reachability walk dropped is left out here, which is where dropping happens - not by
# deleting text afterwards.
. (Use-Module './ast.ps1' $PSCommandPath -Named Get-BundleCommandNames, Get-BundleParse, Get-BundleStatements)

function New-BundleModuleText($module) {
  $parts = New-Object System.Collections.Generic.List[string]
  $kept = @()
  if ($null -ne $module.Kept) { $kept = @($module.Kept) }
  foreach ($s in @(Get-BundleStatements $module.Ast)) {
    if ($s -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
      if ($kept.Count -gt 0 -and -not ($kept -contains [string]$s.Name)) { continue }
    }
    $text = [string]$s.Extent.Text
    if ($text) { $parts.Add($text) }
  }
  return ($parts -join "`r`n")
}

# The whole bundle text, module by module, plus the description the finished text must match.
function New-BundleChunk($modules) {
  $parts = New-Object System.Collections.Generic.List[string]
  $functions = New-Object System.Collections.Generic.List[string]
  $commands = New-Object System.Collections.Generic.List[string]
  $shapes = New-Object System.Collections.Generic.List[string]
  foreach ($m in @($modules)) {
    $body = New-BundleModuleText $m
    if ($body) { $parts.Add($body) }
    $fp = Get-BundleFingerprint $body
    foreach ($n in @($fp.Functions)) { $functions.Add($n) }
    foreach ($n in @($fp.Commands)) { $commands.Add($n) }
    foreach ($n in @($fp.Shapes)) { $shapes.Add($n) }
  }
  return @{
    Text      = ($parts -join "`r`n")
    Functions = $functions.ToArray()
    Commands  = $commands.ToArray()
    Shapes    = $shapes.ToArray()
  }
}

# What a piece of script is made of, as the parser describes it.
function Get-BundleFingerprint([string]$text) {
  $parsed = Get-BundleParse $text
  if ($parsed.Errors.Count -gt 0) {
    throw ('the merged text does not parse: ' + [string]$parsed.Errors[0].Message)
  }
  $ast = $parsed.Ast
  $functions = New-Object System.Collections.Generic.List[string]
  $shapes = New-Object System.Collections.Generic.List[string]
  foreach ($s in @(Get-BundleStatements $ast)) {
    $shapes.Add($s.GetType().Name)
    if ($s -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $functions.Add([string]$s.Name) }
  }
  return @{
    Functions = $functions.ToArray()
    Commands  = @(Get-BundleCommandNames $ast)
    Shapes    = $shapes.ToArray()
    Parsed    = $parsed
  }
}

# Every way the bundle differs from the modules it was built from. An empty list means the
# bundle is those modules: same definitions, same order, same statements.
function Compare-BundleFingerprint($expected, $actual, [switch]$Renamed) {
  $problems = New-Object System.Collections.Generic.List[string]
  $wantF = (@($expected.Functions) -join ' ')
  $gotF = (@($actual.Functions) -join ' ')
  if ($wantF -ne $gotF) {
    $problems.Add('definitions differ: expected [' + $wantF + '], found [' + $gotF + ']')
  }
  $wantS = (@($expected.Shapes) -join ' ')
  $gotS = (@($actual.Shapes) -join ' ')
  if ($wantS -ne $gotS) {
    $problems.Add('statement order differs: expected ' + @($expected.Shapes).Count + ' statement(s), found ' + @($actual.Shapes).Count)
  }
  # a rename rewrites command names on purpose, so only their number is comparable then
  if ($Renamed) {
    if (@($expected.Commands).Count -ne @($actual.Commands).Count) {
      $problems.Add('command count differs: expected ' + @($expected.Commands).Count + ', found ' + @($actual.Commands).Count)
    }
  } else {
    $wantC = (@($expected.Commands) -join ' ')
    $gotC = (@($actual.Commands) -join ' ')
    if ($wantC -ne $gotC) { $problems.Add('commands differ') }
  }
  return $problems.ToArray()
}

Export-Function Compare-BundleFingerprint, Get-BundleFingerprint, New-BundleChunk, New-BundleModuleText


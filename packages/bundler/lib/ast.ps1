#Requires -Version 5.1
<#
  tools\bundler\lib\ast.ps1 - a module as the parser sees it.

  The bundler never decides a module boundary by looking at text: no regular expression finds
  a "function", no blank line ends a header, no comment marker is searched for. A module is
  its parsed ScriptBlockAst, and the body that goes into a bundle is the statement list of
  that AST, taken statement by statement through the node's own extent.

  A module is inlinable when its body is a plain sequence of statements. A script that needs a
  param block, a begin / process / end block, a dynamic parameter, a trap or a #Requires line
  cannot be glued into a larger script without changing what it means, so Get-BundleRejectReason
  names it instead of merging it. The entry itself may declare a param block and #Requires: it
  is the one file whose header survives, so it is checked with -Entry.
#>

# Parse one module. Never throws: the errors come back so the caller can report the file.
function Get-BundleParse([string]$text) {
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
  return @{ Ast = $ast; Tokens = @($tokens); Errors = @($errors) }
}

# The first thing that makes this module impossible to inline, or "" when it can be inlined.
# Every answer is about a node type the parser reported, never about how the text looks.
function Get-BundleRejectReason($parsed, [switch]$Entry) {
  if ($null -eq $parsed -or $null -eq $parsed.Ast) { return 'was not parsed' }
  if ($parsed.Errors.Count -gt 0) { return ('does not parse: ' + [string]$parsed.Errors[0].Message) }
  $ast = $parsed.Ast
  if ($Entry) {
    if ($null -ne $ast.DynamicParamBlock) { return 'declares a dynamic parameter block' }
  } else {
    if ($null -ne $ast.ParamBlock) { return 'declares a param block' }
    if ($null -ne $ast.DynamicParamBlock) { return 'declares a dynamic parameter block' }
    if ($null -ne $ast.ScriptRequirements) { return 'declares #Requires' }
  }
  if ($null -ne $ast.BeginBlock) { return 'declares a begin block' }
  if ($null -ne $ast.ProcessBlock) { return 'declares a process block' }
  if ($null -ne $ast.EndBlock -and -not $ast.EndBlock.Unnamed) { return 'declares an end block' }
  $block = $ast.EndBlock
  if ($null -eq $block) { return '' }
  # a trap is not a statement: the parser keeps it on the block beside them
  if ($null -ne $block.Traps -and @($block.Traps).Count -gt 0) { return 'declares a trap' }
  return ''
}

# The statements that make up the module body. Using statements are not here: the parser keeps
# them in UsingStatements, which is where the merge takes them from when it hoists them.
function Get-BundleStatements($ast) {
  if ($null -eq $ast -or $null -eq $ast.EndBlock) { return @() }
  return @($ast.EndBlock.Statements)
}

# The names this module defines at its own top level, in source order. A nested function is not
# listed: it travels inside the function that declares it.
function Get-BundleFunctionNames($ast) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($s in @(Get-BundleStatements $ast)) {
    if ($s -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $out.Add([string]$s.Name) }
  }
  return $out.ToArray()
}

# Every command name the module looks up at run time, at any nesting level.
function Get-BundleCommandNames($ast) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($c in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
    $name = [string]$c.GetCommandName()
    if ($name) { $out.Add($name) }
  }
  return $out.ToArray()
}

# Names the module asks for by string - "Get-Command Foo-Bar", "& 'Foo-Bar'". They are calls the
# reachability walk cannot see as a command, so they come back as extra roots instead of being a
# reason to keep everything.
function Get-BundleLookupNames($ast) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($c in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
    if ($c.CommandElements.Count -lt 2) { continue }
    $head = [string]$c.GetCommandName()
    $operator = [string]$c.InvocationOperator
    $isLookup = $head -and (@('get-command', 'invoke-command') -contains $head.ToLowerInvariant())
    $isCall = ($operator -eq 'Ampersand') -or ($operator -eq 'Dot')
    if (-not $isLookup -and -not $isCall) { continue }
    $arg = $c.CommandElements[1]
    if ($arg -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $out.Add([string]$arg.Value) }
  }
  return $out.ToArray()
}

# Function names written inside a string literal, including a here-string. The text is data: no
# later pass can rewrite it, so a name it spells has to stay defined - the same conservative rule
# rolldown applies to code it cannot analyse. Names that are no definition are ignored by the walk.
function Get-BundleStringNames($ast) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($s in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))) {
    foreach ($m in [regex]::Matches([string]$s.Value, '(?<![A-Za-z0-9_-])[A-Z][A-Za-z0-9]+-[A-Z][A-Za-z0-9]+')) {
      $out.Add($m.Value)
    }
  }
  return $out.ToArray()
}

# Does the module invoke a scriptblock it was handed? "& $cb" may run any function of the module
# through a closure, so the walk keeps every definition of that module - the module, not the
# whole bundle.
function Test-BundleBlockInvoke($ast) {
  foreach ($c in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
    if ([string]$c.InvocationOperator -ne 'Ampersand') { continue }
    if ($c.CommandElements.Count -eq 0) { continue }
    if ($c.CommandElements[0] -is [System.Management.Automation.Language.VariableExpressionAst]) { return $true }
    if ($c.CommandElements[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $true }
  }
  return $false
}

# Reasons the reachability walk cannot be trusted for this module.
#
# Only two things really stop it: code that arrives from somewhere the walk cannot read (a
# dot-sourced path), and a name held in a string and invoked (Invoke-Expression, or "& $name"
# where $name was assigned a literal). Anything else is not opacity - a call through a
# scriptblock is handled per module by Test-BundleBlockInvoke.
function Test-BundleOpaque($ast) {
  $reasons = New-Object System.Collections.Generic.List[string]

  # a variable that was given a literal name and then invoked as a command
  $named = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  foreach ($a in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
    if ($a.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
    if ($a.Right -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
    [void]$named.Add([string]$a.Left.VariablePath.UserPath)
  }

  foreach ($c in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
    $head = $null
    if ($c.CommandElements.Count -gt 0) { $head = $c.CommandElements[0] }
    if ($null -eq $head) { continue }
    $name = [string]$c.GetCommandName()
    $operator = [string]$c.InvocationOperator

    if ($name -and $name.ToLowerInvariant() -eq 'invoke-expression') {
      $reasons.Add('calls Invoke-Expression')
      continue
    }
    if ($operator -eq 'Dot' -and $head -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
      $reasons.Add('dot-sources a path it computes')
      continue
    }
    if ($operator -eq 'Ampersand' -and $head -is [System.Management.Automation.Language.VariableExpressionAst]) {
      $varName = [string]$head.VariablePath.UserPath
      if ($named.Contains($varName)) { $reasons.Add('invokes a name it kept in $' + $varName) }
    }
  }
  return @($reasons | Select-Object -Unique)
}


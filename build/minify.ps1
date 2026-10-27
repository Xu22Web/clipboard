#Requires -Version 5.1
<#
  minify.ps1 - PowerShell minifier for this tool's own scripts.

  Works on the parser output, like a front-end bundler works on an ESTree:

    1. lexical pass   drop comments, indentation and blank lines (a #Requires line stays)
    2. syntax pass    rename internal functions (one map shared by every file) and local
                      variables (one map per file), replacing the extents the parser
                      reports instead of doing text substitution

  Never renamed: parameters (they are passed by name: -Library, -Count, -NoInject), any
  variable with a scope/drive qualifier ($script:, $env:, $using:), PowerShell automatic
  variables, member and hash keys (not variables at all), and anything reached through
  Get-Command <name>.

  The result is still a .ps1 with the same behaviour; build.ps1 proves that by running
  the whole test suite against the minified copy before it accepts the package.
#>

$script:LetterPool = 'abcdefghijklmnopqrstuvwxyz'

# Names that must survive: automatic variables, and anything the runtime or a caller
# may look up by name.
$script:ReservedVariables = @(
  '_', 'args', 'input', 'this', 'PSItem', 'PSBoundParameters', 'PSScriptRoot',
  'PSCommandPath', 'MyInvocation', 'Matches', 'Error', 'true', 'false', 'null',
  'LASTEXITCODE', 'Host', 'PID', 'PSVersionTable', 'ExecutionContext', 'PSCulture',
  'PSUICulture', 'ShellId', 'StackTrace', 'OFS', 'Profile', 'HOME', 'PWD', 'PSCmdlet',
  'PSDebugContext', 'Event', 'EventArgs', 'Sender', 'IsCoreCLR', 'IsWindows',
  'IsLinux', 'IsMacOS'
)

# a1, b1 ... z1, a2 ... short, unique, and never a PowerShell keyword
function New-ShortName([int]$index) {
  $n = [Math]::Max(0, $index)
  $letter = [string]$script:LetterPool[$n % 26]
  if ($n -lt 26) { return $letter }
  return $letter + [string]([int][Math]::Floor($n / 26))
}

function Get-ParsedScript([string]$text) {
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
  return @{ Ast = $ast; Tokens = $tokens; Errors = $errors }
}

# Every name a command is looked up by at runtime (Get-Command <literal>) must keep its
# name, otherwise the lookup silently fails after renaming.
function Get-LookedUpNames($ast) {
  $out = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
  foreach ($c in $cmds) {
    if ([string]$c.GetCommandName() -ne 'Get-Command') { continue }
    if ($c.CommandElements.Count -lt 2) { continue }
    $arg = $c.CommandElements[1]
    if ($arg -is [System.Management.Automation.Language.StringConstantExpressionAst]) { [void]$out.Add([string]$arg.Value) }
  }
  return $out
}

# Functions defined in one file that can be renamed safely.
function Get-RenameableFunctions($ast, $protected) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $name = [string]$f.Name
    if (-not $name) { continue }
    if ($protected.Contains($name)) { continue }
    if ($out -contains $name) { continue }
    $out.Add($name)
  }
  return $out
}

# Parameter names of the whole file, at any nesting level: callers pass them by name.
function Get-ParameterNames($ast) {
  $keep = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  foreach ($p in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
    $n = [string]$p.Name.VariablePath.QualifiedName
    if ($n) { [void]$keep.Add($n) }
  }
  return $keep
}

# Build one function map for the whole project so lib/plugins.ps1, clipboard.ps1 and the
# plugins agree on the new names.
function New-FunctionMap([string[]]$paths) {
  $protected = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($path in $paths) {
    $text = [IO.File]::ReadAllText($path)
    $parsed = Get-ParsedScript $text
    if ($parsed.Errors.Count -gt 0) { throw ('cannot parse ' + $path + ': ' + $parsed.Errors[0].Message) }
    foreach ($n in (Get-LookedUpNames $parsed.Ast)) { [void]$protected.Add($n) }
    foreach ($f in (Get-RenameableFunctions $parsed.Ast $protected)) {
      if (-not $names.Contains($f)) { $names.Add($f) }
    }
  }
  # a second pass: a name looked up in file B must not be renamed because file A used it.
  # The new names avoid every alias and command on the machine: "fl" would be Format-List
  # and the call site would silently hit the alias instead of the renamed function.
  $taken = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  foreach ($a in @(Get-Alias -ErrorAction SilentlyContinue)) { [void]$taken.Add([string]$a.Name) }
  foreach ($c in @(Get-Command -CommandType Function, Cmdlet, ExternalScript -ErrorAction SilentlyContinue)) { [void]$taken.Add([string]$c.Name) }
  $map = @{}
  $i = 0
  foreach ($n in $names) {
    if ($protected.Contains($n)) { continue }
    $candidate = 'zz' + $i
    while ($taken.Contains($candidate)) { $i++; $candidate = 'zz' + $i }
    $i++
    [void]$taken.Add($candidate)
    $map[$n] = $candidate
  }
  return $map
}

# Replace the text of a set of parser extents, right to left so earlier offsets stay valid.
function Apply-Edits([string]$text, $edits) {
  $seen = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  $clean = New-Object System.Collections.Generic.List[object]
  foreach ($e in $edits) {
    $off = [int]$e.Offset
    $len = [int]$e.Length
    if ($off -lt 0 -or $len -lt 0) { continue }
    if (($off + $len) -gt $text.Length) { continue }
    $key = [string]$off + ':' + [string]$len
    if (-not $seen.Add($key)) { continue }
    $clean.Add(@{ Offset = $off; Length = $len; Text = [string]$e.Text })
  }
  $sorted = @($clean | Sort-Object -Property { [int]$_.Offset } -Descending)
  # report the colliding pair instead of writing a broken file
  $byStart = @($clean | Sort-Object -Property { [int]$_.Offset })
  for ($i = 1; $i -lt $byStart.Count; $i++) {
    $prev = $byStart[$i - 1]
    $cur = $byStart[$i]
    if (($prev.Offset + $prev.Length) -gt $cur.Offset) {
      $from = [Math]::Max(0, $prev.Offset - 40)
      $len = [Math]::Min(160, $text.Length - $from)
      throw ('edits overlap: "' + $prev.Text + '" (' + $prev.Offset + '+' + $prev.Length + ') and "' + $cur.Text + '" (' + $cur.Offset + '+' + $cur.Length + ') near: ' + $text.Substring($from, $len).Replace("`n", ' ').Replace("`r", ''))
    }
  }
  $sb = New-Object System.Text.StringBuilder($text)
  foreach ($e in $sorted) {
    [void]$sb.Remove($e.Offset, $e.Length)
    [void]$sb.Insert($e.Offset, $e.Text)
  }
  return $sb.ToString()
}

# PowerShell's tokenizer does not emit whitespace at all, so the separator between two
# tokens has to be decided here. A space goes in wherever gluing the two would change how
# they are read: word next to word, a parameter name after a command, an operator that
# starts with - or + after a value.
# Lexical pass: comments, indentation, blank lines. Whether two tokens were separated in
# the source is read from their offsets - the tokenizer drops whitespace, and guessing the
# separator would change meaning ("$box.Height (Px 4)" is two arguments, "$f($x)" is a
# call). Everything else is collapsed: many spaces become one, indentation and blank lines
# disappear.
function Compress-Whitespace([string]$text) {
  $parsed = Get-ParsedScript $text
  if ($parsed.Errors.Count -gt 0) { throw ('cannot tokenize: ' + $parsed.Errors[0].Message) }
  $sb = New-Object System.Text.StringBuilder
  $prevEnd = 0
  $atLineStart = $true
  foreach ($t in $parsed.Tokens) {
    $kind = [string]$t.Kind
    if ($kind -eq 'Comment') {
      # #Requires is an instruction, not a comment
      if ($t.Text -match '(?i)^#requires') {
        if (-not $atLineStart) { [void]$sb.Append([Environment]::NewLine) }
        [void]$sb.Append($t.Text.TrimEnd())
        $prevEnd = $t.Extent.EndOffset
        $atLineStart = $false
      }
      continue
    }
    if ($kind -eq 'NewLine') {
      # one line break per statement, no blank lines
      if (-not $atLineStart) { [void]$sb.Append([Environment]::NewLine) }
      $prevEnd = $t.Extent.EndOffset
      $atLineStart = $true
      continue
    }
    if ($kind -eq 'EndOfInput') { break }
    if (-not $atLineStart -and $t.Extent.StartOffset -gt $prevEnd) { [void]$sb.Append(' ') }
    [void]$sb.Append([string]$t.Text)
    $prevEnd = $t.Extent.EndOffset
    $atLineStart = $false
  }
  return $sb.ToString()
}

# Minify one file. $FunctionMap comes from New-FunctionMap, so all files agree.
function Invoke-MinifyFile {
  param(
    [string]$Path,
    [string]$OutPath,
    [hashtable]$FunctionMap = @{},
    [switch]$NoRename
  )
  $text = [IO.File]::ReadAllText($Path)
  $parsed = Get-ParsedScript $text
  if ($parsed.Errors.Count -gt 0) { throw ($Path + ': ' + $parsed.Errors[0].Message) }
  $ast = $parsed.Ast

  $renamed = $text
  if (-not $NoRename) {
    $edits = New-Object System.Collections.Generic.List[object]

    # internal functions: the declaration (found through its tokens: Function + Identifier)
    # and every call site
    if ($FunctionMap.Count -gt 0) {
      $tokens = $parsed.Tokens
      for ($i = 0; $i -lt ($tokens.Count - 1); $i++) {
        $kind = [string]$tokens[$i].Kind
        if ($kind -ne 'Function' -and $kind -ne 'Filter') { continue }
        $nameToken = $tokens[$i + 1]
        # a name with a dash (Get-Foo) is a Generic token, a plain one an Identifier
        $nameKind = [string]$nameToken.Kind
        if ($nameKind -ne 'Identifier' -and $nameKind -ne 'Generic') { continue }
        $old = [string]$nameToken.Text
        if (-not $FunctionMap.ContainsKey($old)) { continue }
        $edits.Add(@{ Offset = $nameToken.Extent.StartOffset; Length = $nameToken.Extent.EndOffset - $nameToken.Extent.StartOffset; Text = [string]$FunctionMap[$old] })
      }
      foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $old = [string]$c.GetCommandName()
        if (-not $old -or -not $FunctionMap.ContainsKey($old)) { continue }
        $head = $c.CommandElements[0]
        $edits.Add(@{ Offset = $head.Extent.StartOffset; Length = $head.Extent.EndOffset - $head.Extent.StartOffset; Text = [string]$FunctionMap[$old] })
      }
    }

    # local variables: one stable new name per original name, never colliding with a
    # name the file already uses
    $keep = Get-ParameterNames $ast
    # a plain $x and $script:x are the same variable at script scope: if the file uses the
    # qualified form anywhere, $x must keep its name or the two drift apart
    $qualified = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    $taken = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $script:ReservedVariables) { [void]$taken.Add($r) }
    foreach ($v in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
      $vp = $v.VariablePath
      $plain = [string]$vp.UnqualifiedPath
      [void]$taken.Add($plain)
      if ($vp.IsDriveQualified -or $vp.IsGlobal -or $vp.IsScript -or $vp.IsPrivate -or $vp.IsLocal) { [void]$qualified.Add($plain) }
    }
    $varMap = @{}
    $slot = 0
    foreach ($v in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
      $varPath = $v.VariablePath
      if ($varPath.IsDriveQualified -or $varPath.IsGlobal -or $varPath.IsScript -or $varPath.IsPrivate -or $varPath.IsLocal) { continue }
      $name = [string]$varPath.UnqualifiedPath
      if (-not $name -or $keep.Contains($name)) { continue }
      if ($qualified.Contains($name)) { continue }
      if ($script:ReservedVariables -contains $name) { continue }
      if (-not $varMap.ContainsKey($name)) {
        $new = New-ShortName $slot
        while ($taken.Contains($new)) { $slot++; $new = New-ShortName $slot }
        $slot++
        [void]$taken.Add($new)
        $varMap[$name] = $new
      }
      $edits.Add(@{ Offset = $v.Extent.StartOffset; Length = $v.Extent.EndOffset - $v.Extent.StartOffset; Text = '$' + [string]$varMap[$name] })
    }

    if ($edits.Count -gt 0) { $renamed = Apply-Edits $text $edits }

    # renaming can introduce a clash (two names mapping to one): check before going on
    $check = Get-ParsedScript $renamed
    if ($check.Errors.Count -gt 0) { throw ($Path + ': rename broke the syntax (' + $check.Errors[0].Message + ')') }
  }

  $minified = Compress-Whitespace $renamed
  $final = Get-ParsedScript $minified
  if ($final.Errors.Count -gt 0) {
    $err = $final.Errors[0]
    $around = $minified
    $idx = [Math]::Max(0, $err.Extent.StartOffset - 80)
    $len = [Math]::Min(200, $minified.Length - $idx)
    throw ($Path + ': minified result does not parse at line ' + $err.Extent.StartLineNumber + ' (' + $err.Message + ') near: ' + $around.Substring($idx, $len).Replace("`n", ' | ').Replace("`r", ''))
  }

  $utf8 = New-Object System.Text.UTF8Encoding $false
  [IO.File]::WriteAllText($OutPath, $minified, $utf8)
  return [pscustomobject]@{
    Path   = $Path
    Before = $text.Length
    After  = $minified.Length
  }
}

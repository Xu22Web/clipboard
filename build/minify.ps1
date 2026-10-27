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
    $n = Get-VariableName $p.Name.VariablePath
    if ($n) { [void]$keep.Add($n) }
  }
  return , $keep
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
  $slot = 0
  foreach ($n in $names) {
    if ($protected.Contains($n)) { continue }
    # one or two characters, like the local variables: a call site pays for the name once
    # and the project has over a thousand of them
    $candidate = New-ShortName $slot
    while ($taken.Contains($candidate)) { $slot++; $candidate = New-ShortName $slot }
    $slot++
    [void]$taken.Add($candidate)
    $map[$n] = $candidate
  }
  return $map
}

# the bare name of a variable: VariablePath.UnqualifiedPath comes back empty in this
# runtime, while UserPath gives "x" for $x and "script:x" for $script:x
function Get-VariableName($variablePath) {
  $u = [string]$variablePath.UserPath
  if (-not $u) { return '' }
  if ($u -match '(?i)^script:(.+)$') { return $Matches[1] }
  if ($u.Contains(':')) { return '' }
  return $u
}

# the bare name of a $script: reference: VariablePath.UserPath keeps the "script:" prefix
# and UnqualifiedPath comes back empty for a scoped variable
function Get-ScriptVariableName($variablePath) {
  $u = [string]$variablePath.UserPath
  if ($u -match '(?i)^script:(.+)$') { return $Matches[1] }
  return ''
}

# $script: names share one scope with the files that are dot-sourced into the main script,
# so those files get one map. A plugin runs in a scope of its own and gets its own map.
# Names keep the s prefix so they never read like a local variable, and a name that also
# appears unqualified ($x next to $script:x) is left alone: renaming one of the two would
# split what the runtime treats as a single variable.
function New-ScriptVariableMap([string[]]$paths) {
  $taken = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  $plain = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  $names = New-Object System.Collections.Generic.List[string]
  $asts = @()
  foreach ($path in $paths) {
    $ast = (Get-ParsedScript ([IO.File]::ReadAllText($path))).Ast
    $asts += $ast
    foreach ($v in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
      $vp = $v.VariablePath
      if ($vp.IsScript) {
        $n = Get-ScriptVariableName $vp
        if (-not $n) { continue }
        if (-not $names.Contains($n)) { $names.Add($n) }
        [void]$taken.Add($n)
      } else {
        $pn = Get-VariableName $vp
        if ($pn) { [void]$plain.Add($pn) }
      }
    }
  }
  $map = @{}
  $slot = 0
  foreach ($n in $names) {
    if ($plain.Contains($n)) { continue }
    $candidate = 's' + (New-ShortName $slot)
    while ($taken.Contains($candidate)) { $slot++; $candidate = 's' + (New-ShortName $slot) }
    $slot++
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

# A line break between these two tokens cannot change how they read: the left one already
# separates statements ({ , | ( [ = ; &) or the right one closes a block or a group.
function Test-CanJoinLine([string]$a, [string]$b) {
  if (@('{', ',', '|', '(', '[', '=', ';', '&') -contains $a) { return $true }
  if (@('}', ')', ']') -contains $b) { return $true }
  return $false
}

# Statements that the parser puts in one block can always be separated by a semicolon
# instead of a line break, whatever token they happen to start and end with. This is the
# statement pass of a bundler: the parser already knows where one statement ends, so the
# replacement needs no guessing (the lexical pass alone can only collapse a few boundaries).
function Merge-Statements([string]$text) {
  $parsed = Get-ParsedScript $text
  if ($parsed.Errors.Count -gt 0) { throw ('cannot parse statements: ' + $parsed.Errors[0].Message) }
  $edits = New-Object System.Collections.Generic.List[object]
  $blocks = $parsed.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StatementBlockAst] }, $true)
  foreach ($block in $blocks) {
    $stmts = @($block.Statements)
    for ($i = 0; $i -lt ($stmts.Count - 1); $i++) {
      $end = $stmts[$i].Extent.EndOffset
      $next = $stmts[$i + 1].Extent.StartOffset
      if ($next -le $end) { continue }
      $gap = $text.Substring($end, $next - $end)
      if ($gap -notmatch "[`r`n]") { continue }
      # the gap holds only whitespace and comments: a semicolon keeps the two apart
      $edits.Add(@{ Offset = $end; Length = ($next - $end); Text = ';' })
    }
  }
  if ($edits.Count -eq 0) { return $text }
  return (Apply-Edits $text $edits)
}

# Gluing two tokens is only safe when neither the reading nor the token split changes:
# two word-ends would merge, a parameter name would be swallowed by the command, and a
# bare - or + would turn into the sign of the next number.
# token kinds that always need a separator after them unless a bracket or a brace follows:
# "if($x){" is fine, "in[IO.File]" and "throw'x'" are not
$script:KeywordKinds = @(
  'Keyword', 'If', 'Else', 'ElseIf', 'Foreach', 'For', 'While', 'Do', 'Switch', 'Function',
  'Filter', 'Param', 'Return', 'Throw', 'Try', 'Catch', 'Finally', 'Trap', 'Begin',
  'Process', 'End', 'In', 'Break', 'Continue', 'Exit', 'Class', 'Enum', 'Using', 'Data',
  'Workflow', 'Parallel', 'Sequence', 'Static', 'Hidden'
)

function Test-NeedsSpace($a, $b, $before) {
  $at = [string]$a.Text
  $bt = [string]$b.Text
  if (-not $at -or -not $bt) { return $false }
  $aKind = [string]$a.Kind
  $bKind = [string]$b.Kind
  if ($script:KeywordKinds -contains $aKind) { return -not ($bt -eq '(' -or $bt -eq '{') }
  if ($aKind -eq 'Parameter' -or $bKind -eq 'Parameter') { return $true }
  # Gluing is allowed only around punctuation whose reading cannot change; everything else
  # keeps one space ("Join-Path $Root 'x'" must not become "Join-Path $Root'x'", and a bare
  # word followed by an argument would turn both into one command name).
  if (@('(', '[', '{', '@{', '@(', ',', ';', '=', '|', '&', '.', '::', '+', '*', '/', '%', '!', '>', '<') -contains $at) {
    # an operator followed by a type literal keeps its gap: "-ne[char]1" reads as a parameter
    if ($bt[0] -eq '[' -and $at -match '^[-+*/%!<>]') { return $true }
    return $false
  }
  if (@(')', ']', '}', ',', ';', '|', '=', '.', '::') -contains $bt) { return $false }
  # an index or a type annotation after a value stays glued: $x[0]
  if ($bt[0] -eq '[') { return $false }
  return $true
}

# Lexical pass: comments, indentation, blank lines, optional line breaks and every space
# that is not needed. Whether two tokens were separated in the source is read from their
# offsets - the tokenizer drops whitespace, and guessing the separator would change
# meaning ("$box.Height (Px 4)" is two arguments, "$f($x)" is a call).
function Compress-Whitespace([string]$text) {
  $parsed = Get-ParsedScript $text
  if ($parsed.Errors.Count -gt 0) { throw ('cannot tokenize: ' + $parsed.Errors[0].Message) }
  $nl = "`n"
  $sb = New-Object System.Text.StringBuilder
  $prev = $null
  $prevPrev = $null
  $pendingNewline = $false
  foreach ($t in $parsed.Tokens) {
    $kind = [string]$t.Kind
    if ($kind -eq 'Comment') {
      # #Requires is an instruction, not a comment
      if ($t.Text -match '(?i)^#requires') {
        if ($null -ne $prev) { [void]$sb.Append($nl) }
        [void]$sb.Append($t.Text.TrimEnd())
        $prev = $t
        $pendingNewline = $true
      }
      continue
    }
    if ($kind -eq 'NewLine') { $pendingNewline = $true; continue }
    if ($kind -eq 'EndOfInput') { break }
    if ($null -ne $prev) {
      if ($pendingNewline) {
        if (-not (Test-CanJoinLine ([string]$prev.Text) ([string]$t.Text))) {
          [void]$sb.Append($nl)
        } elseif (Test-NeedsSpace $prev $t $prevPrev) {
          [void]$sb.Append(' ')
        }
      } elseif ($t.Extent.StartOffset -gt $prev.Extent.EndOffset) {
        # the source had a space here: keep one when gluing would change the reading
        if (Test-NeedsSpace $prev $t $prevPrev) { [void]$sb.Append(' ') }
      }
      # tokens that were already adjacent stay adjacent: that spelling parsed before
    }
    [void]$sb.Append([string]$t.Text)
    $prevPrev = $prev
    $prev = $t
    $pendingNewline = $false
  }
  return $sb.ToString()
}

# Minify one file. $FunctionMap comes from New-FunctionMap, so all files agree.
function Invoke-MinifyFile {
  param(
    [string]$Path,
    [string]$OutPath,
    [hashtable]$FunctionMap = @{},
    [hashtable]$ScriptVarMap = @{},
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

    # $script: names: one map per scope group (see New-ScriptVariableMap)
    if ($ScriptVarMap.Count -gt 0) {
      foreach ($v in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $vp = $v.VariablePath
        if (-not $vp.IsScript) { continue }
        $n = Get-ScriptVariableName $vp
        if (-not $n -or -not $ScriptVarMap.ContainsKey($n)) { continue }
        $edits.Add(@{ Offset = $v.Extent.StartOffset; Length = $v.Extent.EndOffset - $v.Extent.StartOffset; Text = '$script:' + [string]$ScriptVarMap[$n] })
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
      $plain = Get-VariableName $vp
      if ($plain) { [void]$taken.Add($plain) }
      if ($vp.IsDriveQualified -or $vp.IsGlobal -or $vp.IsScript -or $vp.IsPrivate -or $vp.IsLocal) { [void]$qualified.Add($plain) }
    }
    $varMap = @{}
    $slot = 0
    foreach ($v in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
      $varPath = $v.VariablePath
      if ($varPath.IsDriveQualified -or $varPath.IsGlobal -or $varPath.IsScript -or $varPath.IsPrivate -or $varPath.IsLocal) { continue }
      $name = Get-VariableName $varPath
      if (-not $name) { continue }
      if ($keep.Contains($name)) { continue }
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

  # statement pass, then the lexical pass on what is left
  $merged = Merge-Statements $renamed
  $minified = Compress-Whitespace $merged
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

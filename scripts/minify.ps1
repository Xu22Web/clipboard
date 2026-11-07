#Requires -Version 5.1
<#
  minify.ps1 - PowerShell minifier for this tool's own scripts.

  Works on the parser output, like a front-end bundler works on an ESTree:

    1. lexical pass   drop comments, indentation and blank lines (a #Requires line stays)
    2. syntax pass    rename internal functions (one map shared by every file) and local
                      variables (one map per file), replacing the extents the parser
                      reports instead of doing text substitution
    3. C# pass        the C# in an Add-Type here-string is opaque to the other passes, but the
                      compiler does not care about its layout: comments out, one space only
                      where two word characters would merge
    4. call pass      -ErrorAction <name> becomes -ea <number>, the same documented interface
                      in fewer characters

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

# Build one function map for the whole project so lib/plugin/plugins.ps1, clipboard.ps1 and the
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

# a splat is a variable read with a different sigil, and the parser reports its extent from
# the '@': rebuilding the text with a '$' turns `f @h` into `f $h`, which passes the hashtable
# as the first positional argument instead of spreading it over the parameters
function Get-VariableSigil($node) {
  $text = [string]$node.Extent.Text
  if ($text.StartsWith('@')) { return '@' }
  return '$'
}

# the bare name of a variable: VariablePath.UnqualifiedPath comes back empty in this
# runtime, while UserPath gives "x" for $x and "script:x" for $script:x
function Get-VariableName($variablePath) {  $u = [string]$variablePath.UserPath
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

# Names assigned at script scope (outside every function) plus every $script: name. The
# modules of one build share one scope once they are dot-sourced, so these names must be
# renamed consistently across files; a per-file table would let lib\base.ps1 pick the same
# short name as the entry file and silently overwrite $Root.
function New-GlobalVariableMap([string[]]$paths) {
  $names = New-Object System.Collections.Generic.List[string]
  $taken = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  # a name written as $script:x somewhere belongs to New-ScriptVariableMap (or is left alone
  # when the same name is read bare); renaming it here too would split it into two variables
  $scripted = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  foreach ($path in $paths) {
    $scanned = Get-ParsedScript ([IO.File]::ReadAllText($path))
    if ($scanned.Errors.Count -gt 0) { continue }
    foreach ($v in $scanned.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
      if (-not $v.VariablePath.IsScript) { continue }
      $nm = Get-ScriptVariableName $v.VariablePath
      if ($nm) { [void]$scripted.Add($nm) }
    }
  }
  foreach ($path in $paths) {
    $parsed = Get-ParsedScript ([IO.File]::ReadAllText($path))
    if ($parsed.Errors.Count -gt 0) { continue }
    $ast = $parsed.Ast
    foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
      $parent = $a.Parent
      $inFunction = $false
      while ($null -ne $parent) {
        if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $inFunction = $true; break }
        $parent = $parent.Parent
      }
      if ($inFunction) { continue }
      $left = $a.Left
      if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $nm = Get-VariableName $left.VariablePath
        if ($nm -and -not $names.Contains($nm)) { $names.Add($nm) }
      }
    }
    foreach ($v in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
      if (-not $v.VariablePath.IsScript) { continue }
      $nm = Get-ScriptVariableName $v.VariablePath
      if ($nm -and -not $names.Contains($nm)) { $names.Add($nm) }
    }
  }
  foreach ($r in $script:ReservedVariables) { [void]$taken.Add($r) }
  $map = @{}
  $slot = 0
  foreach ($nm in $names) {
    if ($script:ReservedVariables -contains $nm) { continue }
    if ($scripted.Contains($nm)) {
      # also spelled $script:x somewhere: keep the spelling so both forms stay one variable
      $map[$nm] = $nm
      [void]$taken.Add($nm)
      continue
    }
    $candidate = 'g' + [string]$slot
    while ($taken.Contains($candidate)) { $slot++; $candidate = 'g' + [string]$slot }
    $slot++
    [void]$taken.Add($candidate)
    $map[$nm] = $candidate
  }
  return $map
}

# Replace the text of a set of parser extents, right to left so earlier offsets stay valid.
function Apply-Edits([string]$text, $edits) {  $seen = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
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

# ---- C# handed to Add-Type ------------------------------------------------
# A here-string is opaque to the lexical pass: its body is not PowerShell, so it travels
# untouched. But the body is C# and the compiler does not care about layout, so it gets what a
# JavaScript bundle gives a dependency - comments out, and one space only where two word
# characters (or two operators) would otherwise merge into a different token. A literal is
# copied through as it is, which is what keeps 'http://x' from losing half of itself.
$script:CSharpWordChars = '[A-Za-z0-9_]'
$script:CSharpOperatorChars = '[+\-*/%&|^<>=!?:]'

function Compress-CSharp([string]$code) {
  if ([string]::IsNullOrEmpty($code)) { return $code }
  $sb = New-Object System.Text.StringBuilder
  $i = 0
  $n = $code.Length
  $pendingSpace = $false
  while ($i -lt $n) {
    $c = $code[$i]
    if ($c -eq '/' -and ($i + 1) -lt $n) {
      $c2 = $code[$i + 1]
      if ($c2 -eq '/') {
        while ($i -lt $n -and $code[$i] -ne "`n" -and $code[$i] -ne "`r") { $i++ }
        $pendingSpace = $true
        continue
      }
      if ($c2 -eq '*') {
        $i = $i + 2
        while ($i -lt $n) {
          if ($code[$i] -eq '*' -and ($i + 1) -lt $n -and $code[$i + 1] -eq '/') { $i = $i + 2; break }
          $i++
        }
        $pendingSpace = $true
        continue
      }
    }
    if ($c -eq '@' -and ($i + 1) -lt $n -and $code[$i + 1] -eq '"') {
      $start = $i
      $i = $i + 2
      while ($i -lt $n) {
        if ($code[$i] -eq '"') {
          if (($i + 1) -lt $n -and $code[$i + 1] -eq '"') { $i = $i + 2; continue }
          $i++
          break
        }
        $i++
      }
      [void]$sb.Append($code.Substring($start, $i - $start))
      $pendingSpace = $false
      continue
    }
    if ($c -eq '"' -or $c -eq "'") {
      $quote = $c
      $start = $i
      $i++
      while ($i -lt $n) {
        if ($code[$i] -eq '\') { $i = $i + 2; continue }
        if ($code[$i] -eq $quote) { $i++; break }
        $i++
      }
      [void]$sb.Append($code.Substring($start, $i - $start))
      $pendingSpace = $false
      continue
    }
    if ([char]::IsWhiteSpace($c)) { $pendingSpace = $true; $i++; continue }
    if ($pendingSpace -and $sb.Length -gt 0) {
      $last = [string]$sb[$sb.Length - 1]
      $cur = [string]$c
      # two word characters would become one token ('int x' -> 'intx'), and two operators a
      # different operator ('a - -b' -> 'a--b')
      $needSpace = (($last -match $script:CSharpWordChars) -and ($cur -match $script:CSharpWordChars))
      if (-not $needSpace) { $needSpace = (($last -match $script:CSharpOperatorChars) -and ($cur -match $script:CSharpOperatorChars)) }
      if ($needSpace) { [void]$sb.Append(' ') }
    }
    $pendingSpace = $false
    [void]$sb.Append($c)
    $i++
  }
  return $sb.ToString()
}

# Every single quoted here-string whose body is C# gets squeezed; a "@..."@ body belongs to
# PowerShell (it interpolates), so it is left alone.
function Compress-CSharpBlocks([string]$text) {
  $parsed = Get-ParsedScript $text
  if ($parsed.Errors.Count -gt 0) { return $text }
  $edits = New-Object System.Collections.Generic.List[object]
  foreach ($t in $parsed.Tokens) {
    if ([string]$t.Kind -ne 'HereStringLiteral') { continue }
    $lines = ([string]$t.Text) -split "\r?\n"
    if ($lines.Count -lt 3) { continue }
    if (([string]$lines[0]).Trim() -ne "@'") { continue }
    if (([string]$lines[$lines.Count - 1]).Trim() -ne "'@") { continue }
    $body = ($lines[1..($lines.Count - 2)] -join "`n")
    # only a body that looks like C# is touched: a here-string full of help text stays
    if ($body -notmatch '(?m)^\s*(using |namespace |public |private |internal |protected |\[)') { continue }
    $squeezed = Compress-CSharp $body
    if ($squeezed.Length -ge $body.Length) { continue }
    $edits.Add(@{
        Offset = $t.Extent.StartOffset
        Length = $t.Extent.EndOffset - $t.Extent.StartOffset
        Text = ("@'" + "`n" + $squeezed + "`n" + "'@")
      })
  }
  if ($edits.Count -eq 0) { return $text }
  return (Apply-Edits $text $edits)
}

# ---- how a call spells its preference --------------------------------------
# -ErrorAction takes the name of an enum value, and every one of them also has a number. Both
# are the documented interface, so the call reads differently rather than acting differently.
$script:PreferenceNumbers = @{
  'SilentlyContinue' = '0'; 'Stop' = '1'; 'Continue' = '2'; 'Inquire' = '3'; 'Ignore' = '4'
}

function Compress-ErrorAction([string]$text) {
  $parsed = Get-ParsedScript $text
  if ($parsed.Errors.Count -gt 0) { return $text }
  $tokens = @($parsed.Tokens)
  $edits = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i -lt ($tokens.Count - 1); $i++) {
    if ([string]$tokens[$i].Kind -ne 'Parameter') { continue }
    if ([string]$tokens[$i].Text -ine '-ErrorAction') { continue }
    $j = $i + 1
    while ($j -lt $tokens.Count -and [string]$tokens[$j].Kind -eq 'NewLine') { $j++ }
    if ($j -ge $tokens.Count) { continue }
    $val = [string]$tokens[$j].Text
    if (-not $script:PreferenceNumbers.ContainsKey($val)) { continue }
    $edits.Add(@{ Offset = $tokens[$i].Extent.StartOffset; Length = $tokens[$i].Extent.EndOffset - $tokens[$i].Extent.StartOffset; Text = '-ea' })
    $edits.Add(@{ Offset = $tokens[$j].Extent.StartOffset; Length = $tokens[$j].Extent.EndOffset - $tokens[$j].Extent.StartOffset; Text = [string]$script:PreferenceNumbers[$val] })
  }
  if ($edits.Count -eq 0) { return $text }
  return (Apply-Edits $text $edits)
}

# Minify one file. $FunctionMap comes from New-FunctionMap, so all files agree.
function Invoke-MinifyFile {
  param(
    [string]$Path,
    [string]$OutPath,
    [hashtable]$FunctionMap = @{},
    [hashtable]$ScriptVarMap = @{},
    [hashtable]$GlobalVarMap = @{},
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
    foreach ($gv in $GlobalVarMap.Values) { [void]$taken.Add([string]$gv) }
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
      # a script-scope name keeps the one short name the whole project agreed on
      if ($GlobalVarMap.ContainsKey($name)) {
        $edits.Add(@{ Offset = $v.Extent.StartOffset; Length = $v.Extent.EndOffset - $v.Extent.StartOffset; Text = (Get-VariableSigil $v) + [string]$GlobalVarMap[$name] })
        continue
      }
      if (-not $varMap.ContainsKey($name)) {
        $new = New-ShortName $slot
        while ($taken.Contains($new)) { $slot++; $new = New-ShortName $slot }
        $slot++
        [void]$taken.Add($new)
        $varMap[$name] = $new
      }
      $edits.Add(@{ Offset = $v.Extent.StartOffset; Length = $v.Extent.EndOffset - $v.Extent.StartOffset; Text = (Get-VariableSigil $v) + [string]$varMap[$name] })
    }

    if ($edits.Count -gt 0) { $renamed = Apply-Edits $text $edits }

    # renaming can introduce a clash (two names mapping to one): check before going on
    $check = Get-ParsedScript $renamed
    if ($check.Errors.Count -gt 0) { throw ($Path + ': rename broke the syntax (' + $check.Errors[0].Message + ')') }
  }

  # the C# body and the shortened preference first: both change the text the later passes
  # parse, and both are their own token level rewrite
  $squeezed = Compress-CSharpBlocks $renamed
  $squeezed = Compress-ErrorAction $squeezed
  # statement pass, then the lexical pass on what is left
  $merged = Merge-Statements $squeezed
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

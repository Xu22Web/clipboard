# packages\module\lib\graph.ps1 - the import graph of one entry, in two passes.
#
# Pass one registers: every file is read once, its statements turn into edges, and a file that is
# already registered is not registered again. Pass two orders: dependencies first, the entry last.
# Two passes are what makes a cycle harmless - a file that is already on the stack is simply not
# entered again, and lands after the file that closes the loop, which is where the bundler puts
# it too.
#
# A module declares its edges as statements, not comments:
#
#     . (Use-Module './leaf' $PSCommandPath)
#     Export-Function Get-A, Get-B
#     Export-Function Get-C -From './other'
#     Export-Function -All -From './other'
#     Export-Function Get-D -Default
#
# The comment forms (#@use / #@export) still read, so a file written before the statements is not
# left out. Both are read here and nowhere else.
function Get-ModuleStatementAst($ast) {
  $uses = New-Object System.Collections.Generic.List[object]
  $exports = New-Object System.Collections.Generic.List[object]
  $defined = New-Object System.Collections.Generic.List[string]
  $calls = New-Object System.Collections.Generic.List[string]
  if ($null -eq $ast) { return @{ Uses = @(); Exports = @(); Defined = @(); Calls = @() } }

  # one walk for both questions: the calls that write an edge and the functions the file defines.
  # Asking the tree twice doubled the cost of a long file, and the second answer never changed.
  $nodes = @($ast.FindAll({ param($n)
    if ($n -is [System.Management.Automation.Language.CommandAst]) { return $true }
    if ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
      return (($n.Parent -is [System.Management.Automation.Language.NamedBlockAst]) -and
              ($n.Parent.Parent -is [System.Management.Automation.Language.ScriptBlockAst]) -and
              ($null -eq $n.Parent.Parent.Parent))
    }
    return $false
  }, $true))

  foreach ($cmd in $nodes) {
    if ($cmd -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
      $defined.Add([string]$cmd.Name)
      continue
    }
    $name = ''
    try { $name = [string]$cmd.GetCommandName() } catch { $name = '' }
    $line = [int]$cmd.Extent.StartLineNumber
    if ($name) { $calls.Add($name) }
    if ($name -eq 'Use-Module') {
      # a named import is the readable form - `. (Use-Module 'main/utils/native' -Named Get-ClipCapture)`
      # states what the file actually uses, and the diagnostics pass checks each name against the
      # exports of the target module
      $spec = ''
      $named = New-Object System.Collections.Generic.List[string]
      $i = 1
      while ($i -lt @($cmd.CommandElements).Count) {
        $e = $cmd.CommandElements[$i]
        $i++
        if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
          $value = ''
          if ($i -lt @($cmd.CommandElements).Count) {
            $next = $cmd.CommandElements[$i]
            if ($next -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $value = [string]$next.Value; $i++ }
            elseif ($next -is [System.Management.Automation.Language.ArrayLiteralAst]) {
              foreach ($item in @($next.Elements)) {
                if ($item -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $named.Add([string]$item.Value) }
              }
              $i++
            }
          }
          if (([string]$e.ParameterName).ToLowerInvariant() -eq 'named' -and $value) {
            foreach ($one in @($value -split '[,\s]+')) { if ($one) { $named.Add($one) } }
          }
          continue
        }
        if ($e -is [System.Management.Automation.Language.ArrayLiteralAst]) {
          foreach ($item in @($e.Elements)) {
            if ($item -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $named.Add([string]$item.Value) }
          }
          continue
        }
        if (-not $spec -and $e -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $spec = [string]$e.Value }
      }
      if ($spec) { $uses.Add(@{ Spec = $spec.Trim(); Named = $named.ToArray(); Line = $line }) }
      continue
    }
    if ($name -ne 'Export-Function') { continue }

    $names = New-Object System.Collections.Generic.List[string]
    $default = ''
    $defaultFlag = $false
    $all = $false
    $from = ''
    $i = 1
    while ($i -lt @($cmd.CommandElements).Count) {
      $e = $cmd.CommandElements[$i]
      $i++
      if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
        $p = ([string]$e.ParameterName).ToLowerInvariant()
        if ($p -eq 'all') { $all = $true; continue }
        $value = ''
        if ($i -lt @($cmd.CommandElements).Count) {
          $next = $cmd.CommandElements[$i]
          if ($next -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $value = [string]$next.Value; $i++ }
        }
        if ($p -eq 'from') { $from = $value.Trim() }
        elseif ($p -eq 'default') {
          # both readings: --Default X names the default, --Default alone marks the first name
          if ($value) { $default = $value.Trim() } else { $defaultFlag = $true }
        }
        continue
      }
      if ($e -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        foreach ($item in @($e.Elements)) {
          if ($item -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $names.Add([string]$item.Value) }
        }
        continue
      }
      if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        foreach ($one in @(([string]$e.Value) -split '[,\s]+')) {
          if ($one) { $names.Add($one) }
        }
      }
    }
    if (-not $default -and $defaultFlag -and $names.Count -gt 0) { $default = $names[0] }
    $exports.Add(@{ Names = $names.ToArray(); Default = $default; All = $all; From = $from; Line = $line })
  }

  # the comment forms were read beside the statements above
  return @{ Uses = $uses.ToArray(); Exports = $exports.ToArray(); Defined = $defined.ToArray(); Calls = $calls.ToArray() }
}

# The comment form, kept for files that have not been moved to statements yet. One function so
# both readers answer the same shape: a use is a specifier and a line, an export is a set of names
# and the line of the token that wrote them.
function Get-ModuleCommentDirectives($parsed) {
  $uses = New-Object System.Collections.Generic.List[object]
  $exports = New-Object System.Collections.Generic.List[object]
  if ($null -eq $parsed -or $null -eq $parsed.Tokens) { return @{ Uses = @(); Exports = @() } }
  foreach ($t in @($parsed.Tokens)) {
    if ([string]$t.Kind -ne 'Comment') { continue }
    $text = ([string]$t.Text).Trim()
    if (-not $text.StartsWith('#')) { continue }
    $m = [regex]::Match($text, '^#\s*@(use|export)\b(.*)$')
    if (-not $m.Success) { continue }
    $kind = $m.Groups[1].Value
    $line = [int]$t.Extent.StartLineNumber
    $names = @($m.Groups[2].Value -split '[,;\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($kind -eq 'use') {
      foreach ($one in $names) {
        if (-not @($uses | Where-Object { $_.Spec -eq $one })) { $uses.Add(@{ Spec = $one; Line = $line }) }
      }
    } else {
      $exports.Add(@{ Names = $names; Default = ''; All = $false; From = ''; Line = $line })
    }
  }
  return @{ Uses = $uses.ToArray(); Exports = $exports.ToArray(); Defined = @() }
}

# One file's statements, statements first and the comment form merged in. Uses carry a line;
# an export from a comment carries the line of the token. Defined is the list of functions the
# file defines, and Calls every command name it looks up - the diagnostics pass asks for both, and
# asking the tree twice cost as much as the first walk did.
function Get-ModuleStatements([string]$path) {
  $empty = @{ Uses = @(); Exports = @(); Defined = @(); Calls = @() }
  if (-not $path -or -not [IO.File]::Exists($path)) { return $empty }
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  $found = Get-ModuleStatementAst $ast

  # the comment form is rare: one string search skips the token walk for every file that does not
  # carry one, which is all of the generated and most of the hand-written code
  $comments = @{ Uses = @(); Exports = @() }
  $raw = ''
  try { $raw = [IO.File]::ReadAllText($path) } catch { $raw = '' }
  if ($raw.Contains('#@')) { $comments = Get-ModuleCommentDirectives @{ Tokens = $tokens } }

  $uses = New-Object System.Collections.Generic.List[object]
  $seenUse = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  foreach ($one in @($found.Uses)) {
    $key = [string]$one.Spec
    if ($seenUse.Add($key)) { $uses.Add($one); continue }
    # two lines importing one module: one edge, the names as the union of both
    for ($i = 0; $i -lt $uses.Count; $i++) {
      if ([string]$uses[$i].Spec -ne $key) { continue }
      $merged = New-Object System.Collections.Generic.List[string]
      foreach ($n in @($uses[$i].Named) + @($one.Named)) {
        if ($n -and -not $merged.Contains([string]$n)) { $merged.Add([string]$n) }
      }
      $uses[$i] = @{ Spec = $key; Named = $merged.ToArray(); Line = [int]$uses[$i].Line }
      break
    }
  }
  foreach ($one in @($comments.Uses)) {
    if ($seenUse.Add([string]$one.Spec)) { $uses.Add(@{ Spec = [string]$one.Spec; Named = @(); Line = [int]$one.Line }) }
  }

  $exports = New-Object System.Collections.Generic.List[object]
  foreach ($one in @($found.Exports)) { $exports.Add($one) }
  foreach ($one in @($comments.Exports)) { $exports.Add($one) }
  return @{ Uses = $uses.ToArray(); Exports = $exports.ToArray(); Defined = @($found.Defined); Calls = @($found.Calls) }
}

# The older shape: names only, no lines. Kept because the bundler comparison and older tests read it.
function Get-ModuleDirectives([string]$path) {
  $statements = Get-ModuleStatements $path
  $uses = New-Object System.Collections.Generic.List[string]
  $exports = New-Object System.Collections.Generic.List[string]
  foreach ($one in @($statements.Uses)) { if (-not $uses.Contains([string]$one.Spec)) { $uses.Add([string]$one.Spec) } }
  foreach ($one in @($statements.Exports)) {
    foreach ($name in @($one.Names)) { if (-not $exports.Contains([string]$name)) { $exports.Add([string]$name) } }
    if ($one.Default -and -not $exports.Contains([string]$one.Default)) { $exports.Add([string]$one.Default) }
  }
  return @{ Uses = $uses.ToArray(); Exports = $exports.ToArray() }
}

# resolve.alias, applied to a specifier: the longest name that prefixes it is replaced by the
# folder it stands for.
function Expand-ModuleAlias([string]$spec, $alias) {
  if (-not $spec -or $null -eq $alias -or -not ($alias -is [System.Collections.IDictionary])) { return $spec }
  if ($spec.StartsWith('./') -or $spec.StartsWith('../') -or $spec.StartsWith('.\') -or $spec.StartsWith('..\')) { return $spec }
  $best = ''
  foreach ($k in @($alias.Keys)) {
    $name = [string]$k
    if (-not $name) { continue }
    if (-not $spec.StartsWith($name, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if ($name.Length -gt $best.Length) { $best = $name }
  }
  if (-not $best) { return $spec }
  $rest = $spec.Substring($best.Length).TrimStart([char]'/', [char]92)
  $dir = ([string]$alias[$best]).TrimEnd([char]'/', [char]92)
  if (-not $rest) { return $dir }
  return ($dir + '/' + $rest)
}

# The id a #@use names: the path under src\ without the extension, forward slashes.
function Get-ModuleId([string]$root, [string]$path) {
  $full = [IO.Path]::GetFullPath($path)
  $srcRoot = [IO.Path]::GetFullPath((Join-Path $root 'src')).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
  $rel = $full
  if ($full.StartsWith($srcRoot, [StringComparison]::OrdinalIgnoreCase)) { $rel = $full.Substring($srcRoot.Length) }
  $rel = $rel -replace '\\', '/'
  if ($rel.ToLowerInvariant().EndsWith('.ps1')) { $rel = $rel.Substring(0, $rel.Length - 4) }
  return $rel
}

# Walk one entry in two passes. Answers:
#   Order    the files to load, dependencies first
#   Nodes    one row per module: Path, Id, Line, Uses, Exports, Statements
#   Missing  specifiers that name nothing, each with the file and the line that wrote it
#   Cycles   the loop closers, as '<file>:<line> closes a cycle through <id>'
function Get-ModuleGraph([string]$entry, [string]$root, $alias = $null, [string[]]$Conditions = @()) {
  $nodes = New-Object System.Collections.Generic.List[object]
  $missing = New-Object System.Collections.Generic.List[string]
  $cycles = New-Object System.Collections.Generic.List[string]
  $byPath = @{}

  if (-not $entry -or -not (Test-Path -LiteralPath $entry)) {
    $missing.Add('entry not found: ' + $entry)
    return @{ Order = @(); Nodes = @(); Missing = $missing.ToArray(); Cycles = @(); Edges = @() }
  }
  $entryPath = [IO.Path]::GetFullPath($entry)
  $edges = New-Object System.Collections.Generic.List[object]

  # ---------------------------------------------------------------- pass one: register
  $register = {
    param($file)
    $key = ([string]$file).ToLowerInvariant()
    if ($byPath.ContainsKey($key)) { return $byPath[$key] }
    # a data module has no statements to read and nothing to dot-source: the edge is recorded so a
    # report can name it, and the walk stops there
    if ((Get-ModulePathKind ([string]$file)) -ne 'script') { $byPath[$key] = $null; return $null }
    $statements = Get-ModuleStatements $file
    $node = @{
      Path       = [string]$file
      Id         = (Get-ModuleId $root $file)
      Uses       = @($statements.Uses)
      Exports    = @()
      Statements = $statements
      Line       = 0
    }
    $byPath[$key] = $node
    $nodes.Add($node)
    foreach ($one in @($statements.Uses)) {
      $spec = Expand-ModuleAlias ([string]$one.Spec) $alias
      $ref = Resolve-ModuleSpecifier $spec $file $root $Conditions
      $line = [int]$one.Line
      if ($ref.Problem) {
        $missing.Add(('{0}:{1} {2} ({3})' -f (Split-Path -Leaf $file), $line, $one.Spec, $ref.Problem))
        continue
      }
      $edges.Add(@{ From = [string]$file; To = $ref.Path; Line = $line; Spec = [string]$one.Spec })
      [void](& $register $ref.Path)
    }
    return $node
  }

  [void](& $register $entryPath)

  # ---------------------------------------------------------------- pass two: order
  $order = New-Object System.Collections.Generic.List[string]
  $state = @{}
  $out = @{}
  foreach ($e in $edges) { $out[[string]$e.From] = @($out[[string]$e.From]) + @($e) }

  $visit = {
    param($file)
    if ((Get-ModulePathKind ([string]$file)) -ne 'script') { return }
    $key = ([string]$file).ToLowerInvariant()
    if ($state.ContainsKey($key)) {
      # a visit that finds an unfinished file is looking at the loop closing; the row names the
      # import line that closes it, not the file, so it points at something a reader can fix
      return
    }
    $state[$key] = 0
    foreach ($e in @($out[$file])) {
      if ($null -eq $e) { continue }
      $toKey = ([string]$e.To).ToLowerInvariant()
      if ($state.ContainsKey($toKey) -and $state[$toKey] -eq 0) {
        $cycles.Add(('{0}:{1} closes a cycle through {2}' -f (Split-Path -Leaf ([string]$e.From)), [int]$e.Line, (Get-ModuleId $root ([string]$e.To))))
      }
      & $visit ([string]$e.To)
    }
    $state[$key] = 1
    $order.Add([string]$file)
  }

  & $visit $entryPath
  return @{ Order = $order.ToArray(); Nodes = $nodes.ToArray(); Missing = $missing.ToArray(); Cycles = $cycles.ToArray(); Edges = $edges.ToArray() }
}

# One entry, what it would report before it runs: the graph's rows (a specifier that names
# nothing, a line that closes a cycle) and the export set's rows (a forwarded name the source
# does not export, an export naming a function the file does not define). See Get-ModuleDiagnostics
# in order.ps1, which folds these together with the export set.


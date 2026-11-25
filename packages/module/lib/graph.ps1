# packages\module\lib\graph.ps1 - the import graph of one entry.
#
# The same two comments the bundler reads drive this walk: #@use names the modules a file needs,
# #@export names what the rest of the program may call. The order is dependency first, the entry
# last, so dot-sourcing the result in order reproduces what the file asks for.
#
# A cycle is not an error - the later module simply lands after the one that closes it, exactly
# as the bundler places it - but the entry is reported so a real mistake stays visible.
function Get-ModuleDirectives([string]$path) {
  $uses = New-Object System.Collections.Generic.List[string]
  $exports = New-Object System.Collections.Generic.List[string]
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return @{ Uses = @(); Exports = @() } }
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  foreach ($t in @($tokens)) {
    if ([string]$t.Kind -ne 'Comment') { continue }
    $text = ([string]$t.Text).Trim()
    if (-not $text.StartsWith('#')) { continue }
    $m = [regex]::Match($text, '^#\s*@(use|export)\b(.*)$')
    if (-not $m.Success) { continue }
    $kind = $m.Groups[1].Value
    $names = @($m.Groups[2].Value -split '[,;\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($one in $names) {
      if ($kind -eq 'use') { if (-not $uses.Contains($one)) { $uses.Add($one) } }
      else { if (-not $exports.Contains($one)) { $exports.Add($one) } }
    }
  }
  return @{ Uses = $uses.ToArray(); Exports = $exports.ToArray() }
}

# resolve.alias, applied to a specifier: the longest name that prefixes it is replaced by the
# folder it stands for. Only id-shaped specifiers are rewritten; './x' and a package name are
# already unambiguous.
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

# Walk one entry. Answers:
#   Order    the files to load, dependencies first
#   Nodes    one row per module: Path, Id, Uses, Exports, Kind
#   Missing  specifiers that name nothing (they are skipped, so a source run still starts)
#   Cycles   specifiers that close a loop
function Get-ModuleGraph([string]$entry, [string]$root, $alias = $null) {
  $order = New-Object System.Collections.Generic.List[string]
  $nodes = New-Object System.Collections.Generic.List[object]
  $missing = New-Object System.Collections.Generic.List[string]
  $cycles = New-Object System.Collections.Generic.List[string]

  if (-not $entry -or -not (Test-Path -LiteralPath $entry)) {
    $missing.Add('entry not found: ' + $entry)
    return @{ Order = @(); Nodes = @(); Missing = $missing.ToArray(); Cycles = @() }
  }
  $entryPath = [IO.Path]::GetFullPath($entry)
  $state = @{}

  $visit = {
    param($file)
    $key = ([string]$file).ToLowerInvariant()
    if ($state.ContainsKey($key)) {
      if ($state[$key] -eq 0) { $cycles.Add($file) }
      return
    }
    $state[$key] = 0
    $decl = Get-ModuleDirectives $file
    foreach ($one in @($decl.Uses)) {
      $spec = Expand-ModuleAlias ([string]$one) $alias
      $ref = Resolve-ModuleSpecifier $spec $file $root
      if ($ref.Problem) { $missing.Add(('{0}: {1} ({2})' -f (Split-Path -Leaf $file), $one, $ref.Problem)); continue }
      & $visit $ref.Path
    }
    $state[$key] = 1
    $order.Add([string]$file)
    $nodes.Add(@{
        Path    = [string]$file
        Id      = (Get-ModuleId $root $file)
        Uses    = @($decl.Uses)
        Exports = @($decl.Exports)
        Kind    = 'file'
      })
  }

  & $visit $entryPath
  return @{ Order = $order.ToArray(); Nodes = $nodes.ToArray(); Missing = $missing.ToArray(); Cycles = $cycles.ToArray() }
}

# The id a #@use names: the path under src\ without the extension, forward slashes. A file
# outside src\ keeps the path it has on disk, so a module added later still reads sensibly.
function Get-ModuleId([string]$root, [string]$path) {
  $full = [IO.Path]::GetFullPath($path)
  $srcRoot = [IO.Path]::GetFullPath((Join-Path $root 'src')).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
  $rel = $full
  if ($full.StartsWith($srcRoot, [StringComparison]::OrdinalIgnoreCase)) { $rel = $full.Substring($srcRoot.Length) }
  $rel = $rel -replace '\\', '/'
  if ($rel.ToLowerInvariant().EndsWith('.ps1')) { $rel = $rel.Substring(0, $rel.Length - 4) }
  return $rel
}

# The whole set of problems one entry has, before anything runs: missing modules, an export no
# package declares, and a #@export naming a function the file does not define. The bundler does
# the same check for what it writes; this one is for the source tree.
function Test-ModuleSpecifiers([string]$entry, [string]$root, $alias = $null) {
  $problems = New-Object System.Collections.Generic.List[string]
  $graph = Get-ModuleGraph $entry $root $alias
  foreach ($one in @($graph.Missing)) { $problems.Add($one) }

  foreach ($node in @($graph.Nodes)) {
    $decl = @($node.Exports)
    if ($decl.Count -eq 0) { continue }
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile([string]$node.Path, [ref]$tokens, [ref]$errors)
    $defined = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) { [void]$defined.Add([string]$f.Name) }
    foreach ($name in $decl) {
      if (-not $defined.Contains($name)) { $problems.Add(([string]$node.Id + ': exports ' + $name + ', which it does not define')) }
    }
  }
  return $problems.ToArray()
}

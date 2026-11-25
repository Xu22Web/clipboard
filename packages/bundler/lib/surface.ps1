#Requires -Version 5.1
<#
  tools\bundler\lib\surface.ps1 - what a module says it needs, and what it says it offers.

  A bundle can be checked before it is built if the modules declare their edges the way a module
  system does: an import list, an export list. The declarations are comment directives read from
  the token stream the parser produced, not from the raw text:

      #@use renderer/src/core/layout
      #@export New-UiBox, Get-UiStack, Get-UiColumns

  A comment is deliberate. The declarations describe the *build*, not the program: the shipped
  copy runs the same file with the same dot-sourcing it has today, so a directive must cost it
  nothing and must not be something the runtime has to understand. Reading them out of the
  token stream keeps the rule the rest of the bundler follows - the parser decides what is a
  declaration and what merely looks like one inside a string or a here-string.

  What the checks buy, all of them static:

    * a call to a function another module defines, which that module does not export
    * a call to a function defined in a module this entry does not carry - the mistake that
      today only shows up at run time as "module group too small"
    * an export that names nothing the module defines
    * the same name exported by two modules, which makes a call ambiguous
    * a #@use naming a module the entry does not list, or one that does not exist
    * a module the entry carries but nothing reaches (a warning: it is what shaking removes)
#>

# The id a #@use names: the path under src\ without the extension, forward slashes.
. (Use-Module './ast.ps1' $PSCommandPath -Named Get-BundleCommandNames)

function Get-BundleModuleId([string]$root, [string]$path) {
  $full = [IO.Path]::GetFullPath($path)
  $srcRoot = [IO.Path]::GetFullPath((Join-Path $root 'src')).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
  $rel = $full
  if ($full.StartsWith($srcRoot, [StringComparison]::OrdinalIgnoreCase)) { $rel = $full.Substring($srcRoot.Length) }
  $rel = $rel -replace '\\', '/'
  if ($rel.ToLowerInvariant().EndsWith('.ps1')) { $rel = $rel.Substring(0, $rel.Length - 4) }
  return $rel
}

# A #@use may name a file beside the module: './x' means the module's own folder, the way an
# import inside a folder reads. A package specifier ('pkg#Export') has no file under src\ to
# point at, so it is left as written and reported as a module the entry does not carry - which
# is the honest answer for a bundle that only knows the source tree.
function Resolve-BundleUseId([string]$moduleId, [string]$use) {
  if (-not $use) { return $use }
  if (-not ($use.StartsWith('./') -or $use.StartsWith('.\'))) { return $use }
  $dir = ''
  $slash = ([string]$moduleId).LastIndexOf('/')
  if ($slash -ge 0) { $dir = ([string]$moduleId).Substring(0, $slash) }
  $rest = $use.Substring(2).TrimStart([char]'/', [char]92)
  if (-not $rest) { return $dir }
  if (-not $dir) { return $rest }
  return ($dir + '/' + $rest)
}

# resolve.alias for a #@use id: the longest matching prefix wins and is replaced by the folder
# it names, the way a vite alias turns '@renderer/x' into 'src/renderer/src/x'. An id that
# matches nothing comes back unchanged, so tables without an alias keep their behaviour.
function Expand-BundleAlias([string]$id, $alias) {
  if (-not $id -or $null -eq $alias -or -not ($alias -is [System.Collections.IDictionary])) { return $id }
  $best = ''
  foreach ($k in @($alias.Keys)) {
    $name = [string]$k
    if (-not $name) { continue }
    if (-not $id.StartsWith($name, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if ($name.Length -gt $best.Length) { $best = $name }
  }
  if (-not $best) { return $id }
  $rest = $id.Substring($best.Length).TrimStart([char]'/')
  $dir = ([string]$alias[$best]).TrimEnd([char]'/', [char]92)
  if (-not $rest) { return $dir }
  return ($dir + '/' + $rest)
}

# The directives of one module: the edges it writes as statements, and the names it declares.
#
#     . (Use-Module 'renderer/src/core/draw')
#     Export-Function New-UiBox, Get-UiBox
#
# A file written before the statements still carries the comment form (#@use / #@export), so both
# are read and merged. An Export-Function that forwards (-From) or takes another module's whole
# set (-All) declares nothing of its own: those names belong to the module it names.
function Get-BundleDirectives($parsed) {
  $uses = New-Object System.Collections.Generic.List[string]
  $exports = New-Object System.Collections.Generic.List[string]
  if ($null -eq $parsed) { return @{ Uses = @(); Exports = @() } }

  if ($null -ne $parsed.Ast) {
    foreach ($cmd in @($parsed.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
      $name = ''
      try { $name = [string]$cmd.GetCommandName() } catch { $name = '' }
      if ($name -eq 'Use-Module') {
        $spec = ''
        if (@($cmd.CommandElements).Count -gt 1) {
          $first = $cmd.CommandElements[1]
          if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $spec = [string]$first.Value }
        }
        # a member id, the way the include table already spells them: forward slashes, no suffix
        $spec = $spec.Trim() -replace '\\', '/'
        if ($spec.ToLowerInvariant().EndsWith('.ps1')) { $spec = $spec.Substring(0, $spec.Length - 4) }
        if ($spec -and -not $uses.Contains($spec)) { $uses.Add($spec) }
        continue
      }
      if ($name -ne 'Export-Function') { continue }
      $forward = $false
      $names = New-Object System.Collections.Generic.List[string]
      $i = 1
      while ($i -lt @($cmd.CommandElements).Count) {
        $e = $cmd.CommandElements[$i]
        $i++
        if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
          $p = ([string]$e.ParameterName).ToLowerInvariant()
          if ($p -eq 'from' -or $p -eq 'all') { $forward = $true }
          continue
        }
        if ($e -is [System.Management.Automation.Language.ArrayLiteralAst]) {
          foreach ($item in @($e.Elements)) {
            if ($item -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
              foreach ($one in @(([string]$item.Value) -split '[,\s]+')) { if ($one) { $names.Add($one) } }
            }
          }
          continue
        }
        if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
          foreach ($one in @(([string]$e.Value) -split '[,\s]+')) { if ($one) { $names.Add($one) } }
        }
      }
      if ($forward) { continue }
      foreach ($one in $names) { if (-not $exports.Contains($one)) { $exports.Add($one) } }
    }
  }

  # the comment form, for a file written before the statements
  if ($null -ne $parsed.Tokens) {
    foreach ($t in @($parsed.Tokens)) {
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
  }
  return @{ Uses = $uses.ToArray(); Exports = $exports.ToArray() }
}

# The whole check for one entry: the declared graph, what is wrong with it, and what it leaves
# unused. Modules without directives are reported separately: they can be bundled (the inferred
# walk is used for them) but they cannot be checked.
function Get-BundleSurfaceReport($modules, $externals = $null, $alias = $null) {
  $problems = New-Object System.Collections.Generic.List[string]
  $warnings = New-Object System.Collections.Generic.List[string]

  # a module an entry names under External= is not in the bundle: another file provides it at
  # run time (the base layer the package still ships as lib\*.ps1). A #@use naming one of those
  # is the edge between two files, not a module the list forgot.
  $external = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  foreach ($one in @($externals)) { if ($one) { [void]$external.Add([string]$one) } }

  $byId = @{}
  $defs = @{}
  foreach ($m in @($modules)) {
    $byId[[string]$m.Id] = $m
    foreach ($name in @($m.Functions)) {
      $key = $name.ToLowerInvariant()
      if ($defs.ContainsKey($key)) { $defs[$key] = @($defs[$key]) + @([string]$m.Id) } else { $defs[$key] = @([string]$m.Id) }
    }
  }

  $declared = 0
  $exported = @{}
  foreach ($m in @($modules)) {
    $uses = @($m.Uses)
    $exports = @($m.Exports)
    if ($uses.Count -gt 0 -or $exports.Count -gt 0) { $declared++ }

    foreach ($one in $exports) {
      if (@($m.Functions) -notcontains $one) {
        $problems.Add(([string]$m.Id + ': exports ' + $one + ', which it does not define'))
      }
      $key = $one.ToLowerInvariant()
      if ($exported.ContainsKey($key)) {
        $problems.Add(($one + ' is exported by both ' + $exported[$key] + ' and ' + [string]$m.Id))
      } else {
        $exported[$key] = [string]$m.Id
      }
    }

    foreach ($one in $uses) {
      $use = ([string](Expand-BundleAlias (Resolve-BundleUseId ([string]$m.Id) ([string]$one)) $alias)).ToLowerInvariant()
      if ($external.Contains($use)) { continue }
      if (-not $byId.ContainsKey($use)) {
        $problems.Add(([string]$m.Id + ': uses ' + $one + ', which the entry does not carry'))
      }
    }
  }

  # a call that leaves its module has to land on an export
  $edges = 0
  foreach ($m in @($modules)) {
    $mine = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($m.Functions)) { [void]$mine.Add($name) }
    foreach ($name in @(Get-BundleCommandNames $m.Ast)) {
      if ($mine.Contains($name)) { continue }
      $key = $name.ToLowerInvariant()
      if (-not $defs.ContainsKey($key)) { continue }        # a cmdlet, or something outside the project
      $owners = @($defs[$key])
      foreach ($owner in $owners) {
        if ($owner -eq [string]$m.Id) { continue }
        $edges++
        $target = $byId[$owner]
        # a module that declares no export list cannot be checked yet: the declarations are
        # added one module at a time, so only a declared surface is enforced
        if (@($target.Exports).Count -eq 0) { continue }
        if (@($target.Exports) -notcontains $name) {
          $problems.Add(([string]$m.Id + ': calls ' + $name + ', which ' + $owner + ' does not export'))
        }
      }
    }
  }

  # what nothing reaches: the modules a shake would remove
  $unused = New-Object System.Collections.Generic.List[string]
  $used = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  foreach ($m in @($modules)) {
    foreach ($one in @($m.Uses)) { [void]$used.Add($one) }
  }
  foreach ($m in @($modules)) {
    if ($used.Contains([string]$m.Id)) { continue }
    if (@($m.Uses).Count -gt 0 -and @($m.Exports).Count -eq 0) { continue }
    if (-not $used.Contains([string]$m.Id)) { $unused.Add([string]$m.Id) }
  }

  return @{
    Declared = $declared
    Total    = @($modules).Count
    Edges    = $edges
    Problems = $problems.ToArray()
    Warnings = $warnings.ToArray()
    Unused   = $unused.ToArray()
    Exported = $exported.Count
  }
}

Export-Function Expand-BundleAlias, Get-BundleDirectives, Get-BundleModuleId, Get-BundleSurfaceReport, Resolve-BundleUseId


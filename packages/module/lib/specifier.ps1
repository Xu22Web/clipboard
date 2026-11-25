# packages\module\lib\specifier.ps1 - one import specifier turned into a file.
#
# The forms are node's, in the order a resolver tries them:
#
#   ./name  ../name     relative to the module that writes the line, like import './x.js'
#   <package>           the Main a package.ini declares, like import 'vite'
#   <package>#Export    one name that package lists in Exports, like import { x } from 'vite'
#   <package>/sub/path  a file inside that package, like import 'vite/dist/x.js'
#   name/of/module      a module id under src\ - the form #@use has always used
#
# A .ps1 suffix is optional everywhere; it is added when the name has none.
#
# The root may be empty: a relative specifier is answered from the file that writes it and needs
# no repository, which is what lets a script run from a scratch folder import the file beside it.
function Get-ModulePackagesRoot([string]$root) {
  if (-not $root) { return '' }
  return (Join-Path $root 'packages')
}

# The package.ini of a package folder, read without depending on another package: four keys are
# all a specifier needs, and a package that is not there is a missing import, not a crash.
function Read-ModulePackage([string]$dir) {
  $file = Join-Path $dir 'package.ini'
  if (-not [IO.File]::Exists($file)) { return $null }
  $map = @{}
  $section = ''
  foreach ($line in [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)) {
    $text = $line.Trim()
    if (-not $text -or $text.StartsWith('#') -or $text.StartsWith(';')) { continue }
    if ($text.StartsWith('[') -and $text.EndsWith(']')) { $section = $text.Substring(1, $text.Length - 2).Trim(); continue }
    $eq = $text.IndexOf('=')
    if ($eq -lt 1) { continue }
    $key = $text.Substring(0, $eq).Trim()
    $value = $text.Substring($eq + 1).Trim()
    $map[$key] = $value
    if ($section) { $map[$section + '.' + $key] = $value }
  }
  $read = {
    param($name)
    if ($map.ContainsKey('package.' + $name)) { return ([string]$map['package.' + $name]).Trim() }
    if ($map.ContainsKey($name)) { return ([string]$map[$name]).Trim() }
    return ''
  }
  return @{
    Dir      = $dir
    Name     = (& $read 'Name')
    Main     = (& $read 'Main')
    Exports  = (& $read 'Exports')
    Map      = $map
  }
}

# A condition is a second layer of the same three keys: [package.dev] Main=... in a package.ini
# says what that package's entry is for the 'dev' condition, and the plain Main answers when the
# condition does not name one. It is the smallest form of a conditional export.
function Get-ModulePackageValue($pkg, [string]$key, [string[]]$Conditions = @()) {
  if ($null -eq $pkg) { return '' }
  foreach ($c in @($Conditions)) {
    $name = ([string]$c).Trim()
    if (-not $name) { continue }
    $slot = 'package.' + $name + '.' + $key
    if ($pkg.Map.ContainsKey($slot) -and ([string]$pkg.Map[$slot]).Trim()) { return ([string]$pkg.Map[$slot]).Trim() }
  }
  return [string]$pkg.$key
}

# Add the suffix a specifier left out. Only a module id is spelled without one: an id names a
# module under src\, the way #@use always has, while a path keeps the suffix it was written with.
function Add-ModuleSuffix([string]$path) {
  if (-not $path) { return $path }
  if ($path.ToLowerInvariant().EndsWith('.ps1')) { return $path }
  return ($path + '.ps1')
}

# What a path names: 'script', 'ini', or '' for something this layer cannot load. The suffix
# decides - the resolver never adds one and never tries a list of them.
function Get-ModulePathKind([string]$path) {
  switch ([IO.Path]::GetExtension($path).ToLowerInvariant()) {
    '.ps1' { return 'script' }
    '.ini' { return 'ini' }
    default { return '' }
  }
}

# A path specifier, answered the way an ESM resolver answers it: the file is the one the line
# names, so the suffix is part of the name. A missing suffix is a mistake to report, not a hole to
# fill - the same name may be a script, an ini file and a json file, and picking one for the caller
# is how a build reads the wrong thing.
#
# Existence is asked of [IO.File] rather than of Test-Path: a resolver runs once per import line
# and twice more per candidate, and the cmdlet's own plumbing costs more than the call it makes.
function Resolve-ModulePath([string]$base, [string]$target) {
  if (-not $base) { $base = (Get-Location).Path }
  if ([IO.File]::Exists($base)) { $base = Split-Path -Parent $base }
  $path = [IO.Path]::GetFullPath((Join-Path $base ($target -replace '/', '\')))
  $kind = Get-ModulePathKind $path
  if (-not $kind) {
    return @{ Path = $path; Kind = ''; Problem = 'no suffix: write ' + $target + '.ps1 or ' + $target + '.ini' }
  }
  if (-not [IO.File]::Exists($path)) {
    return @{ Path = $path; Kind = $kind; Problem = 'no such file: ' + $target }
  }
  return @{ Path = $path; Kind = $kind; Problem = '' }
}

# One specifier to one answer:
#   @{ Spec; Kind; Path; Export; Package; Id; Problem }
# Kind is 'local', 'package', 'package-file' or 'id'; PathKind says what the file is - 'script',
# 'ini' or 'json'. Problem is '' when the answer is usable.
function Resolve-ModuleSpecifier([string]$spec, [string]$from, [string]$root, [string[]]$Conditions = @()) {
  $answer = @{ Spec = $spec; Kind = 'id'; Path = ''; PathKind = 'script'; Export = ''; Package = ''; Id = ''; Problem = '' }
  if (-not $spec) { $answer.Problem = 'empty specifier'; return $answer }

  $target = $spec.Trim()
  $export = ''
  $hash = $target.IndexOf('#')
  if ($hash -ge 0) {
    $export = $target.Substring($hash + 1).Trim()
    $target = $target.Substring(0, $hash).Trim()
    if (-not $target) { $answer.Problem = 'a #export needs a package in front of it'; return $answer }
  }
  $answer.Export = $export

  # ---------------------------------------------------------------- relative
  if ($target.StartsWith('./') -or $target.StartsWith('../') -or $target.StartsWith('.\') -or $target.StartsWith('..\')) {
    $answer.Kind = 'local'
    $base = $from
    if (-not $base) { $base = $root }
    $hit = Resolve-ModulePath $base $target
    $answer.Path = $hit.Path
    $answer.PathKind = $hit.Kind
    $answer.Problem = $hit.Problem
    return $answer
  }

  # the package table is only needed from here on: a relative import never reads it, and this
  # function runs once per import line of every module
  $packagesRoot = Get-ModulePackagesRoot $root

  # ---------------------------------------------------------------- package, or a file inside one
  $parts = @($target -split '[\\/]' | Where-Object { $_ })
  if ($parts.Count -gt 0 -and $packagesRoot) {
    $pkgDir = Join-Path $packagesRoot $parts[0]
    if ([IO.Directory]::Exists($pkgDir)) {
      $pkg = Read-ModulePackage $pkgDir
      $answer.Package = $parts[0]
      if ($parts.Count -eq 1) {
        $answer.Kind = 'package'
        $main = Get-ModulePackageValue $pkg 'Main' $Conditions
        if ($null -eq $pkg -or -not $main) { $answer.Problem = 'package ' + $parts[0] + ' declares no Main'; return $answer }
        $answer.Path = [IO.Path]::GetFullPath((Join-Path $pkgDir $main))
        $answer.Id = $parts[0]
      } else {
        $answer.Kind = 'package-file'
        $rel = ($parts[1..($parts.Count - 1)] -join [IO.Path]::DirectorySeparatorChar)
        $hit = Resolve-ModulePath $pkgDir $rel
        $answer.Path = $hit.Path
        $answer.PathKind = $hit.Kind
        $answer.Id = ($parts -join '/')
      }
      if ($null -eq $pkg) { $answer.Problem = 'package ' + $parts[0] + ' has no package.ini'; return $answer }
      if ($answer.Kind -eq 'package-file' -and $hit.Problem) { $answer.Problem = $parts[0] + ': ' + $hit.Problem; return $answer }
      if ($answer.Kind -eq 'package') { $answer.PathKind = (Get-ModulePathKind $answer.Path) }
      if (-not [IO.File]::Exists($answer.Path)) { $answer.Problem = 'no such file in ' + $parts[0] + ': ' + $answer.Id; return $answer }
      if ($export) {
        $declared = Get-ModulePackageValue $pkg 'Exports' $Conditions
        $names = @($declared -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($names -notcontains $export) {
          $answer.Problem = $parts[0] + ' does not export ' + $export + '   (exports: ' + $(if ($names.Count) { $names -join ', ' } else { 'none' }) + ')'
        }
      }
      return $answer
    }
  }

  # ---------------------------------------------------------------- a module id under src
  if (-not $root) {
    $answer.Problem = 'no module root for ' + $target + ' (a relative ./ name needs none)'
    return $answer
  }
  $srcRoot = Join-Path $root 'src'
  $answer.Kind = 'id'
  $answer.Id = ($target -replace '\\', '/')
  $answer.Path = [IO.Path]::GetFullPath((Add-ModuleSuffix (Join-Path $srcRoot ($target -replace '/', '\'))))
  $answer.PathKind = (Get-ModulePathKind $answer.Path)
  if ($export) { $answer.Problem = 'only a package can be asked for one export' }
  elseif (-not [IO.File]::Exists($answer.Path)) { $answer.Problem = 'no module with that id under src: ' + $target }
  return $answer
}

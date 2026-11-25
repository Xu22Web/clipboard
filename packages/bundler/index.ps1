# packages\bundler\index.ps1 - the bundler's public surface.
#
# A caller dot-sources this file and calls what package.ini Exports. Nothing else of the package
# is visible: the engine, the plugins and the lib\ modules stay behind it, so the only thing a
# caller can depend on is the shape of Invoke-BundleTarget.
#
# The engine runs in a process of its own, the way a bundler runs its compiler: a target that
# crashes takes its own process with it and nothing else, and two targets built side by side
# cannot corrupt each other's parser state.
$script:BundlerHome = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:BundlerHome) { throw 'bundler: cannot locate the package folder' }
$script:BundlerScript = Join-Path $script:BundlerHome 'bundler.ps1'
if (-not (Test-Path -LiteralPath $script:BundlerScript)) { throw ('bundler: missing ' + $script:BundlerScript) }

function Get-BundlerRoot {
  return $script:BundlerHome
}

# Build one target, or every target, from a resolved input.
#
#   Spec    { Root, OutDir, Workers, Targets: [ { Name, Kind, Plugins, Input, Output,
#                                                External, Target, Minify, Rename, Treeshake } ] }
#   Entry   one target of Spec. -All builds them all.
#   Out     the file itself, when the caller stages it somewhere the target does not name.
#   From    the root file of another copy of the same C# source.
#
# Returns @{ Ok = $true|$false; Log = @(the lines the engine printed) }. The caller decides what
# a failed target means; this function does not throw for one.
function Invoke-BundleTarget {
  param(
    $Spec,
    [string]$Entry = '',
    [string]$Out = '',
    [string]$From = '',
    [switch]$All,
    [switch]$Quiet
  )
  $file = Join-Path $env:TEMP ('bundle-spec-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
  try {
    $json = $Spec | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding $false))
    $moduleBin = Join-Path (Split-Path -Parent $script:BundlerHome) 'module\bin\module.ps1'
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $moduleBin, $script:BundlerScript, '-TargetFile', $file)
    if ($All) { $argv += '-All' }
    elseif ($Entry) { $argv += @('-Entry', $Entry) }
    if ($Out) { $argv += @('-Out', $Out) }
    if ($From) { $argv += @('-From', $From) }
    if ($Quiet) { $argv += '-Quiet' }
    $log = @(& powershell.exe @argv 2>&1)
    $ok = ($LASTEXITCODE -eq 0)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($one in $log) { $lines.Add([string]$one) }
    return @{ Ok = $ok; Log = $lines.ToArray() }
  } finally {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
  }
}

Export-Function Get-BundlerRoot, Invoke-BundleTarget

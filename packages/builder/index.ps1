# packages\builder\index.ps1 - the builder's public surface.
#
# A caller dot-sources this file and calls what package.ini Exports. The staging, the asset table
# and the check run stay behind it: what a caller can depend on is the shape of Invoke-Package.
#
# The release runs in a process of its own for the same reason the bundler does - a packaging run
# that fails takes its own process with it, and the caller keeps the exit code and the log.
$script:BuilderHome = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:BuilderHome) { throw 'builder: cannot locate the package folder' }
$script:BuilderScript = Join-Path $script:BuilderHome 'package.ps1'
if (-not (Test-Path -LiteralPath $script:BuilderScript)) { throw ('builder: missing ' + $script:BuilderScript) }

function Get-BuilderRoot {
  return $script:BuilderHome
}

# One archive beside the package folder. This is a release step, not a packing step: `cli build`
# writes the folder and stops, and `cli release` decides whether the folder is worth an archive.
function Invoke-BuilderArchive {
  param(
    [Parameter(Mandatory = $true)][string]$PackageDir,
    [string]$Destination = ''
  )
  if (-not (Test-Path -LiteralPath $PackageDir)) { throw ('no package folder: ' + $PackageDir) }
  $name = Split-Path -Leaf $PackageDir
  if (-not $Destination) {
    $Destination = Join-Path (Split-Path -Parent $PackageDir) ($name + '.zip')
  }
  Compress-Archive -LiteralPath $PackageDir -DestinationPath $Destination -CompressionLevel Optimal -Force
  return $Destination
}

# Write the release.
#
#   Request   @{
#               Root    the repository root
#               App     the program name
#               Version <major>.<minor>.<patch>
#               Outputs @( @{ Rel = 'renderer\picker.27afbde2.ps1'; Path = '<abs>'; Replaces = @('renderer\...') } )
#             }
#
# Returns @{ Ok = $true|$false; Log = @(the lines the release printed); Package = <folder> }.
function Invoke-Package {
  param(
    $Request,
    [string]$Config = ''
  )
  $file = Join-Path $env:TEMP ('builder-request-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
  try {
    [IO.File]::WriteAllText($file, ($Request | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding $false))
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:BuilderScript, '-RequestFile', $file)
    if ($Config) { $argv += @('-Config', $Config) }
    $log = @(& powershell.exe @argv 2>&1)
    $ok = ($LASTEXITCODE -eq 0)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($one in $log) { $lines.Add([string]$one) }
    # the folder the run wrote, written by package.ps1 itself: a caller that wants to check the
    # release needs the path, not a name it would have to rebuild from two files
    $packagePath = ''
    $resultFile = $file + '.result'
    if (Test-Path -LiteralPath $resultFile) { $packagePath = ([IO.File]::ReadAllText($resultFile)).Trim() }
    return @{
      Ok      = $ok
      Log     = $lines.ToArray()
      Package = $packagePath
    }
  } finally {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ($file + '.result') -Force -ErrorAction SilentlyContinue
  }
}

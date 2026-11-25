# packages\cli\bundle.ps1 - build the targets the config declares, through the bundler.
#
# A function, not a script: packages\cli\bin\cli.ps1 is the assembly point.
#
#   -Entry <name>   one target, by name
#   -All            every target, side by side
#   -Inspect        say which modules a bundle cannot inline
#
# This is the vite half of the tooling: it resolves the config, decides the chain, the sources,
# the output path and the three rewrite switches, and hands that document to packages\bundler.
# The bundler reads no config of its own.
#
# No package is written here. `build` is the one that stages and packs; this command leaves its
# outputs under out\ so a single target can be inspected.
function Invoke-CliBundle {
  param(
    [string]$Entry = '',
    [string]$Out = '',
    [string]$From = '',
    [string]$ConfigFile = '',
    [switch]$All,
    [switch]$Inspect,
    [switch]$Suggest,
    [switch]$Quiet,
    [switch]$Silent
  )
  if (-not (Get-Command -Name 'Invoke-BundleTarget' -CommandType Function -ErrorAction SilentlyContinue)) {
    Write-Fail 'packages\bundler is not loaded'
    return 1
  }
  $bundlerScript = Join-Path (Split-Path -Parent (Get-CliHome)) 'bundler\bundler.ps1'
  if (-not (Test-Path -LiteralPath $bundlerScript)) { Write-Fail ('missing: ' + $bundlerScript); return 1 }

  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bundlerScript)
  $specFile = ''
  try {
    if ($Inspect) {
      $argv += '-Inspect'
      if ($Suggest) { $argv += '-Suggest' }
    } else {
      $config = Resolve-CliSession -ConfigFile $ConfigFile
      $spec = ConvertTo-BundleSpec $config 'out'
      $specFile = Join-Path $env:TEMP ('bundle-spec-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
      [IO.File]::WriteAllText($specFile, ($spec | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding $false))
      $argv += @('-TargetFile', $specFile)
      if ($All) { $argv += '-All' }
      elseif ($Entry) { $argv += @('-Entry', $Entry) }
      if ($Out) { $argv += @('-Out', $Out) }
      if ($From) { $argv += @('-From', $From) }
    }
    if ($Quiet) { $argv += '-Quiet' }
    if ($Silent) { $argv += '-Silent' }
    # straight to the host: the caller gets the exit code back and nothing else
    & powershell.exe @argv | Out-Host
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    return $code
  } finally {
    if ($specFile) { Remove-Item -LiteralPath $specFile -Force -ErrorAction SilentlyContinue }
  }
}

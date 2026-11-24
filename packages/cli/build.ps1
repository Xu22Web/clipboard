# packages\cli\build.ps1 - build every target, then hand the result to packages\builder.
#
# A function, not a script: builder.cli.ps1 is the assembly point that loads the three packages
# and calls this one. Nothing here dot-sources a package or reads the command table.
#
# Two stages, the way electron-vite and electron-builder divide the work:
#
#   1. every target of builder.cli.config.ps1 is built through packages\bundler. A Ship target
#      is written to a temporary folder, because the package keeps its output instead of its
#      sources; a C# target is compiled into src\, so a source run and the watcher use the same
#      binary.
#   2. the outputs and the file list in builder.ini go to packages\builder, which stages, packs
#      and checks the release.
#
# Neither stage reads the other's config: this function is the only place that knows both, and
# what it passes on is a list of paths.
function Invoke-CliBuild {
  param(
    [string]$ConfigFile = '',
    [string]$BuilderConfig = ''
  )

  $config = Resolve-CliSession -ConfigFile $ConfigFile
  $app = Get-PkgValue 'name'
  $version = Get-PkgValue 'version'
  if (-not $app) { Write-Fail 'package.ini has no [package] Name'; return @{ Code = 1; Package = '' } }
  if (-not $version) { Write-Fail 'package.ini has no [package] Version'; return @{ Code = 1; Package = '' } }
  if (-not (Get-Command -Name 'Invoke-BundleTarget' -CommandType Function -ErrorAction SilentlyContinue)) {
    Write-Fail 'packages\bundler is not loaded'
    return @{ Code = 1; Package = '' }
  }
  if (-not (Get-Command -Name 'Invoke-Package' -CommandType Function -ErrorAction SilentlyContinue)) {
    Write-Fail 'packages\builder is not loaded'
    return @{ Code = 1; Package = '' }
  }

  $tmpOut = Join-Path $env:TEMP ('cli-build-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmpOut -Force | Out-Null
  $outputs = New-Object System.Collections.Generic.List[object]
  $failed = $false
  try {
    foreach ($t in @($config.Targets)) {
      # a target that is neither shipped nor compiled is a check, not a release step: it is built
      # by `bundle -Entry <name>` when someone asks for it
      if (-not $t.Ship -and $t.Kind -ne 'cs') { continue }
      $relOut = ([string]$t.Output) -replace '/', '\'
      # an entry-driven target writes one file per chunk under the template's folder, so -Out (a
      # single file) does not apply: the whole folder it produced is staged, manifest included
      $multi = @($t.Entries).Count -gt 0
      $toSrc = ($t.Kind -eq 'cs' -and -not $t.Ship)
      if ($toSrc) { $targetPath = Join-Path (Join-Path $config.Root 'src') $relOut }
      else { $targetPath = Join-Path $tmpOut $relOut }

      $spec = ConvertTo-BundleSpec $config 'out'
      $one = @{
        Root    = $config.Root
        OutDir  = 'out'
        Workers = 1
        Targets = @($spec.Targets | Where-Object { $_.Name -eq $t.Name })
      }
      if ($multi) { $r = Invoke-BundleTarget -Spec $one -Entry $t.Name }
      else { $r = Invoke-BundleTarget -Spec $one -Entry $t.Name -Out $targetPath }
      foreach ($line in @($r.Log)) {
        $text = ([string]$line).Trim()
        if (-not $text) { continue }
        if ($text.StartsWith('[ok]')) { continue }
        Write-Note $text
      }
      if (-not $r.Ok) {
        Write-Fail ('target ' + $t.Name + ' failed')
        $failed = $true
        continue
      }

      # the sources the output replaces, as paths relative to the repository root
      $replaces = New-Object System.Collections.Generic.List[string]
      if ($toSrc) {
        $srcDir = Join-Path (Join-Path $config.Root 'src') (Split-Path -Parent $relOut)
        if (Test-Path -LiteralPath $srcDir) {
          $srcFull = ([IO.Path]::GetFullPath($srcDir)).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
          foreach ($f in @(Get-ChildItem -LiteralPath $srcDir -Recurse -File -Filter '*.cs')) {
            $full = [IO.Path]::GetFullPath($f.FullName)
            $under = $full
            if ($full.StartsWith($srcFull, [StringComparison]::OrdinalIgnoreCase)) { $under = $full.Substring($srcFull.Length) }
            $replaces.Add(('src\' + (Split-Path -Parent $relOut) + '\' + $under))
          }
        }
      } elseif ($multi) {
        # exactly the modules the chunks carry: the manifest's [modules] section names them, so a
        # shared module ships once (inside its chunk) and one nothing bundled keeps its own file
        $toParent = Split-Path -Parent $relOut
        $manifestPath = Join-Path (Join-Path (Join-Path $config.Root 'out') $toParent) 'manifest.ini'
        # only the modules the window layer itself owns may leave the package: every command that
        # runs without a window (list / status / config) still loads its own files, so a module the
        # base or a command group reaches keeps its file even when a chunk also carries it
        $windowSet = @{}
        $entryText = [IO.File]::ReadAllText((Join-Path (Join-Path $config.Root 'src') 'clipboard.ps1'))
        $windowBlock = [regex]::Match($entryText, '\$windowModules\s*=\s*@\(([^\)]*)\)').Groups[1].Value
        foreach ($m in [regex]::Matches($windowBlock, "'([^']+)'")) {
          $windowSet[$m.Groups[1].Value.Replace('\', '/').ToLowerInvariant()] = $true
        }
        $inModules = $false
        if (Test-Path -LiteralPath $manifestPath) {
          foreach ($line in @([IO.File]::ReadAllLines($manifestPath))) {
            $t2 = $line.Trim()
            if ($t2.StartsWith('[')) { $inModules = ($t2 -eq '[modules]'); continue }
            if (-not $inModules -or -not $t2) { continue }
            $at = $t2.IndexOf('=')
            if ($at -lt 1) { continue }
            foreach ($id in @($t2.Substring($at + 1).Split(','))) {
              $one3 = $id.Trim()
              if (-not $one3) { continue }
              if (-not $windowSet.ContainsKey($one3.ToLowerInvariant())) { continue }
              $replaces.Add(('src\' + $one3.Replace('/', '\') + '.ps1'))
            }
          }
        }
      } else {
        foreach ($one2 in @(([string]$t.Input) -split '[,;]')) {
          $item = $one2.Trim()
          if (-not $item -or $item -match '[*?]') { continue }
          $replaces.Add(($item -replace '/', '\'))
        }
      }

      if ($multi) {
        # stage everything the target wrote: the entry chunks, the shared ones under assets\, and
        # the manifest that says which file is loaded when
        $toParent = Split-Path -Parent $relOut
        $fromFull = ([IO.Path]::GetFullPath((Join-Path (Join-Path $config.Root 'out') $toParent))).TrimEnd([char]92, [char]47)
        if (Test-Path -LiteralPath $fromFull) {
          foreach ($f in @(Get-ChildItem -LiteralPath $fromFull -Recurse -File)) {
            $rel = $f.FullName.Substring($fromFull.Length + 1)
            $dest = Join-Path (Join-Path $tmpOut $toParent) $rel
            $parent = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
            $outputs.Add(@{ Rel = ($toParent + '\' + $rel); Path = $dest; Replaces = $replaces.ToArray() })
            Write-Note ('built ' + $toParent + '\' + $rel + '   ' + [Math]::Round($f.Length / 1KB, 1) + ' KB')
          }
        }
      } else {
        $outputs.Add(@{
            Rel      = $relOut
            Path     = $targetPath
            Replaces = $replaces.ToArray()
          })
        $kb = 0
        if (Test-Path -LiteralPath $targetPath) { $kb = [Math]::Round((Get-Item -LiteralPath $targetPath).Length / 1KB, 1) }
        Write-Note ('built ' + $relOut + '   ' + $kb + ' KB')
      }
    }

    if ($failed) { return @{ Code = 1; Package = '' } }

    $request = @{
      Root    = $config.Root
      App     = $app
      Version = $version
      Outputs = $outputs.ToArray()
    }
    $result = Invoke-Package -Request $request -Config $BuilderConfig
    foreach ($line in @($result.Log)) { Write-Raw ([string]$line) }
    if (-not $result.Ok) {
      Write-Fail 'the release was not written'
      return @{ Code = 1; Package = '' }
    }
    return @{ Code = 0; Package = $result.Package }
  } finally {
    if (Test-Path -LiteralPath $tmpOut) { Remove-Item -LiteralPath $tmpOut -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

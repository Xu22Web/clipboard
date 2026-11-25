# packages\cli\config.ps1 - read builder.cli.config.ps1 and decide, for every target, what the
# bundler is told.
#
# This is the resolveConfig step: the one place that knows the shape of a target, applies the
# preset the config names, merges this package's own defaults into it, and hands a plain document
# to the bundler. No other file in this package reads the config file.

# The keys a target may hold. Anything else is a typo the failure of which would otherwise be
# silent - a misspelled Minify simply keeps the default.
$script:TargetKeys = @('Preset', 'Plugins', 'Kind', 'Input', 'Scan', 'Output', 'External', 'Ship', 'Target', 'Minify', 'Rename', 'Treeshake', 'Append', 'Keep')

function ConvertTo-Flag($value) {
  if ($null -eq $value) { return $false }
  if ($value -is [bool]) { return $value }
  $text = ([string]$value).Trim()
  if (-not $text) { return $false }
  return @('1', 'true', 'yes', 'on') -contains $text.ToLowerInvariant()
}

# A package.ini is the package's own declaration: what it is called, the module that stands for
# it, and what that module exports. Anything missing is a broken package, reported when it is
# loaded rather than when something is called.
function Read-PackageFile([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { throw ('missing package file: ' + $path) }
  $doc = Read-IniDoc ([IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8))
  $map = $doc.Map
  $read = {
    param($name)
    if ($map.ContainsKey('package.' + $name)) { return ([string]$map['package.' + $name]).Trim() }
    if ($map.ContainsKey($name)) { return ([string]$map[$name]).Trim() }
    return ''
  }
  $pkg = @{
    Path     = $path
    Dir      = Split-Path -Parent $path
    Name     = (& $read 'Name')
    Version  = (& $read 'Version')
    Main     = (& $read 'Main')
    Exports  = (& $read 'Exports')
    Requires = (& $read 'Requires')
    Map      = $map
  }
  foreach ($required in @('Name', 'Version', 'Main')) {
    if (-not $pkg[$required]) { throw ((Split-Path -Leaf $path) + ': no ' + $required + '=') }
  }
  $mainPath = Join-Path $pkg.Dir $pkg.Main
  if (-not (Test-Path -LiteralPath $mainPath)) { throw ((Split-Path -Leaf $path) + ': Main= names no file: ' + $pkg.Main) }
  $pkg['MainPath'] = $mainPath
  return $pkg
}

# the targets the config file declares, in the order it declares them
function Resolve-CliConfig {
  param(
    [string]$Root,
    [string]$ConfigFile = '',
    [array]$Problems = $null
  )
  if (-not $ConfigFile) { $ConfigFile = Join-Path $Root 'builder.cli.config.ps1' }
  if (-not (Test-Path -LiteralPath $ConfigFile)) { throw ('missing config file: ' + $ConfigFile) }
  $doc = & $ConfigFile
  if ($null -eq $doc -or -not ($doc -is [System.Collections.IDictionary])) {
    throw ((Split-Path -Leaf $ConfigFile) + ' must return one table of targets')
  }

  # The defaults of the whole tooling, in one place: a config file names a key here only to
  # change it, the way a vite.config writes build.minify only when it is not the default.
  $bundler = @{ Minify = $true; Rename = $true; Treeshake = $true; Workers = 0 }
  $watch = @{ Interval = 600 }
  if ($doc.Contains('Bundler')) {
    $given = $doc['Bundler']
    if ($null -eq $given -or -not ($given -is [System.Collections.IDictionary])) { throw 'Bundler must be a table of keys' }
    foreach ($key in @('Minify', 'Rename', 'Treeshake')) {
      if ($given.Contains($key)) { $bundler[$key] = ConvertTo-Flag $given[$key] }
    }
    if ($given.Contains('Workers')) {
      $w = 0
      [void][int]::TryParse(([string]$given['Workers']).Trim(), [ref]$w)
      $bundler['Workers'] = $w
    }
  }
  if ($doc.Contains('Watch')) {
    $given = $doc['Watch']
    if ($null -ne $given -and $given -is [System.Collections.IDictionary] -and $given.Contains('Interval')) {
      $i = 0
      [void][int]::TryParse(([string]$given['Interval']).Trim(), [ref]$i)
      if ($i -gt 0) { $watch['Interval'] = $i }
    }
  }

  $names = New-Object System.Collections.Generic.List[string]
  $targets = New-Object System.Collections.Generic.List[object]
  $bad = New-Object System.Collections.Generic.List[string]
  foreach ($key in @($doc.Keys)) {
    $name = [string]$key
    # the two settings sections are not targets
    if (@('bundler', 'watch') -contains $name.ToLowerInvariant()) { continue }
    $def = $doc[$key]
    if ($null -eq $def) { $bad.Add(($name + ': the section is empty')); continue }
    if (-not ($def -is [System.Collections.IDictionary])) { $bad.Add(($name + ': a target is a table of keys')); continue }
    if ($names.Contains($name)) { continue }
    $names.Add($name)

    $t = @{
      Name      = $name
      Kind      = 'script'
      Plugins   = ''
      Input     = ''
      Entries   = @()
      Scan      = ''
      Output    = ''
      ChunkOutput = ''
      External  = ''
      Target    = 'library'
      Ship      = $false
      Append    = ''
      Keep      = ''
      Minify    = $bundler.Minify
      Rename    = $bundler.Rename
      Treeshake = $bundler.Treeshake
    }

    # a preset first: the config then overrides whatever it names, an empty value included. A
    # section named like a preset uses it without writing Preset= at all.
    $presetName = $name.ToLowerInvariant()
    $explicit = $false
    if ($def.Contains('Preset')) {
      $given = ([string]$def['Preset']).Trim()
      if ($given) { $presetName = $given; $explicit = $true }
    }
    $preset = Get-Preset $presetName
    if ($null -eq $preset) {
      if ($explicit) { $bad.Add(($name + ': no preset named ' + $presetName + '   (known: ' + ((Get-PresetNames) -join ', ') + ')')) }
    } else {
      foreach ($pk in @($preset.Keys)) { $t[[string]$pk] = $preset[$pk] }
    }

    foreach ($k in @($def.Keys)) {
      $field = [string]$k
      if ($field -eq 'Preset') { continue }
      if ($script:TargetKeys -notcontains $field) { $bad.Add(($name + ': unknown key ' + $field)); continue }
      $value = $def[$k]
      if (@('Ship', 'Minify', 'Rename', 'Treeshake') -contains $field) {
        $t[$field] = ConvertTo-Flag $value
      } elseif ($field -eq 'Input') {
        # rolldown's input: one path, a table of key -> path, or a table of key -> @{ Entry= }.
        # A table names the chunks, so the output template can use [name] and the file a window
        # loads is the key it was given; Entry= is the form that keeps a key and its file apart.
        if ($value -is [System.Collections.IDictionary]) {
          $entryList = New-Object System.Collections.Generic.List[object]
          foreach ($chunkKey in @($value.Keys)) {
            $item = $value[$chunkKey]
            $chunkName = [string]$chunkKey
            $path = ''
            if ($item -is [System.Collections.IDictionary]) {
              if ($item.Contains('Entry')) { $path = ([string]$item['Entry']).Trim() }
              if ($item.Contains('Key')) {
                $given = ([string]$item['Key']).Trim()
                if ($given) { $chunkName = $given }
              }
            } else {
              $path = ([string]$item).Trim()
            }
            if (-not $path) { continue }
            $entryList.Add(@{ Name = $chunkName; Path = $path })
          }
          $t['Entries'] = $entryList.ToArray()
          $t['Input'] = ''
        } else {
          $parts = @($value | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
          $t['Input'] = ($parts -join ',')
        }
      } elseif ($field -eq 'Scan') {
        $parts = @($value | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
        $t['Scan'] = ($parts -join ',')
      } elseif ($field -eq 'Output' -and $value -is [System.Collections.IDictionary]) {
        # rolldown's entryFileNames / chunkFileNames: an entry chunk keeps the entry's own name,
        # a chunk more than one entry loads goes to its own folder
        if ($value.Contains('Entry')) { $t['Output'] = ([string]$value['Entry']).Trim() }
        if ($value.Contains('Chunk')) { $t['ChunkOutput'] = ([string]$value['Chunk']).Trim() }
      } else {
        $t[$field] = ([string]$value).Trim()
      }
    }

    foreach ($required in @('Plugins', 'Input', 'Output')) {
      if ($required -eq 'Input') {
        # a target starts from its entry table as well as from a file list
        if (-not $t['Input'] -and @($t['Entries']).Count -eq 0) { $bad.Add(($name + ': no Input')) }
        continue
      }
      if (-not $t[$required]) { $bad.Add(($name + ': no ' + $required)) }
    }
    $targets.Add($t)
  }
  if ($names.Count -eq 0) { $bad.Add((Split-Path -Leaf $ConfigFile) + ': declares no target') }

  $result = @{
    Root       = $Root
    ConfigFile = $ConfigFile
    Names      = $names.ToArray()
    Targets    = $targets.ToArray()
    Bundler    = $bundler
    Watch      = $watch
  }
  if ($null -ne $Problems) {
    foreach ($p in $bad) { [void]$Problems.Add($p) }
  } elseif ($bad.Count -gt 0) {
    throw ($bad -join [Environment]::NewLine)
  }
  return $result
}

# The document the bundler reads: the repository root, the folder an output lands in when the
# target names no absolute path, the worker count, and the targets themselves.
function ConvertTo-BundleSpec($config, [string]$outDir = 'out') {
  $spec = @{
    Root    = $config.Root
    OutDir  = $outDir
    Workers = $config.Bundler.Workers
    Targets = @()
  }
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($t in @($config.Targets)) {
    $list.Add(@{
        Name      = $t.Name
        Kind      = $t.Kind
        Plugins   = $t.Plugins
        Input     = $t.Input
        Entries   = $t.Entries
        Scan      = $t.Scan
        Output    = $t.Output
        ChunkOutput = $t.ChunkOutput
        External  = $t.External
        Target    = $t.Target
        Append    = $t.Append
        Keep      = $t.Keep
        Minify    = [string]$(if ($t.Minify) { '1' } else { '0' })
        Rename    = [string]$(if ($t.Rename) { '1' } else { '0' })
        Treeshake = [string]$(if ($t.Treeshake) { '1' } else { '0' })
      })
  }
  $spec['Targets'] = $list.ToArray()
  return $spec
}

# packages\bundler\lib\chunk.ps1 - which modules belong to which chunk, and what a chunk is called.
#
# The rule is rolldown's: every entry gets a bit, every module carries the set of entries that
# reach it, and modules with the *same* set land in the same chunk. Two modules with different
# sets are never loaded under the same conditions, so merging them would make one entry load code
# it never reaches; identical sets are the only safe grouping, and it needs no configuration.
#
# The shared chunk comes first: a set covering every entry is loaded by all of them, so it is
# written before the chunks that read from it. The rest follow the number of entries that reach
# them, so a module two entries share is placed before one a single entry needs.
function Split-BundleChunks($closures) {
  $leaves = New-Object System.Collections.Generic.List[string]
  foreach ($name in @($closures.Keys)) { $leaves.Add([string]$name) }
  $index = @{}
  for ($i = 0; $i -lt $leaves.Count; $i++) { $index[$leaves[$i].ToLowerInvariant()] = $i }

  # reachability: one bit per entry, set for every entry that reaches the module
  $reach = @{}
  $firstSeen = New-Object System.Collections.Generic.List[string]
  foreach ($leaf in $leaves) {
    foreach ($file in @($closures[$leaf])) {
      $key = ([string]$file).ToLowerInvariant()
      if (-not $reach.ContainsKey($key)) {
        $reach[$key] = New-Object 'bool[]' $leaves.Count
        $firstSeen.Add([string]$file)
      }
      $reach[$key][$index[$leaf.ToLowerInvariant()]] = $true
    }
  }

  # the signature is the bits as text: two modules with the same text are always needed together
  $groups = New-Object System.Collections.Generic.List[object]
  $groupOf = @{}
  foreach ($file in $firstSeen) {
    $key = $file.ToLowerInvariant()
    $sig = ''
    for ($i = 0; $i -lt $leaves.Count; $i++) { if ($reach[$key][$i]) { $sig += '1' } else { $sig += '0' } }
    if (-not $groupOf.ContainsKey($sig)) {
      $groupOf[$sig] = @{ Signature = $sig; Bits = 0; First = $groups.Count; Files = (New-Object System.Collections.Generic.List[string]) }
      $groups.Add($groupOf[$sig])
    }
    $groupOf[$sig].Files.Add([string]$file)
  }
  foreach ($g in $groups) {
    $bits = 0
    for ($i = 0; $i -lt $leaves.Count; $i++) { if ($g.Signature[$i] -eq '1') { $bits++ } }
    $g.Bits = $bits
  }

  # most entries first (the shared chunk), and the order the modules first appeared inside a group
  $ordered = @($groups | Sort-Object -Property @{ Expression = { -1 * $_.Bits } }, @{ Expression = { $_.First } })
  $all = ''
  for ($i = 0; $i -lt $leaves.Count; $i++) { $all += '1' }

  $pieces = New-Object System.Collections.Generic.List[object]
  $used = @{}
  $sharedNo = 0
  foreach ($g in $ordered) {
    $name = ''
    if ($g.Signature -eq $all) {
      $name = 'shared'
    } else {
      $only = -1
      $count = 0
      for ($i = 0; $i -lt $leaves.Count; $i++) {
        if ($g.Signature[$i] -eq '1') { $count++; $only = $i }
      }
      if ($count -eq 1) { $name = $leaves[$only] } else { $sharedNo++; $name = 'shared' + $sharedNo }
    }
    if ($used.ContainsKey($name.ToLowerInvariant())) { $sharedNo++; $name = 'shared' + $sharedNo }
    $used[$name.ToLowerInvariant()] = $true
    $pieces.Add(@{ Name = $name; Files = $g.Files.ToArray(); Bits = $g.Bits })
  }

  return @{ Pieces = $pieces.ToArray() }
}

# Eight hex characters of the content's sha256, which is what a bundler puts in a file name: the
# name changes when the bytes change, so a cache and a browser (or a dot-source list) can trust it.
function Get-BundleHash([string]$text) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$text))
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 4; $i++) { [void]$sb.Append($bytes[$i].ToString('x2')) }
    return $sb.ToString()
  } finally {
    $sha.Dispose()
  }
}

# Output= may carry [name] and [hash]; a template without them is used as it is.
function Format-BundleOutput([string]$template, [string]$name, [string]$hash) {
  $out = [string]$template
  if (-not $out) { $out = '[name].ps1' }
  $out = $out.Replace('[name]', [string]$name)
  $out = $out.Replace('[hash]', [string]$hash)
  return $out
}

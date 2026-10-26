# transform - rewrite what gets pasted.
#
# Modes: keep (default) / text / upper / lower / camel / snake / kebab / title
#   text   line breaks and runs of spaces collapse into single spaces
#   camel / snake / kebab / title   split on space, _ - and lower->upper, then join
#
# Settings: transform.Mode / transform.Trim
# One-off:  clipboard transform 3            entry 3 with the configured mode
#           clipboard transform "3 snake"    entry 3 as snake_case (quotes required)
#
# Scriptblocks must be self-contained: they may call base helpers
# (Get-Records, Get-PluginSetting, Format-Item ...) but must never read a variable created
# in this file's own scope - that scope is gone by the time the block runs, so the variable
# reads as $null and any `& $var` on it fails. That is why the rewrite logic is repeated
# instead of living in a shared helper variable.
@{
  Name        = 'transform'
  Description = 'Paste transformed: plain text, UPPER, lower, camelCase, snake_case, kebab-case, Title Case'
  CommandHelp = @{
    'transform' = 'transform entry N and put it on the clipboard (quote "3 snake" for a one-off mode)'
  }
  Settings    = [ordered]@{
    Mode = @{ Kind = 'enum'; Options = @('keep', 'text', 'upper', 'lower', 'camel', 'snake', 'kebab', 'title'); Default = 'keep'; Desc = 'how a pasted entry is rewritten' }
    Trim = @{ Kind = 'bool'; Default = 1; Desc = '1 = trim leading and trailing spaces of the result' }
  }
  Transform   = {
    param($payload)
    $mode = Get-PluginSetting 'transform' 'Mode'
    if (-not $mode -or $mode -eq 'keep') { return $payload }
    $s = [string]$payload
    if ($s.Length -eq 0) { return $payload }
    if ($s[0] -eq [char]1) { return $payload }   # file lists are left alone
    switch ($mode) {
      'text' { return ($s -replace '\s+', ' ').Trim() }
      'upper' { return $s.ToUpperInvariant() }
      'lower' { return $s.ToLowerInvariant() }
    }
    $words = @([regex]::Replace($s.Trim(), '([a-z0-9])([A-Z])', '$1 $2') -split '[\s_\-]+' | Where-Object { $_ })
    if ($words.Count -eq 0) { return $payload }
    $out = $payload
    switch ($mode) {
      'camel' {
        $out = $words[0].ToLowerInvariant()
        for ($i = 1; $i -lt $words.Count; $i++) {
          $w = $words[$i].ToLowerInvariant()
          $out += $w.Substring(0, 1).ToUpperInvariant() + $w.Substring(1)
        }
      }
      'snake' { $out = (($words | ForEach-Object { $_.ToLowerInvariant() }) -join '_') }
      'kebab' { $out = (($words | ForEach-Object { $_.ToLowerInvariant() }) -join '-') }
      'title' {
        $out = (($words | ForEach-Object {
              $w = $_.ToLowerInvariant()
              $w.Substring(0, 1).ToUpperInvariant() + $w.Substring(1)
            }) -join ' ')
      }
    }
    if ((Get-PluginSetting 'transform' 'Trim') -eq '1') { $out = ([string]$out).Trim() }
    return $out
  }
  Commands    = @{
    'transform' = {
      param($value)
      $modes = @('keep', 'text', 'upper', 'lower', 'camel', 'snake', 'kebab', 'title')
      $parts = @([string]$value -split '\s+' | Where-Object { $_ })
      $i = 0
      if ($parts.Count -eq 0 -or -not [int]::TryParse($parts[0], [ref]$i)) {
        Write-Host 'usage: clipboard transform 3            (configured mode)'
        Write-Host '       clipboard transform "3 snake"    (one-off mode)'
        return
      }
      $recs = @(Get-Records)
      if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; return }
      $src = [string]$recs[$i - 1].Payload
      $mode = Get-PluginSetting 'transform' 'Mode'
      if ($parts.Count -gt 1) { $mode = $parts[1] }
      if ($modes -notcontains $mode) {
        Write-Host ('unknown mode: ' + $mode)
        Write-Host ('modes: ' + ($modes -join ' '))
        return
      }
      $out = $src
      switch ($mode) {
        'keep' { }
        'text' { $out = ($src -replace '\s+', ' ').Trim() }
        'upper' { $out = $src.ToUpperInvariant() }
        'lower' { $out = $src.ToLowerInvariant() }
        default {
          $words = @([regex]::Replace($src.Trim(), '([a-z0-9])([A-Z])', '$1 $2') -split '[\s_\-]+' | Where-Object { $_ })
          if ($words.Count -eq 0) { Write-Host 'nothing to transform'; return }
          switch ($mode) {
            'camel' {
              $out = $words[0].ToLowerInvariant()
              for ($k = 1; $k -lt $words.Count; $k++) {
                $w = $words[$k].ToLowerInvariant()
                $out += $w.Substring(0, 1).ToUpperInvariant() + $w.Substring(1)
              }
            }
            'snake' { $out = (($words | ForEach-Object { $_.ToLowerInvariant() }) -join '_') }
            'kebab' { $out = (($words | ForEach-Object { $_.ToLowerInvariant() }) -join '-') }
            'title' {
              $out = (($words | ForEach-Object {
                    $w = $_.ToLowerInvariant()
                    $w.Substring(0, 1).ToUpperInvariant() + $w.Substring(1)
                  }) -join ' ')
            }
          }
        }
      }
      if ((Get-PluginSetting 'transform' 'Trim') -eq '1') { $out = ([string]$out).Trim() }
      if ([string]::IsNullOrEmpty($out)) { Write-Host 'nothing left after the transform'; return }
      [void](Set-ClipItem $out)
      Add-Item $out
      Write-Host ('[' + $mode + '] ' + (Format-Item $out 100))
    }
  }
}

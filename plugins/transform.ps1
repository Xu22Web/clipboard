# transform - rewrite what gets pasted.
#
# Modes: keep (default) / text / upper / lower / camel / snake / kebab / title
#   text   line breaks and runs of spaces collapse into single spaces
#   camel / snake / kebab / title   split on space, _ - and lower->upper, then join
#
# Settings: transform.Mode / transform.Trim
# One-off:  clipboard transform 3            entry 3 with the configured mode
#           clipboard transform "3 snake"    entry 3 as snake_case (quotes required)
# Right-click  "Transform as <mode>" applies the configured mode to that row and copies it
#
# The rewrite itself lives in one shared block (Apply). The paste hook, the command and
# the context menu all reach it through Get-PluginData - a scriptblock cannot see this
# file's own variables, so blocks are looked up by plugin name instead of captured.
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
  # param($text, $mode) -> rewritten text; the input comes back unchanged when the mode
  # is 'keep', the payload is a file list, or the text holds nothing to split
  Apply       = {
    param([string]$text, [string]$mode)
    if (-not $mode -or $mode -eq 'keep') { return $text }
    if ($text.Length -eq 0) { return $text }
    if ($text[0] -eq [char]1) { return $text }
    $out = $text
    switch ($mode) {
      'text' { $out = ($text -replace '\s+', ' ').Trim() }
      'upper' { $out = $text.ToUpperInvariant() }
      'lower' { $out = $text.ToLowerInvariant() }
      default {
        $words = @([regex]::Replace($text.Trim(), '([a-z0-9])([A-Z])', '$1 $2') -split '[\s_\-]+' | Where-Object { $_ })
        if ($words.Count -eq 0) { return $text }
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
      }
    }
    $out = [string]$out
    if ((Get-PluginSetting 'transform' 'Trim') -eq '1') { $out = $out.Trim() }
    return $out
  }
  Transform   = {
    param($payload)
    $mode = [string](& (Get-PluginData 'transform' 'CurrentMode'))
    return (& (Get-PluginData 'transform' 'Apply') ([string]$payload) $mode)
  }
  # the configured mode, never empty
  CurrentMode = {
    $m = [string](Get-PluginSetting 'transform' 'Mode')
    if (-not $m) { $m = 'keep' }
    return $m
  }
  # rewrite + put on the clipboard + record it: what both the command and the menu do
  CopyAs      = {
    param($payload, $mode)
    $out = [string](& (Get-PluginData 'transform' 'Apply') ([string]$payload) ([string]$mode))
    if ([string]::IsNullOrEmpty($out)) { return '' }
    [void](Set-ClipItem $out)
    Add-Item $out
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
      $mode = [string](& (Get-PluginData 'transform' 'CurrentMode'))
      if ($parts.Count -gt 1) { $mode = $parts[1] }
      if ($modes -notcontains $mode) {
        Write-Host ('unknown mode: ' + $mode)
        Write-Host ('modes: ' + ($modes -join ' '))
        return
      }
      $out = [string](& (Get-PluginData 'transform' 'CopyAs') $src $mode)
      if ([string]::IsNullOrEmpty($out)) { Write-Host 'nothing left after the transform'; return }
      Write-Host ('[' + $mode + '] ' + (Format-Item $out 100))
    }
  }
  # acts on the row under the cursor: only when a real mode is configured and the row is
  # text (a file list has no words to re-join)
  ContextMenu = @(
    @{
      Label  = { param($rec) 'Transform as ' + [string](& (Get-PluginData 'transform' 'CurrentMode')) }
      Test   = {
        param($rec)
        if ($null -eq $rec) { return $false }
        $m = [string](& (Get-PluginData 'transform' 'CurrentMode'))
        if (-not $m -or $m -eq 'keep') { return $false }
        $p = [string]$rec.Payload
        if ($p.Length -eq 0) { return $false }
        return ($p[0] -ne [char]1)
      }
      Invoke = {
        param($rec)
        if ($null -eq $rec) { return }
        $m = [string](& (Get-PluginData 'transform' 'CurrentMode'))
        [void](& (Get-PluginData 'transform' 'CopyAs') ([string]$rec.Payload) $m)
      }
    }
  )
}

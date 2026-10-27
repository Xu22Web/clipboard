# transform - rewrite what gets pasted.
#
# Modes: keep (default) / text / upper / lower / camel / snake / kebab / title
#   text   line breaks and runs of spaces collapse into single spaces
#   camel / snake / kebab / title   split on space, _ - and lower->upper, then join
#
# Settings: transform.Mode / transform.Modes / transform.Trim
# One-off:  clipboard transform 3            entry 3 with the configured mode
#           clipboard transform "3 snake"    entry 3 as snake_case (quotes required)
# Right-click  one "Transform as <mode>" entry per mode listed in transform.Modes; with
#              Modes empty the menu offers the configured transform.Mode only
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
    Mode  = @{ Kind = 'enum'; Options = @('keep', 'text', 'upper', 'lower', 'camel', 'snake', 'kebab', 'title'); Default = 'keep'; Desc = 'how a pasted entry is rewritten' }
    Modes = @{ Kind = 'string'; Default = ''; Desc = 'modes offered in the context menu, comma separated; empty = only Mode' }
    Trim  = @{ Kind = 'bool'; Default = 1; Desc = '1 = trim leading and trailing spaces of the result' }
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
  # how a mode is spelled in the menu and in messages
  ModeLabel   = {
    param($mode)
    switch ([string]$mode) {
      'text' { return 'plain text' }
      'upper' { return 'UPPER' }
      'lower' { return 'lower' }
      'camel' { return 'camelCase' }
      'snake' { return 'snake_case' }
      'kebab' { return 'kebab-case' }
      'title' { return 'Title Case' }
      default { return [string]$mode }
    }
  }
  # the modes the context menu offers: what transform.Modes lists, or just the configured
  # Mode when it is empty. Unknown and repeated names are dropped, 'keep' never shows up.
  MenuModes   = {
    $known = @('text', 'upper', 'lower', 'camel', 'snake', 'kebab', 'title')
    $list = @()
    $raw = [string](Get-PluginSetting 'transform' 'Modes')
    foreach ($part in @($raw -split '[,;\s]+')) {
      $n = ([string]$part).Trim().ToLowerInvariant()
      if (-not $n -or $n -eq 'keep') { continue }
      if (($known -notcontains $n) -or ($list -contains $n)) { continue }
      $list += $n
    }
    if ($list.Count -eq 0) {
      $m = [string](& (Get-PluginData 'transform' 'CurrentMode'))
      if ($m -and $m -ne 'keep') { $list += $m }
    }
    return $list
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
  # one entry per mode the settings ask for; the row under the cursor is rewritten with
  # that mode, so a single setting decides how many menu items exist
  ContextMenu = {
    $out = @()
    foreach ($m in @(& (Get-PluginData 'transform' 'MenuModes'))) {
      # GetNewClosure binds this mode into the block, the loop variable changes each pass
      $mode = [string]$m
      $out += @{
        Label  = { param($rec) 'Transform as ' + [string](& (Get-PluginData 'transform' 'ModeLabel') $mode) }.GetNewClosure()
        Test   = {
          param($rec)
          if ($null -eq $rec) { return $false }
          $p = [string]$rec.Payload
          if ($p.Length -eq 0) { return $false }
          # a file list has no words to re-join
          return ($p[0] -ne [char]1)
        }
        Invoke = {
          param($rec)
          if ($null -eq $rec) { return }
          [void](& (Get-PluginData 'transform' 'CopyAs') ([string]$rec.Payload) $mode)
        }.GetNewClosure()
      }
    }
    return $out
  }
}

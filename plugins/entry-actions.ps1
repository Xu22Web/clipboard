# entry-actions - know what an entry is, then act on it.
#
#   clipboard kind 3    kind, size, target parts, sniffed formats and a preview
#   clipboard kinds     how many entries of each kind the history holds
#   clipboard open 3    open the link / path / file list in entry 3
#   Ctrl+O, context menu  the same open, on the selected row
#
# The base only tells a file list from text (Get-EntryKind); the richer typing used by the
# commands, the menu item and the Ctrl+O key lives here as the shared KindOf helper.
#
# Settings: entry-actions.Browser / Reveal / Detail / PreviewChars / Detect / ShowTargets
#
# Scriptblocks must be self-contained: they may call base helpers, but must not read
# variables created in this file's scope (that scope is gone when they run).
@{
  Name         = 'entry-actions'
  Description  = 'Inspect an entry (kind, size, target parts, sniffed format) and open links, paths and file lists'
  CommandOrder = @('kind', 'kinds', 'open')
  CommandHelp  = @{
    'kind'  = 'analyse entry N: kind, size, target parts and sniffed formats'
    'kinds' = 'count the entries per kind across the whole history'
    'open'  = 'open entry N (http link, file path or file list)'
  }
  # one classifier shared by every scriptblock in this file
  KindOf       = {
    param($payload)
    if ([string]::IsNullOrEmpty($payload)) { return 'empty' }
    if ($payload[0] -eq [char]1) { return 'files' }
    $head = $payload
    if ($head.Length -gt 2048) { $head = $head.Substring(0, 2048) }
    $t = $head.Trim()
    if ($t -match '^(https?|ftp|file)://') { return 'link' }
    if ($t -match '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$') { return 'mail' }
    if ($t -match '^[A-Za-z]:\\' -or $t.StartsWith('\\')) { return 'path' }
    if ($t.StartsWith('{') -or $t.StartsWith('[') -or $t.IndexOf(';') -ge 0 -or $t.IndexOf('{') -ge 0 -or $t -match '^(function|class|def|import|using|#include|const|let|var|public|private|package|select)\s') { return 'code' }
    if ($payload.IndexOf([char]10) -ge 0) { return 'multi' }
    return 'text'
  }
  # ------------------------------------------------------------- shared behaviour
  # Which rows this plugin can act on, and the action itself. The context menu entry and
  # the Ctrl+O key both call these, so the rule and the behaviour exist exactly once.
  CanOpen      = {
    param($rec)
    if ($null -eq $rec) { return $false }
    $k = [string](& (Get-PluginData 'entry-actions' 'KindOf') ([string]$rec.Payload))
    return ($k -eq 'link' -or $k -eq 'path' -or $k -eq 'files')
  }
  OpenPayload  = {
    param($payload)
    $target = [string]$payload
    $kind = [string](& (Get-PluginData 'entry-actions' 'KindOf') $target)
    if ($target.Length -gt 0 -and $target[0] -eq [char]1) {
      $parts = @($target.Substring(1) -split "`n" | Where-Object { $_ })
      if ($parts.Count -eq 0) { throw 'nothing to open' }
      $target = $parts[0]
      $kind = 'files'
    }
    $target = $target.Trim()
    if ($kind -eq 'link') {
      $browser = Get-PluginSetting 'entry-actions' 'Browser'
      if ($browser) { Start-Process $browser @($target) } else { Start-Process $target }
    } elseif (($kind -eq 'path' -or $kind -eq 'files') -and (Get-PluginSetting 'entry-actions' 'Reveal') -eq '1') {
      Start-Process 'explorer.exe' @('/select,"' + $target + '"')
    } else {
      Start-Process $target
    }
    return $target
  }
  # param($sample) -> flavour strings; entry-actions.Detect decides which sniffers run,
  # a hit is additive and an unknown name in the list is simply skipped
  Sniff        = {
    param([string]$sample)
    $out = @()
    if (-not $sample) { return $out }
    $want = @((Get-PluginSetting 'entry-actions' 'Detect') -split '[,;]' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    if (($want -contains 'json') -and ($sample.StartsWith('{') -or $sample.StartsWith('['))) {
      $ok = $false
      try { [void]($sample | ConvertFrom-Json); $ok = $true } catch { }
      if ($ok) { $out += 'json' } else { $out += 'json-like (invalid)' }
    }
    if (($want -contains 'xml') -and $sample.StartsWith('<')) {
      $ok = $false
      try { [void][xml]$sample; $ok = $true } catch { }
      if ($ok) { $out += 'xml' } else { $out += 'markup-like (invalid)' }
    }
    if (($want -contains 'yaml') -and ($sample -match '(?m)^[A-Za-z0-9_.-]+:\s*\S') -and -not ($sample -match '[{}]')) {
      $out += 'yaml-like'
    }
    if ($want -contains 'color') {
      if ($sample -match '^#?(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{3}|[0-9A-Fa-f]{8})$') {
        $hex = $sample.TrimStart('#')
        $out += ('colour #' + $hex.ToUpper())
        if ($hex.Length -eq 6) {
          $r = [Convert]::ToInt32($hex.Substring(0, 2), 16)
          $g = [Convert]::ToInt32($hex.Substring(2, 2), 16)
          $b = [Convert]::ToInt32($hex.Substring(4, 2), 16)
          $out += ('rgb(' + $r + ',' + $g + ',' + $b + ')')
        }
      }
    }
    if (($want -contains 'base64') -and $sample -match '^[A-Za-z0-9+/]+={0,2}$' -and $sample.Length -ge 16 -and ($sample.Length % 4) -eq 0) {
      try {
        $bytes = [Convert]::FromBase64String($sample)
        $out += ('base64 ' + $bytes.Length + ' bytes')
      } catch { }
    }
    if (($want -contains 'ip') -and ($sample -match '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')) {
      if (([int]$matches[1] -le 255) -and ([int]$matches[2] -le 255) -and ([int]$matches[3] -le 255) -and ([int]$matches[4] -le 255)) {
        $out += 'ipv4'
      }
    }
    if (($want -contains 'uuid') -and ($sample -match '^\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?$')) {
      $out += 'uuid'
    }
    if (($want -contains 'number') -and ($sample -match '^-?\d{1,3}(,\d{3})*(\.\d+)?$')) {
      $out += ('number ' + $sample.Replace(',', ''))
    }
    if (($want -contains 'version') -and ($sample -match '^v?\d+\.\d+(\.\d+)*$')) {
      $out += 'version'
    }
    if (($want -contains 'date') -and ($sample -match '^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?)?')) {
      $out += 'date'
    }
    if ($want -contains 'hash') {
      if ($sample -match '^[0-9A-Fa-f]{32}$') { $out += 'hash md5' }
      elseif ($sample -match '^[0-9A-Fa-f]{40}$') { $out += 'hash sha1' }
      elseif ($sample -match '^[0-9A-Fa-f]{64}$') { $out += 'hash sha256' }
    }
    return $out
  }
  Settings     = [ordered]@{
    Detail       = @{ Kind = 'enum'; Options = @('short', 'full'); Default = 'full'; Desc = 'kind: short = one summary line, full = the whole block' }
    PreviewChars = @{ Kind = 'int'; Min = 20; Max = 400; Default = 100; Desc = 'kind: characters of the entry shown in the preview' }
    Detect       = @{ Kind = 'list'; Default = 'json,xml,yaml,base64,color,ip,uuid,number,version,date,hash'; Desc = 'kind: formats to sniff, comma separated' }
    ShowTargets  = @{ Kind = 'bool'; Default = 1; Desc = 'kind: 1 = break links, mail, paths and file lists into their parts' }
    Browser      = @{ Kind = 'string'; Default = ''; Desc = 'open: browser exe for http(s) links, empty = system default' }
    Reveal       = @{ Kind = 'bool'; Default = 1; Desc = 'open: 1 = reveal a picked file in Explorer instead of running it' }
  }
  Commands     = @{
    'open' = {
      param($value)
      $i = 0
      if (-not [int]::TryParse([string]$value, [ref]$i)) { Write-Host 'usage: clipboard open 3'; return }
      $recs = @(Get-Records)
      if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; return }
      try {
        [void](& (Get-PluginData 'entry-actions' 'OpenPayload') ([string]$recs[$i - 1].Payload))
        Write-Host ('opened: ' + (Format-Item $recs[$i - 1].Payload 60))
      } catch {
        Write-Log ('entry-actions open failed: ' + $_.Exception.Message)
        Write-Host ('[x] cannot open: ' + $_.Exception.Message)
      }
    }
    'kind' = {
      param($value)
      $i = 0
      if (-not [int]::TryParse([string]$value, [ref]$i)) {
        Write-Host 'usage: clipboard kind 3        clipboard kinds  (the whole history)'
        return
      }
      $recs = @(Get-Records)
      if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; return }
      $rec = $recs[$i - 1]
      $raw = [string]$rec.Payload
      $kind = [string](& (Get-PluginData 'entry-actions' 'KindOf') $raw)

      $detail = Get-PluginSetting 'entry-actions' 'Detail'
      if (-not $detail) { $detail = 'full' }
      $prevN = 0
      if (-not [int]::TryParse((Get-PluginSetting 'entry-actions' 'PreviewChars'), [ref]$prevN)) { $prevN = 100 }
      if ($prevN -lt 20) { $prevN = 20 }
      $showTargets = ((Get-PluginSetting 'entry-actions' 'ShowTargets') -eq '1')

      # a file-list payload starts with char 1 and keeps one path per line
      $isFiles = ($raw.Length -gt 0 -and $raw[0] -eq [char]1)
      $names = @()
      $body = $raw
      if ($isFiles) {
        $names = @($raw.Substring(1) -split "`n" | Where-Object { $_ })
        $body = ($names -join ' ')
      }
      $chars = $raw.Length
      $lines = 1
      if (-not $isFiles -and $raw.Length -gt 0) { $lines = ([regex]::Matches($raw, "`n")).Count + 1 }
      $trimmed = $body.Trim()
      $words = 0
      if ($trimmed) { $words = @($trimmed -split '\s+' | Where-Object { $_ }).Count }

      # ---------------------------------------------------------------- target parts
      $target = ''
      if ($showTargets) {
        if ($kind -eq 'link') {
          try {
            $u = New-Object System.Uri($trimmed)
            $target = $u.Scheme + '   ' + $u.Host
            if ($u.AbsolutePath -and $u.AbsolutePath -ne '/') { $target = $target + '   ' + $u.AbsolutePath }
            if ($u.Query) { $target = $target + '   ?' + ($u.Query.TrimStart('?')) }
          } catch { $target = '(not a parsable url)' }
        } elseif ($kind -eq 'mail') {
          $at = $trimmed.IndexOf('@')
          if ($at -gt 0) { $target = 'user ' + $trimmed.Substring(0, $at) + '   domain ' + $trimmed.Substring($at + 1) }
        } elseif ($kind -eq 'path') {
          $leaf = ''
          $dir = ''
          $ext = ''
          try { $leaf = [IO.Path]::GetFileName($trimmed) } catch { }
          try { $ext = [IO.Path]::GetExtension($trimmed) } catch { }
          try { $dir = [IO.Path]::GetDirectoryName($trimmed) } catch { }
          $target = 'name ' + $leaf
          if ($ext) { $target = $target + '   ext ' + $ext }
          if ($dir) { $target = $target + '   in ' + $dir }
          if (Test-Path -LiteralPath $trimmed) { $target = $target + '   (exists)' } else { $target = $target + '   (not found)' }
        } elseif ($kind -eq 'files') {
          $shown = @($names | Select-Object -First 5 | ForEach-Object { [IO.Path]::GetFileName($_) })
          $target = $names.Count.ToString() + ' file(s): ' + ($shown -join ', ')
          if ($names.Count -gt 5) { $target = $target + ' ...' }
        } elseif ($kind -eq 'code') {
          $lang = 'unknown syntax'
          if ($trimmed -match '(?m)^#include') { $lang = 'c / c++' }
          elseif ($trimmed -match '(?m)^using\s+System') { $lang = 'c#' }
          elseif ($trimmed -match '(?m)^\s*(def|import|from)\s+\w') { $lang = 'python' }
          elseif ($trimmed -match '(?m)^\s*(function|param\s*\(|\$\w+\s*=)') { $lang = 'powershell' }
          elseif ($trimmed -match '(?m)^\s*(const|let|var)\s+\w') { $lang = 'javascript' }
          elseif ($trimmed -match '(?m)^\s*package\s+\w') { $lang = 'java / go' }
          elseif ($trimmed -match '(?m)^\s*(select|insert|update|delete)\s') { $lang = 'sql' }
          $target = 'looks like ' + $lang
        }
      }

      # ------------------------------------------------------------- format sniffers
      $flavours = @()
      if (-not $isFiles) {
        $sample = $trimmed
        if ($sample.Length -gt 8000) { $sample = $sample.Substring(0, 8000) }
        $flavours = @(& (Get-PluginData 'entry-actions' 'Sniff') $sample)
      }

      $pv = Get-ItemLabel $raw $true
      if ($pv.Length -gt $prevN) { $pv = $pv.Substring(0, $prevN) + '...' }

      if ($detail -eq 'short') {
        Write-Host ('entry ' + $i + '   ' + $kind + '   ' + $chars + ' chars / ' + $lines + ' line(s) / ' + $words + ' word(s)   ' + $pv)
        return
      }

      $age = [string](Get-RelTime $rec.Time)
      if (-not $age) { $age = '-' }
      Write-Host ('entry ' + $i + '   kind ' + $kind)
      Write-Host ('  {0,-8}: {1} chars   {2} line(s)   {3} word(s)' -f 'size', $chars, $lines, $words)
      if ($showTargets) {
        if ($target) { Write-Host ('  {0,-8}: {1}' -f 'target', $target) }
      }
      $fmt = '(none)'
      if ($flavours.Count -gt 0) { $fmt = ($flavours -join ', ') }
      Write-Host ('  {0,-8}: {1}' -f 'format', $fmt)
      $flags = @(Get-RecordMarkWords $rec)
      if ($flags.Count -eq 0) { $flags += 'plain' }
      if ($age) { $flags += ('age ' + $age) }
      Write-Host ('  {0,-8}: {1}' -f 'state', ($flags -join ', '))
      Write-Host ('  {0,-8}: {1}' -f 'preview', $pv)
    }
    'kinds' = {
      param($value)
      $recs = @(Get-Records)
      if ($recs.Count -eq 0) { Write-Host '(history is empty)'; return }
      $order = @('link', 'mail', 'path', 'files', 'code', 'multi', 'text', 'empty')
      $counts = @{}
      foreach ($k in $order) { $counts[$k] = 0 }
      $chars = 0
      foreach ($r in $recs) {
        $k = [string](& (Get-PluginData 'entry-actions' 'KindOf') ([string]$r.Payload))
        if (-not $counts.ContainsKey($k)) { $counts[$k] = 0 }
        $counts[$k] = [int]$counts[$k] + 1
        $chars = $chars + ([string]$r.Payload).Length
      }
      Write-Host ('kinds in ' + $recs.Count + ' entries:')
      foreach ($k in $order) {
        if ([int]$counts[$k] -le 0) { continue }
        $pct = [int][Math]::Round((100.0 * [int]$counts[$k]) / $recs.Count)
        Write-Host ('  {0,-6} {1,4}   {2,3}%' -f $k, [int]$counts[$k], $pct)
      }
      foreach ($k in $counts.Keys) {
        if ($order -contains $k) { continue }
        if ([int]$counts[$k] -le 0) { continue }
        Write-Host ('  {0,-6} {1,4}' -f $k, [int]$counts[$k])
      }
      Write-Host ('  ' + ((@(Get-MarkCountWords $recs) + ('chars ' + $chars)) -join '   '))
    }
  }
  # Rows this plugin can act on: a link, a path or a file list. Shared by the context menu
  # entry and the Ctrl+O panel key, so both apply exactly the same rule.
  ContextMenu  = @(
    @{
      Label  = 'Open link or path'
      Test   = { param($rec) [bool](& (Get-PluginData 'entry-actions' 'CanOpen') $rec) }
      Invoke = { param($rec) if ($null -ne $rec) { [void](& (Get-PluginData 'entry-actions' 'OpenPayload') ([string]$rec.Payload)) } }
    }
  )
  PanelKeys    = @(
    @{
      Key    = 'O'
      Ctrl   = $true
      Label  = 'open link or path'
      Test   = { param($rec) [bool](& (Get-PluginData 'entry-actions' 'CanOpen') $rec) }
      Invoke = { param($rec) if ($null -ne $rec) { [void](& (Get-PluginData 'entry-actions' 'OpenPayload') ([string]$rec.Payload)) } }
    }
  )
}

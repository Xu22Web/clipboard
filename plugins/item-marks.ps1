# item-marks - pin, star and highlight an entry.
#
#   pin        float the entry, keep it out of the size trim        pin / unpin, Ctrl+P
#   star       survive clear and trimming, unstar before delete     star / unstar, Ctrl+S
#   highlight  paint the row text and its background                highlight / unhighlight, Ctrl+H
#
# The three coexist: one row can be pinned, starred and highlighted at the same time.
# Only the star is protected, so only it blocks a delete, a trim or a clear.
# The leading bar in the picker is the selection indicator, so no mark here draws it.
#
# Everything the base needs is declared below: the three marks, which one sorts first and
# which one `clear` keeps. The base stores the characters and asks this file for the rest.
#
# ThemeSettings -> themes\<name>.ini  [item-marks]  (not ini keys of clipboard.ini)
#
# Scriptblocks must be self-contained: they may call base helpers, but must not read
# variables created in this file's scope (that scope is gone when they run).
@{
  Name          = 'item-marks'
  Description   = 'Pin, star and highlight entries: the verbs, the keys and the row styling'
  Marks         = [ordered]@{
    p = @{ Set = 'pin'; Unset = 'unpin'; Word = 'pinned'; Hint = 'Ctrl+P'; Protected = $false }
    s = @{ Set = 'star'; Unset = 'unstar'; Word = 'starred'; Hint = 'Ctrl+S'; Protected = $true }
    h = @{ Set = 'highlight'; Unset = 'unhighlight'; Word = 'highlighted'; Hint = 'Ctrl+H'; Protected = $false }
  }
  SortMark      = 'p'
  ClearKeeps    = {
    if ((Get-PluginSetting 'item-marks' 'ClearKeepsPinned') -eq '1') { @('p') } else { @() }
  }
  CommandOrder  = @('pin', 'unpin', 'star', 'unstar', 'highlight', 'unhighlight', 'marks')
  CommandHelp   = @{
    'pin'         = 'pin entry N to the top (clear keeps it unless -All)'
    'unpin'       = 'remove the pin from entry N'
    'star'        = 'favourite entry N: clear and trimming never remove it'
    'unstar'      = 'remove the favourite flag so the entry can be deleted'
    'highlight'   = 'highlight entry N: text and background take the highlight colours'
    'unhighlight' = 'remove the highlight from entry N'
    'marks'       = 'show the colours and glyph this plugin paints with'
  }
  Settings      = [ordered]@{
    MaxPins          = @{ Kind = 'int'; Min = 0; Max = 1000; Default = 50; Desc = 'pinned entry cap, 0 = unlimited' }
    ClearKeepsPinned = @{ Kind = 'bool'; Default = 1; Desc = '1 = clear keeps pinned rows, 0 = clear wipes them too' }
    # the row highlight is a plugin setting of its own; left empty it follows the theme's
    # [item-marks] section, which stays an independent, theme-side default
    HighlightColor   = @{ Kind = 'color'; Default = ''; Desc = 'highlight ink; empty = the theme [item-marks] EmphasisInk' }
    HighlightBg      = @{ Kind = 'color'; Default = ''; Desc = 'highlight fill; empty = the theme [item-marks] EmphasisFill' }
  }
  ThemeSettings = [ordered]@{
    StarGlyph      = @{ Kind = 'string'; Default = [string][char]0xE735; Desc = 'glyph shown for a starred entry' }
    StarColor      = @{ Kind = 'color'; Default = '#FFC86E'; Desc = 'colour of the star mark' }
    PinColor       = @{ Kind = 'color'; Default = ''; Desc = 'colour of the pin mark, empty = theme Mark colour' }
    EmphasisInk    = @{ Kind = 'color'; Default = '#9FDDFF'; Desc = 'ink of an emphasised row (an ini key may override it)' }
    EmphasisFill   = @{ Kind = 'color'; Default = '#3360CDFF'; Desc = 'fill of an emphasised row (an ini key may override it)' }
  }
  # effective highlight colours: the ini key wins, an empty one follows the theme
  HighlightInk  = {
    $v = [string](Get-PluginSetting 'item-marks' 'HighlightColor')
    if (-not $v) { $v = [string](Get-PluginTheme 'item-marks' 'EmphasisInk') }
    return $v
  }
  HighlightFill = {
    $v = [string](Get-PluginSetting 'item-marks' 'HighlightBg')
    if (-not $v) { $v = [string](Get-PluginTheme 'item-marks' 'EmphasisFill') }
    return $v
  }
  # the pin cap spans several rows, so it runs as one pass over the whole record list
  TrimPins      = {
    $cap = [int](Get-PluginSetting 'item-marks' 'MaxPins')
    if ($cap -le 0) { return }
    # GetNewClosure keeps $cap visible inside the block Update-Records runs
    $body = {
      param($list)
      $count = 0
      foreach ($r in $list) { if (Test-Mark $r 'p') { $count++ } }
      if ($count -le $cap) { return }
      # the newest pin sits on top, so dropping from the end drops the oldest first
      for ($i = $list.Count - 1; $i -ge 0 -and $count -gt $cap; $i--) {
        if (Test-Mark $list[$i] 'p') { [void](Set-RecordMark $list[$i] 'p' $false); $count-- }
      }
      Write-Log ('pin cap applied, kept ' + $cap)
    }.GetNewClosure()
    Update-Records $body
  }
  Commands      = @{
    'pin' = {
      param($value)
      $i = 0
      if (-not [int]::TryParse([string]$value, [ref]$i)) { Write-Host 'usage: clipboard pin 3'; return }
      $recs = @(Get-Records)
      if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; return }
      if (Set-Mark $recs[$i - 1].Payload 'p' $true) {
        & (Get-PluginData 'item-marks' 'TrimPins')
        Write-Host ('pinned: ' + (Format-Item $recs[$i - 1].Payload 60))
      } else { Write-Host 'already pinned' }
    }
    'unpin' = {
      param($value)
      $i = 0
      if (-not [int]::TryParse([string]$value, [ref]$i)) { Write-Host 'usage: clipboard unpin 3'; return }
      $recs = @(Get-Records)
      if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; return }
      if (Set-Mark $recs[$i - 1].Payload 'p' $false) { Write-Host ('unpinned: ' + (Format-Item $recs[$i - 1].Payload 60)) }
      else { Write-Host 'not pinned' }
    }
    'star' = {
      param($value)
      $i = 0
      if (-not [int]::TryParse([string]$value, [ref]$i)) { Write-Host 'usage: clipboard star 3'; return }
      $recs = @(Get-Records)
      if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; return }
      if (Set-Mark $recs[$i - 1].Payload 's' $true) { Write-Host ('starred: ' + (Format-Item $recs[$i - 1].Payload 60) + '   clear and trimming keep it') }
      else { Write-Host 'already starred' }
    }
    'unstar' = {
      param($value)
      $i = 0
      if (-not [int]::TryParse([string]$value, [ref]$i)) { Write-Host 'usage: clipboard unstar 3'; return }
      $recs = @(Get-Records)
      if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; return }
      if (Set-Mark $recs[$i - 1].Payload 's' $false) { Write-Host ('unstarred: ' + (Format-Item $recs[$i - 1].Payload 60)) }
      else { Write-Host 'not starred' }
    }
    'highlight' = {
      param($value)
      $i = 0
      if (-not [int]::TryParse([string]$value, [ref]$i)) { Write-Host 'usage: clipboard highlight 3'; return }
      $recs = @(Get-Records)
      if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; return }
      if (Set-Mark $recs[$i - 1].Payload 'h' $true) { Write-Host ('highlighted: ' + (Format-Item $recs[$i - 1].Payload 60)) }
      else { Write-Host 'already highlighted' }
    }
    'unhighlight' = {
      param($value)
      $i = 0
      if (-not [int]::TryParse([string]$value, [ref]$i)) { Write-Host 'usage: clipboard unhighlight 3'; return }
      $recs = @(Get-Records)
      if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; return }
      if (Set-Mark $recs[$i - 1].Payload 'h' $false) { Write-Host ('highlight cleared: ' + (Format-Item $recs[$i - 1].Payload 60)) }
      else { Write-Host 'not highlighted' }
    }
    'marks' = {
      param($value)
      $star = Get-PluginTheme 'item-marks' 'StarGlyph'
      $starColor = Get-PluginTheme 'item-marks' 'StarColor'
      $pinColor = Get-PluginTheme 'item-marks' 'PinColor'
      $ink = [string](& (Get-PluginData 'item-marks' 'HighlightInk'))
      $bg = [string](& (Get-PluginData 'item-marks' 'HighlightFill'))
      # say where the highlight colours come from: the ini key wins, the theme fills in
      $inkSrc = $(if ((Get-PluginSetting 'item-marks' 'HighlightColor')) { 'ini' } else { 'theme' })
      $bgSrc = $(if ((Get-PluginSetting 'item-marks' 'HighlightBg')) { 'ini' } else { 'theme' })
      # code points, not the glyphs themselves: a console without the icon font shows
      # boxes, and this command exists to be read in a console
      $starCode = $(if ($star) { 'U+' + ([int][char]$star).ToString('X4') } else { '(none)' })
      $pinFont = $(if ((Get-IconGlyph 0xE718) -eq '*') { "plain '*'" } else { 'icon font' })
      Write-Host ('pin glyph     : U+E718   ' + $pinFont + '   colour ' + $(if ($pinColor) { $pinColor } else { '(theme mark)' }))
      Write-Host ('star glyph    : ' + $starCode + '   colour ' + $(if ($starColor) { $starColor } else { '(theme mark)' }))
      Write-Host ('highlight ink : ' + $(if ($ink) { $ink } else { '(none)' }) + '   (' + $inkSrc + ')')
      Write-Host ('highlight bg  : ' + $(if ($bg) { $bg } else { '(none)' }) + '   (' + $bgSrc + ')')
      Write-Host 'selection bar : theme accent (the row you are on, not a mark)'
    }
  }
  ContextMenu   = @(
    @{
      Label  = { param($rec) if ($rec -and (Test-Mark $rec 'p')) { 'Remove pin' } else { 'Pin to top' } }
      Key    = 'Ctrl+P'
      Test   = { param($rec) $null -ne $rec }
      Invoke = {
        param($rec)
        if ($null -eq $rec) { return }
        [void](Set-Mark ([string]$rec.Payload) 'p' (-not (Test-Mark $rec 'p')))
        & (Get-PluginData 'item-marks' 'TrimPins')
      }
    }
    @{
      Label  = { param($rec) if ($rec -and (Test-Mark $rec 's')) { 'Remove star' } else { 'Star' } }
      Key    = 'Ctrl+S'
      Test   = { param($rec) $null -ne $rec }
      Invoke = {
        param($rec)
        if ($null -eq $rec) { return }
        [void](Set-Mark ([string]$rec.Payload) 's' (-not (Test-Mark $rec 's')))
      }
    }
    @{
      Label  = { param($rec) if ($rec -and (Test-Mark $rec 'h')) { 'Clear highlight' } else { 'Highlight' } }
      Key    = 'Ctrl+H'
      Test   = { param($rec) $null -ne $rec }
      Invoke = {
        param($rec)
        if ($null -eq $rec) { return }
        [void](Set-Mark ([string]$rec.Payload) 'h' (-not (Test-Mark $rec 'h')))
      }
    }
  )
  PanelKeys     = @(
    @{
      Key    = 'P'
      Ctrl   = $true
      Label  = 'pin / unpin'
      Hint   = 'Pin'
      Test   = { param($rec) $null -ne $rec }
      Invoke = {
        param($rec)
        if ($null -eq $rec) { return }
        [void](Set-Mark ([string]$rec.Payload) 'p' (-not (Test-Mark $rec 'p')))
        & (Get-PluginData 'item-marks' 'TrimPins')
      }
    }
    @{
      Key    = 'S'
      Ctrl   = $true
      Label  = 'star / unstar'
      Hint   = 'Star'
      Test   = { param($rec) $null -ne $rec }
      Invoke = {
        param($rec)
        if ($null -eq $rec) { return }
        [void](Set-Mark ([string]$rec.Payload) 's' (-not (Test-Mark $rec 's')))
      }
    }
    @{
      Key    = 'H'
      Ctrl   = $true
      Label  = 'highlight / clear'
      Hint   = 'Mark'
      Test   = { param($rec) $null -ne $rec }
      Invoke = {
        param($rec)
        if ($null -eq $rec) { return }
        [void](Set-Mark ([string]$rec.Payload) 'h' (-not (Test-Mark $rec 'h')))
      }
    }
  )
  # display only: marks become glyphs in the trailing slots, a highlight recolours the row
  # text and background. Nothing here draws the selection indicator.
  RowDecor      = {
    param($rec)
    if ($null -eq $rec) { return $null }
    $d = @{}
    $marks = @()
    if (Test-Mark $rec 'p') {
      $pg = Get-IconGlyph 0xE718
      $pc = Get-PluginTheme 'item-marks' 'PinColor'
      if (-not $pc) { $pc = '' }
      $marks += @{ Glyph = $pg; Color = $pc }
    }
    if (Test-Mark $rec 's') {
      $sg = Get-PluginTheme 'item-marks' 'StarGlyph'
      if (-not $sg) { $sg = [string][char]0xE735 }
      $sc = Get-PluginTheme 'item-marks' 'StarColor'
      if (-not $sc) { $sc = '' }
      $marks += @{ Glyph = $sg; Color = $sc }
    }
    if ($marks.Count -gt 0) { $d['Marks'] = $marks }
    if (Test-Mark $rec 'h') {
      $ink = [string](& (Get-PluginData 'item-marks' 'HighlightInk'))
      if ($ink) { $d['TextColor'] = $ink }
      $bg = [string](& (Get-PluginData 'item-marks' 'HighlightFill'))
      if ($bg) { $d['BackColor'] = $bg }
    }
    if ($d.Count -gt 0) { return $d }
    return $null
  }
}

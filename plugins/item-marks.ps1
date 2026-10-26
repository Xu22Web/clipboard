# item-marks - pin, star and highlight an entry.
#
#   pin        float the entry, keep it out of the size trim        pin / unpin, Ctrl+P
#   star       survive clear and trimming, unstar before delete     star / unstar, Ctrl+S
#   highlight  accent bar on the leading edge of the row             starred, else pinned
#
# The three coexist: a row can be pinned, starred and highlighted at once. The base stores
# the p/s flags and enforces the protection rules; everything visible or typeable is here.
#
# ThemeSettings -> themes\<name>.ini  [item-marks]  (not ini keys of clipboard.ini)
#
# Scriptblocks must be self-contained: they may call base helpers, but must not read
# variables created in this file's scope (that scope is gone when they run).
@{
  Name          = 'item-marks'
  Description   = 'Pin, star and highlight entries: the verbs, the keys and the row marks'
  CommandOrder  = @('pin', 'unpin', 'star', 'unstar', 'marks')
  CommandHelp   = @{
    'pin'    = 'pin entry N to the top (clear keeps it unless -All)'
    'unpin'  = 'remove the pin from entry N'
    'star'   = 'favourite entry N: clear and trimming never remove it'
    'unstar' = 'remove the favourite flag so the entry can be deleted'
    'marks'  = 'show the pin / star / bar styling that is active now'
  }
  Settings      = [ordered]@{
    MaxPins          = @{ Kind = 'int'; Min = 0; Max = 1000; Default = 50; Desc = 'pinned entry cap, 0 = unlimited' }
    ClearKeepsPinned = @{ Kind = 'bool'; Default = 1; Desc = '1 = clear keeps pinned rows, 0 = clear wipes them too' }
  }
  ThemeSettings = [ordered]@{
    StarGlyph      = @{ Kind = 'string'; Default = [string][char]0xE735; Desc = 'glyph shown for a starred entry' }
    StarColor      = @{ Kind = 'color'; Default = '#FFC86E'; Desc = 'colour of the star mark' }
    PinColor       = @{ Kind = 'color'; Default = ''; Desc = 'colour of the pin mark, empty = theme Pin colour' }
    BarColor       = @{ Kind = 'color'; Default = ''; Desc = 'accent bar on starred rows, empty = theme accent' }
    PinnedBarColor = @{ Kind = 'color'; Default = ''; Desc = 'accent bar on pinned rows, empty = theme accent' }
  }
  Commands      = @{
    'pin' = {
      param($value)
      $i = 0
      if (-not [int]::TryParse([string]$value, [ref]$i)) { Write-Host 'usage: clipboard pin 3'; return }
      $recs = @(Get-Records)
      if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; return }
      $cap = [int](Get-PluginSetting 'item-marks' 'MaxPins')
      if (Set-Pin $recs[$i - 1].Payload $true $cap) { Write-Host ('pinned: ' + (Format-Item $recs[$i - 1].Payload 60)) }
      else { Write-Host 'already pinned' }
    }
    'unpin' = {
      param($value)
      $i = 0
      if (-not [int]::TryParse([string]$value, [ref]$i)) { Write-Host 'usage: clipboard unpin 3'; return }
      $recs = @(Get-Records)
      if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; return }
      if (Set-Pin $recs[$i - 1].Payload $false) { Write-Host ('unpinned: ' + (Format-Item $recs[$i - 1].Payload 60)) }
      else { Write-Host 'not pinned' }
    }
    'star' = {
      param($value)
      $i = 0
      if (-not [int]::TryParse([string]$value, [ref]$i)) { Write-Host 'usage: clipboard star 3'; return }
      $recs = @(Get-Records)
      if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; return }
      if (Set-Star $recs[$i - 1].Payload $true) { Write-Host ('starred: ' + (Format-Item $recs[$i - 1].Payload 60) + '   clear and trimming keep it') }
      else { Write-Host 'already starred' }
    }
    'unstar' = {
      param($value)
      $i = 0
      if (-not [int]::TryParse([string]$value, [ref]$i)) { Write-Host 'usage: clipboard unstar 3'; return }
      $recs = @(Get-Records)
      if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; return }
      if (Set-Star $recs[$i - 1].Payload $false) { Write-Host ('unstarred: ' + (Format-Item $recs[$i - 1].Payload 60)) }
      else { Write-Host 'not starred' }
    }
    'marks' = {
      param($value)
      $star = Get-PluginTheme 'item-marks' 'StarGlyph'
      $starColor = Get-PluginTheme 'item-marks' 'StarColor'
      $pinColor = Get-PluginTheme 'item-marks' 'PinColor'
      $barColor = Get-PluginTheme 'item-marks' 'BarColor'
      $pinBarColor = Get-PluginTheme 'item-marks' 'PinnedBarColor'
      Write-Host ('star glyph   : ' + $(if ($star) { $star + '  (U+' + ([int][char]$star).ToString('X4') + ')' } else { '(none)' }))
      Write-Host ('star colour  : ' + $(if ($starColor) { $starColor } else { '(theme pin)' }))
      Write-Host ('pin colour   : ' + $(if ($pinColor) { $pinColor } else { '(theme pin)' }))
      Write-Host ('bar starred  : ' + $(if ($barColor) { $barColor } else { '(theme accent)' }))
      Write-Host ('bar pinned   : ' + $(if ($pinBarColor) { $pinBarColor } else { '(theme accent)' }) + '   (only when the row is not starred)')
    }
  }
  ContextMenu   = @(
    @{
      Label  = { param($rec) if ($rec -and $rec.Pinned) { 'Remove pin' } else { 'Pin to top' } }
      Key    = 'Ctrl+P'
      Test   = { param($rec) $null -ne $rec }
      Invoke = {
        param($rec)
        if ($null -eq $rec) { return }
        [void](Set-Pin ([string]$rec.Payload) (-not [bool]$rec.Pinned) ([int](Get-PluginSetting 'item-marks' 'MaxPins')))
      }
    }
    @{
      Label  = { param($rec) if ($rec -and $rec.Starred) { 'Remove star' } else { 'Star' } }
      Key    = 'Ctrl+S'
      Test   = { param($rec) $null -ne $rec }
      Invoke = {
        param($rec)
        if ($null -eq $rec) { return }
        [void](Set-Star ([string]$rec.Payload) (-not [bool]$rec.Starred))
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
        [void](Set-Pin ([string]$rec.Payload) (-not [bool]$rec.Pinned) ([int](Get-PluginSetting 'item-marks' 'MaxPins')))
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
        [void](Set-Star ([string]$rec.Payload) (-not [bool]$rec.Starred))
      }
    }
  )
  # what `clear` and the tray "Clear history" do with pinned rows
  ClearKeepsPinned = {
    (Get-PluginSetting 'item-marks' 'ClearKeepsPinned') -eq '1'
  }
  RowDecor      = {
    param($rec)
    if ($null -eq $rec) { return $null }
    $d = @{}
    # pin mark colour (the mark itself is drawn by the base for a pinned row)
    if ($rec.Pinned) {
      $pc = Get-PluginTheme 'item-marks' 'PinColor'
      if ($pc) { $d['PinColor'] = $pc }
    }
    # star mark
    if ($rec.Starred) {
      $glyph = Get-PluginTheme 'item-marks' 'StarGlyph'
      if ($glyph) { $d['Mark'] = $glyph }
      $sc = Get-PluginTheme 'item-marks' 'StarColor'
      if ($sc) { $d['MarkColor'] = $sc }
    }
    # accent bar: starred rows first, pinned rows when the row is not starred
    if ($rec.Starred) {
      $d['Emphasis'] = $true
      $bc = Get-PluginTheme 'item-marks' 'BarColor'
      if ($bc) { $d['EmphasisColor'] = $bc }
    } elseif ($rec.Pinned) {
      $d['Emphasis'] = $true
      $bc = Get-PluginTheme 'item-marks' 'PinnedBarColor'
      if ($bc) { $d['EmphasisColor'] = $bc }
    }
    if ($d.Count -gt 0) { return $d }
    return $null
  }
}

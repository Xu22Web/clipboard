# lib/config-template.ps1 - the clipboard.ini this build writes: the commented template, the
# gap-filling merge, and the file reset. Nothing here applies a setting; it only decides what
# the file says. lib/config.ps1 owns the command surface, lib/settings.ps1 owns reading a
# value back.
#
# What a key means and which value it starts with are read from schema\clipboard.ps1, so the
# comment in the file, the `config` listing and the default in `config set` all come from one
# place. What lives here is the layout: the prose at the top, which heading a key sits under,
# and the order of the lines. `config init` (which only fills gaps) and `config reset` (which
# replaces the file) share this one source, so the two can never drift apart.

# The shape of the file a user reads: a heading and the keys under it, in this order. A key
# the schema knows but this table forgets fails loudly below, because `config init` comments
# out whatever the template does not carry, and that would hide the user's value.
$script:IniTemplateLayout = [ordered]@{
  '' = @(
    'DataDir', 'Hotkey', 'HotkeyFallbacks', 'PasteKeys', 'ModReleaseTimeout', 'PasteSettle',
    'MaxTextBytes', 'MaxTextTotalBytes', 'MaxMediaTotalBytes', 'BlobChars',
    'CaptureImages', 'MaxImageBytes', 'CaptureRich', 'MaxHtmlBytes', 'MaxRtfBytes',
    'RtfImagesUpToBytes', 'InlineImageUpToBytes', 'PasteRich', 'PasteFilesAsText', 'PasteTyping',
    'AppRules', 'Interval', 'NoPaste', 'Balloon', 'Theme', 'ExcludePattern'
  )
  'panel geometry (96 dpi baseline, scaled by the system DPI)' = @(
    'WindowWidth', 'Rows', 'WindowLeft', 'WindowTop', 'SaveWindowWidth', 'SaveWindowPos',
    'PlaceNearForeground'
  )
  'panel behaviour' = @(
    'ShowTime', 'ShowTypeIcon', 'ShowThumbnails', 'Highlight', 'HighlightMaxBytes',
    'ShowNewlineMarker', 'PreviewHover', 'PreviewDelay', 'PreviewChars', 'ScrollLines',
    'Animations', 'DpiAware', 'ImeTakeover'
  )
  'history' = @('MaxItems', 'Undo')
  'install' = @('Autostart', 'DesktopShortcut')
  'plugins (see README.md)' = @('Plugins')
}

function Get-IniTemplateLines {
  $t = New-Object System.Collections.Generic.List[string]
  $t.Add('# clipboard.ini - key=value lines, and one [section] per plugin.')
  $t.Add('# Restart the daemon after editing (clipboard stop, clipboard serve), or use config set.')
  $t.Add('# Every key below can also be written with:')
  $t.Add('#   clipboard config set <key> <value>        (plugin keys: config set <plugin>.<Key> <value>)')
  $seen = @{}
  foreach ($heading in @($script:IniTemplateLayout.Keys)) {
    if ($heading) {
      $t.Add('')
      $t.Add('# ---- ' + $heading + ' ----')
    }
    foreach ($key in @($script:IniTemplateLayout[$heading])) {
      if (-not $script:IniSchema.Contains($key)) {
        throw ('the template lists a key the schema does not have: ' + $key)
      }
      $spec = $script:IniSchema[$key]
      if ($spec.Contains('Description') -and [string]$spec['Description']) {
        $t.Add('# ' + [string]$spec['Description'])
      }
      if ($key -eq 'Plugins') {
        $t.Add($key + '=' + (@($script:PluginList) -join ','))
      } else {
        $dv = ''
        if ($spec.Contains('Default')) { $dv = [string]$spec['Default'] }
        $t.Add($key + '=' + $dv)
      }
      $seen[$key.ToLowerInvariant()] = $true
    }
  }
  # every base key the schema knows has to be in the file: config init comments out whatever
  # the template does not carry, so a missing line would turn a user's value into "[unknown]".
  # Dotted names are plugin keys and get their own section below.
  $missing = @()
  foreach ($k in @($script:IniSchema.Keys)) {
    $k = [string]$k
    if ($k.Contains('.')) { continue }
    if (-not $seen.ContainsKey($k.ToLowerInvariant())) { $missing += $k }
  }
  if ($missing.Count -gt 0) { throw ('the template does not cover: ' + ($missing -join ', ')) }
  # Settings declared by every plugin file on disk, loaded or not: the template documents
  # what exists, while help / the plugin commands / the panel follow the resolved Plugins=.
  # A plugin's keys are written as a section of its own - [item-marks] + MaxPins=50 - which
  # is the same key as item-marks.MaxPins=50 for every reader.
  $pset = $null
  if (Get-Command Get-AllPluginSettings -ErrorAction SilentlyContinue) {
    $pset = Get-AllPluginSettings (Join-Path $Root 'schema\plugins')
  }
  if ($null -eq $pset -or $pset.Count -eq 0) { $pset = $script:PluginSettings }
  if ($null -eq $pset) { $pset = @{} }
  $extra = New-Object System.Collections.Generic.List[string]
  foreach ($pname in @($pset.Keys)) {
    $extra.Add('')
    $extra.Add('# ---- plugin: ' + $pname + ' (used when listed in Plugins=) ----')
    $extra.Add('[' + $pname + ']')
    foreach ($full in @($pset[$pname].Keys)) {
      $spec = $pset[$pname][$full]
      $desc = ''
      if ($spec.Contains('Description')) { $desc = [string]$spec['Description'] }
      if ($desc) { $extra.Add('# ' + $desc) }
      $dv = ''
      if ($spec.Contains('Default')) { $dv = [string]$spec['Default'] }
      $leaf = [string]$full
      if ($leaf.StartsWith($pname + '.')) { $leaf = $leaf.Substring($pname.Length + 1) }
      $extra.Add($leaf + '=' + $dv)
    }
  }
  $all = New-Object System.Collections.Generic.List[string]
  foreach ($l in $t) { $all.Add($l) }
  foreach ($l in $extra) { $all.Add($l) }
  # one line per item: the caller wraps this in @() and gets a flat string array
  return $all.ToArray()
}


# `config init`: bring the file in line with this version - add the keys that appeared,
# comment out the ones that no longer exist, and leave every value alone. A value the user
# set - a plugin setting in particular - is never replaced by its default. Returns the two
# counts so the caller can say what happened.
function Merge-IniDefaults {
  Ensure-Dir
  $tpl = @(Get-IniTemplateLines)
  # everything the program can write is "known"; anything else is left over from an older
  # version or a plugin that is gone. The template is read with the same reader as the file, so
  # "[item-marks]" + "MaxPins=50" counts as item-marks.MaxPins here exactly as it does there.
  $known = @{}
  foreach ($k in @((Read-IniDoc $tpl).Keys)) { $known[([string]$k).ToLowerInvariant()] = $true }
  # the file as a document: comments, blank lines and the order of every key stay where they are
  $lines = @()
  if (Test-Path -LiteralPath $IniPath) { $lines = [IO.File]::ReadAllLines($IniPath, [Text.Encoding]::UTF8) }
  $doc = Read-IniDoc $lines
  # a key this version does not know is kept readable but out of the way: removing the '#'
  # brings it back
  $pruned = 0
  foreach ($k in @($doc.Keys)) {
    if ($known.ContainsKey(([string]$k).ToLowerInvariant())) { continue }
    foreach ($n in @($doc.Index[$k].Lines)) {
      $at = [int]$n
      $doc = Set-IniDocLine $doc $at ('# [unknown] ' + ([string]$doc.Lines[$at]).Trim())
      $pruned++
    }
  }
  # comments are buffered so an added key keeps the explanation that introduces it; a
  # section header is buffered with them, so a gap is filled inside its own [section].
  # A section the file already has gets no second header - the key joins the block it has.
  $pending = New-Object System.Collections.Generic.List[string]
  $tplSectionName = ''
  $added = 0
  foreach ($raw in $tpl) {
    $s = [string]$raw
    $tl = $s.Trim()
    if ($tl -eq '' -or $tl.StartsWith('#')) { $pending.Add($s); continue }
    if ($tl -match '^\[(.+)\]$') {
      $tplSectionName = $Matches[1].Trim()
      if ($null -ne (Get-IniDocSection $doc $tplSectionName)) { $pending.Clear(); continue }
      $pending.Add($s)
      continue
    }
    if ($tl -notmatch '^\s*([A-Za-z0-9_.-]+)\s*=') { $pending.Clear(); continue }
    $key = $Matches[1]
    if ($tplSectionName) { $key = $tplSectionName + '.' + $key }
    if (Test-IniDocKey $doc $key) { $pending.Clear(); continue }
    $block = @()
    foreach ($p in $pending) { $block += $p }
    $block += $s
    $sec = $null
    if ($tplSectionName) { $sec = Get-IniDocSection $doc $tplSectionName }
    if ($null -ne $sec) {
      # the section is already in the file: insert after its last line, comments included
      $doc = Insert-IniDocLines $doc ([int]$sec.Last + 1) $block
    } else {
      $cur = @($doc.Lines)
      if ($cur.Count -gt 0 -and $cur[$cur.Count - 1].Trim()) { $doc = Insert-IniDocLines $doc $cur.Count @('') }
      $doc = Insert-IniDocLines $doc @($doc.Lines).Count $block
    }
    $pending.Clear()
    $added++
  }
  if ($added -gt 0 -or $pruned -gt 0 -or -not (Test-Path -LiteralPath $IniPath)) {
    [void](Save-IniDoc $IniPath $doc)
  }
  return @{ Added = $added; Pruned = $pruned }
}


# `config reset`: replace the file with a fresh template. This is the only path that throws
# values away, and it is never reached by accident.
function Write-IniTemplate([switch]$Force) {
  if ((Test-Path -LiteralPath $IniPath) -and (-not $Force)) { return $IniPath }
  Ensure-Dir
  [void](Save-IniLines $IniPath @(Get-IniTemplateLines))
  return $IniPath
}

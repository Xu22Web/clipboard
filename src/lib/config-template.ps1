# lib/config-template.ps1 - the clipboard.ini this build writes: the commented template, the
# file reset, and the one call that fits an existing file to it. Nothing here applies a setting;
# it only decides what the file says. lib/config.ps1 owns the command surface, lib/settings.ps1
# owns reading a value back, and utils/ini.ps1 owns every edit to a parsed file.
#
# What a key means and which value it starts with are read from schema\clipboard.ps1, so the
# comment in the file, the `config` listing and the default in `config set` all come from one
# place. What lives here is the layout: the prose at the top, which heading a key sits under,
# and the order of the lines. `config init` (which fits the file to the template) and
# `config reset` (which replaces the file) share this one source, so the two can never drift
# apart.

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
    'WindowWidth', 'Rows', 'CompactWidth', 'CompactRows',
    'WindowLeft', 'WindowTop', 'SaveWindowPos'
  )
  'panel behaviour' = @(
    'CompactMode', 'ShowTime', 'ShowTypeIcon', 'ShowThumbnails', 'Highlight', 'HighlightMaxBytes',
    'ShowNewlineMarker', 'PreviewHover', 'PreviewDelay', 'PreviewChars', 'ScrollLines',
    'Animations', 'DpiAware'
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


# `config init`: bring the file in line with this version. The template is the shape of the
# file, so the file is written from it - the same headings, the same order, one comment above
# each key - with every value the file already holds. Filling gaps by inserting single keys is
# what left blank lines inside blocks and comments without the key they describe.
#
# A value the user set, a plugin setting in particular, is never replaced. A key this version
# does not know is kept as a comment at the end, where removing the '#' brings it back, so
# nothing is lost and `config init` stays repeatable. Only text that actually changes is
# written. Returns the two counts the caller reports.
#
# What the file should say is Merge-IniDocTemplate's job (utils/ini.ps1); this function owns
# only the file around it: reading it, deciding whether anything changed, and writing it.
function Merge-IniDefaults {
  Ensure-Dir
  $before = @()
  if (Test-Path -LiteralPath $IniPath) {
    $before = [IO.File]::ReadAllLines($IniPath, [Text.Encoding]::UTF8)
  }
  $doc = Read-IniDoc $before
  $next = Merge-IniDocTemplate $doc @(Get-IniTemplateLines)
  if (-not (Test-IniLinesSame $before $next.Lines)) { [void](Save-IniLines $IniPath $next.Lines) }
  return @{ Added = $next.Added; Pruned = $next.Unknown }
}


# `config reset`: replace the file with a fresh template. This is the only path that throws
# values away, and it is never reached by accident.
function Write-IniTemplate([switch]$Force) {
  if ((Test-Path -LiteralPath $IniPath) -and (-not $Force)) { return $IniPath }
  Ensure-Dir
  [void](Save-IniLines $IniPath @(Get-IniTemplateLines))
  return $IniPath
}

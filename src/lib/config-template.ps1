# lib/config-template.ps1 - the clipboard.ini this build writes: the commented template, the
# gap-filling merge, and the file reset. Nothing here applies a setting; it only decides what
# the file says. lib/config.ps1 owns the command surface, lib/settings.ps1 owns reading a
# value back.
#
# The template is hand-written on purpose: the comments say what a key is for in the words a
# user reads, which a generated listing of the schema cannot do. The two paths that write it
# share this one source, so `config init` and `config reset` can never drift apart.

# every line of a fresh clipboard.ini, comments included. Shared by `config init` (which
# only fills gaps) and `config reset` (which replaces the file), so the two can never drift.
function Get-IniTemplateLines {
  $t = @(
    '# clipboard.ini - key=value lines, and one [section] per plugin.',
    '# Restart the daemon after editing (clipboard stop, clipboard serve), or use config set.',
    '# Every key below can also be written with:',
    '#   clipboard config set <key> <value>        (plugin keys: config set <plugin>.<Key> <value>)',
    '# write location, empty = <script dir>\data. relative paths resolve against the script dir.',
    'DataDir=',
    '# Hotkey: key may be A-Z 0-9 F1-F24 Insert Delete Home End PgUp PgDn Space.',
    '# Default is Ctrl+Alt+V. Win+V would be nicer but Windows reserves it on most builds',
    '# (RegisterHotKey fails); the tool then falls back to Alt+` / Win+Shift+V by itself.',
    'Hotkey=Ctrl+Alt+V',
    '# comma separated list tried in order when Hotkey is taken. empty = built-in chain:',
    '# Ctrl+Alt+V, Win+V, Alt+`, Win+Shift+V',
    'HotkeyFallbacks=',
    '# ^v = Ctrl+V | ^+v = Ctrl+Shift+V (terminal) | +{INS} = Shift+Insert (mintty)',
    'PasteKeys=^v',
    '# ms to wait for the modifiers to be released before injecting the paste',
    'ModReleaseTimeout=1200',
    '# ms to wait after focusing the previous window before sending PasteKeys',
    'PasteSettle=80',
    '# entry cap; pinned entries are never trimmed away',
    'MaxItems=300',
    '# per text entry cap in bytes; a larger payload is not saved',
    'MaxTextBytes=204800',
    '# total size of the text entries in bytes; the oldest are dropped beyond it',
    'MaxTextTotalBytes=4194304',
    '# size budget for the image and the html / rtf sidecar files, in bytes (0 = unlimited).',
    '# it is counted apart from MaxTextTotalBytes, so a screenshot cannot evict every text row',
    'MaxMediaTotalBytes=134217728',
    '# 1 = capture pictures (a Word selection carries text, so it stays a formatted entry)',
    'CaptureImages=1',
    '# per image cap in bytes; larger pictures are logged and skipped',
    'MaxImageBytes=16777216',
    '# 1 = remember the html / rtf of formatted text so it can be pasted back',
    'CaptureRich=1',
    '# the html and the rtf are capped apart, so a large rtf cannot cost the html',
    'MaxHtmlBytes=20971520',
    'MaxRtfBytes=20971520',
    '# an rtf above this size is laid out on the card with a marker where each picture was',
    '# (the entry and the paste keep the pictures), 0 = never',
    'RtfImagesUpToBytes=8388608',
    '# a picture the html points at is inlined when it is at most this large, 0 = never',
    'InlineImageUpToBytes=4194304',
    '# 1 = paste the formatting back, 0 = always paste plain text',
    'PasteRich=1',
    '# 1 = a file list also carries its paths as text, so a text box gets something',
    'PasteFilesAsText=1',
    '# per program paste behaviour, e.g. windowsterminal.exe:plain;code.exe:rich;*',
    '# actions: plain / rich / no-paste; one rule per ; separated item',
    'AppRules=',
    '# payloads above this many characters are kept in data\blobs instead of this file,',
    '# 0 = always inline (one self-contained history.dat)',
    'BlobChars=32768',
    '# clipboard poll interval in ms',
    'Interval=300',
    '# 1 = clipboard only, never inject a paste',
    'NoPaste=0',
    '# 1 = tray balloon on startup',
    'Balloon=1',
    '# the theme is a file name in themes\ (win11-dark.ini, win11-light.ini, ...)',
    '# win11-dark is the default; an unknown name falls back to it',
    'Theme=win11-dark',
    '# regex: matching clipboard text is never saved',
    'ExcludePattern=',
    '',
    '# ---- panel geometry (96 dpi baseline, scaled by the system DPI) ----',
    '# width only: the height is derived from Rows and is never set directly',
    'WindowWidth=700',
    '# visible rows; the panel is Rows x 40 + 110 tall and always shows whole rows',
    'Rows=10',
    '# empty = centre the panel on the monitor of the window you came from',
    'WindowLeft=',
    'WindowTop=',
    '# 1 = remember the width you dragged / the position you moved it to',
    'SaveWindowWidth=0',
    'SaveWindowPos=0',
    '',
    '# ---- panel behaviour ----',
    '# 1 = relative time column (now / 5m / 3h / 2d / 10-24)',
    'ShowTime=1',
    '# 1 = show the row icon a plugin provides (there is none without one)',
    'ShowTypeIcon=1',
    '# 1 = show a small picture in the icon slot of a picture or formatted-text row',
    'ShowThumbnails=1',
    '# 1 = highlight the search matches',
    'Highlight=1',
    '# skip the highlight above this payload size in bytes, 0 = always highlight',
    'HighlightMaxBytes=8192',
    '# 1 = show <NL> for line breaks, 0 = collapse them into a single space',
    'ShowNewlineMarker=1',
    '# 1 = hover a row to preview its text beside the panel, 0 = no card at all',
    'PreviewHover=1',
    '# ms the cursor has to rest on a row before the card appears',
    'PreviewDelay=350',
    '# characters of an entry the card reads and shows (the rest is elided)',
    'PreviewChars=6000',
    '# wheel step in rows, 0 = follow the system setting',
    'ScrollLines=0',
    '# 1 = fade / grow transitions on hover, selection, scrollbar and search field, 0 = instant',
    'Animations=1',
    '# 1 = per-monitor DPI aware rendering, 0 = legacy rendering',
    'DpiAware=1',
    '',
    '# ---- history ----',
    '# entry cap, 0 = unlimited',
    'MaxItems=300',
    '# 1 = Ctrl+Z in the panel restores the last deleted entry',
    'Undo=1',
    '',
    '# ---- install ----',
    '# 1 = install creates the logon shortcut that runs serve',
    'Autostart=1',
    '# 1 = install creates the desktop shortcut that runs ui',
    'DesktopShortcut=1',
    '',
    '# ---- plugins (see README.md) ----',
    '# names to load, in load order; the default lists every plugin on disk',
    '# e.g. Plugins=item-marks,entry-actions',
    # the whole expression needs its own parentheses: inside an array literal a bare
    # `-join ','` turns the comma into an element separator and the line comes out empty
    ('Plugins=' + (@($script:PluginList) -join ','))
  )
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
  # version or a plugin that is gone. A key inside a template section counts under the
  # section name, so "[item-marks]" + "MaxPins=50" is the key item-marks.MaxPins.
  $known = @{}
  $tplSection = ''
  foreach ($t in $tpl) {
    if ($t -match '^\s*\[(.+)\]\s*$') { $tplSection = $Matches[1].Trim(); continue }
    if ($t -match '^\s*([A-Za-z0-9_.-]+)\s*=') {
      $name = $Matches[1]
      if ($tplSection) { $name = $tplSection + '.' + $name }
      $known[$name.ToLowerInvariant()] = $true
    }
  }
  $lines = New-Object System.Collections.Generic.List[string]
  $have = @{}
  $haveSections = @{}
  $sectionEnd = @{}
  $pruned = 0
  if (Test-Path -LiteralPath $IniPath) {
    # a key may be written flat or as a leaf inside [section]; both count as that key, and
    # the extent of every section is remembered so a late key can join it in place
    $section = ''
    foreach ($l in [IO.File]::ReadAllLines($IniPath, [Text.Encoding]::UTF8)) {
      if ($l -match '^\s*\[(.+)\]\s*$') {
        $section = $Matches[1].Trim()
        $lines.Add($l)
        $haveSections[$section.ToLowerInvariant()] = $true
        $sectionEnd[$section.ToLowerInvariant()] = $lines.Count - 1
        continue
      }
      if ($l -match '^\s*([A-Za-z0-9_.-]+)\s*=') {
        $name = $Matches[1]
        if ($section) { $name = $section + '.' + $name }
        $name = $name.ToLowerInvariant()
        if (-not $known.ContainsKey($name)) {
          # keep the value readable, but out of the way: a removed '#' brings it back
          $lines.Add('# [unknown] ' + $l.Trim())
          $pruned++
          continue
        }
        $lines.Add($l)
        $have[$name] = $true
        if ($section) { $sectionEnd[$section.ToLowerInvariant()] = $lines.Count - 1 }
        continue
      }
      $lines.Add($l)
      if ($section -and $l.Trim()) { $sectionEnd[$section.ToLowerInvariant()] = $lines.Count - 1 }
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
      $tplSectionName = $Matches[1].Trim().ToLowerInvariant()
      if ($haveSections.ContainsKey($tplSectionName)) { $pending.Clear(); continue }
      $pending.Add($s)
      continue
    }
    if ($tl -notmatch '^\s*([A-Za-z0-9_.-]+)\s*=') { $pending.Clear(); continue }
    $k = $Matches[1].ToLowerInvariant()
    if ($tplSectionName) { $k = $tplSectionName + '.' + $k }
    if ($have.ContainsKey($k)) { $pending.Clear(); continue }
    if ($tplSectionName -and $haveSections.ContainsKey($tplSectionName)) {
      # the section is already in the file: insert after its last line and keep the indices
      $at = [int]$sectionEnd[$tplSectionName] + 1
      $lines.Insert($at, $s)
      foreach ($sec in @($sectionEnd.Keys)) {
        if ([int]$sectionEnd[$sec] -ge $at) { $sectionEnd[$sec] = [int]$sectionEnd[$sec] + 1 }
      }
      $sectionEnd[$tplSectionName] = $at
      $pending.Clear()
      $have[$k] = $true
      $added++
      continue
    }
    if ($lines.Count -gt 0 -and $pending.Count -gt 0) { $lines.Add('') }
    foreach ($p in $pending) { $lines.Add($p) }
    $lines.Add($s)
    $pending.Clear()
    $have[$k] = $true
    $added++
  }
  if ($added -gt 0 -or $pruned -gt 0 -or -not (Test-Path -LiteralPath $IniPath)) {
    [IO.File]::WriteAllText($IniPath, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), $Utf8)
  }
  return @{ Added = $added; Pruned = $pruned }
}


# `config reset`: replace the file with a fresh template. This is the only path that throws
# values away, and it is never reached by accident.
function Write-IniTemplate([switch]$Force) {
  if ((Test-Path -LiteralPath $IniPath) -and (-not $Force)) { return $IniPath }
  Ensure-Dir
  $all = @(Get-IniTemplateLines)
  [IO.File]::WriteAllText($IniPath, (($all -join [Environment]::NewLine) + [Environment]::NewLine), $Utf8)
  return $IniPath
}

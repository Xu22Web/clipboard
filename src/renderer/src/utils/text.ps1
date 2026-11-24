# renderer/src/utils/text.ps1 - the words the tool draws, one file per language in lang\.
#
# A language file is an ini file next to the tool: [meta] names the language and the font family
# it needs, and every other section carries one surface's words. The keys are the identity - a
# schema key, a group name, a unit, a plugin name - so nothing a language adds is ever stored in
# clipboard.ini, and a key renamed in code breaks the same lookup in every language at once.
#
# en.ini is the base: it is read first and the chosen language is laid over it, so a line a
# translation has not reached yet still reads as English instead of disappearing. A key no file
# carries is returned as itself and logged once, which makes a missing translation visible
# without a blank row or an exception in a paint path.
#
# The words are resolved once per process and cached, formatted only when asked for, so a paint
# path does one dictionary lookup and no file read. Changing Language re-runs Initialize-Text;
# the panel window rebuilds its fonts on the same call (a language may name its own family).

$script:TextMap = @{}       # 'section.key' -> words (base, then the chosen language over it)
$script:TextMeta = @{}      # code / name / font of the language in use
$script:TextCode = ''
$script:TextReady = $false   # the files have been read for this process
$script:TextMissing = @{}   # keys already reported, so the log holds one line per key

# Reading is deferred to the first lookup so every entry point gets words: a command line run
# through Apply-Config, and a dot-sourced library that never applies a config at all (the tests
# and the screenshot tool build menus directly).
function Initialize-TextLoaded {
  if ($script:TextReady) { return }
  $code = ''
  if (Get-Variable -Name Language -Scope Script -ErrorAction SilentlyContinue) { $code = [string]$script:Language }
  [void](Initialize-Text $code)
}

function Get-TextDir { return (Join-Path $Root 'lang') }

# One language file as two tables: Map holds 'section.key' -> words, Meta holds [meta] -> words.
function Read-TextFile([string]$code) {
  if (-not $code) { return $null }
  $path = Join-Path (Get-TextDir) ($code + '.ini')
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    $doc = Read-IniDoc ([IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8))
  } catch {
    Write-Log ('language file not readable: ' + $path + ' - ' + $_.Exception.Message)
    return $null
  }
  $map = @{}
  $meta = @{}
  foreach ($k in @($doc.Map.Keys)) {
    $name = [string]$k
    $dot = $name.IndexOf('.')
    if ($dot -lt 1) { continue }
    $group = $name.Substring(0, $dot).ToLowerInvariant()
    if ($group -eq 'meta') { $meta[$name.Substring($dot + 1)] = [string]$doc.Map[$k]; continue }
    $map[$name] = [string]$doc.Map[$k]
  }
  return @{ Map = $map; Meta = $meta }
}

# The languages on disk, en first: the code is the file name, the name is [meta] name. Scanning
# the folder means a new translation is one file and no code change; the schema lists the codes
# the window offers, and a test holds the two together.
function Get-LanguageList {
  $out = New-Object System.Collections.Generic.List[object]
  $dir = Get-TextDir
  if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return $out.ToArray() }
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.ini' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $code = $f.BaseName
    $name = $code
    $t = Read-TextFile $code
    if ($null -ne $t -and $t.Meta.ContainsKey('name') -and [string]$t.Meta['name']) { $name = [string]$t.Meta['name'] }
    $out.Add([pscustomobject]@{ Code = $code; Name = $name })
  }
  # en is the base file, so it leads the list; the rest keep the folder order
  $en = @($out | Where-Object { $_.Code -eq 'en' })
  $rest = @($out | Where-Object { $_.Code -ne 'en' })
  return @($en + $rest)
}

# Load the base and lay the chosen language over it. An unknown or unreadable code keeps the
# base, so a language file deleted by hand leaves an English window instead of an empty one.
function Initialize-Text([string]$code = '') {
  $script:TextMap = @{}
  $script:TextMeta = @{}
  $script:TextMissing = @{}
  $script:TextReady = $true
  $base = Read-TextFile 'en'
  if ($null -ne $base) {
    foreach ($k in @($base.Map.Keys)) { $script:TextMap[$k] = [string]$base.Map[$k] }
    foreach ($k in @($base.Meta.Keys)) { $script:TextMeta[$k] = [string]$base.Meta[$k] }
  }
  $want = ([string]$code).Trim()
  if (-not $want) { $want = 'en' }
  $over = $null
  if ($want -ne 'en') { $over = Read-TextFile $want }
  if ($null -ne $over) {
    foreach ($k in @($over.Map.Keys)) { $script:TextMap[$k] = [string]$over.Map[$k] }
    foreach ($k in @($over.Meta.Keys)) { $script:TextMeta[$k] = [string]$over.Meta[$k] }
  } elseif ($want -ne 'en') {
    Write-Log ('language not found: ' + $want + ' - keeping en')
    $want = 'en'
  }
  if (-not $script:TextMeta.ContainsKey('code') -or -not [string]$script:TextMeta['code']) { $script:TextMeta['code'] = $want }
  $script:TextCode = [string]$script:TextMeta['code']
  return $script:TextCode
}

# The words for one key. $Args fills {0}, {1} ...; a key no file carries comes back as itself, so
# a missing translation reads as an unfinished key rather than as an empty control.
function Get-UiText([string]$key, [object[]]$Values = @()) {
  if (-not $key) { return '' }
  Initialize-TextLoaded
  if (-not $script:TextMap.ContainsKey($key)) {
    if (-not $script:TextMissing.ContainsKey($key)) {
      $script:TextMissing[$key] = $true
      Write-Log ('text missing: ' + $key)
    }
    return $key
  }
  $s = [string]$script:TextMap[$key]
  if ($null -eq $Values -or @($Values).Count -eq 0) { return $s }
  try { return ([string]::Format($s, $Values)) } catch { return $s }
}

# A key with a word to fall back on instead of the key itself - a plugin names its own caption in
# the language files, and a plugin that has none keeps the name it declares.
function Get-UiTextOr([string]$key, [string]$Fallback) {
  Initialize-TextLoaded
  if ($key -and $script:TextMap.ContainsKey($key)) { return (Get-UiText $key) }
  return $Fallback
}

# One count, in the form the language uses: a language with a separate singular writes .one and
# .other, one without writes .other alone and the lookup falls back to it.
function Get-UiTextCount([string]$key, [int]$n) {
  Initialize-TextLoaded
  if ($n -eq 1 -and $script:TextMap.ContainsKey($key + '.one')) { return (Get-UiText ($key + '.one') @($n)) }
  return (Get-UiText ($key + '.other') @($n))
}

# The family this language wants drawn (a CJK language names one, because the Segoe faces have no
# CJK glyphs); empty means the theme and the built-in chain decide.
function Get-UiTextFont {
  Initialize-TextLoaded
  if ($script:TextMeta.ContainsKey('font')) { return [string]$script:TextMeta['font'] }
  return ''
}

# The code in use, for the row in the settings window and for `status`.
function Get-UiTextCode {
  Initialize-TextLoaded
  return $script:TextCode
}

# The name the language file calls itself. Used where a measurement has to stand for the words on
# screen - the ink of the script, not of the alphabet.
function Get-UiTextName {
  Initialize-TextLoaded
  if ($script:TextMeta.ContainsKey('name') -and [string]$script:TextMeta['name']) { return [string]$script:TextMeta['name'] }
  return $script:TextCode
}

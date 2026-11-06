# lib/query.ps1 - what a search line means. The text is cut up by utils/query.ps1; this file
# decides which fields exist, compiles the patterns, and answers one record at a time.
#
# The vocabulary is deliberately small, and every field is a filter that can only narrow:
#
#   word            the payload contains it (case-insensitive)
#   "two words"     the phrase, spaces included
#   -word           the payload must not contain it
#   type:a,b        text / files / image / rich, or a kind a plugin declares
#   mark:p          carries that mark;  -mark:p  does not
#   age:7d          older than seven days (d, h, m, s, or a plain number of days)
#   newer:2026-11-01  captured on or after that date;  older:...  before it
#   re:<pattern>    regular expression over the head of the payload
#   py:zg           pinyin initials (GB2312 level-1 hanzi), see utils/pinyin.ps1
#
# An unknown type or a pattern that does not compile is reported in Bad and makes the query
# match nothing: silently dropping it would answer a different question than the one asked.

# The kinds the base can tell apart for itself; anything else has to come from a plugin.
function Get-QueryBaseTypes { return @('text', 'files', 'image', 'rich', 'any') }

# field name -> what it accepts, shown by the panel and by `clipboard list --help` style output
function Get-QueryFields {
  return [ordered]@{
    type  = 'text, files, image, rich'
    mark  = 'a mark a plugin declares, e.g. p'
    age   = '7d, 12h, 30m'
    newer = 'a date, e.g. 2026-11-01'
    older = 'a date'
    re    = 'a regular expression'
    py    = 'pinyin initials, e.g. zg'
  }
}

# '7d' / '12h' / '30m' / '90s' / '3' -> seconds
function ConvertTo-QuerySeconds([string]$spec) {
  $s = ([string]$spec).Trim().ToLowerInvariant()
  if (-not $s) { return -1 }
  $m = [regex]::Match($s, '^(\d+)([dhms])?$')
  if (-not $m.Success) { return -1 }
  $n = [long]$m.Groups[1].Value
  $unit = [string]$m.Groups[2].Value
  switch ($unit) {
    's' { return $n }
    'm' { return ($n * 60) }
    'h' { return ($n * 3600) }
    'd' { return ($n * 86400) }
    default { return ($n * 86400) }
  }
}

function ConvertTo-QueryEpoch([string]$spec) {
  $s = ([string]$spec).Trim()
  if (-not $s) { return [long]-1 }
  $d = [DateTime]::MinValue
  $ok = [DateTime]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)
  if (-not $ok) { $ok = [DateTime]::TryParse($s, [ref]$d) }
  if (-not $ok) { return [long]-1 }
  return ([long](([DateTimeOffset]$d.ToUniversalTime()).ToUnixTimeSeconds()))
}

# A query is a bag of filters; an empty one matches everything. Count is how many filters
# were given, which is what the panel uses to tell "no search" from "no results".
function New-Query {
  param([string]$Line = '', [string[]]$Tokens = $null)
  $q = @{
    Line     = [string]$Line
    Terms    = New-Object System.Collections.Generic.List[string]
    Excludes = New-Object System.Collections.Generic.List[string]
    Patterns = New-Object System.Collections.Generic.List[object]
    Types    = New-Object System.Collections.Generic.List[object]
    Marks    = New-Object System.Collections.Generic.List[object]
    Initials = New-Object System.Collections.Generic.List[string]
    Newer    = [long]0
    Older    = [long]0
    Bad      = New-Object System.Collections.Generic.List[string]
    Count    = 0
  }
  $raw = @()
  if ($null -ne $Tokens) { $raw = @($Tokens) } else { $raw = @(Split-QueryText $Line) }
  $known = @(Get-QueryFields).Keys
  $base = @(Get-QueryBaseTypes)
  $pluginKinds = @{}
  if (Get-Command Get-PluginQueryKinds -ErrorAction SilentlyContinue) {
    try { $pluginKinds = Get-PluginQueryKinds } catch { $pluginKinds = @{} }
  }
  foreach ($token in $raw) {
    if (-not $token) { continue }
    $p = Get-QueryPart ([string]$token)
    $field = [string]$p.Field
    $value = [string]$p.Value
    if ($field -and ($known -notcontains $field)) { $field = '' }
    switch ($field) {
      're' {
        $q.Count++
        if (-not $value) { $q.Bad.Add('re: needs a pattern'); break }
        try {
          $re = New-Object Text.RegularExpressions.Regex ($value),
            ([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant),
            ([TimeSpan]::FromMilliseconds(250))
          $q.Patterns.Add($re)
        } catch { $q.Bad.Add('re: ' + $_.Exception.Message) }
      }
      'type' {
        $q.Count++
        $group = New-Object System.Collections.Generic.List[object]
        foreach ($name in @(Split-QueryValue $value)) {
          $n = $name.ToLowerInvariant()
          if ($base -contains $n) { $group.Add(@{ Name = $n; Test = $null }); continue }
          if ($pluginKinds.ContainsKey($n)) { $group.Add(@{ Name = $n; Test = $pluginKinds[$n] }); continue }
          $q.Bad.Add('unknown type: ' + $n)
        }
        if ($group.Count -gt 0) { $q.Types.Add($group.ToArray()) }
      }
      'mark' {
        $q.Count++
        foreach ($name in @(Split-QueryValue $value)) {
          if ($name.Length -eq 1) { $q.Marks.Add(@{ Mark = $name; On = (-not $p.Negated) }) }
          else { $q.Bad.Add('mark: wants one character') }
        }
      }
      'age' {
        $q.Count++
        $secs = ConvertTo-QuerySeconds $value
        if ($secs -lt 0) { $q.Bad.Add('age: wants 7d, 12h or 30m') }
        else { $q.Older = [long]((Get-Epoch) - $secs) }
      }
      'newer' {
        $q.Count++
        $t = ConvertTo-QueryEpoch $value
        if ($t -lt 0) { $q.Bad.Add('newer: needs a date') } else { $q.Newer = $t }
      }
      'older' {
        $q.Count++
        $t = ConvertTo-QueryEpoch $value
        if ($t -lt 0) { $q.Bad.Add('older: needs a date') } else { $q.Older = $t }
      }
      'py' {
        $q.Count++
        if ($value -match '^[A-Za-z]+$') { $q.Initials.Add($value.ToLowerInvariant()) }
        else { $q.Bad.Add('py: wants latin initials') }
      }
      default {
        $q.Count++
        if ($p.Negated) { $q.Excludes.Add([string]$p.Text) } else { $q.Terms.Add([string]$p.Text) }
      }
    }
  }
  return $q
}

# One type test. A plugin kind carries its own scriptblock; the base kinds are answered here
# because they come from the payload prefix and the rich sidecar, which only the base knows.
function Test-QueryType($record, $type) {
  $payload = [string]$record.Payload
  switch ([string]$type.Name) {
    'any' { return $true }
    'files' { return (Test-FilePayload $payload) }
    'image' { return (Test-ImagePayload $payload) }
    'rich' { return ([bool][string]$record.Rich) }
    'text' { return ((-not (Test-FilePayload $payload)) -and (-not (Test-ImagePayload $payload)) -and (-not [string]$record.Rich)) }
  }
  if ($null -eq $type.Test) { return $false }
  try { return [bool](& $type.Test $payload) } catch { return $false }
}

# Does this record survive every filter in the query?
function Test-QueryRecord($record, $query) {
  $head = [string]$record.Payload
  $len = $head.Length
  # only the head of a big payload is ever shown, so that is what the search reads
  if ($len -gt 4096) { $len = 4096 }
  foreach ($term in $query.Terms) {
    if ($term.Length -gt $len) { return $false }
    if ($head.IndexOf($term, 0, $len, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
  }
  foreach ($term in $query.Excludes) {
    if ($term.Length -le $len -and $head.IndexOf($term, 0, $len, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
  }
  foreach ($re in $query.Patterns) {
    $slice = $head
    if ($slice.Length -gt 4096) { $slice = $slice.Substring(0, 4096) }
    try { if (-not $re.IsMatch($slice)) { return $false } } catch { return $false }
  }
  foreach ($group in $query.Types) {
    $ok = $false
    foreach ($type in $group) { if (Test-QueryType $record $type) { $ok = $true; break } }
    if (-not $ok) { return $false }
  }
  foreach ($want in $query.Marks) {
    $has = (([string]$record.Marks).IndexOf([string]$want.Mark) -ge 0)
    if ($has -ne [bool]$want.On) { return $false }
  }
  if ($query.Newer -gt 0 -and [long]$record.Time -lt $query.Newer) { return $false }
  if ($query.Older -gt 0 -and [long]$record.Time -ge $query.Older) { return $false }
  foreach ($token in $query.Initials) {
    if (-not (Test-PinyinHit $head $token)) { return $false }
  }
  return $true
}

# True when every row that matches New also matches Old - that is, when Old's answer can be
# used as the candidate set for New. Adding a term or an exclusion narrows; extending the last
# term narrows (a longer word only matches a subset); extending an exclusion does not, because
# -ab rejected rows containing 'ab' and -abc rejects fewer.
function Test-QueryNarrow($old, $new) {
  if ($null -eq $old) { return $false }
  if (($old.Types.Count -gt 0) -or ($old.Marks.Count -gt 0) -or ($old.Patterns.Count -gt 0) -or ($old.Initials.Count -gt 0)) { return $false }
  if (([long]$old.Newer -ne [long]$new.Newer) -or ([long]$old.Older -ne [long]$new.Older)) { return $false }
  $oldTerms = $old.Terms
  $newTerms = $new.Terms
  if ($oldTerms.Count -eq 0) { return $false }
  if ($newTerms.Count -lt $oldTerms.Count) { return $false }
  for ($i = 0; $i -lt $oldTerms.Count; $i++) {
    if ($i -eq ($oldTerms.Count - 1)) {
      if (-not ([string]$newTerms[$i]).StartsWith([string]$oldTerms[$i], [StringComparison]::OrdinalIgnoreCase)) { return $false }
    } elseif ([string]$newTerms[$i] -cne [string]$oldTerms[$i]) { return $false }
  }
  $oldExcl = $old.Excludes
  $newExcl = $new.Excludes
  if ($newExcl.Count -lt $oldExcl.Count) { return $false }
  for ($i = 0; $i -lt $oldExcl.Count; $i++) {
    if ([string]$newExcl[$i] -cne [string]$oldExcl[$i]) { return $false }
  }
  return $true
}

# The rows the panel and the CLI show for one query. A query that could not be understood
# matches nothing: answering with everything would hide the typo.
#
# The panel asks again for every typed character, and each line is the one before it plus a
# character or a word. When the new line can only narrow the old one, the rows the old answer
# kept are the only candidates left, so the scan shrinks as the user types instead of starting
# over: a 3000 row history costs 76 ms cold and 2 ms once the first characters have landed.
# The cache holds one line and its answer; anything that is not a narrowing falls back to a
# full scan, which keeps the semantics identical to one query per line.
$script:QueryNarrow = $null
function Invoke-Query($entries, $query) {
  # The caller's array is kept rather than copied: the store replaces its array whenever a row
  # is added or removed and never edits one in place, so the identity is what tells the
  # narrowing cache below that the rows it knows about are still the rows on screen.
  $all = $entries
  if ($null -eq $all) { return @() }
  if ($all -isnot [array]) {
    $asList = $all -as [System.Collections.IList]
    if ($null -ne $asList) { $all = $asList.ToArray() } else { $all = @($all) }
  }
  if ($null -eq $query) { return $all }
  if ($query.Bad.Count -gt 0) { return @() }
  if ($query.Count -eq 0) { return $all }
  # The panel runs this on every keystroke, and one PowerShell call per record (plus a property
  # read inside it) was the whole cost at 300 rows. The common shape - plain words and
  # -exclusions - is spelled out here; a query carrying a filter falls back to the per record
  # test below, which is the readable version of the same rules.
  $plain = (($query.Types.Count -eq 0) -and ($query.Marks.Count -eq 0) -and
            ($query.Patterns.Count -eq 0) -and ($query.Initials.Count -eq 0) -and
            ([long]$query.Newer -le 0) -and ([long]$query.Older -le 0))
  $rows = New-Object System.Collections.Generic.List[object]
  if ($plain) {
    $terms = $query.Terms
    $excl = $query.Excludes
    # a line that only adds to the one just answered keeps a subset of that answer, so only
    # those rows are read again; the array identity covers a store that changed in between
    $scan = $all
    $memo = $script:QueryNarrow
    if ($null -ne $memo) {
      if (([object]::ReferenceEquals($memo.Array, $all)) -and
          ($memo.Line.Length -gt 0) -and
          ([string]$query.Line).StartsWith($memo.Line, [StringComparison]::Ordinal) -and
          (Test-QueryNarrow $memo.Query $query)) { $scan = $memo.Rows }
    }
    for ($i = 0; $i -lt $scan.Count; $i++) {
      $rec = $scan[$i]
      $head = [string]$rec.Payload
      $len = $head.Length
      # only the head of a big payload is ever shown, so that is what the search reads
      if ($len -gt 4096) { $len = 4096 }
      $ok = $true
      for ($t = 0; $t -lt $terms.Count; $t++) {
        $term = $terms[$t]
        if ($term.Length -gt $len -or $head.IndexOf($term, 0, $len, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $ok = $false; break }
      }
      if ($ok) {
        for ($t = 0; $t -lt $excl.Count; $t++) {
          $term = $excl[$t]
          if ($term.Length -le $len -and $head.IndexOf($term, 0, $len, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $ok = $false; break }
        }
      }
      if ($ok) { $rows.Add($rec) }
    }
    $kept = $rows.ToArray()
    $script:QueryNarrow = @{ Array = $all; Line = [string]$query.Line; Query = $query; Rows = $kept }
    return $kept
  }
  foreach ($rec in $all) {
    if (Test-QueryRecord $rec $query) { $rows.Add($rec) }
  }
  return $rows.ToArray()
}

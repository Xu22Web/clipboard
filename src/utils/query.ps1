# utils/query.ps1 - cut a query line into tokens. No meaning lives here: what a field means,
# which types exist and what counts as a match is the caller's business (lib/query.ps1).
#
# Double quotes hold a phrase together, including its spaces; an unclosed quote simply runs
# to the end of the line instead of being an error.

function Split-QueryText([string]$line) {
  $out = New-Object System.Collections.Generic.List[string]
  if ([string]::IsNullOrEmpty($line)) { return $out.ToArray() }
  $sb = New-Object System.Text.StringBuilder
  $quoted = $false
  $have = $false
  foreach ($ch in $line.ToCharArray()) {
    if ($ch -eq '"') { $quoted = -not $quoted; $have = $true; continue }
    if (-not $quoted -and [char]::IsWhiteSpace($ch)) {
      if ($have) { $out.Add($sb.ToString()); [void]$sb.Clear(); $have = $false }
      continue
    }
    [void]$sb.Append($ch)
    $have = $true
  }
  if ($have) { $out.Add($sb.ToString()) }
  return $out.ToArray()
}

# Read one token: a leading '-' negates, 'name:value' names a field. The field name is only
# recognisable when it is short and alphanumeric, so 'https://x' and '12:30' stay text; whether
# the name is one the caller knows is decided by the caller.
function Get-QueryPart([string]$raw) {
  $p = @{ Raw = $raw; Text = $raw; Field = ''; Value = ''; Negated = $false }
  $s = [string]$raw
  if ($s.Length -gt 1 -and $s[0] -eq '-') { $p.Negated = $true; $s = $s.Substring(1) }
  $colon = $s.IndexOf(':')
  if ($colon -ge 1) {
    $name = $s.Substring(0, $colon).ToLowerInvariant()
    if ($name -match '^[a-z][a-z0-9]*$') {
      $p.Field = $name
      $p.Value = $s.Substring($colon + 1)
    }
  }
  $p.Text = $s
  return $p
}

# Split a comma separated value, trimming and dropping the empty parts ('a, b' -> a b).
function Split-QueryValue([string]$value) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($piece in @(([string]$value) -split ',')) {
    $p = $piece.Trim()
    if ($p) { $out.Add($p) }
  }
  return $out.ToArray()
}

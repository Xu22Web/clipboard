# utils/apprules.ps1 - the text form of "in this program, paste like that".
#
#   AppRules=windowsterminal.exe:plain;code.exe:rich;*
#
# One rule per ';' or ',' separated item, written 'name:action'. A name is a process name,
# with or without '.exe'; '*' is the fallback for everything else. Parsing is all this file
# does, so the rules can be checked without a window and a bad value is reported by the same
# schema pass as every other setting.

# the actions a rule may name, and what each one means for a paste
function Get-AppRuleActions {
  return [ordered]@{
    plain    = 'paste the text without its formatting'
    rich     = 'paste the formatting too, when the entry has any'
    'no-paste' = 'copy only, never inject the paste keys'
  }
}

function ConvertFrom-AppRuleText([string]$text) {
  $map = [ordered]@{}
  if ([string]::IsNullOrWhiteSpace($text)) { return $map }
  foreach ($item in @(([string]$text) -split '[;,]')) {
    $one = $item.Trim()
    if (-not $one) { continue }
    $cut = $one.LastIndexOf(':')
    if ($cut -lt 1 -or $cut -ge ($one.Length - 1)) { continue }
    $name = $one.Substring(0, $cut).Trim().ToLowerInvariant()
    $action = $one.Substring($cut + 1).Trim().ToLowerInvariant()
    if (-not $name) { continue }
    if ($name -ne '*' -and -not $name.EndsWith('.exe')) { $name = $name + '.exe' }
    $map[$name] = $action
  }
  return $map
}

# @{ Ok; Value (the normalised text); Error } - the schema calls this instead of guessing
function Test-AppRuleText([string]$text) {
  $raw = [string]$text
  if ([string]::IsNullOrWhiteSpace($raw)) { return @{ Ok = $true; Value = ''; Error = '' } }
  $actions = @((Get-AppRuleActions).Keys)
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($raw -split '[;,]')) {
    $one = $item.Trim()
    if (-not $one) { continue }
    $cut = $one.LastIndexOf(':')
    if ($cut -lt 1 -or $cut -ge ($one.Length - 1)) {
      return @{ Ok = $false; Value = ''; Error = ('expected program:action, got "' + $one + '"') }
    }
    $name = $one.Substring(0, $cut).Trim()
    $action = $one.Substring($cut + 1).Trim().ToLowerInvariant()
    if ($actions -notcontains $action) {
      return @{ Ok = $false; Value = ''; Error = ('unknown action "' + $action + '" (use ' + ($actions -join ', ') + ')') }
    }
    if ($name -ne '*') {
      $probe = $name.ToLowerInvariant()
      if (-not $probe.EndsWith('.exe')) { $probe = $probe + '.exe' }
      if ($probe -notmatch '^[a-z0-9_.\-]+\.exe$') {
        return @{ Ok = $false; Value = ''; Error = ('"' + $name + '" is not a program name') }
      }
      $name = $probe
    }
    $parts.Add($name + ':' + $action)
  }
  return @{ Ok = $true; Value = ($parts -join ';'); Error = '' }
}

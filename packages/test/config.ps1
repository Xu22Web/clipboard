# packages\test\config.ps1 - read test.config.ps1 and decide how a run is shaped.
#
# The one place that knows the shape of the test config. A key it does not know is a typo whose
# failure would otherwise be silent - a misspelled Report just keeps the default - so it stops the
# run with the list of what this loader accepts.

$script:TestKeys = @('Groups', 'Exclude', 'Workers', 'Reporter', 'Bail', 'Serial')
$script:TestGroups = @('unit', 'integration', 'e2e')

function Get-TestConfig {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$ConfigFile = ''
  )
  if (-not $ConfigFile) { $ConfigFile = Join-Path $Root 'test.config.ps1' }
  if (-not (Test-Path -LiteralPath $ConfigFile)) { throw ('missing test config: ' + $ConfigFile) }
  $doc = & $ConfigFile
  if ($null -eq $doc -or -not ($doc -is [System.Collections.IDictionary])) {
    throw ((Split-Path -Leaf $ConfigFile) + ' must return one table')
  }
  if (-not $doc.Contains('Test') -or -not ($doc['Test'] -is [System.Collections.IDictionary])) {
    throw ((Split-Path -Leaf $ConfigFile) + ' must return a Test table: @{ Test = @{ Groups = ... } }')
  }
  $raw = $doc['Test']
  $bad = New-Object System.Collections.Generic.List[string]
  foreach ($k in @($raw.Keys)) {
    if ($script:TestKeys -notcontains ([string]$k)) { $bad.Add(('unknown key: Test.' + $k)) }
  }

  $groups = @()
  foreach ($one in @($raw['Groups'])) { if ([string]$one -and ([string]$one).Trim()) { $groups += ([string]$one).Trim() } }
  if ($groups.Count -eq 0) { $bad.Add('Test.Groups is empty') }
  foreach ($g in $groups) {
    if ($script:TestGroups -notcontains $g) { $bad.Add(('Test.Groups names no group: ' + $g)) }
  }

  $workers = 0
  if ($raw.Contains('Workers')) { [void][int]::TryParse(([string]$raw['Workers']).Trim(), [ref]$workers) }
  if ($workers -lt 0 -or $workers -gt 64) { $bad.Add('Test.Workers is outside 0..64') }

  $reporter = 'default'
  if ($raw.Contains('Reporter') -and ([string]$raw['Reporter']).Trim()) { $reporter = ([string]$raw['Reporter']).Trim() }
  if (@('default', 'verbose') -notcontains $reporter) { $bad.Add('Test.Reporter is neither default nor verbose') }

  $exclude = @()
  foreach ($one in @($raw['Exclude'])) { if ([string]$one -and ([string]$one).Trim()) { $exclude += ([string]$one).Trim() } }

  $result = @{
    ConfigFile = $ConfigFile
    Groups     = $groups
    Exclude    = $exclude
    Workers    = $workers
    Reporter   = $reporter
    Bail       = [bool]$(if ($raw.Contains('Bail')) { $raw['Bail'] } else { $false })
    Serial     = [bool]$(if ($raw.Contains('Serial')) { $raw['Serial'] } else { $false })
  }
  if ($bad.Count -gt 0) { throw ($bad -join [Environment]::NewLine) }
  return $result
}

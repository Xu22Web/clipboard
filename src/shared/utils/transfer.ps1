# utils/transfer.ps1 - the shapes an export can take, as text.
#
# Nothing here touches the store or the disk: a caller hands over plain rows (text, time,
# marks, and optionally media as base64) and gets text back, or hands over text and gets rows
# back. That keeps the file formats testable without a history and without a clipboard.
#
# JSON is the format that keeps everything; CSV carries the three columns a spreadsheet can
# hold; TXT is for reading, so it is export only.

# The document version. A reader refuses anything else instead of guessing.
function Get-TransferVersion { return 1 }

# rows -> the JSON document
function ConvertTo-TransferJson($rows) {
  $doc = [ordered]@{
    format   = 'clipboard-history'
    version  = (Get-TransferVersion)
    exported = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    records  = @($rows)
  }
  return ($doc | ConvertTo-Json -Depth 8)
}

# text -> @{ Version; Rows }, or $null with a reason in $script nowhere: the caller checks.
function ConvertFrom-TransferJson([string]$text) {
  $doc = $null
  try { $doc = $text | ConvertFrom-Json } catch { return $null }
  if ($null -eq $doc) { return $null }
  if ([string]$doc.format -ne 'clipboard-history') { return $null }
  if ([int]$doc.version -ne (Get-TransferVersion)) { return $null }
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($r in @($doc.records)) {
    if ($null -eq $r) { continue }
    $rows.Add(@{
        Text  = [string]$r.text
        Time  = [long]$r.time
        Marks = [string]$r.marks
        Media = $r.media
      })
  }
  return @{ Version = [int]$doc.version; Rows = $rows.ToArray() }
}

# rows -> 'text,time,marks' lines; ConvertTo-Csv does the quoting a payload needs
function ConvertTo-TransferCsv($rows) {
  $flat = @()
  foreach ($r in @($rows)) {
    $flat += [pscustomobject]@{ text = [string]$r.Text; time = [long]$r.Time; marks = [string]$r.Marks }
  }
  if ($flat.Count -eq 0) { return "text,time,marks`r`n" }
  # the pipeline form: -InputObject with an array would write one row describing the array
  return (($flat | ConvertTo-Csv -NoTypeInformation) -join "`r`n")
}

function ConvertFrom-TransferCsv([string]$text) {
  $rows = New-Object System.Collections.Generic.List[object]
  $parsed = @()
  try { $parsed = @($text | ConvertFrom-Csv) } catch { return $null }
  $first = $null
  if ($parsed.Count -gt 0) { $first = $parsed[0] }
  if ($null -eq $first) { return @{ Version = 0; Rows = @() } }
  # the header has to be the one this build writes, or the columns mean something else
  $props = @($first.PSObject.Properties.Name)
  if (($props -notcontains 'text') -or ($props -notcontains 'time')) { return $null }
  foreach ($r in $parsed) {
    $t = [long]0
    [void][long]::TryParse([string]$r.time, [ref]$t)
    $rows.Add(@{ Text = [string]$r.text; Time = $t; Marks = [string]$r.marks; Media = $null })
  }
  return @{ Version = 0; Rows = $rows.ToArray() }
}

# rows -> one payload per record, separated by a rule line, for reading and grepping
function ConvertTo-TransferText($rows) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($r in @($rows)) {
    [void]$sb.Append([string]$r.Text).Append("`r`n")
    [void]$sb.Append('---').Append("`r`n")
  }
  return $sb.ToString()
}

# base64 -> bytes, for a media block that has to be written back
function ConvertFrom-TransferBase64([string]$data) {
  if (-not $data) { return $null }
  try { return [Convert]::FromBase64String($data) } catch { return $null }
}

function ConvertTo-TransferBase64([byte[]]$bytes) {
  if ($null -eq $bytes -or $bytes.Length -eq 0) { return '' }
  return [Convert]::ToBase64String($bytes)
}

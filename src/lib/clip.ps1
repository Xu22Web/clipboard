# lib/clip.ps1 - the only place that talks to the Windows clipboard.
#
# Everything above this layer works with strings: text, or a file-list payload (leading
# char 1). Keeping the WinForms / CF_HDROP details here is what makes the store and the
# picker easy to test, and keeps clipboard-ownership bugs in one file.

function Get-Text {
  Load-Forms
  for ($i = 0; $i -lt 10; $i++) {
    try {
      if (-not [Windows.Forms.Clipboard]::ContainsText()) { return '' }
      return [Windows.Forms.Clipboard]::GetText([Windows.Forms.TextDataFormat]::UnicodeText)
    } catch { Start-Sleep -Milliseconds 50 }
  }
  return $null
}

function Set-Text([string]$t) {
  Load-Forms
  for ($i = 0; $i -lt 10; $i++) {
    try {
      [Windows.Forms.Clipboard]::SetText($t, [Windows.Forms.TextDataFormat]::UnicodeText)
      return $true
    } catch { Start-Sleep -Milliseconds 50 }
  }
  return $false
}

# one clipboard item: plain text, or FILESIG + newline-joined paths (CF_HDROP)
function Get-ClipItem {
  Load-Forms
  for ($i = 0; $i -lt 10; $i++) {
    try {
      if ([Windows.Forms.Clipboard]::ContainsFileDropList()) {
        $col = [Windows.Forms.Clipboard]::GetFileDropList()
        if ($null -ne $col -and $col.Count -gt 0) {
          $parts = New-Object System.Collections.Generic.List[string]
          foreach ($p in $col) { $parts.Add($p) }
          return ($FILESIG + ($parts -join "`n"))
        }
      }
      if (-not [Windows.Forms.Clipboard]::ContainsText()) { return '' }
      return [Windows.Forms.Clipboard]::GetText([Windows.Forms.TextDataFormat]::UnicodeText)
    } catch { Start-Sleep -Milliseconds 50 }
  }
  return $null
}

function Set-ClipItem([string]$entry) {
  if ($entry.Length -gt 0 -and $entry[0] -eq [char]1) {
    Load-Forms
    $sc = New-Object System.Collections.Specialized.StringCollection
    foreach ($p in @($entry.Substring(1) -split "`n" | Where-Object { $_ })) { [void]$sc.Add($p) }
    for ($i = 0; $i -lt 10; $i++) {
      try { [Windows.Forms.Clipboard]::SetFileDropList($sc); return $true } catch { Start-Sleep -Milliseconds 50 }
    }
    return $false
  }
  return (Set-Text $entry)
}

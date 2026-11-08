# tools\utils\csc.ps1 - find the C# compiler and report what it says.
#
# Both build scripts compile with the compiler that ships inside the .NET Framework 4, which
# Windows 10 and 11 already have. Nothing here writes a file: it only locates the tool and
# filters its output, so a failure message stays a failure message.

function Find-Csc {
  # the 64-bit compiler first, then the 32-bit one: both products are AnyCPU
  foreach ($dir in @(
      (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'),
      (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'))) {
    $candidate = Join-Path $dir 'csc.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  return ''
}

function Write-CscLog($output) {
  foreach ($line in @($output)) {
    $text = ([string]$line).Trim()
    # the compiler prints a version advisory on every run; it is not a problem report
    if (-not $text -or $text -like '*provided as part of the Microsoft*') { continue }
    Write-Host ('    ' + $text)
  }
}

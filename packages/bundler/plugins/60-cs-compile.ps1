#Requires -Version 5.1
<#
  tools\bundler\plugins\60-cs-compile.ps1 - one assembly out of the file list.

  The compiler is handed the list the part stage resolved; nothing here writes C#. A failure is
  reported with the compiler's own log and stops the entry: a product that does not compile is
  not a smaller product, it is a missing one.
#>

$Plugin = @{
  Name  = 'cs-compile'
  Hooks = @{
    compile = {
      param($ctx, $files)
      $csc = Find-Csc
      if (-not $csc) { throw 'no C# compiler found (looked for the .NET Framework 4 csc.exe)' }
      $out = [string]$ctx.Entry.Out
      $parent = Split-Path -Parent $out
      if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
      if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
      $target = 'library'
      if ([string]$ctx.Entry.Target) { $target = [string]$ctx.Entry.Target }
      $refs = @('-r:System.Windows.Forms.dll', '-r:System.Drawing.dll', '-r:System.Core.dll')
      foreach ($r in @($ctx.Entry.References)) { $refs += ('-r:' + $r) }
      $args = @('-nologo', '-optimize+', ('-target:' + $target), ('-out:' + $out)) + $refs + @($files)
      $log = & $csc @args 2>&1
      $code = $LASTEXITCODE
      if ($code -ne 0 -or -not (Test-Path -LiteralPath $out)) {
        # CS0016 is "could not write to output file", and in this program it means one thing:
        # the resident process has the assembly loaded. Say which step fixes it, once.
        $hint = ''
        if (($log -join ' ') -match 'CS0016') { $hint = ' (the output file is in use - run: clipboard stop)' }
        Write-CscLog $log
        throw ('the compiler refused the source list (exit ' + $code + ')' + $hint)
      }
      $size = (Get-Item -LiteralPath $out).Length
      return @{ Files = @($files).Count; Bytes = $size }
    }
  }
}

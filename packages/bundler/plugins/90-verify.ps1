#Requires -Version 5.1
<#
  tools\bundler\plugins\90-verify.ps1 - the bundle is the modules, proved by reading it back.

  "It ran" is not evidence that the merge was right: a statement can go missing and the program
  keeps working until the one path that needed it runs. So the finished text is parsed again and
  described the same way the modules were, and the two descriptions have to match exactly -
  definitions in order, statements in order, commands (by name when nothing was renamed, by
  number when it was).
#>

$Plugin = @{
  Name  = 'verify'
  Hooks = @{
    verify = {
      param($ctx, $expected, $text)
      $actual = Get-BundleFingerprint $text
      $problems = @(Compare-BundleFingerprint $expected $actual -Renamed:$ctx.Options.Rename)
      if ($problems.Count -gt 0) {
        foreach ($p in $problems) { Write-Fail ($ctx.Entry.Name + ': ' + $p) }
        throw ('entry ' + $ctx.Entry.Name + ' does not match its modules')
      }
      return @{
        Functions = @($actual.Functions).Count
        Commands  = @($actual.Commands).Count
        Shapes    = @($actual.Shapes).Count
        Fingerprint = $actual
      }
    }
  }
}

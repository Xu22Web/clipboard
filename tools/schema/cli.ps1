# tools\schema\cli.ps1 - what cli.ini may contain.
#
# One table of flat keys: a "[dev]" section prefixes the keys that follow it, so the key here
# is "dev.Interval" - the same rule the program's own ini files use. The tooling validates the
# file against this table before it acts on it (tools\utils\schema.ps1), so a missing key, an
# unknown key or a value of the wrong type stops the command instead of falling back to a
# silent default.
#
# Required is the default: every key must be present. A list may be empty, which means "none"
# - an empty Plugins= ships no plugin rather than every plugin.

@{
  Name        = 'cli'
  File        = 'cli.ini'
  Description = 'the repository tooling: watcher, package and test settings'
  Version     = 1
  Keys        = [ordered]@{
    'dev.Interval'  = @{ Type = 'int'; Minimum = 100; Maximum = 60000; Description = 'watcher poll interval in ms' }
    'dev.Includes'  = @{ Type = 'list'; Pattern = '^[A-Za-z0-9_.*?/\-]+$'; NonEmpty = $true; Description = 'globs to watch, relative to src\' }
    'dev.Excludes'  = @{ Type = 'list'; Pattern = '^[A-Za-z0-9_.*?/\-]+$'; Description = 'globs to leave out of Includes' }
    'dev.Client'    = @{ Type = 'bool'; Description = '1 = compile src\client.exe before the first start and after a client.cs change' }
    'dev.Assembly'  = @{ Type = 'bool'; Description = '1 = compile src\lib\assembly\clipboard.dll before the first start and after a .cs change' }

    'build.OutDir'      = @{ Type = 'string'; Description = 'output folder, relative to the repository root' }
    'build.Minify'      = @{ Type = 'bool'; Description = '1 = rewrite every .ps1 from its syntax tree' }
    'build.Rename'      = @{ Type = 'bool'; Description = '1 = also rename internal functions and local variables' }
    'build.Verify'      = @{ Type = 'bool'; Description = '1 = run the CLI suite against the package' }
    'build.IncludeDocs' = @{ Type = 'bool'; Description = '1 = also ship README.md, LICENSE and docs\' }
    'build.Overwrite'   = @{ Type = 'bool'; Description = '1 = replace an existing clipboard-<version> folder' }
    'build.Zip'         = @{ Type = 'bool'; Description = '1 = also write clipboard-<version>.zip' }
    'build.Client'      = @{ Type = 'bool'; Description = '1 = compile client.exe into the package' }
    'build.Assembly'    = @{ Type = 'bool'; Description = '1 = compile lib\assembly\clipboard.dll into the package' }
    'build.Plugins'     = @{ Type = 'list'; Description = 'plugins to ship, empty = none' }
    'build.Themes'      = @{ Type = 'list'; Description = 'themes to ship, empty = none' }
    'build.Includes'    = @{ Type = 'list'; Pattern = '^[A-Za-z0-9_.*?/\-]+$'; Description = 'extra files to ship, relative to src\' }
    'build.Excludes'    = @{ Type = 'list'; Pattern = '^[A-Za-z0-9_.*?/\-]+$'; Description = 'files to leave out of the package' }

    'test.Groups'  = @{ Type = 'list'; Enum = @('unit', 'integration', 'e2e'); NonEmpty = $true; Description = 'groups a plain run covers' }
    'test.Workers' = @{ Type = 'int'; Minimum = 1; Maximum = 64; Description = 'sandboxes that may run side by side' }
  }
}

# tools\schema\cli.ps1 - what cli.ini may contain.
#
# One table of flat keys: a "[dev]" section prefixes the keys that follow it, so the key here
# is "dev.Interval" - the same rule the program's own ini files use. The tooling validates the
# file against this table before it acts on it (tools\utils\schema.ps1), so a missing key, an
# unknown key or a value of the wrong type stops the command instead of falling back to a
# silent default.
#
# Required is the default: every key must be present. A list key says for itself whether it
# may be empty: NonEmpty marks the ones where an empty value would mean "nothing at all"
# (the build would ship no file), so it stops the command instead.

@{
  Name        = 'cli'
  File        = 'cli.ini'
  Description = 'the repository tooling: watcher, package and test settings'
  Version     = 1
  Keys        = [ordered]@{
    'dev.Interval'  = @{ Type = 'int'; Minimum = 100; Maximum = 60000; Description = 'watcher poll interval in ms' }
    'dev.BaseUrl'   = @{ Type = 'string'; Description = 'folder the include and exclude globs are relative to' }
    'dev.Includes'  = @{ Type = 'list'; Pattern = '^[A-Za-z0-9_.*?/\-]+$'; NonEmpty = $true; Description = 'globs to watch, relative to BaseUrl; a .cs here is compiled before the first start and after every save' }
    'dev.Excludes'  = @{ Type = 'list'; Pattern = '^[A-Za-z0-9_.*?/\-]+$'; Description = 'globs to leave out of Includes' }

    'build.OutDir'      = @{ Type = 'string'; Description = 'output folder, relative to the repository root' }
    'build.BaseUrl'     = @{ Type = 'string'; Description = 'folder the include and exclude globs are relative to' }
    'build.Minify'      = @{ Type = 'bool'; Description = '1 = rewrite every .ps1 from its syntax tree' }
    'build.Rename'      = @{ Type = 'bool'; Description = '1 = also rename internal functions and local variables' }
    'build.Verify'      = @{ Type = 'bool'; Description = '1 = run the CLI suite against the package' }
    'build.Overwrite'   = @{ Type = 'bool'; Description = '1 = replace an existing clipboard-<version> folder' }
    'build.Zip'         = @{ Type = 'bool'; Description = '1 = also write clipboard-<version>.zip' }
    'build.Includes'    = @{ Type = 'list'; Pattern = '^[A-Za-z0-9_.*?/\-]+$'; NonEmpty = $true; Description = 'the files to ship, as globs relative to BaseUrl: a .ps1 is minified, a .cs under a product folder is compiled, an .ini stripped of comments' }
    'build.Excludes'    = @{ Type = 'list'; Pattern = '^[A-Za-z0-9_.*?/\-]+$'; Description = 'files to leave out of the package' }

    'test.Groups'  = @{ Type = 'list'; Enum = @('unit', 'integration', 'e2e'); NonEmpty = $true; Description = 'groups a plain run covers' }
    'test.Workers' = @{ Type = 'int'; Minimum = 1; Maximum = 64; Description = 'sandboxes that may run side by side' }
  }
}

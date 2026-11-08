# tools\schema\package.ps1 - what package.ini may contain.
#
# package.ini is the one file the whole tooling reads first: the name and version describe the
# build, and every "[scripts]" key is a cli command. It is checked before a command runs, so a
# mistyped section ("[script]") or a command with no command line is reported instead of being
# read as "no such command".
#
# A command name is free-form (scripts.Dev, scripts.Test, ...), which is what DynamicKeys is
# for: the prefix plus the spec every key under it obeys.

@{
  Name        = 'package'
  File        = 'package.ini'
  Description = 'project metadata and the cli command table'
  Version     = 1
  Keys        = [ordered]@{
    'package.Name'    = @{ Type = 'string'; Pattern = '^[a-z][a-z0-9-]*$'; NonEmpty = $true; Description = 'project name, lower case' }
    'package.Version' = @{ Type = 'string'; Pattern = '^[0-9]+\.[0-9]+\.[0-9]+$'; NonEmpty = $true; Description = 'version as <major>.<minor>.<patch>' }
  }
  DynamicKeys = [ordered]@{
    'scripts.' = @{ Type = 'string'; NonEmpty = $true; Description = 'one key per cli command: the command line it runs' }
  }
}

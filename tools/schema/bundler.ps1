# tools\schema\bundler.ps1 - what bundler.ini may contain.
#
# The bundler reads this before it resolves anything: a key that is missing, unknown or of the
# wrong type stops it with the list of problems, so a typo cannot turn into "the build quietly
# stopped minifying".
#
# The two tables under a section that can be written more than once are dynamic: "[entry.core]"
# and "[product.renderer]" are free names, and every key under them is a string the bundler
# parses itself (a comma separated module list, a chain of plugin names).

@{
  Name        = 'bundler'
  File        = 'bundler.ini'
  Description = 'the bundler entry table and its defaults'
  Version     = 1
  Keys        = [ordered]@{
    'bundler.OutDir'    = @{ Type = 'string'; NonEmpty = $true; Description = 'where bundles are written, relative to the repository root' }
    'bundler.Overwrite' = @{ Type = 'bool'; Description = '1 = replace an existing output' }
    'bundler.Minify'    = @{ Type = 'bool'; Description = '1 = rewrite a bundle from its syntax tree' }
    'bundler.Rename'    = @{ Type = 'bool'; Description = '1 = rename internal names of a bundle' }
    'bundler.Treeshake' = @{ Type = 'bool'; Description = '1 = drop definitions no load-time path reaches' }
    'bundler.Workers'   = @{ Type = 'int'; Minimum = 0; Maximum = 64; Optional = $true; Description = 'how many entries may be built side by side; 0 = one per processor' }
  }
  DynamicKeys = [ordered]@{
    'entry.'   = @{ Type = 'string'; Description = 'one key of an [entry.<name>] section' }
    'product.' = @{ Type = 'string'; NonEmpty = $true; Description = 'the plugin chain of a [product.<name>] section' }
  }
}

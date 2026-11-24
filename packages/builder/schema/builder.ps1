# packages\builder\schema\builder.ps1 - what builder.ini may contain.
#
# The keys are electron-builder's: compression at the top, directories and files as sections.
# The tooling validates the file before it acts on it, so an unknown key stops the build instead
# of silently doing nothing.
@{
  Name        = 'builder'
  File        = 'builder.ini'
  Description = 'what a release carries: how the scripts are written, the output folder, the list'
  Version     = 2
  Keys        = [ordered]@{
    'compression'         = @{ Type = 'string'; Enum = @('store', 'normal', 'maximum'); NonEmpty = $true; Description = 'store = pack as is, normal = rewrite every .ps1, maximum = also rename' }
    'directories.Output'  = @{ Type = 'string'; Description = 'folder a release is written to, relative to the repository root' }
    'directories.BaseUrl' = @{ Type = 'string'; Description = 'folder the file list is relative to; "." is the repository root' }
    'files.Files'         = @{ Type = 'list'; Pattern = '^!?[A-Za-z0-9_.*?/\-]+$'; NonEmpty = $true; Description = 'what the release carries, comma separated; a path prefixed with "!" is excluded' }
  }
}

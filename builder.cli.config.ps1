# builder.cli.config.ps1 - what this repository builds, shaped like electron.vite.config.ts.
#
# The file is a PowerShell expression that returns one ordered table: every key is a target, and
# the keys inside it are the ones a target accepts. Bundler and Watch may be written as well, but
# only to change a default - those live in packages\cli\config.ps1. dot-sourcing the file gives
# the shape back, so a wrong name is reported by the loader - packages\cli\config.ps1 - with the
# list of accepted keys.
#
#   Preset      one of the shapes packages\cli\plugins\presets.ps1 defines; the keys
#               below it override what the preset says, an empty value included
#   Plugins     the bundler chain, in order: each name is a file under packages\bundler\plugins
#   Kind        cs compiles C#, script bundles .ps1 files (the default)
#   Input       the sources: a list of files, or a glob, or both
#   Output      where it lands; for a C# target the path doubles as the package path
#   External    modules the target does not carry (a #@use edge into one is a file boundary)
#   Ship        $true puts the output in the release: `cli build` merges it and builder.ini
#               leaves its sources out of Files
#   Target      library (default) or exe, for a C# target
#   Minify      overrides Bundler for this target
#   Rename      overrides Bundler for this target
#   Treeshake   overrides Bundler for this target
#
# The four sections are the four outputs a build produces: two C# products, the window layer as
# one file, and the framework-plus-settings bundle that exists to prove the merge.

[ordered]@{

  # Bundler and Watch are optional: every key they can carry already has a default in
  # packages\cli\config.ps1, the way vite keeps its defaults in source and a project's
  # vite.config.ts writes only what it changes. Name a key here to change it for this build:
  #
  #   Bundler = @{ Treeshake = $false; Workers = 2 }
  #   Watch   = @{ Interval = 300 }

  Main = [ordered]@{

    Input  = 'src/main/index.cs'
    Output = 'main/clipboard.dll'
  }

  Preload = [ordered]@{

    Input  = 'src/preload/client.cs'
    Output = 'preload/client.exe'
  }

  Renderer = [ordered]@{

    # rolldown's input: one key per window, and the entry each one starts from. The modules a
    # window reaches are resolved from that entry - the call graph and the #@use edges - so no
    # file is listed here, and a module that nothing reaches never travels.
    Input  = [ordered]@{
      Picker   = @{ Entry = 'src/renderer/src/windows/picker.ps1' }
      Settings = @{ Entry = 'src/renderer/src/windows/settings.ps1' }
      Tray     = @{ Entry = 'src/renderer/src/windows/tray-menu.ps1' }
    }
    Scan   = 'src/**/*.ps1'
    # rolldown's entryFileNames / chunkFileNames: a window's own chunk sits in renderer\, the
    # chunks more than one window loads sit in renderer\assets\
    Output = [ordered]@{
      Entry = 'renderer/[name].[hash].ps1'
      Chunk = 'renderer/assets/[name]-[hash].ps1'
    }
    Ship   = $true
    # the build's own passes compress and rename the whole package with one table, so a name
    # means the same thing in the bundle and in the files beside it
    Minify = $false
    Rename = $false
  }
}

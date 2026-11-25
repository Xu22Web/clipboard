# builder.cli.config.ps1 - what this repository builds, shaped like electron.vite.config.ts.
#
# The file is a PowerShell expression that returns one ordered table: every key is a target, and
# the keys inside it are the ones a target accepts. Bundler and Watch may be written as well, but
# only to change a default - those live in packages\cli\config.ps1. dot-sourcing the file gives
# the shape back, so a wrong name is reported by the loader - packages\cli\config.ps1 - with the
# list of accepted keys.
#
#   Preset      one of the shapes packages\cli\plugins\presets.ps1 defines; the keys
#               below it override what the preset says, an empty value included. The preset
#               carries the shape's build.input / build.output and its stage chain
#   build       what the target is made of: input, output, scan - vite's three names
#   plugins     the bundler chain, in order: each name is a file under packages\bundler\plugins.
#               A preset already carries the chain of its shape, so a target writes this only
#               to change it (a shorter chain, a different order)
#   alias       name = folder, the way resolve.alias works: a #@use id that starts with a
#               name has the prefix replaced before the module is looked up
#   Kind        cs compiles C#, script bundles .ps1 files (the default)
#   External    modules the target does not carry (a #@use edge into one is a file boundary)
#   Ship        $true puts the output in the release: `run build` merges it and builder.ini
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

    # everything comes from the preset: src/main/index.cs -> main/clipboard.dll through the
    # cs-part, cs-compile chain. Naming a key here changes just that one.
  }

  Preload = [ordered]@{

    # src/preload/client.cs -> preload/client.exe, chain and paths from the preset as well
  }

  Renderer = [ordered]@{

    # rolldown's input: one key per window, and the entry each one starts from. The modules a
    # window reaches are resolved from that entry - the call graph and the #@use edges - so no
    # file is listed here, and a module that nothing reaches never travels. More than one entry
    # is why this table is written out: the preset knows the output and the scan, not the windows.
    build = [ordered]@{
      input = [ordered]@{
        Picker   = @{ Entry = 'src/renderer/src/windows/picker.ps1' }
        Settings = @{ Entry = 'src/renderer/src/windows/settings.ps1' }
        Tray     = @{ Entry = 'src/renderer/src/windows/tray-menu.ps1' }
      }
      # entryFileNames / chunkFileNames - the preset writes both templates: a window's own chunk
      # in renderer\, the chunks more than one window loads in renderer\assets\
      #   output = [ordered]@{ entry = 'renderer/[name].[hash].ps1'; chunk = 'renderer/assets/[name]-[hash].ps1' }
      # the graph is resolved against this set, so a module nothing calls is not dragged in
      #   scan = 'src/**/*.ps1'
    }

    # the chain and the two output templates come from the preset; the windows do not, because a
    # preset cannot know how many there are

    # how a #@use id is spelled: the prefix is replaced before the module is looked up, the way
    # resolve.alias works in a vite config. Empty here - every #@use names a full id.
    alias = [ordered]@{}

    # the build's own passes compress and rename the whole package with one table, so a name
    # means the same thing in the bundle and in the files beside it
    Minify = $false
    Rename = $false
    Ship   = $true
  }
}

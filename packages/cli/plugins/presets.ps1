# packages\cli\plugins\presets.ps1 - the three target shapes a build starts from.
#
# These are this package's extension plugins: the bundler knows how to resolve, merge and write a
# bundle, but what a "main process" or a "window layer" is made of belongs here, next to the
# config that names it. A target picks one with Preset= and may override any key; a preset whose
# name matches the section (Main, Preload, Renderer) is used without writing Preset= at all.
#
# A preset is what electron-vite calls the default of a section: the input and the output the
# three shapes start from. It carries no stage list - `plugins` is the target's own declaration,
# the way a vite config writes its own plugin array - so a target that names no plugins is a
# broken target, not one that quietly inherits a chain.
#
#   main       the type library: C#, library
#   preload    the command line accelerator: C#, exe
#   renderer   the window layer: one script out of many modules, with the base layer and the
#              window geometry left outside - they travel as their own files
#
# A key the config writes wins over the preset, including an empty one: External='' means "carry
# every module", which is what the core check target wants.
$script:Presets = [ordered]@{
  'main'     = [ordered]@{
    Kind   = 'cs'
    Target = 'library'
    build  = [ordered]@{ input = 'src/main/index.cs'; output = 'main/clipboard.dll' }
  }
  'preload'  = [ordered]@{
    Kind   = 'cs'
    Target = 'exe'
    build  = [ordered]@{ input = 'src/preload/client.cs'; output = 'preload/client.exe' }
  }
  'renderer' = [ordered]@{
    Kind     = 'script'
    External = 'main/utils/native,renderer/src/utils/text,shared/utils/schema,shared/utils/dpi,shared/utils/image,main/utils/config,main/utils/store,renderer/src/utils/themes,renderer/src/utils/theme-stub,main/utils/plugin/plugins,renderer/src/components/picker-geom'
    build    = [ordered]@{
      scan   = 'src/**/*.ps1'
      output = [ordered]@{ entry = 'renderer/[name].[hash].ps1'; chunk = 'renderer/assets/[name]-[hash].ps1' }
    }
  }
}

function Get-PresetNames {
  return @($script:Presets.Keys)
}

# The preset a section names, or the one whose name the section already carries: "Renderer" is
# the "renderer" preset unless the section says otherwise. $null means "no preset for this name",
# which is a normal answer - a section may describe itself completely.
function Get-Preset([string]$name) {
  if (-not $name) { return $null }
  if (-not $script:Presets.Contains($name)) { return $null }
  return $script:Presets[$name]
}

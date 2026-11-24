# packages\cli\plugins\presets.ps1 - the three target shapes a build starts from.
#
# These are this package's extension plugins: the bundler knows how to resolve, merge and write a
# bundle, but what a "main process" or a "window layer" is made of belongs here, next to the
# config that names it. A target picks one with Preset= and may override any key; a preset whose
# name matches the section (Main, Preload, Renderer) is used without writing Preset= at all.
#
#   main       the type library: C#, library, two stages
#   preload    the command line accelerator: C#, exe
#   renderer   the window layer: one script out of many modules, with the base layer and the
#              window geometry left outside - they travel as their own files
#
# A key the config writes wins over the preset, including an empty one: External='' means "carry
# every module", which is what the core check target wants.
$script:Presets = [ordered]@{
  'main'     = [ordered]@{
    Plugins = 'cs-part,cs-compile'
    Kind    = 'cs'
    Target  = 'library'
  }
  'preload'  = [ordered]@{
    Plugins = 'cs-part,cs-compile'
    Kind    = 'cs'
    Target  = 'exe'
  }
  'renderer' = [ordered]@{
    Plugins  = 'resolve,treeshake,merge,render,verify'
    Kind     = 'script'
    External = 'main/utils/native,renderer/src/utils/text,shared/utils/schema,shared/utils/dpi,shared/utils/image,main/utils/config,main/utils/store,renderer/src/utils/themes,renderer/src/utils/theme-stub,main/utils/plugin/plugins,renderer/src/components/picker-geom'
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

# schema/theme.ps1 - what a theme file in themes\ may contain.
#
# The same field names as schema/clipboard.ps1, plus Target on a section: where the values
# of that section land in the parsed theme (Read-ThemeIni in lib/themes.ps1 reads it).
# There is no Ref here: a theme is read, never written back.
#
# A section the schema does not name is a plugin section: it restyles that plugin's
# ThemeSettings for this theme only, which is why ExtraSections allows any value.
@{
  Name        = 'theme'
  File        = 'themes\*.ini'
  Description = 'one theme: meta keys, a palette, font sizes, optional 96 dpi metrics and one section per plugin'
  Version     = 1
  Properties  = [ordered]@{
    Name        = @{ Type = 'string'; Default = ''; Description = 'name shown by `clipboard themes`, empty = the file name' }
    Description = @{ Type = 'string'; Default = ''; Description = 'one line, shown next to the name' }
    FontFamily  = @{ Type = 'string'; Default = ''; Description = 'UI font, empty = Segoe UI Variable Text then Segoe UI' }
    IconFamily  = @{ Type = 'string'; Default = ''; Description = 'icon font, empty = Segoe Fluent Icons then Segoe MDL2 Assets' }
  }
  Sections    = [ordered]@{
    palette = @{ Type = 'color'; Target = 'Palette'; Description = 'colour tokens: Surface, Field, FieldBorder, Text, Dim, Faint, Accent, AccentSoft, Border, SelBg, HoverBg, BadgeBg, BadgeText, KeyCapBg, KeyCapBorder, Mark, Warn (#RRGGBB or #AARRGGBB)' }
    fonts   = @{ Type = 'number'; Target = 'Fonts'; Description = 'point sizes: Body, Small, Tiny, Title, Icon, IconSmall, IconBig, IconTiny' }
    metrics = @{ Type = 'number'; Target = 'Metrics'; Description = '96 dpi design metrics, optional; a theme may override any key of the built-in table' }
  }
  ExtraSections = @{ Type = 'any'; Target = 'Plugin'; Description = 'a section named after a plugin restyles that plugin ThemeSettings for this theme' }
}

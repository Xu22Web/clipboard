# schema/plugins/item-marks.ps1 - the keys the item-marks plugin adds.
#
# Properties      -> clipboard.ini keys, merged into the settings schema as item-marks.<Key>
#                    when the plugin loads
# ThemeProperties -> theme-only look-and-feel, restyleable through a [item-marks] section in
#                    themes\*.ini; never an ini key of the settings file
@{
  Name            = 'item-marks'
  File            = 'clipboard.ini'
  Description     = 'pins, stars and highlights on top of the history'
  Version         = 1
  Properties      = [ordered]@{
    MaxPins          = @{ Type = 'int'; Minimum = 0; Maximum = 1000; Default = 50; Description = 'pinned entry cap, 0 = unlimited' }
    ClearKeepsPinned = @{ Type = 'bool'; Default = 1; Description = '1 = clear keeps pinned rows, 0 = clear wipes them too' }
    StickyPins       = @{ Type = 'bool'; Default = 1; Description = '1 = pinned rows stay on top while searching, 0 = the search hides them too' }
    StickyRows       = @{ Type = 'int'; Minimum = 0; Maximum = 50; Default = 3; Description = 'rows the sticky pins may take while searching, 0 = as many as fit' }
  }
  ThemeProperties = [ordered]@{
    StarGlyph    = @{ Type = 'string'; Default = [string][char]0xE735; Description = 'glyph shown for a starred entry' }
    StarColor    = @{ Type = 'color'; Default = '#FFC86E'; Description = 'colour of the star mark' }
    PinColor     = @{ Type = 'color'; Default = ''; Description = 'colour of the pin mark, empty = theme Mark colour' }
    EmphasisInk  = @{ Type = 'color'; Default = '#9FDDFF'; Description = 'ink of a highlighted row' }
    EmphasisFill = @{ Type = 'color'; Default = '#3360CDFF'; Description = 'fill of a highlighted row' }
  }
}

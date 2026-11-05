# schema/plugins/transform.ps1 - the keys the transform plugin adds.
#
# Properties -> clipboard.ini keys, merged into the settings schema as transform.<Key> when
#               the plugin loads. This plugin restyles nothing, so it declares no theme keys.
@{
  Name        = 'transform'
  File        = 'clipboard.ini'
  Description = 'rewrite text before it is pasted'
  Version     = 1
  Properties  = [ordered]@{
    Mode  = @{ Type = 'enum'; Enum = @('keep', 'text', 'upper', 'lower', 'camel', 'snake', 'kebab', 'title'); Default = 'keep'; Description = 'how a pasted entry is rewritten' }
    Modes = @{ Type = 'list'; Enum = @('text', 'upper', 'lower', 'camel', 'snake', 'kebab', 'title'); Default = 'text,upper,lower,camel,snake,kebab,title'; Description = 'modes offered in the context menu, comma separated (default: every mode)' }
    Trim  = @{ Type = 'bool'; Default = 1; Description = '1 = trim leading and trailing spaces of the result' }
  }
}

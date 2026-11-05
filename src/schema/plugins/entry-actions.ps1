# schema/plugins/entry-actions.ps1 - the keys the entry-actions plugin adds.
#
# Properties      -> clipboard.ini keys, merged into the settings schema as
#                    entry-actions.<Key> when the plugin loads
# ThemeProperties -> theme-only look-and-feel (this plugin restyles nothing yet)
@{
  Name            = 'entry-actions'
  File            = 'clipboard.ini'
  Description     = 'typing an entry and opening it'
  Version         = 1
  Properties      = [ordered]@{
    Detail       = @{ Type = 'enum'; Enum = @('short', 'full'); Default = 'full'; Description = 'kind: short = one summary line, full = the whole block' }
    PreviewChars = @{ Type = 'int'; Minimum = 20; Maximum = 400; Default = 100; Description = 'kind: characters of the entry shown in the preview' }
    Detect       = @{ Type = 'list'; Enum = @('json', 'xml', 'yaml', 'base64', 'color', 'ip', 'uuid', 'number', 'version', 'date', 'hash'); Default = 'json,xml,yaml,base64,color,ip,uuid,number,version,date,hash'; Description = 'kind: formats to sniff, comma separated' }
    ShowTargets  = @{ Type = 'bool'; Default = 1; Description = 'kind: 1 = break links, mail, paths and file lists into their parts' }
    Browser      = @{ Type = 'string'; Default = ''; Description = 'open: browser exe for http(s) links, empty = system default' }
    Reveal       = @{ Type = 'bool'; Default = 1; Description = 'open: 1 = reveal a picked file in Explorer instead of running it' }
  }
}

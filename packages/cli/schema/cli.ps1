# tools\schema\cli.ps1 - what cli.ini may contain.
#
# One table of flat keys: a "[global]" section prefixes the keys that follow it, so the key here
# is "global.OutDir" - the same rule the program's own ini files use. The tooling validates the
# file against this table before it acts on it (tools\utils\schema.ps1), so a missing key, an
# unknown key or a value of the wrong type stops the command instead of falling back to a
# silent default.
#
# A key must be present unless its spec says Optional: the command that reads it then has a
# fallback of its own (global.Workers left out means one worker per logical processor). A list
# key says for itself whether it may be empty: NonEmpty marks the ones where an empty value
# would mean "nothing at all" (the build would ship no file), so it stops the command instead.

@{
  Name        = 'cli'
  File        = 'cli.ini'
  Description = 'what this repository builds: one section per output, and nothing else'
  Version     = 3
  Keys        = [ordered]@{}
  # One section per output, the way a vite config names its targets: the plugin chain, the input,
  # where it lands, and the per-target overrides. The keys inside a section are checked by the
  # reader that uses them (Resolve-CliConfig), because a chain may carry any name it likes and a
  # section's key set is small enough to list there.
  DynamicKeys = [ordered]@{
    'target.' = @{ Type = 'string'; Description = 'one key of a [target.<name>] section' }
  }
}

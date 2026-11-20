# utils/hotkey.ps1 - turn a hotkey spec ("Ctrl+Alt+V") into modifiers plus a virtual key code.
#
# Pure table lookup: no Windows call, no keyboard state, no window. The runtime half - asking
# whether the modifiers are released - needs a WinForms type and lives in lib/modifiers.ps1.
# Splitting them here keeps the value check in utils/schema.ps1 from depending on the module
# that talks to the window station.

function Parse-Hotkey([string]$spec) {
  $mods = 0
  $parts = @($spec -split '\+')
  for ($i = 0; $i -lt $parts.Count - 1; $i++) {
    switch ($parts[$i].Trim().ToLower()) {
      'win'   { $mods = $mods -bor 0x0008 }
      'ctrl'  { $mods = $mods -bor 0x0002 }
      'alt'   { $mods = $mods -bor 0x0001 }
      'shift' { $mods = $mods -bor 0x0004 }
    }
  }
  $k = $parts[$parts.Count - 1].Trim().ToUpper()
  # Punctuation is read as the key that types it, not as the character it types: a backtick is
  # 0x60 as a character and 0xC0 as a key (0x60 is the numeric keypad's 0), a hyphen is 0x2D as
  # a character and 0xBD as a key (0x2D is Insert). Both spellings are read, because the settings
  # window writes the name and a file may hold the character; ',' and ';' cannot appear as
  # themselves - they separate the chords of a chain.
  $punct = @{
    'BACKTICK' = 0xC0; 'MINUS' = 0xBD; 'EQUALS' = 0xBB; 'LBRACKET' = 0xDB; 'RBRACKET' = 0xDD
    'BACKSLASH' = 0xDC; 'SEMICOLON' = 0xBA; 'QUOTE' = 0xDE; 'COMMA' = 0xBC; 'PERIOD' = 0xBE; 'SLASH' = 0xBF
    '`' = 0xC0; '-' = 0xBD; '=' = 0xBB; '[' = 0xDB; ']' = 0xDD; '\' = 0xDC; '.' = 0xBE; '/' = 0xBF
    "'" = 0xDE; '"' = 0xDE
  }
  $vk = 0
  if ($punct.ContainsKey($k)) { $vk = [int]$punct[$k] }
  elseif ($k.Length -eq 1) { $vk = [int][char]$k }
  elseif ($k -match '^F([1-9]|1[0-9]|2[0-4])$') { $vk = 0x70 + [int]$k.Substring(1) - 1 }
  elseif ($k -eq 'INSERT') { $vk = 0x2D }
  elseif ($k -eq 'DELETE') { $vk = 0x2E }
  elseif ($k -eq 'HOME') { $vk = 0x24 }
  elseif ($k -eq 'END') { $vk = 0x23 }
  elseif ($k -eq 'PGUP') { $vk = 0x21 }
  elseif ($k -eq 'PGDN') { $vk = 0x22 }
  elseif ($k -eq 'SPACE') { $vk = 0x20 }
  return @{ Mods = $mods; Vk = $vk }
}

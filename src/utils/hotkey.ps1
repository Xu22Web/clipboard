# utils/hotkey.ps1 - turn a hotkey spec ("Ctrl+Alt+V") into modifiers plus a virtual key code.
#
# Pure table lookup: no Windows call, no keyboard state, no window. The runtime half - asking
# whether the modifiers are released - needs a WinForms type and lives in lib/hotkey.ps1.
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
  $vk = 0
  if ($k.Length -eq 1) { $vk = [int][char]$k }
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

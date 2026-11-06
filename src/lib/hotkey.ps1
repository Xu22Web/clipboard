# lib/hotkey.ps1 - the runtime half of the hotkey: is every modifier released right now?
#
# Parsing the spec ("Ctrl+Alt+V" -> modifiers + virtual key) is pure table work and lives in
# utils/hotkey.ps1, so a value check can use it without loading anything that talks to
# Windows. This file answers the question that needs the real keyboard state, and is used by
# the resident daemon (before it injects a paste) and by `diag`.

function Test-Modifiers-Up {
  $m = [int][Windows.Forms.Control]::ModifierKeys
  $win = (([Cb.Win]::GetAsyncKeyState(0x5B) -band 0x8000) -ne 0) -or (([Cb.Win]::GetAsyncKeyState(0x5C) -band 0x8000) -ne 0)
  return (($m -eq 0) -and (-not $win))
}

# lib/modifiers.ps1 - the runtime half of the hotkey: is every modifier released right now?
#
# Parsing the spec ("Ctrl+Alt+V" -> modifiers + virtual key) is pure table work and lives in
# utils/hotkey.ps1, so a value check can use it without loading anything that talks to
# Windows. This file answers the question that needs the real keyboard state, and is used by
# the resident daemon before it injects a paste.

# The virtual keys a paste must not be sent under. The generic Ctrl/Shift/Alt cover both sides;
# the two Win keys have no generic code.
$script:ModifierKeys = @(0x11, 0x12, 0x10, 0x5B, 0x5C)

# Which modifier is still physically down, or 0. GetAsyncKeyState is asked instead of
# Control.ModifierKeys because the latter reads the calling thread's key state, which only
# holds keys that thread received: while another window has the foreground it answers
# "nothing is down" with Alt still held, and the paste goes in as Ctrl+Alt+V.
function Get-HeldModifier {
  foreach ($vk in @($script:ModifierKeys)) {
    $down = $false
    try { $down = (([Cb.Win]::GetAsyncKeyState([int]$vk) -band 0x8000) -ne 0) } catch { $down = $false }
    if ($down) { return [int]$vk }
  }
  return 0
}

function Test-Modifiers-Up { return ((Get-HeldModifier) -eq 0) }

local caps = ...

local body = [[
Sega Genesis / Mega Drive emulator, using the Gwenesis core.

ROMS
.md, .gen and .bin files, in /genesis on the SD card or in the Genesis app folder. Battery-backed saves are written to a .srm file next to the ROM.

SETTINGS
- Idle Skip: on by default and worth leaving on. If a game stalls at a fixed point, or crawls while its music keeps playing, turn it off and relaunch - that trades some speed for compatibility.
- Frameskip: drops frames to keep the pace up.

DEFAULT KEYS
D-pad - W A S D, or the trackball
B - M, or trackball click
A - N
C - K
Start - Enter

Change any of these in Controls.
]]

if not caps.keyboard then
    body = body .. [[

On this device you play on the on-screen pad or with a USB gamepad. The Touch button opens the pad's layout editor, and the Games > Gamepad app maps a gamepad's buttons. Hold the on-screen QUIT button for about a second to exit.]]
else
    body = body .. [[

Hold Alt and Backspace for about 1.5 seconds to quit back to the launcher.]]
end

return { body = body }

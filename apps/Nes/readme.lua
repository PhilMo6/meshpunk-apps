local caps = ...

local body = [[
NES emulator, using Nofrendo.

ROMS
.nes files, in /nes on the SD card or in the Nes app folder. No game ROMs are included - supply your own.

DEFAULT KEYS
D-pad - W A S D, or the trackball
A - M, or trackball click
B - N
Start - Enter
Select - Backspace

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

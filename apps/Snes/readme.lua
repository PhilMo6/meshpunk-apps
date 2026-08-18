local caps = ...

local body = [[
SNES emulator, using the Snes9x core from retro-go. Special-chip carts work too - SuperFX (Yoshi's Island) and Cx4 (Mega Man X2) - though the heaviest SuperFX games run slowly.

ROMS
.smc, .sfc and .fig files, in /snes on the SD card or in the Snes app folder. Battery saves are written to a .srm file next to the ROM.

SETTINGS
- Renderer: the one to reach for per game. Speed is the default and is much faster; Accuracy redraws the slower way some games need if the picture looks wrong.

The Speed renderer needs a large block of free memory for its worker. If it cannot get one the launcher says so, because otherwise you would silently get the slower path anyway.

DEFAULT KEYS
D-pad - W A S D, or the trackball
A - M, or trackball click
B - N
X - K
Y - J
L - Q
R - P
Start - Enter
Select - Backspace

Change any of these in Controls.
]]

if not caps.keyboard then
    body = body .. [[

On this device you play on the on-screen pad or with a USB gamepad. Twelve buttons is a lot for a screen, so it is worth opening the Touch button's layout editor and arranging them to suit your hands - or map a USB gamepad in the Games > Gamepad app. Hold the on-screen QUIT button for about a second to exit.]]
else
    body = body .. [[

Hold Alt and Backspace for about 1.5 seconds to quit back to the launcher.]]
end

return { body = body }

local caps = ...

local body = [[
Neo Geo Pocket and Neo Geo Pocket Color emulator, using the RACE core.

ROMS
.ngp and .ngc files, in /ngpc on the SD card or in the NeoGeoPocket app folder.

SETTINGS
- Sound: turns the game's sound on or off entirely.
- Video rate: Smooth (35 fps) or Speed (25 fps). Fewer video frames leave more headroom for game speed, so switch to Speed if a game runs badly.

DEFAULT KEYS
D-pad - W A S D, or the trackball
A - M, or trackball click
B - N
Option - Enter

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

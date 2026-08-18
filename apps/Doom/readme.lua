local caps = ...

local body = [[
Doom, using doomgeneric. Music and sound effects are included; the game data is not.

WADS
Place a .wad in /doom on the SD card or in the Doom app folder. Freedoom wads work, as do the original ones. A PWAD needs a valid IWAD alongside it. Large wads take a while to load.

SETTINGS
- Music: OFF or ON.
- SFX: OFF or ON.

DEFAULT KEYS
Forward - W, or trackball up
Backward - S, or trackball down
Strafe left - A
Strafe right - D
Turn left - J, or trackball left
Turn right - L, or trackball right
Fire - Space, or trackball click
Use / open - E
Run - Shift
Menu OK - Enter
Menu / Esc - Backspace
Weapons 1-9 - Z X C V B N M, then T and G

Change any of these in Controls.
]]

if not caps.keyboard then
    body = body .. [[

Doom wants more buttons than most games here, so arrange the on-screen pad before you play - the Touch button opens its layout editor. A USB gamepad works too, mapped in the Games > Gamepad app. Hold the on-screen QUIT button for about a second to exit.]]
else
    body = body .. [[

Hold Alt and Backspace for about 1.5 seconds to quit back to the launcher.]]
end

return { body = body }

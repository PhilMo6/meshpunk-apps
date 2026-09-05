local caps = ...

local body = [[
Game Boy and Game Boy Color emulator, using the gnuboy core from retro-go.

ROMS
.gb and .gbc files, in /gb on the SD card or in the GameBoy app folder. No BIOS or game ROMs are included - supply your own.

SETTINGS
- GB palette: colour scheme for original Game Boy games. Game Boy Color titles carry their own colours and ignore this.
- Screen: how the picture fills the display.
- Resume session: pick up where you left off instead of starting the ROM fresh.

Battery saves are written to a .sav file next to the ROM.

CART CLOCK
Games with a cartridge clock (Pokemon Gold, Silver and Crystal) keep it running between sessions: on launch the clock jumps forward by the time the game was closed, using the device clock - set by GPS, the mesh, or Settings > Time. If the device clock is not set, the cart clock only runs during play.

DEFAULT KEYS
D-pad - W A S D, or the trackball
A - M, or trackball click
B - N
Start - Enter
Select - Space

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

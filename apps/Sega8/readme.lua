local caps = ...

local body = [[
Sega 8-bit emulator - Game Gear, Master System and SG-1000 in one app, using the SMS Plus core. The file extension picks the system, and the launcher shows which one a ROM will run as before you start it.

ROMS
.gg (Game Gear), .sms (Master System) and .sg (SG-1000) files, in /sega8 on the SD card or in the Sega8 app folder.

SETTINGS
- Scale: Fit, Native or Stretch. Game Gear games have a smaller native picture than Master System ones, so Native looks small for those and Fit is usually the one you want.

DEFAULT KEYS
D-pad - W A S D, or the trackball
2 - M, or trackball click
1 - N
Start - Enter
Pause - Backspace

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

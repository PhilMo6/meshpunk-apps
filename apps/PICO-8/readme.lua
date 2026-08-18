local caps = ...

local body = [[
PICO-8 fantasy console, using the fake08 core. It runs carts made for PICO-8; it is not the official PICO-8 and includes no carts.

CARTS
.p8 and .p8.png cart files, in /p8carts on the SD card or in the PICO-8 app folder. A plain .png is not a cart - the double extension is PICO-8's own cart-image format.

DEFAULT KEYS
D-pad - W A S D, or the trackball
O - Z, or trackball click
X - X, or Space
Pause - Enter, or P

O and X are what PICO-8 calls its two buttons. Change any of these in Controls.
]]

if not caps.keyboard then
    body = body .. [[

On this device you play on the on-screen pad or with a USB gamepad. The Touch button opens the pad's layout editor, and the Games > Gamepad app maps a gamepad's buttons. Hold the on-screen QUIT button for about a second to exit.]]
else
    body = body .. [[

Hold Alt and Backspace for about 1.5 seconds to quit back to the launcher.]]
end

return { body = body }

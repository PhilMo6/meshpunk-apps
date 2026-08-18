local caps = ...

local body = [[
Jet 3D is a 3D game engine rather than an emulator: the games are built for it, and the engine is loaded on demand when you pick one.

GAMES
Game folders in /jet3d on the SD card, or in the Jet 3D app folder. The launcher lists what it finds and remembers your last choice.

DEFAULT KEYS
Up / Thrust - W, or trackball up
Down / Use item - S, or trackball down
Left - A
Right - D
Thrust / Select - Space
Pause / Back - P
Restart - R

Controls bind to game ACTIONS, not to keys: games name the action they want, so what you set here holds in every Jet 3D game rather than being per-game.
]]

if not caps.keyboard then
    body = body .. [[

On this device you play on the on-screen pad or with a USB gamepad. The Touch button opens the pad's layout editor, and the Games > Gamepad app maps a gamepad's buttons. Hold the on-screen QUIT button for about a second to exit.]]
else
    body = body .. [[

Hold Alt and Backspace for about 1.5 seconds to quit back to the launcher.]]
end

return { body = body }

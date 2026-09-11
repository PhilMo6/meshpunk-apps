local caps = ...

local body = [[
Doom, using doomgeneric. Music and sound effects are included; the game data is not.

WADS
Place a .wad in /doom on the SD card or in the Doom app folder. Freedoom wads work, as do the original ones. A PWAD needs a valid IWAD alongside it. Large wads take a while to load.

SETTINGS
- Music: OFF or ON.
- SFX: OFF or ON.

MULTIPLAYER
Two to four decks, over a USB cable between two decks or over a WiFi network they all share (a router or a phone hotspot). Every choice is made on the Multiplayer screen; the game only shows what it is doing while it connects.
- Host a game: pick the number of players, co-op or deathmatch, skill, start level, monsters, respawn and a time limit, then Start. The game waits until that many players are in and starts by itself. The screen shows the host's WiFi address. The start level list is read from the selected WAD, so it holds that WAD's own levels and a mod's levels when you play one.
- Join over USB cable: connect the two decks with the cable (the launcher shows USB link: connected), then Start.
- Join over WiFi (search): the game looks for a host on the network by itself.
- Join over WiFi (address): type the host's address as shown on its screen.
Order does not matter: a joiner keeps looking for the host for two minutes. The Menu key backs out of any wait.
Both decks need this app version and a firmware that supports it. Hotspots that keep their clients apart block WiFi play. The host's settings apply to everyone; use the same WAD on every deck.

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

local caps = ...

local body = [[
A full 386 PC - VGA, Adlib, Sound Blaster and a PS/2 mouse - running real DOS, using the tiny386 core with SeaBIOS. No proprietary ROMs are involved.

DISKS AND GAMES
Disk images and game folders go in /dos on the SD card. If you have no disks, the Download DOS button fetches ready-made FreeDOS boot disks over WiFi:

- freedos-a.img - boot floppy for A:, start here
- freedos-c.img - bootable hard disk for C:, leaving A: free for game disks
- the -nb versions - the same two without SET BLASTER, for games that misbehave when they find a sound card

Put a boot disk in A: (or C:), then either add game .img disks in A: or point C: at a folder of games. A folder becomes a real writable C: drive, so installers run and save games persist.

The Boot button lists every setting it will start with before it starts, including whether the trackball acts as a mouse or as arrow keys.

WHEN A GAME MISBEHAVES
- Audio rate: trades pitch for emulation speed and cures crackle. 0.5 is the usual answer.
- SB digital: can fake a card fault, so a game switches its own digitised sound off.
- Timer cap: keeps games alive that pace their sound off the system timer.

The settings screen also carries CPU class, Native res, Render gate, Text smoothing, Click latch, Folder C: writes and Trackball. Each has a ? button next to it explaining what it does and when to reach for it - those are worth reading rather than guessing.

TYPING AT THE DOS PROMPT
Sym + key - numbers and symbols
Alt + number - F1 to F10
Shift + Bksp - Esc
Alt + Enter - turns your key bindings off and on, so the prompt types normally (W A S D are arrow keys by default)

DEFAULT KEYS
Arrows - W A S D
Esc, Ctrl, Alt, Tab, Del, F1-F10 and right mouse button are all bindable in Controls but start unassigned, since a DOS game decides for itself what it wants.
]]

if not caps.keyboard then
    body = body .. [[

On this device, use the on-screen keyboard for the DOS prompt. Play on the on-screen pad or with a USB gamepad - the Touch button edits the pad layout, and the Games > Gamepad app maps a gamepad. Hold the on-screen QUIT button for about a second to exit.]]
else
    body = body .. [[

Hold Alt and Backspace for about 1.5 seconds to quit back to the launcher.]]
end

return { body = body }

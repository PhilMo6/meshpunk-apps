local _, dev = ...

local body = [[
MP3 player with a tag-based library.

Put MP3s in /Music on the SD card. Auto-organize by tags sorts tagged files into /Music/Artist/Album for you. Playlists live in /Music/Playlists - Add current song and Add songs build them from what you are listening to.

Background playback: music keeps going when you leave the app, so you can read messages or play a game while it plays. It appears in the launcher's background row, which is also where you stop it.
]]

if dev.audio == "buzzer" then
    body = body .. [[

This device has a buzzer rather than a speaker, so it cannot play music on its own. Attach a USB audio adapter - see the USB accessories page in the guide - and the player will come through that.]]
end

return { body = body }

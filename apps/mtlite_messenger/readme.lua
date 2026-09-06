return { body = [[
Messaging for the MTLite LoRa protocol (compatible with Meshtastic networks). Works only while MTLite is the active protocol - switch in Settings > Lora.

- The inbox lists every channel and direct-message thread, newest first, with unread counts. Tap a row to open its chat.
- Channels (up to 8) are managed in the Channels view: add one by name with an optional base64 PSK - AQ== is the well-known default key, a blank PSK inherits the primary's, and a full 16- or 32-byte base64 key makes a private channel. Set PSK on the primary row is how you join a network with a private primary channel. Channel edits apply immediately (nothing retunes).
- The URL button shares or joins a whole network the official way: Copy URL / Show QR produce the meshtastic.org link other apps scan or paste, and Import from clipboard applies a pasted link - it REPLACES all channels plus the radio settings (region, preset, frequency), which retune at the reboot it offers. Long-press any add field for copy and paste.
- Chats page their history straight from disk - scroll up for older messages, no matter how long the thread. Long-press a message for its details, a reply mention, or copy.
- Nodes lists every node heard on air. Tap one for its details, to open a direct-message thread, or to request its info.
- An unidentified node (shown by its !id) can be asked to introduce itself, but Meshtastic devices refuse the request if they heard you in the last 12 hours - the answer then arrives with their next scheduled broadcast instead. Triggering a user-info exchange FROM the other device identifies it immediately. Once learned, a node stays known forever.
- Direct messages are end-to-end encrypted and confirmed: your bubble shows sent, then delivered or failed. Sending needs the peer's key, which arrives with their NodeInfo - a fresh peer may take a few minutes to become messageable (the chat requests it automatically).
- New traffic appears within a couple of seconds - the app polls the store; there is no push channel in MTLite yet.

History, unread counts and notifications ride the same storage machinery the MeshCore Messenger uses, but in MTLite's own folder - the two protocols never mix conversation files. Everything survives app switches, games and reflashes (on SD).]] }

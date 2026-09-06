return { body = [[
Notification settings for the MTLite LoRa protocol. Editable under any protocol: while MTLite runs, a picked mode applies immediately; otherwise it is written to MTLite's notify file and takes effect when it next boots.

- Direct messages always alert and always appear in the top-bar bell log.
- Each channel has its own mode, applied immediately when you pick it: Off never alerts; Mentions only alerts when a message contains @[your name] (the default); All messages alerts on everything.
- A muted channel still counts unread messages - only the melody and keyboard blink are silenced.
- The sound and keyboard-blink master switches cover every protocol and live in Settings > Alerts.

MTLite keeps its own notify file - nothing here touches the MeshCore channel modes.]] }

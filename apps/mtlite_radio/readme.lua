return { body = [[
Settings for the MTLite LoRa protocol (compatible with Meshtastic networks). Editable under any protocol: while MTLite runs, saves apply to it directly; otherwise they are written to its config file and take effect when it next boots. Switch protocols in Settings > Lora.

- Nothing applies until you press Save changes. Pick values from the dropdowns, edit the names, then Save - the status line lists what was saved. This confirmation step exists so a stray tap can never silently retune the radio.
- Region picks the band plan (US, EU_868, ANZ and so on). Preset picks the modem speed (LongFast is the network default). Both retune the radio at boot - reboot after saving them.
- Role: Client relays mesh traffic for others and cancels its relay when it hears another node get there first (the normal citizen setting); Client Mute sends and receives but never relays; Router Late always relays, deliberately after everyone else - the gap-filler setting for a well-placed node.
- NodeInfo every / Position every set the broadcast cadence; the defaults are the stock Meshtastic ones (NodeInfo 3 h, Position 1 h). Shorter appears faster on other people's node lists at the cost of airtime. Position still honors the Location precision setting - Off there silences it entirely.
- OK to MQTT marks your packets as allowed onto the internet by MQTT bridge nodes. No (the default) asks bridges to keep your traffic radio-only.
- Location sets how precisely your position is shared: Exact, blurred to a chosen area (~370 m up to ~23 km), or Off. Peers see an accuracy circle, not your exact point, when blurred.
- Node and channel info at the top shows this device's id, active channel and exact frequency.
- Freq slot pins the channel slot within the region (0 = automatic, derived from the primary channel name); Freq override sets an explicit frequency in MHz (0 = off, wins over the slot). Both retune at boot.
- Node names moved to MTLite > Identity (with the keys they broadcast alongside).
- Channels are managed in the MTLite Messenger's Channels view (like MeshCore's).

MTLite keeps its own settings file - nothing here touches the MeshCore radio settings.]] }

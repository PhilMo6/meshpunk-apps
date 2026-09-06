return { body = [[
This node's Meshtastic identity: its names, node id and x25519 keypair. Works only while MTLite is the active protocol - switch in Settings > Lora.

- Name and Short name identify this node to others; they apply on Save names and go out with the next NodeInfo broadcast (or immediately via Broadcast node info in the Messenger's My Node card).
- The node id derives from the public key - peers know this node by both.
- The public key is what peers need to send you encrypted direct messages; it travels inside your NodeInfo broadcasts automatically.
- Show Key reveals the private key for backup. Anyone holding it can read your DMs and impersonate this node - treat it accordingly. Hold the key area for copy and paste.
- Pasting (or typing) a different key reveals a Set button: it imports that private key as this node's identity and re-derives the public key - how you restore a backup or move an identity between devices. Takes over at reboot, like New Identity.
- New Identity generates a fresh keypair. The old key is lost forever and the node id changes, so peers will see you as a brand-new node. The new identity takes over at the next reboot - the prompt offers it.]] }

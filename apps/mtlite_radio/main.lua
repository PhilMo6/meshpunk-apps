-- MTLite Radio — settings for the mtlite LoRa protocol (Meshtastic-compatible).
-- All values flow through _lora_proto_config_get/_lora_proto_config_set with the
-- "mtlite" protocol id: while mtlite is running they go through its vtable;
-- under any other protocol the firmware edits mtlite's own cfg file, which
-- the module re-validates at its next boot — settings are never gated on the
-- active protocol. NOTHING applies until Save: changes stage locally, so a
-- stray tap can never silently retune the radio (a cycle-button once flipped
-- the region on a single tap). List settings are dropdowns for the same
-- reason. Region/preset retune the radio at boot; role/location/names apply
-- live once saved (or at the next mtlite boot when it is not running).
local lvgl  = require("lvgl")
local apps  = require("lib/apps")
local nav   = require("lib/nav")
local theme = require("lib/theme")

local SID = "mtlite"
local active = ((type(_lora_proto) == "function") and _lora_proto() or "meshcore") == SID

local root = apps.new_root()
root:set { w = lvgl.HOR_RES(), h = lvgl.VER_RES(), pad_all = 0, border_width = 0, bg_opa = 0 }
root:clear_flag(lvgl.FLAG.SCROLLABLE)

theme.show_background()

local content = root:Object {
    flex = { flex_direction = "row", flex_wrap = "wrap" },
    w = lvgl.HOR_RES(), h = lvgl.VER_RES(),
    border_width = 0, pad_all = 6, bg_opa = 0,
}
nav.replace(content)

content:Label { text = "MTLite Radio", w = lvgl.PCT(70), h = 26 }
local back_btn = content:Button { w = 50, h = 22 }
back_btn:Label { text = "Home", align = lvgl.ALIGN.CENTER }

local status = content:Label { text = "", w = lvgl.PCT(100), h = 16 }

local function cget(k) return _lora_proto_config_get(k, SID) or "?" end

-- Node id / channel / frequency are live values the running stack computes;
-- offline there is nothing to show but where the edits will land.
content:Label {
    text = active
        and ("Node " .. cget("node_id") .. "  ch #" .. cget("channel")
             .. "  " .. cget("freq") .. " MHz")
        or "MTLite is not running - saves apply at its next boot",
    w = lvgl.PCT(100), h = 16,
}

-- Staged changes: key -> value string, applied only by the Save button.
local pending = {}
local function stage(key, v, desc)
    pending[key] = tostring(v)
    status.text = desc .. " (unsaved)"
end

-- Dropdown row for a list setting. `values` maps option index -> config
-- value (nil = the index itself). Selection only STAGES.
local function dd_row(label, key, opts_tbl, values)
    content:Label { text = label, w = lvgl.PCT(40), h = 30 }
    local dd = content:Dropdown {
        options = table.concat(opts_tbl, "\n"),
        w = lvgl.PCT(55), h = 30,
    }
    local cur = tonumber(cget(key)) or 0
    local sel = 0
    if values then
        for i, v in ipairs(values) do if v == cur then sel = i - 1 break end end
    else
        sel = cur
    end
    dd:set({ selected = sel })
    dd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
        local idx = dd:get("selected")
        local v = values and values[idx + 1] or idx
        stage(key, v, label .. ": " .. opts_tbl[idx + 1])
    end)
end

dd_row("Region", "region",
    { "US", "EU_433", "EU_868", "CN", "JP", "ANZ", "ANZ433",
      "KR", "TW", "IN", "NZ_865", "TH", "RU", "UNSET" })
dd_row("Preset", "preset",
    { "LongFast", "LongSlow", "LongMod", "LongTurbo", "MediumFast",
      "MediumSlow", "ShortFast", "ShortSlow", "ShortTurbo" })
dd_row("Role", "role", { "Client", "Client Mute", "Router Late" })
dd_row("TX power", "tx_power",
    { "10 dBm", "14 dBm", "17 dBm", "20 dBm", "22 dBm" },
    { 10, 14, 17, 20, 22 })
dd_row("Hop limit", "hop_limit", { "1", "2", "3", "5", "7" }, { 1, 2, 3, 5, 7 })
dd_row("Location", "pos_precision",
    { "Exact", "~370 m", "~3 km", "~12 km", "~23 km", "Off" },
    { 32, 16, 13, 11, 10, 0 })
dd_row("NodeInfo every", "nodeinfo_mins",
    { "15 min", "30 min", "1 h", "3 h (stock)", "6 h" },
    { 15, 30, 60, 180, 360 })
dd_row("Position every", "pos_mins",
    { "5 min", "15 min", "30 min", "1 h (stock)", "3 h" },
    { 5, 15, 30, 60, 180 })
dd_row("OK to MQTT", "ok_to_mqtt", { "No", "Yes" })

-- Frequency slot (1-based; 0 = auto, the hash of the primary channel name)
-- and an explicit override in MHz (0 = off; wins over the slot). Both retune
-- at boot, staged like everything else. The live slot line shows what the
-- running stack computed.
content:Label {
    text = active
        and ("Slot in use: " .. cget("freq_slot_active") .. " of " .. cget("freq_slots"))
        or "Slot facts show while MTLite is running.",
    w = lvgl.PCT(100), h = 16,
}
content:Label { text = "Freq slot (0=auto)", w = lvgl.PCT(40), h = 30 }
local slot_ta = content:Textarea {
    one_line = true, text = cget("freq_slot"), w = lvgl.PCT(55), h = 30,
}
slot_ta:clear_flag(lvgl.FLAG.SCROLLABLE)
content:Label { text = "Freq override MHz (0=off)", w = lvgl.PCT(40), h = 30 }
local ovr_ta = content:Textarea {
    one_line = true, text = cget("freq_override"), w = lvgl.PCT(55), h = 30,
}
ovr_ta:clear_flag(lvgl.FLAG.SCROLLABLE)

-- Save: the ONLY place anything is applied and persisted.
local save_btn = content:Button { w = lvgl.PCT(100), h = 32 }
save_btn:Label { text = "Save changes", align = lvgl.ALIGN.CENTER }
save_btn:onClicked(function()
    local sl = slot_ta.text or ""
    if sl ~= "" and sl ~= cget("freq_slot") then pending.freq_slot = sl end
    local ov = ovr_ta.text or ""
    if ov ~= "" and ov ~= cget("freq_override") then pending.freq_override = ov end

    local ok_n, fail_n, rf = 0, 0, false
    for k, v in pairs(pending) do
        if _lora_proto_config_set(k, v, SID) then
            ok_n = ok_n + 1
            if k == "region" or k == "preset" or k == "freq_slot"
                or k == "freq_override" then rf = true end
        else
            fail_n = fail_n + 1
        end
    end
    pending = {}
    if ok_n + fail_n == 0 then
        status.text = "No changes to save"
    elseif not active then
        status.text = "Saved " .. ok_n
            .. (fail_n > 0 and (", rejected " .. fail_n) or "")
            .. " - applies at MTLite's next boot"
    else
        status.text = "Saved " .. ok_n
            .. (fail_n > 0 and (", rejected " .. fail_n) or "")
            .. (rf and " - reboot to retune the radio" or "")
    end
end)

content:Label {
    text = active
        and "Nothing applies until Save. Region, preset and the frequency settings retune the radio at boot - reboot after saving them. Node names live in MTLite > Identity."
        or "Nothing applies until Save. Saved values are written to MTLite's config file and take effect when it next runs.",
    w = lvgl.PCT(100),
}


back_btn:onClicked(function()
    apps.go_home()
end)

return root

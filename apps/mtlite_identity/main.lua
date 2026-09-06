-- MTLite Identity — the node's x25519 keypair (Meshtastic PKI): public and
-- private key display and regeneration. Key material lives in the module
-- (pki.bin, both locations), so this app needs MTLite RUNNING; a regenerated
-- keypair lands on disk only and takes over at reboot (the node id derives
-- from the public key, so a live swap would break the running session).
local lvgl  = require("lvgl")
local utils = require("lib/utils")
local apps  = require("lib/apps")
local nav   = require("lib/nav")
local theme = require("lib/theme")
local reboot_prompt = require("lib/reboot_prompt")
local clipboard = require("lib/clipboard")

-- MTLite-only app: under any other LoRa protocol, show the notice and bail.
if apps.proto_gate("mtlite") then return end

local SID = "mtlite"

local function cget(k)
    local ok, v = pcall(_lora_proto_config_get, k, SID)
    return (ok and v) or ""
end

local root = apps.new_root()
root:set { w = lvgl.HOR_RES(), h = lvgl.VER_RES(), pad_all = 0, border_width = 0, bg_opa = 0 }
root:clear_flag(lvgl.FLAG.SCROLLABLE)

-- Themed wallpaper behind this (lightweight) screen; containers below are transparent.
theme.show_background()

local content = root:Object {
    flex = { flex_direction = "row", flex_wrap = "wrap" },
    w = lvgl.HOR_RES(), h = lvgl.VER_RES(),
    border_width = 0, pad_all = 6, bg_opa = 0,
}
nav.replace(content, { flags = nav.ROLLOVER + nav.SCROLL_FIRST })

-- Title
content:Label { text = "Identity", w = lvgl.PCT(70), h = 26 }
local back_btn = content:Button { w = 50, h = 22 }
back_btn:Label { text = "Home", align = lvgl.ALIGN.CENTER }

local status = content:Label { text = "", w = lvgl.PCT(100), h = 16 }

content:Label { text = "Node id: " .. cget("node_id"), w = lvgl.PCT(100), h = 16 }

-- Node names (identity, not radio): applied on save, announced with the
-- next NodeInfo broadcast (or Broadcast node info in the Messenger).
content:Label { text = "-- Name --", w = lvgl.PCT(100), h = 16 }
content:Label { text = "Name", w = lvgl.PCT(40), h = 30 }
local name_ta = content:Textarea {
    one_line = true, text = cget("long_name"), w = lvgl.PCT(55), h = 30,
}
name_ta:clear_flag(lvgl.FLAG.SCROLLABLE)
content:Label { text = "Short", w = lvgl.PCT(40), h = 30 }
local short_ta = content:Textarea {
    one_line = true, text = cget("short_name"), w = lvgl.PCT(55), h = 30,
}
short_ta:clear_flag(lvgl.FLAG.SCROLLABLE)

local save_names = content:Button { w = lvgl.PCT(60), h = 30 }
save_names:Label { text = "Save names", align = lvgl.ALIGN.CENTER }
save_names:onClicked(function()
    local n_ok, n_fail = 0, 0
    local nm = name_ta.text or ""
    if nm ~= "" and nm ~= cget("long_name") then
        local okc, res = pcall(_lora_proto_config_set, "long_name", string.sub(nm, 1, 39), SID)
        if okc and res then n_ok = n_ok + 1 else n_fail = n_fail + 1 end
    end
    local sn = short_ta.text or ""
    if sn ~= "" and sn ~= cget("short_name") then
        local okc, res = pcall(_lora_proto_config_set, "short_name", string.sub(sn, 1, 4), SID)
        if okc and res then n_ok = n_ok + 1 else n_fail = n_fail + 1 end
    end
    if n_ok + n_fail == 0 then
        status.text = "No name changes"
    else
        status.text = "Saved " .. n_ok
            .. (n_fail > 0 and (", rejected " .. n_fail) or "")
            .. " - out with the next NodeInfo"
    end
end)

-- Public key display (64 hex chars wrap: size to content, never clip).
content:Label { text = "-- Public Key --", w = lvgl.PCT(100), h = 16 }
content:Label { text = cget("public_key"), w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT }

-- Private key: hidden behind a Show button. The textarea is created HERE
-- (hidden) so it reveals in place next to the button — appending it on tap
-- would land it at the layout's end, below the fold.
content:Label { text = "-- Private Key --", w = lvgl.PCT(100), h = 16 }

local btn_export = content:Button { w = lvgl.PCT(48), h = 30 }
local export_lbl = btn_export:Label { text = "Show Key", align = lvgl.ALIGN.CENTER }
-- Set: appears when the shown text differs from the current key (typed or
-- pasted) — imports it as THIS node's private key, public key re-derived.
local btn_set = content:Button { w = lvgl.PCT(48), h = 30 }
btn_set:Label { text = "Set", align = lvgl.ALIGN.CENTER }
btn_set:add_flag(lvgl.FLAG.HIDDEN)
-- Sized to content so a long key is never cut off; grows while editing.
local key_ta = content:Textarea {
    password_mode = false, one_line = false,
    text = "", w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
}
key_ta:add_flag(lvgl.FLAG.HIDDEN)

local key_shown = false
local shown_key = ""

local function refresh_set_btn()
    local t = key_ta.text or ""
    if key_shown and t ~= "" and t ~= shown_key then
        btn_set:clear_flag(lvgl.FLAG.HIDDEN)
    else
        btn_set:add_flag(lvgl.FLAG.HIDDEN)
    end
end

btn_export:onClicked(function()
    key_shown = not key_shown
    if key_shown then
        shown_key = cget("private_key")
        key_ta.text = shown_key
        key_ta:clear_flag(lvgl.FLAG.HIDDEN)
        export_lbl.text = "Hide Key"
    else
        key_ta.text = ""
        shown_key = ""
        key_ta:add_flag(lvgl.FLAG.HIDDEN)
        export_lbl.text = "Show Key"
    end
    refresh_set_btn()
end)

key_ta:onevent(lvgl.EVENT.VALUE_CHANGED, refresh_set_btn)

btn_set:onClicked(function()
    local t = key_ta.text or ""
    local okc, res = pcall(_lora_proto_config_set, "set_private_key", t, SID)
    if okc and res then
        status.text = "Private key set - public key re-derived"
        reboot_prompt.show("New identity active after reboot")
    else
        status.text = "Rejected (need 64 hex chars)"
    end
end)

-- Hold the key area for copy/paste (the Messenger input-row clipboard menu).
key_ta:onevent(lvgl.EVENT.LONG_PRESSED, function()
    local overlay = root:Object {
        w = lvgl.HOR_RES(), h = lvgl.VER_RES(), x = 0, y = 0,
        bg_color = "#000000", bg_opa = 128, border_width = 0, pad_all = 0,
    }
    overlay:clear_flag(lvgl.FLAG.SCROLLABLE)
    overlay:add_flag(lvgl.FLAG.CLICKABLE)
    local function close()
        nav.pop()
        overlay:delete()
    end
    local pbox = overlay:Object {
        w = lvgl.HOR_RES() - 40, h = lvgl.SIZE_CONTENT, align = lvgl.ALIGN.CENTER,
        bg_color = "#333333", radius = 6,
        border_width = 1, border_color = "#555555", pad_all = 8,
        flex = { flex_direction = "column", flex_wrap = "nowrap" },
    }
    nav.push(pbox)
    pbox:Label { text = "Clipboard", w = lvgl.PCT(100) }

    local copy_b = pbox:Button { w = lvgl.PCT(100), h = 28 }
    copy_b:Label { text = "Copy key", align = lvgl.ALIGN.CENTER }
    copy_b:onevent(lvgl.EVENT.RELEASED, function()
        clipboard.copy(key_ta.text or "")
        close()
    end)

    local paste_b = pbox:Button { w = lvgl.PCT(100), h = 28 }
    paste_b:Label { text = "Paste", align = lvgl.ALIGN.CENTER }
    paste_b:onevent(lvgl.EVENT.RELEASED, function()
        if clipboard.has() then
            key_ta.text = clipboard.paste()
            refresh_set_btn()
        end
        close()
    end)

    local cancel_b = pbox:Button { w = lvgl.PCT(100), h = 26 }
    cancel_b:Label { text = "Cancel", align = lvgl.ALIGN.CENTER }
    cancel_b:onevent(lvgl.EVENT.RELEASED, close)
end)

-- Regenerate section
content:Label { text = "-- Generate New --", w = lvgl.PCT(100), h = 16 }

local btn_gen = content:Button { w = lvgl.PCT(60), h = 30 }
btn_gen:Label { text = "New Identity", align = lvgl.ALIGN.CENTER }

btn_gen:onClicked(function()
    local overlay = root:Object {
        w = lvgl.HOR_RES(), h = lvgl.VER_RES(),
        x = 0, y = 0, bg_opa = 200, border_width = 0, pad_all = 0,
    }
    overlay:clear_flag(lvgl.FLAG.SCROLLABLE)
    overlay:add_flag(lvgl.FLAG.CLICKABLE)  -- modal
    local box = overlay:Object {
        w = 280, h = 150, align = lvgl.ALIGN.CENTER,
        border_width = 1, pad_all = 10,
        flex = { flex_direction = "row", flex_wrap = "wrap" },
    }
    box:clear_flag(lvgl.FLAG.SCROLLABLE)
    nav.push(box)

    box:Label { text = "WARNING", w = lvgl.PCT(100), h = 20 }
    box:Label { text = "Generate a new keypair?", w = lvgl.PCT(100), h = 18 }
    box:Label { text = "Old key is LOST forever and the", w = lvgl.PCT(100), h = 18 }
    box:Label { text = "node id CHANGES for all peers!", w = lvgl.PCT(100), h = 18 }

    local yes = box:Button { w = lvgl.PCT(48), h = 32 }
    yes:Label { text = "Confirm", align = lvgl.ALIGN.CENTER }
    local no = box:Button { w = lvgl.PCT(48), h = 32 }
    no:Label { text = "Cancel", align = lvgl.ALIGN.CENTER }
    no:onClicked(function()
        nav.pop()
        overlay:delete()
    end)
    yes:onClicked(function()
        nav.pop()
        overlay:delete()
        local okc, res = pcall(_lora_proto_config_set, "regenerate_identity", "1", SID)
        if okc and res then
            status.text = "New keypair generated"
            reboot_prompt.show("New identity active after reboot")
        else
            status.text = "Regeneration failed"
        end
    end)
end)

-- Back
back_btn:onClicked(function()
    apps.go_home()
end)

return root

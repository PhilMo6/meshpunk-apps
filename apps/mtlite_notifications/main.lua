-- MTLite Notify — per-channel notification modes for the mtlite LoRa protocol.
-- Same model as MeshCore's Settings > Notifications: DMs always alert;
-- each channel is Off / Mentions only (@[name], the default) / All messages.
-- Modes flow through _lora_proto_config_get/_lora_proto_config_set with the "mtlite"
-- protocol id ("notify_ch:<name>" keys): the running module applies them live,
-- and under any other protocol the firmware edits mtlite's notify file for
-- its next boot — settings are never gated on the active protocol. Unlike
-- MTLite Radio there is no Save button: a dropdown pick is a deliberate
-- two-tap gesture and a wrong mode is harmless (nothing retunes), so changes
-- apply immediately. The global sound / keyboard-blink switches are
-- protocol-agnostic and stay in Settings > Notifications.
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

content:Label { text = "MTLite Notify", w = lvgl.PCT(70), h = 26 }
local back_btn = content:Button { w = 50, h = 22 }
back_btn:Label { text = "Home", align = lvgl.ALIGN.CENTER }

local status = content:Label { text = "", w = lvgl.PCT(100), h = 16 }

content:Label {
    text = "Direct messages always alert. Channels:",
    w = lvgl.PCT(100), h = 16,
}

-- Mode dropdown per channel. The option index IS the stored mode
-- (0 Off, 1 Mentions, 2 All), so no mapping table is needed.
local MODE_OPTS = "Off\nMentions only\nAll messages"
local MODE_NAMES = { [0] = "Off", [1] = "Mentions only", [2] = "All messages" }

local function mode_row(name)
    content:Label { text = "#" .. name, w = lvgl.PCT(40), h = 30 }
    local dd = content:Dropdown { options = MODE_OPTS, w = lvgl.PCT(55), h = 30 }
    local cur = tonumber(_lora_proto_config_get("notify_ch:" .. name, SID)) or 1
    dd:set({ selected = cur })
    dd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
        local idx = dd:get("selected")
        if _lora_proto_config_set("notify_ch:" .. name, tostring(idx), SID) then
            status.text = "#" .. name .. ": " .. (MODE_NAMES[idx] or "?")
                .. (active and "" or " (at next MTLite boot)")
        else
            status.text = "#" .. name .. ": not saved"
        end
    end)
end

-- The channel list is a live value; when mtlite is not running, v1 has
-- exactly its one built-in default channel. The multi-channel milestone
-- persists the list to a file and replaces this fallback.
local chs = _lora_proto_config_get("channels", SID) or "LongFast"
local any = false
for name in string.gmatch(chs, "[^\n]+") do
    mode_row(name)
    any = true
end
if not any then
    content:Label { text = "(no channels)", w = lvgl.PCT(100), h = 16 }
end

content:Label {
    text = "Mentions only alerts when a message contains @[your name]. A muted channel still counts unread. Sound and keyboard blink for all protocols are in Settings > Notifications.",
    w = lvgl.PCT(100),
}

back_btn:onClicked(function()
    apps.go_home()
end)

return root

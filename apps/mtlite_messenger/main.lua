-- ══════════════════════════════════════════════════════════════════
-- MTLite Messenger — the Meshcore Messenger UI over the mtlite protocol.
-- Views: inbox (merged channels + DMs), chat (baked bubbles, disk-paged
--        window), nodes (Meshtastic NodeDB), my node.
-- Meshtastic differences from the Meshcore app: no push-to-Lua machinery
-- (the module has no lua_tick), so live traffic is POLLED — the chat view
-- refetches its tail and the inbox re-scans summaries on a timer. DMs have
-- ONE in-flight delivery ladder (_mtlite_dm_status), not per-message acks.
-- Rooms/repeaters, contact cards, paths and regions do not exist here.
-- ══════════════════════════════════════════════════════════════════

local lvgl = require("lvgl")
local messages = require("lib/mesh/messages")
local utils = require("lib/utils")
local gridnav_body = require("lib/gridnav_body")
local apps = require("lib/apps")
local nav = require("lib/nav")
local theme = require("lib/theme")
local clipboard = require("lib/clipboard")

-- MTLite-only app: under any other LoRa protocol, show the notice and bail.
if apps.proto_gate("mtlite") then return end

local SID = "mtlite"

-- Summaries only (one {count, last} entry per conversation): the module's
-- _store_summaries override supplies the channel table; DM threads come from
-- the shared store. A chat's history pages straight from its log file.
messages:loadSummaries()

local W = lvgl.HOR_RES()
local H = lvgl.VER_RES()
local HEADER_H = 24

local root = apps.new_root()
root:set { w = W, h = H, pad_all = 0, border_width = 0, bg_opa = 0 }
root:clear_flag(lvgl.FLAG.SCROLLABLE)

theme.show_background()

-- ── Theme (the Meshcore Messenger palette) ──────────────────────
local COL_ME_BG       = "#0b3d2e"
local COL_ME_TX       = "#d7f5e6"
local COL_THEM_BG     = "#262626"
local COL_THEM_TX     = "#f0f0f0"
local COL_META        = "#9aa0a6"
local COL_ACCENT      = "#7fb3ff"
local COL_FOCUS       = "#ffffff"
local NAME_COLORS = {
    "#7fb3ff", "#ffb37f", "#a0e57f", "#e57fb3",
    "#7fe5e5", "#e5e57f", "#c79fff", "#ff9f9f",
}

local current_view = nil
local current_input = nil
local current_mode = "inbox"
local chat_target = nil

-- Cached self name (flags own messages in the store records).
local my_name = nil
local function self_name()
    if my_name then return my_name end
    local ok, n = pcall(_lora_proto_config_get, "long_name", SID)
    if ok and n and n ~= "" then my_name = n end
    return my_name or "me"
end

-- Config helper (live values from the running stack).
local function cget(k)
    local ok, v = pcall(_lora_proto_config_get, k, SID)
    return (ok and v) or ""
end

-- Channel list: {idx, name} rows from the module's newline-separated
-- "channels" key (primary first; idx matches the store summaries).
local function channel_list()
    local out = {}
    local i = 0
    for name in cget("channels"):gmatch("[^\n]+") do
        out[#out + 1] = { idx = i, name = name }
        i = i + 1
    end
    return out
end

-- ── Header (always visible) ─────────────────────────────────────
local header = root:Object {
    w = W, h = HEADER_H, y = 0,
    border_width = 0, pad_left = 4, pad_right = 4, bg_opa = 0,
}
header:clear_flag(lvgl.FLAG.SCROLLABLE)

local header_title = header:Label { text = "Messenger", align = lvgl.ALIGN.LEFT_MID }
local header_right = header:Label { text = "", align = lvgl.ALIGN.RIGHT_MID, text_color = COL_META }

local function set_header(title, right_text)
    header_title.text = title or "Messenger"
    header_right.text = right_text or ""
end

local function node_count()
    local ok, peers = pcall(_lora_proto_peers)
    return (ok and type(peers) == "table") and #peers or 0
end

-- ── Helpers ─────────────────────────────────────────────────────
local function clear_view()
    pcall(_gridnav_edge_lock, false)
    nav.reset()
    messages:closeThread()
    if current_view then apps.delete_view(current_view); current_view = nil end
    if current_input then current_input:delete(); current_input = nil end
end

local function truncate(str, max)
    if not str then return "" end
    if #str <= max then return str end
    return string.sub(str, 1, max - 2) .. ".."
end

local function name_color(name)
    if not name or name == "" then return "#cccccc" end
    local h = 0
    for i = 1, #name do h = (h * 31 + string.byte(name, i)) % 2147483647 end
    return NAME_COLORS[(h % #NAME_COLORS) + 1]
end

local scroll_aware_list = nav.scroll_aware

-- Delivery word on own DM bubbles. mtlite has one in-flight ladder:
-- "sent" until the ROUTING ack, then delivered/failed.
local function dm_status_text(status)
    if status == "delivered" then return "delivered"
    elseif status == "failed" then return "failed"
    else return "sent" end
end

local show_inbox, show_chat, show_nodes, show_my_node, show_node_detail
local show_channels, show_nav_help

-- ── Long-press popup showing message metadata ───────────────────
local function show_msg_info(msg, on_reply, on_dismiss)
    local overlay = root:Object {
        w = W, h = H, x = 0, y = 0,
        bg_color = "#000000", bg_opa = 128,
        border_width = 0, pad_all = 0,
    }
    overlay:clear_flag(lvgl.FLAG.SCROLLABLE)
    overlay:add_flag(lvgl.FLAG.CLICKABLE)

    -- Fixed height: a long message (e.g. a pasted key) overflows and SCROLLS
    -- inside the box instead of pushing the buttons off-screen.
    local box = overlay:Object {
        w = W - 20, h = H - 20,
        align = lvgl.ALIGN.CENTER,
        bg_color = "#333333", radius = 6,
        border_width = 1, border_color = "#555555",
        pad_all = 8,
        flex = { flex_direction = "column", flex_wrap = "nowrap" },
    }
    nav.push(box)

    local function close()
        nav.pop()
        overlay:delete()
        if on_dismiss then on_dismiss() end
    end

    local function info_label(text)
        box:Label { text = text, w = lvgl.PCT(100) }
    end

    info_label("-- Message Info --")
    info_label("From: " .. utils.emojiText(msg.from or "?"))
    info_label("Time: " .. (msg.timestamp and utils.clockDateTime(msg.timestamp) or "?"))
    info_label("Hops: " .. (msg.hops or "?"))
    info_label("SNR: " .. (msg.snr and string.format("%.1f dB", msg.snr) or "N/A"))
    info_label("RSSI: " .. (msg.rssi and string.format("%.0f dBm", msg.rssi) or "N/A"))
    info_label("Route: " .. (msg.direct and "Direct" or "Relayed"))

    local reply_b = box:Button { w = lvgl.PCT(100), h = 26 }
    reply_b:Label { text = "Reply (@mention)", align = lvgl.ALIGN.CENTER }
    reply_b:onevent(lvgl.EVENT.RELEASED, function()
        close()
        if on_reply then on_reply(msg) end
    end)

    local copy_b = box:Button { w = lvgl.PCT(100), h = 26 }
    copy_b:Label { text = "Copy text", align = lvgl.ALIGN.CENTER }
    copy_b:onevent(lvgl.EVENT.RELEASED, function()
        clipboard.copy(msg.text or "")
        close()
    end)

    local close_b = box:Button { w = lvgl.PCT(100), h = 26 }
    close_b:Label { text = "Close", align = lvgl.ALIGN.CENTER }
    close_b:onevent(lvgl.EVENT.RELEASED, close)
end

-- ── Navigation help popup ───────────────────────────────────────
show_nav_help = function()
    local overlay = root:Object {
        w = W, h = H, x = 0, y = 0,
        bg_color = "#000000", bg_opa = 128, border_width = 0, pad_all = 0,
    }
    overlay:clear_flag(lvgl.FLAG.SCROLLABLE)
    overlay:add_flag(lvgl.FLAG.CLICKABLE)
    local box = overlay:Object {
        w = W - 30, h = lvgl.SIZE_CONTENT, align = lvgl.ALIGN.CENTER,
        bg_color = "#333333", radius = 6,
        border_width = 1, border_color = "#555555", pad_all = 8,
        flex = { flex_direction = "column", flex_wrap = "nowrap" },
    }
    nav.push(box)
    box:Label {
        text = "Tap a list once to arm it, tap a row to open.\n"
            .. "Trackball: click a list to step rows, 'q' backs out.\n"
            .. "Long-press a message for info/reply/copy.\n"
            .. "Channels are managed in the Channels view here.",
        w = lvgl.PCT(100),
    }
    local ok_b = box:Button { w = lvgl.PCT(100), h = 26 }
    ok_b:Label { text = "Close", align = lvgl.ALIGN.CENTER }
    ok_b:onevent(lvgl.EVENT.RELEASED, function()
        nav.pop()
        overlay:delete()
    end)
end

-- ── Clipboard menu for value fields ─────────────────────────────
-- Long-press a field for Copy/Paste/Cancel. Paste REPLACES the content (these
-- carry single values — keys, names — not prose; the chat input keeps its own
-- appending menu). after_paste runs after a successful paste.
local function attach_clipmenu(ta, after_paste)
    ta:onevent(lvgl.EVENT.LONG_PRESSED, function()
        local overlay = root:Object {
            w = W, h = H, x = 0, y = 0,
            bg_color = "#000000", bg_opa = 128, border_width = 0, pad_all = 0,
        }
        overlay:clear_flag(lvgl.FLAG.SCROLLABLE)
        overlay:add_flag(lvgl.FLAG.CLICKABLE)
        local function close()
            nav.pop()
            overlay:delete()
        end
        local pbox = overlay:Object {
            w = W - 40, h = lvgl.SIZE_CONTENT, align = lvgl.ALIGN.CENTER,
            bg_color = "#333333", radius = 6,
            border_width = 1, border_color = "#555555", pad_all = 8,
            flex = { flex_direction = "column", flex_wrap = "nowrap" },
        }
        nav.push(pbox)
        pbox:Label { text = "Clipboard", w = lvgl.PCT(100), text_color = COL_META }

        local paste_b = pbox:Button { w = lvgl.PCT(100), h = 28 }
        paste_b:Label { text = "Paste", align = lvgl.ALIGN.CENTER }
        paste_b:onevent(lvgl.EVENT.RELEASED, function()
            if clipboard.has() then
                ta.text = clipboard.paste()
                if after_paste then after_paste() end
            end
            close()
        end)

        local copy_b = pbox:Button { w = lvgl.PCT(100), h = 28 }
        copy_b:Label { text = "Copy", align = lvgl.ALIGN.CENTER }
        copy_b:onevent(lvgl.EVENT.RELEASED, function()
            clipboard.copy(ta.text or "")
            close()
        end)

        local cancel_b = pbox:Button { w = lvgl.PCT(100), h = 26 }
        cancel_b:Label { text = "Cancel", align = lvgl.ALIGN.CENTER }
        cancel_b:onevent(lvgl.EVENT.RELEASED, close)
    end)
end

-- ── Conversation model (summaries; no thread ever materializes) ─
local function build_conversations()
    local convos = {}
    for _, ch in ipairs(channel_list()) do
        local sum = messages:getChannelSummary(ch.idx)
        local last = sum and sum.last or nil
        convos[#convos + 1] = {
            kind = "channel", idx = ch.idx, name = ch.name,
            last = last, ts = last and last.timestamp or 0,
            unread = messages:unreadInChannel(ch.name),
            count = sum and sum.count or 0,
        }
    end
    for _, t in ipairs(messages:getDMThreadNames()) do
        convos[#convos + 1] = {
            kind = "dm", name = t.name, last = t.last_msg,
            ts = t.last_msg and t.last_msg.timestamp or 0,
            unread = t.unread or 0, count = t.count,
        }
    end
    table.sort(convos, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
    return convos
end

-- Fingerprint of the inbox content: the poll rebuilds rows only on change.
local function convo_stamp(convos)
    local s = ""
    for _, c in ipairs(convos) do
        s = s .. (c.name or "") .. ":" .. (c.ts or 0) .. ":" .. (c.unread or 0) .. ";"
    end
    return s
end

-- ── INBOX VIEW ──────────────────────────────────────────────────
show_inbox = function()
    clear_view()
    current_mode = "inbox"
    set_header("Messenger", "Nodes: " .. node_count())

    local body = gridnav_body(root, HEADER_H, H - HEADER_H,
                              GRIDNAV_ROLLOVER + GRIDNAV_SCROLL_FIRST, true)
    current_view = body

    local function ctrl(label, w, cb)
        local b = body:Button { w = w, h = 24 }
        b:Label { text = label, align = lvgl.ALIGN.CENTER }
        b:onevent(lvgl.EVENT.RELEASED, cb)
        return b
    end

    ctrl("Exit", 50, function()
        messages:freePersisted()
        apps.go_home()
    end)
    ctrl("Channels", 72, function() show_channels() end)
    ctrl("Nodes", 60, function() show_nodes() end)
    ctrl("Node", 48, function() show_my_node() end)
    ctrl("?", 26, function() show_nav_help() end)

    local list = body:Object {
        w = lvgl.PCT(100), h = H - HEADER_H - 36,
        border_width = 0, pad_all = 0, bg_opa = 0,
        flex = { flex_direction = "column", flex_wrap = "nowrap" },
    }
    nav.list(list)
    local bind_click = scroll_aware_list(list)

    local rows_stamp = ""

    local function fill_row(row, c)
        row:clean()
        local prefix = c.kind == "channel" and "#" or "@"
        local preview = ""
        if c.last then
            preview = truncate(utils.emojiText(c.last.from or "") .. ": " .. (c.last.text or ""), 24)
        end
        local left = row:Label { align = lvgl.ALIGN.LEFT_MID }
        left.text = prefix .. utils.emojiText(c.name) .. (preview ~= "" and ("  " .. preview) or "")
        if c.unread and c.unread > 0 then left:set { text_color = COL_FOCUS } end
        local right = row:Label { align = lvgl.ALIGN.RIGHT_MID, text_color = COL_META }
        local rt = (c.ts and c.ts > 0) and utils.relTime(c.ts) or ""
        if c.unread and c.unread > 0 then
            right:set { text = "(" .. c.unread .. ") " .. rt, text_color = COL_ACCENT }
        else
            right:set { text = rt }
        end
    end

    local function rebuild_rows()
        list:clean()
        local convos = build_conversations()
        rows_stamp = convo_stamp(convos)
        for _, c in ipairs(convos) do
            local row = list:Button { w = lvgl.PCT(100), h = 28 }
            fill_row(row, c)
            local cc = c
            bind_click(row, function()
                if cc.kind == "channel" then
                    show_chat { type = "channel", idx = cc.idx, name = cc.name }
                else
                    show_chat { type = "dm", name = cc.name }
                end
            end)
        end
        if #convos == 0 then
            list:Label {
                text = "No conversations yet.\nOpen Nodes to message someone,\nor pick a channel row once traffic arrives.",
                w = lvgl.PCT(100), h = 56,
            }
        end
    end
    rebuild_rows()

    -- Poll: re-scan summaries and rebuild only when the content fingerprint
    -- moved (no push events from the module — see the header comment).
    apps.add_timer { period = 3000, cb = function(t)
        if current_mode ~= "inbox" or not current_view then t:delete() return end
        messages:loadSummaries()
        local convos = build_conversations()
        if convo_stamp(convos) ~= rows_stamp then rebuild_rows() end
        set_header("Messenger", "Nodes: " .. node_count())
    end }
end

-- ── CHAT VIEW ───────────────────────────────────────────────────
local function build_chat(target)
    clear_view()
    current_mode = "chat"
    chat_target = target

    messages:openThread(target)
    if target.type == "channel" then
        messages:markChannelSeen(target.name)
    else
        messages:markDMSeen(target.name)
    end

    local me = self_name()
    local title = (target.type == "dm") and ("@" .. utils.emojiText(target.name))
                                          or ("#" .. utils.emojiText(target.name))
    set_header(title, "")

    local body = gridnav_body(root, HEADER_H, H - HEADER_H,
                              GRIDNAV_ROLLOVER + GRIDNAV_SCROLL_FIRST, true)
    current_view = body

    local back_btn = body:Button { w = 45, h = 20 }
    back_btn:Label { text = "Home", align = lvgl.ALIGN.CENTER }
    back_btn:onevent(lvgl.EVENT.RELEASED, function() show_inbox() end)

    if target.type == "dm" then
        local info_btn = body:Button { w = 45, h = 20 }
        info_btn:Label { text = "Info", align = lvgl.ALIGN.CENTER }
        info_btn:onevent(lvgl.EVENT.RELEASED, function() show_node_detail(target.name) end)
    end

    -- Message scroll area.
    local MSG_H = H - HEADER_H - 20 - 34 - 24
    local msg_list = body:Object {
        w = lvgl.PCT(100), h = MSG_H,
        border_width = 0, pad_all = 2, bg_opa = 0,
        flex = { flex_direction = "column", flex_wrap = "nowrap" },
    }
    local okf, text_font = pcall(lvgl.Font, "text", 16)
    if okf and text_font then
        msg_list:set { text_font = text_font }
    end
    msg_list:add_flag(lvgl.FLAG.CLICK_FOCUSABLE)

    local in_msg_select = false
    local textArea
    local context_menu_open = false
    -- Re-bake plumbing for the single-DM delivery status (baked bubbles are
    -- images; a status change re-bakes that one bubble).
    local status_entries, rebake_dirty, rebake_scheduled = {}, {}, false
    local run_rebake

    local on_scroll_settle
    local bind_msg = scroll_aware_list(msg_list, function()
        if on_scroll_settle then on_scroll_settle() end
    end)

    bind_msg(msg_list, function()
        if context_menu_open then return end
        if in_msg_select then return end
        in_msg_select = true
        pcall(_gridnav_edge_lock, true)
        nav.push(msg_list, { flags = nav.NONE, preserve = true })
    end)

    msg_list:onevent(lvgl.EVENT.KEY, function()
        local indev = lvgl.indev.get_act()
        local key = indev:get_key()
        if key == 113 then -- 'q' exits message selection
            in_msg_select = false
            pcall(_gridnav_edge_lock, false)
            nav.pop()
            if run_rebake and next(rebake_dirty) and not rebake_scheduled then
                rebake_scheduled = true
                apps.add_timer { period = 1, cb = function(t) t:delete(); run_rebake() end }
            end
        end
    end)

    -- Live bubble content; bake_msg snapshots it to an image (the Meshcore
    -- Messenger machinery, unchanged).
    local function build_bubble(parent, msg)
        local is_me = (msg.from == me)
        local bubble = parent:Object {
            w = lvgl.PCT(92), h = lvgl.SIZE_CONTENT,
            bg_color = is_me and COL_ME_BG or COL_THEM_BG,
            bg_opa = 255, radius = 6,
            border_width = 1,
            border_color = is_me and COL_ME_BG or COL_THEM_BG,
            pad_all = 4, pad_bottom = 5,
            flex = { flex_direction = "column", flex_wrap = "nowrap" },
        }
        bubble:clear_flag(lvgl.FLAG.SCROLLABLE)

        local hdr = is_me and "You" or utils.emojiText(msg.from or "?")
        local meta = utils.clockHM(msg.timestamp)
        local head_text = hdr .. "  " .. meta
        if is_me and msg.status ~= nil then
            head_text = head_text .. "  " .. dm_status_text(msg.status)
        end
        bubble:Label {
            text = head_text, w = lvgl.PCT(100),
            text_color = is_me and COL_META or name_color(msg.from),
        }
        bubble:Label {
            text = msg.text or "", w = lvgl.PCT(100),
            text_color = is_me and COL_ME_TX or COL_THEM_TX,
        }
        return bubble
    end

    local function bake_msg(msg)
        local bubble = build_bubble(msg_list, msg)
        local ok_s, buf = pcall(_snapshot_take, bubble)
        local bw, bh
        local okc, bc = pcall(function() return bubble:get_coords() end)
        if okc and bc and bc.x2 then bw = bc.x2 - bc.x1 + 1; bh = bc.y2 - bc.y1 + 1 end
        bubble:delete()
        if not ok_s or not buf then
            print("[MTLite Messenger] snapshot failed (OOM?) for a chat bubble")
            return nil
        end
        local img = msg_list:Image {}
        img:set_src(buf)
        if bw and bh and bw > 0 and bh > 0 then img:set { w = bw, h = bh } end
        pcall(_snapshot_attach_free, img, buf)
        img:add_flag(lvgl.FLAG.CLICKABLE)
        img:add_flag(lvgl.FLAG.CLICK_FOCUSABLE)
        img:set_style({ border_width = 1, border_color = COL_FOCUS }, lvgl.STATE.FOCUS_KEY)

        local function open_msg_menu()
            if context_menu_open then return end
            context_menu_open = true
            show_msg_info(msg, function(m)
                textArea.text = "@[" .. (m.from or "?") .. "] "
            end, function()
                context_menu_open = false
                if in_msg_select then nav.set_focused(img) end
            end)
        end
        bind_msg(img, function()
            if in_msg_select then open_msg_menu() end
        end)
        img:onevent(lvgl.EVENT.LONG_PRESSED, open_msg_menu)

        return img
    end

    -- ── Windowed disk-paged history (Meshcore machinery, store-backed) ──
    local bubbles = {}
    local top_off, bot_off, file_size = 0, 0, 0
    local empty_lbl = nil
    local page_scheduled = false
    local PAGE, WIN_MAX, EDGE = 10, 30, 40
    local function following() return bot_off >= file_size end
    local function clear_empty()
        if empty_lbl then pcall(function() empty_lbl:delete() end); empty_lbl = nil end
    end

    local function fetch(mode, cursor)   -- mode 0 tail / 1 older / 2 newer
        local ok, r
        if target.type == "channel" then
            ok, r = pcall(_store_chat_page_channel, target.name, mode, cursor or 0, PAGE)
        else
            ok, r = pcall(_store_chat_page_dm, target.name, mode, cursor or 0, PAGE)
        end
        if ok and type(r) == "table" and type(r.list) == "table" then return r end
        return { list = {}, size = file_size or 0 }
    end

    local function add_bottom(rec)
        clear_empty()
        local img = bake_msg(rec)
        if not img then return nil end
        local entry = { obj = img, msg = rec, off0 = rec.off0, off1 = rec.off1 }
        bubbles[#bubbles + 1] = entry
        return entry
    end
    local function add_top(rec)
        clear_empty()
        local img = bake_msg(rec)
        if not img then return end
        img:move_to_index(0)
        table.insert(bubbles, 1, { obj = img, msg = rec, off0 = rec.off0, off1 = rec.off1 })
    end

    local function drop(entry)
        if not entry then return end
        status_entries[entry.msg] = nil
        rebake_dirty[entry.msg] = nil
        pcall(function() entry.obj:delete() end)
    end
    local function prune_bottom_to(n)
        while #bubbles > n do drop(table.remove(bubbles)) end
        if #bubbles > 0 then bot_off = bubbles[#bubbles].off1 end
    end
    local function prune_top_to(n)
        while #bubbles > n do drop(table.remove(bubbles, 1)) end
        if #bubbles > 0 then top_off = bubbles[1].off0 end
    end
    local function prune_top() prune_top_to(WIN_MAX) end

    local function anchor_y(obj)
        local ok, c = pcall(function() return obj:get_coords() end)
        return (ok and c and c.y1) or 0
    end
    local function reanchor(obj, yb, st0)
        pcall(function() msg_list:update_layout() end)
        pcall(function() msg_list:scroll_to({ y = st0 + (anchor_y(obj) - yb), anim = false }) end)
    end

    local function clear_all()
        for _, e in ipairs(bubbles) do
            status_entries[e.msg] = nil
            rebake_dirty[e.msg] = nil
            pcall(function() e.obj:delete() end)
        end
        bubbles = {}
    end
    local function load_tail(scroll)
        local r = fetch(0, 0)
        file_size = r.size or 0
        for i = 1, #r.list do add_bottom(r.list[i]) end
        if #bubbles > 0 then
            top_off = bubbles[1].off0
            bot_off = bubbles[#bubbles].off1
            if scroll then pcall(function() bubbles[#bubbles].obj:scroll_to_view(false) end) end
        else
            top_off, bot_off = 0, 0
        end
    end

    local function page_older()
        if top_off <= 0 or #bubbles == 0 then return end
        local a = bubbles[1].obj
        local yb, st0 = anchor_y(a), msg_list:get_scroll_top()
        local r = fetch(1, top_off)
        file_size = r.size or file_size
        if #r.list == 0 then top_off = 0; return end
        prune_bottom_to(math.max(0, WIN_MAX - #r.list))
        for i = #r.list, 1, -1 do add_top(r.list[i]) end
        top_off = bubbles[1].off0
        reanchor(a, yb, st0)
    end

    local function page_newer()
        if following() or #bubbles == 0 then return end
        local a = bubbles[#bubbles].obj
        local yb, st0 = anchor_y(a), msg_list:get_scroll_top()
        local r = fetch(2, bot_off)
        file_size = r.size or file_size
        if #r.list == 0 then return end
        prune_top_to(math.max(0, WIN_MAX - #r.list))
        for i = 1, #r.list do add_bottom(r.list[i]) end
        bot_off = bubbles[#bubbles].off1
        reanchor(a, yb, st0)
    end

    local function alive() return current_mode == "chat" and chat_target == target end

    local FOCUS_KEY = lvgl.STATE.FOCUS_KEY
    local function is_focused(obj)
        local ok, st = pcall(function() return obj:get_state() end)
        return ok and st and (st & FOCUS_KEY) ~= 0
    end

    local function run_page()
        page_scheduled = false
        if not alive() then return end
        local ok_tp, pressed = pcall(_touch_pressed)
        if ok_tp and pressed then
            page_scheduled = true
            apps.add_timer { period = 30, cb = function(t) t:delete(); run_page() end }
            return
        end
        local keep
        if in_msg_select then
            for _, e in ipairs(bubbles) do
                if is_focused(e.obj) then keep = e; break end
            end
        end
        if msg_list:get_scroll_top() <= EDGE then
            page_older()
        elseif not following() and msg_list:get_scroll_bottom() <= EDGE then
            page_newer()
        end
        if keep and keep.obj then
            pcall(function() nav.set_focused(keep.obj) end)
        end
    end
    on_scroll_settle = function()
        if page_scheduled then return end
        page_scheduled = true
        apps.add_timer { period = 1, cb = function(t) t:delete(); run_page() end }
    end

    -- ── DM delivery status (single in-flight ladder) ────────────────────
    -- After a DM send, poll _mtlite_dm_status until it leaves "pending";
    -- the tracked bubble re-bakes with delivered/failed.
    local dm_watch = nil        -- the entry of the last own DM bubble
    local dm_poll_on = false
    local function start_dm_poll()
        if dm_poll_on then return end
        dm_poll_on = true
        apps.add_timer { period = 1000, cb = function(t)
            if not alive() or not dm_watch then
                t:delete(); dm_poll_on = false; return
            end
            local ok, st = pcall(_mtlite_dm_status)
            if not ok then t:delete(); dm_poll_on = false; return end
            if st == "delivered" or st == "failed" then
                local m = dm_watch.msg
                m.status = st
                rebake_dirty[m] = true
                dm_watch = nil
                t:delete(); dm_poll_on = false
                if not rebake_scheduled then
                    rebake_scheduled = true
                    apps.add_timer { period = 1, cb = function(tt) tt:delete(); run_rebake() end }
                end
            end
        end }
    end

    local function rebake_one(m, entry)
        local pos
        for k = 1, #bubbles do if bubbles[k] == entry then pos = k; break end end
        if not pos then return end
        local old = entry.obj
        local new = bake_msg(m)
        if not new then return end
        pcall(function() new:move_to_index(pos - 1) end)
        entry.obj = new
        pcall(function() old:delete() end)
    end
    run_rebake = function()
        rebake_scheduled = false
        if not alive() then rebake_dirty = {}; return end
        if in_msg_select then return end
        local dirty = rebake_dirty; rebake_dirty = {}
        for m in pairs(dirty) do
            local entry = status_entries[m]
            if entry and entry.obj then rebake_one(m, entry) end
        end
    end

    -- ── Live traffic poll (no push machinery in mtlite) ─────────────────
    -- Refetch newer records past the window's bottom edge. At the tail the
    -- new bubbles append below the fold (no viewport yank — the melody +
    -- unread badge announce them); scrolled up, just mark that more exists
    -- so page_newer unblocks.
    local function poll_live()
        if in_msg_select then return end
        local r = fetch(2, bot_off)
        if #r.list == 0 then
            file_size = math.max(file_size, r.size or 0)
            return
        end
        if following() and msg_list:get_scroll_bottom() <= EDGE + MSG_H then
            local a = bubbles[#bubbles] and bubbles[#bubbles].obj
            local yb, st0 = a and anchor_y(a) or 0, msg_list:get_scroll_top()
            for i = 1, #r.list do add_bottom(r.list[i]) end
            prune_top()
            bot_off = bubbles[#bubbles].off1
            file_size = math.max(r.size or 0, bot_off)
            if a then reanchor(a, yb, st0) end
            -- Reading the thread live: keep its unread counter clear.
            if target.type == "channel" then messages:markChannelSeen(target.name)
            else messages:markDMSeen(target.name) end
        else
            file_size = math.max(file_size, r.size or 0, bot_off + 1)
        end
    end
    apps.add_timer { period = 2000, cb = function(t)
        if not alive() then t:delete() return end
        poll_live()
    end }

    -- Initial window.
    load_tail(true)
    if #bubbles == 0 then
        empty_lbl = msg_list:Label {
            text = "No messages yet — say hello.",
            text_color = COL_META, w = lvgl.PCT(100),
        }
    end

    -- ── Input row ───────────────────────────────────────────────────────
    -- The module's wire text cap is 200 bytes (Meshtastic payload budget);
    -- names travel via NodeInfo, so channels get the full budget too.
    local MAX_TEXT_LEN = 200
    textArea = body:Textarea {
        password_mode = false, one_line = true,
        max_length = MAX_TEXT_LEN,
        w = lvgl.PCT(75), h = 34,
    }
    if okf and text_font then
        textArea:set { text_font = text_font }
    end

    -- After a successful send the module stored our echo: jump to the newest
    -- records (they carry real file offsets) and track the last own DM
    -- bubble for the delivery ladder.
    local function after_send()
        if not following() then
            clear_all()
            load_tail(false)
        else
            local r = fetch(2, bot_off)
            for i = 1, #r.list do
                local entry = add_bottom(r.list[i])
                if entry and target.type == "dm" and entry.msg.from == me then
                    entry.msg.status = "sent"
                    rebake_dirty[entry.msg] = nil
                    status_entries[entry.msg] = entry
                    rebake_one(entry.msg, entry)   -- bake the "sent" word in
                    dm_watch = entry
                end
            end
            prune_top()
            if #bubbles > 0 then bot_off = bubbles[#bubbles].off1 end
            file_size = math.max(r.size or 0, bot_off)
        end
        local last = bubbles[#bubbles]
        if last then pcall(function() last.obj:scroll_to_view(false) end) end
        if target.type == "dm" and dm_watch then start_dm_poll() end
    end

    local function do_send()
        local text = textArea.text
        if not text or #text == 0 then return end
        -- Wire form: expand composed PUA emoji to real Unicode (Meshtastic
        -- peers must receive standard UTF-8).
        local okd, wire = pcall(_emoji_decompose, text)
        if not okd or not wire then wire = text end
        local sent
        if target.type == "channel" then
            sent = _lora_proto_send_channel(target.name, wire)
        else
            sent = _lora_proto_send_text(target.name, wire)
        end
        if sent then
            textArea.text = ""
            set_header(title, "")
            apps.add_timer { period = 1, cb = function(t) t:delete(); after_send() end }
        else
            set_header(title, target.type == "dm" and "No key yet - info requested" or "Send failed")
        end
    end

    -- Enforce the true wire budget live (composed emoji expand on the wire).
    local function enforce_wire_budget()
        local t = textArea.text
        if not t or #t == 0 then return end
        local ok, wire = pcall(_emoji_decompose, t)
        if not ok or not wire then return end
        while #wire > MAX_TEXT_LEN and #t > 0 do
            local i = #t
            while i > 1 and t:byte(i) >= 0x80 and t:byte(i) < 0xC0 do i = i - 1 end
            t = t:sub(1, i - 1)
            ok, wire = pcall(_emoji_decompose, t)
            if not ok or not wire then return end
        end
        if t ~= textArea.text then textArea.text = t end
    end

    textArea:onevent(lvgl.EVENT.KEY, function()
        local indev = lvgl.indev.get_act()
        local key = indev:get_key()
        if key == lvgl.KEY.ENTER then do_send() return end
        enforce_wire_budget()
    end)

    textArea:onevent(lvgl.EVENT.LONG_PRESSED, function()
        local overlay = root:Object {
            w = W, h = H, x = 0, y = 0,
            bg_color = "#000000", bg_opa = 128, border_width = 0, pad_all = 0,
        }
        overlay:clear_flag(lvgl.FLAG.SCROLLABLE)
        overlay:add_flag(lvgl.FLAG.CLICKABLE)
        local function close()
            nav.pop()
            overlay:delete()
        end
        local pbox = overlay:Object {
            w = W - 40, h = lvgl.SIZE_CONTENT, align = lvgl.ALIGN.CENTER,
            bg_color = "#333333", radius = 6,
            border_width = 1, border_color = "#555555", pad_all = 8,
            flex = { flex_direction = "column", flex_wrap = "nowrap" },
        }
        nav.push(pbox)
        pbox:Label { text = "Clipboard", w = lvgl.PCT(100), text_color = COL_META }

        local paste_b = pbox:Button { w = lvgl.PCT(100), h = 28 }
        paste_b:Label { text = "Paste", align = lvgl.ALIGN.CENTER }
        paste_b:onevent(lvgl.EVENT.RELEASED, function()
            if clipboard.has() then
                textArea.text = (textArea.text or "") .. clipboard.paste()
                enforce_wire_budget()
            end
            close()
        end)

        local copy_b = pbox:Button { w = lvgl.PCT(100), h = 28 }
        copy_b:Label { text = "Copy", align = lvgl.ALIGN.CENTER }
        copy_b:onevent(lvgl.EVENT.RELEASED, function()
            clipboard.copy(textArea.text or "")
            close()
        end)

        local cancel_b = pbox:Button { w = lvgl.PCT(100), h = 26 }
        cancel_b:Label { text = "Cancel", align = lvgl.ALIGN.CENTER }
        cancel_b:onevent(lvgl.EVENT.RELEASED, close)
    end)

    local send_btn = body:Button { w = lvgl.SIZE_CONTENT, h = 34 }
    send_btn:Label { text = "Send", align = lvgl.ALIGN.CENTER }
    send_btn:onevent(lvgl.EVENT.RELEASED, do_send)
end

show_chat = function(target)
    local step = 0
    utils.loadingPopUpAdd(nil, utils.emojiText((target and target.name) or "chat"), function()
        step = step + 1
        if step == 1 then return false end
        pcall(build_chat, target)
        return true
    end)
end

-- ── NODE DETAIL POPUP ───────────────────────────────────────────
-- Everything the module holds on one node (peer_info renders verbatim),
-- plus Message / Request info actions.
show_node_detail = function(name)
    local overlay = root:Object {
        w = W, h = H, x = 0, y = 0,
        bg_color = "#000000", bg_opa = 128, border_width = 0, pad_all = 0,
    }
    overlay:clear_flag(lvgl.FLAG.SCROLLABLE)
    overlay:add_flag(lvgl.FLAG.CLICKABLE)
    -- Fixed-height box: content taller than the screen scrolls inside it.
    local box = overlay:Object {
        w = W - 20, h = H - 20, align = lvgl.ALIGN.CENTER,
        bg_color = "#333333", radius = 6,
        border_width = 1, border_color = "#555555", pad_all = 8,
        flex = { flex_direction = "column", flex_wrap = "nowrap" },
    }
    nav.push(box)

    local function close()
        nav.pop()
        overlay:delete()
    end

    box:Label { text = "-- Node --", w = lvgl.PCT(100), text_color = COL_META }
    local info = cget("peer_info:" .. name)
    box:Label {
        text = (info ~= "" and info or (utils.emojiText(name) .. "\n(no details held)")),
        w = lvgl.PCT(100),
    }

    local msg_b = box:Button { w = lvgl.PCT(100), h = 28 }
    msg_b:Label { text = "Message", align = lvgl.ALIGN.CENTER }
    msg_b:onevent(lvgl.EVENT.RELEASED, function()
        close()
        show_chat { type = "dm", name = name }
    end)

    local req_b = box:Button { w = lvgl.PCT(100), h = 28 }
    req_b:Label { text = "Request info (key exchange)", align = lvgl.ALIGN.CENTER }
    req_b:onevent(lvgl.EVENT.RELEASED, function()
        local okc, res = pcall(_lora_proto_config_set, "request_nodeinfo", name, SID)
        set_header("Nodes", (okc and res) and "NodeInfo requested"
                            or "Request failed (rate limit?)")
        close()
    end)

    local close_b = box:Button { w = lvgl.PCT(100), h = 26 }
    close_b:Label { text = "Close", align = lvgl.ALIGN.CENTER }
    close_b:onevent(lvgl.EVENT.RELEASED, close)
end

-- ── CHANNELS VIEW ───────────────────────────────────────────────
-- Channel management lives HERE (the meshcore Messenger convention).
-- Channels apply live and persist in the protocol module; the vendor rules hold:
-- blank PSK inherits the primary's, "AQ==" is the well-known default key, a
-- full 16/32-byte base64 key makes a private channel. The view rebuilds
-- itself after every action (the meshcore show_channels shape).
show_channels = function()
    clear_view()
    current_mode = "channels"
    set_header("Channels", "")

    local body = root:Object {
        flex = { flex_direction = "row", flex_wrap = "wrap" },
        w = W, h = H - HEADER_H, y = HEADER_H,
        border_width = 0, pad_all = 4, bg_opa = 0,
    }
    nav.replace(body)
    current_view = body

    local back_btn = body:Button { w = 45, h = 22 }
    back_btn:Label { text = "Home", align = lvgl.ALIGN.CENTER }
    back_btn:onevent(lvgl.EVENT.RELEASED, function() show_inbox() end)

    -- Add channel: name + optional base64 PSK.
    local ch_input = body:Textarea {
        password_mode = false, one_line = true, placeholder_text = "name",
        w = lvgl.PCT(34), h = 28,
    }
    ch_input:clear_flag(lvgl.FLAG.SCROLLABLE)

    local psk_input = body:Textarea {
        password_mode = false, one_line = true, placeholder_text = "PSK b64",
        w = lvgl.PCT(28), h = 28,
    }
    psk_input:clear_flag(lvgl.FLAG.SCROLLABLE)
    attach_clipmenu(ch_input)
    attach_clipmenu(psk_input)

    local add_btn = body:Button { w = 45, h = 28 }
    add_btn:Label { text = "Add", align = lvgl.ALIGN.CENTER }
    add_btn:onevent(lvgl.EVENT.RELEASED, function()
        local name = (ch_input.text or ""):gsub("%s+$", "")
        if name == "" then set_header("Channels", "Name required") return end
        local psk = psk_input.text or ""
        local val = (psk ~= "") and (name .. "\t" .. psk) or name
        local okc, res = pcall(_lora_proto_config_set, "channel_add", val, SID)
        if okc and res then
            show_channels()
        else
            set_header("Channels", "Add failed (dup, full, or bad PSK)")
        end
    end)

    ch_input:onevent(lvgl.EVENT.KEY, function()
        local key = lvgl.indev.get_act():get_key()
        if key == lvgl.KEY.ENTER then add_btn:send_event(lvgl.EVENT.CLICKED, nil) end
    end)

    -- Share/import the whole network as a meshtastic.org/e/# URL (channels +
    -- radio config — the form the official apps put in their QR codes).
    -- Full-width so it reads as the view-level action it is, not a per-row
    -- control (a narrow button wrapped in front of the first channel row).
    local url_btn = body:Button { w = lvgl.PCT(100), h = 26 }
    url_btn:Label { text = "Network URL - share / import", align = lvgl.ALIGN.CENTER }
    url_btn:onevent(lvgl.EVENT.RELEASED, function()
        local overlay = root:Object {
            w = W, h = H, x = 0, y = 0,
            bg_color = "#000000", bg_opa = 128, border_width = 0, pad_all = 0,
        }
        overlay:clear_flag(lvgl.FLAG.SCROLLABLE)
        overlay:add_flag(lvgl.FLAG.CLICKABLE)
        local function close()
            nav.pop()
            overlay:delete()
        end
        local pbox = overlay:Object {
            w = W - 30, h = lvgl.SIZE_CONTENT, align = lvgl.ALIGN.CENTER,
            bg_color = "#333333", radius = 6,
            border_width = 1, border_color = "#555555", pad_all = 8,
            flex = { flex_direction = "column", flex_wrap = "nowrap" },
        }
        nav.push(pbox)
        pbox:Label { text = "Network URL", w = lvgl.PCT(100), text_color = COL_META }

        local copy_b = pbox:Button { w = lvgl.PCT(100), h = 28 }
        copy_b:Label { text = "Copy URL", align = lvgl.ALIGN.CENTER }
        copy_b:onevent(lvgl.EVENT.RELEASED, function()
            local url = cget("channel_url")
            if url ~= "" then
                clipboard.copy(url)
                set_header("Channels", "URL copied")
            else
                set_header("Channels", "URL unavailable")
            end
            close()
        end)

        local qr_b = pbox:Button { w = lvgl.PCT(100), h = 28 }
        qr_b:Label { text = "Show QR", align = lvgl.ALIGN.CENTER }
        qr_b:onevent(lvgl.EVENT.RELEASED, function()
            local url = cget("channel_url")
            close()
            if url == "" then set_header("Channels", "URL unavailable") return end
            local qov = root:Object {
                w = W, h = H, x = 0, y = 0,
                bg_color = "#000000", bg_opa = 245, border_width = 0, pad_all = 0,
            }
            qov:clear_flag(lvgl.FLAG.SCROLLABLE)
            qov:add_flag(lvgl.FLAG.CLICKABLE)
            qov:Label { text = "Scan in a Meshtastic app", text_color = "#FFFFFF",
                        align = lvgl.ALIGN.TOP_MID, y = 4 }
            local holder = qov:Object {
                w = 190, h = 190, align = lvgl.ALIGN.CENTER,
                bg_color = "#FFFFFF", border_width = 0, pad_all = 8,
            }
            holder:clear_flag(lvgl.FLAG.SCROLLABLE)
            local pok, qok = pcall(_qr_create, holder, url, 174)
            if not (pok and qok) then
                holder:Label { text = "QR unavailable", align = lvgl.ALIGN.CENTER,
                               text_color = "#000000" }
            end
            local qclose_btn = qov:Button { w = 28, h = 28, align = lvgl.ALIGN.TOP_RIGHT, x = -4, y = 4 }
            qclose_btn:Label { text = "X", align = lvgl.ALIGN.CENTER }
            qclose_btn:onevent(lvgl.EVENT.RELEASED, function()
                nav.pop()
                qov:delete()
            end)
            nav.push(qov)
        end)

        local imp_b = pbox:Button { w = lvgl.PCT(100), h = 28 }
        imp_b:Label { text = "Import from clipboard", align = lvgl.ALIGN.CENTER }
        imp_b:onevent(lvgl.EVENT.RELEASED, function()
            close()
            if not clipboard.has() then
                set_header("Channels", "Clipboard is empty")
                return
            end
            -- Importing REPLACES the whole channel set + radio config:
            -- confirm like the identity regenerate.
            local cov = root:Object {
                w = W, h = H, x = 0, y = 0,
                bg_opa = 200, border_width = 0, pad_all = 0,
            }
            cov:clear_flag(lvgl.FLAG.SCROLLABLE)
            cov:add_flag(lvgl.FLAG.CLICKABLE)
            local cbox = cov:Object {
                w = 280, h = 150, align = lvgl.ALIGN.CENTER,
                bg_color = "#333333", border_width = 1, pad_all = 10,
                flex = { flex_direction = "row", flex_wrap = "wrap" },
            }
            cbox:clear_flag(lvgl.FLAG.SCROLLABLE)
            nav.push(cbox)
            cbox:Label { text = "Import network URL?", w = lvgl.PCT(100), h = 18 }
            cbox:Label { text = "REPLACES all channels and the", w = lvgl.PCT(100), h = 18 }
            cbox:Label { text = "radio settings with the URL's.", w = lvgl.PCT(100), h = 18 }
            local yes = cbox:Button { w = lvgl.PCT(48), h = 32 }
            yes:Label { text = "Import", align = lvgl.ALIGN.CENTER }
            local no = cbox:Button { w = lvgl.PCT(48), h = 32 }
            no:Label { text = "Cancel", align = lvgl.ALIGN.CENTER }
            no:onClicked(function()
                nav.pop()
                cov:delete()
            end)
            yes:onClicked(function()
                nav.pop()
                cov:delete()
                local okc, res = pcall(_lora_proto_config_set, "channel_url",
                                       clipboard.paste(), SID)
                if okc and res then
                    local okrp, rp = pcall(require, "lib/reboot_prompt")
                    if okrp and rp then
                        rp.show("Imported radio settings retune at reboot")
                    end
                    show_channels()
                else
                    set_header("Channels", "Import failed (bad or unsupported URL)")
                end
            end)
        end)

        local cancel_b = pbox:Button { w = lvgl.PCT(100), h = 26 }
        cancel_b:Label { text = "Cancel", align = lvgl.ALIGN.CENTER }
        cancel_b:onevent(lvgl.EVENT.RELEASED, close)
    end)

    local function info_field(name, field)
        local info = cget("channel_info:" .. name)
        return info:match(field .. "=([^\n]*)") or "?"
    end

    -- PSK editor strip (bottom of the view): opened by a row's PSK button.
    -- Declared up front; built lazily so the view stays short without it.
    local psk_target, psk_lbl, psk_ta, psk_set

    local function open_psk_editor(name)
        psk_target = name
        if not psk_lbl then
            psk_lbl = body:Label { text = "", w = lvgl.PCT(100), h = 16 }
            psk_ta = body:Textarea {
                password_mode = false, one_line = true,
                w = lvgl.PCT(68), h = 28,
            }
            psk_ta:clear_flag(lvgl.FLAG.SCROLLABLE)
            attach_clipmenu(psk_ta)
            psk_set = body:Button { w = lvgl.PCT(28), h = 28 }
            psk_set:Label { text = "Set PSK", align = lvgl.ALIGN.CENTER }
            psk_set:onevent(lvgl.EVENT.RELEASED, function()
                if not psk_target then return end
                local okc, res = pcall(_lora_proto_config_set, "channel_psk",
                                       psk_target .. "\t" .. (psk_ta.text or ""), SID)
                if okc and res then
                    show_channels()
                else
                    set_header("Channels", "PSK rejected (bad base64?)")
                end
            end)
        end
        psk_lbl.text = "PSK for " .. name .. " (b64; AQ== default, blank inherits)"
        psk_ta.text = info_field(name, "psk_b64")
    end

    -- Channel rows: chat button + PSK + Del (never the primary).
    for _, ch in ipairs(channel_list()) do
        local unread = messages:unreadInChannel(ch.name)
        local kind = info_field(ch.name, "psk")
        local primary = info_field(ch.name, "primary") == "1"

        local chat_btn = body:Button { w = lvgl.PCT(56), h = 24 }
        local lbl = chat_btn:Label { align = lvgl.ALIGN.LEFT_MID }
        lbl.text = "#" .. utils.emojiText(ch.name)
            .. "  [" .. kind .. "]" .. (primary and " (pri)" or "")
            .. (unread > 0 and ("  (" .. unread .. ")") or "")
        if unread > 0 then lbl:set { text_color = COL_ACCENT } end
        local ch_copy = { type = "channel", idx = ch.idx, name = ch.name }
        chat_btn:onevent(lvgl.EVENT.RELEASED, function() show_chat(ch_copy) end)

        local pbtn = body:Button { w = lvgl.PCT(18), h = 24 }
        pbtn:Label { text = "PSK", align = lvgl.ALIGN.CENTER }
        local nm = ch.name
        pbtn:onevent(lvgl.EVENT.RELEASED, function() open_psk_editor(nm) end)

        if primary then
            body:Label { text = "", w = lvgl.PCT(18), h = 24 }
        else
            local del_btn = body:Button { w = lvgl.PCT(18), h = 24 }
            del_btn:Label { text = "Del", align = lvgl.ALIGN.CENTER }
            del_btn:onevent(lvgl.EVENT.RELEASED, function()
                local okc, res = pcall(_lora_proto_config_set, "channel_del", nm, SID)
                if okc and res then show_channels()
                else set_header("Channels", "Delete failed") end
            end)
        end
    end
end

-- ── NODES VIEW (the Meshtastic NodeDB) ──────────────────────────
show_nodes = function()
    clear_view()
    current_mode = "nodes"

    local ok_p, peers = pcall(_lora_proto_peers)
    if not ok_p or type(peers) ~= "table" then peers = {} end
    table.sort(peers, function(a, b) return (a.last_heard or 0) > (b.last_heard or 0) end)

    set_header("Nodes", #peers .. " heard")

    local body = gridnav_body(root, HEADER_H, H - HEADER_H,
                              GRIDNAV_ROLLOVER + GRIDNAV_SCROLL_FIRST, true)
    current_view = body

    local back_btn = body:Button { w = 50, h = 24 }
    back_btn:Label { text = "Home", align = lvgl.ALIGN.CENTER }
    back_btn:onevent(lvgl.EVENT.RELEASED, function() show_inbox() end)

    body:Label {
        text = " tap a node for details/DM",
        text_color = COL_META, h = 24,
    }

    local list = body:Object {
        w = lvgl.PCT(100), h = H - HEADER_H - 30,
        border_width = 0, pad_all = 0, bg_opa = 0,
        flex = { flex_direction = "column", flex_wrap = "nowrap" },
    }
    nav.list(list)
    local bind_click = scroll_aware_list(list)

    for _, p in ipairs(peers) do
        local row = list:Button { w = lvgl.PCT(100), h = 28 }
        local left = row:Label { align = lvgl.ALIGN.LEFT_MID }
        left:set { text = utils.emojiText(p.name or p.id or "?") }
        local right = row:Label { align = lvgl.ALIGN.RIGHT_MID, text_color = COL_META }
        local rt = (p.last_heard and p.last_heard > 0) and utils.relTime(p.last_heard) or ""
        right:set { text = (p.snr and string.format("%.0fdB  ", p.snr) or "") .. rt }
        local pp = p
        bind_click(row, function() show_node_detail(pp.name or pp.id) end)
    end

    if #peers == 0 then
        list:Label {
            text = "No nodes heard yet.\nNodes appear as their broadcasts arrive.",
            w = lvgl.PCT(100), h = 40,
        }
    end
end

-- ── MY NODE CARD ────────────────────────────────────────────────
-- Modal card over the current view (the Meshcore Messenger shape): fixed
-- height so overflowing content scrolls inside the box.
show_my_node = function()
    local overlay = root:Object {
        w = W, h = H, x = 0, y = 0,
        bg_color = "#000000", bg_opa = 128, border_width = 0, pad_all = 0,
    }
    overlay:clear_flag(lvgl.FLAG.SCROLLABLE)
    overlay:add_flag(lvgl.FLAG.CLICKABLE)

    local function close_popup()
        nav.pop()
        overlay:delete()
    end

    local box = overlay:Object {
        w = W - 20, h = H - 20, align = lvgl.ALIGN.CENTER,
        bg_color = "#333333", radius = 6,
        border_width = 1, border_color = "#555555", pad_all = 8,
        flex = { flex_direction = "column", flex_wrap = "nowrap" },
    }
    nav.push(box)

    local function info(text) box:Label { text = text, w = lvgl.PCT(100) } end

    info("-- My Node --")
    info("Name: " .. utils.emojiText(cget("long_name")) .. " (" .. cget("short_name") .. ")")
    info("Node id: " .. cget("node_id"))
    info("Region: " .. cget("region_name") .. "   Preset: " .. cget("preset_name"))
    info("Frequency: " .. cget("freq") .. " MHz (slot "
         .. cget("freq_slot_active") .. "/" .. cget("freq_slots") .. ")")
    info("Role: " .. cget("role_name") .. "   Hops: " .. cget("hop_limit"))
    info("TX power: " .. cget("tx_power") .. " dBm")
    info("Primary channel: #" .. cget("channel"))
    info("Location share: " .. cget("pos_precision_name"))
    info("Names: MTLite > Identity. Radio: MTLite > Radio. Channels: the Channels view here.")

    -- Announce ourselves now (name + public key) — the MeshCore advert
    -- equivalent; also how a peer learns our DM key without the wait.
    local adv_btn = box:Button { w = lvgl.PCT(100), h = 28 }
    local adv_lbl = adv_btn:Label { text = "Broadcast node info", align = lvgl.ALIGN.CENTER }
    adv_btn:onevent(lvgl.EVENT.RELEASED, function()
        local okc, res = pcall(_lora_proto_config_set, "broadcast_nodeinfo", "1", SID)
        adv_lbl.text = (okc and res) and "Sent!" or "Failed"
    end)

    local close_b = box:Button { w = lvgl.PCT(100), h = 26 }
    close_b:Label { text = "Close", align = lvgl.ALIGN.CENTER }
    close_b:onevent(lvgl.EVENT.RELEASED, close_popup)
end

-- ── Start ───────────────────────────────────────────────────────
show_inbox()

return root

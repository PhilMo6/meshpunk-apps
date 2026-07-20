-- Games > Gamepad — mapping setup for the dynamic USB gamepad driver.
--
-- The driver parses the pad's HID report descriptor into an exact field
-- table (buttons / hat / axes) and publishes 4-byte SEMANTIC EVENTS on
-- every control change ('E', kind, id, val) — this app never sees raw
-- report bytes. Two-step mapping: tap "Map a button", press the GAMEPAD
-- control (the next event names it exactly: "Button 3", "hat Up", "X axis
-- low"), then press the T-DECK input to emulate — any key or trackball
-- move/click, captured raw by the firmware's own input reader
-- (_input_capture_*; the press is swallowed so it doesn't navigate the UI).
-- Each pad control holds ONE mapping (remapping replaces it); any number
-- of controls may share the same T-Deck output.
--
-- conf rules (all hex): BTN <n> <code> | HAT <dir> <code> |
-- AX <usage> <L|H> <code>. Old byte-format lines (B/H/T) are dropped on
-- load. With NO conf the driver runs a default mapping (dpad -> WASD,
-- sticks -> nav, buttons per DEFAULT_RULES below); the app then SEEDS the
-- list with those same defaults so they're visible/editable. "Restore defaults"
-- (shown only while a conf exists) deletes the conf. Profiles: "Save as"
-- snapshots the list to <name>.prof beside the conf; "Load" lists profiles
-- and applying one rewrites conf immediately. All apply on RECONNECT (the
-- core re-reads conf on every attach).
local lvgl    = require("lvgl")
local apps    = require("lib/apps")
local nav     = require("lib/nav")
local theme   = require("lib/theme")
local fileman = require("lib/fileman")

local root = apps.new_root()
root:set { w = lvgl.HOR_RES(), h = lvgl.VER_RES(), pad_all = 0, border_width = 0, bg_opa = 0 }
root:clear_flag(lvgl.FLAG.SCROLLABLE)
theme.show_background()

local W = lvgl.HOR_RES()
local H = lvgl.VER_RES()

local DRV_DIRS = { "L:/usb_drivers/gamepad", "S:/meshpunk/usb_drivers/gamepad" }

local function driver_dir()
    for _, d in ipairs(DRV_DIRS) do
        if fileman.exists(d) then return d end
    end
    return nil
end

-- Friendly name for an emulated code.
local function code_name(c)
    if c == 0x81 then return "Trackball Up"    end
    if c == 0x82 then return "Trackball Down"  end
    if c == 0x83 then return "Trackball Left"  end
    if c == 0x84 then return "Trackball Right" end
    if c == 0x85 then return "Click"           end
    if c == 0x0D then return "Enter"           end
    if c == 0x08 then return "Backspace"       end
    if c == 0x20 then return "Space"           end
    if c == 0x1B then return "Esc"             end
    if c == 0x09 then return "Tab"             end
    if c >= 0x21 and c <= 0x7E then return "'" .. string.char(c) .. "'" end
    return string.format("0x%02X", c)
end

-- Hat directions, clockwise from north (HID convention; index = dir + 1).
local HAT_NAMES = { "Up", "Up-Right", "Right", "Down-Right",
                    "Down", "Down-Left", "Left", "Up-Left" }

local AXIS_NAMES = { [0x30] = "X", [0x31] = "Y", [0x32] = "Z", [0x33] = "Rx",
                     [0x34] = "Ry", [0x35] = "Rz", [0x36] = "Slider",
                     [0x37] = "Dial" }

local function axis_name(u)
    return AXIS_NAMES[u] or string.format("axis %02X", u)
end

-- ── UI skeleton ──────────────────────────────────────────────────────────────

local content = root:Object {
    flex = { flex_direction = "row", flex_wrap = "wrap" },
    w = W, h = H,
    border_width = 0, pad_all = 6, pad_row = 3, bg_opa = 0,
}
nav.replace(content, { flags = nav.ROLLOVER + nav.SCROLL_FIRST })

content:Label { text = "Gamepad Setup", w = lvgl.PCT(70), h = 24 }
local back_btn = content:Button { w = 50, h = 22 }
back_btn:Label { text = "Home", align = lvgl.ALIGN.CENTER }
back_btn:onClicked(function() apps.go_home() end)

local status = content:Label { text = "", w = lvgl.PCT(100), h = 30 }
local raw    = content:Label { text = "(no pad input yet)", w = lvgl.PCT(100), h = 16 }

-- ── Controls + rules model ───────────────────────────────────────────────────
-- A control identity is { kind="BTN", id= } | { kind="HAT", dir= } |
-- { kind="AX", usage=, half="L"|"H" }; rules carry the identity plus code.

local rules = {}

local function ctl_desc(c)
    if c.kind == "BTN" then return "Button " .. c.id end
    if c.kind == "HAT" then return "hat " .. (HAT_NAMES[c.dir + 1] or c.dir) end
    return axis_name(c.usage) .. " axis " .. (c.half == "H" and "high" or "low")
end

local function rule_line(c, code)
    if c.kind == "BTN" then return string.format("BTN %02X %02X", c.id, code) end
    if c.kind == "HAT" then return string.format("HAT %X %02X", c.dir, code) end
    return string.format("AX %02X %s %02X", c.usage, c.half, code)
end

-- Parse a conf rule line, or nil (old B/H/T byte-format lines land here).
local function parse_line(line)
    local t = {}
    for tok in line:gmatch("%S+") do t[#t + 1] = tok end
    local k = t[1] and t[1]:upper()
    if k == "BTN" and #t >= 3 then
        local id, code = tonumber(t[2], 16), tonumber(t[3], 16)
        if id and code then return { kind = "BTN", id = id, code = code } end
    elseif k == "HAT" and #t >= 3 then
        local dir, code = tonumber(t[2], 16), tonumber(t[3], 16)
        if dir and dir <= 7 and code then
            return { kind = "HAT", dir = dir, code = code }
        end
    elseif k == "AX" and #t >= 4 then
        local usage = tonumber(t[2], 16)
        local half  = t[3]:upper()
        local code  = tonumber(t[4], 16)
        if usage and (half == "L" or half == "H") and code then
            return { kind = "AX", usage = usage, half = half, code = code }
        end
    end
    return nil
end

-- Same PHYSICAL control — exact identity, no overlap math.
local function same_control(x, y)
    if x.kind ~= y.kind then return false end
    if x.kind == "BTN" then return x.id == y.id end
    if x.kind == "HAT" then return x.dir == y.dir end
    return x.usage == y.usage and x.half == y.half
end

local dropped_old = 0
local conf_exists = false     -- a saved conf is active (vs driver defaults)

-- Mirror of the driver's gen_defaults() (modules/usbdrv_gamepad/main.cpp):
-- the mapping the driver runs when no conf exists (Phil's baseline: dpad ->
-- WASD, sticks -> trackball nav, buttons -> Enter/'m'/'n'/'e'/Space/Click/
-- Backspace/Enter). KEEP THE TWO IN SYNC. Rows for controls the pad
-- doesn't have are inert (the driver ignores unbound rules) — Del them if
-- they bother you.
local DEFAULT_RULES = {
    { kind = "HAT", dir = 0, code = 0x77 },              -- up    -> 'w'
    { kind = "HAT", dir = 2, code = 0x64 },              -- right -> 'd'
    { kind = "HAT", dir = 4, code = 0x73 },              -- down  -> 's'
    { kind = "HAT", dir = 6, code = 0x61 },              -- left  -> 'a'
    { kind = "AX", usage = 0x30, half = "L", code = 0x83 },
    { kind = "AX", usage = 0x30, half = "H", code = 0x84 },
    { kind = "AX", usage = 0x31, half = "L", code = 0x81 },
    { kind = "AX", usage = 0x31, half = "H", code = 0x82 },
    { kind = "BTN", id = 0x01, code = 0x0D },            -- Enter
    { kind = "BTN", id = 0x02, code = 0x6D },            -- 'm'
    { kind = "BTN", id = 0x03, code = 0x6E },            -- 'n'
    { kind = "BTN", id = 0x04, code = 0x65 },            -- 'e'
    { kind = "BTN", id = 0x06, code = 0x20 },            -- Space
    { kind = "BTN", id = 0x08, code = 0x85 },            -- Click
    { kind = "BTN", id = 0x09, code = 0x08 },            -- Backspace
    { kind = "BTN", id = 0x0A, code = 0x0D },            -- Enter
    { kind = "BTN", id = 0x0C, code = 0x77 },            -- 'w' (Xbox dpad up)
    { kind = "BTN", id = 0x0D, code = 0x73 },            -- 's' (dpad down)
    { kind = "BTN", id = 0x0E, code = 0x61 },            -- 'a' (dpad left)
    { kind = "BTN", id = 0x0F, code = 0x64 },            -- 'd' (dpad right)
}

local function finish_rule(r)
    r.line = rule_line(r, r.code)
    r.desc = code_name(r.code) .. "  <-  " .. ctl_desc(r)
    return r
end

local function seed_defaults()
    rules = {}
    for _, d in ipairs(DEFAULT_RULES) do
        rules[#rules + 1] = finish_rule({ kind = d.kind, id = d.id,
            dir = d.dir, usage = d.usage, half = d.half, code = d.code })
    end
end

-- Parse conf-format text into a fresh rules array + dropped-line count.
local function parse_conf_text(txt)
    local out, dropped = {}, 0
    for line in txt:gmatch("[^\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local r = parse_line(line)
            if r then
                out[#out + 1] = finish_rule(r)
            else
                dropped = dropped + 1
            end
        end
    end
    return out, dropped
end

local function rules_text()
    local out = { "# gamepad mapping (written by the Gamepad app)" }
    for _, r in ipairs(rules) do out[#out + 1] = r.line end
    return table.concat(out, "\n") .. "\n"
end

local function load_existing()
    rules = {}
    dropped_old = 0
    conf_exists = false
    local dir = driver_dir()
    if not dir then return end
    local txt = fileman.read(dir .. "/conf")
    if not txt then
        seed_defaults()   -- show the defaults the driver is running
        return
    end
    conf_exists = true
    rules, dropped_old = parse_conf_text(txt)
end

local update_profile_btns   -- defined with the buttons below

local function save_rules()
    local dir = driver_dir()
    if not dir then status.text = "Driver not installed."; return end
    if fileman.write(dir .. "/conf", rules_text()) then
        conf_exists = true
        if update_profile_btns then update_profile_btns() end
        status.text = "Saved. RECONNECT the gamepad to apply."
    else
        status.text = "Save FAILED (" .. dir .. ")"
    end
end

-- ── Driver event feed ────────────────────────────────────────────────────────
-- 4 bytes: 'E', kind (0=button 1=hat 2=axis), id, val.

local last_seq = 0

local function decode_event(blob)
    if #blob < 4 or blob:byte(1) ~= 0x45 then return nil end
    local kind, id, val = blob:byte(2), blob:byte(3), blob:byte(4)
    if kind == 0 then
        return { kind = "BTN", id = id, released = (val == 0) }
    elseif kind == 1 then
        if val > 7 then return { kind = "HAT", centered = true } end
        return { kind = "HAT", dir = val }
    elseif kind == 2 then
        if val == 0 then return { kind = "AX", usage = id, centered = true } end
        return { kind = "AX", usage = id, half = (val == 2) and "H" or "L" }
    end
    return nil
end

-- The control an event identifies for mapping, or nil (recentering a hat
-- or axis names no direction; a button release still names its button).
local function event_control(ev)
    if not ev or ev.centered then return nil end
    if ev.kind == "BTN" then return { kind = "BTN", id = ev.id } end
    if ev.kind == "HAT" then return { kind = "HAT", dir = ev.dir } end
    return { kind = "AX", usage = ev.usage, half = ev.half }
end

local function event_text(ev)
    local c = event_control(ev)
    if c then
        if ev.kind == "BTN" and ev.released then
            return ctl_desc(c) .. " up"
        end
        return ctl_desc(c)
    end
    if ev.kind == "HAT" then return "hat centered" end
    if ev.kind == "AX" then return axis_name(ev.usage) .. " axis centered" end
    return "?"
end

-- ── Rules list (rebuilt in place) ────────────────────────────────────────────

local list_box = content:Object {
    flex = { flex_direction = "row", flex_wrap = "wrap" },
    w = lvgl.PCT(100), h = 80,
    bg_color = "#111111", bg_opa = 255, radius = 4,
    border_width = 1, border_color = "#444444", pad_all = 3, pad_row = 2,
}

local refresh_list
refresh_list = function()
    list_box:clean()
    if #rules == 0 then
        list_box:Label { text = "(no mappings)", w = lvgl.PCT(100), h = 14 }
    end
    for idx, r in ipairs(rules) do
        list_box:Label { text = r.desc, w = lvgl.PCT(78), h = 18 }
        local del = list_box:Button { w = lvgl.PCT(20), h = 18 }
        del:Label { text = "Del", align = lvgl.ALIGN.CENTER }
        del:onClicked(function()
            table.remove(rules, idx)
            refresh_list()
        end)
    end
end

-- ── Two-step mapping wizard ──────────────────────────────────────────────────
-- wizard = nil | { step = 1 (wait for a pad event) | 2 (wait for T-Deck
--                  input); ctl, box, msg }

local wizard = nil

local function wizard_close(msg)
    if _input_capture_stop then pcall(_input_capture_stop) end
    if wizard and wizard.box then wizard.box:delete() end
    wizard = nil
    if msg then status.text = msg end
end

local map_btn = content:Button { w = lvgl.PCT(100), h = 26 }
map_btn:Label { text = "Map a button...", align = lvgl.ALIGN.CENTER }

local save_btn = content:Button { w = lvgl.PCT(32), h = 24 }
save_btn:Label { text = "Save", align = lvgl.ALIGN.CENTER }
save_btn:onClicked(save_rules)

local saveas_btn = content:Button { w = lvgl.PCT(32), h = 24 }
saveas_btn:Label { text = "Save as...", align = lvgl.ALIGN.CENTER }

local loadp_btn = content:Button { w = lvgl.PCT(32), h = 24 }
loadp_btn:Label { text = "Load...", align = lvgl.ALIGN.CENTER }

local clear_btn = content:Button { w = lvgl.PCT(48), h = 24 }
clear_btn:Label { text = "Clear all", align = lvgl.ALIGN.CENTER }
clear_btn:onClicked(function()
    rules = {}
    refresh_list()
    status.text = "Cleared - Save to write it, then reconnect."
end)

-- Only meaningful while a saved conf overrides the driver defaults.
local restore_btn = content:Button { w = lvgl.PCT(48), h = 24 }
restore_btn:Label { text = "Restore defaults", align = lvgl.ALIGN.CENTER }

update_profile_btns = function()
    if conf_exists then
        restore_btn:clear_flag(lvgl.FLAG.HIDDEN)
    else
        restore_btn:add_flag(lvgl.FLAG.HIDDEN)
    end
end

-- "Save as" row (hidden until toggled): profile name + OK. Profiles are
-- flat `<name>.prof` files beside the driver's conf (a subdir would break
-- Tools/USB's flat-dir driver delete).
local prof_name = content:Textarea {
    one_line = true, text = "",
    placeholder_text = "Profile name",
    w = lvgl.PCT(64), h = 30,
}
prof_name:clear_flag(lvgl.FLAG.SCROLLABLE)
prof_name:add_flag(lvgl.FLAG.HIDDEN)

local prof_ok = content:Button { w = lvgl.PCT(32), h = 24 }
prof_ok:Label { text = "OK", align = lvgl.ALIGN.CENTER }
prof_ok:add_flag(lvgl.FLAG.HIDDEN)

-- "Load" box (hidden until toggled): one row per saved profile.
local prof_box = content:Object {
    flex = { flex_direction = "row", flex_wrap = "wrap" },
    w = lvgl.PCT(100), h = 64,
    bg_color = "#101820", bg_opa = 255, radius = 4,
    border_width = 1, border_color = "#444444", pad_all = 3, pad_row = 2,
}
prof_box:add_flag(lvgl.FLAG.HIDDEN)

local prof_mode = nil        -- nil | "save" | "load"
local fill_prof_box          -- defined below

local function set_prof_mode(m)
    prof_mode = (m ~= nil and prof_mode ~= m) and m or nil
    if prof_mode == "save" then
        prof_name:clear_flag(lvgl.FLAG.HIDDEN)
        prof_ok:clear_flag(lvgl.FLAG.HIDDEN)
    else
        prof_name:add_flag(lvgl.FLAG.HIDDEN)
        prof_ok:add_flag(lvgl.FLAG.HIDDEN)
    end
    if prof_mode == "load" then
        fill_prof_box()
        prof_box:clear_flag(lvgl.FLAG.HIDDEN)
    else
        prof_box:add_flag(lvgl.FLAG.HIDDEN)
    end
end

saveas_btn:onClicked(function() set_prof_mode("save") end)
loadp_btn:onClicked(function() set_prof_mode("load") end)

restore_btn:onClicked(function()
    local dir = driver_dir()
    if not dir then return end
    fileman.remove(dir .. "/conf")
    load_existing()
    refresh_list()
    update_profile_btns()
    status.text = "Defaults restored. RECONNECT the pad to apply."
end)

prof_ok:onClicked(function()
    local dir = driver_dir()
    if not dir then status.text = "Driver not installed."; return end
    local name = (prof_name.text or ""):gsub("[^%w_%-]", ""):sub(1, 16)
    if name == "" then status.text = "Enter a profile name."; return end
    if fileman.write(dir .. "/" .. name .. ".prof", rules_text()) then
        status.text = "Profile '" .. name .. "' saved."
        prof_name.text = ""
        set_prof_mode(nil)
    else
        status.text = "Profile save FAILED."
    end
end)

fill_prof_box = function()
    prof_box:clean()
    local dir = driver_dir()
    local entries = dir and fileman.list(dir, {
        sizes = false,
        filter = function(e)
            return e.type == "file" and e.name:sub(-5) == ".prof"
        end,
    }) or nil
    if not entries or #entries == 0 then
        prof_box:Label { text = "(no profiles saved)", w = lvgl.PCT(100), h = 14 }
        return
    end
    for _, e in ipairs(entries) do
        local name = e.name:sub(1, -6)
        local row = prof_box:Button { w = lvgl.PCT(100), h = 18 }
        row:Label { text = name, align = lvgl.ALIGN.LEFT_MID }
        row:onClicked(function()
            local txt = fileman.read(dir .. "/" .. e.name)
            if not txt then status.text = "Read failed: " .. e.name; return end
            local parsed = parse_conf_text(txt)
            rules = parsed
            if fileman.write(dir .. "/conf", rules_text()) then
                conf_exists = true
                status.text = "Loaded '" .. name .. "'. RECONNECT the pad."
            else
                status.text = "Loaded '" .. name .. "' (conf write FAILED)"
            end
            refresh_list()
            update_profile_btns()
            set_prof_mode(nil)
        end)
    end
end

map_btn:onClicked(function()
    if wizard then return end
    local box = root:Object {
        w = W - 30, h = 110,
        align = { type = lvgl.ALIGN.CENTER },
        bg_color = "#202030", bg_opa = 255, radius = 6,
        border_width = 2, border_color = "#8888AA", pad_all = 8, pad_row = 6,
        flex = { flex_direction = "row", flex_wrap = "wrap" },
    }
    local msg = box:Label {
        text = "Step 1/2\nPress the GAMEPAD control\nyou want to map...",
        w = lvgl.PCT(100), h = 54,
    }
    local cancel = box:Button { w = lvgl.PCT(100), h = 24 }
    cancel:Label { text = "Cancel (touch)", align = lvgl.ALIGN.CENTER }
    cancel:onClicked(function() wizard_close("Mapping cancelled.") end)
    -- Swallow ALL T-Deck input for the whole wizard (stray presses must not
    -- act on the UI behind the popup). Step 2 re-arms, which also discards
    -- anything accidentally captured earlier.
    if _input_capture_start then pcall(_input_capture_start) end
    wizard = { step = 1, box = box, msg = msg }
end)

-- ── Poll timer: preflight, event feed, wizard steps ──────────────────────────

apps.add_timer { period = 100, cb = function()
    if not _usb_drv_read then
        status.text = "Firmware too old for dynamic drivers."
        return
    end

    -- Event feed (also drives wizard step 1).
    local blob, seq = _usb_drv_read("gamepad")
    if blob and seq ~= last_seq then
        last_seq = seq
        local ev = decode_event(blob)
        if ev then
            raw.text = "last: " .. event_text(ev)
            local c = event_control(ev)
            if wizard and wizard.step == 1 and c then
                wizard.ctl  = c
                wizard.step = 2
                wizard.msg.text = "Got: " .. ctl_desc(c) ..
                    "\n\nStep 2/2\nNow press the T-DECK key\nor move the trackball..."
                if _input_capture_start then pcall(_input_capture_start) end
            end
        end
    elseif not blob and not wizard then
        local dir = driver_dir()
        if not dir then
            status.text = "Driver not installed (App Library > drivers)."
        elseif not (_usb_running and _usb_running()) then
            status.text = "Start USB host (Tools > USB), then plug the pad."
        else
            status.text = "Waiting for the gamepad... (press a button)"
        end
    end

    -- Wizard step 2: T-Deck input capture.
    if wizard and wizard.step == 2 and _input_capture_poll then
        local ok, code = pcall(_input_capture_poll)
        if ok and code then
            local ctl = wizard.ctl
            -- One mapping per pad control: drop any existing rule for it.
            for i = #rules, 1, -1 do
                if rules[i].kind and same_control(rules[i], ctl) then
                    table.remove(rules, i)
                end
            end
            rules[#rules + 1] = {
                kind = ctl.kind, id = ctl.id, dir = ctl.dir,
                usage = ctl.usage, half = ctl.half, code = code,
                line = rule_line(ctl, code),
                desc = code_name(code) .. "  <-  " .. ctl_desc(ctl),
            }
            refresh_list()
            wizard_close("Mapped: " .. ctl_desc(ctl) .. "  ->  " .. code_name(code))
        end
    end
end }

load_existing()
refresh_list()
update_profile_btns()
if not (_input_capture_start and _input_capture_poll) then
    status.text = "Firmware too old for input capture - update firmware."
elseif dropped_old > 0 then
    status.text = dropped_old .. " old-format rule(s) dropped - remap and Save."
elseif not conf_exists then
    status.text = "Driver defaults shown - Save or map to customize."
end

return root

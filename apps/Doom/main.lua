local lvgl = require("lvgl")
local apps = require("lib/apps")
local nav = require("lib/nav")
local fileman = require("lib/fileman")
local keybind = require("lib/keybind")

local app_dir = ...

local W = lvgl.HOR_RES()
local H = lvgl.VER_RES()

-- ============================================================
-- Doom Launcher with configurable controls
-- ============================================================

-- Derive SD-side mirror of app directory:
-- "L:/lua/apps/Games/Doom" → "S:/lua/apps/Games/Doom"
local sd_app_dir = app_dir:gsub("^L:", "S:")

-- Convert firmware path prefixes to VFS mount points for the ELF module's fopen
local function to_vfs_path(path)
    if path:sub(1, 2) == "S:" then return "/sd" .. path:sub(3) end
    if path:sub(1, 2) == "L:" then return "/littlefs" .. path:sub(3) end
    return path
end

-- Search for a file: check app dir, then SD mirror, then legacy S:/doom/
-- Returns the firmware-convention path (S:/L:) — caller converts to VFS if needed
local function find_file(name)
    local search = { app_dir, sd_app_dir, "S:/doom" }
    for _, dir in ipairs(search) do
        local path = dir .. "/" .. name
        local f = io.open(path, "r")
        if f then f:close(); return path end
    end
    return nil
end

local CFG_PATH = app_dir .. "/controls.cfg"
local ELF_PATH = find_file("doom.app.elf") or sd_app_dir .. "/doom.app.elf"

-- Check WAD type by reading the 4-byte header: "IWAD" or "PWAD"
local function wad_type(path)
    local f = io.open(path, "r")
    if not f then return "unknown" end
    local hdr = f:read(4)
    f:close()
    if not hdr then return "unknown" end
    if hdr == "IWAD" then return "iwad"
    elseif hdr == "PWAD" then return "pwad"
    else return "unknown" end
end

-- The levels a WAD actually contains, read from its own lump directory.
-- Header: 4-byte tag, lump count, directory offset (both 32-bit
-- little-endian). Each 16-byte directory entry ends with an 8-byte name, and
-- a level's marker lump is named ExMy (Doom 1) or MAPxx (Doom 2) - so the
-- names say both which scheme a WAD uses and exactly which levels exist.
-- Returns a sorted list of { name, ep, map } with ep = 0 for MAPxx, or an
-- empty list when the file cannot be read or holds no levels.
local level_cache = {}

local function le32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d or d > 127 then return nil end   -- truncated, or past 2GB
    return a + b * 256 + c * 65536 + d * 16777216
end

local function wad_levels(path)
    local cached = level_cache[path]
    if cached then return cached end

    local levels = {}
    level_cache[path] = levels

    local f = io.open(path, "r")
    if not f then return levels end
    local hdr = f:read(12)
    if not hdr or #hdr < 12 then f:close(); return levels end

    local nlumps = le32(hdr, 5)
    local dirofs = le32(hdr, 9)
    if not nlumps or not dirofs or nlumps <= 0 then f:close(); return levels end
    f:seek("set", dirofs)

    local seen = {}
    local left = nlumps
    while left > 0 do
        local batch = (left > 512) and 512 or left      -- 8KB per read
        local dir = f:read(batch * 16)
        if not dir or #dir < 16 then break end
        for pos = 1, #dir - 15, 16 do
            -- Only E... and MAP... can be level markers; skip the rest on one
            -- byte rather than building a string per lump.
            local c1 = dir:byte(pos + 8)
            if c1 == 69 or c1 == 77 then        -- 'E' / 'M'
                local name = dir:sub(pos + 8, pos + 15)
                local z = name:find("\0", 1, true)      -- names are NUL-padded
                if z then name = name:sub(1, z - 1) end
                if not seen[name] then
                    local ep, mp = name:match("^E(%d)M(%d)$")
                    if ep then
                        ep, mp = tonumber(ep), tonumber(mp)
                        seen[name] = true
                        levels[#levels + 1] = {
                            name = name, ep = ep, map = mp, key = ep * 100 + mp,
                        }
                    else
                        mp = name:match("^MAP(%d%d)$")
                        if mp then
                            mp = tonumber(mp)
                            seen[name] = true
                            levels[#levels + 1] = {
                                name = name, ep = 0, map = mp, key = 1000 + mp,
                            }
                        end
                    end
                end
            end
        end
        left = left - batch
    end
    f:close()

    table.sort(levels, function(a, b) return a.key < b.key end)
    return levels
end

local found_wads = {}  -- { {name, path, wtype="iwad"|"pwad"}, ... }
local seen_lower = {}

-- fileman routes the drive from the L:/S: prefix itself; sizes=false skips
-- the per-entry size lookup, so huge WAD folders list fast (watchdog-safe).
local function scan_dir_for_wads(dir_path)
    local entries = fileman.list(dir_path, {
        sizes = false,
        filter = function(e)
            return e.type == "file" and e.name:lower():match("%.wad$")
        end,
    }) or {}
    for _, e in ipairs(entries) do
        local low = e.name:lower()
        if not seen_lower[low] then
            seen_lower[low] = true
            found_wads[#found_wads + 1] = {
                name = e.name,
                path = dir_path .. "/" .. e.name,
                wtype = "unknown",  -- classified one-per-tick in deferred init
            }
        end
    end
end

local iwad_list = {}
local selected_wad = 1
local selected_base = 1   -- index into iwad_list
local selected_wad_name = nil   -- persisted in config
local selected_base_name = nil  -- persisted in config

-- Doom keycodes
local DK = {
    UP        = 0xAD,
    DOWN      = 0xAF,
    LEFT      = 0xAC,
    RIGHT     = 0xAE,
    STRAFEL   = 0xA0,
    STRAFER   = 0xA1,
    FIRE      = 0xA3,
    USE       = 0xA2,  -- KEY_USE in Doom
    RUN       = 0xB6,  -- rshift
    ENTER     = 0x0D,
    ESCAPE    = 0x1B,
}

-- What this launcher wants bound. lib/keybind owns the key table, the Controls
-- and picker screens, storage and the -keymap/-trkball strings, and appends the
-- standard Quit action itself. Defaults name keys rather than repeating codes.
local ACTIONS = {
    { id="fwd",     label="Forward",      out=DK.UP,      key1="w",     key2="TrkUp"  },
    { id="back",    label="Backward",     out=DK.DOWN,    key1="s",     key2="TrkDn"  },
    { id="sleft",   label="Strafe Left",  out=DK.STRAFEL, key1="a"                    },
    { id="sright",  label="Strafe Right", out=DK.STRAFER, key1="d"                    },
    { id="tleft",   label="Turn Left",    out=DK.LEFT,    key1="j",     key2="TrkLt"  },
    { id="tright",  label="Turn Right",   out=DK.RIGHT,   key1="l",     key2="TrkRt"  },
    { id="fire",    label="Fire",         out=DK.FIRE,    key1="Space", key2="TrkClk" },
    { id="use",     label="Use / Open",   out=DK.USE,     key1="e"                    },
    { id="run",     label="Run",          out=DK.RUN,     key1="Shift"                },
    { id="enter",   label="Menu OK",      out=DK.ENTER,   key1="Enter"                },
    { id="esc",     label="Menu / ESC",   out=DK.ESCAPE,  key1="BkSpc"                },
    -- Weapon select (bottom row z-m + t,g for easy access)
    { id="wp1",     label="Weapon 1",     out=0x31,       key1="z"                    },
    { id="wp2",     label="Weapon 2",     out=0x32,       key1="x"                    },
    { id="wp3",     label="Weapon 3",     out=0x33,       key1="c"                    },
    { id="wp4",     label="Weapon 4",     out=0x34,       key1="v"                    },
    { id="wp5",     label="Weapon 5",     out=0x35,       key1="b"                    },
    { id="wp6",     label="Weapon 6",     out=0x36,       key1="n"                    },
    { id="wp7",     label="Weapon 7",     out=0x37,       key1="m"                    },
    { id="wp8",     label="Weapon 8",     out=0x38,       key1="t"                    },
    { id="wp9",     label="Weapon 9",     out=0x39,       key1="g"                    },
}

-- Touch controller layout (keyboardless boards, and any board once the user
-- turns touch input on). Doom has far more actions than fit one screen, so
-- the two presets split them: "Play" turns with the d-pad and keeps fire /
-- use / run to hand, "Strafe" puts strafing on the d-pad and turning up top.
-- Weapon keys are deliberately absent — add them in the editor if wanted.
-- lib/padlayout owns the user's edits (drag, resize, per-pad off), persisted
-- per app; these are only defaults. The lib ships with firmware newer than
-- this launcher's min_fw, so it may be absent.
local pl_ok, padlayout = pcall(require, "lib/padlayout")
if not pl_ok then padlayout = nil end

local pad = padlayout and padlayout.new{
    app = "Doom",
    presets = {
        {
            name = "Play",
            zones = {
                { id="fwd",    out=DK.UP,      label="^",    x=52,  y=118, w=64, h=56 },
                { id="tleft",  out=DK.LEFT,    label="<",    x=0,   y=174, w=56, h=66 },
                { id="back",   out=DK.DOWN,    label="v",    x=56,  y=174, w=60, h=66 },
                { id="tright", out=DK.RIGHT,   label=">",    x=116, y=174, w=56, h=66 },
                { id="fire",   out=DK.FIRE,    label="FIRE", x=254, y=160, w=66, h=76 },
                { id="use",    out=DK.USE,     label="USE",  x=188, y=174, w=60, h=62 },
                { id="run",    out=DK.RUN,     label="RUN",  x=188, y=110, w=60, h=54 },
                { id="sleft",  out=DK.STRAFEL, label="SL",   x=176, y=0,   w=50, h=30 },
                { id="sright", out=DK.STRAFER, label="SR",   x=230, y=0,   w=50, h=30 },
                { id="esc",    out=DK.ESCAPE,  label="ESC",  x=56,  y=0,   w=54, h=30 },
                { id="enter",  out=DK.ENTER,   label="OK",   x=114, y=0,   w=58, h=30 },
                { id="quit",   out=keybind.QUIT, label="QUIT", x=0, y=0,   w=52, h=30 },
            },
        },
        {
            name = "Strafe",
            zones = {
                { id="fwd",    out=DK.UP,      label="^",    x=52,  y=118, w=64, h=56 },
                { id="sleft",  out=DK.STRAFEL, label="<",    x=0,   y=174, w=56, h=66 },
                { id="back",   out=DK.DOWN,    label="v",    x=56,  y=174, w=60, h=66 },
                { id="sright", out=DK.STRAFER, label=">",    x=116, y=174, w=56, h=66 },
                { id="fire",   out=DK.FIRE,    label="FIRE", x=254, y=160, w=66, h=76 },
                { id="use",    out=DK.USE,     label="USE",  x=188, y=174, w=60, h=62 },
                { id="run",    out=DK.RUN,     label="RUN",  x=188, y=110, w=60, h=54 },
                { id="tleft",  out=DK.LEFT,    label="TL",   x=176, y=0,   w=50, h=30 },
                { id="tright", out=DK.RIGHT,   label="TR",   x=230, y=0,   w=50, h=30 },
                { id="esc",    out=DK.ESCAPE,  label="ESC",  x=56,  y=0,   w=54, h=30 },
                { id="enter",  out=DK.ENTER,   label="OK",   x=114, y=0,   w=58, h=30 },
                { id="quit",   out=keybind.QUIT, label="QUIT", x=0, y=0,   w=52, h=30 },
            },
        },
    },
} or nil

-- Built once the screen helpers below exist; save_config/load_config reach it
-- as an upvalue.
local kb

-- Audio toggle state
local sfx_enabled = true
local music_enabled = true

-- Multiplayer choices (persisted). Mode: 1 host, 2 join over the USB cable,
-- 3 join over WiFi by searching the network, 4 join over WiFi by address.
-- Host options only matter when hosting: the host's game settings go to
-- every player. They travel to the module as ONE "-netgame <spec>" argument.
local mp_mode = 1
local mp_players = 2          -- the host starts once this many are in
local mp_dm = 0               -- 0 co-op, 1 deathmatch, 2 deathmatch 2
local mp_skill = 3            -- 1..5
local mp_level = ""           -- start level name, e.g. "E1M1" or "MAP07";
                              -- "" (or a name the WAD lacks) = its first
local mp_monsters = true
local mp_respawn = false
local mp_timer_min = 0        -- level time limit in minutes, 0 = none
local mp_ip = ""              -- last host address typed
local MP_TIMERS = { 0, 5, 10, 15, 20, 30 }

-- Which WAD supplies the level list for the current selection: a mod's own
-- levels when it has any, otherwise the base game's.
local function selected_levels()
    if #found_wads == 0 then return {} end
    local w = found_wads[selected_wad]
    local levels = wad_levels(w.path)
    if #levels == 0 and w.wtype == "pwad" and #iwad_list > 0 then
        levels = wad_levels(iwad_list[selected_base].path)
    end
    return levels
end

-- The chosen start level, or the WAD's first when the saved name isn't in it
-- (a different WAD is selected now, or nothing has been chosen yet).
local function mp_selected_level()
    local levels = selected_levels()
    if #levels == 0 then return nil end
    for _, lv in ipairs(levels) do
        if lv.name == mp_level then return lv end
    end
    return levels[1]
end

-- Save bindings + settings to config file
local function save_config()
    local f = io.open(CFG_PATH, "w")
    if not f then return end
    kb:save_lines(f)
    f:write(string.format("sfx=%d\n", sfx_enabled and 1 or 0))
    f:write(string.format("music=%d\n", music_enabled and 1 or 0))
    f:write(string.format("mp_mode=%d\n", mp_mode))
    f:write(string.format("mp_players=%d\n", mp_players))
    f:write(string.format("mp_dm=%d\n", mp_dm))
    f:write(string.format("mp_skill=%d\n", mp_skill))
    f:write("mp_level=" .. mp_level .. "\n")
    f:write(string.format("mp_monsters=%d\n", mp_monsters and 1 or 0))
    f:write(string.format("mp_respawn=%d\n", mp_respawn and 1 or 0))
    f:write(string.format("mp_timer=%d\n", mp_timer_min))
    f:write("mp_ip=" .. mp_ip .. "\n")
    if #found_wads > 0 then
        f:write("wad=" .. found_wads[selected_wad].name .. "\n")
    end
    if #iwad_list > 0 then
        f:write("basewad=" .. iwad_list[selected_base].name .. "\n")
    end
    f:close()
end

-- Load bindings + settings from config file
local function load_config()
    kb:reset_defaults()
    local f = io.open(CFG_PATH, "r")
    if not f then return false end
    local text = f:read("*a")
    f:close()
    if not text then return false end
    for line in text:gmatch("[^\r\n]+") do
        -- Binding and trk_* lines are the library's; the patterns below are
        -- disjoint from them, so an unconsumed line just falls through.
        kb:load_line(line)
        local setting, val = line:match("^(%a+)=([01])$")
        if setting == "sfx" then sfx_enabled = (val == "1") end
        if setting == "music" then music_enabled = (val == "1") end
        local wname = line:match("^wad=(.+)$")
        if wname then selected_wad_name = wname end
        local bname = line:match("^basewad=(.+)$")
        if bname then selected_base_name = bname end
        -- Multiplayer choices; out-of-range values fall back to defaults.
        local mkey, mval = line:match("^mp_(%w+)=(.*)$")
        if mkey then
            local n = tonumber(mval)
            if mkey == "mode" and n and n >= 1 and n <= 4 then mp_mode = n
            elseif mkey == "players" and n and n >= 2 and n <= 4 then mp_players = n
            elseif mkey == "dm" and n and n >= 0 and n <= 2 then mp_dm = n
            elseif mkey == "skill" and n and n >= 1 and n <= 5 then mp_skill = n
            elseif mkey == "level" then mp_level = mval
            elseif mkey == "monsters" then mp_monsters = (mval == "1")
            elseif mkey == "respawn" then mp_respawn = (mval == "1")
            elseif mkey == "timer" and n then
                for _, m in ipairs(MP_TIMERS) do
                    if m == n then mp_timer_min = n end
                end
            elseif mkey == "ip" then mp_ip = mval
            end
        end
    end
    -- Migrate old backspace code: host used to produce 0x1B for backspace,
    -- now produces 0x08. Convert any saved bindings that reference 0x1B as
    -- a physical key to 0x08 so ESC/menu still works after the update.
    for _, a in ipairs(ACTIONS) do
        local b = kb:get(a.id)
        if b then
            if b.key1 == 0x1B then b.key1 = 0x08 end
            if b.key2 == 0x1B then b.key2 = 0x08 end
        end
    end
    -- Restore selections by name
    if selected_wad_name then
        for i, w in ipairs(found_wads) do
            if w.name == selected_wad_name then selected_wad = i; break end
        end
    end
    if selected_base_name then
        for i, b in ipairs(iwad_list) do
            if b.name == selected_base_name then selected_base = i; break end
        end
    end
    return true
end

-- ============================================================
-- Screen management
-- ============================================================
-- Stable, manager-registered root. Every view is a single navigable scope: one
-- flex container whose focusable children (buttons, dropdowns) are ALL direct
-- children, so gridnav's trackball/WASD navigation reaches every one of them
-- (it only walks direct children of the scope container). show_screen builds
-- the new view and hands it to nav.replace BEFORE deleting the old one, so the
-- outgoing gridnav stays alive across the handoff (App Library swap_view).
local root = apps.new_root({
    w = W, h = H,
    bg_color = "#000000", bg_opa = lvgl.OPA(255),
    border_width = 0, pad_all = 0,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)

local scr

local FONT = lvgl.BUILTIN_FONT.MONTSERRAT_12
local ACCENT = "#FF4444"

-- The Multiplayer screen's 1s link/WiFi status refresh; dies with its view.
local mp_timer

local function show_screen(builder)
    if mp_timer then mp_timer:delete(); mp_timer = nil end
    local old = scr
    scr = root:Object({
        w = W, h = H, x = 0, y = 0,
        bg_color = "#000000", bg_opa = lvgl.OPA(255),
        border_width = 0, pad_all = 8,
        flex = {
            flex_direction = "row", flex_wrap = "wrap",
            justify_content = "center", row_gap = 6, column_gap = 6,
        },
    })
    builder(scr)
    nav.replace(scr, { flags = nav.ROLLOVER + nav.SCROLL_FIRST })
    if old then apps.delete_view(old) end
end

-- A full-width, non-focusable heading/label (gridnav skips non-clickables).
local function heading(parent, text, color, font)
    return parent:Label{
        text = text,
        text_font = font or FONT,
        text_color = color or ACCENT,
        w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
    }
end

local function create_main_screen() end
local function create_help_screen() end
local function create_about_screen() end
local function create_multiplayer_screen() end

-- Controls, the key picker and the trackball Input screen all live in
-- lib/keybind. It renders through this app's show_screen, so the view stack,
-- nav flags and theme are unchanged; only the duplicated code is gone.
kb = keybind.new{
    actions     = ACTIONS,
    root        = root,
    show_screen = show_screen,
    font        = FONT,
    accent      = ACCENT,
    on_back     = function() create_main_screen() end,
    on_save     = save_config,
    trackball   = { momentum = true, impulse = 15, friction = 82, thresh = 4 },
}

-- Module argument list: WAD, base IWAD for mods, audio flags, the key and
-- trackball bindings, and the touch layout (staged for the next launch).
-- Shared by single-player Play and the Multiplayer screen, which appends its
-- own -netgame spec. Returns the list, or nil plus a status message.
local function build_launch_args()
    if #found_wads == 0 then return nil, "No WAD file found!" end
    local w = found_wads[selected_wad]
    local vfs_wad = to_vfs_path(w.path)
    local wad_dir = vfs_wad:match("^(.*)/") or "."
    local args
    if w.wtype == "pwad" then
        -- PWADs need a base IWAD
        if #iwad_list == 0 then return nil, "No base IWAD found!" end
        local base = iwad_list[selected_base]
        local vfs_base = to_vfs_path(base.path)
        args = {ELF_PATH, "-iwad", vfs_base,
                "-file", vfs_wad,
                "-configdir", wad_dir}
    else
        args = {ELF_PATH, "-iwad", vfs_wad,
                "-configdir", wad_dir}
    end
    -- Independent audio flags: -nosfx keeps music alive (the module pumps
    -- it via the music Poll), unlike -nosound.
    if not sfx_enabled then
        args[#args + 1] = "-nosfx"
    end
    if not music_enabled then
        args[#args + 1] = "-nomusic"
    end
    -- -keymap is omitted when nothing is bound, so the firmware falls back
    -- to passthrough rather than an empty table.
    local km = kb:keymap_string()
    if km then
        args[#args + 1] = "-keymap"
        args[#args + 1] = km
    end
    args[#args + 1] = "-trkball"
    args[#args + 1] = kb:trkball_string()
    if _elf_touch_layout and pad then
        local tl = pad:zones()
        if tl then _elf_touch_layout(tl) end
    end
    return args
end

-- ============================================================
-- Main screen
-- ============================================================
create_main_screen = function()
    show_screen(function(c)
        c:Label{
            text = "DOOM",
            text_font = lvgl.BUILTIN_FONT.MONTSERRAT_22,
            text_color = ACCENT,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        -- WAD selector — dropdown over all found WADs (mods tagged)
        local wad_opts = "No WADs found"
        if #found_wads > 0 then
            local names = {}
            for i, w in ipairs(found_wads) do
                names[i] = w.name .. (w.wtype == "pwad" and " (mod)" or "")
            end
            wad_opts = table.concat(names, "\n")
        end

        local wadDd = c:Dropdown{
            options = wad_opts,
            w = lvgl.PCT(100), h = 28,
        }
        if #found_wads > 0 then
            wadDd:set{ selected = selected_wad - 1 }
        end

        -- Base IWAD selector (shown only when a PWAD is selected)
        local base_lbl = c:Label{
            text = "Base game (for mods):",
            text_font = FONT, text_color = "#AAAAAA",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }
        local base_opts = "No base game"
        if #iwad_list > 0 then
            local names = {}
            for i, b in ipairs(iwad_list) do names[i] = b.name end
            base_opts = table.concat(names, "\n")
        end
        local baseDd = c:Dropdown{
            options = base_opts,
            w = lvgl.PCT(100), h = 28,
        }
        if #iwad_list > 0 then
            baseDd:set{ selected = selected_base - 1 }
        end

        local function update_base_visibility()
            local is_pwad = #found_wads > 0 and found_wads[selected_wad].wtype == "pwad"
            if is_pwad then
                base_lbl:clear_flag(lvgl.FLAG.HIDDEN)
                baseDd:clear_flag(lvgl.FLAG.HIDDEN)
            else
                base_lbl:add_flag(lvgl.FLAG.HIDDEN)
                baseDd:add_flag(lvgl.FLAG.HIDDEN)
            end
        end
        update_base_visibility()

        wadDd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
            if #found_wads == 0 then return end
            selected_wad = wadDd:get("selected") + 1
            update_base_visibility()
            save_config()
        end)

        baseDd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
            if #iwad_list == 0 then return end
            selected_base = baseDd:get("selected") + 1
            save_config()
        end)

        -- Status
        local has_wads = #found_wads > 0
        local status = c:Label{
            text = has_wads and "Ready to launch"
                   or "Place a .WAD in " .. sd_app_dir,
            text_font = FONT,
            text_color = has_wads and "#888888" or "#FF6666",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        -- Options: SFX + Music toggles
        local sfxBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        local sfxLbl = sfxBtn:Label{
            text = sfx_enabled and "SFX: ON" or "SFX: OFF",
            align = lvgl.ALIGN.CENTER,
        }
        sfxBtn:onClicked(function()
            sfx_enabled = not sfx_enabled
            sfxLbl:set{ text = sfx_enabled and "SFX: ON" or "SFX: OFF" }
            save_config()
        end)

        local musBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        local musLbl = musBtn:Label{
            text = music_enabled and "Music: ON" or "Music: OFF",
            align = lvgl.ALIGN.CENTER,
        }
        musBtn:onClicked(function()
            music_enabled = not music_enabled
            musLbl:set{ text = music_enabled and "Music: ON" or "Music: OFF" }
            save_config()
        end)

        -- Action buttons
        local launchBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
        launchBtn:Label{ text = "Play", align = lvgl.ALIGN.CENTER }
        launchBtn:onClicked(function()
            if #found_wads == 0 then
                status:set{ text = "No WAD file found!" }
                return
            end
            status:set{ text = "Loading Doom..." }
            lvgl.Timer{
                period = 50,
                cb = function(t)
                    t:delete()
                    local args, err = build_launch_args()
                    if not args then
                        status:set{ text = err }
                        return
                    end
                    -- Deferred launch: the firmware tears Lua down, runs Doom, then
                    -- recreates Lua and returns to the launcher home. _launch_elf only
                    -- queues the request, so there's no result to handle here.
                    _launch_elf(table.unpack(args))
                end
            }
        end)

        local ctrlBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
        ctrlBtn:Label{ text = "Controls", align = lvgl.ALIGN.CENTER }
        ctrlBtn:onClicked(function() kb:open() end)

        local mpBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
        mpBtn:Label{ text = "Multiplayer", align = lvgl.ALIGN.CENTER }
        mpBtn:onClicked(function() create_multiplayer_screen() end)

        if pad then
            local touchBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
            touchBtn:Label{ text = "Touch", align = lvgl.ALIGN.CENTER }
            touchBtn:onClicked(function()
                pad:open{
                    show_screen = show_screen, font = FONT, accent = ACCENT,
                    on_back = function() create_main_screen() end,
                }
            end)
        end

        local quitBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
        quitBtn:Label{ text = "Quit", align = lvgl.ALIGN.CENTER }
        quitBtn:onClicked(function()
            apps.go_home()   -- manager tears down the stable root (and its current view)
        end)

        -- Documents the firmware's quit chord
        local helpBtn = c:Button{ w = lvgl.PCT(48), h = 30 }
        helpBtn:Label{ text = "Quit help", align = lvgl.ALIGN.CENTER }
        helpBtn:onClicked(function() create_help_screen() end)

        local aboutBtn = c:Button{ w = lvgl.PCT(48), h = 30 }
        aboutBtn:Label{ text = "About", align = lvgl.ALIGN.CENTER }
        aboutBtn:onClicked(function() create_about_screen() end)
    end)
end

-- ============================================================
-- Multiplayer screen — every network choice is made here; the game itself
-- only shows status text while it connects and waits (no dialogs of its
-- own). The choices reach the module as one argument, "-netgame <spec>".
-- Host: waits until `players` decks are in, then starts with these options.
-- Join: over the USB cable, by searching the WiFi network, or by address.
-- ============================================================
local function mp_spec()
    local t = {}
    if mp_mode == 1 then
        t[#t + 1] = "host"
        t[#t + 1] = "players=" .. mp_players
        t[#t + 1] = "dm=" .. mp_dm
        t[#t + 1] = "skill=" .. mp_skill
        -- Start level. The module takes an episode and a map and applies
        -- whichever its WAD's game type uses; both are omitted when the
        -- WAD's levels could not be read, leaving the game's own first one.
        local lv = mp_selected_level()
        if lv then
            if lv.ep > 0 then t[#t + 1] = "ep=" .. lv.ep end
            t[#t + 1] = "map=" .. lv.map
        end
        if not mp_monsters then t[#t + 1] = "nomon=1" end
        if mp_respawn then t[#t + 1] = "respawn=1" end
        if mp_timer_min > 0 then t[#t + 1] = "timer=" .. mp_timer_min end
    elseif mp_mode == 2 then
        t[#t + 1] = "join=usb"
    elseif mp_mode == 3 then
        t[#t + 1] = "join=lan"
    else
        t[#t + 1] = "join=" .. mp_ip
    end
    return table.concat(t, ",")
end

-- Kick the firmware's saved-network connect round and poll for it (the
-- downloader's wifi_wait pattern). cb(connected) runs on the event loop.
local function wifi_wait(wait_ms, cb)
    if _wifi_status() == "connected" then cb(true) return end
    pcall(_wifi_auto_connect)
    local waited = 0
    lvgl.Timer{ period = 500, cb = function(t)
        if _wifi_status() == "connected" then
            t:delete()
            cb(true)
            return
        end
        waited = waited + 500
        if waited >= wait_ms then
            t:delete()
            cb(false)
        end
    end }
end

local function cable_up()
    return _gblink_status ~= nil and _gblink_status() > 0
end

create_multiplayer_screen = function()
    show_screen(function(c)
        heading(c, "MULTIPLAYER", ACCENT)

        local modeDd = c:Dropdown{
            options = "Host a game\nJoin over USB cable\n"
                   .. "Join over WiFi (search)\nJoin over WiFi (address)",
            w = lvgl.PCT(100), h = 28,
        }
        modeDd:set{ selected = mp_mode - 1 }

        local ipTa = c:Textarea{
            password_mode = false, one_line = true,
            placeholder_text = "host address, e.g. 192.168.1.5",
            text = mp_ip,
            w = lvgl.PCT(100), h = 30,
        }
        ipTa:clear_flag(lvgl.FLAG.SCROLLABLE)

        -- Host options: label + control pairs, all direct children of the
        -- scope container so the trackball reaches every control.
        local function opt_label(text)
            return c:Label{
                text = text, text_font = FONT, text_color = "#AAAAAA",
                w = lvgl.PCT(48), h = 28,
            }
        end
        local function opt_dropdown(options, selected)
            local dd = c:Dropdown{ options = options, w = lvgl.PCT(48), h = 28 }
            dd:set{ selected = selected }
            return dd
        end

        local playersLbl = opt_label("Players")
        local playersDd = opt_dropdown("2\n3\n4", mp_players - 2)
        playersDd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
            mp_players = playersDd:get("selected") + 2
            save_config()
        end)

        local gameLbl = opt_label("Game")
        local gameDd = opt_dropdown("Co-op\nDeathmatch\nDeathmatch 2", mp_dm)
        gameDd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
            mp_dm = gameDd:get("selected")
            save_config()
        end)

        local skillLbl = opt_label("Skill")
        local skillDd = opt_dropdown(
            "1 Too young to die\n2 Not too rough\n3 Hurt me plenty\n"
         .. "4 Ultra-Violence\n5 Nightmare", mp_skill - 1)
        skillDd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
            mp_skill = skillDd:get("selected") + 1
            save_config()
        end)

        -- Start level: exactly the levels the chosen WAD holds, read from the
        -- WAD itself, so Doom 1 offers E1M1.. and Doom 2 offers MAP01.. and
        -- neither offers a level that isn't there.
        local levels = selected_levels()
        local level_names, level_sel = {}, 0
        if #levels == 0 then
            level_names[1] = "First level"
        else
            local matched = false
            for i, lv in ipairs(levels) do
                level_names[i] = lv.name
                if lv.name == mp_level then
                    level_sel = i - 1
                    matched = true
                end
            end
            if not matched then mp_level = levels[1].name end
        end
        local levelLbl = opt_label("Start level")
        local levelDd = opt_dropdown(table.concat(level_names, "\n"), level_sel)
        levelDd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
            local lv = levels[levelDd:get("selected") + 1]
            if lv then
                mp_level = lv.name
                save_config()
            end
        end)

        local timer_names, timer_sel = {}, 0
        for i, m in ipairs(MP_TIMERS) do
            timer_names[i] = (m == 0) and "No limit" or (m .. " min")
            if m == mp_timer_min then timer_sel = i - 1 end
        end
        local timerLbl = opt_label("Level time limit")
        local timerDd = opt_dropdown(table.concat(timer_names, "\n"), timer_sel)
        timerDd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
            mp_timer_min = MP_TIMERS[timerDd:get("selected") + 1]
            save_config()
        end)

        local monBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        local monLbl = monBtn:Label{
            text = mp_monsters and "Monsters: ON" or "Monsters: OFF",
            align = lvgl.ALIGN.CENTER,
        }
        monBtn:onClicked(function()
            mp_monsters = not mp_monsters
            monLbl:set{ text = mp_monsters and "Monsters: ON" or "Monsters: OFF" }
            save_config()
        end)

        local respBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        local respLbl = respBtn:Label{
            text = mp_respawn and "Respawn: ON" or "Respawn: OFF",
            align = lvgl.ALIGN.CENTER,
        }
        respBtn:onClicked(function()
            mp_respawn = not mp_respawn
            respLbl:set{ text = mp_respawn and "Respawn: ON" or "Respawn: OFF" }
            save_config()
        end)

        local host_widgets = {
            playersLbl, playersDd, gameLbl, gameDd, skillLbl, skillDd,
            levelLbl, levelDd, timerLbl, timerDd, monBtn, respBtn,
        }
        local function apply_mode()
            for _, wdg in ipairs(host_widgets) do
                if mp_mode == 1 then
                    wdg:clear_flag(lvgl.FLAG.HIDDEN)
                else
                    wdg:add_flag(lvgl.FLAG.HIDDEN)
                end
            end
            if mp_mode == 4 then
                ipTa:clear_flag(lvgl.FLAG.HIDDEN)
            else
                ipTa:add_flag(lvgl.FLAG.HIDDEN)
            end
        end
        apply_mode()
        modeDd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
            mp_mode = modeDd:get("selected") + 1
            apply_mode()
            save_config()
        end)

        -- Live link + WiFi status (both can change while this screen is up).
        local stat = c:Label{
            text = "", text_font = FONT, text_color = "#FFCC44",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }
        local function refresh_status()
            local s, ip = _wifi_status()
            local wifi
            if s == "connected" then wifi = "WiFi: " .. ip
            elseif s == "connecting" then wifi = "WiFi: connecting..."
            else wifi = "WiFi: " .. s end
            stat:set{ text = (cable_up() and "USB link: connected" or "USB link: none")
                          .. "\n" .. wifi }
        end
        refresh_status()
        mp_timer = lvgl.Timer{ period = 1000, cb = refresh_status }

        local startBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
        startBtn:Label{ text = "Start", align = lvgl.ALIGN.CENTER }
        startBtn:onClicked(function()
            mp_ip = (ipTa.text or ""):gsub("%s+", "")
            save_config()
            if mp_mode == 4 and mp_ip == "" then
                stat:set{ text = "Enter the host's address first" }
                return
            end
            if mp_mode == 2 and not cable_up() then
                stat:set{ text = "No USB link - connect the cable" }
                return
            end

            local function go()
                local args, err = build_launch_args()
                if not args then
                    stat:set{ text = err }
                    return
                end
                args[#args + 1] = "-netgame"
                args[#args + 1] = mp_spec()
                stat:set{ text = "Loading Doom..." }
                lvgl.Timer{ period = 50, cb = function(t)
                    t:delete()
                    _launch_elf(table.unpack(args))
                end }
            end

            local wifi_on = (_wifi_get_enabled == nil) or _wifi_get_enabled()
            if mp_mode == 2 then
                go()
            elseif mp_mode == 1 then
                -- A host listens on whatever is up: the cable, WiFi, or both.
                if wifi_on and _wifi_status() ~= "connected" then
                    stat:set{ text = "Connecting WiFi..." }
                    wifi_wait(15000, function(ok)
                        if ok or cable_up() then
                            go()
                        else
                            stat:set{ text = "No USB link and no WiFi" }
                        end
                    end)
                elseif _wifi_status() == "connected" or cable_up() then
                    go()
                else
                    stat:set{ text = "No USB link and no WiFi" }
                end
            else
                if not wifi_on then
                    stat:set{ text = "Turn WiFi on first (Settings)" }
                    return
                end
                stat:set{ text = "Connecting WiFi..." }
                wifi_wait(15000, function(ok)
                    if ok then
                        go()
                    else
                        stat:set{ text = "WiFi did not connect" }
                    end
                end)
            end
        end)

        local backBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
        backBtn:Label{ text = "Back", align = lvgl.ALIGN.CENTER }
        backBtn:onClicked(function()
            mp_ip = (ipTa.text or ""):gsub("%s+", "")
            save_config()
            create_main_screen()
        end)
    end)
end

-- ============================================================
-- Quit help screen (firmware-wide Alt+Backspace exit chord)
-- ============================================================
create_help_screen = function()
    show_screen(function(c)
        heading(c, "QUIT TO LAUNCHER", ACCENT)

        c:Label{
            text = "While the game is running, hold\n"
                 .. "ALT + Backspace for about 1.5 seconds\n"
                 .. "to quit back to the launcher.\n\n"
                 .. "Or tap the Quit key - Y by default,\n"
                 .. "rebindable under Controls. That is the\n"
                 .. "only exit on a device in legacy\n"
                 .. "keyboard mode, where holds and key\n"
                 .. "combos do not register.",
            text_font = FONT,
            text_color = "#CCCCCC",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        local okBtn = c:Button{ w = lvgl.PCT(60), h = 30 }
        okBtn:Label{ text = "OK", align = lvgl.ALIGN.CENTER }
        okBtn:onClicked(function() create_main_screen() end)
    end)
end

-- ============================================================
-- About screen — engine license and credits.
-- The scope container scrolls (nav.SCROLL_FIRST), so the text runs
-- past the panel height without extra machinery.
-- ============================================================
create_about_screen = function()
    show_screen(function(c)
        heading(c, "ABOUT", ACCENT)

        c:Label{
            text = "DOOM engine\n"
                 .. "(c) 1993-1996 id Software, Inc.\n"
                 .. "License: GNU GPL v2\n\n"
                 .. "Port: doomgeneric by ozkl\n"
                 .. "github.com/ozkl/doomgeneric\n"
                 .. "Descends from Chocolate Doom\n"
                 .. "(c) 2005-2014 Simon Howard\n\n"
                 .. "Music and sound effects:\n"
                 .. "Chocolate Doom OPL/MIDI stack\n"
                 .. "  (c) 2005-2014 Simon Howard\n"
                 .. "DOSBox dbopl OPL emulator\n"
                 .. "  (c) 2002-2010 The DOSBox Team\n"
                 .. "MUS to MIDI conversion\n"
                 .. "  (c) 2006 Ben Ryves\n\n"
                 .. "DOOM is a trademark of id Software.\n"
                 .. "No WAD game data is included -\n"
                 .. "supply your own. Freedoom is a\n"
                 .. "freely licensed IWAD if you don't\n"
                 .. "own a copy of DOOM.",
            text_font = FONT,
            text_color = "#CCCCCC",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        local okBtn = c:Button{ w = lvgl.PCT(60), h = 30 }
        okBtn:Label{ text = "OK", align = lvgl.ALIGN.CENTER }
        okBtn:onClicked(function() create_main_screen() end)
    end)
end

-- ============================================================
-- Startup: load config (or defaults) and show main screen
-- ============================================================
-- keybind.new already seeded the defaults; load_config re-seeds then parses.
-- Return a deferred init function. The sublauncher calls this once per event
-- loop tick (inside its loadingPopUpAdd), keeping the watchdog fed between steps.
local init_phase = 0
local classify_idx = 0
return function()
    init_phase = init_phase + 1

    -- Phases 1-3: directory scanning (no file I/O per WAD)
    if init_phase == 1 then
        scan_dir_for_wads(app_dir)
        return false
    elseif init_phase == 2 then
        scan_dir_for_wads(sd_app_dir)
        return false
    elseif init_phase == 3 then
        if sd_app_dir ~= "S:/doom" then
            scan_dir_for_wads("S:/doom")
        end
        classify_idx = 0
        return false
    end

    -- Phases 4..4+N: classify one WAD header per tick (one SD open each)
    classify_idx = classify_idx + 1
    if classify_idx <= #found_wads then
        local w = found_wads[classify_idx]
        w.wtype = wad_type(w.path)
        return false
    end

    -- Final phase: sort, build IWAD list, config, screen
    table.sort(found_wads, function(a, b)
        if a.wtype ~= b.wtype then return a.wtype == "iwad" end
        return a.name:lower() < b.name:lower()
    end)
    for i, w in ipairs(found_wads) do
        if w.wtype == "iwad" then
            iwad_list[#iwad_list + 1] = { idx = i, name = w.name, path = w.path }
        end
    end
    load_config()
    create_main_screen()
    return true
end

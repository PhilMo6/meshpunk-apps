local lvgl = require("lvgl")
local apps = require("lib/apps")
local nav = require("lib/nav")
local fileman = require("lib/fileman")

local app_dir = ...

local W = lvgl.HOR_RES()
local H = lvgl.VER_RES()

-- ============================================================
-- SNES (snes9x) Launcher
-- ============================================================

local TITLE     = "SNES"
local ACCENT    = "#7F00FF"
local ELF_NAME  = "snes.app.elf"
local ROM_HINT  = "Place .smc/.sfc ROMs in S:/snes/"
local EXTRA_DIR = "S:/snes"
local function is_rom(name)
    return name:match("%.smc$") or name:match("%.sfc$") or name:match("%.fig$")
end

-- Derive SD-side mirror of app directory:
-- "L:/lua/apps/Games/SNES" -> "S:/lua/apps/Games/SNES"
local sd_app_dir = app_dir:gsub("^L:", "S:")

-- ROM paths are converted for the ELF module's fopen; the ELF path itself is
-- passed raw — the loader reads L:/S: prefixes natively.
local function to_vfs_path(path)
    if path:sub(1, 2) == "S:" then return "/sd" .. path:sub(3) end
    if path:sub(1, 2) == "L:" then return "/littlefs" .. path:sub(3) end
    return path
end

local function find_file(name)
    local search = { app_dir, sd_app_dir }
    for _, dir in ipairs(search) do
        local path = dir .. "/" .. name
        local f = io.open(path, "r")
        if f then f:close(); return path end
    end
    return nil
end

local CFG_PATH = app_dir .. "/launcher.cfg"
local ELF_PATH = find_file(ELF_NAME)

-- ============================================================
-- Keymap / controls system (host-side translation, same as GameBoy/NGPC:
-- the -keymap string maps physical keys to the codes the module reads)
-- ============================================================

-- Codes main_tdeck.c's poll_input() understands.
local SNES = {
    UP     = 0x77,  -- 'w'
    DOWN   = 0x73,  -- 's'
    LEFT   = 0x61,  -- 'a'
    RIGHT  = 0x64,  -- 'd'
    A      = 0x6D,  -- 'm'
    B      = 0x6E,  -- 'n'
    X      = 0x6B,  -- 'k'
    Y      = 0x6A,  -- 'j'
    L      = 0x71,  -- 'q'
    R      = 0x70,  -- 'p'
    START  = 0x0D,  -- Enter
    SELECT = 0x20,  -- Space
}

-- Physical key names -> hex codes for the keymap string.
local KEYS = {
    a=0x61, b=0x62, c=0x63, d=0x64, e=0x65, f=0x66, g=0x67, h=0x68,
    i=0x69, j=0x6A, k=0x6B, l=0x6C, m=0x6D, n=0x6E, o=0x6F, p=0x70,
    q=0x71, r=0x72, s=0x73, t=0x74, u=0x75, v=0x76, w=0x77, x=0x78,
    z=0x7A,
    Space  = 0x20,
    Enter  = 0x0D,
    BkSpc  = 0x08,
    Shift  = 0x80,
    TrkUp  = 0x81,
    TrkDn  = 0x82,
    TrkLt  = 0x83,
    TrkRt  = 0x84,
    TrkClk = 0x85,
}

local KEY_NAMES = {}
for name, code in pairs(KEYS) do KEY_NAMES[code] = name end

-- Action definitions: {id, label, target code, default key1, default key2}
local ACTIONS = {
    { id="up",     label="Up",     snes=SNES.UP,     key1=KEYS.w,     key2=KEYS.TrkUp  },
    { id="down",   label="Down",   snes=SNES.DOWN,   key1=KEYS.s,     key2=KEYS.TrkDn  },
    { id="left",   label="Left",   snes=SNES.LEFT,   key1=KEYS.a,     key2=KEYS.TrkLt  },
    { id="right",  label="Right",  snes=SNES.RIGHT,  key1=KEYS.d,     key2=KEYS.TrkRt  },
    { id="btn_a",  label="A btn",  snes=SNES.A,      key1=KEYS.m,     key2=KEYS.TrkClk },
    { id="btn_b",  label="B btn",  snes=SNES.B,      key1=KEYS.n,     key2=nil         },
    { id="btn_x",  label="X btn",  snes=SNES.X,      key1=KEYS.k,     key2=nil         },
    { id="btn_y",  label="Y btn",  snes=SNES.Y,      key1=KEYS.j,     key2=nil         },
    { id="btn_l",  label="L btn",  snes=SNES.L,      key1=KEYS.q,     key2=nil         },
    { id="btn_r",  label="R btn",  snes=SNES.R,      key1=KEYS.p,     key2=nil         },
    { id="start",  label="Start",  snes=SNES.START,  key1=KEYS.Enter, key2=nil         },
    { id="select", label="Select", snes=SNES.SELECT, key1=KEYS.BkSpc, key2=nil         },
}

local bindings = {}  -- bindings[action_id] = {snes=N, key1=N|nil, key2=N|nil}

local function load_defaults()
    bindings = {}
    for _, a in ipairs(ACTIONS) do
        bindings[a.id] = { snes = a.snes, key1 = a.key1, key2 = a.key2 }
    end
end
load_defaults()

-- Build the -keymap hex string from current bindings
local function build_keymap_string()
    local parts = {}
    for _, a in ipairs(ACTIONS) do
        local b = bindings[a.id]
        if b and (b.key1 or b.key2) then
            local s = string.format("%02X=", b.snes)
            if b.key1 then
                s = s .. string.format("%02X", b.key1)
                if b.key2 then
                    s = s .. string.format("+%02X", b.key2)
                end
            elseif b.key2 then
                s = s .. string.format("%02X", b.key2)
            end
            parts[#parts + 1] = s
        end
    end
    return table.concat(parts, ",")
end

-- Renderer: 0 = Speed (Core-1 worker), 1 = Accuracy (Core 0).
-- The worker binds one frame-boundary snapshot of the palette and BG base
-- registers, so games that rewrite those mid-frame (HDMA colour gradients,
-- mid-frame base switches) render them wrong. Core 0 re-reads them per span.
local renderer = 0

-- Trackball momentum settings (host-side model, same values as GameBoy/NGPC)
local trk_momentum = true
local trk_impulse  = 15       -- impulse * 10 (1.5 -> 15)
local trk_friction = 82       -- friction * 100 (0.82 -> 82)
local trk_thresh   = 4        -- threshold * 10 (0.4 -> 4)

local function build_trkball_string()
    return string.format("%d,%d,%d,%d",
        trk_momentum and 1 or 0, trk_impulse, trk_friction, trk_thresh)
end

local function key_display(code)
    if not code then return "---" end
    return KEY_NAMES[code] or string.format("0x%02X", code)
end

local BINDABLE_KEYS = {}
for name, code in pairs(KEYS) do
    BINDABLE_KEYS[#BINDABLE_KEYS + 1] = { name = name, code = code }
end
table.sort(BINDABLE_KEYS, function(a, b) return a.name < b.name end)

local found_roms = {}   -- { {name, path}, ... }
local seen_lower = {}
local selected_rom = 1
local selected_rom_name = nil
local scr = nil

-- Stable, manager-registered root (same pattern as the GameBoy launcher).
local root = apps.new_root({
    w = W, h = H,
    bg_color = "#000000", bg_opa = lvgl.OPA(255),
    border_width = 0, pad_all = 0,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)

-- fileman routes the drive from the L:/S: prefix itself; sizes=false skips
-- the per-entry size lookup, so huge ROM folders list fast (watchdog-safe).
local function scan_dir_for_roms(dir_path)
    local entries = fileman.list(dir_path, {
        sizes = false,
        filter = function(e)
            return e.type == "file" and is_rom(e.name:lower())
        end,
    }) or {}
    for _, e in ipairs(entries) do
        local low = e.name:lower()
        if not seen_lower[low] then
            seen_lower[low] = true
            found_roms[#found_roms + 1] = {
                name = e.name,
                path = dir_path .. "/" .. e.name,
            }
        end
    end
end

-- Remember key bindings, trackball tuning and the last played ROM.
local function save_config()
    local f = io.open(CFG_PATH, "w")
    if not f then return end
    for _, a in ipairs(ACTIONS) do
        local b = bindings[a.id]
        local k1 = b.key1 and string.format("%02X", b.key1) or "--"
        local k2 = b.key2 and string.format("%02X", b.key2) or "--"
        f:write(a.id .. "=" .. k1 .. "," .. k2 .. "\n")
    end
    f:write(string.format("renderer=%d\n", renderer))
    f:write(string.format("trk_momentum=%d\n", trk_momentum and 1 or 0))
    f:write(string.format("trk_impulse=%d\n", trk_impulse))
    f:write(string.format("trk_friction=%d\n", trk_friction))
    f:write(string.format("trk_thresh=%d\n", trk_thresh))
    if #found_roms > 0 then
        f:write("rom=" .. found_roms[selected_rom].name .. "\n")
    end
    f:close()
end

local function load_config()
    load_defaults()
    local f = io.open(CFG_PATH, "r")
    if not f then return end
    local text = f:read("*a")
    f:close()
    if not text then return end
    for line in text:gmatch("[^\r\n]+") do
        local id, k1s, k2s = line:match("^([%w_]+)=(%S+),(%S+)$")
        if id and bindings[id] then
            bindings[id].key1 = (k1s ~= "--") and tonumber(k1s, 16) or nil
            bindings[id].key2 = (k2s ~= "--") and tonumber(k2s, 16) or nil
        end
        local rmode = line:match("^renderer=([01])$")
        if rmode then renderer = tonumber(rmode) end
        local val = line:match("^trk_momentum=([01])$")
        if val then trk_momentum = (val == "1") end
        local trk_key, trk_val = line:match("^(trk_%a+)=(%d+)$")
        if trk_key == "trk_impulse" then trk_impulse = tonumber(trk_val) end
        if trk_key == "trk_friction" then trk_friction = tonumber(trk_val) end
        if trk_key == "trk_thresh" then trk_thresh = tonumber(trk_val) end
        local rname = line:match("^rom=(.+)$")
        if rname then selected_rom_name = rname end
    end
end

-- ============================================================
-- Screen management — single navigable scope per view, focusables as direct
-- children; the new view goes to nav.replace BEFORE the old one is deleted
-- (GameBoy/App Library swap_view pattern).
-- ============================================================
local FONT = lvgl.BUILTIN_FONT.MONTSERRAT_12

local function show_screen(builder)
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

-- A label + value button pair; the value button cycles and persists.
local function setting_row(parent, label, get_text, on_click)
    parent:Label{
        text = label,
        text_font = FONT,
        text_color = "#CCCCCC",
        w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
    }
    local valBtn = parent:Button{ w = lvgl.PCT(100), h = 28 }
    local valLbl = valBtn:Label{
        text = get_text(),
        text_font = FONT,
        align = lvgl.ALIGN.CENTER,
    }
    valBtn:onClicked(function()
        on_click()
        valLbl:set{ text = get_text() }
        save_config()
    end)
    return valBtn
end

local create_main_screen
local create_help_screen
local create_about_screen
local create_controls_screen
local create_bind_screen
local create_input_screen

-- ============================================================
-- Main screen
-- ============================================================
create_main_screen = function()
    show_screen(function(c)
        c:Label{
            text = TITLE,
            text_font = lvgl.BUILTIN_FONT.MONTSERRAT_22,
            text_color = ACCENT,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        -- ROM selector — dropdown over all found ROMs
        local rom_opts = "No ROMs found"
        if #found_roms > 0 then
            local names = {}
            for i, r in ipairs(found_roms) do names[i] = r.name end
            rom_opts = table.concat(names, "\n")
        end

        local romDd = c:Dropdown{
            options = rom_opts,
            w = lvgl.PCT(100), h = 30,
        }
        if #found_roms > 0 then
            romDd:set{ selected = selected_rom - 1 }
        end
        romDd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
            if #found_roms == 0 then return end
            selected_rom = romDd:get("selected") + 1
            save_config()
        end)

        -- One row rather than a setting_row pair: the main screen is tight,
        -- and this is the control most likely to be changed per game.
        local function rend_text()
            return (renderer == 0) and "Renderer: Speed" or "Renderer: Accuracy"
        end
        local rendBtn = c:Button{ w = lvgl.PCT(100), h = 28 }
        local rendLbl = rendBtn:Label{
            text = rend_text(),
            text_font = FONT,
            align = lvgl.ALIGN.CENTER,
        }
        rendBtn:onClicked(function()
            renderer = (renderer == 0) and 1 or 0
            rendLbl:set{ text = rend_text() }
            save_config()
        end)

        local has_elf = ELF_PATH ~= nil
        local has_roms = #found_roms > 0
        local status = c:Label{
            text = (not has_elf) and (ELF_NAME .. " not found!")
                or (has_roms and "Ready to play" or ROM_HINT),
            text_font = FONT,
            text_color = (has_elf and has_roms) and "#888888" or "#FF6666",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        local launchBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
        launchBtn:Label{ text = "Play", align = lvgl.ALIGN.CENTER }
        launchBtn:onClicked(function()
            if not ELF_PATH then
                status:set{ text = ELF_NAME .. " not found!" }
                return
            end
            if #found_roms == 0 then
                status:set{ text = "No ROMs found!" }
                return
            end
            status:set{ text = "Loading..." }
            local km = build_keymap_string()
            local ts = build_trkball_string()
            lvgl.Timer{
                period = 50,
                cb = function(t)
                    t:delete()
                    local r = found_roms[selected_rom]
                    -- Deferred launch: the firmware tears Lua down, runs the
                    -- module, then recreates Lua and returns to the launcher.
                    -- -stackkb 24: snes9x's loop is iterative; the smaller
                    -- rung fits when internal RAM has no free 32KB block.
                    _launch_elf(ELF_PATH, to_vfs_path(r.path),
                        "-stackkb", "24",
                        "-render", tostring(renderer),
                        "-keymap", km,
                        "-trkball", ts)
                end
            }
        end)

        local ctrlBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
        ctrlBtn:Label{ text = "Controls", align = lvgl.ALIGN.CENTER }
        ctrlBtn:onClicked(function() create_controls_screen() end)

        local helpBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
        helpBtn:Label{ text = "Quit help", align = lvgl.ALIGN.CENTER }
        helpBtn:onClicked(function() create_help_screen() end)

        local aboutBtn = c:Button{ w = lvgl.PCT(48), h = 30 }
        aboutBtn:Label{ text = "About", align = lvgl.ALIGN.CENTER }
        aboutBtn:onClicked(function() create_about_screen() end)

        local quitBtn = c:Button{ w = lvgl.PCT(48), h = 30 }
        quitBtn:Label{ text = "Quit", align = lvgl.ALIGN.CENTER }
        quitBtn:onClicked(function()
            apps.go_home()   -- manager tears down the stable root
        end)
    end)
end

-- ============================================================
-- Quit help screen (firmware-wide Alt+Backspace exit chord)
-- ============================================================
create_help_screen = function()
    show_screen(function(c)
        c:Label{
            text = "QUIT TO LAUNCHER",
            text_font = FONT,
            text_color = ACCENT,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        c:Label{
            text = "While the game is running, hold\n"
                 .. "ALT + Backspace for about 1.5 seconds\n"
                 .. "to quit back to the launcher.\n\n"
                 .. "Works in every game and emulator,\n"
                 .. "on the built-in and USB keyboards.",
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
-- About screen — emulator license and credits.
-- The scope container scrolls (nav.SCROLL_FIRST), so the text runs
-- past the panel height without extra machinery.
-- ============================================================
create_about_screen = function()
    show_screen(function(c)
        c:Label{
            text = "ABOUT",
            text_font = FONT,
            text_color = ACCENT,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        c:Label{
            text = "SNES emulation by Snes9x, via the\n"
                 .. "retro-go pure-C port, based on\n"
                 .. "libretro snes9x2010.\n\n"
                 .. "LICENSE - PLEASE NOTE:\n"
                 .. "Snes9x is NOT free software. It may\n"
                 .. "be used and distributed for\n"
                 .. "NON-COMMERCIAL, personal use only.\n"
                 .. "Commercial use requires permission\n"
                 .. "from the copyright holders.\n\n"
                 .. "Also includes:\n"
                 .. "ndssfc (GPL v2) (c) 2010 dking,\n"
                 .. "  BassAceGold, ShadauxCat, Nebuleon\n"
                 .. "ZSNES code (GPL v2)\n"
                 .. "  (c) 1997-2001 ZSNES Team\n\n"
                 .. "Snes9x (c) Gary Henderson,\n"
                 .. "Jerremy Koot, John Weidman,\n"
                 .. "Brad Jorsch, Nach, zones, BearOso,\n"
                 .. "OV2, byuu, neviksti, Shay Green\n"
                 .. "and many others - the full list is\n"
                 .. "in the source tree's LICENSE.\n\n"
                 .. "Super Nintendo is a trademark of\n"
                 .. "Nintendo. No game ROMs are included\n"
                 .. "- supply your own.",
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
-- Controls overview screen
-- ============================================================
create_controls_screen = function()
    show_screen(function(c)
        c:Label{
            text = "CONTROLS",
            text_font = FONT,
            text_color = ACCENT,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        for idx, a in ipairs(ACTIONS) do
            local b = bindings[a.id]

            c:Label{
                text = a.label,
                text_font = FONT,
                text_color = "#CCCCCC",
                w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
            }

            local k1btn = c:Button{ w = lvgl.PCT(48), h = 26 }
            k1btn:Label{
                text = key_display(b.key1),
                text_font = FONT,
                align = lvgl.ALIGN.CENTER,
            }
            k1btn:onClicked(function() create_bind_screen(idx, 1) end)

            local k2btn = c:Button{ w = lvgl.PCT(48), h = 26 }
            k2btn:Label{
                text = key_display(b.key2),
                text_font = FONT,
                align = lvgl.ALIGN.CENTER,
            }
            k2btn:onClicked(function() create_bind_screen(idx, 2) end)
        end

        local defBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        defBtn:Label{ text = "Defaults", text_font = FONT, align = lvgl.ALIGN.CENTER }
        defBtn:onClicked(function()
            load_defaults()
            save_config()
            create_controls_screen()
        end)

        local inputBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        inputBtn:Label{ text = "Input", text_font = FONT, align = lvgl.ALIGN.CENTER }
        inputBtn:onClicked(function() create_input_screen() end)

        local backBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        backBtn:Label{ text = "Back", text_font = FONT, align = lvgl.ALIGN.CENTER }
        backBtn:onClicked(function() create_main_screen() end)
    end)
end

-- ============================================================
-- Key binding picker screen
-- ============================================================
create_bind_screen = function(action_idx, slot)
    local a = ACTIONS[action_idx]
    local b = bindings[a.id]
    show_screen(function(c)
        local slot_name = (slot == 1) and "Primary" or "Alt"
        c:Label{
            text = a.label .. " - " .. slot_name,
            text_font = FONT,
            text_color = ACCENT,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        local current = (slot == 1) and b.key1 or b.key2

        local clrBtn = c:Button{ w = lvgl.PCT(100), h = 24 }
        clrBtn:Label{ text = "--- (clear)", text_font = FONT, align = lvgl.ALIGN.CENTER }
        clrBtn:onClicked(function()
            if slot == 1 then b.key1 = nil else b.key2 = nil end
            save_config()
            create_controls_screen()
        end)

        for _, k in ipairs(BINDABLE_KEYS) do
            local btn = c:Button{ w = lvgl.PCT(48), h = 24 }
            local lbl = k.name
            if k.code == current then lbl = "> " .. lbl .. " <" end
            btn:Label{ text = lbl, text_font = FONT, align = lvgl.ALIGN.CENTER }
            btn:onClicked(function()
                if slot == 1 then b.key1 = k.code else b.key2 = k.code end
                save_config()
                create_controls_screen()
            end)
        end

        local cancelBtn = c:Button{ w = lvgl.PCT(100), h = 26 }
        cancelBtn:Label{ text = "Cancel", text_font = FONT, align = lvgl.ALIGN.CENTER }
        cancelBtn:onClicked(function() create_controls_screen() end)
    end)
end

-- ============================================================
-- Input settings screen (trackball momentum tuning)
-- ============================================================
create_input_screen = function()
    show_screen(function(c)
        c:Label{
            text = "INPUT SETTINGS",
            text_font = FONT,
            text_color = ACCENT,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        setting_row(c, "Momentum",
            function() return trk_momentum and "< ON >" or "< OFF >" end,
            function() trk_momentum = not trk_momentum end
        )

        setting_row(c, "Sensitivity",
            function() return string.format("< %.1f >", trk_impulse / 10) end,
            function()
                trk_impulse = trk_impulse + 1
                if trk_impulse > 30 then trk_impulse = 5 end
            end
        )

        setting_row(c, "Friction",
            function() return string.format("< %.2f >", trk_friction / 100) end,
            function()
                trk_friction = trk_friction + 2
                if trk_friction > 95 then trk_friction = 50 end
            end
        )

        setting_row(c, "Dead Zone",
            function() return string.format("< %.1f >", trk_thresh / 10) end,
            function()
                trk_thresh = trk_thresh + 1
                if trk_thresh > 10 then trk_thresh = 2 end
            end
        )

        c:Label{
            text = "Sensitivity: impulse per tick\n"
                 .. "Friction: decay rate (lower=faster stop)\n"
                 .. "Dead Zone: min velocity to register",
            text_font = FONT,
            text_color = "#666666",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        local resetBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        resetBtn:Label{ text = "Reset", text_font = FONT, align = lvgl.ALIGN.CENTER }
        resetBtn:onClicked(function()
            trk_momentum = true
            trk_impulse = 15
            trk_friction = 82
            trk_thresh = 4
            save_config()
            create_input_screen()
        end)

        local backBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        backBtn:Label{ text = "Back", text_font = FONT, align = lvgl.ALIGN.CENTER }
        backBtn:onClicked(function() create_controls_screen() end)
    end)
end

-- ============================================================
-- Startup: phased directory scanning, then UI
-- ============================================================
local init_phase = 0
return function()
    init_phase = init_phase + 1

    if init_phase == 1 then
        scan_dir_for_roms(app_dir)
        return false
    elseif init_phase == 2 then
        scan_dir_for_roms(sd_app_dir)
        return false
    elseif init_phase == 3 then
        if EXTRA_DIR ~= app_dir and EXTRA_DIR ~= sd_app_dir then
            scan_dir_for_roms(EXTRA_DIR)
        end
        return false
    end

    table.sort(found_roms, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    load_config()
    if selected_rom_name then
        for i, r in ipairs(found_roms) do
            if r.name == selected_rom_name then selected_rom = i; break end
        end
    end
    create_main_screen()
    return true
end

local lvgl = require("lvgl")
local apps = require("lib/apps")
local nav = require("lib/nav")
local fileman = require("lib/fileman")
local keybind = require("lib/keybind")

local app_dir = ...

local W = lvgl.HOR_RES()
local H = lvgl.VER_RES()

-- ============================================================
-- Neo Geo Pocket / Color (RACE) Launcher
-- ============================================================

local TITLE     = "Neo Geo Pocket"
local ACCENT    = "#00AAFF"
local ELF_NAME  = "ngpc.app.elf"
local ROM_HINT  = "Place .ngp/.ngc ROMs in S:/ngpc/"
local EXTRA_DIR = "S:/ngpc"
local function is_rom(name)
    return name:match("%.ngp$") or name:match("%.ngc$") or name:match("%.ngpc$")
end

-- Derive SD-side mirror of app directory:
-- "L:/lua/apps/Games/ngpc" -> "S:/lua/apps/Games/ngpc"
local sd_app_dir = app_dir:gsub("^L:", "S:")

-- ROM paths are converted for the ELF module's fopen; the ELF path itself is
-- passed raw — the loader reads L:/S: prefixes natively. Flash saves (.ngf)
-- are written by the module next to the ROM.
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

local found_roms = {}   -- { {name, path}, ... }
local seen_lower = {}
local selected_rom = 1
local selected_rom_name = nil
local scr = nil

-- Settings (persisted in launcher.cfg)
local vcap_smooth = true    -- true = 35 fps video cap, false = 25 (more game speed)
local sound_on    = true

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

-- ============================================================
-- Keymap / controls system (host-side translation, same as GameBoy:
-- the -keymap string maps physical keys to the codes the module reads)
-- ============================================================

-- Codes the module's input_poll_cb understands.
local NGP = {
    UP     = 0x77,  -- 'w'
    DOWN   = 0x73,  -- 's'
    LEFT   = 0x61,  -- 'a'
    RIGHT  = 0x64,  -- 'd'
    A      = 0x6D,  -- 'm'
    B      = 0x6E,  -- 'n'
    OPTION = 0x0D,  -- Enter
}

-- What this launcher wants bound. lib/keybind owns the key table, the Controls
-- and picker screens, storage and the -keymap/-trkball strings, and appends the
-- standard Quit action itself. Defaults name keys rather than repeating codes.
local ACTIONS = {
    { id="up",     label="Up",     out=NGP.UP,     key1="w",     key2="TrkUp"  },
    { id="down",   label="Down",   out=NGP.DOWN,   key1="s",     key2="TrkDn"  },
    { id="left",   label="Left",   out=NGP.LEFT,   key1="a",     key2="TrkLt"  },
    { id="right",  label="Right",  out=NGP.RIGHT,  key1="d",     key2="TrkRt"  },
    { id="btn_a",  label="A btn",  out=NGP.A,      key1="m",     key2="TrkClk" },
    { id="btn_b",  label="B btn",  out=NGP.B,      key1="n"                    },
    { id="option", label="Option", out=NGP.OPTION, key1="Enter"                },
}

-- Touch controller layout (keyboardless boards, and any board once the user
-- turns touch input on). lib/padlayout owns the user's edits — drag, resize,
-- per-pad off — persisted per app; this is only the default. The lib ships
-- with firmware newer than this launcher's min_fw, so it may be absent.
local pl_ok, padlayout = pcall(require, "lib/padlayout")
if not pl_ok then padlayout = nil end

local pad = padlayout and padlayout.new{
    app = "NeoGeoPocket",
    presets = { {
        name = "Default",
        zones = {
            { id="up",     out=NGP.UP,     label="^",   x=52,  y=118, w=64, h=56 },
            { id="left",   out=NGP.LEFT,   label="<",   x=0,   y=174, w=56, h=66 },
            { id="down",   out=NGP.DOWN,   label="v",   x=56,  y=174, w=60, h=66 },
            { id="right",  out=NGP.RIGHT,  label=">",   x=116, y=174, w=56, h=66 },
            { id="btn_b",  out=NGP.B,      label="B",   x=188, y=174, w=60, h=66 },
            { id="btn_a",  out=NGP.A,      label="A",   x=254, y=152, w=66, h=66 },
            { id="option", out=NGP.OPTION, label="OPT", x=120, y=0,   w=58, h=30 },
            { id="quit",   out=keybind.QUIT, label="QUIT", x=0, y=0,  w=52, h=30 },
        },
    } },
} or nil

-- Built once the screen helpers below exist; save_config/load_config reach it
-- as an upvalue.
local kb

-- ============================================================
-- Config persistence
-- ============================================================
local function save_config()
    local f = io.open(CFG_PATH, "w")
    if not f then return end
    kb:save_lines(f)
    f:write("vcap=" .. (vcap_smooth and "35" or "25") .. "\n")
    f:write("sound=" .. (sound_on and "1" or "0") .. "\n")
    if #found_roms > 0 then
        f:write("rom=" .. found_roms[selected_rom].name .. "\n")
    end
    f:close()
end

local function load_config()
    kb:reset_defaults()
    local f = io.open(CFG_PATH, "r")
    if not f then return end
    local text = f:read("*a")
    f:close()
    if not text then return end
    for line in text:gmatch("[^\r\n]+") do
        -- Binding and trk_* lines are the library's; the patterns below are
        -- disjoint from them, so an unconsumed line just falls through.
        kb:load_line(line)
        local vc = line:match("^vcap=(%d+)$")
        if vc then vcap_smooth = (vc ~= "25") end
        local snd = line:match("^sound=([01])$")
        if snd then sound_on = (snd == "1") end
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

local function heading(parent, text)
    return parent:Label{
        text = text,
        text_font = FONT,
        text_color = ACCENT,
        w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
    }
end

local create_main_screen
local create_help_screen
local create_settings_screen
local create_about_screen

-- Label + cycling value button, persisted (see lib/keybind).
local setting_row = keybind.rows{ font = FONT, on_save = save_config }

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
            local km = kb:keymap_string()
            local ts = kb:trkball_string()
            lvgl.Timer{
                period = 50,
                cb = function(t)
                    t:delete()
                    local r = found_roms[selected_rom]
                    -- Deferred launch: the firmware tears Lua down, runs the
                    -- module, then recreates Lua and returns to the launcher.
                    -- -stackkb 24: RACE runs shallow; the smaller rung fits
                    -- when internal RAM has no free 32KB block.
                    local args = { ELF_PATH, to_vfs_path(r.path),
                        "-stackkb", "24",
                        "-trkball", ts,
                        "-vcap", vcap_smooth and "35" or "25",
                        "-soundoff", sound_on and "0" or "1" }
                    -- Omitted when nothing is bound, so the firmware falls back
                    -- to passthrough instead of parsing an empty table.
                    if km then
                        args[#args + 1] = "-keymap"
                        args[#args + 1] = km
                    end
                    if _elf_touch_layout and pad then
                        local tl = pad:zones()
                        if tl then _elf_touch_layout(tl) end
                    end
                    _launch_elf(table.unpack(args))
                end
            }
        end)

        local ctrlBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
        ctrlBtn:Label{ text = "Controls", align = lvgl.ALIGN.CENTER }
        ctrlBtn:onClicked(function() kb:open() end)

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

        local setBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
        setBtn:Label{ text = "Settings", align = lvgl.ALIGN.CENTER }
        setBtn:onClicked(function() create_settings_screen() end)

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
-- Settings screen
-- ============================================================
create_settings_screen = function()
    show_screen(function(c)
        heading(c, "SETTINGS")

        setting_row(c, "Video rate",
            function()
                return vcap_smooth and "< Smooth (35 fps) >" or "< Speed (25 fps) >"
            end,
            function() vcap_smooth = not vcap_smooth end
        )

        setting_row(c, "Sound",
            function() return sound_on and "< ON >" or "< OFF >" end,
            function() sound_on = not sound_on end
        )

        c:Label{
            text = "Video rate: fewer video frames leave\n"
                 .. "more headroom for game speed\n"
                 .. "Sound: silences the game entirely",
            text_font = FONT,
            text_color = "#666666",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        local backBtn = c:Button{ w = lvgl.PCT(60), h = 28 }
        backBtn:Label{ text = "Back", text_font = FONT, align = lvgl.ALIGN.CENTER }
        backBtn:onClicked(function() create_main_screen() end)
    end)
end

-- ============================================================
-- Quit help screen (firmware-wide Alt+Backspace exit chord)
-- ============================================================
create_help_screen = function()
    show_screen(function(c)
        heading(c, "QUIT TO LAUNCHER")

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
-- About screen — emulator license and credits.
-- The scope container scrolls (nav.SCROLL_FIRST), so the text runs
-- past the panel height without extra machinery.
-- ============================================================
create_about_screen = function()
    show_screen(function(c)
        heading(c, "ABOUT")

        c:Label{
            text = "Neo Geo Pocket emulation by RACE!\n"
                 .. "License: GNU GPL v2\n\n"
                 .. "Credits:\n"
                 .. "Judge_ - original MHE emulator\n"
                 .. "Flavor - port lead, optimization\n"
                 .. "Thor - emulation fixes, GP32 port\n"
                 .. "neopop_uk - NeoPop, sound and ideas\n"
                 .. "Reesy - DrZ80\n"
                 .. "Akop Karapetyan, theelf - PSP ports\n\n"
                 .. "Components:\n"
                 .. "CZ80 Z80 core\n"
                 .. "  (c) 2004-2005 S. Dallongeville\n"
                 .. "Blip_Buffer (LGPL v2.1)\n"
                 .. "  (c) 2003-2006 Shay Green\n"
                 .. "libretro-common (MIT)\n"
                 .. "  (c) The RetroArch team\n"
                 .. "Sound from NEOPOP\n"
                 .. "  (c) 2001-2002 neopop_uk,\n"
                 .. "  based on sn76496.c from MAME\n\n"
                 .. "Neo Geo Pocket is a trademark of\n"
                 .. "SNK. No game ROMs are included -\n"
                 .. "supply your own.",
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
-- Startup: phased directory scanning, then UI
-- ============================================================
-- keybind.new already seeded the defaults; load_config re-seeds then parses.
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

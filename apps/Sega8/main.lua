local lvgl = require("lvgl")
local apps = require("lib/apps")
local nav = require("lib/nav")
local fileman = require("lib/fileman")
local keybind = require("lib/keybind")

local app_dir = ...

local W = lvgl.HOR_RES()
local H = lvgl.VER_RES()

-- ============================================================
-- Sega 8-bit — Game Gear / Master System / SG-1000 (SMS Plus) Launcher
-- ============================================================

local TITLE     = "Sega 8-bit"
-- Which system a ROM runs as is decided by its extension (see main_tdeck.c),
-- so the subtitle lists them in the same order as SYSTEMS below.
local SUBTITLE  = "Game Gear / Master System / SG-1000"
local ACCENT    = "#00A3E0"
local ELF_NAME  = "sega8.app.elf"
local ROM_HINT  = "Place .gg/.sms/.sg ROMs in S:/sega8/"
local EXTRA_DIR = "S:/sega8"

-- Extension -> system, for the per-ROM label under the selector.
local SYSTEMS = {
    gg  = "Game Gear",
    sms = "Master System",
    sg  = "SG-1000",
}
local function system_of(name)
    return SYSTEMS[(name:lower():match("%.(%w+)$")) or ""] or "Unknown"
end
local function is_rom(name)
    return name:match("%.gg$") or name:match("%.sms$") or name:match("%.sg$")
end

-- Derive SD-side mirror of app directory:
-- "L:/lua/apps/Games/Sega8" -> "S:/lua/apps/Games/Sega8"
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
-- Keymap / controls system (host-side translation, same as SNES/GameBoy:
-- the -keymap string maps physical keys to the codes the module reads)
-- ============================================================

-- Codes main_tdeck.c's poll_input() understands.
local GG = {
    UP    = 0x77,  -- 'w'
    DOWN  = 0x73,  -- 's'
    LEFT  = 0x61,  -- 'a'
    RIGHT = 0x64,  -- 'd'
    BTN1  = 0x6E,  -- 'n'
    BTN2  = 0x6D,  -- 'm'
    START = 0x0D,  -- Enter
    PAUSE = 0x08,  -- Backspace
}

-- What this launcher wants bound. lib/keybind owns the key table, the Controls
-- and picker screens, storage and the -keymap/-trkball strings, and appends the
-- standard Quit action itself. Defaults name keys rather than repeating codes.
--
-- Start and Pause are both console buttons, and which one a game listens to
-- depends on the hardware: Game Gear carts read Start, Master System carts
-- read Pause. Both are bound so either system works without rebinding.
local ACTIONS = {
    { id="up",     label="Up",     out=GG.UP,    key1="w",     key2="TrkUp"  },
    { id="down",   label="Down",   out=GG.DOWN,  key1="s",     key2="TrkDn"  },
    { id="left",   label="Left",   out=GG.LEFT,  key1="a",     key2="TrkLt"  },
    { id="right",  label="Right",  out=GG.RIGHT, key1="d",     key2="TrkRt"  },
    { id="btn_2",  label="2 btn",  out=GG.BTN2,  key1="m",     key2="TrkClk" },
    { id="btn_1",  label="1 btn",  out=GG.BTN1,  key1="n"                    },
    { id="start",  label="Start",  out=GG.START, key1="Enter"                },
    { id="pause",  label="Pause",  out=GG.PAUSE, key1="BkSpc"                },
}

-- Built once the screen helpers below exist; save_config/load_config reach it
-- as an upvalue.
local kb

-- Scale: how the native frame lands on the 320x240 panel. Game Gear is
-- 160x144 and Master System 256x192, so "fit" resolves per ROM inside the
-- module — 1.5x and 1.25x respectively.
local SCALES = { "fit", "1x", "full" }
local SCALE_LABEL = { fit = "Scale: Fit", ["1x"] = "Scale: Native", full = "Scale: Stretch" }
local scale = "fit"

local found_roms = {}   -- { {name, path}, ... }
local seen_lower = {}
local selected_rom = 1
local selected_rom_name = nil
local scr = nil

-- Stable, manager-registered root (same pattern as the SNES launcher).
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
    kb:save_lines(f)
    f:write("scale=" .. scale .. "\n")
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
        local s = line:match("^scale=(%w+)$")
        if s and SCALE_LABEL[s] then scale = s end
        local rname = line:match("^rom=(.+)$")
        if rname then selected_rom_name = rname end
    end
end

-- ============================================================
-- Screen management — single navigable scope per view, focusables as direct
-- children; the new view goes to nav.replace BEFORE the old one is deleted
-- (SNES/App Library swap_view pattern).
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

local create_main_screen
local create_help_screen
local create_about_screen

-- Deferred launch: the firmware tears Lua down, runs the module, then
-- recreates Lua and returns to the launcher. The 50ms timer lets the caller's
-- status text paint before Lua goes away.
--
-- No radio prompt here, unlike the SNES launcher: this module renders on
-- Core 0 and spawns no worker, so it never needs a contiguous block of
-- internal SRAM and BLE/WiFi can stay up.
local function launch_now()
    local km = kb:keymap_string()
    local ts = kb:trkball_string()
    local rom = found_roms[selected_rom]
    lvgl.Timer{
        period = 50,
        cb = function(t)
            t:delete()
            local args = { ELF_PATH, to_vfs_path(rom.path),
                "-scale", scale,
                "-trkball", ts }
            -- Omitted when nothing is bound, so the firmware falls back
            -- to passthrough instead of parsing an empty table.
            if km then
                args[#args + 1] = "-keymap"
                args[#args + 1] = km
            end
            _launch_elf(table.unpack(args))
        end
    }
end

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

        -- Always shown, not just when the ROM folder is empty: the app name
        -- alone does not say it plays three systems.
        c:Label{
            text = SUBTITLE,
            text_font = FONT,
            text_color = "#888888",
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

        -- The module picks the system from the extension, so show which one
        -- the selected ROM will actually run as.
        local function sys_text()
            if #found_roms == 0 then return "" end
            return "Runs as: " .. system_of(found_roms[selected_rom].name)
        end
        local sysLbl = c:Label{
            text = sys_text(),
            text_font = FONT,
            text_color = "#888888",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        romDd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
            if #found_roms == 0 then return end
            selected_rom = romDd:get("selected") + 1
            sysLbl:set{ text = sys_text() }
            save_config()
        end)

        -- One row rather than a setting_row pair: the main screen is tight,
        -- and this is the control most likely to be changed per game.
        local scaleBtn = c:Button{ w = lvgl.PCT(100), h = 28 }
        local scaleLbl = scaleBtn:Label{
            text = SCALE_LABEL[scale],
            text_font = FONT,
            align = lvgl.ALIGN.CENTER,
        }
        scaleBtn:onClicked(function()
            local idx = 1
            for i, v in ipairs(SCALES) do
                if v == scale then idx = i break end
            end
            scale = SCALES[(idx % #SCALES) + 1]
            scaleLbl:set{ text = SCALE_LABEL[scale] }
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
            launch_now()
        end)

        local ctrlBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
        ctrlBtn:Label{ text = "Controls", align = lvgl.ALIGN.CENTER }
        ctrlBtn:onClicked(function() kb:open() end)

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
        c:Label{
            text = "ABOUT",
            text_font = FONT,
            text_color = ACCENT,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        c:Label{
            text = "Game Gear, Master System and\n"
                 .. "SG-1000 emulation by SMS Plus,\n"
                 .. "via the retro-go port.\n\n"
                 .. "License: GNU GPL v2 or later\n\n"
                 .. "SMS Plus (c) 1998-2007\n"
                 .. "  Charles MacDonald\n"
                 .. "SMS Plus GX accuracy work\n"
                 .. "  (c) Eke-Eke\n"
                 .. "retro-go port (c) ducalex\n"
                 .. "SN76489 PSG core (c) Maxim\n"
                 .. "YM2413 FM core (c) Mitsutaka\n"
                 .. "  Okazaki (emu2413)\n\n"
                 .. "Colecovision is not supported:\n"
                 .. "it needs a BIOS ROM we have no\n"
                 .. "right to ship, so that code and\n"
                 .. "the bundled BIOS were removed.\n\n"
                 .. "Sega, Game Gear and Master System\n"
                 .. "are trademarks of Sega. No game\n"
                 .. "ROMs are included - supply your\n"
                 .. "own.",
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

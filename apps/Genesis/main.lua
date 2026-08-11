local lvgl = require("lvgl")
local apps = require("lib/apps")
local nav = require("lib/nav")
local fileman = require("lib/fileman")
local keybind = require("lib/keybind")

local app_dir = ...

local W = lvgl.HOR_RES()
local H = lvgl.VER_RES()

-- ============================================================
-- Sega Genesis / Mega Drive (Gwenesis) Launcher
-- ============================================================

local TITLE     = "Genesis"
local SUBTITLE  = "Mega Drive"
local ACCENT    = "#E63946"
local ELF_NAME  = "genesis.app.elf"
local ROM_HINT  = "Place .md/.gen/.bin ROMs in S:/genesis/"
local EXTRA_DIR = "S:/genesis"
-- .smd is the interleaved Super Magic Drive format; the core reads plain
-- (BIN/MD) dumps, so it is deliberately not listed.
local function is_rom(name)
    return name:match("%.md$") or name:match("%.gen$") or name:match("%.bin$")
end

-- Derive SD-side mirror of app directory:
-- "L:/lua/apps/Games/Genesis" -> "S:/lua/apps/Games/Genesis"
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
-- Keymap / controls system (host-side translation, same as SNES/Sega8:
-- the -keymap string maps physical keys to the codes the module reads)
-- ============================================================

-- Codes main_tdeck.c's poll_input() understands.
local GEN = {
    UP    = 0x77,  -- 'w'
    DOWN  = 0x73,  -- 's'
    LEFT  = 0x61,  -- 'a'
    RIGHT = 0x64,  -- 'd'
    A     = 0x6E,  -- 'n'
    B     = 0x6D,  -- 'm'
    C     = 0x6B,  -- 'k'
    START = 0x0D,  -- Enter
}

-- What this launcher wants bound. lib/keybind owns the key table, the Controls
-- and picker screens, storage and the -keymap/-trkball strings, and appends the
-- standard Quit action itself. Defaults name keys rather than repeating codes.
local ACTIONS = {
    { id="up",     label="Up",     out=GEN.UP,    key1="w",     key2="TrkUp"  },
    { id="down",   label="Down",   out=GEN.DOWN,  key1="s",     key2="TrkDn"  },
    { id="left",   label="Left",   out=GEN.LEFT,  key1="a",     key2="TrkLt"  },
    { id="right",  label="Right",  out=GEN.RIGHT, key1="d",     key2="TrkRt"  },
    { id="btn_b",  label="B btn",  out=GEN.B,     key1="m",     key2="TrkClk" },
    { id="btn_a",  label="A btn",  out=GEN.A,     key1="n"                    },
    { id="btn_c",  label="C btn",  out=GEN.C,     key1="k"                    },
    { id="start",  label="Start",  out=GEN.START, key1="Enter"                },
}

-- Built once the screen helpers below exist; save_config/load_config reach it
-- as an upvalue.
local kb

-- Frameskip: the 68000, Z80, VDP and FM all still run every frame; only
-- rendering and the blit are skipped. Genesis is by far the heaviest system
-- here, so this is the first knob to reach for if a game runs slow.
local SKIPS = { 0, 1, 2, 3 }
local frameskip = 2

-- Idle skip: the emulator detects a 68000 loop that cannot exit on its own --
-- registers frozen, no memory write, no port read -- and hands it the rest of
-- the scanline instead of interpreting a spin whose results are discarded.
-- Worth about 20% and it is the largest single gain in the port, but it has to
-- infer a loop's intent, so it is switchable per-game for compatibility.
-- Turn it off if a game stalls or crawls at a fixed point while music plays on.
local idle_skip = true

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
    f:write(string.format("frameskip=%d\n", frameskip))
    f:write("idleskip=" .. (idle_skip and "1" or "0") .. "\n")
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
        local fs = line:match("^frameskip=(%d+)$")
        if fs then
            local v = tonumber(fs)
            if v and v >= 0 and v <= 3 then frameskip = v end
        end
        local isk = line:match("^idleskip=(%d)$")
        if isk then idle_skip = (isk == "1") end
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
local function launch_now()
    local km = kb:keymap_string()
    local ts = kb:trkball_string()
    local rom = found_roms[selected_rom]
    lvgl.Timer{
        period = 50,
        cb = function(t)
            t:delete()
            local args = { ELF_PATH, to_vfs_path(rom.path),
                "-fs", tostring(frameskip),
                "-idle", idle_skip and "1" or "0",
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
        romDd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
            if #found_roms == 0 then return end
            selected_rom = romDd:get("selected") + 1
            save_config()
        end)

        local function skip_text()
            return (frameskip == 0) and "Frameskip: Off"
                or ("Frameskip: " .. frameskip)
        end
        local skipBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        local skipLbl = skipBtn:Label{
            text = skip_text(),
            text_font = FONT,
            align = lvgl.ALIGN.CENTER,
        }
        skipBtn:onClicked(function()
            local idx = 1
            for i, v in ipairs(SKIPS) do
                if v == frameskip then idx = i break end
            end
            frameskip = SKIPS[(idx % #SKIPS) + 1]
            skipLbl:set{ text = skip_text() }
            save_config()
        end)

        local function idle_text()
            return idle_skip and "Idle Skip: On" or "Idle Skip: Off"
        end
        local idleBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        local idleLbl = idleBtn:Label{
            text = idle_text(),
            text_font = FONT,
            align = lvgl.ALIGN.CENTER,
        }
        idleBtn:onClicked(function()
            idle_skip = not idle_skip
            idleLbl:set{ text = idle_text() }
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
            text = "Genesis / Mega Drive emulation by\n"
                 .. "Gwenesis (c) bzhxx\n"
                 .. "License: GNU AGPL v3 (sources say\n"
                 .. "GPLv3); the full source ships with\n"
                 .. "this app.\n\n"
                 .. "Components:\n"
                 .. "68000 core from Musashi\n"
                 .. "  (c) Karl Stenerud\n"
                 .. "Z80 core (c) Marat Fayzullin\n"
                 .. "  1994-2007 - NOT for commercial\n"
                 .. "  distribution\n"
                 .. "YM2612 FM and SN76489 PSG cores\n"
                 .. "  from the Gwenesis tree\n\n"
                 .. "PLEASE NOTE: because of the Z80\n"
                 .. "core above, this app may not be\n"
                 .. "distributed commercially.\n\n"
                 .. "Sega, Genesis and Mega Drive are\n"
                 .. "trademarks of Sega. No game ROMs\n"
                 .. "are included - supply your own.",
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

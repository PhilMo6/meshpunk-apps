local lvgl = require("lvgl")
local apps = require("lib/apps")
local nav = require("lib/nav")
local fileman = require("lib/fileman")
local keybind = require("lib/keybind")

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

-- What this launcher wants bound. lib/keybind owns the key table, the Controls
-- and picker screens, storage and the -keymap/-trkball strings, and appends the
-- standard Quit action itself. Defaults name keys rather than repeating codes.
local ACTIONS = {
    { id="up",     label="Up",     out=SNES.UP,     key1="w",     key2="TrkUp"  },
    { id="down",   label="Down",   out=SNES.DOWN,   key1="s",     key2="TrkDn"  },
    { id="left",   label="Left",   out=SNES.LEFT,   key1="a",     key2="TrkLt"  },
    { id="right",  label="Right",  out=SNES.RIGHT,  key1="d",     key2="TrkRt"  },
    { id="btn_a",  label="A btn",  out=SNES.A,      key1="m",     key2="TrkClk" },
    { id="btn_b",  label="B btn",  out=SNES.B,      key1="n"                    },
    { id="btn_x",  label="X btn",  out=SNES.X,      key1="k"                    },
    { id="btn_y",  label="Y btn",  out=SNES.Y,      key1="j"                    },
    { id="btn_l",  label="L btn",  out=SNES.L,      key1="q"                    },
    { id="btn_r",  label="R btn",  out=SNES.R,      key1="p"                    },
    { id="start",  label="Start",  out=SNES.START,  key1="Enter"                },
    { id="select", label="Select", out=SNES.SELECT, key1="BkSpc"                },
}

-- Built once the screen helpers below exist; save_config/load_config reach it
-- as an upvalue.
local kb

-- Renderer: 0 = Speed (Core-1 worker), 1 = Accuracy (Core 0).
-- The worker binds one frame-boundary snapshot of the palette and BG base
-- registers, so games that rewrite those mid-frame (HDMA colour gradients,
-- mid-frame base switches) render them wrong. Core 0 re-reads them per span.
local renderer = 0

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
    kb:save_lines(f)
    f:write(string.format("renderer=%d\n", renderer))
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
        local rmode = line:match("^renderer=([01])$")
        if rmode then renderer = tonumber(rmode) end
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

local create_main_screen
local create_help_screen
local create_about_screen
local create_radio_screen

-- ============================================================
-- Radios vs the Speed renderer
-- ============================================================
-- The Core-1 render worker's band context is 13,076 bytes and lives on that
-- task's stack, so Speed needs a 16KB contiguous block of internal SRAM.
-- BLE and WiFi hold enough of that pool that the worker cannot spawn. The
-- second argument to the _*_set_enabled bindings applies the change without
-- writing prefs, so the next boot restores whatever the user had set; they
-- are NOT switched back on when the module exits.
local function radios_on()
    return _ble_get_enabled(), _wifi_get_enabled()
end

local function radios_off()
    if _ble_get_enabled() then _ble_set_enabled(false, false) end
    if _wifi_get_enabled() then _wifi_set_enabled(false, false) end
end

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
            -- -stackkb 24 is a ceiling: the firmware caps the module task
            -- there instead of taking a 32KB rung, which leaves internal
            -- SRAM for the render worker.
            local args = { ELF_PATH, to_vfs_path(rom.path),
                "-stackkb", "24",
                "-render", tostring(renderer),
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
            -- Only Speed needs the radios down, and only when one is up.
            local ble, wifi = radios_on()
            if renderer == 0 and (ble or wifi) then
                create_radio_screen()
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
-- Speed-renderer memory prompt. Reached from Play only when the Speed
-- renderer is selected and at least one radio is up.
-- ============================================================
create_radio_screen = function()
    show_screen(function(c)
        c:Label{
            text = "FREE MEMORY?",
            text_font = FONT,
            text_color = ACCENT,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        local msg = c:Label{
            text = "The Speed renderer needs memory\n"
                 .. "that Bluetooth and WiFi are\n"
                 .. "holding.\n\n"
                 .. "Continue turns BOTH of them off\n"
                 .. "before the game starts. They stay\n"
                 .. "off after you quit - turn them\n"
                 .. "back on in Settings > Wireless,\n"
                 .. "or restart the device.\n\n"
                 .. "The Accuracy renderer runs\n"
                 .. "without shutting anything down.",
            text_font = FONT,
            text_color = "#CCCCCC",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        local yesBtn = c:Button{ w = lvgl.PCT(48), h = 32 }
        yesBtn:Label{ text = "Continue", align = lvgl.ALIGN.CENTER }
        yesBtn:onClicked(function()
            msg:set{ text = "Turning Bluetooth and WiFi off..." }
            -- Torn down one paint later so that text is on screen for it;
            -- launch_now() then takes its own 50ms before Lua goes away.
            lvgl.Timer{
                period = 50,
                cb = function(t)
                    t:delete()
                    radios_off()
                    launch_now()
                end
            }
        end)

        local noBtn = c:Button{ w = lvgl.PCT(48), h = 32 }
        noBtn:Label{ text = "Cancel", align = lvgl.ALIGN.CENTER }
        noBtn:onClicked(function() create_main_screen() end)
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

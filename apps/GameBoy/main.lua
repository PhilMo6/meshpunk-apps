local lvgl = require("lvgl")
local apps = require("lib/apps")
local nav = require("lib/nav")
local fileman = require("lib/fileman")
local keybind = require("lib/keybind")
-- Touch controller layouts (keyboardless boards) — the lib ships with
-- firmware newer than this launcher's min_fw, so it may be absent.
local pl_ok, padlayout = pcall(require, "lib/padlayout")
if not pl_ok then padlayout = nil end

local app_dir = ...

local W = lvgl.HOR_RES()
local H = lvgl.VER_RES()

-- ============================================================
-- Game Boy / Game Boy Color (gnuboy) Launcher
-- ============================================================

-- Derive SD-side mirror of app directory:
-- "L:/lua/apps/Games/GameBoy" -> "S:/lua/apps/Games/GameBoy"
local sd_app_dir = app_dir:gsub("^L:", "S:")

-- Convert firmware path prefixes to VFS mount points for the ELF module's fopen
local function to_vfs_path(path)
    if path:sub(1, 2) == "S:" then return "/sd" .. path:sub(3) end
    if path:sub(1, 2) == "L:" then return "/littlefs" .. path:sub(3) end
    return path
end

-- Search for a file: check app dir, then SD mirror, then legacy S:/gb/
local function find_file(name)
    local search = { app_dir, sd_app_dir, "S:/gb" }
    for _, dir in ipairs(search) do
        local path = dir .. "/" .. name
        local f = io.open(path, "r")
        if f then f:close(); return path end
    end
    return nil
end

local CFG_PATH = app_dir .. "/controls.cfg"
local ELF_PATH = find_file("gameboy.app.elf") or sd_app_dir .. "/gameboy.app.elf"

local found_roms = {}   -- { {name, path}, ... }
local seen_lower = {}
local selected_rom = 1
local selected_rom_name = nil
local scr = nil

-- Stable, manager-registered root (same pattern as the PICO-8/Doom launchers).
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
            return e.type == "file"
                and (e.name:lower():match("%.gb$") or e.name:lower():match("%.gbc$"))
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
-- Keymap / controls system
-- ============================================================

-- Canonical Game Boy button codes: these are the key codes map_key() inside
-- the ELF understands. The launcher maps physical keys to these via the
-- host's keymap system.
local GB = {
    UP     = 0x77,  -- 'w'
    DOWN   = 0x73,  -- 's'
    LEFT   = 0x61,  -- 'a'
    RIGHT  = 0x64,  -- 'd'
    A      = 0x6D,  -- 'm'
    B      = 0x6E,  -- 'n'
    START  = 0x0D,  -- Enter
    SELECT = 0x20,  -- Space
}

-- What this launcher wants bound. lib/keybind owns the key table, the Controls
-- and picker screens, storage and the -keymap/-trkball strings, and appends the
-- standard Quit action itself. Defaults name keys rather than repeating codes.
local ACTIONS = {
    { id="up",     label="Up",     out=GB.UP,     key1="w",     key2="TrkUp"  },
    { id="down",   label="Down",   out=GB.DOWN,   key1="s",     key2="TrkDn"  },
    { id="left",   label="Left",   out=GB.LEFT,   key1="a",     key2="TrkLt"  },
    { id="right",  label="Right",  out=GB.RIGHT,  key1="d",     key2="TrkRt"  },
    { id="btn_a",  label="A btn",  out=GB.A,      key1="m",     key2="TrkClk" },
    { id="btn_b",  label="B btn",  out=GB.B,      key1="n"                    },
    { id="start",  label="Start",  out=GB.START,  key1="Enter"                },
    { id="select", label="Select", out=GB.SELECT, key1="Space"                },
}

-- Built once the screen helpers below exist; save_config/load_config reach it
-- as an upvalue.
local kb

-- ============================================================
-- Emulator settings
-- ============================================================

-- DMG colorization palettes (gb_palette_t indices in the ELF).
-- Only affects original Game Boy games; GBC games use their own colors.
local PALETTES = {
    { label = "GBC auto",   value = 35 }, -- per-game colorization, like a real GBC
    { label = "DMG green",  value = 32 },
    { label = "Pocket",     value = 33 },
    { label = "Light",      value = 34 },
    { label = "SGB",        value = 36 },
}
local SCALES = {
    { label = "Fit (240x216)",    value = "fit"  },
    { label = "Native (160x144)", value = "1x"   },
    { label = "Fullscreen",       value = "full" },
}
local sel_palette = 1
local sel_scale   = 1
local resume_on   = false

-- Save bindings + settings to config file
local function save_config()
    local f = io.open(CFG_PATH, "w")
    if not f then return end
    kb:save_lines(f)
    f:write(string.format("pal=%d\n", sel_palette))
    f:write(string.format("scale=%d\n", sel_scale))
    f:write(string.format("resume=%d\n", resume_on and 1 or 0))
    if #found_roms > 0 then
        f:write("rom=" .. found_roms[selected_rom].name .. "\n")
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
        local pal = line:match("^pal=(%d+)$")
        if pal then
            pal = tonumber(pal)
            if pal >= 1 and pal <= #PALETTES then sel_palette = pal end
        end
        local sc = line:match("^scale=(%d+)$")
        if sc then
            sc = tonumber(sc)
            if sc >= 1 and sc <= #SCALES then sel_scale = sc end
        end
        local res = line:match("^resume=([01])$")
        if res then resume_on = (res == "1") end
        local rname = line:match("^rom=(.+)$")
        if rname then selected_rom_name = rname end
    end
    return true
end

-- ============================================================
-- Screen management
-- ============================================================
-- Every view is a single navigable scope: one flex container whose focusable
-- children (buttons, dropdowns) are ALL direct children, so gridnav's
-- trackball/WASD navigation reaches every one of them (it only walks direct
-- children of the scope container). show_screen builds the new view and hands
-- it to nav.replace BEFORE deleting the old one, so the outgoing gridnav stays
-- alive across the handoff (App Library swap_view pattern).
local FONT = lvgl.BUILTIN_FONT.MONTSERRAT_12
local ACCENT = "#9BBC0F"

-- Link-notice refresh timer (main screen only). Deleted on every screen
-- change and on Quit so it can never fire against a deleted label; the
-- Play path tears the whole Lua state down, which takes the timer with it.
local notice_timer = nil

local function show_screen(builder)
    if notice_timer then notice_timer:delete(); notice_timer = nil end
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
local function create_settings_screen() end
local function create_help_screen() end
local function create_about_screen() end

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

-- Label + cycling value button, persisted (see lib/keybind).
local setting_row = keybind.rows{ font = FONT, on_save = save_config }

-- Touch controller layout: the default preset is the hardware-proven P3
-- geometry. lib/padlayout owns the user's edits (drag/size/per-pad off,
-- persisted per app); pad:zones() resolves them at launch.
local pad = padlayout and padlayout.new{
    app = "GameBoy",
    presets = { {
        name = "Default",
        zones = {
            { id = "up",     out = GB.UP,     label = "^",    x = 52,  y = 118, w = 64, h = 56 },
            { id = "left",   out = GB.LEFT,   label = "<",    x = 0,   y = 174, w = 56, h = 66 },
            { id = "down",   out = GB.DOWN,   label = "v",    x = 56,  y = 174, w = 60, h = 66 },
            { id = "right",  out = GB.RIGHT,  label = ">",    x = 116, y = 174, w = 56, h = 66 },
            { id = "a",      out = GB.A,      label = "A",    x = 254, y = 152, w = 66, h = 66 },
            { id = "b",      out = GB.B,      label = "B",    x = 188, y = 174, w = 60, h = 66 },
            { id = "start",  out = GB.START,  label = "STRT", x = 120, y = 0,   w = 58, h = 30 },
            { id = "select", out = GB.SELECT, label = "SEL",  x = 184, y = 0,   w = 58, h = 30 },
            { id = "quit",   out = keybind.QUIT, label = "QUIT", x = 0, y = 0,  w = 52, h = 30 },
        },
    } },
} or nil

-- ============================================================
-- Main screen
-- ============================================================
create_main_screen = function()
    show_screen(function(c)
        c:Label{
            text = "GAME BOY",
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

        -- Status
        local has_roms = #found_roms > 0
        local status = c:Label{
            text = has_roms and "Ready to play"
                   or "Place .gb/.gbc ROMs in S:/gb/",
            text_font = FONT,
            text_color = has_roms and "#888888" or "#FF6666",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        -- Link-cable notice. With a peer session up, the firmware pauses the
        -- mesh radio for the whole linked game (it shares the SPI bus with
        -- the link's display traffic) and resumes it on exit. Live-updated:
        -- the session often establishes a second or two AFTER this screen
        -- builds (or drops on unplug), so a one-shot check kept missing it.
        -- Guarded so the app still runs on firmware without the binding.
        if _gblink_status then
            local notice = c:Label{
                text = "Link cable connected!\n" ..
                       "Mesh will PAUSE while playing\n" ..
                       "to keep the link stable.",
                text_font = FONT,
                text_color = "#FFCC44",
                w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
            }
            local function refresh()
                if _gblink_status() > 0 then
                    notice:clear_flag(lvgl.FLAG.HIDDEN)
                else
                    notice:add_flag(lvgl.FLAG.HIDDEN)
                end
            end
            refresh()
            notice_timer = lvgl.Timer{ period = 1000, cb = refresh }
        end

        local launchBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
        launchBtn:Label{ text = "Play", align = lvgl.ALIGN.CENTER }
        launchBtn:onClicked(function()
            if #found_roms == 0 then
                status:set{ text = "No .gb/.gbc ROM found!" }
                return
            end
            status:set{ text = "Loading..." }
            local km = kb:keymap_string()
            lvgl.Timer{
                period = 50,
                cb = function(t)
                    t:delete()
                    local r = found_roms[selected_rom]
                    -- Deferred launch: the firmware tears Lua down, runs the
                    -- module, then recreates Lua and returns to the launcher.
                    -- -stackkb 24: gnuboy runs shallow, and the smaller rung
                    -- lets the game task fit beside USB host mode (link
                    -- cable) where big internal-RAM blocks are scarce.
                    local args = { ELF_PATH, to_vfs_path(r.path),
                        "-pal", tostring(PALETTES[sel_palette].value),
                        "-scale", SCALES[sel_scale].value,
                        "-resume", resume_on and "1" or "0",
                        "-trkball", kb:trkball_string(),
                        "-stackkb", "24" }
                    -- Omitted when nothing is bound, so the firmware falls back
                    -- to passthrough instead of parsing an empty table.
                    if km then
                        args[#args + 1] = "-keymap"
                        args[#args + 1] = km
                    end
                    -- Touch controller layout (keyboardless boards): binding
                    -- and lib are both feature-checked — this launcher also
                    -- runs on firmware that predates them.
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

        local quitBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
        quitBtn:Label{ text = "Quit", align = lvgl.ALIGN.CENTER }
        quitBtn:onClicked(function()
            if notice_timer then notice_timer:delete(); notice_timer = nil end
            apps.go_home()
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
-- About screen — emulator license and credits.
-- The scope container scrolls (nav.SCROLL_FIRST), so the text runs
-- past the panel height without extra machinery.
-- ============================================================
create_about_screen = function()
    show_screen(function(c)
        heading(c, "ABOUT", ACCENT)

        c:Label{
            text = "Game Boy emulation by gnuboy\n"
                 .. "License: GNU GPL v2\n\n"
                 .. "Core vendored from retro-go\n"
                 .. "github.com/ducalex/retro-go\n\n"
                 .. "Credits:\n"
                 .. "Laguna - design, main program\n"
                 .. "Gilgamesh - concept, research, builds\n"
                 .. "Damian M Gryski - SDL port\n"
                 .. "Jonathan Gevaryahu - sound emulation\n"
                 .. "Mattias Wadman - LCDC behavior\n"
                 .. "Magnus Damm - YUV colorspace\n"
                 .. "Neil Stevens - noise samples\n"
                 .. "Hii - memory mapper information\n"
                 .. "Alex Duchesne - ODROID-GO port,\n"
                 .. "  optimizations, GBC palettes\n\n"
                 .. "Game Boy and Game Boy Color are\n"
                 .. "trademarks of Nintendo. No BIOS or\n"
                 .. "game ROMs are included - supply\n"
                 .. "your own.",
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
-- Settings screen (palette / scale / resume)
-- ============================================================
create_settings_screen = function()
    show_screen(function(c)
        heading(c, "SETTINGS", ACCENT)

        -- DMG palette (GBC games ignore this)
        setting_row(c, "GB palette",
            function() return "< " .. PALETTES[sel_palette].label .. " >" end,
            function()
                sel_palette = sel_palette + 1
                if sel_palette > #PALETTES then sel_palette = 1 end
            end
        )

        -- Screen scale
        setting_row(c, "Screen",
            function() return "< " .. SCALES[sel_scale].label .. " >" end,
            function()
                sel_scale = sel_scale + 1
                if sel_scale > #SCALES then sel_scale = 1 end
            end
        )

        -- Resume toggle
        setting_row(c, "Resume session",
            function() return resume_on and "< ON >" or "< OFF >" end,
            function() resume_on = not resume_on end
        )

        c:Label{
            text = "GB palette: colors for original GB games\n"
                 .. "Resume: save/restore full state on exit\n"
                 .. "Battery saves (.sav) always work",
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
-- Startup: load config (or defaults) and show main screen
-- ============================================================
-- keybind.new already seeded the defaults; load_config re-seeds then parses.
local init_phase = 0
return function()
    init_phase = init_phase + 1

    -- Phase 1-3: directory scanning
    if init_phase == 1 then
        scan_dir_for_roms(app_dir)
        return false
    elseif init_phase == 2 then
        scan_dir_for_roms(sd_app_dir)
        return false
    elseif init_phase == 3 then
        if sd_app_dir ~= "S:/gb" then
            scan_dir_for_roms("S:/gb")
        end
        return false
    end

    -- Final phase: sort ROMs, load config, show UI
    table.sort(found_roms, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    load_config()
    -- Restore ROM selection by name
    if selected_rom_name then
        for i, r in ipairs(found_roms) do
            if r.name == selected_rom_name then selected_rom = i; break end
        end
    end
    create_main_screen()
    return true
end

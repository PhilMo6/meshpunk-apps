local lvgl = require("lvgl")
local apps = require("lib/apps")
local nav = require("lib/nav")
local fileman = require("lib/fileman")
local keybind = require("lib/keybind")

local app_dir = ...

local W = lvgl.HOR_RES()
local H = lvgl.VER_RES()

-- ============================================================
-- Jet 3D Launcher
--
-- Games are folders containing main.lua. They are searched for in the app's
-- own games/ folder (flash) and in S:/jet3d on the SD card.
-- ============================================================

local sd_app_dir = app_dir:gsub("^L:", "S:")

local function to_vfs_path(path)
    if path:sub(1, 2) == "S:" then return "/sd" .. path:sub(3) end
    if path:sub(1, 2) == "L:" then return "/littlefs" .. path:sub(3) end
    return path
end

local function find_file(name)
    local search = { app_dir, sd_app_dir, "S:/jet3d" }
    for _, dir in ipairs(search) do
        local path = dir .. "/" .. name
        local f = io.open(path, "r")
        if f then f:close(); return path end
    end
    return nil
end

local CFG_PATH = app_dir .. "/jet3d.cfg"
local ELF_PATH = find_file("jet3d.app.elf") or sd_app_dir .. "/jet3d.app.elf"

local found_games = {}   -- { {name, path}, ... }  path = folder holding main.lua
local seen_lower = {}
local sel_game = 1
local sel_game_name = nil
local scr = nil
local kb = nil           -- keybind object, created once show_screen exists

-- ============================================================
-- Engine settings — fixed, no longer user-facing
-- ============================================================
-- These were a Settings screen while the renderer was being tuned. The
-- values below won that tuning, so they ship as constants rather than as
-- choices a player has to understand. Each is passed to the module on
-- launch (see the Launch button).
--
-- BAND_ROWS: the module rasterises one band at a time into internal SRAM,
-- so this IS the whole render buffer (320 * rows * 2 bytes) and must
-- divide 240 exactly. The dual-core band renderer wants many small bands:
-- four buffers fit internal SRAM easily and the two cores load-balance
-- best on fine work units.
--
-- CHECKERBOARD: draw half the pixels on a parity that flips every frame
-- and rebuild the rest from their left/right neighbours before the band
-- goes out. Halves the per-pixel work -- the frame's biggest cost -- for
-- some horizontal detail. Nothing has to survive between frames, so
-- unlike band interlacing there is no band drag while moving.
--
-- DBUF: hand each finished band to the Core-1 push task and rasterise the
-- next into the other buffer while it goes out on the wire. No visual
-- cost; needs two band buffers in internal SRAM, and the engine steps the
-- band height down if they will not fit (the boot line reports what it
-- got).
--
-- FOG off: the engine ignores a game's fog calls, keeping distant geometry
-- and LOD swaps visible on a long view.
--
-- Frame rate is uncapped and band interlacing is off, so neither is sent.
local BAND_ROWS    = 5
local CHECKERBOARD = true
local DBUF         = true
local FOG          = false

local root = apps.new_root({
    w = W, h = H,
    bg_color = "#000000", bg_opa = lvgl.OPA(255),
    border_width = 0, pad_all = 0,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)

-- A game is any subfolder holding a main.lua.
local function scan_dir_for_games(dir_path)
    local entries = fileman.list(dir_path, {
        sizes = false,
        filter = function(e) return e.type == "dir" end,
    }) or {}
    for _, e in ipairs(entries) do
        local low = e.name:lower()
        if not seen_lower[low] then
            local folder = dir_path .. "/" .. e.name
            local f = io.open(folder .. "/main.lua", "r")
            if f then
                f:close()
                seen_lower[low] = true
                found_games[#found_games + 1] = { name = e.name, path = folder }
            end
        end
    end
end

-- The config holds the chosen game and the key bindings. Engine settings
-- are constants now, so a cfg written by an older build keeps its stale
-- band=/fps=/checker=/... lines — they simply no longer match anything
-- here and are ignored, which is what makes the settled defaults stick.
local function save_config()
    local f = io.open(CFG_PATH, "w")
    if not f then return end
    if sel_game > 0 and found_games[sel_game] then
        f:write("game=" .. found_games[sel_game].name .. "\n")
    end
    if kb then kb:save_lines(f) end
    f:close()
end

local function load_config()
    local f = io.open(CFG_PATH, "r")
    if not f then return end
    local text = f:read("*a")
    f:close()
    if not text then return end
    for line in text:gmatch("[^\r\n]+") do
        -- Binding lines belong to keybind (id=K1,K2 hex pairs).
        if not (kb and kb:load_line(line)) then
            local name = line:match("^game=(.+)$")
            if name then sel_game_name = name end
        end
    end
end

-- ============================================================
-- Screen management
-- ============================================================
-- Every view is a single navigable scope: one flex container whose focusable
-- children are ALL direct children, so gridnav's trackball/WASD navigation
-- reaches every one of them. show_screen builds the new view and hands it to
-- nav.replace BEFORE deleting the old one, so the outgoing gridnav stays alive
-- across the handoff.
local FONT = lvgl.BUILTIN_FONT.MONTSERRAT_12
local ACCENT = "#55AAFF"

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

local function heading(parent, text, color, font)
    return parent:Label{
        text = text,
        text_font = font or FONT,
        text_color = color or ACCENT,
        w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
    }
end

local function body(parent, text, color)
    return parent:Label{
        text = text,
        text_font = FONT,
        text_color = color or "#CCCCCC",
        w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
    }
end

local function create_main_screen() end
local function create_controls_screen() end
local function create_about_screen() end

-- ============================================================
-- Key bindings (lib/keybind)
-- ============================================================
-- Games receive ACTIONS, not keys: the firmware -keymap (built from these
-- bindings by keybind) turns whatever the user bound into the action codes
-- 0xA0..0xA7, and a game reads those codes. Game code and on-screen hints
-- name the ACTION ("fire = select"); which physical key that is lives here,
-- on this screen, only. Quit (0xFF) is appended by the lib itself and is
-- swallowed by the firmware, so it exits the module from any game.
-- The codes sit above every input code in use (ASCII, 0x80 shift,
-- 0x81-0x85 trackball) so they can only arrive as keymap outputs.
kb = keybind.new{
    -- No separate fire action: Down IS use-item in the race (nothing else
    -- reads Down there — the game has no braking, drag is the only
    -- decelerator), and Thrust or trackball click selects in menus.
    -- 0xA5 was fire's code; it stays unassigned.
    actions = {
        { id = "up",      label = "Up / Thrust",      out = 0xA0,
          key1 = "w", key2 = "TrkUp" },
        { id = "down",    label = "Down / Use item",  out = 0xA1,
          key1 = "s", key2 = "TrkDn" },
        { id = "left",    label = "Left",             out = 0xA2, key1 = "a" },
        { id = "right",   label = "Right",            out = 0xA3, key1 = "d" },
        { id = "thrust",  label = "Thrust / Select",  out = 0xA4,
          key1 = "Space" },
        { id = "pause",   label = "Pause / Back",     out = 0xA6, key1 = "p" },
        { id = "restart", label = "Restart",          out = 0xA7, key1 = "r" },
    },
    root = root, show_screen = show_screen,
    font = FONT, accent = ACCENT,
    note = "Keys bind to game ACTIONS; games name\n"
        .. "actions, not keys, so what you set here\n"
        .. "holds in every game.\n"
        .. "Quit leaves a game instantly. Holding\n"
        .. "ALT + Backspace 1.5s always works too.",
    on_back = function() create_main_screen() end,
    on_save = save_config,
}

-- Touch controller layout (keyboardless boards, and any board once the user
-- turns touch input on). Zone outs are the same game ACTION codes the
-- keymap produces (0xA0..0xA7), so touch and keys reach games identically.
-- lib/padlayout owns the user's edits — drag, resize, per-pad off —
-- persisted per app; this is only the default. The lib ships with firmware
-- newer than this launcher's min_fw, so it may be absent.
local pl_ok, padlayout = pcall(require, "lib/padlayout")
if not pl_ok then padlayout = nil end

local pad = padlayout and padlayout.new{
    app = "Jet_3D",
    presets = { {
        name = "Default",
        zones = {
            { id="up",      out=0xA0, label="^",    x=52,  y=118, w=64, h=56 },
            { id="left",    out=0xA2, label="<",    x=0,   y=174, w=56, h=66 },
            { id="down",    out=0xA1, label="v",    x=56,  y=174, w=60, h=66 },
            { id="right",   out=0xA3, label=">",    x=116, y=174, w=56, h=66 },
            { id="thrust",  out=0xA4, label="GO",   x=254, y=160, w=66, h=76 },
            { id="pause",   out=0xA6, label="PAUS", x=120, y=0,   w=62, h=30 },
            { id="restart", out=0xA7, label="RST",  x=186, y=0,   w=56, h=30 },
            { id="quit",    out=keybind.QUIT, label="QUIT", x=0, y=0, w=52, h=30 },
        },
    } },
} or nil

-- ============================================================
-- Main screen
-- ============================================================
create_main_screen = function()
    show_screen(function(c)
        c:Label{
            text = "Jet 3D",
            text_font = lvgl.BUILTIN_FONT.MONTSERRAT_22,
            text_color = ACCENT,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        body(c, "Software 3D engine with its own Lua\nruntime. Games are folders holding a\nmain.lua.", "#888888")

        heading(c, "Game", "#CCCCCC")

        if #found_games == 0 then
            body(c, "No games found.\nPut a folder with main.lua in\nS:/jet3d/ on the SD card.", "#FF6666")
        else
            local names = {}
            for i, g in ipairs(found_games) do names[i] = g.name end
            local dd = c:Dropdown{
                options = table.concat(names, "\n"),
                w = lvgl.PCT(100), h = 28,
            }
            dd:set{ selected = sel_game - 1 }
            dd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
                sel_game = dd:get("selected") + 1
                save_config()
            end)

            local launchBtn = c:Button{ w = lvgl.PCT(100), h = 30 }
            launchBtn:Label{ text = "Launch", align = lvgl.ALIGN.CENTER }
            launchBtn:onClicked(function()
                local g = found_games[sel_game]
                if not g then return end
                lvgl.Timer{
                    period = 50,
                    cb = function(t)
                        t:delete()
                        local args = {
                            ELF_PATH,
                            "-game", to_vfs_path(g.path .. "/main.lua"),
                            "-band", tostring(BAND_ROWS),
                        }
                        if CHECKERBOARD then
                            args[#args + 1] = "-checkerboard"
                            args[#args + 1] = "1"
                        end
                        if DBUF then
                            args[#args + 1] = "-dbuf"
                            args[#args + 1] = "1"
                        end
                        if not FOG then
                            args[#args + 1] = "-fog"
                            args[#args + 1] = "0"
                        end
                        local km = kb:keymap_string()
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
        end

        local ctrlBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        ctrlBtn:Label{ text = "Controls", align = lvgl.ALIGN.CENTER }
        ctrlBtn:onClicked(function() create_controls_screen() end)

        if pad then
            local touchBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
            touchBtn:Label{ text = "Touch", align = lvgl.ALIGN.CENTER }
            touchBtn:onClicked(function()
                pad:open{
                    show_screen = show_screen, font = FONT, accent = ACCENT,
                    on_back = function() create_main_screen() end,
                }
            end)
        end

        local aboutBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        aboutBtn:Label{ text = "About", align = lvgl.ALIGN.CENTER }
        aboutBtn:onClicked(function() create_about_screen() end)

        local quitBtn = c:Button{ w = lvgl.PCT(100), h = 28 }
        quitBtn:Label{ text = "Quit", align = lvgl.ALIGN.CENTER }
        quitBtn:onClicked(function() apps.go_home() end)
    end)
end

-- ============================================================
-- Controls — the shared keybind screens (see the kb table above)
-- ============================================================
create_controls_screen = function()
    kb:open()
end

-- ============================================================
-- About  -- engine licensing and credits
-- ============================================================
create_about_screen = function()
    show_screen(function(c)
        heading(c, "ABOUT", ACCENT)

        body(c, "3D rendering by Jet\n"
             .. "(c) CubeCoders Limited\n"
             .. "License: AGPL-3.0-or-later\n"
             .. "github.com/CubeCoders/Jet\n\n"
             .. "A fixed-function software rasteriser\n"
             .. "using integer math, rendering RGB565\n"
             .. "directly into a band of internal SRAM.\n\n"
             .. "Scripting by Lua 5.5\n"
             .. "(c) 1994-2025 Lua.org, PUC-Rio\n"
             .. "License: MIT\n"
             .. "lua.org\n\n"
             .. "This module is distributed under the\n"
             .. "AGPL. Its complete source, including\n"
             .. "the Meshpunk glue, is in the app repo\n"
             .. "this app installs from:\n"
             .. "github.com/PhilMo6/meshpunk-apps\n"
             .. "  module-src/jet3d\n"
             .. "It also ships with the firmware\n"
             .. "sources.\n\n"
             .. "The Meshpunk firmware itself remains\n"
             .. "MIT licensed: no Jet code is built\n"
             .. "into it, and this module is a separate\n"
             .. "program loaded on demand.")

        local backBtn = c:Button{ w = lvgl.PCT(100), h = 28 }
        backBtn:Label{ text = "Back", align = lvgl.ALIGN.CENTER }
        backBtn:onClicked(function() create_main_screen() end)
    end)
end

-- ============================================================
-- Startup
-- ============================================================
local init_phase = 0
return function()
    init_phase = init_phase + 1

    if init_phase == 1 then
        scan_dir_for_games(app_dir .. "/games")
        return false
    elseif init_phase == 2 then
        scan_dir_for_games(sd_app_dir .. "/games")
        return false
    elseif init_phase == 3 then
        scan_dir_for_games("S:/jet3d")
        return false
    end

    table.sort(found_games, function(a, b)
        return a.name:lower() < b.name:lower()
    end)

    load_config()
    if sel_game_name then
        for i, g in ipairs(found_games) do
            if g.name == sel_game_name then sel_game = i; break end
        end
    end
    if sel_game > #found_games then sel_game = 1 end

    create_main_screen()
    return true
end

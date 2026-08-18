local lvgl = require("lvgl")
local apps = require("lib/apps")
local nav = require("lib/nav")
local fileman = require("lib/fileman")
local keybind = require("lib/keybind")

local app_dir = ...

local W = lvgl.HOR_RES()
local H = lvgl.VER_RES()

-- ============================================================
-- PICO-8 (fake-08) Launcher
-- ============================================================

-- Derive SD-side mirror of app directory:
-- "L:/lua/apps/Games/PICO-8" -> "S:/lua/apps/Games/PICO-8"
local sd_app_dir = app_dir:gsub("^L:", "S:")

-- Convert firmware path prefixes to VFS mount points for the ELF module's fopen
local function to_vfs_path(path)
    if path:sub(1, 2) == "S:" then return "/sd" .. path:sub(3) end
    if path:sub(1, 2) == "L:" then return "/littlefs" .. path:sub(3) end
    return path
end

-- Search for a file: check app dir, then SD mirror, then legacy S:/p8carts/
local function find_file(name)
    local search = { app_dir, sd_app_dir, "S:/p8carts" }
    for _, dir in ipairs(search) do
        local path = dir .. "/" .. name
        local f = io.open(path, "r")
        if f then f:close(); return path end
    end
    return nil
end

local CFG_PATH = app_dir .. "/controls.cfg"
local ELF_PATH = find_file("pico8.app.elf") or sd_app_dir .. "/pico8.app.elf"

local found_carts = {}   -- { {name, path}, ... }
local seen_lower = {}
local selected_cart = 1
local selected_cart_name = nil
local scr = nil

-- Stable, manager-registered root. Every view is a single navigable scope: one
-- flex container whose focusable children are ALL direct children, so gridnav's
-- trackball/WASD navigation reaches every one of them.
local root = apps.new_root({
    w = W, h = H,
    bg_color = "#000000", bg_opa = lvgl.OPA(255),
    border_width = 0, pad_all = 0,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)

-- fileman routes the drive from the L:/S: prefix itself; sizes=false skips
-- the per-entry size lookup, so huge cart folders list fast (watchdog-safe).
local function scan_dir_for_carts(dir_path)
    local entries = fileman.list(dir_path, {
        sizes = false,
        filter = function(e)
            return e.type == "file"
                and (e.name:lower():match("%.p8$") or e.name:lower():match("%.p8%.png$"))
        end,
    }) or {}
    for _, e in ipairs(entries) do
        local low = e.name:lower()
        if not seen_lower[low] then
            seen_lower[low] = true
            found_carts[#found_carts + 1] = {
                name = e.name,
                path = dir_path .. "/" .. e.name,
            }
        end
    end
end

-- ============================================================
-- Keymap / controls system
-- ============================================================

-- PICO-8 button target codes: these are the key codes that mapKeyToP8()
-- inside the ELF understands. The launcher maps physical keys to these
-- via the host's keymap system.
local P8 = {
    UP    = 0x77,  -- 'w' -> P8_KEY_UP
    DOWN  = 0x73,  -- 's' -> P8_KEY_DOWN
    LEFT  = 0x61,  -- 'a' -> P8_KEY_LEFT
    RIGHT = 0x64,  -- 'd' -> P8_KEY_RIGHT
    O     = 0x7A,  -- 'z' -> P8_KEY_O
    X     = 0x78,  -- 'x' -> P8_KEY_X
    PAUSE = 0x0D,  -- Enter -> P8_KEY_PAUSE
}

-- What this launcher wants bound. lib/keybind owns the key table, the Controls
-- and picker screens, storage and the -keymap/-trkball strings, and appends the
-- standard Quit action itself. Defaults name keys rather than repeating codes.
local ACTIONS = {
    { id="up",    label="Up",      out=P8.UP,    key1="w",     key2="TrkUp"  },
    { id="down",  label="Down",    out=P8.DOWN,  key1="s",     key2="TrkDn"  },
    { id="left",  label="Left",    out=P8.LEFT,  key1="a",     key2="TrkLt"  },
    { id="right", label="Right",   out=P8.RIGHT, key1="d",     key2="TrkRt"  },
    { id="btn_o", label="O btn",   out=P8.O,     key1="z",     key2="TrkClk" },
    { id="btn_x", label="X btn",   out=P8.X,     key1="x",     key2="Space"  },
    { id="pause", label="Pause",   out=P8.PAUSE, key1="Enter", key2="p"      },
}

-- Touch controller layout (keyboardless boards, and any board once the user
-- turns touch input on). lib/padlayout owns the user's edits — drag, resize,
-- per-pad off — persisted per app; this is only the default. The lib ships
-- with firmware newer than this launcher's min_fw, so it may be absent.
local pl_ok, padlayout = pcall(require, "lib/padlayout")
if not pl_ok then padlayout = nil end

local pad = padlayout and padlayout.new{
    app = "PICO-8",
    presets = { {
        name = "Default",
        zones = {
            { id="up",    out=P8.UP,    label="^",   x=52,  y=118, w=64, h=56 },
            { id="left",  out=P8.LEFT,  label="<",   x=0,   y=174, w=56, h=66 },
            { id="down",  out=P8.DOWN,  label="v",   x=56,  y=174, w=60, h=66 },
            { id="right", out=P8.RIGHT, label=">",   x=116, y=174, w=56, h=66 },
            { id="btn_o", out=P8.O,     label="O",   x=188, y=174, w=60, h=66 },
            { id="btn_x", out=P8.X,     label="X",   x=254, y=152, w=66, h=66 },
            { id="pause", out=P8.PAUSE, label="PAU", x=120, y=0,   w=58, h=30 },
            { id="quit",  out=keybind.QUIT, label="QUIT", x=0, y=0, w=52, h=30 },
        },
    } },
} or nil

-- Built once the screen helpers below exist; save_config/load_config reach it
-- as an upvalue.
local kb

-- Save bindings + settings to config file
local function save_config()
    local f = io.open(CFG_PATH, "w")
    if not f then return end
    kb:save_lines(f)
    if #found_carts > 0 then
        f:write("cart=" .. found_carts[selected_cart].name .. "\n")
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
        local cname = line:match("^cart=(.+)$")
        if cname then selected_cart_name = cname end
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
local ACCENT = "#FF77A8"

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
            text = "PICO-8",
            text_font = lvgl.BUILTIN_FONT.MONTSERRAT_22,
            text_color = ACCENT,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        -- Cart selector — dropdown over all found carts
        local cart_opts = "No carts found"
        if #found_carts > 0 then
            local names = {}
            for i, cc in ipairs(found_carts) do names[i] = cc.name end
            cart_opts = table.concat(names, "\n")
        end

        local cartDd = c:Dropdown{
            options = cart_opts,
            w = lvgl.PCT(100), h = 28,
        }
        if #found_carts > 0 then
            cartDd:set{ selected = selected_cart - 1 }
        end

        -- Stable preview slot (non-focusable): holds the .p8.png cart art when
        -- the selected cart is a label image. A fixed slot keeps the preview in
        -- place across selection changes instead of re-flowing the layout.
        local preview = c:Object{
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
            bg_opa = 0, border_width = 0, pad_all = 0,
        }
        preview:clear_flag(lvgl.FLAG.SCROLLABLE)
        preview:clear_flag(lvgl.FLAG.CLICKABLE)

        local function update_cart_preview()
            preview:clean()
            if #found_carts == 0 then return end
            local cc = found_carts[selected_cart]
            if not cc.name:lower():match("%.p8%.png$") then return end
            preview:Image{
                src = cc.path,
                align = lvgl.ALIGN.CENTER,
            }
        end

        cartDd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
            if #found_carts == 0 then return end
            selected_cart = cartDd:get("selected") + 1
            update_cart_preview()
            save_config()
        end)

        -- Status
        local has_carts = #found_carts > 0
        local status = c:Label{
            text = has_carts and "Ready to play"
                   or "Place .p8 carts in S:/p8carts/",
            text_font = FONT,
            text_color = has_carts and "#888888" or "#FF6666",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        local launchBtn = c:Button{ w = lvgl.PCT(48), h = 34 }
        launchBtn:Label{ text = "Play", align = lvgl.ALIGN.CENTER }
        launchBtn:onClicked(function()
            if #found_carts == 0 then
                status:set{ text = "No .p8 cart found!" }
                return
            end
            status:set{ text = "Loading..." }
            local km = kb:keymap_string()
            lvgl.Timer{
                period = 50,
                cb = function(t)
                    t:delete()
                    local cc = found_carts[selected_cart]
                    local vfs_cart = to_vfs_path(cc.path)
                    -- Deferred launch: the firmware tears Lua down, runs the cart,
                    -- then recreates Lua and returns to the launcher home. _launch_elf
                    -- only queues the request, so there's no result to handle here.
                    local args = { ELF_PATH, vfs_cart,
                        "-trkball", kb:trkball_string() }
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

        update_cart_preview()
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
-- About screen — player license and credits.
-- The scope container scrolls (nav.SCROLL_FIRST), so the text runs
-- past the panel height without extra machinery.
-- ============================================================
create_about_screen = function()
    show_screen(function(c)
        heading(c, "ABOUT", ACCENT)

        c:Label{
            text = "Cart player: FAKE-08 by jtothebell\n"
                 .. "License: MIT\n"
                 .. "github.com/jtothebell/fake-08\n\n"
                 .. "Not affiliated with or supported by\n"
                 .. "Lexaloffle Games.\n\n"
                 .. "T-Deck ELF conversion by mintylinux.\n\n"
                 .. "Bundled libraries:\n"
                 .. "z8lua (MIT) - Sam Hocevar\n"
                 .. "Lua (MIT) - PUC-Rio\n"
                 .. "LodePNG (zlib) - Lode Vandevenne\n"
                 .. "miniz (MIT) - Rich Geldreich\n"
                 .. "SimpleIni (MIT) - Brodie Thiesfield\n\n"
                 .. "Code ported from:\n"
                 .. "zepto8 (WTFPL-2) - Sam Hocevar\n"
                 .. "  audio, tline, PNG decompression\n"
                 .. "tac08 (MIT) - 0xcafed00d\n"
                 .. "  sprite rendering, cart parsing\n"
                 .. "PicoLove (zlib) - gamax92\n"
                 .. "  noise synthesis\n"
                 .. "LovePotion (MIT) - TurtleP\n\n"
                 .. "PICO-8 is (c) Lexaloffle Games LLP.\n"
                 .. "No carts are included - supply your\n"
                 .. "own. Buy PICO-8 if you can.",
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
local init_phase = 0
return function()
    init_phase = init_phase + 1

    -- Phase 1-3: directory scanning
    if init_phase == 1 then
        scan_dir_for_carts(app_dir)
        return false
    elseif init_phase == 2 then
        scan_dir_for_carts(sd_app_dir)
        return false
    elseif init_phase == 3 then
        if sd_app_dir ~= "S:/p8carts" then
            scan_dir_for_carts("S:/p8carts")
        end
        return false
    end

    -- Final phase: sort carts, load config, show UI
    table.sort(found_carts, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    load_config()
    -- Restore cart selection by name
    if selected_cart_name then
        for i, cc in ipairs(found_carts) do
            if cc.name == selected_cart_name then selected_cart = i; break end
        end
    end
    create_main_screen()
    return true
end

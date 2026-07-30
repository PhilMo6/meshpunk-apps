local lvgl = require("lvgl")
local apps = require("lib/apps")
local nav = require("lib/nav")
local fileman = require("lib/fileman")
local downloader = require("lib/downloader")   -- WiFi wait; see Download DOS

local app_dir = ...

local W = lvgl.HOR_RES()
local H = lvgl.VER_RES()

-- ============================================================
-- Dos (tiny386) Launcher
-- ============================================================

local sd_app_dir = app_dir:gsub("^L:", "S:")

local function to_vfs_path(path)
    if path:sub(1, 2) == "S:" then return "/sd" .. path:sub(3) end
    if path:sub(1, 2) == "L:" then return "/littlefs" .. path:sub(3) end
    return path
end

local function find_file(name)
    local search = { app_dir, sd_app_dir, "S:/dos" }
    for _, dir in ipairs(search) do
        local path = dir .. "/" .. name
        local f = io.open(path, "r")
        if f then f:close(); return path end
    end
    return nil
end

local CFG_PATH = app_dir .. "/controls.cfg"
local ELF_PATH = find_file("dos.app.elf") or sd_app_dir .. "/dos.app.elf"

local found_imgs = {}    -- { {name, path}, ... }
local seen_lower = {}
local found_folders = {} -- { {name, path}, ... } folder-backed C: candidates
local seen_folder_lower = {}
local sel_fda = 1        -- index into 1="None", 2.. = found_imgs[i-1]
local sel_hda = 1        -- index into 1="None", 2.. = hda_choices[i-1]
local hda_choices = {}   -- imgs then folders: { {kind="img"|"folder", name, path}, ... }
local sel_fda_name, sel_hda_name = nil, nil
local sel_hda_folder_name = nil
local scr = nil

local root = apps.new_root({
    w = W, h = H,
    bg_color = "#000000", bg_opa = lvgl.OPA(255),
    border_width = 0, pad_all = 0,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)

-- fileman routes the drive from the L:/S: prefix itself; sizes=false skips
-- the per-entry size lookup, so huge image folders list fast (watchdog-safe).
local function scan_dir_for_imgs(dir_path)
    local entries = fileman.list(dir_path, {
        sizes = false,
        filter = function(e)
            return e.type == "file"
                and (e.name:lower():match("%.img$") or e.name:lower():match("%.raw$"))
        end,
    }) or {}
    for _, e in ipairs(entries) do
        local low = e.name:lower()
        if not seen_lower[low] then
            seen_lower[low] = true
            found_imgs[#found_imgs + 1] = {
                name = e.name,
                path = dir_path .. "/" .. e.name,
            }
        end
    end
end

-- Subfolders double as C: drives (module synthesizes a FAT16 disk from them).
local function scan_dir_for_folders(dir_path)
    local entries = fileman.list(dir_path, {
        sizes = false,
        filter = function(e) return e.type == "dir" end,
    }) or {}
    for _, e in ipairs(entries) do
        local low = e.name:lower()
        if not seen_folder_lower[low] then
            seen_folder_lower[low] = true
            found_folders[#found_folders + 1] = {
                name = e.name,
                path = dir_path .. "/" .. e.name,
            }
        end
    end
end

-- FolderDisk manifest: line 1 = folder VFS root, then one line per entry
-- "relpath<TAB>size<TAB>isdir". The module resolves each entry's parent by
-- prefix lookup, so a directory must appear before anything inside it
-- (pre-order walk). Rewritten fresh at every boot.
local MANIFEST_PATH = app_dir .. "/cdrive.man"
local MANIFEST_MAX_ENTRIES = 1024
local function write_cdrive_manifest(folder_path)
    local f = io.open(MANIFEST_PATH, "w")
    if not f then return nil end
    f:write(to_vfs_path(folder_path) .. "\n")
    local count = 0
    local function walk(dir, rel, depth)
        if depth > 8 or count >= MANIFEST_MAX_ENTRIES then return end
        local entries = fileman.list(dir, { sizes = true }) or {}
        for _, e in ipairs(entries) do
            if count >= MANIFEST_MAX_ENTRIES then return end
            local erel = (rel == "") and e.name or (rel .. "/" .. e.name)
            count = count + 1
            if e.type == "dir" then
                f:write(erel .. "\t0\t1\n")
                walk(dir .. "/" .. e.name, erel, depth + 1)
            else
                f:write(erel .. "\t" .. tostring(e.size or 0) .. "\t0\n")
            end
        end
    end
    walk(folder_path, "", 1)
    f:close()
    return to_vfs_path(MANIFEST_PATH)
end

-- ============================================================
-- Keymap / controls system
-- ============================================================

-- Module extension codes understood by the DOS module's ascii_to_scan() (dos_input.c)
local PC = {
    ESC   = 0x1B,
    F1    = 0xB0, F2 = 0xB1, F3 = 0xB2, F4 = 0xB3, F5 = 0xB4,
    F6    = 0xB5, F7 = 0xB6, F8 = 0xB7, F9 = 0xB8, F10 = 0xB9,
    CTRL  = 0x96,
    ALT   = 0x97,
    DEL   = 0x98,
    TAB   = 0x99,
    UP    = 0x91, DOWN = 0x92, LEFT = 0x93, RIGHT = 0x94,
    RMOUSE = 0x95,
}

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

-- DOS needs keys the T-Deck doesn't have. All unbound by default — binding a
-- physical key STEALS it from typing, so users bind only what a game needs.
local ACTIONS = {
    { id="esc",    label="Esc",    pc=PC.ESC    },
    { id="up",     label="Up",     pc=PC.UP     },
    { id="down",   label="Down",   pc=PC.DOWN   },
    { id="left",   label="Left",   pc=PC.LEFT   },
    { id="right",  label="Right",  pc=PC.RIGHT  },
    { id="ctrl",   label="Ctrl",   pc=PC.CTRL   },
    { id="alt",    label="Alt",    pc=PC.ALT    },
    { id="tab",    label="Tab",    pc=PC.TAB    },
    { id="del",    label="Del",    pc=PC.DEL    },
    { id="f1",     label="F1",     pc=PC.F1     },
    { id="f2",     label="F2",     pc=PC.F2     },
    { id="f3",     label="F3",     pc=PC.F3     },
    { id="f4",     label="F4",     pc=PC.F4     },
    { id="f5",     label="F5",     pc=PC.F5     },
    { id="f6",     label="F6",     pc=PC.F6     },
    { id="f7",     label="F7",     pc=PC.F7     },
    { id="f8",     label="F8",     pc=PC.F8     },
    { id="f9",     label="F9",     pc=PC.F9     },
    { id="f10",    label="F10",    pc=PC.F10    },
    { id="rmouse", label="R.Mouse", pc=PC.RMOUSE },
}

local bindings = {}

-- WASD -> arrows out of the box: the arrows are what DOS games want most and
-- what the T-Deck lacks entirely, and binding costs nothing while the binding
-- layer starts OFF (ALT+Enter turns it on). Everything else stays unbound --
-- a binding steals its key from typing, so users opt into the rest.
local DEFAULT_BINDS = { up = KEYS.w, left = KEYS.a, down = KEYS.s, right = KEYS.d }

local function load_defaults()
    bindings = {}
    for _, a in ipairs(ACTIONS) do
        bindings[a.id] = { pc = a.pc, key1 = DEFAULT_BINDS[a.id], key2 = nil }
    end
end

-- Build the -keymap hex string. Returns nil when nothing is bound (then we
-- omit -keymap entirely = full passthrough). The firmware keymap is a pure
-- remapper (unmapped codes pass through unchanged), so only the actual
-- bindings are emitted — no identity entries needed.
local function build_keymap_string()
    local parts = {}
    for _, a in ipairs(ACTIONS) do
        local b = bindings[a.id]
        if b and (b.key1 or b.key2) then
            local s = string.format("%02X=", b.pc)
            if b.key1 then
                s = s .. string.format("%02X", b.key1)
                if b.key2 then s = s .. string.format("+%02X", b.key2) end
            else
                s = s .. string.format("%02X", b.key2)
            end
            parts[#parts + 1] = s
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ",")
end

-- Trackball momentum settings (used in arrow-keys mode, i.e. mouse off)
local trk_momentum = true
local trk_impulse  = 15
local trk_friction = 82
local trk_thresh   = 4

local function build_trkball_string()
    return string.format("%d,%d,%d,%d",
        trk_momentum and 1 or 0, trk_impulse, trk_friction, trk_thresh)
end

-- ============================================================
-- Emulator settings
-- ============================================================
-- tiny386 CPU generation: 3=386, 4=486, 5=586, 6=686. Higher generations only
-- add instructions; they don't make the emulator faster. 486 is upstream's own
-- default and what SeaBIOS expects.
local CPU_GENS  = { 3, 4, 5, 6 }
local CPU_NAMES = { "386", "486", "586", "686" }
local sel_cpu   = 2      -- 486 default

-- Box-filter modes that are larger than the panel. 80-column text is 640x400
-- and loses 40% of its scanlines on the way to 240 rows; without filtering the
-- dropped rows delete parts of glyphs (a 'b' reads as an 'h'). Filtering keeps
-- them as grey, which is complete but softer. Modes that are not shrinking are
-- point-sampled either way, so games stay sharp regardless.
local text_smooth = true

-- vga_step() signals "refresh due" at 60Hz but the panel only takes ~11fps, so
-- ungated the emulator builds five full screen renders for every one shown. ON
-- renders only frames we will display; OFF is upstream's behaviour, kept as an
-- escape hatch if a game ever needs every frame composed.
local render_gate = true

-- Render pixel-doubled modes (13h etc) at their real 320x200 source size rather
-- than the 640x400 timing size, letting the blit scale instead. Measured 1.88x
-- on emulated CPU. OFF restores upstream's behaviour as an escape hatch.
local native_res = true

-- Folder-as-C: is a read-write drive: DOS can create, delete and rewrite files
-- and they become real files in the folder on the SD card. ON here makes it
-- read-only again (writes are refused, not silently dropped) as a safety valve.
local cdrive_ro = false
-- Audio RATE, not a toggle. The guest's SoundBlaster interrupt handler only
-- runs because the emulator drains its DMA buffer, so draining N times slower
-- means N times fewer interrupts and N times less emulated CPU burned inside
-- the game's own audio code. Pitch and speed drop by the same factor.
-- PERCENT of the normal audio rate. The cycle steps DOWN from FULL in tenths
-- so the highest rate the guest keeps up with is found by walking 0.9, 0.8,
-- ... until clean. 0 = off, which is cheapest of all.
local audio_pct = 100
-- SB digital mode. 1 = ON (normal card). 3 = NO DMA: DSP and interrupts work
-- but SB DMA transfers never progress, so a game's DMA verification fails
-- and it disables digitised playback only (music keeps working in games with
-- that branch). 2 = NO IRQ: the DSP answers but the card's interrupt line
-- never raises (the classic wrong-IRQ-jumper condition) so a game's IRQ test
-- fails fast and deterministically. 0 = OFF: the DSP ports float entirely
-- (detection itself fails -- some games retry that for minutes). For games
-- that freeze or crash playing digitised speech/effects (per-sample players
-- demand interrupt rates far beyond the emulated CPU).
local sb_digital = 1
-- Timer cap. Per-sample digitised-audio players (SB direct DAC, Covox,
-- PC-speaker PWM) reprogram the system timer to the sample rate -- ~20k
-- interrupts/s, several times the emulated CPU's whole budget, so the guest
-- livelocks whenever a sample plays. ON delivers channel-0 interrupts at most
-- 1000/s; the skipped periods are dropped, so the sample just advances slowly
-- in the background while the game keeps running. Normal game timer rates
-- pass through untouched. OFF = stock behaviour.
local pit_cap = false
local AUDIO_CHOICES = { 100, 90, 80, 70, 60, 50, 40, 30, 20, 0 }
local AUDIO_NAMES = { [100]="FULL", [90]="0.9", [80]="0.8", [70]="0.7",
                      [60]="0.6", [50]="0.5", [40]="0.4", [30]="0.3",
                      [20]="0.2" }
local function audio_label()
    if audio_pct == 0 then return "< OFF >" end
    return "< " .. (AUDIO_NAMES[audio_pct] or (audio_pct .. "%")) .. " >"
end
local mouse_speed = 0    -- 0 = arrow keys (default: most DOS games are
                         -- keyboard-driven), 1..5 = PS/2 mouse at that speed
                         -- (needs a DOS mouse driver like CTMOUSE loaded)
-- Click latch (mouse mode): each trackball click toggles the mouse button
-- held/released instead of following the physical press -- dragging without
-- holding the ball pressed while rolling it.
local click_latch = false
-- No boot-drive selector: SeaBIOS owns the boot order.

local function save_config()
    local f = io.open(CFG_PATH, "w")
    if not f then return end
    for _, a in ipairs(ACTIONS) do
        local b = bindings[a.id]
        local k1 = b.key1 and string.format("%02X", b.key1) or "--"
        local k2 = b.key2 and string.format("%02X", b.key2) or "--"
        f:write(a.id .. "=" .. k1 .. "," .. k2 .. "\n")
    end
    f:write(string.format("trk_momentum=%d\n", trk_momentum and 1 or 0))
    f:write(string.format("trk_impulse=%d\n", trk_impulse))
    f:write(string.format("trk_friction=%d\n", trk_friction))
    f:write(string.format("trk_thresh=%d\n", trk_thresh))
    f:write(string.format("cpu=%d\n", sel_cpu))
    f:write(string.format("smooth=%d\n", text_smooth and 1 or 0))
    f:write(string.format("rgate=%d\n", render_gate and 1 or 0))
    f:write(string.format("native=%d\n", native_res and 1 or 0))
    f:write(string.format("cro=%d\n", cdrive_ro and 1 or 0))
    f:write(string.format("audio=%d\n", audio_pct))
    f:write(string.format("sbdigi=%d\n", sb_digital))
    f:write(string.format("pitcap=%d\n", pit_cap and 1 or 0))
    f:write(string.format("mousespd=%d\n", mouse_speed))
    f:write(string.format("mlatch=%d\n", click_latch and 1 or 0))
    if sel_fda > 1 then f:write("fda=" .. found_imgs[sel_fda - 1].name .. "\n") end
    if sel_hda > 1 then
        local c = hda_choices[sel_hda - 1]
        if c and c.kind == "folder" then
            f:write("hdafolder=" .. c.name .. "\n")
        elseif c then
            f:write("hda=" .. c.name .. "\n")
        end
    end
    f:close()
end

local function load_config()
    load_defaults()
    local f = io.open(CFG_PATH, "r")
    if not f then return false end
    local text = f:read("*a")
    f:close()
    if not text then return false end
    for line in text:gmatch("[^\r\n]+") do
        local id, k1s, k2s = line:match("^([%w_]+)=(%S+),(%S+)$")
        if id and bindings[id] then
            bindings[id].key1 = (k1s ~= "--") and tonumber(k1s, 16) or nil
            bindings[id].key2 = (k2s ~= "--") and tonumber(k2s, 16) or nil
        end
        local val = line:match("^trk_momentum=([01])$")
        if val then trk_momentum = (val == "1") end
        local trk_key, trk_val = line:match("^(trk_%a+)=(%d+)$")
        if trk_key == "trk_impulse" then trk_impulse = tonumber(trk_val) end
        if trk_key == "trk_friction" then trk_friction = tonumber(trk_val) end
        if trk_key == "trk_thresh" then trk_thresh = tonumber(trk_val) end
        local v = line:match("^cpu=(%d+)$")
        if v then
            v = tonumber(v)
            if v >= 1 and v <= #CPU_GENS then sel_cpu = v end
        end
        v = line:match("^smooth=([01])$")
        if v then text_smooth = (v == "1") end
        v = line:match("^rgate=([01])$")
        if v then render_gate = (v == "1") end
        v = line:match("^native=([01])$")
        if v then native_res = (v == "1") end
        v = line:match("^cro=([01])$")
        if v then cdrive_ro = (v == "1") end
        v = line:match("^audio=(%d+)$")
        if v then audio_pct = tonumber(v) or 100 end
        v = line:match("^sbdigi=([0123])$")
        if v then sb_digital = tonumber(v) end
        v = line:match("^pitcap=([01])$")
        if v then pit_cap = (v == "1") end
        v = line:match("^mlatch=([01])$")
        if v then click_latch = (v == "1") end
        v = line:match("^mousespd=(%d+)$")
        if v then
            v = tonumber(v)
            if v >= 0 and v <= 5 then mouse_speed = v end
        end
        local fname = line:match("^fda=(.+)$")
        if fname then sel_fda_name = fname end
        fname = line:match("^hda=(.+)$")
        if fname then sel_hda_name = fname end
        fname = line:match("^hdafolder=(.+)$")
        if fname then sel_hda_folder_name = fname end
    end
    return true
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

-- ── Per-setting help ────────────────────────────────────────────────────────
-- Every compatibility setting gets a "?" beside it. These exist because a
-- misbehaving DOS game gives you no clue which knob it needs, so each entry
-- says what the setting does AND the symptom that calls for it.
local HELP = {

cpu = { "CPU CLASS", [[
Which x86 generation the emulated CPU
claims to be, and which instructions it
accepts. 486 is the default and what the
BIOS expects.

This does NOT change speed - every class
runs through the same interpreter at the
same cost.

When to change it: raise it only if a
program refuses to run because it needs
newer instructions. Lower it to 386 in
the rare case a program misbehaves after
detecting a newer CPU.]] },

smooth = { "TEXT SMOOTHING", [[
When a video mode is TALLER than the
panel, rows have to be dropped. 80-column
DOS text is 640x400 into 240 rows, which
throws away two scanlines in every five -
enough to erase the bottom of a 'b' and
leave an 'h'.

ON averages the dropped row into its
neighbour, so the stroke survives as grey.
OFF drops it outright: sharper, but text
loses pieces.

Leave it ON for DOS work. Turn it OFF for
games, which are usually 320x200 and are
not shrinking at all - filtering there
only blurs them.]] },

rgate = { "RENDER GATE", [[
The emulated VGA signals a new frame 60
times a second; the panel can show about
11. ON composes only the frames that will
actually be displayed, and throws the
rest away before doing the work.

Leave it ON - it is free speed. Turn it
OFF only if a game's animation looks
wrong in a way that suggests it needs
every frame composed.]] },

native = { "NATIVE RES", [[
Low-resolution VGA modes are programmed
as high-resolution timing with every
pixel drawn twice across and every line
twice down: mode 13h is 320x200 of real
content rendered as 640x400, so three of
every four pixel writes are duplicates
that get scaled away again.

ON renders the real size instead -
measured at 1.88x the emulated CPU speed.

Leave it ON. It is an escape hatch for a
mode that displays wrong.]] },

cwrites = { "FOLDER C: WRITES", [[
A game folder mounted as C: is a REAL
writable drive: installers create files,
games save, and it all lands in the
folder on your SD card.

OFF makes it read-only. Writes are
refused so DOS reports an error, rather
than being silently dropped.

Turn it OFF to protect a folder you do
not want a game (or a stray installer) to
change.]] },

audio = { "AUDIO RATE", [[
DOS games compute every audio sample on
the emulated CPU. When a game cannot keep
up at FULL rate, the gaps come out as
static and clicks.

Lowering the rate slows the Sound
Blaster's sample clock: the game spends
less CPU on audio, so the defects fade out
and emulation runs faster - at the cost of
slower, lower-pitched sound.

Step down in tenths until the noise stops.

Recommended: 0.5 if you hear static. OFF
gives maximum emulation speed.]] },

sbdigi = { "SB DIGITAL", [[
Fakes a broken Sound Blaster so a game
disables the audio our CPU cannot afford.
Digitised sound (recorded speech and
effects) is computed by the GAME on the
emulated CPU; some games demand more of
it than the emulator can deliver and hang
or crash.

ON - normal card.
NO DMA - card works, its DMA does not.
  Games that check usually keep MUSIC and
  turn digitised effects off. Try this
  first.
NO IRQ - card works, its interrupt line
  is dead. Some games then disable sound
  entirely.
OFF - no card at all. Last resort: a few
  games retry detection for minutes.

Use it when a game freezes or crashes the
moment a sound effect plays.]] },

pitcap = { "TIMER CAP", [[
Some games play sound by reprogramming
the system timer to the sample rate and
feeding one sample per interrupt - about
20,000 interrupts a second, several times
the emulated CPU's whole budget. The game
starves the moment a sound starts.

ON delivers those interrupts at most 1000
a second and drops the rest. Normal game
timer rates pass through untouched.

Use it when a game hangs as soon as it
plays digitised sound. Side effect: a
game that also derives its own clock from
that timer will run slow.]] },

trkball = { "TRACKBALL", [[
Arrow keys - rolling the ball sends arrow
key presses. What most DOS games want.

Mouse x1-x5 - the ball is a PS/2 mouse at
that speed. This needs a mouse DRIVER
loaded inside DOS (CTMOUSE is on the
FreeDOS disks we provide) AND a game that
supports a mouse.

Note this resets to Arrow keys whenever
the device filesystem is reflashed.]] },

mlatch = { "CLICK LATCH", [[
OFF - the mouse button follows the ball
button: press and hold to drag.

ON - a click PRESSES and holds the button,
the next click releases it. Dragging
without keeping the ball pressed while
you roll it, which is easier on menus and
paint programs.

ALT + click switches this while a game is
running; the keyboard backlight blinks
once when it changes.]] },

}

local function create_help_topic(key, back) end

-- A full-width, non-focusable heading/label (gridnav skips non-clickables).
local function heading(parent, text, color, font)
    return parent:Label{
        text = text,
        text_font = font or FONT,
        text_color = color or ACCENT,
        w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
    }
end

-- A label + value button pair; the value button cycles and persists. Both are
-- direct children of the scope so the trackball can land on each button.
-- With a help_key the value button narrows to make room for a "?" beside it,
-- opening that topic from HELP above.
local function setting_row(parent, label, get_text, on_click, help_key)
    parent:Label{
        text = label,
        text_font = FONT,
        text_color = "#CCCCCC",
        w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
    }
    local valBtn = parent:Button{ w = lvgl.PCT(help_key and 78 or 100), h = 28 }
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
    if help_key then
        local qBtn = parent:Button{ w = lvgl.PCT(18), h = 28 }
        qBtn:Label{ text = "?", text_font = FONT, align = lvgl.ALIGN.CENTER }
        qBtn:onClicked(function() create_help_topic(help_key) end)
    end
    return valBtn
end

local function create_main_screen() end
local function create_controls_screen() end
local function create_bind_screen(action_idx, slot) end
local function create_binds_screen() end
local function create_confirm_screen(hda_choice, on_yes) end
local function create_download_screen() end
local function create_dest_screen(disk) end
local function create_input_screen() end
local function create_settings_screen() end
local function create_help_screen() end
local function create_about_screen() end

-- ============================================================
-- Main screen
-- ============================================================
create_main_screen = function()
    show_screen(function(c)
        c:Label{
            text = "DOS",
            text_font = lvgl.BUILTIN_FONT.MONTSERRAT_22,
            text_color = ACCENT,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        local img_opts = "None"
        if #found_imgs > 0 then
            local names = { "None" }
            for i, r in ipairs(found_imgs) do names[i + 1] = r.name end
            img_opts = table.concat(names, "\n")
        end

        -- C: accepts images and folders
        local hda_names = { "None" }
        for _, ch in ipairs(hda_choices) do
            hda_names[#hda_names + 1] =
                (ch.kind == "folder") and ("Folder: " .. ch.name) or ch.name
        end
        local hda_opts = table.concat(hda_names, "\n")

        -- The two slots need different KINDS of image and DOS gives a useless
        -- error if they are swapped ("Invalid drive C:"), so say it up front.
        c:Label{
            text = "A: needs a floppy image (720K/1.44M).\n"
                 .. "C: needs a hard-disk image (with a\n"
                 .. "partition table) or a game folder.\n"
                 .. "A floppy image in C: will not boot.",
            text_font = FONT,
            text_color = "#888888",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        heading(c, "A:  floppy", "#CCCCCC")
        local fdaDd = c:Dropdown{
            options = img_opts,
            w = lvgl.PCT(100), h = 28,
        }
        fdaDd:set{ selected = sel_fda - 1 }
        fdaDd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
            sel_fda = fdaDd:get("selected") + 1
            save_config()
        end)

        heading(c, "C:  hard disk / folder", "#CCCCCC")
        local hdaDd = c:Dropdown{
            options = hda_opts,
            w = lvgl.PCT(100), h = 28,
        }
        hdaDd:set{ selected = sel_hda - 1 }
        hdaDd:onevent(lvgl.EVENT.VALUE_CHANGED, function()
            sel_hda = hdaDd:get("selected") + 1
            save_config()
        end)

        -- Nothing here boots without a DISK IMAGE: a game folder is a data
        -- drive, and DOS itself has to come off a floppy or a bootable hard
        -- disk. So "have folders, no images" is still a dead end, and it is
        -- exactly the state a user lands in after copying games across.
        local has_boot = #found_imgs > 0
        local has_any = has_boot or #hda_choices > 0
        local status_text
        if has_boot then
            status_text = "Ready"
        elseif has_any then
            status_text = "No boot disk - use Download DOS"
        else
            status_text = "Put .img disks / game folders in S:/dos/"
        end
        local status = c:Label{
            text = status_text,
            text_font = FONT,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        -- No bootable IMAGE is the dead-end state (folders alone cannot boot):
        -- make the way out of it the most obvious thing on the screen, ABOVE
        -- the Boot button it is standing in for. It stays available from
        -- Settings afterwards for the other images.
        if not has_boot then
            local getBtn = c:Button{ w = lvgl.PCT(100), h = 30 }
            getBtn:Label{ text = "Download DOS", align = lvgl.ALIGN.CENTER }
            getBtn:onClicked(function() create_download_screen() end)
        end

        local launchBtn = c:Button{ w = lvgl.PCT(48), h = 30 }
        launchBtn:Label{ text = "Boot", align = lvgl.ALIGN.CENTER }
        launchBtn:onClicked(function()
            if sel_fda == 1 and sel_hda == 1 then
                status:set{ text = "Select a boot disk first!" }
                return
            end
            local hda_choice = (sel_hda > 1) and hda_choices[sel_hda - 1] or nil
            if hda_choice and hda_choice.kind == "folder" and sel_fda == 1 then
                -- Folder C: is a data drive; DOS itself must come off a floppy.
                status:set{ text = "Folder C: needs a boot floppy in A:" }
                return
            end
            create_confirm_screen(hda_choice, function()
            lvgl.Timer{
                period = 50,
                cb = function(t)
                    t:delete()
                    local args = { ELF_PATH }
                    if sel_fda > 1 then
                        args[#args + 1] = "-fda"
                        args[#args + 1] = to_vfs_path(found_imgs[sel_fda - 1].path)
                    end
                    if hda_choice and hda_choice.kind == "folder" then
                        local man = write_cdrive_manifest(hda_choice.path)
                        if man then
                            args[#args + 1] = "-cfolder"
                            args[#args + 1] = man
                        end
                    elseif hda_choice then
                        args[#args + 1] = "-hda"
                        args[#args + 1] = to_vfs_path(hda_choice.path)
                    end
                    -- No -boot argument: SeaBIOS owns the boot order (floppy
                    -- first, then hard disk), which already does the right
                    -- thing for both a bootable C: image and a folder C: that
                    -- has to be started from a DOS floppy in A:.
                    args[#args + 1] = "-cpu"
                    args[#args + 1] = tostring(CPU_GENS[sel_cpu])
                    if not text_smooth then
                        args[#args + 1] = "-smooth"
                        args[#args + 1] = "0"
                    end
                    -- Escape hatches: both defaults are the fast/correct path.
                    if not render_gate then
                        args[#args + 1] = "-render"
                        args[#args + 1] = "0"
                    end
                    if not native_res then
                        args[#args + 1] = "-native"
                        args[#args + 1] = "0"
                    end
                    if cdrive_ro then
                        args[#args + 1] = "-cro"
                        args[#args + 1] = "1"
                    end
                    if audio_pct ~= 100 then
                        args[#args + 1] = "-audio"
                        args[#args + 1] = tostring(audio_pct)
                    end
                    if sb_digital ~= 1 then
                        args[#args + 1] = "-sbdigi"
                        args[#args + 1] = tostring(sb_digital)
                    end
                    if pit_cap then
                        args[#args + 1] = "-pitcap"
                        args[#args + 1] = "1000"
                    end
                    -- Opt in to the firmware's ALT+Enter binding toggle,
                    -- starting in TYPING mode: DOS drops you at a command
                    -- prompt, and bound keys would hijack the letters you
                    -- need to type. Toggle on once the game is running.
                    args[#args + 1] = "-kbtoggle"
                    args[#args + 1] = "0"
                    local km = build_keymap_string()
                    if km then
                        args[#args + 1] = "-keymap"
                        args[#args + 1] = km
                    end
                    if mouse_speed > 0 then
                        -- Mouse mode: module reads raw deltas; no -trkball needed
                        args[#args + 1] = "-mouse"
                        args[#args + 1] = tostring(mouse_speed)
                        if click_latch then
                            args[#args + 1] = "-mlatch"
                            args[#args + 1] = "1"
                        end
                    else
                        -- Arrow-keys mode: trackball momentum drives 0x81-0x84
                        args[#args + 1] = "-trkball"
                        args[#args + 1] = build_trkball_string()
                    end
                    _launch_elf(table.unpack(args))
                end
            }
            end)
        end)

        local ctrlBtn = c:Button{ w = lvgl.PCT(48), h = 30 }
        ctrlBtn:Label{ text = "Controls", align = lvgl.ALIGN.CENTER }
        ctrlBtn:onClicked(function() create_controls_screen() end)

        local setBtn = c:Button{ w = lvgl.PCT(48), h = 30 }
        setBtn:Label{ text = "Settings", align = lvgl.ALIGN.CENTER }
        setBtn:onClicked(function() create_settings_screen() end)

        local quitBtn = c:Button{ w = lvgl.PCT(48), h = 30 }
        quitBtn:Label{ text = "Quit", align = lvgl.ALIGN.CENTER }
        quitBtn:onClicked(function() apps.go_home() end)

        -- Documents the firmware's quit chord
        local helpBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        helpBtn:Label{ text = "Quit help", align = lvgl.ALIGN.CENTER }
        helpBtn:onClicked(function() create_help_screen() end)

        local aboutBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
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
            text = "While the emulator is running, hold\n"
                 .. "ALT + Backspace for about 1.5 seconds\n"
                 .. "to quit back to the launcher.\n\n"
                 .. "Backspace on its own stays a normal\n"
                 .. "DOS key. Works in every game and\n"
                 .. "emulator, on the built-in and USB\n"
                 .. "keyboards.",
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
            text = "PC emulation by tiny386\n"
                 .. "(c) 2024-2025 Chunhui He\n"
                 .. "License: BSD 3-Clause\n"
                 .. "github.com/hchunhui/tiny386\n\n"
                 .. "Emulates a 386/486/586/686 PC with\n"
                 .. "an x87 FPU, VGA, IDE, PS/2 keyboard\n"
                 .. "and mouse, Adlib, Sound Blaster 16\n"
                 .. "and PC speaker.\n\n"
                 .. "Components:\n"
                 .. "Peripherals ported from QEMU and\n"
                 .. "  TinyEMU (MIT) - VGA and IDE by\n"
                 .. "  Fabrice Bellard\n"
                 .. "Adlib OPL2 via fmopl (LGPL)\n\n"
                 .. "Firmware:\n"
                 .. "SeaBIOS and SeaVGABIOS (LGPL v3)\n"
                 .. "  (c) SeaBIOS Developers\n"
                 .. "Both ship with this app - no\n"
                 .. "proprietary ROMs are used.\n\n"
                 .. "MS-DOS is a trademark of Microsoft.\n"
                 .. "No disk images or games are\n"
                 .. "included - supply your own. FreeDOS\n"
                 .. "is a freely licensed DOS.",
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
-- Settings screen
-- ============================================================
create_settings_screen = function()
    show_screen(function(c)
        heading(c, "SETTINGS", ACCENT)

        setting_row(c, "CPU class",
            function() return string.format("< %s >", CPU_NAMES[sel_cpu]) end,
            function()
                sel_cpu = sel_cpu + 1
                if sel_cpu > #CPU_GENS then sel_cpu = 1 end
            end,
            "cpu"
        )

        setting_row(c, "Text smoothing",
            function() return text_smooth and "< ON >" or "< OFF >" end,
            function() text_smooth = not text_smooth end,
            "smooth"
        )

        setting_row(c, "Render gate",
            function() return render_gate and "< ON >" or "< OFF >" end,
            function() render_gate = not render_gate end,
            "rgate"
        )

        setting_row(c, "Native res",
            function() return native_res and "< ON >" or "< OFF >" end,
            function() native_res = not native_res end,
            "native"
        )

        -- Folder C: is a read-write drive. This forces it read-only, which
        -- also makes DOS report the failure instead of silently losing writes.
        setting_row(c, "Folder C: writes",
            function() return cdrive_ro and "< OFF >" or "< ON >" end,
            function() cdrive_ro = not cdrive_ro end,
            "cwrites"
        )

        setting_row(c, "Audio rate",
            audio_label,
            function()
                local i = 1
                for k, v in ipairs(AUDIO_CHOICES) do
                    if v == audio_pct then i = k break end
                end
                audio_pct = AUDIO_CHOICES[(i % #AUDIO_CHOICES) + 1]
            end,
            "audio"
        )

        setting_row(c, "SB digital",
            function()
                if sb_digital == 3 then return "< NO DMA >" end
                if sb_digital == 2 then return "< NO IRQ >" end
                return sb_digital == 0 and "< OFF >" or "< ON >"
            end,
            function()
                if sb_digital == 1 then sb_digital = 3
                elseif sb_digital == 3 then sb_digital = 2
                elseif sb_digital == 2 then sb_digital = 0
                else sb_digital = 1 end
            end,
            "sbdigi"
        )

        setting_row(c, "Timer cap",
            function() return pit_cap and "< 1 kHz >" or "< OFF >" end,
            function() pit_cap = not pit_cap end,
            "pitcap"
        )

        setting_row(c, "Trackball",
            function()
                if mouse_speed == 0 then return "< Arrow keys >" end
                return string.format("< Mouse x%d >", mouse_speed)
            end,
            function()
                mouse_speed = mouse_speed + 1
                if mouse_speed > 5 then mouse_speed = 0 end
            end,
            "trkball"
        )

        setting_row(c, "Click latch",
            function() return click_latch and "< ON >" or "< OFF >" end,
            function() click_latch = not click_latch end,
            "mlatch"
        )

        local dlBtn = c:Button{ w = lvgl.PCT(100), h = 28 }
        dlBtn:Label{ text = "Download DOS disks", text_font = FONT,
                     align = lvgl.ALIGN.CENTER }
        dlBtn:onClicked(function() create_download_screen() end)

        local trkBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        trkBtn:Label{ text = "Trackball", text_font = FONT, align = lvgl.ALIGN.CENTER }
        trkBtn:onClicked(function() create_input_screen() end)

        local backBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        backBtn:Label{ text = "Back", text_font = FONT, align = lvgl.ALIGN.CENTER }
        backBtn:onClicked(function() create_main_screen() end)
    end)
end

-- ============================================================
-- Controls help screen
-- ============================================================
-- Numbers, symbols, F-keys and backslash are reached natively via the T-Deck
-- SYM and ALT modifiers (decoded in the firmware's ELF keyboard path + the
-- module's ascii_to_scan). This screen documents that scheme plus the
-- trackball mouse buttons (modules/dos/dos_input.c).
create_controls_screen = function()
    show_screen(function(c)
        heading(c, "CONTROLS", ACCENT)

        local function head(t)
            c:Label{ text = t, text_font = FONT, text_color = ACCENT,
                     w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT }
        end
        local function body(t)
            c:Label{ text = t, text_font = FONT, text_color = "#CCCCCC",
                     w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT }
        end

        head("Numbers & symbols")
        body("Hold SYM + key.  SYM+1 = 1, SYM+! = !")

        head("Function keys F1-F10")
        body("Hold ALT + a number key.\nALT+1 = F1  ...  ALT+0 = F10")

        head("Backslash  \\  (DOS paths)")
        body("ALT + / key (the G key).   e.g. cd \\dos")

        head("USB keyboard (Tools/USB host on)")
        body("Everything is native: arrows, F1-F12,\nCtrl, Alt, Home/End/PgUp/PgDn/Ins/Del,\nCapsLock. NumLock inert: keypad = digits,\narrow keys always navigate.")

        head("Mouse  (Settings -> Trackball -> Mouse)")
        body("Roll the trackball to move the pointer.\nNeeds a DOS mouse driver (e.g. CTMOUSE).\nIn Arrow keys mode the trackball sends\narrow keys instead and the buttons are off.")

        head("Mouse buttons")
        body("Click = left button; hold the ball\npressed to keep it held (drag).\nSHIFT + click = right button.")

        head("Click latch  (Settings, or ALT + click)")
        body("With Click latch ON, a click toggles the\nbutton held/released - drag windows and\nmenus without keeping the ball pressed\nwhile rolling it. ALT + click switches\nlatch mode while DOS runs.")

        head("Toggle feedback")
        body("The keyboard backlight blinks once each\ntime a toggle above changes state.")

        head("Key bindings on/off  (ALT + Enter)")
        body("DOS starts in TYPING mode so the prompt\nworks normally. ALT + Enter switches your\nbindings on for the game and off again\nwhenever you need to type.\nThe trackball is unaffected either way, so\nmouse + bound arrows work together.")

        head("Quit to launcher")
        body("Hold ALT + Backspace about 1.5 seconds.\nBackspace alone stays a normal DOS key.")

        local bindBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        bindBtn:Label{ text = "Bindings", text_font = FONT, align = lvgl.ALIGN.CENTER }
        bindBtn:onClicked(function() create_binds_screen() end)

        local trkBtn = c:Button{ w = lvgl.PCT(48), h = 28 }
        trkBtn:Label{ text = "Trackball", text_font = FONT, align = lvgl.ALIGN.CENTER }
        trkBtn:onClicked(function() create_input_screen() end)

        local backBtn = c:Button{ w = lvgl.PCT(100), h = 28 }
        backBtn:Label{ text = "Back", text_font = FONT, align = lvgl.ALIGN.CENTER }
        backBtn:onClicked(function() create_main_screen() end)
    end)
end

-- ============================================================
-- One help topic from HELP, shown as its own screen. Returns to Settings,
-- which is the only place these are reachable from.
-- ============================================================
create_help_topic = function(key)
    local entry = HELP[key]
    if not entry then return end
    show_screen(function(c)
        heading(c, entry[1], ACCENT)

        -- OK goes FIRST, and the body is its own scrollable focusable child.
        -- Two reasons, both learned from the Read Me app: gridnav focuses the
        -- first focusable and the view scrolls to it, so a button below long
        -- text opens the page scrolled past the beginning; and SCROLL_FIRST
        -- scrolls the FOCUSED CHILD, never the nav container, so text that is
        -- not itself focusable cannot be scrolled with the trackball at all.
        -- Roll down from OK to focus the text, then up/down scrolls it.
        local okBtn = c:Button{ w = lvgl.PCT(100), h = 28 }
        okBtn:Label{ text = "OK", text_font = FONT, align = lvgl.ALIGN.CENTER }
        okBtn:onClicked(function() create_settings_screen() end)

        local body = c:Object{ w = lvgl.PCT(100), h = H - 80, pad_all = 6 }
        body:Label{
            text = entry[2],
            text_font = FONT,
            text_color = "#CCCCCC",
            w = lvgl.PCT(100),
        }
    end)
end

-- ============================================================
-- Download DOS -- fetch the FreeDOS images we publish, to either drive.
-- The emulator is useless without a boot disk and we cannot ship one inside
-- the app (they are megabytes), so this is the on-ramp: pick a disk, pick a
-- drive, and it lands in a folder the launcher already scans.
-- ============================================================
-- Raw-file base for the images: same repo and branch the emoji extended set
-- comes from (Settings > Emoji), so there is one place to keep current.
local DOS_URL = "https://raw.githubusercontent.com/PhilMo6/meshpunk/launcher/freedos"

local DOS_DISKS = {
    { file = "freedos-a.img",    bytes = 1474560,
      label = "Boot floppy (A:)",
      desc  = "FreeDOS 1.4 + XMS + Sound Blaster,\nCTMOUSE, EDIT. Start here." },
    { file = "freedos-c.img",    bytes = 1548288,
      label = "Boot hard disk (C:)",
      desc  = "Same system, bootable as C: so the\nA: slot is free for game disks." },
    { file = "freedos-a-nb.img", bytes = 1474560,
      label = "Boot floppy, no BLASTER",
      desc  = "As above without SET BLASTER, for\ngames that misbehave with a card." },
    { file = "freedos-c-nb.img", bytes = 1548288,
      label = "Boot hard disk, no BLASTER",
      desc  = "Hard-disk version of the same." },
}

-- Free bytes on a drive, or nil when it is not available (no SD card).
local function drive_free(drv)
    local total, used = _fs_df(drv)
    if not total then return nil end
    return total - used
end

local function mb(n) return string.format("%.1f MB", n / 1048576) end

create_download_screen = function()
    show_screen(function(c)
        heading(c, "DOWNLOAD DOS", ACCENT)

        c:Label{
            text = "FreeDOS boot disks, downloaded over\nWiFi. Pick one:",
            text_font = FONT, text_color = "#CCCCCC",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        for _, d in ipairs(DOS_DISKS) do
            local btn = c:Button{ w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT }
            btn:Label{
                text = d.label .. "  (" .. mb(d.bytes) .. ")\n" .. d.desc,
                text_font = FONT, align = lvgl.ALIGN.CENTER,
            }
            btn:onClicked(function() create_dest_screen(d) end)
        end

        local backBtn = c:Button{ w = lvgl.PCT(100), h = 28 }
        backBtn:Label{ text = "Back", text_font = FONT, align = lvgl.ALIGN.CENTER }
        backBtn:onClicked(function() create_main_screen() end)
    end)
end

create_dest_screen = function(disk)
    show_screen(function(c)
        heading(c, disk.label, ACCENT)

        local status = c:Label{
            text = "Save where?  (" .. mb(disk.bytes) .. ")",
            text_font = FONT, text_color = "#CCCCCC",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        -- Both destinations are folders the launcher already scans, so a
        -- finished download shows up in the disk lists without any rescan
        -- bookkeeping here: internal lives beside the app, SD in /dos.
        local dests = {
            { drv = "L", dir = app_dir, name = "Internal" },
            { drv = "S", dir = "S:/dos", name = "SD card" },
        }

        local busy = false
        for _, dest in ipairs(dests) do
            local free = drive_free(dest.drv)
            local btn = c:Button{ w = lvgl.PCT(100), h = 30 }
            local lbl = btn:Label{
                text = dest.name .. (free and ("  -  " .. mb(free) .. " free")
                                          or "  -  not available"),
                text_font = FONT, align = lvgl.ALIGN.CENTER,
            }
            btn:onClicked(function()
                if busy then return end
                if not _wifi_download_file then
                    status:set{ text = "Firmware has no download support" }
                    return
                end
                if not free then
                    status:set{ text = dest.name .. " is not available." }
                    return
                end
                if free < disk.bytes + 65536 then
                    status:set{ text = "Not enough space on " .. dest.name .. "." }
                    return
                end
                busy = true
                status:set{ text = "Connecting to WiFi..." }
                downloader.wifi_wait(15000, function(ok)
                    if not ok then
                        busy = false
                        status:set{ text = "No WiFi. Check Settings > WiFi." }
                        return
                    end
                    status:set{ text = "Downloading " .. disk.file .. "..." }
                    -- One tick of breathing room so the label paints before
                    -- the synchronous download blocks the UI.
                    apps.add_timer{ period = 50, cb = function(t)
                        t:delete()
                        fileman.mkdir(dest.dir)
                        -- Stage as .part and only rename once the whole
                        -- image is there: the launcher scans these folders
                        -- for *.img, so a half-downloaded file would show up
                        -- as a bootable disk and fail deep inside SeaBIOS.
                        -- (Same discipline as the emoji extended set.)
                        local path = dest.dir .. "/" .. disk.file
                        local part = path .. ".part"
                        local res = _wifi_download_file(DOS_URL .. "/" .. disk.file, part)
                        pcall(_wifi_download_end)
                        busy = false
                        local st = (res and res.success) and fileman.stat(part) or nil
                        if not (res and res.success) then
                            pcall(fileman.remove, part)
                            status:set{ text = "Download failed: "
                                             .. ((res and res.error) or "unknown") }
                        elseif not st or st.size ~= disk.bytes then
                            pcall(fileman.remove, part)
                            status:set{ text = string.format(
                                "Bad download: got %s, expected %s",
                                st and mb(st.size) or "nothing", mb(disk.bytes)) }
                        elseif not fileman.rename(part, path) then
                            pcall(fileman.remove, part)
                            status:set{ text = "Could not save to " .. dest.name }
                        else
                            lbl:set{ text = dest.name .. "  -  saved" }
                            status:set{ text = "Saved to " .. path
                                             .. "\nRestart the app to use it." }
                        end
                    end }
                end)
            end)
        end

        local backBtn = c:Button{ w = lvgl.PCT(100), h = 28 }
        backBtn:Label{ text = "Back", text_font = FONT, align = lvgl.ALIGN.CENTER }
        backBtn:onClicked(function() create_download_screen() end)
    end)
end

-- ============================================================
-- Boot confirmation -- every setting the emulator will actually start with,
-- on one screen. The settings live across three screens (and the trackball
-- mode resets whenever the filesystem is reflashed), so this is the last
-- chance to see the real state before the module takes the device over.
-- ============================================================
create_confirm_screen = function(hda_choice, on_yes)
    show_screen(function(c)
        heading(c, "BOOT WITH THESE?", ACCENT)

        -- Buttons FIRST, list inside a focusable scrollable child -- the same
        -- shape as the help topics. Gridnav focuses the first focusable and
        -- scrolls to it, and SCROLL_FIRST only ever scrolls the focused child,
        -- so buttons under a long list would both open the page scrolled past
        -- the top and leave the list unscrollable by trackball.
        local yesBtn = c:Button{ w = lvgl.PCT(48), h = 30 }
        yesBtn:Label{ text = "Boot", text_font = FONT, align = lvgl.ALIGN.CENTER }
        yesBtn:onClicked(function() on_yes() end)

        local noBtn = c:Button{ w = lvgl.PCT(48), h = 30 }
        noBtn:Label{ text = "Cancel", text_font = FONT, align = lvgl.ALIGN.CENTER }
        noBtn:onClicked(function() create_main_screen() end)

        local list = c:Object{ w = lvgl.PCT(100), h = H - 80, pad_all = 6,
                               flex = { flex_direction = "row",
                                        flex_wrap = "wrap", row_gap = 2 } }

        local function row(label, value)
            list:Label{
                text = label .. ":  " .. value,
                text_font = FONT,
                text_color = "#CCCCCC",
                w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
            }
        end

        -- Both slots list every .img, so a hard-disk image in A: is an easy
        -- mistake; the floppy controller can only take the standard geometries
        -- and just leaves the drive empty otherwise. Say so here rather than
        -- letting the boot quietly skip it.
        local fda_name = (sel_fda > 1) and found_imgs[sel_fda - 1].name or "none"
        if sel_fda > 1 then
            local st = fileman.stat(found_imgs[sel_fda - 1].path)
            local FLOPPY = { [368640]=1, [737280]=1, [1228800]=1,
                             [1474560]=1, [2949120]=1 }
            if st and not FLOPPY[st.size] then
                fda_name = fda_name .. "  (not a floppy - C: image?)"
            end
        end
        row("A: floppy", fda_name)
        row("C: drive", hda_choice
                        and ((hda_choice.kind == "folder" and "[folder] " or "")
                             .. hda_choice.name)
                        or "none")
        row("CPU", CPU_NAMES[sel_cpu])
        row("Audio rate", (audio_pct == 0) and "OFF"
                          or (AUDIO_NAMES[audio_pct] or (audio_pct .. "%")))
        local sb = (sb_digital == 3) and "NO DMA"
                or (sb_digital == 2) and "NO IRQ"
                or (sb_digital == 0) and "OFF" or "ON"
        row("SB digital", sb)
        row("Timer cap", pit_cap and "1 kHz" or "OFF")
        -- The one that bites most often: a flash resets it to Arrow keys and
        -- a mouse game then has no pointer at all.
        row("Trackball", (mouse_speed == 0) and "Arrow keys"
                         or string.format("Mouse x%d", mouse_speed))
        if mouse_speed > 0 then
            row("Click latch", click_latch and "ON" or "OFF")
        end
        local nbind = 0
        for _, a in ipairs(ACTIONS) do
            local b = bindings[a.id]
            if b and (b.key1 or b.key2) then nbind = nbind + 1 end
        end
        row("Key bindings", (nbind == 0) and "none"
                            or (nbind .. " bound (ALT+Enter)"))
        row("Folder C: writes", cdrive_ro and "OFF (read-only)" or "ON")
        if not (text_smooth and render_gate and native_res) then
            row("Video", (text_smooth and "" or "no-smooth ")
                      .. (render_gate and "" or "no-gate ")
                      .. (native_res and "" or "no-native"))
        end
    end)
end

-- ============================================================
-- Key binding list screen -- one row per action, two key slots.
-- The only entry into create_bind_screen; a key assigned here STEALS the
-- key from typing (the -keymap remap replaces its output).
-- ============================================================
create_binds_screen = function()
    show_screen(function(c)
        heading(c, "KEY BINDINGS", ACCENT)

        c:Label{
            text = "Bind T-Deck keys to PC keys a game\n"
                 .. "needs. A bound key replaces its normal\n"
                 .. "typing. Primary / Alt are two\n"
                 .. "alternative keys for the same action.",
            text_font = FONT,
            text_color = "#CCCCCC",
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        for i, a in ipairs(ACTIONS) do
            local b = bindings[a.id]
            c:Label{
                text = a.label,
                text_font = FONT,
                text_color = "#CCCCCC",
                w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
            }
            local b1 = c:Button{ w = lvgl.PCT(48), h = 24 }
            b1:Label{ text = key_display(b.key1), text_font = FONT,
                      align = lvgl.ALIGN.CENTER }
            b1:onClicked(function() create_bind_screen(i, 1) end)
            local b2 = c:Button{ w = lvgl.PCT(48), h = 24 }
            b2:Label{ text = key_display(b.key2), text_font = FONT,
                      align = lvgl.ALIGN.CENTER }
            b2:onClicked(function() create_bind_screen(i, 2) end)
        end

        local backBtn = c:Button{ w = lvgl.PCT(100), h = 26 }
        backBtn:Label{ text = "Back", text_font = FONT, align = lvgl.ALIGN.CENTER }
        backBtn:onClicked(function() create_controls_screen() end)
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
        heading(c, a.label .. " - " .. slot_name, ACCENT)

        local current = (slot == 1) and b.key1 or b.key2

        local clrBtn = c:Button{ w = lvgl.PCT(100), h = 24 }
        clrBtn:Label{ text = "--- (clear)", text_font = FONT, align = lvgl.ALIGN.CENTER }
        clrBtn:onClicked(function()
            if slot == 1 then b.key1 = nil else b.key2 = nil end
            save_config()
            create_binds_screen()
        end)

        for _, k in ipairs(BINDABLE_KEYS) do
            local btn = c:Button{ w = lvgl.PCT(48), h = 24 }
            local lbl = k.name
            if k.code == current then lbl = "> " .. lbl .. " <" end
            btn:Label{ text = lbl, text_font = FONT, align = lvgl.ALIGN.CENTER }
            btn:onClicked(function()
                -- The firmware keymap holds ONE output per physical key, so a
                -- key bound in two places silently loses one of them. Strip
                -- the key from every other slot before assigning it here.
                for _, o in ipairs(ACTIONS) do
                    local ob = bindings[o.id]
                    if ob.key1 == k.code then ob.key1 = nil end
                    if ob.key2 == k.code then ob.key2 = nil end
                end
                if slot == 1 then b.key1 = k.code else b.key2 = k.code end
                save_config()
                create_binds_screen()
            end)
        end

        local cancelBtn = c:Button{ w = lvgl.PCT(100), h = 26 }
        cancelBtn:Label{ text = "Cancel", text_font = FONT, align = lvgl.ALIGN.CENTER }
        cancelBtn:onClicked(function() create_binds_screen() end)
    end)
end

-- ============================================================
-- Input settings screen (trackball tuning for arrow-keys mode)
-- ============================================================
create_input_screen = function()
    show_screen(function(c)
        heading(c, "INPUT SETTINGS", ACCENT)

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
            text = "These apply in Arrow-keys trackball mode\n"
                 .. "(Settings -> Trackball -> Arrow keys).",
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
-- Startup
-- ============================================================
load_defaults()
local init_phase = 0
return function()
    init_phase = init_phase + 1

    if init_phase == 1 then
        scan_dir_for_imgs(app_dir)
        return false
    elseif init_phase == 2 then
        scan_dir_for_imgs(sd_app_dir)
        scan_dir_for_folders(sd_app_dir)
        return false
    elseif init_phase == 3 then
        if sd_app_dir ~= "S:/dos" then
            scan_dir_for_imgs("S:/dos")
            scan_dir_for_folders("S:/dos")
        end
        return false
    end

    table.sort(found_imgs, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    table.sort(found_folders, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    for _, r in ipairs(found_imgs) do
        hda_choices[#hda_choices + 1] = { kind = "img", name = r.name, path = r.path }
    end
    for _, r in ipairs(found_folders) do
        hda_choices[#hda_choices + 1] = { kind = "folder", name = r.name, path = r.path }
    end
    load_config()
    -- Restore selections by name
    if sel_fda_name then
        for i, r in ipairs(found_imgs) do
            if r.name == sel_fda_name then sel_fda = i + 1; break end
        end
    end
    if sel_hda_name or sel_hda_folder_name then
        for i, ch in ipairs(hda_choices) do
            if (ch.kind == "img" and ch.name == sel_hda_name)
                or (ch.kind == "folder" and ch.name == sel_hda_folder_name) then
                sel_hda = i + 1
                break
            end
        end
    end
    create_main_screen()
    return true
end

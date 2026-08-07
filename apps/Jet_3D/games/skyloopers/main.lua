-- SKYLOOPERS hover race (up to six ships, six distinct classes) on a
-- randomly generated floating circuit. Kart rules: weapon pickups, boost
-- pads, walled corridors and open cliff-edge sections, 3 laps,
-- checkpoint respawns.
--
-- Everything the renderer is best at and nothing it is not: flat colours,
-- span fill, the whole scene near. The track is analytic (radius/height/
-- walls are functions of the loop angle), so physics, AI steering, homing
-- weapons and wall collision never touch a mesh.
--
-- Items: ZAP (hits the nearest racer AHEAD) · MINE · BOOST ·
--        ROCKET (always hits the race leader) · SHIELD (brief immunity).
--
-- Controls are ACTIONS (see ACT below), bound to physical keys on the
-- launcher's Controls screen: Thrust/Up = accelerate · Left/Right +
-- trackball = steer · Down = use item · Thrust/click = menu select ·
-- Pause = pause / back · Restart = new race · Quit = firmware-handled.

-- ---------------------------------------------------------------------------
-- Track shape + race customization (RACE SETUP menu)
-- ---------------------------------------------------------------------------
-- Track-shape rows need a rebuild: leaving the setup screen with changes
-- applies them with full NEW TRACK semantics. Station SPACING is fixed
-- (see SEGLEN): longer tracks add STATIONS and the loop radius derives
-- from the count, so every constant tuned in station units (corners,
-- crossing windows, tessellation, AI braking) survives any length.
local CFG_LEN   = { { "SHORT", 192 }, { "NORMAL", 256 },
                    { "LONG", 384 }, { "EPIC", 768 } }
local CFG_WIDTH = { { "NARROW", 20000 }, { "NORMAL", 26000 },
                    { "WIDE", 34000 } }
-- ALL (100%) = a fully enclosed circuit: no cliff edges anywhere, so no
-- falls and no rim glow, but wall ribbons run the whole lap (the heaviest
-- triangle count of any setting).
local CFG_WALLS = { { "NONE", 0 }, { "LIGHT", 30 },
                    { "NORMAL", 60 }, { "HEAVY", 85 }, { "ALL", 100 } }
local CFG_PADS  = { { "NONE", 0 }, { "FEW", 16 },
                    { "NORMAL", 8 }, { "MANY", 4 } }
local CFG_ITEMS = { { "NONE", 0 }, { "FEW", 8 },
                    { "NORMAL", 4 }, { "MANY", 2 } }
-- Boxes per item row, at the fixed lane spacing; the whole row sits at a
-- random lateral offset (see buildBoxes). Fewer boxes makes rows
-- contested: a box that has been grabbed is gone for its 4s respawn, so
-- trailing racers arrive at picked-over rows and at 1 per row the
-- single box can sit anywhere across the width.
local CFG_NBOX  = { { "1", 1 }, { "2", 2 }, { "3", 3 }, { "4", 4 },
                    { "5", 5 } }
local raceCfg = { npcs = 2, len = 2, width = 2, walls = 3, pads = 3,
                  items = 3, nbox = 3 }

local R        = 420000        -- derived from length (see applyRaceCfg)
local HALFW    = 26000         -- deck half-width, the WIDTH option
local EDGEW    = 1600
local WALLH    = 3200          -- corridor wall height
local STATIONS = 256           -- the LENGTH option
local BAND     = 4
-- Respawn checkpoints, one per 32 stations (= one per sector) rather than a
-- fixed 8: with a fixed count a long track's checkpoints spread out with
-- it, so an EPIC lap would send a fall back up to 64 stations. Derived in
-- applyRaceCfg; 8 at NORMAL, exactly as tuned.
local CPS      = 8
-- Sector LOD switch (see updateSectorLOD): past LOD_OUT (xz distance from
-- the camera to the sector's station centroid) the detail object swaps for
-- its coarse twin; back under LOD_IN it swaps back. BOTH members of the
-- pair switch on the ONE shared centroid the engine's own fade/appear
-- measures each object's OWN mesh centre, which differ between the pair,
-- so near the threshold one vanishes before the other appears and the
-- sector blinks. The 40k dead band keeps a ship riding the threshold from
-- toggling the pair every frame. Squared floats: these overflow the
-- 32-bit Lua integer, so keep the .0 on the literals.
local LOD_OUT2 = 470000.0 * 470000.0
local LOD_IN2  = 430000.0 * 430000.0
local BOX_FAR  = 300000        -- item boxes vanish beyond this (subpixel)

local TWO_PI = 6.28318530718

-- Station spacing is FIXED at the original tuning (2*pi*420000/256): the
-- LENGTH option changes STATIONS, and R derives from it, never the spacing.
local SEGLEN = TWO_PI * 420000 / 256

-- ---------------------------------------------------------------------------
-- Track generator a TURTLE, not a radius function.
--
-- The old r(theta) form could only make a wobbly circle: curvature never
-- meaningfully changed sign or magnitude, so every lap was "hold left and
-- thrust". Here the track is a SEGMENT RECIPE straights, sweepers,
-- hairpins, chicanes turned into a per-station curvature list and
-- integrated station by station. Closure is exact by construction:
--   * heading: the curvature sum is corrected to exactly +-2*pi by adding
--     the remainder evenly to every station (well under a degree each an
--     imperceptible bend on the straights);
--   * position: the leftover endpoint gap is spread linearly around the
--     loop, then the loop is recentred on the origin.
-- Every station stores centre, walled flag, and (in buildTrack) the lane
-- normal. ALL queries downstream are station-space.
-- ---------------------------------------------------------------------------
local stC, stN, stWalled = {}, {}, {}
local stK = {}                 -- |curvature| per station, for AI braking
local seed

local function wrapAngle(a)
    while a >  3.14159265 do a = a - TWO_PI end
    while a < -3.14159265 do a = a + TWO_PI end
    return a
end

local function wrapSt(d)
    if d > STATIONS / 2 then return d - STATIONS end
    if d < -STATIONS / 2 then return d + STATIONS end
    return d
end

-- Sharpest corner: 42,000 minimum turn radius (hardware-tuned at HALFW
-- 26000). Half-width beyond 26000 adds 4x its excess to the radius, so
-- wider decks get gentler corners; narrow/normal keep the tuned value.
local KMAX = SEGLEN / 42000

-- Apply the RACE SETUP shape options to the generator variables.
local function applyRaceCfg()
    STATIONS = CFG_LEN[raceCfg.len][2]
    R        = math.floor(SEGLEN * STATIONS / TWO_PI)
    HALFW    = CFG_WIDTH[raceCfg.width][2]
    CPS      = STATIONS // 32
    KMAX     = SEGLEN / (42000 + 4 * math.max(0, HALFW - 26000))
end

local function rollTrack()
    -- Device-uptime ticks, NOT jet.timer.time(): time() starts at zero when
    -- the module loads, so the boot race always rolled the same seed.
    seed = jet.timer.ticks() % 1000000
    math.randomseed(seed)

    local wallPct = CFG_WALLS[raceCfg.walls][2]
    -- Roll until the lap is self-consistent, then apply crossings once.
    -- Chained same-direction tight segments can curl a corner past ~300
    -- degrees so the exit leg overlaps the entry leg and index
    -- separations under 28 are deliberately EXEMPT from crossing
    -- enforcement (hairpin legs live there), so nothing downstream can
    -- rescue such a roll. Rerolling keeps the recipe's character instead
    -- of capping curvature globally.
    local rerolls = 0
    for _ = 1, 24 do

    -- Per-station curvature + walled flag from a random segment recipe.
    local dir = (math.random(2) == 1) and 1 or -1
    local ks, wall = {}, {}
    local n = 0
    local function seg(len, k, w)
        for _ = 1, len do
            if n >= STATIONS then return end
            n = n + 1; ks[n] = k; wall[n] = w
        end
    end
    while n < STATIONS - 26 do
        local roll = math.random(100)
        if roll <= 30 then                              -- straight
            seg(math.random(14, 26), 0, math.random(100) <= wallPct)
        elseif roll <= 58 then                          -- sweeper, loop dir
            seg(math.random(12, 22),
                dir * (0.35 + math.random() * 0.40) * KMAX,
                math.random(100) <= wallPct)
        elseif roll <= 74 then                          -- counter-sweeper
            seg(math.random(8, 14),
                -dir * (0.30 + math.random() * 0.30) * KMAX,
                math.random(100) <= wallPct)
        elseif roll <= 90 then                          -- hairpin: walled
            seg(math.random(12, 16),
                dir * (0.85 + math.random() * 0.15) * KMAX, wallPct > 0)
        else                                            -- chicane
            local w = math.random(100) <= wallPct
            local kk = (0.55 + math.random() * 0.30) * KMAX
            seg(math.random(5, 7),  dir * kk, w)
            seg(math.random(5, 7), -dir * kk, w)
        end
    end
    seg(STATIONS - n, 0, math.random(100) <= wallPct)   -- closing straight

    -- Exact heading closure: spread the curvature remainder evenly.
    local S = 0
    for i = 1, STATIONS do S = S + ks[i] end
    local corr = (dir * TWO_PI - S) / STATIONS
    for i = 1, STATIONS do ks[i] = ks[i] + corr end

    -- Elevation: smooth hills from a few harmonics over the lap.
    local YH = {}
    for k = 1, 3 do
        YH[k] = { amp = (0.35 + math.random() * 0.65) * 16000 / k,
                  ph  = math.random() * TWO_PI }
    end

    -- Integrate the turtle.
    local h, x, z = 0, 0, 0
    for i = 0, STATIONS - 1 do
        local y = 0
        for k, hh in ipairs(YH) do
            y = y + hh.amp * math.sin(k * TWO_PI * i / STATIONS + hh.ph)
        end
        stC[i] = { x = x, y = y, z = z }
        stWalled[i] = wall[i + 1]
        stK[i] = math.abs(ks[i + 1])
        x = x + math.sin(h) * SEGLEN
        z = z + math.cos(h) * SEGLEN
        h = h + ks[i + 1]
    end

    -- Position closure + recentre.
    local gx, gz = x - stC[0].x, z - stC[0].z
    local mx, mz = 0, 0
    for i = 0, STATIONS - 1 do
        stC[i].x = stC[i].x - gx * (i / STATIONS)
        stC[i].z = stC[i].z - gz * (i / STATIONS)
        mx = mx + stC[i].x; mz = mz + stC[i].z
    end
    mx, mz = mx / STATIONS, mz / STATIONS
    for i = 0, STATIONS - 1 do
        stC[i].x = stC[i].x - mx
        stC[i].z = stC[i].z - mz
    end

    -- Self-overlap check over the index range the crossing system exempts
    -- (8..27; under 8 is just the track being continuous). Two stations
    -- that close in XZ with decks 2 x HALFW wide means the corner folded
    -- onto itself reroll. Float product (32-bit int literals wrap).
    local okRoll = true
    local LIM    = 2.0 * HALFW + 4000     -- float: squared below
    local LIMIT2 = LIM * LIM
    for i = 0, STATIONS - 1 do
        for d = 8, 27 do
            local a, b = stC[i], stC[(i + d) % STATIONS]
            local ddx, ddz = a.x - b.x, a.z - b.z
            if ddx * ddx + ddz * ddz < LIMIT2 then okRoll = false; break end
        end
        if not okRoll then break end
    end
    if okRoll then break end
    rerolls = rerolls + 1

    end -- reroll loop
    if rerolls > 0 then
        jet.log(string.format("[kart] track rerolled %d time(s) (corner"
                              .. " self-overlap)", rerolls))
    end

    -- Over/under crossings never flat crossroads. Wherever two sections
    -- far apart ALONG the track come close in XZ, force at least VGAP of
    -- vertical separation with smooth cosine ramps (~9% peak grade worst
    -- case; the hover tracking follows the station lerp directly, so grade
    -- only affects pitch feel). Ships stay on their own branch
    -- automatically: the nearest-station tracker only searches +-8
    -- around its cached index, and the other branch is far away in INDEX
    -- space. Long parallel near-passes become elevated parallel sections
    -- the same mechanism, chained.
    --
    -- The 28-station index floor keeps hairpins and chicanes (whose own
    -- legs sit ~12-16 stations apart) from being read as crossings.
    -- NEED2 MUST be a float product: a world-scale square as an INTEGER
    -- wraps negative on this 32-bit Lua build, and `dist2 < NEED*NEED`
    -- then never fires the whole crossing system silently does nothing.
    local NEED    = 2.0 * HALFW + 10000   -- float: squared below
    local NEED2   = NEED * NEED
    -- VGAP 24000 (~48 m at 500 units/m): 2.6x the ship+camera stack
    -- (hover 900 + camera boom 8200). W sized with it: worst-case
    -- half-push 12000 over +-20 stations = ~9% peak grade.
    local VGAP, W = 24000, 20
    -- Enforcement is PER PAIR, not per merged event centre: the closest
    -- approach of two branches is often stations away from where a single
    -- centred bump peaks, and the cosine falloff there left only ~65% of
    -- the push. Every close pair is measured and corrected in place;
    -- overlapping windows self-limit because later pairs re-measure the
    -- already-lifted stations. Repeat until a full scan finds nothing to
    -- fix (typically 1-2 passes; capped, with a warning if ever hit).
    -- Candidate pairs come from an XZ grid, not an all-pairs sweep: at EPIC
    -- length the O(STATIONS^2) scan (x6 passes, plus the audit below) was
    -- the whole cost of a rebuild. Everything past this point moves only
    -- stC.y x and z are final so ONE grid stays valid for every pass
    -- AND the audit scan. Cell = NEED means a station's own cell plus its 8
    -- neighbours contain every station within NEED of it, so the pair set
    -- is exactly the same one the sweep found.
    local CELL  = NEED
    local bins  = {}
    local function cellOf(i)
        local c = stC[i]
        return math.floor(c.x / CELL), math.floor(c.z / CELL)
    end
    for i = 0, STATIONS - 1 do
        local cx, cz = cellOf(i)
        local k = (cx + 2048) * 8192 + (cz + 2048)
        local t = bins[k]
        if t then t[#t + 1] = i else bins[k] = { i } end
    end
    -- Fills `out` with the stations in the 3x3 cell block around i and
    -- returns the count (out is reused across calls; the count bounds it).
    local function candidates(i, out)
        local cx, cz = cellOf(i)
        local n = 0
        for ox = -1, 1 do
            for oz = -1, 1 do
                local t = bins[(cx + ox + 2048) * 8192 + (cz + oz + 2048)]
                if t then
                    for m = 1, #t do n = n + 1; out[n] = t[m] end
                end
            end
        end
        return n
    end

    local pushes, passes = 0, 0
    local cand = {}
    for pass = 1, 6 do
        passes = pass
        local dirty = false
        for i = 0, STATIONS - 1 do
            local nc = candidates(i, cand)
            for c = 1, nc do
                local j = cand[c]
                -- j > i visits each unordered pair once; the index-space
                -- floor keeps hairpin legs out (see the 28-station note).
                local sep = (j > i) and math.min(j - i, STATIONS - (j - i))
                              or -1
                if sep >= 28 then
                    local a, b = stC[i], stC[j]
                    local dx, dz = a.x - b.x, a.z - b.z
                    if dx * dx + dz * dz < NEED2 then
                        local dy = a.y - b.y
                        local need = VGAP - math.abs(dy)
                        if need > 0 then
                            dirty = true
                            pushes = pushes + 1
                            local sgn = (dy >= 0) and 1 or -1
                            local half = need * 0.5
                            for k = -W, W do
                                local w = 0.5 * (1 + math.cos(
                                              3.14159265 * k / (W + 1)))
                                local ii = (i + k) % STATIONS
                                local jj = (j + k) % STATIONS
                                stC[ii].y = stC[ii].y + sgn * half * w
                                stC[jj].y = stC[jj].y - sgn * half * w
                            end
                        end
                    end
                end
            end
        end
        if not dirty then break end
    end
    -- Audit scan: the worst clearance actually left between close branches.
    -- Prints every roll so a regression can never hide.
    local worst = math.huge
    for i = 0, STATIONS - 1 do
        local nc = candidates(i, cand)
        for c = 1, nc do
            local j = cand[c]
            local sep = (j > i) and math.min(j - i, STATIONS - (j - i)) or -1
            if sep >= 28 then
                local a, b = stC[i], stC[j]
                local dx, dz = a.x - b.x, a.z - b.z
                if dx * dx + dz * dz < NEED2 then
                    local dy = math.abs(a.y - b.y)
                    if dy < worst then worst = dy end
                end
            end
        end
    end
    if worst < math.huge then
        jet.log(string.format(
            "[kart] crossings: %d pushes, %d passes, worst clearance %d",
            pushes, passes, math.floor(worst)))
        if worst < VGAP - 500 then
            jet.log("[kart] WARNING: crossing clearance UNRESOLVED")
        end
    else
        jet.log("[kart] crossings: none on this track")
    end
end

-- Point on the centreline at a float station index (lerp).
local function stationAt(fi)
    local i = math.floor(fi) % STATIONS
    local j = (i + 1) % STATIONS
    local f = fi - math.floor(fi)
    local a, b = stC[i], stC[j]
    return a.x + (b.x - a.x) * f,
           a.y + (b.y - a.y) * f,
           a.z + (b.z - a.z) * f
end

-- Tangent heading at a station, oriented along increasing station index.
local function stationHeading(i)
    i = i % STATIONS
    local j = (i + 1) % STATIONS
    return math.atan(stC[j].x - stC[i].x, stC[j].z - stC[i].z)
end

-- Nearest-station tracker: walks +-8 from the racer's cached index O(1)
-- per frame (max travel per frame is ~3 stations at boost speed). Returns
-- station index, lateral offset (signed, along the lane normal) and the
-- longitudinal fraction toward the next station. Teleports (spawn/respawn)
-- must reset rc.stIdx themselves.
local function trackQuery(rc)
    local best, bestD2 = rc.stIdx, math.huge
    for o = -8, 8 do
        local i = (rc.stIdx + o) % STATIONS
        local c = stC[i]
        local dx, dz = rc.px - c.x, rc.pz - c.z
        local d2 = dx * dx + dz * dz
        if d2 < bestD2 then best, bestD2 = i, d2 end
    end
    rc.stIdx = best
    local c, nv = stC[best], stN[best]
    local lat = (rc.px - c.x) * nv.x + (rc.pz - c.z) * nv.z
    local j = (best + 1) % STATIONS
    local tx, tz = stC[j].x - c.x, stC[j].z - c.z
    local f = ((rc.px - c.x) * tx + (rc.pz - c.z) * tz) / (tx * tx + tz * tz)
    if f < -0.5 then f = -0.5 elseif f > 1.0 then f = 1.0 end
    return best, lat, f
end

-- Boost-pad and item-box bands, by band index (STATIONS/BAND bands total).
-- Item rows every 4th band: weapons should be nearly always in hand the
-- game is combat-first. (2 mod 4 never collides with 5 mod 8.)
-- Cadence from RACE SETUP: one band in m (m = 0 disables). Distinct
-- phases (m-1 vs m//2) keep pads and item rows off the same band even
-- when the two moduli match.
local function isPadBand(bi)
    local m = CFG_PADS[raceCfg.pads][2]
    return m > 0 and bi % m == m - 1
end
local function isItemBand(bi)
    local m = CFG_ITEMS[raceCfg.items][2]
    return m > 0 and bi % m == m // 2
end

-- Pads are STRIPS, not full-width bands: centred at a position that cycles
-- centre/left/right from pad to pad, so hitting one is a line choice. The
-- mesh and the trigger both come from padCentre()/padHalf(). Pad edges land
-- EXACTLY on the deck's uniform lateral cut lines (see CUTS in buildTrack):
-- centre pad spans -7k..7k, side pads 7k..19k / -19k..-7k which is why
-- the centre one is 7k-half and the sides 6k-half.
local function padCentre(bi)
    local m = CFG_PADS[raceCfg.pads][2]
    if m == 0 then return 0 end
    local k = math.floor((bi - (m - 1)) / m)
    return ({ 0, -0.5, 0.5 })[(k % 3) + 1] * HALFW
end
-- Halves derived from the SAME fractions as the deck cut lines (0.27 /
-- 0.73 of HALFW), so pad edges land exactly on cuts at ANY track width.
local function padHalf(bi)
    return (padCentre(bi) == 0) and math.floor(HALFW * 0.27)
                                 or math.floor(HALFW * 0.23)
end

-- ---------------------------------------------------------------------------
-- Materials
-- ---------------------------------------------------------------------------
local matDeckA = jet.material{ color = jet.rgb( 62,  66,  84), shading = jet.FLAT }
local matDeckB = jet.material{ color = jet.rgb( 82,  86, 106), shading = jet.FLAT }
-- Far-twin deck: the average of the A/B check tones, so the coarse strip
-- reads as the same surface once the checkering is subpixel anyway.
local matDeckF = jet.material{ color = jet.rgb( 72,  76,  95), shading = jet.FLAT }
local matStart = jet.material{ color = jet.rgb(235, 235, 235), shading = jet.FLAT }
local matPad   = jet.material{ color = jet.rgb(255, 150,  40), shading = jet.UNLIT,
                               emissive = true }
local matEdge  = jet.material{ color = jet.rgb( 90, 225, 255), shading = jet.UNLIT,
                               emissive = true }
local matWall  = jet.material{ color = jet.rgb(110, 116, 140), shading = jet.UNLIT,
                               emissive = true }
local matBox   = jet.material{ color = jet.rgb(220,  90, 235), shading = jet.UNLIT,
                               emissive = true }
local matZap   = jet.material{ color = jet.rgb( 90, 255, 110), shading = jet.UNLIT,
                               emissive = true }
local matRkt   = jet.material{ color = jet.rgb(255, 230,  80), shading = jet.UNLIT,
                               emissive = true }
local matShld  = jet.material{ color = jet.rgb(150, 240, 255), shading = jet.UNLIT,
                               emissive = true }
local matMine  = jet.material{ color = jet.rgb(255,  70,  60), shading = jet.UNLIT,
                               emissive = true }
local matDark  = jet.material{ color = jet.rgb( 40,  44,  54), shading = jet.FLAT }
local matTrim  = jet.material{ color = jet.rgb(225, 218, 205), shading = jet.FLAT }
-- Engine flame: the same energy blue as matEdge, so thrust reads as the
-- track's own glow rather than combustion.
local matFlame = jet.material{ color = jet.rgb( 90, 225, 255), shading = jet.UNLIT,
                               emissive = true }
-- Ship classes. Stat semantics: top = cruise speed ceiling (per-racer
-- drag pins the thrust equilibrium at (ACCEL/DRAG)*top see dragK),
-- accel = how fast speed converges to that ceiling (spool-up, corner-exit
-- and post-spin recovery), turn = steering rate AND cornering grip (see
-- CORNER_SCRUB), mass = who moves whom in a bump. Racers always carry
-- DISTINCT classes, so colour identifies class, not driver.
local SHIP_TYPES = {
    { name = "VIPER", accel = 1.00, top = 1.00, turn = 1.00, mass = 1.0,
      mat = jet.material{ color = jet.rgb(205,  70,  55), shading = jet.FLAT } },
    { name = "BRICK", accel = 0.85, top = 1.06, turn = 0.85, mass = 1.6,
      mat = jet.material{ color = jet.rgb( 66, 120, 225), shading = jet.FLAT } },
    { name = "WASP",  accel = 1.10, top = 0.94, turn = 1.30, mass = 0.7,
      mat = jet.material{ color = jet.rgb( 70, 200, 110), shading = jet.FLAT } },
    { name = "COMET", accel = 0.92, top = 1.10, turn = 0.78, mass = 1.1,
      mat = jet.material{ color = jet.rgb(235, 188,  60), shading = jet.FLAT } },
    { name = "JOLT",  accel = 1.30, top = 0.96, turn = 1.10, mass = 0.85,
      mat = jet.material{ color = jet.rgb(150,  92, 225), shading = jet.FLAT } },
    { name = "GHOST", accel = 1.05, top = 1.00, turn = 1.18, mass = 0.6,
      mat = jet.material{ color = jet.rgb(200, 220, 235), shading = jet.FLAT } },
}

-- ---------------------------------------------------------------------------
-- Track build four quadrant objects, cull-grouped
-- ---------------------------------------------------------------------------
local trackObjs = {}
local twinObjs  = {}   -- coarse far-LOD twin per sector
local sectorLOD = {}   -- { x, z, d = detail, t = twin, far } per sector

local function buildTrack()
    -- rollTrack() has already filled stC/stWalled; derive the lane normals.
    for i = 0, STATIONS - 1 do
        local a = stC[(i - 1) % STATIONS]
        local b = stC[(i + 1) % STATIONS]
        local tx, tz = b.x - a.x, b.z - a.z
        local l = math.sqrt(tx * tx + tz * tz)
        stN[i] = { x = -tz / l, z = tx / l }
    end
    local function edge(i, off, lift)
        local c, n = stC[i % STATIONS], stN[i % STATIONS]
        return c.x + n.x * off, c.y + (lift or 0), c.z + n.z * off
    end

    -- Adaptive cross-rows. ONE shared keep-set for EVERY ribbon deck
    -- strips, rims, walls so all seams carry exactly matching vertices;
    -- per-strip decimation would put sub-pixel T-junction gaps (white
    -- dots) along the cut lines. Always kept: band boundaries
    -- (checker/pad/start materials change there) and wall/rim zone
    -- transitions (ribbon runs start and end there). Interior rows survive
    -- only where dropping them would deviate the mesh from the true path:
    -- XZ chord error over TESS_XZ, or ride-height error over TESS_Y (the
    -- hover follows stC, not the mesh a sagging deck reads as the ship
    -- floating). Straights collapse to one quad per strip per band; gentle
    -- sweepers keep the middle row; tight corners keep every row.
    local TESS_XZ, TESS_Y = 1800.0, 350.0
    local keepRow = {}
    for i = 0, STATIONS - 1 do keepRow[i] = (i % BAND == 0) end
    for i = 0, STATIONS - 1 do
        if stWalled[i] ~= stWalled[(i - 1) % STATIONS] then
            for k = -2, 1 do keepRow[(i + k) % STATIONS] = true end
        end
    end
    local function spanErr(k0, k1)
        local a, b = stC[k0 % STATIONS], stC[k1 % STATIONS]
        local abx, abz, aby = b.x - a.x, b.z - a.z, b.y - a.y
        local len = math.sqrt(abx * abx + abz * abz)
        if len < 1 then return 0 end
        local worst = 0
        for m = k0 + 1, k1 - 1 do
            local c = stC[m % STATIONS]
            local exz = math.abs(abx * (c.z - a.z) - abz * (c.x - a.x)) / len
            local t = (m - k0) / (k1 - k0)
            local ey = math.abs(a.y + aby * t - c.y) * (TESS_XZ / TESS_Y)
            if exz > worst then worst = exz end
            if ey > worst then worst = ey end
        end
        return worst
    end
    for s = 0, STATIONS - 1, BAND do
        local half = BAND // 2
        if spanErr(s, s + BAND) < TESS_XZ then
            -- single span carries the whole band
        elseif spanErr(s, s + half) < TESS_XZ
           and spanErr(s + half, s + BAND) < TESS_XZ then
            keepRow[(s + half) % STATIONS] = true
        else
            for k = 1, BAND - 1 do keepRow[(s + k) % STATIONS] = true end
        end
    end

    -- One builder per sector of 32 stations: on a twisty track a coarse
    -- chunk's bounding box can span most of the view, so finer sectors cull
    -- much tighter. Each sector is also a cull-group anchor (see
    -- buildGroups) that gates its item boxes with it.
    local perQ    = 32                 -- stations per sector, fixed
    local sectors = STATIONS // perQ
    for q = 0, sectors - 1 do
        local b = jet.builder()
        local s0, s1 = q * perQ, (q + 1) * perQ

        -- One deck strip between lateral offsets o1..o2 over stations
        -- s..s+BAND (shared boundary stations, exact edges).
        local function deckStrip(s, o1, o2, m)
            local pts = {}
            for i = s, s + BAND do
                -- s and s+BAND are band boundaries, always in the keep-set.
                if keepRow[i % STATIONS] then
                    local ax, ay, az = edge(i, o1)
                    local bx2, by2, bz2 = edge(i, o2)
                    pts[#pts + 1] = ax;  pts[#pts + 1] = ay;  pts[#pts + 1] = az
                    pts[#pts + 1] = bx2; pts[#pts + 1] = by2; pts[#pts + 1] = bz2
                end
            end
            b:ribbon(pts, m)
        end

        -- UNIFORM lateral cuts on EVERY band: a lattice whose cross-section
        -- is subdivided identically everywhere has no T-junctions at all,
        -- and a T-junction here shows as sub-pixel white dots along the
        -- seam. All pad-strip edges land exactly on these cut lines by
        -- construction.
        local cutA = math.floor(HALFW * 0.73)
        local cutB = math.floor(HALFW * 0.27)
        local CUTS = { HALFW, cutA, cutB, -cutB, -cutA, -HALFW }
        for s = s0, s1 - 1, BAND do
            local bi = s / BAND
            local deckM = (bi % 2 == 0) and matDeckA or matDeckB
            local padC = isPadBand(bi) and padCentre(bi) or nil
            local padH = padC and padHalf(bi) or 0
            for ci = 1, #CUTS - 1 do
                local o1, o2 = CUTS[ci], CUTS[ci + 1]
                local m = deckM
                if s == 0 then
                    m = matStart
                elseif padC and o1 <= padC + padH + 1
                            and o2 >= padC - padH - 1 then
                    m = matPad
                end
                deckStrip(s, o1, o2, m)
            end
        end

        -- Glowing edge strips ONLY along the open cliff sections. In the
        -- corridors the wall IS the edge marker; a strip hidden behind the
        -- wall base was wasted triangles AND a painter's hazard long
        -- grazing-angle quads sort by max vertex depth, and a strip quad
        -- misordering against the wall drew THROUGH it: the "glowing piece
        -- hanging in mid air". Runs extend one station past each zone edge
        -- so the rim marking never gaps at a wall mouth.
        local function stripAt(i)
            local function open(k) return not stWalled[k % STATIONS] end
            return open(i) or open(i - 1) or open(i + 1)
        end
        for side = -1, 1, 2 do
            local run = nil
            for i = s0, s1 do
                if stripAt(i) then
                    -- Sparse rows follow the shared keep-set; run start/end
                    -- stations are zone transitions, which are always kept.
                    if keepRow[i % STATIONS] then
                        run = run or {}
                        local ox, oy, oz = edge(i, side * (HALFW + EDGEW))
                        local ix, iy, iz = edge(i, side * HALFW)
                        run[#run + 1] = ox; run[#run + 1] = oy; run[#run + 1] = oz
                        run[#run + 1] = ix; run[#run + 1] = iy; run[#run + 1] = iz
                    end
                elseif run then
                    if #run >= 12 then b:ribbon(run, matEdge) end
                    run = nil
                end
            end
            if run and #run >= 12 then b:ribbon(run, matEdge) end
        end

        -- Walls: vertical ribbons (bottom edge = deck rim, top edge = rim
        -- lifted WALLH) over contiguous walled-station runs. UNLIT so the
        -- near-vertical face normals cannot stripe the lighting.
        for side = -1, 1, 2 do
            local run = nil
            -- Station s1 is shared with the next quadrant: including it here
            -- closes the wall across the boundary (the next quadrant starts
            -- its own run AT s1, so there is no overlap either).
            for i = s0, s1 do
                local w = stWalled[i % STATIONS]
                if w then
                    -- Same shared keep-set; walled-run boundary stations are
                    -- zone transitions and therefore always kept.
                    if keepRow[i % STATIONS] then
                        run = run or {}
                        local bx, by, bz = edge(i, side * HALFW)
                        run[#run + 1] = bx; run[#run + 1] = by; run[#run + 1] = bz
                        local tx2, ty2, tz2 = edge(i, side * HALFW, WALLH)
                        run[#run + 1] = tx2; run[#run + 1] = ty2; run[#run + 1] = tz2
                    end
                elseif run then
                    if #run >= 12 then b:ribbon(run, matWall) end
                    run = nil
                end
            end
            if run and #run >= 12 then b:ribbon(run, matWall) end
        end

        local o = b:bake{ light = true, sortdepth = jet.SORT_FARTHEST }
        o:culling(jet.CULL_NONE)
        trackObjs[#trackObjs + 1] = o

        -- Far twin: one-tone deck strips on the SAME CUTS columns as the
        -- detail deck (the shared boundary station line then carries
        -- identical vertices, so a detail sector meeting a twin sector has
        -- NO T-junction at the seam) plus both glow rims full-length,
        -- sampled every 4th station: ~112 tris vs ~450.
        -- Walls/pads/start line omitted; they are a few pixels out there.
        -- Enabled/disabled against the detail object by updateSectorLOD.
        local tb = jet.builder()
        local function twinStrip(o1, o2, m)
            local pts = {}
            for i = s0, s1, 4 do
                local ax, ay, az = edge(i, o1)
                local bx2, by2, bz2 = edge(i, o2)
                pts[#pts + 1] = ax;  pts[#pts + 1] = ay;  pts[#pts + 1] = az
                pts[#pts + 1] = bx2; pts[#pts + 1] = by2; pts[#pts + 1] = bz2
            end
            tb:ribbon(pts, m)
        end
        twinStrip(-HALFW - EDGEW, -HALFW, matEdge)
        for ci = 1, #CUTS - 1 do
            twinStrip(CUTS[ci], CUTS[ci + 1], matDeckF)
        end
        twinStrip(HALFW, HALFW + EDGEW, matEdge)
        local tw = tb:bake{ light = true, sortdepth = jet.SORT_FARTHEST }
        tw:culling(jet.CULL_NONE)
        tw:enabled(false)
        twinObjs[#twinObjs + 1] = tw

        -- One shared switch point for the pair: the sector's station
        -- centroid (xz height is noise at these ranges).
        local scx, scz = 0, 0
        for i = s0, s1 - 1 do
            local c = stC[i % STATIONS]
            scx = scx + c.x; scz = scz + c.z
        end
        sectorLOD[q + 1] = { x = scx / perQ, z = scz / perQ,
                             d = o, t = tw, far = false }
    end
end

-- Detail<->twin switch with hysteresis, ONE xz distance per sector pair.
-- Called from every state that moves the camera; the disabled partner is
-- skipped by the engine before any per-vertex work.
local function updateSectorLOD(camx, camz)
    for _, s in ipairs(sectorLOD) do
        local dx, dz = camx - s.x, camz - s.z
        local d2 = dx * dx + dz * dz
        if s.far then
            if d2 < LOD_IN2 then
                s.far = false; s.d:enabled(true); s.t:enabled(false)
            end
        elseif d2 > LOD_OUT2 then
            s.far = true; s.d:enabled(false); s.t:enabled(true)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Ships
-- ---------------------------------------------------------------------------
local function buildShip(mat)
    -- Lofted hull: one continuous surface swept through the cross-sections
    -- below, tail to nose, as four ribbon strips (deck, two sides, belly),
    -- so the nose is attached by construction. Small lofted quads are also
    -- the cheapest shape this renderer draws: no interpenetrating
    -- primitives for the painter's sort to misorder, ~58 tris total.
    -- Cross-sections: z, half-width, bottom y, top y (+z = nose).
    local CS = {
        { -2800, 1500,  -60, 1040 },   -- blunt tail
        { -1500, 1950, -170, 1260 },   -- engine shoulders (widest)
        {     0, 1850, -210, 1150 },
        {  1600, 1400, -150,  900 },   -- taper begins
        {  3000,  820,  -60,  560 },
        {  4300,  140,  170,  300 },   -- needle tip
    }
    local b = jet.builder()
    do
        local deck, belly, lft, rgt = {}, {}, {}, {}
        local function push(t, x1, y1, z1, x2, y2, z2)
            t[#t + 1] = x1; t[#t + 1] = y1; t[#t + 1] = z1
            t[#t + 1] = x2; t[#t + 1] = y2; t[#t + 1] = z2
        end
        for i = 1, #CS do
            local z, hw, yb, yt = CS[i][1], CS[i][2], CS[i][3], CS[i][4]
            push(deck,  -hw, yt, z,   hw, yt, z)
            push(belly, -hw, yb, z,   hw, yb, z)
            push(rgt,    hw, yt, z,   hw, yb, z)
            push(lft,   -hw, yt, z,  -hw, yb, z)
        end
        b:ribbon(deck, mat)
        b:ribbon(rgt, mat)
        b:ribbon(lft, mat)
        b:ribbon(belly, matDark)
    end
    -- Canopy: a second tiny loft whose apex rises amidships and pinches
    -- closed at both ends (apex y meets base y), so it merges into the
    -- deck line instead of sitting on it as a loose box.
    do
        local CAN = {
            { -1100, 640, 1200, 1210 },
            {  -100, 700, 1140, 1650 },
            {  1100, 520, 1000, 1050 },
        }
        local deck, lft, rgt = {}, {}, {}
        for i = 1, #CAN do
            local z, cw, yb, ya = CAN[i][1], CAN[i][2], CAN[i][3], CAN[i][4]
            deck[#deck + 1] = -cw; deck[#deck + 1] = ya; deck[#deck + 1] = z
            deck[#deck + 1] =  cw; deck[#deck + 1] = ya; deck[#deck + 1] = z
            rgt[#rgt + 1] =  cw; rgt[#rgt + 1] = ya; rgt[#rgt + 1] = z
            rgt[#rgt + 1] =  cw; rgt[#rgt + 1] = yb; rgt[#rgt + 1] = z
            lft[#lft + 1] = -cw; lft[#lft + 1] = ya; lft[#lft + 1] = z
            lft[#lft + 1] = -cw; lft[#lft + 1] = yb; lft[#lft + 1] = z
        end
        b:ribbon(deck, matDark)
        b:ribbon(rgt, matDark)
        b:ribbon(lft, matDark)
    end
    -- Tail plate closes the loft's open rear (engine wall; the animated
    -- flame object provides the glow behind it).
    b:ribbon({ -1500, 1040, -2800,  -1500, -60, -2800,
                1500, 1040, -2800,   1500, -60, -2800 }, matDark)
    -- Twin fins: thin single-quad surfaces sweeping up and back.
    b:ribbon({  1600, 1150, -1500,   1650, 1050, -2650,
                2750, 2050, -2250,   2750, 2000, -2850 }, matTrim)
    b:ribbon({ -1600, 1150, -1500,  -1650, 1050, -2650,
               -2750, 2050, -2250,  -2750, 2000, -2850 }, matTrim)
    local ship = b:bake{ light = false }
    -- Ribbon winding on near-vertical faces follows strip direction, and
    -- the hull must read from every angle (previews rotate), so draw it
    -- double-sided.
    ship:culling(jet.CULL_NONE)
    local fb = jet.builder()
    fb:pyramid(1500, 3000, matFlame, { rx = -90 })
    local flame = fb:bake{ light = false }
    return ship, flame
end

-- Shield bubble: a 6-segment ring band around the ship, spun while active.
-- A closed surface would hide the ship (this renderer has no blending), and
-- a ring seen from the elevated chase camera reads as a halo without
-- covering anything. 12 triangles, and only drawn while a shield is up.
-- Hex flats sit at RAD*cos(30) = ~3200, still clear of the 1950 hull.
local function buildShieldRing()
    local b = jet.builder()
    local N, RAD, Y0, Y1 = 6, 3700, 250, 1450
    local pts = {}
    for k = 0, N do
        local a = k / N * TWO_PI
        local x, z = math.cos(a) * RAD, math.sin(a) * RAD
        pts[#pts + 1] = x; pts[#pts + 1] = Y1; pts[#pts + 1] = z
        pts[#pts + 1] = x; pts[#pts + 1] = Y0; pts[#pts + 1] = z
    end
    b:ribbon(pts, matShld)
    local ring = b:bake{ light = false }
    ring:culling(jet.CULL_NONE)
    ring:enabled(false)
    return ring
end

-- ---------------------------------------------------------------------------
-- Racers
-- ---------------------------------------------------------------------------
-- Combat pacing: neutral cruise is ACCEL/DRAG = ~65,000 (about a third of
-- the old racer speeds), so ships spend time NEXT to each other trading
-- shots instead of flashing past. Boost still spikes to VMAX*1.42*top =
-- ~128,000 the escape/chase button, not the default state. Each racer
-- carries dragK = DRAG * accel / (top * aiV), which pins its thrust
-- equilibrium at (ACCEL/DRAG) * top * aiV: `top` sets the real cruise
-- speed and `accel` only the convergence rate. (A shared DRAG made
-- cruise = accel * 65,000 instead `top` never bound below the 90,000
-- cap, so the accel stat silently decided every race.)
local HOVER, ACCEL, VMAX = 900, 36000, 90000
local DRAG, TURN, TRKB   = 0.55, 2.3, 0.03

-- Driving feel. Steering is a chain: input -> commanded rate -> SMOOTHED
-- actual rate (STEER_EASE) -> nose heading -> velocity heading chasing the
-- nose at the GRIP rate. The ship carves instead of pivoting: keys stop
-- snapping, trackball flicks roll into sustained rate (tbRoll), corners get a
-- hint of drift, and in the air the ship keeps its momentum line while the
-- nose swings almost freely.
local STEER_EASE = 9.0         -- how fast actual turn rate chases command
local GRIP_GND   = 7.0         -- velocity-chases-nose rate on the deck
local GRIP_AIR   = 0.9         -- ...and airborne (floaty, momentum keeps)
local HISPD_DROP = 0.40        -- steering authority lost at full speed

-- Cornering grip: carving scrubs speed by CORNER_SCRUB * frac^2 per
-- second, where frac = |actual turn rate| / this ship's max rate
-- (grounded only). Normalizing to the ship's OWN max makes the turn stat
-- govern corner speed retention: a high-turn ship uses less of its
-- envelope for the same arc, so it keeps more speed through it.
local CORNER_SCRUB = 0.9

-- Trackball ROLL: the ball's counts are too sparse and bursty to drive a
-- turn rate directly (hw: "almost no input"), so each count adds SUSTAINED
-- rate that decays momentum, like a flicked scroll wheel. A tick or two
-- holds a smooth arc; a counter-flick cancels. Strength and decay are the
-- user-facing knobs on the SETTINGS screen.
local TRK_ROLL   = 0.35        -- rad/s of sustained turn added per count
local G, KILLY           = 320000, -420000
local BOOSTMAX           = 1.42     -- VMAX multiplier while boosting
local SHIP_HALF          = 1800

local racers = {}      -- [1] = player
-- The five items, in weapon-id order. `on` is the RACE SETUP > ITEMS IN
-- PLAY toggle; d1/d2 are the ITEMS info screen's two description lines.
-- Roll is uniform over the enabled ones (see rollItem).
local ITEMS = {
    { name = "ZAP",    on = true,
      d1 = "seeks the nearest racer ahead",
      d2 = "spins them out. never fires backward" },
    { name = "MINE",   on = true,
      d1 = "dropped behind you, arms in 0.8s",
      d2 = "then spins out anyone who touches it" },
    { name = "BOOST",  on = true,
      d1 = "1.6s of overspeed, past your top",
      d2 = "the escape button, and the chase one" },
    { name = "ROCKET", on = true,
      d1 = "always hunts the race LEADER",
      d2 = "takes the runner-up if you lead" },
    { name = "SHIELD", on = true,
      d1 = "blocks every hit for 3 seconds",
      d2 = "not used up by a hit -- it rides out" },
}
local SHIELD_T     = 3.0

-- Flat list of enabled item ids, so a pickup is one math.random into it
-- rather than a reject-and-retry loop. Rebuilt on every toggle.
local itemPool = {}
local function rebuildItemPool()
    itemPool = {}
    for w = 1, #ITEMS do
        if ITEMS[w].on then itemPool[#itemPool + 1] = w end
    end
end
rebuildItemPool()   -- derive it, so an `on` default can never go stale

local chosenTypes = { 1, 2, 3 }   -- [racer idx] -> SHIP_TYPES index

-- Ship library: every hull+flame pair is BAKED ONCE at startup and reused
-- for the whole session. Racers always carry DISTINCT
-- types (chosenTypes draws without replacement), so ONE instance per type
-- covers a full six-ship grid, and the select screen shows the same
-- objects instead of a second set. Nothing destroys these until the
-- module exits race starts and NEW TRACK never re-bake or churn the heap.
local shipLib = {}
local function buildShipLib()
    for t, st in ipairs(SHIP_TYPES) do
        local ship, flame = buildShip(st.mat)
        ship:enabled(false)
        flame:enabled(false)
        shipLib[t] = { { obj = ship, flame = flame,
                         shield = buildShieldRing() } }
    end
end

local function newRacer(idx, isAI, lib)
    local st = SHIP_TYPES[chosenTypes[idx]]
    local ship, flame = lib.obj, lib.flame
    ship:enabled(true)
    -- AI personality: cruise factor plus a lane it likes to hold.
    local aiV = isAI and (0.96 + math.random() * 0.07) or 1.0
    return {
        idx = idx, ai = isAI, st = st,
        obj = ship, flame = flame, shield = lib.shield,
        -- Per-racer drag (see the pacing comment): pins this ship's
        -- thrust equilibrium at (ACCEL/DRAG) * top * aiV.
        dragK = DRAG * st.accel / (st.top * aiV),
        px = 0, py = 0, pz = 0, heading = 0,
        speed = 0, vy = 0, grounded = true, bank = 0,
        progress = 0, lap = 0, cp = 0, finishT = nil, stIdx = 0,
        spinT = 0, spinA = 0, boostT = 0, weapon = nil, graceT = 0,
        shieldT = 0,
        velH = 0, turnRate = 0, tbRoll = 0, wrongT = 0,
        aiV = aiV,
        aiLane = isAI and (math.random() * 2 - 1) * HALFW * 0.45 or 0,
        aiFireT = 3 + math.random() * 4,
    }
end

local function placeAtStart(rc)
    -- Grid: three lanes per row, extra rows staggered back from the line.
    local row = (rc.idx - 1) // 3
    local st = math.floor(1.5 * BAND) - row * 2
    local c, n = stC[st], stN[st]
    local lat = ({ 0, -1, 1 })[(rc.idx - 1) % 3 + 1]
                * math.floor(HALFW * 0.4)
    rc.px, rc.py, rc.pz = c.x + n.x * lat, c.y + HOVER, c.z + n.z * lat
    rc.heading = stationHeading(st)
    rc.stIdx = st
    rc.speed, rc.vy, rc.grounded, rc.bank = 0, 0, true, 0
    rc.progress, rc.lap, rc.cp = 0, 0, 0
    rc.spinT, rc.boostT, rc.weapon, rc.finishT = 0, 0, nil, nil
    rc.graceT, rc.shieldT = 0, 0
    rc.shield:enabled(false)
    rc.velH, rc.turnRate, rc.tbRoll, rc.wrongT = rc.heading, 0, 0, 0
    -- Visual sync now: menu/attract states never run the sim's visual loop,
    -- and unsynced ships would float at the world origin.
    rc.obj:position(math.floor(rc.px), math.floor(rc.py), math.floor(rc.pz))
    rc.obj:rotation(0, math.floor(math.deg(rc.heading)) % 360, 0)
    rc.flame:enabled(false)
end

local function respawn(rc)
    -- Back to the last checkpoint (every 32 stations, see CPS), on the deck
    -- centre, facing along the track.
    local st = (rc.cp * (STATIONS // CPS)) % STATIONS
    local c = stC[st]
    rc.px, rc.py, rc.pz = c.x, c.y + HOVER, c.z
    rc.heading = stationHeading(st)
    rc.stIdx = st
    rc.speed, rc.vy, rc.grounded, rc.spinT, rc.boostT = 0, 0, true, 0, 0
    rc.velH, rc.turnRate, rc.tbRoll, rc.wrongT = rc.heading, 0, 0, 0
end

-- ---------------------------------------------------------------------------
-- Items, weapons
-- ---------------------------------------------------------------------------
-- boxes = the flat list (build, teardown and cull-group membership).
-- itemRows/rowAt/deadBoxes are the per-frame access paths: NOTHING in the
-- tick walks `boxes` itself, because at EPIC+MANY that is 288 entries times
-- the racer loop every frame. (itemRows, not `rows`: the menu draw blocks
-- have their own local `rows` of text lines.)
-- Pickup window: 1.0 station along the track, 3,200 units laterally.
-- Measured on the box station's OWN axes rather than as a single radius,
-- so the along-track reach can be widened -- a narrow window lets boost
-- speed carry a racer clean past a box between two frames -- without also
-- making it easier to grab a box from the neighbouring lane.
local BOX_ALONG = SEGLEN * 0.5
local BOX_LAT   = 3200
-- Spin window, in stations either side of the player. DERIVED, not tuned:
-- the boxes carry fade(BOX_FAR, BOX_FAR), and Scene skips any object whose
-- camera distance passes fadeFar outright ("no transform, no per-tri
-- work"), so BOX_FAR is a hard visibility wall -- rotating a box past it
-- cannot show. Behind is tiny because the chase camera sits 21,000-27,000
-- units BEHIND the ship (camd), so barely two stations back is all that
-- stays on screen. Every box shares one angle, so this window is the only
-- thing that decides the cost of the spin.
local SPIN_AHEAD  = math.floor(BOX_FAR / SEGLEN)   -- ~29 stations
local SPIN_BEHIND = 4
local boxes = {}       -- { obj, x, z, y, st, deadT }
local itemRows = {}    -- { st = mid station, box = { its boxes } } per row
local rowAt = {}       -- [band index] -> that band's row, O(1)
local deadBoxes = {}   -- only the picked-up boxes, i.e. the ones with a timer
-- kind 1 = zap (homes on the closest racer), 2 = mine (static, arms after
-- armT), 3 = rocket (homes on the race leader, faster and longer-lived).
local shots = {}       -- { kind, obj, stF, x, y, z, target, ttl, owner, armT }
local shotPool = {}

local function buildBoxes()
    for s = 0, STATIONS - 1, BAND do
        local bi = s // BAND
        if isItemBand(bi) then
            local mid = (s + BAND // 2) % STATIONS
            local c, n = stC[mid], stN[mid]
            local cx, cy, cz = c.x, c.y, c.z
            local row = { st = mid, box = {} }
            -- ITEMS PER ROW boxes at the FIXED lane spacing (0.42*HALFW,
            -- exactly the original three-lane grid a ship fits cleanly
            -- between two boxes), but the row AS A UNIT sits at a random
            -- lateral offset: the whole set slides to wherever the deck
            -- has room for it (box centres stay within HALFW - 3200, off
            -- the rim). Small sets roam widely a 1-box row can land
            -- anywhere across the width; a full 5-box set barely moves.
            -- Runs under the track seed, so a given seed always places
            -- its boxes identically.
            local nB = CFG_NBOX[raceCfg.nbox][2]
            local spacing = HALFW * 0.42
            local halfSpan = (nB - 1) * spacing * 0.5
            local roam = math.max(0, (HALFW - 3200) - halfSpan)
            local centre = (math.random() * 2 - 1) * roam
            for k = 1, nB do
                local lat = centre + (k - (nB + 1) / 2) * spacing
                local b = jet.builder()
                b:cube(1900, 1900, 1900, matBox)
                local o = b:bake{ light = false }
                o:fade(BOX_FAR, BOX_FAR)
                local x = cx + n.x * lat
                local z = cz + n.z * lat
                o:position(math.floor(x), math.floor(cy + 2400), math.floor(z))
                local bx = { obj = o, x = x, z = z, y = cy + 2400,
                             st = mid, deadT = 0 }
                boxes[#boxes + 1] = bx
                row.box[#row.box + 1] = bx
            end
            itemRows[#itemRows + 1] = row
            rowAt[bi] = row
        end
    end
end

-- The aggregation gate from the engine (jet.cullgroup): one sphere test per
-- 32-station sector skips that sector's deck AND its item boxes when the
-- sector is outside the frustum no per-object cull, no per-member work.
-- Static members only: ships, shots and flames move, so they stay out.
local sectorGroups = {}
local function buildGroups()
    for q = 0, STATIONS // 32 - 1 do
        local members = { trackObjs[q + 1], twinObjs[q + 1] }
        for _, bx in ipairs(boxes) do
            if bx.st // 32 == q then members[#members + 1] = bx.obj end
        end
        sectorGroups[#sectorGroups + 1] = jet.cullgroup(members)
    end
end

-- What a box hands over. uniform over the enabled item.
local function rollItem()
    return itemPool[math.random(#itemPool)]
end

local function shotObj(kind)
    for _, s in ipairs(shotPool) do
        if not s.busy and s.kind == kind then s.busy = true; return s end
    end
    local b = jet.builder()
    if kind == 1 then b:sphere(1100, 8, matZap)
    elseif kind == 3 then b:cube(700, 700, 2800, matRkt)   -- rocket: a dart
    else b:cube(2000, 900, 2000, matMine) end
    local rec = { kind = kind, obj = b:bake{ light = false }, busy = true }
    shotPool[#shotPool + 1] = rec
    return rec
end

-- ALWAYS spends the item. Returns true if the shot found a target, false
-- if it went out blind (nobody ahead) the caller uses that only to tell
-- the player why nothing is going to get hit.
local function fireWeapon(rc, ranked)
    local w = rc.weapon
    rc.weapon = nil
    if w == 3 then rc.boostT = 1.6 return true end
    if w == 5 then rc.shieldT = SHIELD_T return true end
    if w == 2 then
        local s = shotObj(2)
        local fx, fz = math.sin(rc.heading), math.cos(rc.heading)
        s.x, s.z = rc.px - fx * 5200, rc.pz - fz * 5200
        s.y = rc.py - HOVER + 700       -- rests on the deck where dropped
        s.ttl, s.armT, s.owner = 25, 0.8, rc
        s.obj:enabled(true)
        shots[#shots + 1] = s
        return true
    end
    -- Homing shots pick their target by ROLE. Finished ships are out of the
    -- fight and never worth a shot (they still drive home on autopilot).
    local target
    if w == 4 then
        -- ROCKET: the race leader, whoever that is ranked[] is already in
        -- standings order. Fired BY the leader it takes the runner-up
        -- instead; a self-seeking rocket would just be a wasted pickup.
        for _, r in ipairs(ranked) do
            if r ~= rc and not r.finishT then target = r; break end
        end
        -- Everyone else already home: take the shot at whoever is left.
        if not target then
            for _, r in ipairs(racers) do if r ~= rc then target = r end end
        end
    else
        -- ZAP: the nearest racer AHEAD, never one behind.
        -- "Ahead" is track position, not standings the racer one place up
        -- can be most of a lap away. Level counts as ahead (delta 0), so a
        -- side-by-side pack fight is still a valid shot. Distance includes
        -- height because over/under crossings stack two decks at nearly the
        -- same xz; a flat distance would pick the ship overhead.
        local best = math.huge
        for _, r in ipairs(racers) do
            if r ~= rc and not r.finishT
               and wrapSt(r.stIdx - rc.stIdx) >= 0 then
                local dx, dy = r.px - rc.px, r.py - rc.py
                local dz = r.pz - rc.pz
                -- floats throughout: squaring world scale as int32 wraps.
                local d2 = dx * dx + dy * dy + dz * dz
                if d2 < best then best, target = d2, r end
            end
        end
    end
    local s = shotObj((w == 4) and 3 or 1)
    s.stF = (rc.stIdx + 1) % STATIONS
    s.target, s.owner = target, rc
    if target then
        -- The rocket's ttl must cover the whole lap: at EPIC length the
        -- leader can be ~380 stations away, which is ~12s of flight even at
        -- rocket speed. A short fuse would silently expire mid-chase.
        s.ttl = (w == 4) and 30 or 7
    else
        -- Nothing valid to shoot (nobody ahead). The item is still SPENT
        -- and the shot still flies holding it back would block the next
        -- pickup, which might be the boost that wins the lap. With no lock
        -- it just runs up the track on a short fuse and pops.
        s.ttl = 1.5
    end
    s.obj:enabled(true)
    shots[#shots + 1] = s
    return target ~= nil
end

-- Post-spin grace blocks chain-locking: without it two mines (or an AI
-- with a zapper on a timer) could hold a victim in place indefinitely.
local function spinOut(rc)
    -- SHIELD absorbs every hit for its full duration and is NOT consumed by
    -- one. The shot still dies at the contact point it hit the bubble.
    if rc.shieldT > 0 then return end
    if rc.spinT <= 0 and rc.graceT <= 0 then rc.spinT, rc.spinA = 1.1, 0 end
end

-- ---------------------------------------------------------------------------
-- Shared racer physics
-- ---------------------------------------------------------------------------
local raceState, raceT, countT = "menu", 0, 3.0
local pausedFrom = "race"

local function driveRacer(rc, dt, thrust, turn)
    if rc.graceT > 0 then rc.graceT = rc.graceT - dt end
    if rc.shieldT > 0 then rc.shieldT = rc.shieldT - dt end
    if rc.spinT > 0 then
        rc.spinT = rc.spinT - dt
        rc.spinA = rc.spinA + dt * 720
        thrust, turn = false, 0
        rc.speed = rc.speed - rc.speed * 2.2 * dt
        if rc.spinT <= 0 then rc.graceT = 1.2 end
        rc.turnRate = 0
    end

    -- Steering chain (see the feel constants): the COMMANDED rate is scaled
    -- by speed-dependent authority, the ACTUAL rate eases toward it, and
    -- the velocity heading chases the nose at the grip rate. Motion follows
    -- the VELOCITY heading the nose leads, the ship carves after it.
    local authority = 1 - HISPD_DROP * math.min(1, rc.speed / VMAX)
    rc.turnRate = rc.turnRate
                + (turn * authority - rc.turnRate) * math.min(1, STEER_EASE * dt)
    rc.heading = rc.heading + rc.turnRate * dt
    local grip = rc.grounded and GRIP_GND or GRIP_AIR
    rc.velH = rc.velH + wrapAngle(rc.heading - rc.velH) * math.min(1, grip * dt)

    local st = rc.st
    if rc.boostT > 0 then
        rc.boostT = rc.boostT - dt
        rc.speed = math.min(rc.speed + ACCEL * 3 * st.accel * dt,
                            VMAX * BOOSTMAX * st.top)
    elseif thrust then
        rc.speed = math.min(rc.speed + ACCEL * st.accel * dt,
                            VMAX * rc.aiV * st.top)
    end
    rc.speed = rc.speed - rc.speed * rc.dragK * dt
    -- Cornering grip (see CORNER_SCRUB). Spin excluded: turnRate is
    -- zeroed there. frac capped so a full trackball-roll pivot (2.2x max
    -- rate) brakes hard but never stops the ship outright.
    if rc.grounded then
        local frac = math.min(1.5, math.abs(rc.turnRate) / (TURN * st.turn))
        rc.speed = rc.speed - rc.speed * CORNER_SCRUB * frac * frac * dt
    end
    if rc.speed < 0 then rc.speed = 0 end

    local fx, fz = math.sin(rc.velH), math.cos(rc.velH)
    rc.px = rc.px + fx * rc.speed * dt
    rc.pz = rc.pz + fz * rc.speed * dt

    local stI, lat, f = trackQuery(rc)
    local fi = stI + f

    -- Corridor walls: strip the excess lateral offset along the lane
    -- normal, scrub speed, steer the nose back along the track. Uses the
    -- same stWalled the meshes were built from.
    if stWalled[stI] and math.abs(lat) > HALFW - SHIP_HALF then
        local lim = (lat > 0) and (HALFW - SHIP_HALF) or -(HALFW - SHIP_HALF)
        local ex = lat - lim
        local nv = stN[stI]
        rc.px, rc.pz = rc.px - nv.x * ex, rc.pz - nv.z * ex
        lat = lim
        rc.speed = rc.speed * (1 - 1.6 * dt)
        local ht = stationHeading(stI)
        if math.cos(rc.heading - ht) < 0 then ht = ht + 3.14159265 end
        rc.heading = rc.heading + wrapAngle(ht - rc.heading) * math.min(1, 5 * dt)
        -- The velocity line too, or momentum keeps pressing into the wall.
        rc.velH = rc.velH + wrapAngle(ht - rc.velH) * math.min(1, 6 * dt)
    end

    -- Wrong-way detector: moving against the station direction for a
    -- sustained moment. Progress/checkpoints already refuse backward credit;
    -- this is the CUE (drawn for the player when wrongT passes 0.6s).
    if rc.speed > 12000
       and math.cos(rc.velH - stationHeading(stI)) < -0.15 then
        rc.wrongT = rc.wrongT + dt
    else
        rc.wrongT = 0
    end

    local _, deckY = stationAt(fi)
    local over = math.abs(lat) <= HALFW + EDGEW
    if rc.grounded then
        if over then
            rc.py = rc.py + (deckY + HOVER - rc.py) * math.min(1, 12 * dt)
            -- Boost pads: the band under the ship AND the ship's lateral
            -- offset inside the pad strip same padCentre() as the mesh.
            local bi = stI // BAND
            if isPadBand(bi) and math.abs(lat - padCentre(bi)) < padHalf(bi) then
                rc.boostT = math.max(rc.boostT, 1.0)
            end
        else
            rc.grounded, rc.vy = false, 0
        end
    else
        local prevY = rc.py
        rc.vy = rc.vy - G * dt
        rc.py = rc.py + rc.vy * dt
        local deck = deckY + HOVER
        if over and rc.vy < 0 and prevY >= deck and rc.py <= deck then
            rc.py, rc.grounded, rc.vy = deck, true, 0
        end
        if rc.py < KILLY then respawn(rc) return end
    end

    -- Lap / checkpoint accounting: progress is an unwrapped STATION count.
    local d = wrapSt(fi - (rc.progress % STATIONS))
    rc.progress = rc.progress + d
    local cp = math.floor((rc.progress % STATIONS) / (STATIONS / CPS))
    if cp == (rc.cp + 1) % CPS then rc.cp = cp end
    if rc.progress >= STATIONS then
        rc.progress = rc.progress - STATIONS
        rc.lap = rc.lap + 1
        if rc.lap >= 3 and not rc.finishT then
            rc.finishT = raceT
            rc.weapon = nil          -- finished = passive: hands off items
        end
    elseif rc.progress < -STATIONS then
        -- A full lap BACKWARD costs a lap without this, wrapping the
        -- progress alone made backward+forward a free lap.
        rc.progress = rc.progress + STATIONS
        rc.lap = rc.lap - 1
    end
end

local function aiControl(rc, dt, ranked)
    local stI = rc.stIdx

    -- Corner-aware braking: the sharpest curvature inside the braking
    -- window ahead sets a safe speed (v = max turn rate * radius, with a
    -- 0.6 margin for line error). Above it, thrust cuts and drag brakes.
    -- This is what stops a ship entering a 42k-radius hairpin at cruise
    -- the way they all sailed off the first corner of every real track.
    local worstK = 0
    local brakeWin = 6 + math.floor(rc.speed / VMAX * 14)
    for o = 2, brakeWin do
        local k = stK[(stI + o) % STATIONS]
        if k > worstK then worstK = k end
    end
    local vSafe = VMAX * rc.aiV
    if worstK > 1e-6 then
        vSafe = math.min(vSafe, TURN * rc.st.turn * (SEGLEN / worstK) * 0.6)
    end

    -- Chase a point ahead on the centreline. Short lookahead: a long one
    -- aims ACROSS a hairpin and cuts the corner through open air. The lane
    -- offset only applies inside corridors over cliffs the pilots hug
    -- the centre.
    local la = 4 + (rc.speed / VMAX) * 6
    local li = math.floor(stI + la) % STATIONS
    local ax, _, az = stationAt(stI + la)
    local n = stN[li]
    local lane = stWalled[li] and rc.aiLane or rc.aiLane * 0.3

    -- Edge recovery: drifting wide on an open section overrides everything
    -- aim at the centreline and get off the throttle.
    local c = stC[stI]
    local latNow = (rc.px - c.x) * stN[stI].x + (rc.pz - c.z) * stN[stI].z
    if not stWalled[stI] and math.abs(latNow) > HALFW * 0.65 then
        lane = 0
        vSafe = math.min(vSafe, VMAX * 0.5)
    end

    local tx = ax + n.x * lane
    local tz = az + n.z * lane
    local want = math.atan(tx - rc.px, tz - rc.pz)
    local err = wrapAngle(want - rc.heading)
    local tmax = TURN * rc.st.turn
    local turn = math.max(-tmax, math.min(tmax, err * 4))
    local thrust = math.abs(err) < 1.0 and rc.speed <= vSafe

    -- Combat: fire on a short timer, but SNAP-fire a zapper the moment any
    -- other racer CPU or player alike is in the window ahead. This is
    -- what makes the CPUs visibly fight each other, not just the leader.
    -- Finished racers are PASSIVE: they drive home but never attack.
    rc.aiFireT = rc.aiFireT - dt
    if rc.weapon and not rc.finishT then
        local eager = false
        if rc.weapon == 1 then
            -- Snap-fire the zapper the moment a rival is in the window
            -- AHEAD the only direction it shoots.
            for _, o in ipairs(racers) do
                if o ~= rc then
                    local d = wrapSt(o.stIdx - rc.stIdx)
                    if d >= 0 and d <= 16 then eager = true; break end
                end
            end
        elseif rc.weapon == 5 then
            -- Raise the shield on an ACTUAL incoming shot, not on pickup:
            -- spending it blind wastes most of its short window, and a CPU
            -- that blocks the rocket aimed at it is the whole point. The
            -- fire timer still spends it eventually, so a shield is never
            -- hoarded forever. Mines carry a stale s.target from the pool,
            -- hence the kind test.
            for _, s in ipairs(shots) do
                if (s.kind == 1 or s.kind == 3) and s.target == rc then
                    eager = true; break
                end
            end
        end
        if eager or rc.aiFireT <= 0 then
            fireWeapon(rc, ranked)
            rc.aiFireT = 2 + math.random() * 2
        end
    end
    return thrust, turn
end

-- ---------------------------------------------------------------------------
-- Race lifecycle
-- ---------------------------------------------------------------------------
-- Pick types for 1 + raceCfg.npcs racers: the player first, then the
-- remaining classes shuffled and drawn WITHOUT replacement six classes
-- cover the full 6-racer grid with every ship distinct.
local function rollChosenTypes(playerType)
    local pool = {}
    for t = 1, #SHIP_TYPES do
        if t ~= playerType then pool[#pool + 1] = t end
    end
    for i = #pool, 2, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end
    chosenTypes = { playerType }
    for i = 2, 1 + raceCfg.npcs do chosenTypes[i] = pool[i - 1] end
end

local function assignRacers()
    local used = {}
    racers = {}
    for i = 1, 1 + raceCfg.npcs do
        local t = chosenTypes[i]
        used[t] = true
        racers[i] = newRacer(i, i > 1, shipLib[t][1])
        placeAtStart(racers[i])
    end
    -- Library instances not racing stay hidden.
    for t = 1, #SHIP_TYPES do
        if not used[t] then
            shipLib[t][1].obj:enabled(false)
            shipLib[t][1].flame:enabled(false)
        end
        shipLib[t][1].shield:enabled(false)
    end
end

local function clearRace()
    for _, g in ipairs(sectorGroups) do g:destroy() end
    sectorGroups = {}
    for _, o in ipairs(trackObjs) do o:destroy() end
    for _, o in ipairs(twinObjs) do o:destroy() end
    for _, bx in ipairs(boxes) do bx.obj:destroy() end
    for _, s in ipairs(shotPool) do s.obj:destroy() end
    -- Racer ships/flames belong to the startup-baked shipLib: hide them,
    -- never destroy them.
    for _, rc in ipairs(racers) do
        rc.obj:enabled(false); rc.flame:enabled(false)
        rc.shield:enabled(false)
    end
    trackObjs, twinObjs, boxes, shots, shotPool, racers =
        {}, {}, {}, {}, {}, {}
    -- The box access paths hold the SAME box records, so they must be
    -- dropped with the list they index or they would reference destroyed
    -- objects on the next track.
    itemRows, rowAt, deadBoxes = {}, {}, {}
    sectorLOD = {}
end

-- Put everything back on the grid on the CURRENT track: racers, boxes,
-- shots, clocks. Cheap no rebuild so RESTART and MAIN MENU are instant.
local function resetRace()
    for _, rc in ipairs(racers) do placeAtStart(rc) end
    for _, s in ipairs(shots) do s.obj:enabled(false); s.busy = false end
    shots = {}
    for _, bx in ipairs(boxes) do bx.deadT = 0; bx.obj:enabled(true) end
    deadBoxes = {}           -- every timer just got cleared above
    raceT, countT = 0, 3.0
end

local function buildRace()
    rollTrack()
    buildTrack()
    buildBoxes()
    buildGroups()
    rollChosenTypes(chosenTypes[1] or 1)
    assignRacers()
    raceT, countT = 0, 3.0
    -- One line per build: the seed reproduces a reported track exactly.
    jet.log(string.format("[kart] seed %d  stations %d  radius %d  walls %d%%",
                          seed, STATIONS, R, CFG_WALLS[raceCfg.walls][2]))
end

-- Rebuild only the racers for a fresh class assignment: player gets the
-- picked class, the CPUs draw distinct classes from the rest at random.
local function rebuildRacers(playerType)
    rollChosenTypes(playerType)
    assignRacers()
end

-- Showcase ships for the select screen. These ARE the library ships the
-- racers fly registration only here: no positioning (the racers are
-- already parked on the grid at this point; the select tick repositions
-- previews every frame while selecting) and no enabled() change.
local previewShips = {}
local function buildPreviews()
    for t in ipairs(SHIP_TYPES) do
        previewShips[t] = shipLib[t][1].obj
    end
end

-- selRow: 1 = the ship carousel (z launches), 2 = BACK (z returns to the
-- main menu). A keybind alone was not enough of an escape here entering
-- ship select by accident needs a visible way out, not a hint.
local selType, selT, selRow = 1, 0, 1
local function showPreviews(on)
    for _, o in ipairs(previewShips) do o:enabled(on) end
    -- Previews and racers share objects now: leaving the select screen
    -- returns every racer's ship to the grid (and re-enables it there).
    if not on then
        for _, rc in ipairs(racers) do placeAtStart(rc); rc.obj:enabled(true) end
    end
end

jet.scene.sky(jet.rgb(96, 148, 205), jet.rgb(198, 220, 238))
jet.scene.ambient(84, 86, 96)
jet.scene.light(-45, 40, 255, 246, 224)
jet.camera.fov(70)
jet.camera.clip(20, 3000000)
applyRaceCfg()
buildShipLib()
buildRace()
buildPreviews()
raceState = "menu"

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------
local edgeKeys = {}
local function pressed(key)
    local now = jet.input.down(key)
    local was = edgeKeys[key]
    edgeKeys[key] = now
    return now and not was
end

-- Input is ACTIONS, not keys: the launcher's Controls screen (lib/keybind)
-- binds physical keys to these codes and passes the map to the firmware as
-- -keymap, so whatever the user bound arrives here as the action code.
-- Which physical key that is never reaches (or concerns) this game all
-- control hints name the action. Quit is keybind's own 0xFF, handled by
-- the firmware before the module ever sees it. Keep in step with the
-- launcher's kb table and its comment.
-- There is no fire action: Down doubles as USE ITEM in the race (nothing
-- else reads Down there no braking exists, drag decelerates), and 0xA5
-- (the old fire code) stays unassigned in the launcher too.
local ACT = { up = 0xA0, down = 0xA1, left = 0xA2, right = 0xA3,
              thrust = 0xA4, pause = 0xA6, restart = 0xA7 }

-- Menu "select": Thrust (trackball click is checked by each caller).
local function selPressed()
    return pressed(ACT.thrust)
end

local flameT = 0

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------
local MAIN_MENU  = { "RACE", "RACE SETUP", "ITEMS", "NEW TRACK",
                     "SETTINGS", "QUIT" }
local PAUSE_MENU = { "RESUME", "RESTART", "SETTINGS", "MAIN MENU", "QUIT" }
local menuSel, menuDy = 1, 0
local attractTh = 0

-- Steering sensitivity, adjustable on the SETTINGS screen. Separate knobs:
-- keySens scales the a/d turn rate, trkSens scales the trackball roll
-- strength, trkDecay is how fast rolled turn rate bleeds off (low = keeps
-- rolling). Session-only for now (no config file in the module's Lua yet).
local keySens, trkSens, trkDecay = 1.0, 1.0, 3.0
local ctlSel, settingsFrom = 1, "menu"
local setupSel, setupDirty = 1, false
local itemSel = 1              -- row on the ITEMS IN PLAY screen
local itemWarnT = 0            -- "keep one item on" refusal note
local showFps = false          -- top-right fps readout (SETTINGS screen)
-- Session win/loss record (shown on the menu and results screens).
local stats = { wins = 0, losses = 0, races = 0 }
-- Countdown for the "no target ahead" HUD note. The shot still goes out
-- and the item is still spent; this only explains why it will hit nothing.
local noTgtT = 0

-- Shared navigation: Up/Down actions or trackball vertical; select via
-- Thrust or trackball click. Returns true on select. The trackball is
-- consumed here, which is safe because menu states never run the race
-- sim.
local function menuNav(n)
    local _, tdy, tclick = jet.input.trackball()
    menuDy = menuDy + tdy
    local moved = 0
    if pressed(ACT.up) then moved = -1 end
    if pressed(ACT.down) then moved = 1 end
    if menuDy < -6 then moved = -1; menuDy = 0 end
    if menuDy >  6 then moved = 1;  menuDy = 0 end
    if moved ~= 0 then menuSel = ((menuSel - 1 + moved) % n) + 1 end
    local sel = selPressed()
    return sel or tclick > 0
end

local function drawMenu(title, entries)
    jet.text(96, 46, title, jet.rgb(255, 230, 120), 2)
    for i, e in ipairs(entries) do
        local marker = (i == menuSel) and "> " or "  "
        jet.text(118, 86 + i * 14, marker .. e,
                 (i == menuSel) and jet.rgb(255, 255, 255)
                                 or jet.rgb(170, 190, 215))
    end
end

local function rankedRacers()
    local list = {}
    for i, rc in ipairs(racers) do list[i] = rc end
    table.sort(list, function(a, b)
        -- Finished racers hold their finishing order; the rest rank live.
        if a.finishT and b.finishT then return a.finishT < b.finishT end
        if a.finishT then return true end
        if b.finishT then return false end
        if a.lap ~= b.lap then return a.lap > b.lap end
        return a.progress > b.progress
    end)
    return list
end

-- ---------------------------------------------------------------------------
-- Per-state tick functions. jet.update dispatches exactly ONE of these on
-- raceState; count/race/done share the race tick, because the sim runs
-- identically through the countdown, the race and the results wait.
-- ---------------------------------------------------------------------------
local tick = {}

-- Main menu: attract flythrough of the current track, ships idle on the
-- grid. The race sim does not run.
function tick.menu(dt)
    if menuNav(#MAIN_MENU) then
        local e = MAIN_MENU[menuSel]
        if e == "RACE" then
            showPreviews(true)
            selRow, raceState = 1, "select"
        elseif e == "RACE SETUP" then
            setupSel, raceState = 1, "setup"
        elseif e == "ITEMS" then
            raceState = "items"
        elseif e == "NEW TRACK" then
            clearRace(); buildRace(); resetRace()
        elseif e == "SETTINGS" then
            settingsFrom, ctlSel, raceState = "menu", 1, "settings"
        else
            jet.quit()
        end
        return
    end
    attractTh = attractTh + dt * 5.5          -- stations per second
    local cx, cy, cz = stationAt(attractTh)
    local lx, ly, lz = stationAt(attractTh + 9)
    jet.camera.position(cx, cy + 30000, cz)
    jet.camera.lookat(lx, ly + 4000, lz)
    jet.camera.fov(70)
    updateSectorLOD(cx, cz)
end

-- Ship select: Left/Right or trackball-x browses the ships, Up/Down
-- picks between the ship row and BACK, Thrust/click acts on the
-- current row, and Pause still backs out from anywhere.
function tick.select(dt)
    selT = selT + dt
    local tdx, tdy, tclick = jet.input.trackball()
    local moved = 0
    if pressed(ACT.left) then moved = -1 end
    if pressed(ACT.right) then moved = 1 end
    menuDy = menuDy + tdx
    if menuDy < -6 then moved = -1; menuDy = 0 end
    if menuDy >  6 then moved = 1;  menuDy = 0 end
    -- Left/Right browses from either row, so it never goes dead on BACK.
    if moved ~= 0 then
        selType = ((selType - 1 + moved) % #SHIP_TYPES) + 1
    end
    local rowMove = 0
    if pressed(ACT.up) then rowMove = -1 end
    if pressed(ACT.down) then rowMove = 1 end
    if tdy < -6 then rowMove = -1 elseif tdy > 6 then rowMove = 1 end
    if rowMove ~= 0 then selRow = (selRow == 1) and 2 or 1 end
    -- Carousel: the picked ship rotates centre stage with its two
    -- neighbours flanking it; the rest are hidden (six in a row would
    -- overflow the frustum at this camera distance).
    local nT = #SHIP_TYPES
    local lftT = (selType - 2) % nT + 1
    local rgtT = selType % nT + 1
    for t, o in ipairs(previewShips) do
        if t == selType then
            o:enabled(true)
            o:rotation(0, math.floor(180 + selT * 60) % 360, 0)
            o:position(0, 90800 + math.floor(
                       math.sin(selT * 3) * 300), 0)
        elseif t == lftT or t == rgtT then
            o:enabled(true)
            o:rotation(0, 180, 0)
            o:position(t == lftT and -9500 or 9500, 90000, 0)
        else
            o:enabled(false)
        end
    end
    jet.camera.position(0, 93500, -21000)
    jet.camera.lookat(0, 90200, 0)
    jet.camera.fov(70)
    updateSectorLOD(0, -21000)
    if selPressed() or tclick > 0 then
        showPreviews(false)
        if selRow == 2 then
            menuSel, raceState = 1, "menu"
        else
            rebuildRacers(selType)
            raceState = "count"
        end
        return
    end
    if pressed(ACT.pause) then
        showPreviews(false)
        menuSel = 1
        raceState = "menu"
    end
end

-- Pause: freeze the whole sim (clocks included) under the menu.
function tick.pause(dt)
    if menuNav(#PAUSE_MENU) then
        local e = PAUSE_MENU[menuSel]
        if e == "RESUME" then
            raceState = pausedFrom
        elseif e == "RESTART" then
            resetRace(); raceState = "count"
        elseif e == "SETTINGS" then
            settingsFrom, ctlSel, raceState = "pause", 1, "settings"
        elseif e == "MAIN MENU" then
            resetRace(); menuSel = 1; raceState = "menu"
        else
            jet.quit()
        end
    end
end

-- Settings: three steering-feel rows, the fps readout toggle, BACK.
-- Up/Down picks the row, Left/Right (or trackball x) adjusts, Thrust on
-- BACK or Pause anywhere returns to whichever menu opened it. Nothing
-- here rebuilds the track, so none of it touches setupDirty.
function tick.settings(dt)
    local tdx, tdy, tclick = jet.input.trackball()
    menuDy = menuDy + tdy
    local moved = 0
    if pressed(ACT.up) then moved = -1 end
    if pressed(ACT.down) then moved = 1 end
    if menuDy < -6 then moved = -1; menuDy = 0 end
    if menuDy >  6 then moved = 1;  menuDy = 0 end
    if moved ~= 0 then ctlSel = ((ctlSel - 1 + moved) % 5) + 1 end

    local adj = 0
    if pressed(ACT.left) then adj = -1 end
    if pressed(ACT.right) then adj = 1 end
    if tdx < -5 then adj = -1 elseif tdx > 5 then adj = 1 end
    local sel = selPressed() or tclick > 0
    if adj ~= 0 then
        if ctlSel == 1 then
            trkSens = math.max(0.2, math.min(3.0, trkSens + adj * 0.2))
        elseif ctlSel == 2 then
            trkDecay = math.max(0.5, math.min(8.0, trkDecay + adj * 0.5))
        elseif ctlSel == 3 then
            keySens = math.max(0.2, math.min(3.0, keySens + adj * 0.2))
        end
    end
    -- The fps row is a toggle: either direction, or select, flips it.
    if ctlSel == 4 and (adj ~= 0 or sel) then showFps = not showFps end

    if pressed(ACT.pause) or (sel and ctlSel == 5) then
        menuSel = 1
        raceState = settingsFrom
    end
end

-- Race setup: w/s row, a/d cycles the value. Leaving with changes
-- rebuilds the track (full NEW TRACK semantics) so every option takes
-- effect immediately.
function tick.setup(dt)
    local tdx, tdy, tclick = jet.input.trackball()
    menuDy = menuDy + tdy
    local moved = 0
    if pressed(ACT.up) then moved = -1 end
    if pressed(ACT.down) then moved = 1 end
    if menuDy < -6 then moved = -1; menuDy = 0 end
    if menuDy >  6 then moved = 1;  menuDy = 0 end
    if moved ~= 0 then setupSel = ((setupSel - 1 + moved) % 9) + 1 end
    local adj = 0
    if pressed(ACT.left) then adj = -1 end
    if pressed(ACT.right) then adj = 1 end
    if tdx < -5 then adj = -1 elseif tdx > 5 then adj = 1 end
    if adj ~= 0 then
        local function cyc(v, n) return ((v - 1 + adj) % n) + 1 end
        if setupSel == 1 then
            raceCfg.npcs = math.max(0, math.min(5, raceCfg.npcs + adj))
            setupDirty = true
        elseif setupSel == 2 then
            raceCfg.len = cyc(raceCfg.len, #CFG_LEN); setupDirty = true
        elseif setupSel == 3 then
            raceCfg.width = cyc(raceCfg.width, #CFG_WIDTH); setupDirty = true
        elseif setupSel == 4 then
            raceCfg.walls = cyc(raceCfg.walls, #CFG_WALLS); setupDirty = true
        elseif setupSel == 5 then
            raceCfg.pads = cyc(raceCfg.pads, #CFG_PADS); setupDirty = true
        elseif setupSel == 6 then
            raceCfg.items = cyc(raceCfg.items, #CFG_ITEMS); setupDirty = true
        elseif setupSel == 7 then
            raceCfg.nbox = cyc(raceCfg.nbox, #CFG_NBOX); setupDirty = true
        end
    end
    local sel = selPressed() or tclick > 0
    -- ITEMS IN PLAY is a sub-screen, not a value row: which items are
    -- enabled is read at pickup time (rollItem), so it never needs a
    -- rebuild and never touches setupDirty.
    if sel and setupSel == 8 then
        itemSel, itemWarnT, raceState = 1, 0, "itemset"
        return
    end
    if pressed(ACT.pause) or (sel and setupSel == 9) then
        if setupDirty then
            applyRaceCfg()
            clearRace(); buildRace(); resetRace()
            setupDirty = false
        end
        menuSel, raceState = 1, "menu"
    end
end

-- ITEMS IN PLAY: Up/Down picks an item, Left/Right or select toggles
-- it. At least one item must stay enabled an empty pool would leave
-- boxes that hand out nothing, which reads as a bug. Use ITEM ROWS =
-- NONE in RACE SETUP to race with no boxes at all.
function tick.itemset(dt)
    if itemWarnT > 0 then itemWarnT = itemWarnT - dt end
    local tdx, tdy, tclick = jet.input.trackball()
    menuDy = menuDy + tdy
    local moved = 0
    if pressed(ACT.up) then moved = -1 end
    if pressed(ACT.down) then moved = 1 end
    if menuDy < -6 then moved = -1; menuDy = 0 end
    if menuDy >  6 then moved = 1;  menuDy = 0 end
    local nRow = #ITEMS + 1
    if moved ~= 0 then itemSel = ((itemSel - 1 + moved) % nRow) + 1 end
    local sel = selPressed() or tclick > 0
    -- Separate ifs, not an `or` chain: pressed() records the key edge as
    -- a side effect, and short-circuiting would skip that record.
    local toggle = false
    if pressed(ACT.left) then toggle = true end
    if pressed(ACT.right) then toggle = true end
    if tdx < -5 or tdx > 5 then toggle = true end
    if sel and itemSel <= #ITEMS then toggle = true end
    if toggle and itemSel <= #ITEMS then
        local it = ITEMS[itemSel]
        if it.on and #itemPool <= 1 then
            itemWarnT = 1.5          -- refuse to empty the pool
        else
            it.on = not it.on
            rebuildItemPool()
        end
    end
    if pressed(ACT.pause) or (sel and itemSel == nRow) then
        setupSel, raceState = 8, "setup"   -- back onto ITEMS IN PLAY
    end
end

-- ITEMS info screen (main menu). Read-only: it shows what every item
-- does and whether it is currently in play.
function tick.items(dt)
    local _, _, tclick = jet.input.trackball()
    -- Locals so every edge is recorded (see selPressed).
    local a = pressed(ACT.pause)
    local b = selPressed()
    if a or b or tclick > 0 then
        menuSel, raceState = 1, "menu"
    end
end

-- The race itself (count / race / done).
local function tickRace(dt)
    if pressed(ACT.pause) then
        pausedFrom, menuSel, raceState = raceState, 1, "pause"
        return
    end
    if pressed(ACT.restart) then clearRace(); buildRace(); resetRace()
        raceState = "count" return end
    flameT = flameT + dt
    if noTgtT > 0 then noTgtT = noTgtT - dt end

    local ranked = rankedRacers()

    if raceState == "count" then
        countT = countT - dt
        if countT <= 0 then raceState = "race" end
    elseif raceState ~= "done" then
        -- Results only when the WHOLE field is home; finished ships run
        -- passive autopilot until then.
        local allHome = true
        for _, rc in ipairs(racers) do
            if not rc.finishT then allHome = false break end
        end
        if allHome then
            raceState = "done"
            -- Session win/loss tally (deliberately no file persistence).
            -- Solo runs are practice: an empty grid is a guaranteed win, so
            -- counting it would inflate the record for free. Left out
            -- entirely, wins + losses always equals races.
            if #racers > 1 then
                stats.races = stats.races + 1
                if ranked[1] == racers[1] then stats.wins = stats.wins + 1
                else stats.losses = stats.losses + 1 end
            end
        end
    end
    if raceState == "race" or raceState == "done" then
        raceT = raceT + dt
    end

    local tdx, _, tclick = jet.input.trackball()

    for i, rc in ipairs(racers) do
        local thrust, turn = false, 0
        if raceState ~= "count" then
            if rc.ai or rc.finishT then
                -- A finished player hands the ship to the passive autopilot
                -- until the rest of the field is home.
                thrust, turn = aiControl(rc, dt, ranked)
            else
                local kt = TURN * rc.st.turn * keySens
                if jet.input.down(ACT.left) then turn = turn - kt end
                if jet.input.down(ACT.right) then turn = turn + kt end
                -- Trackball ROLL (see TRK_ROLL): counts add sustained turn
                -- rate; the rate decays at trkDecay per second. Spinning out
                -- dumps any stored roll.
                local tmax = TURN * rc.st.turn * 2.2
                if rc.spinT > 0 then
                    rc.tbRoll = 0
                else
                    rc.tbRoll = rc.tbRoll
                              + tdx * TRK_ROLL * trkSens * rc.st.turn
                    rc.tbRoll = rc.tbRoll * math.max(0, 1 - trkDecay * dt)
                    rc.tbRoll = math.max(-tmax, math.min(tmax, rc.tbRoll))
                end
                turn = math.max(-tmax, math.min(tmax, turn + rc.tbRoll))
                -- Up doubles as thrust in the race (kart convention), so
                -- one hand can drive from the same cluster it menus with.
                thrust = jet.input.down(ACT.thrust)
                         or jet.input.down(ACT.up)
                if rc.weapon and (pressed(ACT.down) or tclick > 0) then
                    if not fireWeapon(rc, ranked) then noTgtT = 1.2 end
                end
            end
        end
        driveRacer(rc, dt, thrust, turn)
        -- Bank into the ACTUAL smoothed turn rate the same motion the
        -- ship is really making.
        local wb = (rc.grounded and rc.spinT <= 0)
                 and math.max(-26, math.min(26, -rc.turnRate / TURN * 16)) or 0
        rc.bank = rc.bank + (wb - rc.bank) * math.min(1, 10 * dt)
    end

    -- Ship-vs-ship collision: mass-weighted separation the BRICK shoves,
    -- the WASP gets shoved plus a heading nudge away from the contact so
    -- a bump reads as a hit, not two ghosts sliding apart.
    for i = 1, #racers - 1 do
        for j = i + 1, #racers do
            local a, b = racers[i], racers[j]
            local dx, dz = b.px - a.px, b.pz - a.pz
            local d2 = dx * dx + dz * dz
            if d2 > 1 and d2 < 4000 * 4000 then
                local d = math.sqrt(d2)
                local overlap = 4000 - d
                dx, dz = dx / d, dz / d
                local tot = a.st.mass + b.st.mass
                local sa, sb = b.st.mass / tot, a.st.mass / tot
                a.px, a.pz = a.px - dx * overlap * sa, a.pz - dz * overlap * sa
                b.px, b.pz = b.px + dx * overlap * sb, b.pz + dz * overlap * sb
                -- Steer each nose slightly away from the contact; the light
                -- ship takes the bigger deflection.
                local afx, afz = math.sin(a.heading), math.cos(a.heading)
                local aside = (afx * dz - afz * dx) >= 0 and 1 or -1
                local kick = math.min(0.10, overlap * 0.00006)
                a.heading = a.heading + aside * kick * sa * 2
                b.heading = b.heading - aside * kick * sb * 2
                a.speed = a.speed * (1 - 0.03 * sa)
                b.speed = b.speed * (1 - 0.03 * sb)
            end
        end
    end

    -- Respawn timers: only the boxes actually waiting on one. Walking the
    -- whole box list to find them was 288 iterations a frame at EPIC+MANY.
    for i = #deadBoxes, 1, -1 do
        local bx = deadBoxes[i]
        bx.deadT = bx.deadT - dt
        if bx.deadT <= 0 then
            bx.obj:enabled(true)
            table.remove(deadBoxes, i)
        end
    end

    -- Pickup, gated on the ROW: per racer, ONE band
    -- lookup, and the three-box test runs only when that band actually
    -- holds a row. The gate is exact, not an approximation: the pickup
    -- window reaches +-0.5 stations (BOX_ALONG) and the box sits at its
    -- band's MID station, so every position that could collect it lies
    -- within mid+-0.5, comfortably inside the 4-station band. Cost goes
    -- from (boxes x racers) distance tests to (racers) lookups.
    for _, rc in ipairs(racers) do
        -- Finished racers leave the boxes for the field.
        if not rc.weapon and not rc.finishT then
            local row = rowAt[rc.stIdx // BAND]
            if row then
                for _, bx in ipairs(row.box) do
                    if bx.deadT <= 0 then
                        -- Split the offset onto the box station's lane
                        -- normal and its tangent. stN = (-tz, tx)/l, so the
                        -- unit tangent is (nv.z, -nv.x).
                        local dx, dz = rc.px - bx.x, rc.pz - bx.z
                        local nv = stN[bx.st]
                        local lat   = dx * nv.x + dz * nv.z
                        local along = dx * nv.z - dz * nv.x
                        if math.abs(along) < BOX_ALONG
                           and math.abs(lat) < BOX_LAT
                           and math.abs(rc.py - bx.y) < 4000 then
                            rc.weapon = rollItem()
                            bx.deadT = 4
                            bx.obj:enabled(false)
                            deadBoxes[#deadBoxes + 1] = bx
                            break
                        end
                    end
                end
            end
        end
    end

    -- Box spin. ONE angle for every box on the track (they turn in sync --
    -- there is no per-box animation state, and the engine has no shared or
    -- parented transform, so the only per-box cost left is its own
    -- rotation call). Which means the window IS the cost: it is clamped to
    -- what the camera can actually see (see SPIN_AHEAD/SPIN_BEHIND) and
    -- asymmetric, because nearly everything behind the player is off-screen.
    local pst = racers[1].stIdx
    local spinY = math.floor(flameT * 90) % 360
    for _, row in ipairs(itemRows) do
        local d = wrapSt(row.st - pst)
        if d <= SPIN_AHEAD and d >= -SPIN_BEHIND then
            for _, bx in ipairs(row.box) do
                if bx.deadT <= 0 then bx.obj:rotation(0, spinY, 0) end
            end
        end
    end

    -- Shots.
    for si = #shots, 1, -1 do
        local s = shots[si]
        s.ttl = s.ttl - dt
        local dead = s.ttl <= 0
        if not dead and (s.kind == 1 or s.kind == 3) then
            -- Homing shots (zap, rocket) ride the TRACK toward their
            -- target's station rather than flying a straight world line: the
            -- lap folds over itself, so a straight line would pass through
            -- the deck. The rocket is the faster of the two.
            local spd = (s.kind == 3 and 340000 or 200000) / SEGLEN
            local step
            if s.target then
                local d = wrapSt(s.target.stIdx - s.stF)
                step = (d >= 0 and 1 or -1) * spd * dt
                if math.abs(step) > math.abs(d) then step = d end
            else
                -- Fired with no lock: run forward until the short fuse ends.
                -- Nothing to collide with a shot is only targetless when
                -- there was nobody ahead to aim at.
                step = spd * dt
            end
            s.stF = (s.stF + step) % STATIONS
            local x, y, z = stationAt(s.stF)
            s.obj:position(math.floor(x), math.floor(y + 1600), math.floor(z))
            if s.target then
                local dx, dz = s.target.px - x, s.target.pz - z
                if dx * dx + dz * dz < 3400 * 3400 then
                    spinOut(s.target); dead = true
                end
            end
        elseif not dead then
            if s.armT > 0 then s.armT = s.armT - dt end
            s.obj:position(math.floor(s.x), math.floor(s.y), math.floor(s.z))
            for _, rc in ipairs(racers) do
                if s.armT <= 0 or rc ~= s.owner then
                    local dx, dz = rc.px - s.x, rc.pz - s.z
                    if dx * dx + dz * dz < 3000 * 3000
                       and rc.grounded then
                        spinOut(rc); dead = true; break
                    end
                end
            end
        end
        if dead then
            s.obj:enabled(false); s.busy = false
            table.remove(shots, si)
        end
    end

    -- Visuals for every racer.
    for _, rc in ipairs(racers) do
        local fx, fz = math.sin(rc.heading), math.cos(rc.heading)
        local bobY = rc.grounded and (math.sin(flameT * 7 + rc.idx) * 120) or 0
        local pitch = rc.grounded and 0 or 24
        local ry
        if rc.spinT > 0 then
            ry = math.floor(math.deg(rc.heading) + rc.spinA) % 360
        else
            ry = math.floor(math.deg(rc.heading)) % 360
        end
        rc.obj:position(math.floor(rc.px), math.floor(rc.py + bobY),
                        math.floor(rc.pz))
        rc.obj:rotation(pitch, ry, math.floor(rc.bank) % 360)
        rc.flame:position(math.floor(rc.px - fx * 3400),
                          math.floor(rc.py + bobY + 350),
                          math.floor(rc.pz - fz * 3400))
        rc.flame:rotation(0, ry, 0)
        -- Shield bubble: spun fast so it reads as active, and only drawn
        -- while the timer is up.
        if rc.shieldT > 0 then
            rc.shield:enabled(true)
            rc.shield:position(math.floor(rc.px),
                               math.floor(rc.py + bobY - 100),
                               math.floor(rc.pz))
            rc.shield:rotation(0, math.floor(flameT * 420) % 360, 0)
        else
            rc.shield:enabled(false)
        end
        local flen = (rc.boostT > 0 and 1.5 or 0.8)
                   + math.sin(flameT * 31 + rc.idx * 2) * 0.12
        rc.flame:scale(0.8, 0.8, flen)
        -- Hidden through a spin-out: the flame is offset behind the ship
        -- along rc.heading, but a spinning ship is DRAWN at heading+spinA,
        -- so the two separate and the flame orbits on its own. The engine
        -- being out while the pilot fights the spin also reads correctly.
        rc.flame:enabled(rc.speed > 4000 and rc.spinT <= 0)
    end

    -- Player camera with a boost FOV kick. It hangs off the VELOCITY line,
    -- not the nose the nose leads into corners while the camera carries
    -- the momentum arc, which is most of what makes carving read as weight.
    local p = racers[1]
    local fx, fz = math.sin(p.velH), math.cos(p.velH)
    local camd = 21000 + p.speed * 0.045
    local ccx, ccz = p.px - fx * camd, p.pz - fz * camd
    jet.camera.position(ccx, p.py + 8200, ccz)
    jet.camera.lookat(p.px, p.py + 1600, p.pz)
    updateSectorLOD(ccx, ccz)
    jet.camera.fov(70 + math.floor(p.speed / VMAX * 6)
                      + (p.boostT > 0 and 6 or 0))
end
tick.count, tick.race, tick.done = tickRace, tickRace, tickRace

function jet.update(dt)
    -- No quit key here: Quit is a keybind action the firmware swallows
    -- (0xFF), and the main menu's QUIT entry calls jet.quit().
    if dt > 0.25 then dt = 0.25 end
    tick[raceState](dt)
end

-- Per-state draw functions, dispatched exactly like tick.
local draw = {}

function draw.menu()
    drawMenu("SKYLOOPERS", MAIN_MENU)
    jet.text(3, 218, string.format("wins %d   losses %d   races %d",
             stats.wins, stats.losses, stats.races),
             jet.rgb(180, 200, 225))
    jet.text(3, 228, string.format("track seed %d", seed),
             jet.rgb(150, 170, 195))
end

function draw.setup()
    jet.text(102, 30, "RACE SETUP", jet.rgb(255, 230, 120), 2)
    local rows = {
        string.format("opponents     < %s >",
                      raceCfg.npcs == 0 and "SOLO" or raceCfg.npcs),
        string.format("track length  < %s >", CFG_LEN[raceCfg.len][1]),
        string.format("track width   < %s >", CFG_WIDTH[raceCfg.width][1]),
        string.format("walls         < %s >", CFG_WALLS[raceCfg.walls][1]),
        string.format("boost pads    < %s >", CFG_PADS[raceCfg.pads][1]),
        string.format("item rows     < %s >", CFG_ITEMS[raceCfg.items][1]),
        string.format("items per row < %s >", CFG_NBOX[raceCfg.nbox][1]),
        string.format("ITEMS IN PLAY  (%d of %d) >",
                      #itemPool, #ITEMS),
        "BACK",
    }
    for i, e in ipairs(rows) do
        local marker = (i == setupSel) and "> " or "  "
        jet.text(76, 48 + i * 13, marker .. e,
                 (i == setupSel) and jet.rgb(255, 255, 255)
                                  or jet.rgb(170, 190, 215))
    end
    jet.text(28, 184, "up/dn = row   lt/rt = change   pause = apply",
             jet.rgb(150, 170, 195))
end

function draw.itemset()
    jet.text(78, 26, "ITEMS IN PLAY", jet.rgb(255, 230, 120), 2)
    for i, it in ipairs(ITEMS) do
        local on = it.on
        local marker = (i == itemSel) and "> " or "  "
        local col = (i == itemSel) and jet.rgb(255, 255, 255)
                                   or jet.rgb(170, 190, 215)
        jet.text(84, 42 + i * 16, marker .. it.name, col)
        jet.text(180, 42 + i * 16, on and "ON" or "off",
                 on and jet.rgb(120, 255, 140) or jet.rgb(150, 120, 120))
    end
    local nRow = #ITEMS + 1
    jet.text(84, 42 + nRow * 16, ((itemSel == nRow) and "> " or "  ")
             .. "BACK",
             (itemSel == nRow) and jet.rgb(255, 255, 255)
                                or jet.rgb(170, 190, 215))
    if itemWarnT > 0 then
        jet.text(66, 152, "at least one item must stay on",
                 jet.rgb(255, 170, 60))
    end
    jet.text(31, 172, "up/dn = row   lt/rt = toggle   pause = back",
             jet.rgb(150, 170, 195))
    jet.text(40, 184, "no boxes at all: set ITEM ROWS to NONE",
             jet.rgb(130, 150, 175))
end

function draw.items()
    jet.text(122, 22, "ITEMS", jet.rgb(255, 230, 120), 2)
    for i, it in ipairs(ITEMS) do
        local y = 44 + (i - 1) * 26
        jet.text(10, y, it.name, jet.rgb(255, 230, 120))
        if not it.on then
            jet.text(10, y + 11, "(off)", jet.rgb(160, 120, 120))
        end
        jet.text(74, y, it.d1, jet.rgb(225, 235, 245))
        jet.text(74, y + 11, it.d2, jet.rgb(150, 170, 195))
    end
    jet.text(50, 182, "one item at a time - down launches it",
             jet.rgb(180, 200, 225))
    jet.text(74, 196, "boxes respawn 4s after pickup",
             jet.rgb(150, 170, 195))
    jet.text(100, 214, "pause = back", jet.rgb(200, 220, 255))
end

function draw.pause()
    drawMenu("PAUSED", PAUSE_MENU)
end

function draw.settings()
    jet.text(112, 30, "SETTINGS", jet.rgb(255, 230, 120), 2)
    -- Action names, not keys: which key does what is set on the
    -- LAUNCHER's Controls screen (lib/keybind), before launch.
    jet.text(64, 58,  "thrust or up   accelerate", jet.rgb(200, 215, 235))
    jet.text(64, 68,  "left/right + trackball  steer",
             jet.rgb(200, 215, 235))
    jet.text(64, 78,  "down   launch item",        jet.rgb(200, 215, 235))
    jet.text(64, 88,  "pause  pause menu",         jet.rgb(200, 215, 235))
    local rows = {
        string.format("trackball roll  < %.1f >", trkSens),
        string.format("roll decay      < %.1f >", trkDecay),
        string.format("keys sens       < %.1f >", keySens),
        string.format("fps readout     < %s >", showFps and "ON" or "OFF"),
        "BACK",
    }
    for i, e in ipairs(rows) do
        local marker = (i == ctlSel) and "> " or "  "
        jet.text(84, 108 + i * 12, marker .. e,
                 (i == ctlSel) and jet.rgb(255, 255, 255)
                                or jet.rgb(170, 190, 215))
    end
    -- Clear of the BACK row: the last row sits at 108 + 5*12 = 168.
    jet.text(31, 190, "up/dn = row   lt/rt = adjust   pause = back",
             jet.rgb(150, 170, 195))
end

function draw.select()
    local st = SHIP_TYPES[selType]
    local function bar(v)
        return string.rep("#", math.floor(v * 5 + 0.5))
    end
    jet.text(104, 30, "SELECT SHIP", jet.rgb(255, 230, 120), 2)
    -- Markers are drawn beside the rows, not prefixed, so the centred
    -- text does not shift as the cursor moves.
    if selRow == 1 then jet.text(120, 150, ">", jet.rgb(255, 255, 255)) end
    jet.text(136, 150, "< " .. st.name .. " >",
             (selRow == 1) and jet.rgb(255, 255, 255)
                            or jet.rgb(170, 190, 215))
    jet.text(112, 164, string.format("top   %-8s", bar(st.top)),
             jet.rgb(180, 220, 255))
    jet.text(112, 174, string.format("accel %-8s", bar(st.accel)),
             jet.rgb(180, 220, 255))
    jet.text(112, 184, string.format("turn  %-8s", bar(st.turn)),
             jet.rgb(180, 220, 255))
    jet.text(112, 194, string.format("mass  %-8s", bar(st.mass)),
             jet.rgb(180, 220, 255))
    if selRow == 2 then jet.text(120, 206, ">", jet.rgb(255, 255, 255)) end
    jet.text(136, 206, "BACK",
             (selRow == 2) and jet.rgb(255, 255, 255)
                            or jet.rgb(170, 190, 215))
    jet.text(28, 222, "lt/rt = ship   up/dn = row   thrust = select",
             jet.rgb(150, 170, 195))
end

-- Race HUD (count / race / done).
local function drawRace()
    local p = racers[1]
    local ranked = rankedRacers()
    local pos = 1
    for i, r in ipairs(ranked) do if r == p then pos = i end end

    jet.text(3, 3, string.format("%3d km/h", math.floor(p.speed * 0.0036)),
             jet.rgb(255, 255, 255))
    jet.text(3, 14, (#racers > 1)
             and string.format("pos %d/%d  lap %d/3", pos, #racers,
                               math.min(p.lap + 1, 3))
             or string.format("lap %d/3", math.min(p.lap + 1, 3)),
             jet.rgb(255, 255, 255))
    jet.text(3, 25, p.weapon and ("item: " .. ITEMS[p.weapon].name)
             or "item: -", jet.rgb(255, 230, 120))
    if p.shieldT > 0 then
        jet.text(3, 36, string.format("shield %.1f", p.shieldT),
                 jet.rgb(150, 240, 255))
    end
    if noTgtT > 0 then
        jet.text(3, 47, "no target ahead", jet.rgb(255, 170, 60))
    end

    if raceState == "count" then
        jet.text(150, 80, tostring(math.max(1, math.ceil(countT))),
                 jet.rgb(255, 255, 255), 3)
    elseif raceState == "race" and raceT < 0.9 then
        jet.text(140, 80, "GO", jet.rgb(120, 255, 120), 3)
    elseif raceState == "done" then
        jet.text(96, 70, (#racers > 1) and "FINISH" or "SOLO RUN",
                 jet.rgb(255, 230, 120), 3)
        for i, r in ipairs(ranked) do
            local nm = (r == p) and "YOU" or r.st.name
            local tm = r.finishT and string.format("%.1fs", r.finishT) or "--"
            jet.text(110, 100 + i * 12,
                     string.format("%d. %-5s %s", i, nm, tm),
                     jet.rgb(255, 255, 255))
        end
        local hintY = 100 + (#ranked + 1) * 12 + 4
        jet.text(84, hintY, (#racers > 1)
                 and string.format("wins %d  losses %d  races %d",
                                   stats.wins, stats.losses, stats.races)
                 or "practice run - record unchanged",
                 jet.rgb(180, 200, 225))
        jet.text(64, hintY + 12, "restart = new race   pause = menu",
                 jet.rgb(200, 220, 255))
    elseif p.finishT then
        jet.text(96, 60, "FINISHED", jet.rgb(120, 255, 120), 2)
        jet.text(96, 80, "waiting for the field...", jet.rgb(200, 220, 255))
    elseif not p.grounded then
        jet.text(130, 60, "OFF TRACK", jet.rgb(255, 80, 60))
    elseif p.wrongT > 0.6 then
        -- Flash it: visible even against busy track colours.
        if math.floor(p.wrongT * 4) % 2 == 0 then
            jet.text(112, 60, "WRONG WAY", jet.rgb(255, 80, 60), 2)
        end
    end
end
draw.count, draw.race, draw.done = drawRace, drawRace, drawRace

function jet.draw()
    -- FPS, top-right, in every state -- the SETTINGS toggle.
    if showFps then
        jet.text(282, 3, string.format("%2d fps", math.floor(jet.timer.fps())),
                 jet.rgb(180, 200, 220))
    end
    draw[raceState]()
end

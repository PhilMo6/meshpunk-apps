-- MeshCore — LoRa mesh network: night-ops map, teal signal traces, node links
-- and radio ripples around the repeaters.
return {
    name = "MeshCore",
    apply = function(t)
        t.set_palette {
            scr      = "#071019",  -- deep night map
            card     = "#0f1d2b",  -- panel / raised surface
            text     = "#cfeaf2",  -- pale signal readout
            grey     = "#1c3242",  -- inactive traces
            accent   = "#19c3b1",  -- mesh teal
            btn_text = "#eafffb",
            dark     = true,
        }

        t.background.procedural(function(c, w, h)

            local function circle(x, y, r, col, opa)
                c:draw_rect({
                    x1 = x - r, y1 = y - r,
                    x2 = x + r, y2 = y + r,
                    radius = r,
                    bg_color = col,
                    bg_opa = opa or 255,
                })
            end

            ----------------------------------------------------------
            -- NIGHT SKY BASE (subtle vertical falloff, darker at top)
            ----------------------------------------------------------
            local bands = 24
            for i = 0, bands - 1 do
                local f = i / (bands - 1)
                c:draw_rect({
                    x1 = 0,
                    y1 = math.floor(i * h / bands),
                    x2 = w,
                    y2 = math.floor((i + 1) * h / bands),
                    bg_color = t.hsv(200 + 8 * f, 0.55, 0.07 + 0.05 * f),
                    bg_opa = 255,
                })
            end

            ----------------------------------------------------------
            -- FAINT MAP GRID (coordinates under the mesh)
            ----------------------------------------------------------
            local grid = 32
            for x = 0, w, grid do
                c:draw_line({
                    p1 = { x = x, y = 0 }, p2 = { x = x, y = h },
                    color = "#12283a", width = 1, opa = 70,
                })
            end
            for y = 0, h, grid do
                c:draw_line({
                    p1 = { x = 0, y = y }, p2 = { x = w, y = y },
                    color = "#12283a", width = 1, opa = 70,
                })
            end

            ----------------------------------------------------------
            -- NODES (companions + a few tall repeaters)
            ----------------------------------------------------------
            local nodes = {}
            for i = 1, 14 do
                nodes[i] = {
                    x = math.random(math.floor(w * 0.06), math.floor(w * 0.94)),
                    y = math.random(math.floor(h * 0.08), math.floor(h * 0.92)),
                    repeater = (i <= 3),   -- first three are repeaters
                }
            end

            ----------------------------------------------------------
            -- LINKS (connect each node to its nearest neighbours)
            ----------------------------------------------------------
            local links = {}
            for i = 1, #nodes do
                local a = nodes[i]
                -- nearest two neighbours by squared distance
                local best, best2
                for j = 1, #nodes do
                    if j ~= i then
                        local b = nodes[j]
                        local d = (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2
                        if not best or d < best.d then
                            best2 = best
                            best = { j = j, d = d }
                        elseif not best2 or d < best2.d then
                            best2 = { j = j, d = d }
                        end
                    end
                end
                for _, pick in ipairs({ best, best2 }) do
                    if pick then
                        local lo, hi = math.min(i, pick.j), math.max(i, pick.j)
                        links[lo .. "-" .. hi] = { a = nodes[lo], b = nodes[hi] }
                    end
                end
            end

            for _, l in pairs(links) do
                c:draw_line({
                    p1 = { x = l.a.x, y = l.a.y },
                    p2 = { x = l.b.x, y = l.b.y },
                    color = "#19c3b1", width = 1, opa = 90,
                })
            end

            ----------------------------------------------------------
            -- RADIO RIPPLES (dotted rings around the repeaters)
            ----------------------------------------------------------
            for _, n in ipairs(nodes) do
                if n.repeater then
                    for ring = 1, 3 do
                        local r = 14 + ring * 12
                        local dots = 10 + ring * 6
                        local opa = 150 - ring * 40
                        for d = 0, dots - 1 do
                            local ang = (d / dots) * 2 * math.pi
                            circle(
                                n.x + r * math.cos(ang),
                                n.y + r * math.sin(ang),
                                1, "#2de2e6", opa)
                        end
                    end
                end
            end

            ----------------------------------------------------------
            -- PACKETS IN FLIGHT (bright dots along a few links)
            ----------------------------------------------------------
            local flat = {}
            for _, l in pairs(links) do flat[#flat + 1] = l end
            for i = 1, math.min(10, #flat) do
                local l = flat[math.random(#flat)]
                local f = math.random()
                circle(
                    l.a.x + (l.b.x - l.a.x) * f,
                    l.a.y + (l.b.y - l.a.y) * f,
                    2, "#eafffb", 200)
            end

            ----------------------------------------------------------
            -- NODE MARKERS (drawn last, above links + ripples)
            ----------------------------------------------------------
            for _, n in ipairs(nodes) do
                if n.repeater then
                    circle(n.x, n.y, 5, "#0f1d2b", 255)   -- socket
                    circle(n.x, n.y, 4, "#2de2e6", 255)   -- repeater core
                else
                    circle(n.x, n.y, 3, "#19c3b1", 230)
                end
            end

            ----------------------------------------------------------
            -- EDGE VIGNETTE
            ----------------------------------------------------------
            local e = 16
            c:draw_rect({ x1 = 0, y1 = 0, x2 = w, y2 = e, bg_color = "#000000", bg_opa = 70 })
            c:draw_rect({ x1 = 0, y1 = h - e, x2 = w, y2 = h, bg_color = "#000000", bg_opa = 70 })
            c:draw_rect({ x1 = 0, y1 = 0, x2 = e, y2 = h, bg_color = "#000000", bg_opa = 70 })
            c:draw_rect({ x1 = w - e, y1 = 0, x2 = w, y2 = h, bg_color = "#000000", bg_opa = 70 })
        end)
    end,
}

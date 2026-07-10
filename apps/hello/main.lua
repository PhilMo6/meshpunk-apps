--[[
  Hello — minimal App Store test app.
  Demonstrates the smallest possible Meshpunk app that follows the app
  manager contract (apps.new_root once, apps.go_home to exit).
]]

local lvgl = require("lvgl")
local apps = require("lib/apps")

local W = lvgl.HOR_RES()
local H = lvgl.VER_RES()

local root = apps.new_root()
root:set {
    w = W, h = H,
    bg_color = "#111111", bg_opa = 255,
    pad_all = 0, border_width = 0,
}
root:clear_flag(lvgl.FLAG.SCROLLABLE)

root:Label {
    text = "Hello from the App Store!",
    text_color = "#FFFFFF",
    align = lvgl.ALIGN.CENTER,
}

local quit = root:Button { w = 120, h = 32, align = lvgl.ALIGN.BOTTOM_MID, y = -20 }
quit:Label { text = "Quit", align = lvgl.ALIGN.CENTER }
quit:onClicked(function()
    apps.go_home()
end)

return root

package.path = "desktop-sim/?.lua;lua/?.lua;" .. package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

require("premium_now_playing_screen").create {
    background = "/desktop-sim/generated/now-playing-background.png",
    cover = "/desktop-sim/generated/now-playing-cover.png",
    title = "Midnight Circuit (Extended Mix)",
    artist = "Example Artist",
    progress = 0.368,
    elapsed = "1:21",
    remaining = "-2:17",
}

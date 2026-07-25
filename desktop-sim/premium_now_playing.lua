package.path = "desktop-sim/?.lua;lua/?.lua;" .. package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local tracks = {
    {
        title = "Midnight Circuit (Extended Mix)",
        artist = "Example Artist",
        progress = 0.368,
        elapsed = "1:21",
        remaining = "-2:17",
    },
    {
        title = "Afterglow",
        artist = "Example Artist",
        progress = 0.610,
        elapsed = "1:58",
        remaining = "-1:16",
    },
    {
        title = "Homebound Across the Endless Skyline",
        artist = "Second Artist",
        progress = 0.220,
        elapsed = "0:53",
        remaining = "-3:08",
    },
}

local current = 1

local screen = require("premium_now_playing_screen").create {
    background = "/desktop-sim/generated/now-playing-background.png",
    cover = "/desktop-sim/generated/now-playing-cover.png",
    title = tracks[current].title,
    artist = tracks[current].artist,
    progress = tracks[current].progress,
    elapsed = tracks[current].elapsed,
    remaining = tracks[current].remaining,
}

local hitbox = screen.root:Object {
    x = 0,
    y = 0,
    w = 160,
    h = 128,
    border_width = 0,
    bg_opa = 0,
}

hitbox:onClicked(function()
    current = current + 1

    if current > #tracks then
        current = 1
    end

    screen:update(tracks[current])
end)

package.path = "desktop-sim/?.lua;lua/?.lua;" .. package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local root = lvgl.Object()

root:set {
    x = 0,
    y = 0,
    w = 160,
    h = 128,
    pad_all = 0,
    border_width = 0,
    radius = 0,
    bg_color = "#020307",
    scrollbar_mode = lvgl.SCROLLBAR_MODE.OFF,
}

root:Image {
    x = 0,
    y = 0,
    src = lvgl.ImgData("/desktop-sim/generated/now-playing-background.png"),
}

root:Image {
    x = 47,
    y = 2,
    src = lvgl.ImgData("/desktop-sim/generated/now-playing-cover.png"),
}

local title = root:Label {
    x = 6,
    y = 72,
    w = 148,
    h = 15,
    text = "Midnight Circuit (Extended Mix)",
    text_color = "#FFFFFF",
    text_align = 1,
}

title:set {
}

title:set {
    long_mode = 2,
}

root:Label {
    x = 6,
    y = 88,
    w = 148,
    h = 13,
    text = "Example Artist",
    text_color = "#B5B6C0",
    text_align = 1,
    long_mode = 4,
}

local progress = root:Object {
    x = 8,
    y = 106,
    w = 144,
    h = 3,
    radius = 2,
    border_width = 0,
    bg_color = "#555762",
}

progress:Object {
    x = 0,
    y = 0,
    w = 53,
    h = 3,
    radius = 2,
    border_width = 0,
    bg_color = "#F4F4F7",
}

root:Label {
    x = 8,
    y = 113,
    w = 35,
    text = "1:21",
    text_color = "#B7B8C1",
}

root:Label {
    x = 117,
    y = 113,
    w = 35,
    text = "-2:17",
    text_color = "#B7B8C1",
    text_align = 2,
}

local lvgl = require("lvgl")

local root = lvgl.Object()

root:set {
    w = lvgl.HOR_RES(),
    h = lvgl.VER_RES(),
    bg_color = "#10131A",
    pad_all = 0,
}

root:Label {
    text = "Tangara",
    align = {
        type = lvgl.ALIGN.TOP_MID,
        x_ofs = 0,
        y_ofs = 12,
    },
}

root:Label {
    text = "Lua + LVGL works",
    align = {
        type = lvgl.ALIGN.CENTER,
        x_ofs = 0,
        y_ofs = 0,
    },
}

root:Label {
    text = "160 x 128",
    align = {
        type = lvgl.ALIGN.BOTTOM_MID,
        x_ofs = 0,
        y_ofs = -12,
    },
}

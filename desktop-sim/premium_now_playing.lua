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

local title_view = root:Object {
    x = 6,
    y = 72,
    w = 148,
    h = 15,
    pad_all = 0,
    border_width = 0,
    radius = 0,
    bg_opa = 0,
    scrollbar_mode = lvgl.SCROLLBAR_MODE.OFF,
}

title_view:clear_flag(lvgl.FLAG.SCROLLABLE)

local title = title_view:Label {
    x = 0,
    y = 0,
    text = "Midnight Circuit (Extended Mix)",
    text_color = "#FFFFFF",
}

local function wait_ms(ms, callback)
    lvgl.Timer {
        period = ms,
        repeat_count = 1,
        cb = function(timer)
            timer:delete()
            callback()
        end,
    }
end

local function start_marquee()
    local coords = title:get_coords()
    local text_width = coords.x2 - coords.x1 + 1
    local overflow = text_width - 148

    if overflow <= 0 then
        title:set {
            x = math.floor((148 - text_width) / 2),
        }
        return
    end

    local duration = math.max(
        2800,
        math.floor(overflow * 40)
    )

    local forward
    local backward

    forward = function()
        title:Anim {
            run = true,
            start_value = 0,
            end_value = -overflow,
            duration = duration,
            path = "linear",
            exec_cb = function(obj, value)
                obj:set {
                    x = value,
                }
            end,
            done_cb = function(anim)
                anim:delete()
                wait_ms(2000, backward)
            end,
        }
    end

    backward = function()
        title:Anim {
            run = true,
            start_value = -overflow,
            end_value = 0,
            duration = duration,
            path = "linear",
            exec_cb = function(obj, value)
                obj:set {
                    x = value,
                }
            end,
            done_cb = function(anim)
                anim:delete()
                wait_ms(2000, forward)
            end,
        }
    end

    wait_ms(2000, forward)
end

lvgl.Timer {
    period = 50,
    repeat_count = 1,
    cb = function(timer)
        timer:delete()
        start_marquee()
    end,
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

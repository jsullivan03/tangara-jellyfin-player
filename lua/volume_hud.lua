local alerts = require("alerts")
local controls = require("controls")
local lvgl = require("lvgl")

local M = {}

local function clamp_percentage(value)
    value = tonumber(value) or 0

    return math.max(
        0,
        math.min(100, value)
    )
end

function M.geometry(percentage)
    percentage =
        clamp_percentage(percentage)

    local inner_height = 52
    local fill_height =
        math.floor(
            inner_height *
                percentage / 100 +
                0.5
        )

    return {
        percentage = percentage,
        x = 150,
        y = 34,
        width = 7,
        height = 58,
        fill_x = 2,
        fill_y = 3 +
            inner_height -
            fill_height,
        fill_width = 3,
        fill_height = fill_height,
        fill_opacity =
            fill_height > 0 and
            255 or 0,
    }
end

function M.show(percentage)
    if controls.lock_switch:get() then
        return false
    end

    local geometry =
        M.geometry(percentage)

    alerts.show(function()
        local capsule =
            lvgl.Object(
                nil,
                {
                    x = geometry.x,
                    y = geometry.y,
                    w = geometry.width,
                    h = geometry.height,
                    pad_all = 0,
                    border_width = 0,
                    radius = 4,
                    bg_color = "#11131A",
                    bg_opa = 180,
                    scrollbar_mode =
                        lvgl.SCROLLBAR_MODE.OFF,
                }
            )

        capsule:clear_flag(
            lvgl.FLAG.SCROLLABLE
        )

        capsule:Object {
            x = geometry.fill_x,
            y = geometry.fill_y,
            w = geometry.fill_width,
            h = math.max(
                1,
                geometry.fill_height
            ),
            pad_all = 0,
            border_width = 0,
            radius = 2,
            bg_color = "#FFFFFF",
            bg_opa =
                geometry.fill_opacity,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }
    end)

    return true
end

return M

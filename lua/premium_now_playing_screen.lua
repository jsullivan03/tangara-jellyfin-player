local lvgl = require("lvgl")
local jellyfin_marquee =
    require("jellyfin_marquee")

local M = {}

function M.create(options)
    options = options or {}

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
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
    }

    local background = root:Image {
        x = 0,
        y = -16,
        src =
            lvgl.ImgData(
                options.background
            ),
    }

    local background_dimmer =
        root:Object {
            x = 0,
            y = 0,
            w = 160,
            h = 128,
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_color = "#000000",
            bg_opa = 90,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    background_dimmer:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )

    local cover = root:Image {
        x = 47,
        y = 16,
        src =
            lvgl.ImgData(
                options.cover
            ),
    }

    local title_marquee =
        jellyfin_marquee.create(
            root,
            {
                x = 6,
                y = 83,
                w = 148,
                h = 12,
                text = "",
                align = "center",
                text_color = "#FFFFFF",
                autostart = true,
            }
        )

    local artist_marquee =
        jellyfin_marquee.create(
            root,
            {
                x = 6,
                y = 95,
                w = 148,
                h = 12,
                text = "",
                align = "center",
                text_color = "#B5B6C0",
                autostart = true,
            }
        )

    local elapsed = root:Label {
        x = 8,
        y = 111,
        w = 35,
        text = "0:00",
        text_color = "#B7B8C1",
    }

    local remaining = root:Label {
        x = 117,
        y = 111,
        w = 35,
        text = "0:00",
        text_color = "#B7B8C1",
        text_align = 3,
    }

    local progress = root:Object {
        x = 8,
        y = 124,
        w = 144,
        h = 3,
        radius = 2,
        border_width = 0,
        bg_color = "#555762",
    }

    local progress_fill =
        progress:Object {
            x = 0,
            y = 0,
            w = 0,
            h = 3,
            radius = 2,
            border_width = 0,
            bg_color = "#F4F4F7",
        }

    local status_bar = root:Object {
        x = 0,
        y = 0,
        w = 160,
        h = 13,
        pad_all = 0,
        border_width = 0,
        radius = 0,
        bg_color = "#05060A",
        bg_opa = 135,
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
    }

    status_bar:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )

    local connection_container =
        status_bar:Object {
            x = 0,
            y = 0,
            w = 18,
            h = 13,
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_opa = 0,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    connection_container:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )

    local connection_ring =
        connection_container:Object {
            x = 5,
            y = 3,
            w = 7,
            h = 7,
            pad_all = 0,
            border_width = 1,
            border_color = "#8A8C93",
            radius = 4,
            bg_opa = 0,
        }

    local connection_dot =
        connection_ring:Object {
            x = 2,
            y = 2,
            w = 3,
            h = 3,
            pad_all = 0,
            border_width = 0,
            radius = 2,
            bg_color = "#8FB9A8",
            bg_opa = 0,
        }

    local clock = status_bar:Label {
        x = 56,
        y = 2,
        w = 48,
        text = "--:--",
        text_align = 2,
        text_color = "#D4D5DA",
        text_font = font.fusion_10,
    }

    local battery = status_bar:Object {
        x = 139,
        y = 3,
        w = 17,
        h = 8,
        pad_all = 0,
        border_width = 0,
        radius = 0,
        bg_opa = 0,
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
    }

    battery:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )

    local battery_body =
        battery:Object {
            x = 0,
            y = 0,
            w = 14,
            h = 8,
            pad_all = 0,
            border_width = 1,
            border_color = "#D4D5DA",
            radius = 2,
            bg_opa = 0,
        }

    local battery_segments = {}

    for index = 1, 4 do
        battery_segments[index] =
            battery_body:Object {
                x = 1 + (
                    index - 1
                ) * 3,
                y = 2,
                w = 2,
                h = 4,
                pad_all = 0,
                border_width = 0,
                radius = 0,
                bg_color = "#4E5058",
                bg_opa = 190,
            }
    end

    local battery_terminal =
        battery:Object {
            x = 14,
            y = 2,
            w = 2,
            h = 4,
            pad_all = 0,
            border_width = 0,
            radius = 1,
            bg_color = "#D4D5DA",
            bg_opa = 255,
        }

    local battery_percentage =
        tonumber(
            options.battery_pct
        ) or 0

    local battery_charging =
        options.charging == true

    local function update_battery()
        local percentage =
            math.max(
                0,
                math.min(
                    100,
                    battery_percentage
                )
            )

        local active_segments = 0

        if percentage > 0 then
            active_segments =
                math.ceil(
                    percentage / 25
                )
        end

        local active_color =
            "#D4D5DA"

        if battery_charging then
            active_color =
                "#74C991"
        elseif percentage <= 10 then
            active_color =
                "#E06666"
        end

        battery_body:set {
            border_color =
                active_color,
        }

        battery_terminal:set {
            bg_color =
                active_color,
        }

        for index, segment in ipairs(
            battery_segments
        ) do
            segment:set {
                bg_color =
                    index <=
                        active_segments and
                    active_color or
                    "#4E5058",
                bg_opa =
                    index <=
                        active_segments and
                    255 or
                    190,
            }
        end
    end

    pcall(
        function()
            lvgl.group.remove_obj(
                status_bar
            )
            lvgl.group.remove_obj(
                connection_container
            )
            lvgl.group.remove_obj(
                connection_ring
            )
            lvgl.group.remove_obj(
                connection_dot
            )
            lvgl.group.remove_obj(clock)
            lvgl.group.remove_obj(battery)
        end
    )

    local screen = {
        root = root,
    }

    function screen:update(values)
        values = values or {}

        if values.background then
            background:set {
                src =
                    lvgl.ImgData(
                        values.background
                    ),
            }
        end

        if values.cover then
            cover:set {
                src =
                    lvgl.ImgData(
                        values.cover
                    ),
            }
        end

        if values.title ~= nil then
            title_marquee:set(
                values.title
            )
            title_marquee:start()
        end

        if values.artist ~= nil then
            artist_marquee:set(
                values.artist
            )
            artist_marquee:start()
        end

        if values.progress ~= nil then
            local amount =
                math.max(
                    0,
                    math.min(
                        1,
                        values.progress
                    )
                )

            progress_fill:set {
                w =
                    math.floor(
                        144 * amount
                    ),
            }
        end

        if values.elapsed ~= nil then
            elapsed:set {
                text = values.elapsed,
            }
        end

        if values.remaining ~= nil then
            remaining:set {
                text = values.remaining,
            }
        end

        if values.clock ~= nil then
            clock:set {
                text = values.clock,
            }
        end

        if values.connected ~= nil then
            connection_ring:set {
                border_color =
                    values.connected and
                    "#8FB9A8" or
                    "#8A8C93",
            }

            connection_dot:set {
                bg_opa =
                    values.connected and
                    255 or
                    0,
            }
        end

        if values.battery_pct ~= nil then
            battery_percentage =
                tonumber(
                    values.battery_pct
                ) or 0
        end

        if values.charging ~= nil then
            battery_charging =
                values.charging == true
        end

        if values.battery_pct ~= nil or
            values.charging ~= nil then
            update_battery()
        end
    end

    screen:update(options)
    update_battery()

    return screen
end

return M

local lvgl = require("lvgl")
local jellyfin_marquee =
    require("jellyfin_marquee")

local M = {}

local function animate_y(
    object,
    start_y,
    end_y
)
    object:set {
        y = start_y,
    }

    object:Anim {
        run = true,
        start_value = start_y,
        end_value = end_y,
        duration = 150,
        path = "linear",
        exec_cb =
            function(
                animated_object,
                position
            )
                animated_object:set {
                    y = position,
                }
            end,
    }
end

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

    local pause_icon = root:Object {
        x = 76,
        y = 116,
        w = 8,
        h = 10,
        pad_all = 0,
        border_width = 0,
        radius = 0,
        bg_opa = 0,
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
    }

    pause_icon:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    pause_icon:add_flag(
        lvgl.FLAG.HIDDEN
    )

    pause_icon:Object {
        x = 0,
        y = 1,
        w = 2,
        h = 8,
        radius = 1,
        border_width = 0,
        bg_color = "#F4F4F7",
    }

    pause_icon:Object {
        x = 5,
        y = 1,
        w = 2,
        h = 8,
        radius = 1,
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

    local paused = nil
    local layout_ready = false
    local target_time_y = 111
    local target_progress_y = 124
    local pause_icon_generation = 0
    local pause_icon_pending = false

    local function hide_pause_icon()
        pause_icon:add_flag(
            lvgl.FLAG.HIDDEN
        )
    end

    local function show_pause_icon()
        pause_icon:clear_flag(
            lvgl.FLAG.HIDDEN
        )
    end

    local function schedule_pause_icon()
        pause_icon_generation =
            pause_icon_generation + 1

        local generation =
            pause_icon_generation

        pause_icon_pending = true
        hide_pause_icon()

        lvgl.Timer {
            period = 105,
            repeat_count = 1,
            cb = function()
                if paused == true and
                    generation ==
                        pause_icon_generation then
                    pause_icon_pending = false
                    show_pause_icon()
                end
            end,
        }
    end

    local function set_paused(
        next_paused,
        animated
    )
        next_paused = next_paused == true

        if paused == next_paused then
            return
        end

        local start_time_y =
            paused and 116 or 111
        local start_progress_y =
            paused and 128 or 124

        paused = next_paused
        target_time_y =
            paused and 116 or 111
        target_progress_y =
            paused and 128 or 124

        pause_icon_generation =
            pause_icon_generation + 1
        pause_icon_pending = false
        hide_pause_icon()

        if animated then
            animate_y(
                elapsed,
                start_time_y,
                target_time_y
            )
            animate_y(
                remaining,
                start_time_y,
                target_time_y
            )
            animate_y(
                progress,
                start_progress_y,
                target_progress_y
            )
        else
            elapsed:set {
                y = target_time_y,
            }
            remaining:set {
                y = target_time_y,
            }
            progress:set {
                y = target_progress_y,
            }
        end

        if paused then
            if animated then
                schedule_pause_icon()
            else
                show_pause_icon()
            end
        end
    end

    function screen:layout_state()
        return {
            paused = paused == true,
            elapsed_y = target_time_y,
            remaining_y = target_time_y,
            progress_y = target_progress_y,
            pause_icon_visible =
                paused == true and
                pause_icon_pending ~= true,
            pause_icon_pending =
                pause_icon_pending == true,
            pause_icon_delay_ms = 105,
        }
    end

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

        if values.paused ~= nil then
            set_paused(
                values.paused,
                layout_ready
            )
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

    if paused == nil then
        set_paused(false, false)
    end

    layout_ready = true
    update_battery()

    return screen
end

return M

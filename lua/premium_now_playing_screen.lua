local lvgl = require("lvgl")

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
        scrollbar_mode = lvgl.SCROLLBAR_MODE.OFF,
    }

    local background = root:Image {
        x = 0,
        y = 0,
        src = lvgl.ImgData(options.background),
    }

    local cover = root:Image {
        x = 47,
        y = 2,
        src = lvgl.ImgData(options.cover),
    }

    local artist_view = root:Object {
        x = 6,
        y = 88,
        w = 148,
        h = 13,
        pad_all = 0,
        border_width = 0,
        radius = 0,
        bg_opa = 0,
        scrollbar_mode = lvgl.SCROLLBAR_MODE.OFF,
    }

    artist_view:clear_flag(lvgl.FLAG.SCROLLABLE)

    local artist = artist_view:Label {
        x = 0,
        y = 0,
        text = "",
        text_color = "#B5B6C0",
    }

    local artist_id = 0

    local function set_artist(value)
        artist_id = artist_id + 1
        local id = artist_id

        artist:set {
            text = value or "",
            x = 0,
            text_opa = 0,
        }

        lvgl.Timer {
            period = 50,
            repeat_count = 1,
            cb = function(timer)
                timer:delete()

                if id ~= artist_id then
                    return
                end

                local coords = artist:get_coords()
                local width = coords.x2 - coords.x1 + 1

                artist:set {
                    x = math.max(0, math.floor((148 - width) / 2)),
                    text_opa = 255,
                }
            end,
        }
    end

    local progress = root:Object {
        x = 8,
        y = 106,
        w = 144,
        h = 3,
        radius = 2,
        border_width = 0,
        bg_color = "#555762",
    }

    local progress_fill = progress:Object {
        x = 0,
        y = 0,
        w = 0,
        h = 3,
        radius = 2,
        border_width = 0,
        bg_color = "#F4F4F7",
    }

    local elapsed = root:Label {
        x = 8,
        y = 113,
        w = 35,
        text = "0:00",
        text_color = "#B7B8C1",
    }

    local remaining = root:Label {
        x = 117,
        y = 113,
        w = 35,
        text = "-0:00",
        text_color = "#B7B8C1",
        text_align = 2,
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
        text = "",
        text_color = "#FFFFFF",
    }

    local marquee_id = 0

    local function wait_ms(ms, id, callback)
        lvgl.Timer {
            period = ms,
            repeat_count = 1,
            cb = function(timer)
                timer:delete()

                if id == marquee_id then
                    callback()
                end
            end,
        }
    end

    local function set_title(value)
        marquee_id = marquee_id + 1
        local id = marquee_id

        title:set {
            text = value or "",
            x = 0,
            text_opa = 0,
        }

        lvgl.Timer {
            period = 50,
            repeat_count = 1,
            cb = function(timer)
                timer:delete()

                if id ~= marquee_id then
                    return
                end

                local coords = title:get_coords()
                local text_width = coords.x2 - coords.x1 + 1
                local overflow = text_width - 148

                if overflow <= 0 then
                    title:set {
                        x = math.floor((148 - text_width) / 2),
                        text_opa = 255,
                    }
                    return
                end

                title:set {
                    x = 0,
                    text_opa = 255,
                }

                local duration = math.max(
                    2800,
                    math.floor(overflow * 40)
                )

                local forward
                local backward

                forward = function()
                    if id ~= marquee_id then
                        return
                    end

                    title:Anim {
                        run = true,
                        start_value = 0,
                        end_value = -overflow,
                        duration = duration,
                        path = "linear",
                        exec_cb = function(obj, position)
                            if id == marquee_id then
                                obj:set {
                                    x = position,
                                }
                            end
                        end,
                        done_cb = function(anim)
                            anim:delete()

                            if id == marquee_id then
                                wait_ms(2000, id, backward)
                            end
                        end,
                    }
                end

                backward = function()
                    if id ~= marquee_id then
                        return
                    end

                    title:Anim {
                        run = true,
                        start_value = -overflow,
                        end_value = 0,
                        duration = duration,
                        path = "linear",
                        exec_cb = function(obj, position)
                            if id == marquee_id then
                                obj:set {
                                    x = position,
                                }
                            end
                        end,
                        done_cb = function(anim)
                            anim:delete()

                            if id == marquee_id then
                                wait_ms(2000, id, forward)
                            end
                        end,
                    }
                end

                wait_ms(2000, id, forward)
            end,
        }
    end

    local screen = {
        root = root,
    }

    function screen:update(values)
        values = values or {}

        if values.background then
            background:set {
                src = lvgl.ImgData(values.background),
            }
        end

        if values.cover then
            cover:set {
                src = lvgl.ImgData(values.cover),
            }
        end

        if values.title ~= nil then
            set_title(values.title)
        end

        if values.artist ~= nil then
            set_artist(values.artist)
        end

        if values.progress ~= nil then
            local amount = math.max(0, math.min(1, values.progress))

            progress_fill:set {
                w = math.floor(144 * amount),
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
    end

    screen:update(options)

    return screen
end

return M

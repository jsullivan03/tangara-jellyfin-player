local lvgl = require("lvgl")
local jellyfin_marquee =
    require("jellyfin_marquee")
local palette =
    require("jellyfin_theme").current()

local M = {}

local COVER_X = 44
local COVER_Y = 19
local TITLE_Y = 90
local ARTIST_Y = 100
local MEDIA_TEXT_HEIGHT = 18
local BACKGROUND_DIMMER_OPA = 118
local COVER_DISPLAY_SIZE = 72

local function bind_artwork(
    image,
    source,
    options
)
    options = options or {}

    -- Source assignment temporarily restores the decoded image's native
    -- origin and dimensions. Hide the widget for the short rebind so an EOF
    -- track transition cannot paint the new cover at (0, 0) for one frame.
    image:add_flag(
        lvgl.FLAG.HIDDEN
    )
    image:set {
        src = lvgl.ImgData(source),
    }

    local decoded_width,
        decoded_height =
        image:get_img_size()

    decoded_width =
        tonumber(decoded_width) or
        tonumber(options.width) or 1
    decoded_height =
        tonumber(decoded_height) or
        tonumber(options.height) or 1

    local width =
        tonumber(options.width) or
        decoded_width
    local height =
        tonumber(options.height) or
        decoded_height
    local scale_x = width / decoded_width
    local scale_y = height / decoded_height
    local scale =
        options.fill and
        math.max(scale_x, scale_y) or
        math.min(scale_x, scale_y)
    local zoom =
        tonumber(options.zoom) or
        math.max(
            1,
            math.floor(scale * 256 + 0.5)
        )
    local pivot = {
        x = math.floor(decoded_width / 2),
        y = math.floor(decoded_height / 2),
    }
    local object_x =
        tonumber(options.x) or 0
    local object_y =
        tonumber(options.y) or 0
    local fixed_object =
        options.fixed_object == true
    local object_width =
        fixed_object and
        width or decoded_width
    local object_height =
        fixed_object and
        height or decoded_height

    if options.fill then
        object_x = object_x +
            math.floor(width / 2) -
            pivot.x
        object_y = object_y +
            math.floor(height / 2) -
            pivot.y
    end

    image:set {
        x = object_x,
        y = object_y,
        w = object_width,
        h = object_height,
        align = lvgl.ALIGN.TOP_LEFT,
        offset_x = 0,
        offset_y = 0,
        angle = 0,
        zoom = zoom,
        antialias = true,
        inner_align = lvgl.IMAGE_ALIGN.CENTER,
        transform_width = 0,
        transform_height = 0,
        pivot = pivot,
    }

    if fixed_object then
        -- Keep the image widget itself at the display-frame size. LVGL
        -- otherwise clips a small decoded source before its zoomed pixels are
        -- composed, which is why 28x28 Local artwork appeared tiny or shifted.
        image:set {
            x = object_x,
            y = object_y,
        }
    end

    image:clear_flag(
        lvgl.FLAG.HIDDEN
    )
    image:invalidate()

    return {
        source = source,
        decoded_width = decoded_width,
        decoded_height = decoded_height,
        object_width = object_width,
        object_height = object_height,
        x = object_x,
        y = object_y,
        zoom = zoom,
        pivot = pivot,
        alignment = lvgl.ALIGN.TOP_LEFT,
        size_mode = lvgl.IMAGE_ALIGN.CENTER,
        transform_width = 0,
        transform_height = 0,
        target_width = width,
        target_height = height,
    }
end

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
        bg_color = palette.background,
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
    }

    local current_background = options.background
    local current_cover = options.cover
    local current_title = options.title or ""
    local current_artist = options.artist or ""

    local background = root:Image {
        x = 0,
        y = 0,
        src =
            lvgl.ImgData(
                current_background
            ),
    }

    local background_geometry =
        bind_artwork(
            background,
            current_background,
            {
                x = 0,
                y = 0,
                width = 160,
                height = 128,
                fill = true,
            }
        )

    local background_dimmer =
        root:Object {
            x = 0,
            y = 0,
            w = 160,
            h = 128,
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_color = palette.overlay,
            bg_opa = BACKGROUND_DIMMER_OPA,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    background_dimmer:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )

    local cover = root:Image {
        x = COVER_X,
        y = COVER_Y,
        src =
            lvgl.ImgData(
                current_cover
            ),
        pivot = {
            x = 33,
            y = 33,
        },
        zoom = 256,
        antialias = true,
    }

    local cover_geometry =
        bind_artwork(
            cover,
            current_cover,
            {
                x = COVER_X,
                y = COVER_Y,
                width = COVER_DISPLAY_SIZE,
                height = COVER_DISPLAY_SIZE,
                fixed_object = true,
            }
        )

    local title_marquee =
        jellyfin_marquee.create(
            root,
            {
                x = 6,
                y = TITLE_Y,
                w = 148,
                h = MEDIA_TEXT_HEIGHT,
                label_y = 0,
                text = "",
                align = "center",
                text_color = palette.foreground,
                autostart = true,
            }
        )

    local artist_marquee =
        jellyfin_marquee.create(
            root,
            {
                x = 6,
                y = ARTIST_Y,
                w = 148,
                h = MEDIA_TEXT_HEIGHT,
                label_y = 0,
                text = "",
                align = "center",
                text_color = palette.muted_text,
                autostart = true,
            }
        )

    local elapsed = root:Label {
        x = 8,
        y = 111,
        w = 35,
        text = "0:00",
        text_color = palette.muted_text,
    }

    local remaining = root:Label {
        x = 117,
        y = 111,
        w = 35,
        text = "0:00",
        text_color = palette.muted_text,
        text_align = 3,
    }

    local progress = root:Object {
        x = 8,
        y = 124,
        w = 144,
        h = 3,
        radius = 2,
        border_width = 0,
        bg_color = palette.divider,
    }

    local progress_fill =
        progress:Object {
            x = 0,
            y = 0,
            w = 0,
            h = 3,
            radius = 2,
            border_width = 0,
            bg_color = palette.foreground,
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
        bg_color = palette.foreground,
    }

    pause_icon:Object {
        x = 5,
        y = 1,
        w = 2,
        h = 8,
        radius = 1,
        border_width = 0,
        bg_color = palette.foreground,
    }

    local status_bar = root:Object {
        x = 0,
        y = 0,
        w = 160,
        h = 13,
        pad_all = 0,
        border_width = 0,
        radius = 0,
        bg_color = palette.status_background,
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
            y = 2,
            w = 8,
            h = 8,
            pad_all = 0,
            border_width = 1,
            border_color =
                palette.status_muted,
            radius = 5,
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
            bg_color =
                palette.status_good,
            bg_opa = 0,
        }

    local clock = status_bar:Label {
        x = 56,
        y = 2,
        w = 48,
        text = "--:--",
        text_align = 2,
        text_color = palette.foreground,
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
            border_color = palette.foreground,
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
                bg_color =
                    palette.status_muted,
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
            bg_color = palette.foreground,
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
            palette.foreground

        if battery_charging then
            active_color =
                palette.status_good
        elseif percentage <= 10 then
            active_color =
                palette.status_bad
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
                    palette.status_muted,
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

    function screen:media_state()
        return {
            background = current_background,
            cover = current_cover,
            title = current_title,
            artist = current_artist,
            cover_x = COVER_X,
            cover_y = COVER_Y,
            cover_zoom =
                cover_geometry.zoom,
            title_x = 6,
            title_y = TITLE_Y,
            artist_x = 6,
            artist_y = ARTIST_Y,
            background_x = 0,
            background_y = 0,
            background_dimmer_opa =
                BACKGROUND_DIMMER_OPA,
        }
    end

    function screen:artwork_state()
        local root_coordinates =
            root:get_coords()

        return {
            foreground = cover_geometry,
            background = background_geometry,
            clip = {
                x1 = root_coordinates.x1,
                y1 = root_coordinates.y1,
                x2 = root_coordinates.x2,
                y2 = root_coordinates.y2,
            },
        }
    end

    local function text_layout_state(
        marquee
    )
        local view =
            marquee.view:get_coords()
        local label =
            marquee.label:get_coords()

        return {
            measured =
                marquee.measured == true,
            view_width =
                view.x2 - view.x1 + 1,
            view_height =
                view.y2 - view.y1 + 1,
            text_width =
                label.x2 - label.x1 + 1,
            text_height =
                label.y2 - label.y1 + 1,
            relative_x =
                label.x1 - view.x1,
            relative_y =
                label.y1 - view.y1,
            bottom_room =
                view.y2 - label.y2,
        }
    end

    function screen:media_text_layout_state()
        return {
            title =
                text_layout_state(
                    title_marquee
                ),
            artist =
                text_layout_state(
                    artist_marquee
                ),
        }
    end

    function screen:media_marquee_state()
        return {
            title = {
                measured =
                    title_marquee.measured ==
                    true,
                overflow =
                    title_marquee.overflow or 0,
                active =
                    title_marquee.active ==
                    true,
                uses_native_circular =
                    title_marquee
                        .uses_native_circular ==
                    true,
                has_anim =
                    title_marquee.anim ~= nil,
                destroyed =
                    title_marquee.destroyed ==
                    true,
                short_x =
                    title_marquee.short_x or 0,
                text_width =
                    title_marquee.text_width or
                    0,
            },
            artist = {
                measured =
                    artist_marquee.measured ==
                    true,
                overflow =
                    artist_marquee.overflow or
                    0,
                active =
                    artist_marquee.active ==
                    true,
                uses_native_circular =
                    artist_marquee
                        .uses_native_circular ==
                    true,
                has_anim =
                    artist_marquee.anim ~= nil,
                destroyed =
                    artist_marquee.destroyed ==
                    true,
                short_x =
                    artist_marquee.short_x or 0,
                text_width =
                    artist_marquee.text_width or
                    0,
            },
        }
    end

    function screen:refresh_media_layout()
        -- create_ui runs before this root becomes the active firmware screen.
        -- Initial text measured there can use detached-tree coordinates, while
        -- later next/previous updates are already attached and center normally.
        -- Recalculate synchronously from on_show so the first visible frame is
        -- positioned from the active 160x128 layout.
        root:update_layout()
        title_marquee:refresh(true)
        artist_marquee:refresh(true)
    end

    function screen:suspend()
        pause_icon_generation =
            pause_icon_generation + 1
        pause_icon_pending = false
        title_marquee:stop()
        artist_marquee:stop()
    end

    function screen:resume()
        title_marquee:rebind(
            current_title,
            true
        )
        artist_marquee:rebind(
            current_artist,
            true
        )
        title_marquee:start()
        artist_marquee:start()
        self:refresh_media_layout()
    end

    function screen:retire()
        pause_icon_generation =
            pause_icon_generation + 1
        pause_icon_pending = false
        title_marquee:destroy()
        artist_marquee:destroy()
    end

    function screen:update(values)
        values = values or {}

        local title_changed =
            values.title ~= nil
        local artist_changed =
            values.artist ~= nil
        local media_changed =
            values.background ~= nil or
            values.cover ~= nil or
            title_changed or
            artist_changed

        -- Changing a marquee label briefly restores its default left-aligned
        -- position before it is measured and centered again. Keep the text
        -- views hidden through that rebind so an automatic queue advance never
        -- paints the new title at the left edge for one frame.
        if title_changed then
            title_marquee.view:add_flag(
                lvgl.FLAG.HIDDEN
            )
            title_marquee:reset()
        end

        if artist_changed then
            artist_marquee.view:add_flag(
                lvgl.FLAG.HIDDEN
            )
            artist_marquee:reset()
        end

        if media_changed then
            cover_geometry =
                bind_artwork(
                    cover,
                    values.cover or
                        current_cover,
                    {
                        x = COVER_X,
                        y = COVER_Y,
                        width =
                            COVER_DISPLAY_SIZE,
                        height =
                            COVER_DISPLAY_SIZE,
                        fixed_object = true,
                    }
                )
            title_marquee.view:set {
                x = 6,
                y = TITLE_Y,
                w = 148,
                h = MEDIA_TEXT_HEIGHT,
            }
            artist_marquee.view:set {
                x = 6,
                y = ARTIST_Y,
                w = 148,
                h = MEDIA_TEXT_HEIGHT,
            }
        end

        if values.background then
            current_background =
                values.background
            background_geometry =
                bind_artwork(
                    background,
                    values.background,
                    {
                        x = 0,
                        y = 0,
                        width = 160,
                        height = 128,
                        fill = true,
                    }
                )
        end

        if values.cover then
            current_cover = values.cover
        end

        if title_changed then
            current_title = values.title
        end

        if artist_changed then
            current_artist = values.artist
        end

        if title_changed or
            artist_changed then
            root:update_layout()

            if title_changed then
                -- Reveal before measuring so first painted frame is centered
                -- or freshly marqueed from a clean baseline.
                title_marquee.view:clear_flag(
                    lvgl.FLAG.HIDDEN
                )
                title_marquee:rebind(
                    current_title,
                    true
                )
                title_marquee.view:invalidate()
                title_marquee:start()
            end

            if artist_changed then
                artist_marquee.view:clear_flag(
                    lvgl.FLAG.HIDDEN
                )
                artist_marquee:rebind(
                    current_artist,
                    true
                )
                artist_marquee.view:invalidate()
                artist_marquee:start()
            end
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
                    palette.status_good or
                    palette.status_muted,
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

    screen.root = root
    screen.cover_image = cover
    screen.background_image = background

    return screen
end

return M

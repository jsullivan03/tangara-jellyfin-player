local controls = require("controls")
local jellyfin_playback_session =
    require("jellyfin_playback_session")
local jellyfin_theme =
    require("jellyfin_theme")
local lvgl = require("lvgl")

local M = {}
M.LIST_Y = 28
M.MINI_Y = 101
M.MINI_HEIGHT = 25
M.FULL_LIST_HEIGHT = 100
M.MINI_LIST_HEIGHT = 72

local MINI_Y = M.MINI_Y
local MINI_HEIGHT = M.MINI_HEIGHT
local FULL_LIST_HEIGHT = M.FULL_LIST_HEIGHT
local MINI_LIST_HEIGHT = M.MINI_LIST_HEIGHT

function M.usable_viewport(mini_visible)
    local usable_top = M.LIST_Y
    local usable_height =
        mini_visible and
        M.MINI_LIST_HEIGHT or
        M.FULL_LIST_HEIGHT

    return {
        usable_top = usable_top,
        usable_bottom =
            usable_top + usable_height,
        usable_height = usable_height,
    }
end

function M.scroll_track_height(
    usable_height
)
    return
        math.max(
            1,
            math.floor(
                tonumber(usable_height) or
                M.FULL_LIST_HEIGHT
            ) - 4
        )
end

local function sync_scroll_indicator(
    screen,
    usable_height
)
    local indicator =
        screen and
        (
            screen.scroll_indicator or
            screen.virtual_scroll_indicator
        )

    if not indicator then
        return
    end

    local track_height =
        M.scroll_track_height(usable_height)

    if type(indicator.set_track_height) ==
            "function" then
        indicator:set_track_height(
            track_height
        )
    else
        indicator.height = track_height
    end

    if type(indicator.update) ==
            "function" then
        local selected = 1

        if screen.virtual_list_controller and
            screen.virtual_list_controller
                .selected_index then
            selected =
                screen.virtual_list_controller
                    .selected_index
        end

        indicator:update(
            indicator.item_count or
            (
                indicator.models and
                #indicator.models
            ) or 0,
            selected
        )
    end
end

local function remove_from_group(object)
    pcall(function()
        lvgl.group.remove_obj(object)
    end)
end

local function add_to_group(object)
    local group = lvgl.group.get_default()

    local ok = pcall(function()
        lvgl.group.add_obj(group, object)
    end)

    if not ok then
        pcall(function()
            group:add_obj(object)
        end)
    end
end

local function bind_cover(image, source)
    local display_size = 20

    image:set {
        src = lvgl.ImgData(source),
    }

    local width, height = image:get_img_size()
    width = tonumber(width) or display_size
    height = tonumber(height) or display_size
    local zoom = math.max(
        1,
        math.floor(
            math.min(
                display_size / width,
                display_size / height
            ) * 256 + 0.5
        )
    )

    local pivot = {
        x = math.floor(width / 2),
        y = math.floor(height / 2),
    }

    -- Keep the LVGL object fixed to the thumbnail frame. The decoded source
    -- may be 66x66 or larger; using those dimensions for the object lets the
    -- 20x20 parent clip the source before the fitted image is composed.
    image:set {
        w = display_size,
        h = display_size,
        align = lvgl.ALIGN.TOP_LEFT,
        offset_x = 0,
        offset_y = 0,
        angle = 0,
        zoom = zoom,
        pivot = pivot,
        inner_align = lvgl.IMAGE_ALIGN.CENTER,
        transform_width = 0,
        transform_height = 0,
        antialias = true,
    }

    -- Apply position after alignment so an align setter cannot reset it.
    image:set {
        x = 0,
        y = 0,
    }

    return {
        source = source,
        decoded_width = width,
        decoded_height = height,
        width = display_size,
        height = display_size,
        zoom = zoom,
        pivot = pivot,
    }
end

function M.attach(screen)
    if screen.mini_player then
        screen.mini_player.retired = true
    end

    local palette = jellyfin_theme.current()
    local model = {
        owner = screen,
        visible = false,
        current_session_id = nil,
        current_track_id = nil,
        artwork = nil,
    }

    local root = screen.root:Button {
        x = 2,
        y = MINI_Y,
        w = 156,
        h = MINI_HEIGHT,
        pad_all = 0,
        border_width = 0,
        outline_width = 0,
        outline_pad = 0,
        shadow_width = 0,
        radius = 3,
        bg_color = palette.surface,
        bg_opa = 245,
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
    }

    root:clear_flag(lvgl.FLAG.SCROLLABLE)
    root:add_flag(lvgl.FLAG.HIDDEN)
    remove_from_group(root)

    local cover_frame = root:Object {
        x = 2,
        y = 2,
        w = 20,
        h = 20,
        pad_all = 0,
        border_width = 0,
        radius = 2,
        bg_opa = 0,
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
    }
    cover_frame:clear_flag(lvgl.FLAG.SCROLLABLE)
    cover_frame:clear_flag(lvgl.FLAG.CLICKABLE)

    local cover = cover_frame:Image {
        x = 0,
        y = 0,
        w = 20,
        h = 20,
    }
    cover:clear_flag(lvgl.FLAG.CLICKABLE)

    local title = root:Label {
        x = 25,
        y = 2,
        w = 112,
        h = 10,
        text = "",
        text_color = palette.foreground,
        text_font = font.fusion_10,
        long_mode = lvgl.LABEL.LONG_DOT,
    }
    title:clear_flag(lvgl.FLAG.CLICKABLE)

    local artist = root:Label {
        x = 25,
        y = 12,
        w = 112,
        h = 10,
        text = "",
        text_color = palette.muted_text,
        text_font = font.fusion_10,
        long_mode = lvgl.LABEL.LONG_DOT,
    }
    artist:clear_flag(lvgl.FLAG.CLICKABLE)

    local affordance = root:Object {
        x = 140,
        y = 1,
        w = 15,
        h = 23,
        pad_all = 0,
        border_width = 0,
        radius = 0,
        bg_opa = 0,
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
    }
    affordance:clear_flag(lvgl.FLAG.SCROLLABLE)
    affordance:clear_flag(lvgl.FLAG.CLICKABLE)

    local state_icon = affordance:Object {
        x = 2,
        y = 6,
        w = 11,
        h = 11,
        pad_all = 0,
        border_width = 0,
        bg_opa = 0,
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
    }
    state_icon:clear_flag(lvgl.FLAG.SCROLLABLE)
    state_icon:clear_flag(lvgl.FLAG.CLICKABLE)

    for _, point in ipairs({
        {x = 2, y = 1},
        {x = 4, y = 3},
        {x = 6, y = 5},
        {x = 4, y = 7},
        {x = 2, y = 9},
    }) do
        local pixel = state_icon:Object {
            x = point.x,
            y = point.y,
            w = 2,
            h = 2,
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_color = palette.foreground,
            bg_opa = 255,
        }
        pixel:clear_flag(lvgl.FLAG.SCROLLABLE)
        pixel:clear_flag(lvgl.FLAG.CLICKABLE)
    end

    local progress = root:Object {
        x = 25,
        y = 23,
        w = 112,
        h = 1,
        pad_all = 0,
        border_width = 0,
        radius = 0,
        bg_color = palette.divider,
    }
    progress:clear_flag(lvgl.FLAG.SCROLLABLE)
    progress:clear_flag(lvgl.FLAG.CLICKABLE)

    local progress_fill = progress:Object {
        x = 0,
        y = 0,
        w = 0,
        h = 1,
        pad_all = 0,
        border_width = 0,
        radius = 0,
        bg_color = palette.accent,
    }
    progress_fill:clear_flag(lvgl.FLAG.SCROLLABLE)
    progress_fill:clear_flag(lvgl.FLAG.CLICKABLE)

    local function resize_list(visible)
        local viewport =
            M.usable_viewport(visible)
        local height =
            viewport.usable_height
        local controller =
            screen.virtual_list_controller

        if controller and
            type(controller.set_viewport_height) ==
                "function" then
            controller:set_viewport_height(height)
        else
            screen.list:set {h = height}
            sync_scroll_indicator(
                screen,
                height
            )
        end

        if type(
            screen.on_mini_player_visibility
        ) == "function" then
            screen:on_mini_player_visibility(
                visible,
                height
            )
        end
    end

    function model:refresh()
        local session =
            jellyfin_playback_session.current()

        if not session then
            if self.visible then
                self.visible = false
                root:add_flag(lvgl.FLAG.HIDDEN)
                remove_from_group(root)
                resize_list(false)
            end
            return false
        end

        if not self.visible then
            self.visible = true
            root:clear_flag(lvgl.FLAG.HIDDEN)

            if screen.ui_active then
                add_to_group(root)
            end
        end

        -- Always re-apply the shortened list height. Root and other screens may
        -- overwrite list geometry after attach; skipping resize when already
        -- visible left Tracks covered by the mini-player.
        resize_list(true)

        title:set {text = session.metadata.title}
        artist:set {text = session.metadata.artist}
        local duration =
            tonumber(session.metadata.duration) or 0
        local position =
            tonumber(session.position) or 0
        local width = duration > 0 and
            math.floor(
                math.max(0, math.min(1,
                    position / duration)) *
                    112 + 0.5
            ) or 0
        progress_fill:set {w = width}

        local source =
            session.artwork.foreground or
            "//lua/img/cover_placeholder.png"

        if source ~= self.current_artwork then
            self.current_artwork = source
            self.artwork = bind_cover(
                cover,
                source
            )
        end

        self.current_session_id = session.id
        self.current_track_id = session.track_id
        self.queue_index = session.queue_index
        self.position = session.position
        self.paused = session.paused
        return true
    end

    function model:on_show()
        self:refresh()

        if self.visible then
            add_to_group(root)
        end

        local hooks = controls.hooks()
        local input = hooks.wheel or hooks.dpad

        if input and input.right then
            self.input_right = input.right
            self.previous_right_long =
                input.right.long_press
            input.right.long_press =
                jellyfin_playback_session
                    .open_now_playing
        end
    end

    function model:on_hide()
        remove_from_group(root)

        if self.input_right and
            self.input_right.long_press ==
                jellyfin_playback_session
                    .open_now_playing then
            self.input_right.long_press =
                self.previous_right_long
        end

        self.input_right = nil
        self.previous_right_long = nil
    end

    function model:state()
        return {
            visible = self.visible,
            session_id = self.current_session_id,
            track_id = self.current_track_id,
            queue_index = self.queue_index,
            position = self.position,
            paused = self.paused,
            artwork = self.artwork,
            root_coordinates =
                root:get_coords(),
            cover_frame_coordinates =
                cover_frame:get_coords(),
            title_coordinates =
                title:get_coords(),
            artist_coordinates =
                artist:get_coords(),
            affordance_coordinates =
                affordance:get_coords(),
            list_height = self.visible and
                MINI_LIST_HEIGHT or
                FULL_LIST_HEIGHT,
        }
    end

    function model:open()
        return
            jellyfin_playback_session
                .open_now_playing()
    end

    root:onevent(lvgl.EVENT.CLICKED, function()
        model:open()
    end)

    root:onevent(lvgl.EVENT.FOCUSED, function()
        root:set {
            outline_width = 1,
            outline_color = palette.accent,
        }
    end)

    root:onevent(lvgl.EVENT.DEFOCUSED, function()
        root:set {
            outline_width = 0,
        }
    end)

    model.timer = lvgl.Timer {
        period = 250,
        cb = function()
            if not model.retired and
                screen.ui_active then
                model:refresh()
            end
        end,
    }

    model.object = root
    model.cover = cover
    model.title = title
    model.artist = artist
    model.progress = progress_fill
    model.cover_frame = cover_frame
    model.affordance = affordance
    model.state_icon = state_icon
    screen.mini_player = model
    model:refresh()
    return model
end

return M

local lvgl = require("lvgl")
local backstack = require("backstack")
local controls = require("controls")
local jellyfin_marquee =
    require("jellyfin_marquee")
local jellyfin_navigation =
    require("jellyfin_navigation")
local jellyfin_status_bar =
    require("jellyfin_status_bar")
local jellyfin_scroll_indicator =
    require("jellyfin_scroll_indicator")
local jellyfin_theme =
    require("jellyfin_theme")
local jellyfin_track_identity =
    require("jellyfin_track_identity")
local M = {}

local resume_metrics = nil

pcall(
    function()
        resume_metrics =
            require("sim_metrics")
    end
)

local function resume_trace(message)
    if resume_metrics and
        type(resume_metrics.trace) ==
            "function" then
        resume_metrics.trace(
            "list-ui " .. tostring(message)
        )
    end
end

local palette = jellyfin_theme.current()
local COLOR_KEYS = {
    background = "background",
    selected = "selected_surface",
    primary = "foreground",
    secondary = "muted_text",
    badge = "badge",
    badge_text = "badge_text",
    art_background = "art_background",
    modal = "modal",
    modal_border = "modal_border",
}
local COLORS =
    setmetatable(
        {},
        {
            __index = function(_, key)
                return palette[
                    COLOR_KEYS[key] or key
                ]
            end,
        }
    )

local function media_row_parent(self)
    return
        self.virtual_row_parent or
        self.list
end

local MEDIA_ROW_HEIGHT = 23
local MEDIA_ARTWORK_SIZE = 19
local MEDIA_TEXT_X = 24
local MEDIA_TEXT_WIDTH = 127
-- Fusion 10's visible glyphs sit about one pixel below the label box center.
-- Keep one shared optical layout for every compact two-line media row.
local MEDIA_TITLE_Y = -1
local MEDIA_DETAIL_Y = 9
local MEDIA_SINGLE_Y = 4

-- Home and Local root rows are the same control and should use the same
-- geometry instead of each screen supplying a slightly different y offset.
local MENU_ROW_HEIGHT = 24
local MENU_TEXT_Y = 4
local MENU_TEXT_HEIGHT = 14

local pending_initial_scrolls =
    setmetatable(
        {},
        {__mode = "k"}
    )

local initial_scroll_timer = nil

local INITIAL_SCROLL_ROW_Y = 25
local INITIAL_SCROLL_ATTEMPTS = 30
local INITIAL_SCROLL_ROOM = 100

local function normalize_selection_id(value)
    if value == nil then
        return nil
    end

    local text = tostring(value)

    if text == "" then
        return nil
    end

    return text
end

local function item_selection_id(item)
    if type(item) ~= "table" then
        return nil
    end

    if item.kind == "track" or
        item.track_key or
        (
            item.title and
            (
                item.jellyfin_id or
                item.id
            ) and
            item.kind ~= "album" and
            item.kind ~= "artist"
        ) then
        local track_key =
            jellyfin_track_identity.key(item)

        if track_key then
            return track_key
        end
    end

    for _, key in ipairs({
        "key",
        "id",
        "jellyfin_id",
        "local_path",
    }) do
        local value =
            normalize_selection_id(
                item[key]
            )

        if value then
            return value
        end
    end

    return nil
end

local function update_model_selection(
    model,
    value
)
    model.selection_id =
        normalize_selection_id(value)

    if model.focused and
        model.owner and
        not model.owner
            .suppress_selection_tracking and
        model.selection_id then
        model.owner.selected_item_id =
            model.selection_id
    end
end

local function selected_row_object(self)
    local selected_id =
        normalize_selection_id(
            self and
            self.selected_item_id
        )

    if not selected_id then
        return nil
    end

    if self and
        type(
            self.selection_object_for_id
        ) == "function" then
        local object =
            self.selection_object_for_id(
                selected_id
            )

        if object then
            return object
        end
    end

    for _, model in ipairs(
        self.rows or {}
    ) do
        if model.selection_id ==
                selected_id or
            jellyfin_track_identity
                .matches_selection(
                    selected_id,
                    model.selection_id
                ) then
            return model.object
        end
    end

    return nil
end

local function initial_scroll_rows(self)
    local rows = {}

    for _, model in ipairs(
        self and self.leading_rows or {}
    ) do
        if model and
            model.object and
            model.object ~= self.first_row and
            model.object ~= self.initial_scroll_anchor then
            table.insert(rows, model.object)
        end
    end

    if #rows == 0 and
        self and
        self.sort_row and
        self.sort_row.object and
        self.sort_row.object ~=
            self.first_row then
        table.insert(
            rows,
            self.sort_row.object
        )
    end

    return rows
end

local function apply_initial_scroll(self)
    local has_leading_rows =
        self and self.leading_rows and
        #self.leading_rows > 0

    if not self or
        self.preserve_leading_controls_on_open or
        not self.ui_active or
        not self.list or
        (
            not self.sort_row and
            not has_leading_rows
        ) or
        not self.first_row or
        (
            self.sort_row and
            self.first_row ==
                self.sort_row.object
        ) then
        return false
    end

    -- Fixed-viewport catalogs own motion-layer offset. Native list scroll here
    -- on resume/back fights that restoration. First open may still settle Sort.
    if self.controls_installed_once and
        self.virtual_list_controller and
        self.virtual_list_controller
            .fixed_viewport == true then
        return true
    end

    local leading_rows =
        initial_scroll_rows(self)

    if #leading_rows == 0 then
        return false
    end

    local applied = false

    pcall(
        function()
            self.list:scroll_to {
                x = 0,
                y =
                    INITIAL_SCROLL_ROW_Y *
                    #leading_rows,
                anim = false,
            }

            local list_coordinates =
                self.list:get_coords()

            local target_object =
                self.initial_scroll_anchor or
                self.first_row

            local row_coordinates =
                target_object:get_coords()

            local leading_rows_hidden = true

            for _, object in ipairs(
                leading_rows
            ) do
                local coordinates =
                    object:get_coords()

                if coordinates.y2 >=
                    list_coordinates.y1 then
                    leading_rows_hidden = false
                    break
                end
            end

            local list_height =
                list_coordinates.y2 -
                list_coordinates.y1 + 1

            applied =
                list_height >= 20 and
                row_coordinates.y1 >=
                    list_coordinates.y1 - 2 and
                row_coordinates.y1 <=
                    list_coordinates.y1 + 1 and
                leading_rows_hidden
        end
    )

    return applied
end

local function initial_scrolls_pending()
    for self in pairs(
        pending_initial_scrolls
    ) do
        if self and self.ui_active then
            return true
        end

        pending_initial_scrolls[self] = nil
    end

    return false
end

local function ensure_initial_scroll_timer()
    if initial_scroll_timer then
        return initial_scroll_timer
    end

    initial_scroll_timer =
        lvgl.Timer {
            paused = true,
            period = 35,
            repeat_count = -1,
            cb = function()
                for self, attempts in pairs(
                    pending_initial_scrolls
                ) do
                    if not self.ui_active then
                        pending_initial_scrolls[
                            self
                        ] = nil
                    elseif apply_initial_scroll(
                        self
                    ) or attempts <= 1 then
                        pending_initial_scrolls[
                            self
                        ] = nil
                    else
                        pending_initial_scrolls[
                            self
                        ] = attempts - 1
                    end
                end

                if not initial_scrolls_pending() then
                    initial_scroll_timer:pause()
                end
            end,
        }

    return initial_scroll_timer
end

local function schedule_initial_scroll(self)
    if self and
        self.preserve_leading_controls_on_open then
        pending_initial_scrolls[self] = nil
        return
    end

    if apply_initial_scroll(self) then
        pending_initial_scrolls[self] = nil
        return
    end

    local has_leading_rows =
        self and self.leading_rows and
        #self.leading_rows > 0

    if not self or
        not self.ui_active or
        (
            not self.sort_row and
            not has_leading_rows
        ) or
        not self.first_row or
        (
            self.sort_row and
            self.first_row ==
                self.sort_row.object
        ) then
        return
    end

    pending_initial_scrolls[self] =
        INITIAL_SCROLL_ATTEMPTS

    local ok, timer =
        pcall(ensure_initial_scroll_timer)

    if not ok or not timer then
        pending_initial_scrolls[self] = nil
        return
    end

    pcall(
        function()
            timer:resume()
        end
    )
end

local function remove_from_group(object)
    if not object then
        return
    end

    pcall(
        function()
            lvgl.group.remove_obj(
                object
            )
        end
    )
end

local function add_to_group(
    group,
    object
)
    if not group or
        not object then
        return
    end

    local added =
        pcall(
            function()
                lvgl.group.add_obj(
                    group,
                    object
                )
            end
        )

    if not added then
        pcall(
            function()
                group:add_obj(object)
            end
        )
    end
end

local function focus_object(
    object,
    scroll
)
    if not object then
        return
    end

    pcall(
        function()
            lvgl.group.focus_obj(
                object
            )
        end
    )

    if scroll == false then
        return
    end

    pcall(
        function()
            object:scroll_to_view_recursive(true)
        end
    )
end

local function cancel_plain_list_scroll(owner)
    if not owner then
        return
    end

    owner.plain_list_scroll_generation =
        (owner.plain_list_scroll_generation or 0) + 1

    if owner.plain_list_scroll_anim and
        type(
            owner.plain_list_scroll_anim.delete
        ) == "function" then
        pcall(function()
            owner.plain_list_scroll_anim:
                delete()
        end)
    end

    owner.plain_list_scroll_anim = nil
end

local function capture_plain_list_scroll(owner)
    if not owner or
        not owner.list or
        owner.virtual_list_controller then
        return false
    end

    local saved = nil
    local scroll_to_y = nil
    pcall(function()
        owner.list:update_layout()
        local list_coordinates =
            owner.list:get_coords()
        local anchor =
            selected_row_object(owner) or
            owner.first_row or
            (
                owner.rows[1] and
                owner.rows[1].object
            )

        if not anchor then
            return
        end

        local anchor_coordinates =
            anchor:get_coords()
        saved =
            list_coordinates.y1 -
            anchor_coordinates.y1

        local first =
            owner.rows[1] and
            owner.rows[1].object
        if first then
            local first_coordinates =
                first:get_coords()
            scroll_to_y =
                list_coordinates.y1 -
                first_coordinates.y1
        end
    end)

    owner.resume_plain_scroll_y = saved
    owner.resume_plain_scroll_to_y =
        scroll_to_y
    owner.resume_plain_scroll_id =
        owner.selected_item_id
    return saved ~= nil
end

local function restore_plain_list_scroll(owner)
    if not owner or
        not owner.list or
        owner.virtual_list_controller or
        (
            owner.resume_plain_scroll_y == nil and
            owner.resume_plain_scroll_to_y == nil
        ) then
        return false
    end

    local restored = false

    pcall(function()
        cancel_plain_list_scroll(owner)
        owner.list:update_layout()

        if owner.resume_plain_scroll_to_y ~=
                nil then
            owner.list:scroll_to {
                x = 0,
                y = owner.resume_plain_scroll_to_y,
                anim = false,
            }
            owner.list:update_layout()
        end

        local target_offset =
            owner.resume_plain_scroll_y
        if target_offset == nil then
            restored = true
            return
        end

        local anchor = nil
        local preferred_id =
            owner.resume_plain_scroll_id or
            owner.selected_item_id

        if preferred_id then
            for _, model in ipairs(
                owner.rows or {}
            ) do
                if model.selection_id ==
                        preferred_id then
                    anchor = model.object
                    break
                end
            end
        end

        anchor =
            anchor or
            selected_row_object(owner) or
            owner.first_row

        if not anchor then
            restored = true
            return
        end

        local list_coordinates =
            owner.list:get_coords()
        local anchor_coordinates =
            anchor:get_coords()
        local current_offset =
            list_coordinates.y1 -
            anchor_coordinates.y1
        local delta =
            current_offset - target_offset

        if delta ~= 0 then
            if type(owner.list.scroll_by_bounded) ==
                    "function" then
                owner.list:scroll_by_bounded(
                    0,
                    delta,
                    false
                )
            else
                owner.list:scroll_by(
                    0,
                    delta,
                    false
                )
            end
            owner.list:update_layout()
        end

        restored = true
    end)

    return restored
end

local function animate_plain_list_reveal(
    owner,
    object
)
    if not owner or
        not owner.list or
        not object or
        owner.suppress_focus_scroll then
        return
    end

    local list = owner.list
    local list_coords = list:get_coords()
    local object_coords =
        object:get_coords()
    local delta = 0

    if object_coords.y2 >
            list_coords.y2 then
        delta =
            object_coords.y2 -
            list_coords.y2
    elseif object_coords.y1 <
            list_coords.y1 then
        delta =
            object_coords.y1 -
            list_coords.y1
    else
        return
    end

    -- One native LVGL Anim drives the reveal. Rapid input bumps the
    -- generation so the previous animation is abandoned instead of queued.
    cancel_plain_list_scroll(owner)

    local generation =
        owner.plain_list_scroll_generation
    local scrolled = 0

    local ok, anim = pcall(function()
        return list:Anim {
            run = true,
            start_value = 0,
            end_value = -delta,
            duration = 150,
            path = "linear",
            exec_cb = function(
                animated_object,
                value
            )
                if owner.plain_list_scroll_generation ~=
                        generation then
                    return
                end

                local step =
                    value - scrolled
                scrolled = value

                if step ~= 0 then
                    animated_object:
                        scroll_by(
                            0,
                            step,
                            false
                        )
                end
            end,
            done_cb = function()
                if owner.plain_list_scroll_generation ==
                        generation then
                    owner.plain_list_scroll_anim =
                        nil
                end
            end,
        }
    end)

    if ok then
        owner.plain_list_scroll_anim = anim
    else
        pcall(function()
            list:scroll_by(0, -delta, false)
        end)
    end
end

local function set_row_focus(
    object,
    focused
)
    if not object then
        return
    end

    object:set {
        bg_color = COLORS.selected,
        bg_opa =
            focused and 255 or 0,
    }
end

local function stop_marquees(model)
    for _, marquee in ipairs(
        model.marquees or {}
    ) do
        if marquee and
            type(marquee.stop) ==
                "function" then
            marquee:stop()
        end
    end
end

local function start_marquees(model)
    -- Only the focused title marquees. Animating title and detail together
    -- produced staggered stalls on long Sync rows.
    local title =
        model.marquees and
        model.marquees[1]

    if title and
        type(title.start) == "function" then
        title:start()
    end

    for index = 2, #(model.marquees or {}) do
        local marquee = model.marquees[index]
        if marquee and
            type(marquee.stop) ==
                "function" then
            marquee:stop()
        end
    end
end

local function register_model(
    self,
    model
)
    self.rows = self.rows or {}
    model.owner = self

    table.insert(
        self.rows,
        model
    )

    remove_from_group(
        model.object
    )

    return model
end

local function register_leading_row(
    self,
    model
)
    self.leading_rows =
        self.leading_rows or {}

    table.insert(
        self.leading_rows,
        model
    )

    return model
end

local function attach_row_events(model)
    local object = model.object

    object:onevent(
        lvgl.EVENT.FOCUSED,
        function()
            model.focused = true

            if model.owner and
                model.owner.ui_active and
                not model.owner.suppress_selection_tracking and
                model.selection_id then
                if model.owner
                        .discography_selection_lock then
                    model.owner.selected_item_id =
                        model.owner
                            .discography_selection_lock
                else
                    model.owner.selected_item_id =
                        model.selection_id
                end
            end

            set_row_focus(
                object,
                true
            )
            if type(model.on_focus_style) ==
                    "function" then
                model.on_focus_style()
            end
            start_marquees(model)

            if type(model.on_focus) ==
                    "function" then
                model.on_focus()
            end

            -- Plain lists (Local root, menus) must bring the focused row into
            -- the clipped viewport. Virtual lists manage their own window or
            -- motion layer and must not use native parent scrolling here.
            local controller =
                model.owner and
                model.owner
                    .virtual_list_controller

            if model.owner and
                model.owner.ui_active and
                not model.owner.suppress_focus_scroll and
                not controller then
                animate_plain_list_reveal(
                    model.owner,
                    object
                )
            end
        end
    )

    object:onevent(
        lvgl.EVENT.DEFOCUSED,
        function()
            if model.owner and
                model.owner
                    .discography_selection_lock and
                model.selection_id and
                tostring(
                    model.owner
                        .discography_selection_lock
                ) == tostring(
                    model.selection_id
                ) then
                -- Escape/discography resume briefly focuses chrome elsewhere
                -- (sort control) before the locked row is reattached. Keep the
                -- logical selection highlighted through that window.
                model.focused = true
                set_row_focus(
                    object,
                    true
                )
                return
            end

            model.focused = false
            set_row_focus(
                object,
                false
            )
            if type(model.on_defocus_style) ==
                    "function" then
                model.on_defocus_style()
            end
            stop_marquees(model)
        end
    )

    local suppress_click = false
    local pending_long_press = false

    object:onevent(
        lvgl.EVENT.PRESSED,
        function()
            suppress_click = false
            pending_long_press = false

            if type(model.on_press) ==
                    "function" then
                model.on_press()
            end

            focus_object(object)
        end
    )

    object:onevent(
        lvgl.EVENT.LONG_PRESSED,
        function()
            if type(model.on_long_press) ~=
                    "function" then
                return
            end

            suppress_click = true

            if model.defer_long_press_until_release then
                pending_long_press = true

                if type(
                    model.on_long_press_preview
                ) == "function" then
                    model.on_long_press_preview()
                end

                return
            end

            model.on_long_press()
        end
    )

    if lvgl.EVENT.RELEASED then
        object:onevent(
            lvgl.EVENT.RELEASED,
            function()
                local handled =
                    pending_long_press

                pending_long_press = false

                if handled and
                    type(model.on_long_press) ==
                        "function" then
                    model.on_long_press()
                end

                if type(model.on_release) ==
                        "function" then
                    model.on_release(handled)
                end
            end
        )
    end

    if lvgl.EVENT.PRESS_LOST then
        object:onevent(
            lvgl.EVENT.PRESS_LOST,
            function()
                pending_long_press = false

                if type(model.on_press_lost) ==
                        "function" then
                    model.on_press_lost()
                end
            end
        )
    end

    object:onClicked(
        function()
            if suppress_click then
                suppress_click = false
                return
            end

            if type(model.on_click) ==
                    "function" then
                model.on_click()
            end
        end
    )
end

local function fallback_badge_width(value)
    local text = tostring(value or "")

    return text,
        math.max(
            20,
            14 + #text * 6
        )
end

local function measure_badge_width(
    label,
    value
)
    local text, fallback =
        fallback_badge_width(value)

    local measured = nil

    local ok =
        pcall(
            function()
                label:set {
                    w = lvgl.SIZE_CONTENT,
                    text = text,
                    text_align = 0,
                }

                label:update_layout()

                local coordinates =
                    label:get_coords()

                measured =
                    coordinates.x2 -
                    coordinates.x1 + 1
            end
        )

    if not ok or
        type(measured) ~= "number" or
        measured <= 0 or
        measured > 120 then
        return text, fallback
    end

    return text,
        math.max(
            20,
            math.floor(measured) + 16
        )
end

local function create_badge(
    row,
    value,
    y,
    right
)
    local text, fallback_width =
        fallback_badge_width(value)

    local model = {
        right = right or 151,
        y = y or 3,
        width = fallback_width,
    }

    model.object =
        row:Object {
            x =
                model.right -
                fallback_width,
            y = model.y,
            w = fallback_width,
            h = 18,
            pad_all = 0,
            border_width = 0,
            radius = 9,
            bg_color = COLORS.badge,
            bg_opa = 255,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    model.object:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    model.object:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    model.label =
        model.object:Label {
            x = 2,
            y = 3,
            w = lvgl.SIZE_CONTENT,
            h = 12,
            text = text,
            text_align = 0,
            text_color =
                COLORS.badge_text,
            text_font =
                font.fusion_10,
        }

    model.label:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    function model:set(next_value)
        local next_text,
            next_width =
            measure_badge_width(
                model.label,
                next_value
            )

        model.width = next_width

        model.object:set {
            x =
                model.right -
                next_width,
            w = next_width,
        }

        model.label:set {
            x = 2,
            w = math.max(
                1,
                next_width - 4
            ),
            text = next_text,
            text_align = 2,
        }

        return next_width
    end

    model:set(value)

    return model
end

local function create_artwork(
    row,
    source,
    requested_size
)
    local thumbnail_size =
        math.max(
            1,
            math.floor(
                tonumber(requested_size) or 28
            )
        )
    local model = {
        current_source = source,
        cache_key = source,
        attached = true,
        placeholder_visible = false,
        bind_generation = 0,
    }

    local function is_placeholder(
        value
    )
        return
            type(value) ~= "string" or
            value == "" or
            value:find(
                "cover_placeholder.png",
                1,
                true
            ) ~= nil
    end

    model.frame =
        row:Object {
            x = 2,
            y = 2,
            w = thumbnail_size,
            h = thumbnail_size,
            pad_all = 0,
            border_width = 0,
            shadow_width = 0,
            radius = 0,
            bg_color =
                COLORS.art_background,
            bg_opa = 0,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    model.frame:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    model.frame:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    if source == "__playlist_blue__" then
        model.frame:set {
            bg_color =
                palette.placeholder_cover,
            bg_opa = 255,
        }

        function model:set(next_source)
            return next_source
        end

        return model
    end

    if source == "__favorites_star__" then
        model.frame:set {
            bg_color = palette.overlay,
            bg_opa = 255,
        }

        local star_color = palette.foreground

        local segments = {
            {13, 5, 2, 1, 128},
            {13, 6, 2, 2, 255},
            {12, 7, 1, 1, 128},
            {15, 7, 1, 1, 128},
            {12, 8, 4, 3, 255},
            {11, 10, 1, 1, 128},
            {16, 10, 1, 1, 128},
            {4, 11, 6, 1, 128},
            {10, 11, 8, 1, 255},
            {18, 11, 6, 1, 128},
            {4, 12, 1, 1, 128},
            {5, 12, 18, 1, 255},
            {23, 12, 1, 1, 128},
            {6, 13, 16, 1, 255},
            {7, 14, 14, 1, 255},
            {8, 15, 1, 1, 128},
            {9, 15, 10, 1, 255},
            {19, 15, 1, 1, 128},
            {9, 16, 1, 1, 128},
            {10, 16, 8, 1, 255},
            {18, 16, 1, 1, 128},
            {9, 17, 10, 3, 255},
            {8, 19, 1, 2, 128},
            {19, 19, 1, 2, 128},
            {9, 20, 3, 1, 255},
            {12, 20, 1, 1, 128},
            {15, 20, 1, 1, 128},
            {16, 20, 3, 1, 255},
            {8, 21, 3, 1, 255},
            {11, 21, 1, 1, 128},
            {16, 21, 1, 1, 128},
            {17, 21, 3, 1, 255},
            {8, 22, 1, 1, 255},
            {9, 22, 1, 1, 128},
            {18, 22, 1, 1, 128},
            {19, 22, 1, 1, 255},
        }

        model.star = {}

        local scale =
            thumbnail_size / 28

        for _, segment in ipairs(
            segments
        ) do
            local piece =
                model.frame:Object {
                    x = math.floor(
                        segment[1] * scale +
                            0.5
                    ),
                    y = math.floor(
                        segment[2] * scale +
                            0.5
                    ),
                    w = math.max(
                        1,
                        math.floor(
                            segment[3] * scale +
                                0.5
                        )
                    ),
                    h = math.max(
                        1,
                        math.floor(
                            segment[4] * scale +
                                0.5
                        )
                    ),
                    pad_all = 0,
                    border_width = 0,
                    radius = 0,
                    bg_color = star_color,
                    bg_opa = segment[5],
                    scrollbar_mode =
                        lvgl.SCROLLBAR_MODE.OFF,
                }

            piece:clear_flag(
                lvgl.FLAG.SCROLLABLE
            )
            piece:clear_flag(
                lvgl.FLAG.CLICKABLE
            )

            table.insert(
                model.star,
                piece
            )
        end

        function model:set(next_source)
            return next_source
        end

        return model
    end

    local placeholder_source =
        "//lua/img/cover_placeholder.png"

    local function bind_thumbnail(
        image,
        next_source
    )
        local decoded_source =
            lvgl.ImgData(next_source)

        -- Source assignment resets an LVGL image object's content dimensions
        -- to the decoded file size. Always restore list-thumbnail geometry,
        -- even when the cache key/path is unchanged.
        image:set {
            src = decoded_source,
        }

        local decoded_width,
            decoded_height =
            image:get_img_size()

        if (not tonumber(decoded_width) or
                not tonumber(decoded_height)) and
            type(next_source) == "string" and
            next_source:sub(1, 2) == "//" then
            decoded_width,
                decoded_height =
                image:get_img_size(
                    next_source:sub(3)
                )
        end
        local zoom = 256

        if tonumber(decoded_width) and
            tonumber(decoded_height) and
            decoded_width > 0 and
            decoded_height > 0 then
            zoom = math.max(
                1,
                math.floor(
                    math.min(
                        thumbnail_size /
                            decoded_width,
                        thumbnail_size /
                            decoded_height
                    ) * 256 + 0.5
                )
            )
        else
            decoded_width = thumbnail_size
            decoded_height = thumbnail_size
        end

        image:set {
            x = 0,
            y = 0,
            w = thumbnail_size,
            h = thumbnail_size,
            align = lvgl.ALIGN.TOP_LEFT,
            offset_x = 0,
            offset_y = 0,
            angle = 0,
            zoom = zoom,
            antialias = true,
            inner_align =
                lvgl.IMAGE_ALIGN.CENTER,
            transform_width = 0,
            transform_height = 0,
            pivot = {
                x = math.floor(
                    decoded_width / 2
                ),
                y = math.floor(
                    decoded_height / 2
                ),
            },
        }

        return decoded_width,
            decoded_height,
            zoom
    end

    -- Keep the placeholder on a separate LVGL image object. Recycled rows can
    -- then hide the old decoded cover immediately without leaving the artwork
    -- area blank while the correct source is loading.
    model.placeholder_image =
        model.frame:Image {
            x = 0,
            y = 0,
            w = thumbnail_size,
            h = thumbnail_size,
            pad_all = 0,
            border_width = 0,
            shadow_width = 0,
            radius = 0,
            bg_opa = 0,
        }

    bind_thumbnail(
        model.placeholder_image,
        placeholder_source
    )

    model.placeholder_image:clear_flag(
        lvgl.FLAG.CLICKABLE
    )
    model.placeholder_image:add_flag(
        lvgl.FLAG.HIDDEN
    )

    model.image =
        model.frame:Image {
            x = 0,
            y = 0,
            w = thumbnail_size,
            h = thumbnail_size,
            pad_all = 0,
            border_width = 0,
            shadow_width = 0,
            radius = 0,
            bg_opa = 0,
        }

    model.image:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    local function show_placeholder()
        local decoded_width,
            decoded_height,
            zoom =
            bind_thumbnail(
                model.placeholder_image,
                placeholder_source
            )

        model.cache_key =
            placeholder_source
        model.decoded_width =
            decoded_width
        model.decoded_height =
            decoded_height
        model.thumbnail_zoom = zoom
        model.placeholder_visible = true
        model.frame:set {
            bg_color =
                palette.placeholder_cover,
            bg_opa = 255,
        }
        model.image:add_flag(
            lvgl.FLAG.HIDDEN
        )
        model.placeholder_image:clear_flag(
            lvgl.FLAG.HIDDEN
        )
        model.image:invalidate()
        model.placeholder_image:invalidate()
        model.frame:invalidate()
    end

    if is_placeholder(source) then
        show_placeholder()
    else
        local decoded_width,
            decoded_height,
            zoom =
            bind_thumbnail(
                model.image,
                source
            )

        model.decoded_width =
            decoded_width
        model.decoded_height =
            decoded_height
        model.thumbnail_zoom = zoom
        model.frame:set {
            bg_opa = 0,
            shadow_width = 0,
            radius = 0,
        }
    end

    function model:is_valid()
        return self.attached == true and
            self.frame ~= nil and
            self.image ~= nil and
            self.placeholder_image ~= nil
    end

    function model:detach()
        self.attached = false
        self.image = nil
        self.placeholder_image = nil
        self.frame = nil
    end

    function model:set(next_source)
        if not self:is_valid() then
            return false
        end

        model.current_source = next_source
        model.bind_generation =
            model.bind_generation + 1

        if is_placeholder(next_source) then
            show_placeholder()
            return true
        end

        -- Hide the recycled image until the new source has been rebound.
        -- This prevents LVGL from painting the previous row's decoded image
        -- for a frame while the source pointer and invalidation propagate.
        model.image:add_flag(
            lvgl.FLAG.HIDDEN
        )
        model.placeholder_image:add_flag(
            lvgl.FLAG.HIDDEN
        )
        model.placeholder_visible = false
        local decoded_width,
            decoded_height,
            zoom =
            bind_thumbnail(
                model.image,
                next_source
            )
        model.cache_key = next_source
        model.decoded_width =
            decoded_width
        model.decoded_height =
            decoded_height
        model.thumbnail_zoom = zoom
        model.frame:set {
            bg_color =
                COLORS.art_background,
            bg_opa = 0,
            shadow_width = 0,
            radius = 0,
        }
        model.image:clear_flag(
            lvgl.FLAG.HIDDEN
        )
        model.image:invalidate()
        model.frame:invalidate()

        return true
    end

    return model
end

function M.create_root(
    self,
    title,
    options
)
    options = options or {}

    self.root =
        lvgl.Object(nil, {
            x = 0,
            y = 0,
            w = 160,
            h = 128,
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_color =
                COLORS.background,
            bg_opa = 255,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        })

    self.root:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )

    local background_path =
        options.background

    if type(background_path) ==
            "string" and
        background_path ~= "" then
        self.background_art =
            self.root:Image {
                x = 0,
                y = 0,
                src =
                    lvgl.ImgData(
                        background_path
                    ),
            }

        local decoded_width,
            decoded_height =
            self.background_art:
                get_img_size()

        decoded_width =
            tonumber(decoded_width) or 160
        decoded_height =
            tonumber(decoded_height) or 128

        local zoom = math.max(
            1,
            math.floor(
                math.max(
                    160 / decoded_width,
                    128 / decoded_height
                ) * 256 + 0.5
            )
        )
        local pivot = {
            x = math.floor(decoded_width / 2),
            y = math.floor(decoded_height / 2),
        }

        self.background_art:set {
            x = 80 - pivot.x,
            y = 64 - pivot.y,
            w = decoded_width,
            h = decoded_height,
            align = lvgl.ALIGN.TOP_LEFT,
            offset_x = 0,
            offset_y = 0,
            angle = 0,
            zoom = zoom,
            pivot = pivot,
            inner_align =
                lvgl.IMAGE_ALIGN.CENTER,
            transform_width = 0,
            transform_height = 0,
            antialias = true,
        }

        self.background_geometry = {
            decoded_width = decoded_width,
            decoded_height = decoded_height,
            zoom = zoom,
            pivot = pivot,
            x = 80 - pivot.x,
            y = 64 - pivot.y,
            target_width = 160,
            target_height = 128,
        }

        self.background_dimmer =
            self.root:Object {
                x = 0,
                y = 0,
                w = 160,
                h = 128,
                pad_all = 0,
                border_width = 0,
                radius = 0,
                bg_color = palette.overlay,
                bg_opa =
                    tonumber(
                        options
                            .background_dimmer_opa
                    ) or 110,
                scrollbar_mode =
                    lvgl.SCROLLBAR_MODE.OFF,
            }

        self.background_dimmer
            :clear_flag(
                lvgl.FLAG.SCROLLABLE
            )
    end

    self.screen_loaded = false

    self.root:onevent(
        lvgl.EVENT.SCREEN_LOADED,
        function()
            self.screen_loaded = true

            if self.ui_active then
                schedule_initial_scroll(
                    self
                )
            end
        end
    )

    self.root:onevent(
        lvgl.EVENT.SCREEN_UNLOAD_START,
        function()
            self.screen_loaded = false
            pending_initial_scrolls[
                self
            ] = nil
        end
    )

    self.base_back =
        options.on_back or
        function()
            backstack.pop()
        end

    self.go_back =
        function()
            if self.sort_menu_open and
                self.close_sort_menu then
                self.close_sort_menu(
                    false
                )
                return
            end

            self.base_back()
        end

    self.status =
        jellyfin_status_bar.create(
            self.root
        )

    self.bindings =
        self.status.bindings

    self.header_marquee =
        jellyfin_marquee.create(
            self.root,
            {
                x = 5,
                y = 15,
                w = 150,
                h = 13,
                label_y = 0,
                text = title or "",
                align = "center",
                text_color =
                    COLORS.primary,
                text_font =
                    font.fusion_10,
                autostart = true,
            }
        )

    -- Preserve the prior public field for any callers that inspect the
    -- non-focusable header object.
    self.header =
        self.header_marquee.view

    self.list =
        lvgl.List(
            self.root,
            {
                x = 2,
                y = 28,
                w = 156,
                h = 100,
            }
        )

    self.list:set {
        pad_all = 0,
        pad_row = 1,
        border_width = 0,
        radius = 0,
        bg_color =
            COLORS.background,
        bg_opa =
            self.background_art and
            0 or 255,
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
        -- Native scroll-to-view duration for Local root and plain lists.
        anim_time = 150,
    }

    self.rows = {}
    self.media_rows = {}
    self.leading_rows = {}
    self.ui_active = false

    remove_from_group(self.list)
    remove_from_group(self.header)
    remove_from_group(
        self.background_art
    )
    remove_from_group(
        self.background_dimmer
    )

    function self:background_state()
        return {
            enabled =
                self.background_art ~= nil,
            source = background_path,
            dimmer_opa =
                self.background_dimmer and
                (
                    tonumber(
                        options
                            .background_dimmer_opa
                    ) or 110
                ) or 0,
            list_transparent =
                self.background_art ~= nil,
            geometry =
                self.background_geometry,
        }
    end
end

local function add_modal_row_events(
    model
)
    model.object:onevent(
        lvgl.EVENT.FOCUSED,
        function()
            model.focused = true
            set_row_focus(
                model.object,
                true
            )

            if type(model.on_focus) ==
                    "function" then
                model.on_focus()
            end
        end
    )

    model.object:onevent(
        lvgl.EVENT.DEFOCUSED,
        function()
            model.focused = false
            set_row_focus(
                model.object,
                false
            )
        end
    )

    model.object:onevent(
        lvgl.EVENT.PRESSED,
        function()
            focus_object(
                model.object
            )
        end
    )

    model.object:onClicked(
        function()
            if type(model.on_click) ==
                    "function" then
                model.on_click()
            end
        end
    )
end

local function sort_method_title(
    method,
    options
)
    if options and
        type(options.method_labels) ==
            "table" and
        type(
            options.method_labels[method]
        ) == "string" then
        return options.method_labels[
            method
        ]
    end

    return ({
        alpha = "Alphabetical",
        recent = "Recently Added",
        title = "Title",
        artist = "Artist",
        date_added = "Date added",
        relevance = "Relevance",
        year = "Year",
        status = "Status",
        newest = "Newest",
    })[method] or tostring(method or "")
end

local function sort_method_badge(
    method,
    options
)
    return ({
        recent =
            options.recent_label or
            "NEW",
        title = "A-Z",
        artist = "ART",
        date_added = "NEW",
        relevance = "REL",
        year = "YEAR",
        status = "STATE",
        newest = "NEW",
    })[method] or
        (
            options.alpha_label or
            "A-Z"
        )
end

function M.add_sort_control(
    self,
    options
)
    options = options or {}

    local methods =
        options.methods or {
            "alpha",
            "recent",
        }

    local row =
        self.list:Button {
            w = lvgl.PCT(100),
            h = 24,
            pad_all = 0,
            border_width = 0,
            outline_width = 0,
            shadow_width = 0,
            radius = 3,
            bg_opa = 0,
        }

    local title =
        jellyfin_marquee.create(
            row,
            {
                x = 5,
                y = 5,
                w = 100,
                h = 14,
                text = "Sort",
                text_color =
                    COLORS.primary,
            }
        )

    local current_badge =
        create_badge(
            row,
            options.current_label or
                "A-Z",
            3,
            151
        )

    local model = {
        object = row,
        marquees = {title},
    }

    attach_row_events(model)
    register_model(self, model)

    self.sort_row = model
    register_leading_row(
        self,
        model
    )
    self.sort_options = options
    self.sort_dirty = false
    self.sort_menu_open = false
    self.sort_selected_method =
        options.current_method or
        methods[1]
    self.sort_committed_method =
        self.sort_selected_method
    self.sort_order_labels = {}

    function self.update_sort_labels(
        state
    )
        if type(state) ~= "table" then
            return
        end

        if state.method then
            self.sort_selected_method =
                state.method
        end

        current_badge:set(
            state.label or
            options.current_label or
            "A-Z"
        )

        local alpha =
            self.sort_order_labels
                .alpha

        if alpha then
            alpha:set(
                state.alpha_label or
                "A-Z"
            )
        end

        local recent =
            self.sort_order_labels
                .recent

        if recent then
            recent:set(
                state.recent_label or
                "NEW"
            )
        end
    end

    local function update_from(
        callback,
        method,
        mark_dirty
    )
        if type(callback) ~= "function" then
            return false
        end

        local state = callback(method)

        if type(state) ~= "table" then
            return false
        end

        if mark_dirty ~= false then
            self.sort_dirty = true
        end
        self.update_sort_labels(state)

        return true
    end

    function self.sort_select(method)
        return update_from(
            options.on_highlight or
                options.on_select,
            method,
            options.highlight_is_preview ~=
                true
        )
    end

    if #methods == 1 then
        model.on_click =
            function()
                local changed =
                    update_from(
                        options.on_toggle or
                            options.on_select,
                        methods[1]
                    )

                if changed and
                    type(options.on_apply) ==
                        "function" then
                    self.sort_dirty = false
                    options.on_apply()
                end
            end

        return model
    end

    local overlay =
        self.root:Object {
            x = 0,
            y = 0,
            w = 160,
            h = 128,
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_opa = 0,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    overlay:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    overlay:add_flag(
        lvgl.FLAG.HIDDEN
    )
    remove_from_group(overlay)

    local dimmer =
        overlay:Button {
            x = 0,
            y = 0,
            w = 160,
            h = 128,
            pad_all = 0,
            border_width = 0,
            outline_width = 0,
            shadow_width = 0,
            radius = 0,
            bg_color = palette.overlay,
            bg_opa = 105,
        }

    remove_from_group(dimmer)

    local sheet_height =
        #methods * 25 + 2

    local sheet =
        overlay:Object {
            x = 2,
            y = 126 - sheet_height,
            w = 156,
            h = sheet_height,
            pad_all = 1,
            border_width = 1,
            border_color =
                COLORS.modal_border,
            radius = 8,
            bg_color = COLORS.modal,
            bg_opa = 255,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    sheet:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    remove_from_group(sheet)

    self.sort_overlay = overlay
    self.sort_dimmer = dimmer
    self.sort_menu_models = {}

    for index, method in ipairs(
        methods
    ) do
        local option =
            sheet:Button {
                x = 1,
                y = (index - 1) * 25,
                w = 152,
                h = 23,
                pad_all = 0,
                border_width = 0,
                outline_width = 0,
                shadow_width = 0,
                radius = 4,
                bg_opa = 0,
            }

        local method_title =
            sort_method_title(
                method,
                options
            )

        option:Label {
            x = 6,
            y = 5,
            w = 104,
            h = 13,
            text = method_title,
            text_color =
                COLORS.primary,
            text_font =
                font.fusion_10,
        }

        local order_badge =
            create_badge(
                option,
                sort_method_badge(
                    method,
                    options
                ),
                3,
                147
            )

        local option_model = {
            object = option,
            method = method,
            label_text = method_title,
            order_badge =
                order_badge,
        }

        option_model.on_focus =
            function()
                if not self.sort_menu_open or
                    self.sort_selected_method ==
                        method then
                    return
                end

                update_from(
                    options.on_highlight or
                        options.on_select,
                    method,
                    options.highlight_is_preview ~=
                        true
                )
            end

        option_model.on_click =
            function()
                for _, candidate in ipairs(
                    self.sort_menu_models
                ) do
                    candidate.focused = false
                    set_row_focus(
                        candidate.object,
                        false
                    )
                end

                option_model.focused = true
                focus_object(
                    option_model.object,
                    false
                )
                set_row_focus(
                    option_model.object,
                    true
                )

                local selecting_field =
                    options
                        .select_field_before_toggle ==
                        true and
                    self.sort_committed_method ~=
                        method
                local callback =
                    selecting_field and
                    (
                        options.on_select or
                        options.on_toggle
                    ) or
                    (
                        options.on_toggle or
                        options.on_select
                    )

                if update_from(
                    callback,
                    method,
                    true
                ) then
                    self.sort_committed_method =
                        method
                end
            end

        add_modal_row_events(
            option_model
        )
        remove_from_group(option)

        table.insert(
            self.sort_menu_models,
            option_model
        )

        self.sort_order_labels[
            method
        ] = order_badge
    end

    local function remove_screen_rows()
        for _, screen_row in ipairs(
            self.rows or {}
        ) do
            stop_marquees(
                screen_row
            )
            set_row_focus(
                screen_row.object,
                false
            )
            remove_from_group(
                screen_row.object
            )
        end
    end

    local function add_screen_rows()
        if not self.ui_active then
            return
        end

        local group =
            self.focus_group or
            lvgl.group.get_default()

        for _, screen_row in ipairs(
            self.rows or {}
        ) do
            add_to_group(
                group,
                screen_row.object
            )
        end
    end

    function self.open_sort_menu()
        if self.sort_menu_open or
            not self.ui_active then
            return
        end

        if self.virtual_list_controller then
            self.virtual_list_controller
                :suspend_continuous_input()
        end

        overlay:clear_flag(
            lvgl.FLAG.HIDDEN
        )

        self.sort_menu_open = true

        local selected_model = nil

        for _, option_model in ipairs(
            self.sort_menu_models
        ) do
            option_model.focused = false
            set_row_focus(
                option_model.object,
                false
            )
            add_to_group(
                self.focus_group,
                option_model.object
            )

            if option_model.method ==
                    self.sort_selected_method then
                selected_model =
                    option_model
            end
        end

        selected_model =
            selected_model or
            self.sort_menu_models[1]

        if selected_model then
            selected_model.focused = true
            focus_object(
                selected_model.object,
                false
            )
            set_row_focus(
                selected_model.object,
                true
            )
        end

        remove_screen_rows()

        jellyfin_navigation.set_back(
            self.go_back
        )
    end

    function self.close_sort_menu(
        suppress_apply
    )
        if not self.sort_menu_open then
            return
        end

        add_screen_rows()

        if self.ui_active and
            self.sort_row then
            focus_object(
                self.sort_row.object,
                false
            )
        end

        for _, option_model in ipairs(
            self.sort_menu_models
        ) do
            option_model.focused = false
            set_row_focus(
                option_model.object,
                false
            )
            remove_from_group(
                option_model.object
            )
        end

        overlay:add_flag(
            lvgl.FLAG.HIDDEN
        )

        self.sort_menu_open = false

        local should_apply =
            self.sort_dirty and
            not suppress_apply and
            type(options.on_apply) ==
                "function"

        self.sort_dirty = false

        if should_apply then
            options.on_apply()
        elseif type(options.on_restore) ==
                "function" then
            local restored =
                options.on_restore()
            if type(restored) ==
                    "table" then
                self.update_sort_labels(
                    restored
                )
                self.sort_committed_method =
                    restored.method or
                    self.sort_committed_method
            end
        end

        if self.ui_active and
            self.virtual_list_controller then
            self.virtual_list_controller
                :resume_continuous_input()
        end
    end

    dimmer:onClicked(
        function()
            self.close_sort_menu(
                false
            )
        end
    )

    model.on_click =
        self.open_sort_menu

    return model
end

function M.add_play_control(
    self,
    options
)
    options = options or {}

    -- Keep the compact collection control as the first visible and focused
    -- item. On sorted collection screens, only the Sort row is initially
    -- scrolled above it; rotating upward still reveals Sort.
    local container =
        self.list:Object {
            w = lvgl.PCT(100),
            h = 24,
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_opa = 0,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    container:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    container:clear_flag(
        lvgl.FLAG.CLICKABLE
    )
    remove_from_group(container)

    local button =
        container:Button {
            x = 66,
            y = 0,
            w = 24,
            h = 24,
            pad_all = 0,
            border_width = 0,
            outline_width = 0,
            shadow_width = 0,
            radius = 12,
            bg_opa = 0,
        }

    -- PNG image children and LVGL background images do not render reliably
    -- inside this compact button in the desktop simulator. Draw the two
    -- monochrome icons from small LVGL objects instead. This uses the same
    -- primitive rendering path as the Favorites star artwork.
    local function create_icon_piece(
        x,
        y,
        width,
        height,
        color
    )
        local piece =
            button:Object {
                x = x,
                y = y,
                w = width,
                h = height,
                pad_all = 0,
                border_width = 0,
                radius = 0,
                bg_color = color,
                bg_opa = 255,
                scrollbar_mode =
                    lvgl.SCROLLBAR_MODE.OFF,
            }

        piece:clear_flag(
            lvgl.FLAG.SCROLLABLE
        )
        piece:clear_flag(
            lvgl.FLAG.CLICKABLE
        )
        remove_from_group(piece)

        return piece
    end

    local function create_icon(
        runs,
        offset_x,
        offset_y,
        color
    )
        local pieces = {}

        for _, run in ipairs(runs) do
            table.insert(
                pieces,
                create_icon_piece(
                    offset_x + run[1],
                    offset_y + run[2],
                    run[3],
                    run[4] or 1,
                    color
                )
            )
        end

        return pieces
    end

    local function set_icon_visible(
        pieces,
        visible
    )
        for _, piece in ipairs(pieces) do
            if visible then
                piece:clear_flag(
                    lvgl.FLAG.HIDDEN
                )
            else
                piece:add_flag(
                    lvgl.FLAG.HIDDEN
                )
            end
        end
    end

    -- Use a small number of rectangular primitives so the icons remain
    -- inexpensive even when several collection screens are on the backstack.
    local play_icon =
        create_icon(
            {
                {8, 6, 2, 12},
                {10, 7, 2, 10},
                {12, 8, 2, 8},
                {14, 9, 2, 6},
                {16, 10, 2, 4},
            },
            0,
            0,
            COLORS.primary
        )

    local shuffle_icon =
        create_icon(
            {
                -- Upper-left input crossing to the lower-right output.
                {5, 8, 4, 2},
                {9, 9, 3, 2},
                {11, 11, 3, 2},
                {13, 14, 5, 2},
                {16, 16, 2, 2},
                {18, 13, 2, 4},
                -- Lower-left input crossing to the upper-right output.
                {5, 14, 4, 2},
                {9, 13, 3, 2},
                {13, 9, 5, 2},
                {16, 7, 2, 2},
                {18, 8, 2, 4},
            },
            0,
            0,
            COLORS.background
        )

    set_icon_visible(
        shuffle_icon,
        false
    )

    local model = {
        object = button,
        container = container,
        play_icon = play_icon,
        shuffle_icon = shuffle_icon,
        icon_mode = "play",
        selection_id =
            options.selection_id or
            "control:play",
    }

    local function set_shuffle_preview(
        enabled
    )
        model.icon_mode =
            enabled and "shuffle" or "play"

        set_icon_visible(
            play_icon,
            not enabled
        )
        set_icon_visible(
            shuffle_icon,
            enabled
        )

        if enabled then
            button:set {
                bg_color =
                    COLORS.primary,
                bg_opa = 255,
            }
        else
            set_row_focus(
                button,
                model.focused == true
            )
        end
    end

    model.set_shuffle_preview =
        set_shuffle_preview
    model.reset_preview =
        function()
            set_shuffle_preview(false)
        end
    model.on_click =
        options.on_play
    model.on_long_press =
        options.on_shuffle
    model.defer_long_press_until_release =
        true
    model.on_press =
        model.reset_preview
    model.on_long_press_preview =
        function()
            if type(options.on_shuffle) ==
                    "function" then
                set_shuffle_preview(true)
            end
        end
    model.on_release =
        model.reset_preview
    model.on_press_lost =
        model.reset_preview

    attach_row_events(model)
    register_model(self, model)
    register_leading_row(
        self,
        model
    )

    self.play_row = model
    self.initial_focus_object = button
    self.initial_scroll_anchor = button

    return model
end

local function ensure_sort_scroll_room(self)
    if not self or
        not self.sort_row or
        not self.list or
        self.sort_scroll_spacer then
        return
    end

    self.sort_scroll_spacer =
        self.list:Object {
            w = lvgl.PCT(100),
            h = INITIAL_SCROLL_ROOM,
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_opa = 0,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    self.sort_scroll_spacer:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    self.sort_scroll_spacer:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    remove_from_group(
        self.sort_scroll_spacer
    )
end

local function cancel_resume_repaint(self)
    if not self.resume_repaint_timer then
        return
    end

    pcall(
        function()
            self.resume_repaint_timer:delete()
        end
    )
    self.resume_repaint_timer = nil
end

local function schedule_resume_repaint(
    self,
    controller
)
    cancel_resume_repaint(self)

    self.resume_repaint_generation =
        (self.resume_repaint_generation or 0) + 1

    local generation =
        self.resume_repaint_generation

    resume_trace(
        "schedule post-pop repaint generation=" ..
            tostring(generation)
    )

    self.resume_repaint_timer =
        lvgl.Timer {
            period = 1,
            repeat_count = 1,
            cb = function()
                self.resume_repaint_timer = nil

                resume_trace(
                    "post-pop repaint tick generation=" ..
                        tostring(generation) ..
                        " active=" ..
                        tostring(self.ui_active)
                )

                if not self.ui_active or
                    self.virtual_list_controller ~= controller or
                    self.resume_repaint_generation ~= generation then
                    return
                end

                self.suppress_focus_scroll = true
                self.suppress_selection_tracking =
                    true

                if type(
                    controller
                        .repair_resumed_viewport
                ) == "function" and
                    self.controls_installed_once then
                    controller:
                        repair_resumed_viewport()
                elseif type(
                    controller
                        .invalidate_viewport
                ) == "function" then
                    controller:
                        invalidate_viewport()
                end

                local focused_object =
                    selected_row_object(self) or
                    self.initial_focus_object or
                    self.first_row

                if focused_object then
                    focus_object(
                        focused_object,
                        false
                    )
                end

                for _, model in ipairs(
                    self.rows or {}
                ) do
                    local focused =
                        model.object ==
                        focused_object
                    set_row_focus(
                        model.object,
                        focused
                    )
                    model.focused = focused
                    if focused then
                        start_marquees(model)
                    else
                        stop_marquees(model)
                    end
                end

                self.suppress_selection_tracking =
                    false
                self.suppress_focus_scroll = false
            end,
        }
end

function M.install_controls(self)
    self.ui_active = true

    resume_trace(
        "install-controls start resumed=" ..
            tostring(
                self.controls_installed_once ==
                    true
            )
    )

    if self.header_marquee then
        self.header_marquee:refresh(true)
        self.header_marquee:start()
    end

    ensure_sort_scroll_room(self)

    local group =
        lvgl.group.get_default()

    self.focus_group = group

    local got_wrap,
        previous_wrap =
        pcall(
            function()
                return group:get_wrap()
            end
        )

    self.previous_group_wrap =
        got_wrap and
        previous_wrap or true

    pcall(
        function()
            group:set_wrap(false)
        end
    )

    local resuming =
        self.controls_installed_once ==
            true

    local restored_object = nil
    local restored_fixed_viewport = false

    if resuming and
        self.virtual_list_controller and
        type(
            self.virtual_list_controller
                .resume_viewport
        ) == "function" then
        local restored_model =
            self.virtual_list_controller:
                resume_viewport()

        restored_object =
            restored_model and
            restored_model.object or
            nil
        restored_fixed_viewport =
            restored_model ~= nil and
            self.virtual_list_controller
                .fixed_viewport == true

        resume_trace(
            "resume-viewport returned=" ..
                tostring(restored_model ~= nil)
        )
    end

    restored_object =
        restored_object or
        (
            resuming and
            selected_row_object(self) or
            nil
        )

    if resuming and
        not self.virtual_list_controller then
        restore_plain_list_scroll(self)
    end

    self.suppress_selection_tracking = true
    self.suppress_focus_scroll =
        resuming == true or
        (
            self.virtual_list_controller and
            self.virtual_list_controller
                .fixed_viewport == true
        )

    for _, model in ipairs(
        self.rows or {}
    ) do
        remove_from_group(
            model.object
        )
        add_to_group(
            group,
            model.object
        )
    end

    local initial_object =
        restored_object or
        self.initial_focus_object or
        self.first_row or
        (
            self.rows[1] and
            self.rows[1].object
        )

    -- Fixed-viewport catalogs must never use native animated scroll-to-view
    -- during mount/resume. Only encoder selection may animate the motion layer.
    -- Plain Sync root resume must also stay non-animated.
    local allow_native_scroll =
        not resuming and
        not restored_fixed_viewport and
        not (
            self.virtual_list_controller and
            self.virtual_list_controller
                .fixed_viewport == true
        )

    focus_object(
        initial_object,
        allow_native_scroll
    )

    -- Paint the restored/default selection on the first frame without waiting
    -- for a wheel event. FOCUSED may already have fired; force the chrome.
    for _, model in ipairs(
        self.rows or {}
    ) do
        local focused =
            model.object == initial_object

        set_row_focus(
            model.object,
            focused
        )
        model.focused = focused

        if focused then
            start_marquees(model)
            if type(model.on_focus_style) ==
                    "function" then
                model.on_focus_style()
            end
        else
            stop_marquees(model)
            if type(model.on_defocus_style) ==
                    "function" then
                model.on_defocus_style()
            end
        end
    end

    -- Keep resume scroll suppression through the next tick so a delayed
    -- FOCUSED event cannot start animate_plain_list_reveal after Escape.
    if resuming then
        local generation =
            (self.resume_scroll_suppress_generation or 0) + 1
        self.resume_scroll_suppress_generation =
            generation
        self.suppress_focus_scroll = true
        self.suppress_selection_tracking = false

        lvgl.Timer {
            period = 1,
            repeat_count = 1,
            cb = function()
                if self.resume_scroll_suppress_generation ~=
                        generation then
                    return
                end
                if self.ui_active and
                    not (
                        self.virtual_list_controller and
                        self.virtual_list_controller
                            .fixed_viewport == true
                    ) then
                    restore_plain_list_scroll(self)
                end
                self.suppress_focus_scroll = false
            end,
        }
    else
        self.suppress_focus_scroll = false
        self.suppress_selection_tracking = false
    end

    resume_trace(
        "focus assigned native-scroll=" ..
            tostring(allow_native_scroll)
    )

    if restored_fixed_viewport and
        type(
            self.virtual_list_controller
                .invalidate_viewport
        ) == "function" then
        self.virtual_list_controller:
            invalidate_viewport()

        -- firmware_backstack.pop() invokes on_show before it loads the
        -- restored native LVGL screen. Repair the painted viewport once, on
        -- the following LVGL tick, after screen load and focus/layout work.
        schedule_resume_repaint(
            self,
            self.virtual_list_controller
        )
    end

    if not resuming then
        schedule_initial_scroll(self)
    end

    self.controls_installed_once = true

    if self.virtual_list_controller then
        self.virtual_list_controller
            :install_continuous_input()
    end

    jellyfin_navigation.set_back(
        self.go_back
    )

    resume_trace("install-controls end")

    local hooks = controls.hooks()

    local input_method =
        hooks.wheel or
        hooks.dpad

    if not input_method then
        return
    end

    self.input_method =
        input_method

    if input_method.up then
        self.previous_up_long =
            input_method.up.long_press

        input_method.up.long_press =
            self.go_back
    end
end

function M.restore_controls(self)
    self.ui_active = false

    cancel_plain_list_scroll(self)

    self.resume_repaint_generation =
        (self.resume_repaint_generation or 0) + 1
    cancel_resume_repaint(self)

    if self.virtual_list_controller and
        type(
            self.virtual_list_controller
                .capture_resume_viewport
        ) == "function" then
        self.virtual_list_controller:
            capture_resume_viewport()
    else
        capture_plain_list_scroll(self)
    end

    if self.header_marquee then
        self.header_marquee:stop()
    end

    if self.track_action_sheet and
        self.track_action_sheet.is_open then
        self.track_action_sheet:close(true)
    end

    self.suppress_selection_tracking = true
    pending_initial_scrolls[self] = nil

    if self.virtual_list_controller then
        self.virtual_list_controller
            :restore_continuous_input()
    end

    if self.sort_menu_open and
        self.close_sort_menu then
        self.close_sort_menu(
            true
        )
    end

    for _, model in ipairs(
        self.rows or {}
    ) do
        if type(model.reset_preview) ==
                "function" then
            model.reset_preview()
        end

        stop_marquees(model)
        set_row_focus(
            model.object,
            false
        )
        remove_from_group(
            model.object
        )
    end

    for _, option_model in ipairs(
        self.sort_menu_models or {}
    ) do
        set_row_focus(
            option_model.object,
            false
        )
        remove_from_group(
            option_model.object
        )
    end

    jellyfin_navigation.clear_back(
        self.go_back
    )

    if self.focus_group then
        pcall(
            function()
                self.focus_group:set_wrap(
                    self.previous_group_wrap ~=
                        false
                )
            end
        )
    end

    self.focus_group = nil

    local input_method =
        self.input_method

    if input_method and
        input_method.up and
        input_method.up.long_press ==
            self.go_back then
        input_method.up.long_press =
            self.previous_up_long
    end

    self.input_method = nil
    self.suppress_selection_tracking = false
end

function M.focus_first_row(self)
    if not self.ui_active then
        return
    end

    local initial_object =
        self.first_row or
        (
            self.rows[1] and
            self.rows[1].object
        )

    focus_object(initial_object)


    schedule_initial_scroll(self)
end

local function object_height(object)
    if not object then
        return nil
    end

    local ok, coordinates =
        pcall(
            function()
                return object:get_coords()
            end
        )

    if not ok or
        type(coordinates) ~= "table" then
        return nil
    end

    local height =
        tonumber(coordinates.y2) and
        tonumber(coordinates.y1) and
        coordinates.y2 -
            coordinates.y1 + 1 or
        nil

    if not height or height <= 0 then
        return nil
    end

    return height, coordinates
end

local function inferred_visible_items(
    self,
    models
)
    local list_height =
        self and self.list and
        object_height(self.list)
    local row_height = nil
    local first_coordinates = nil

    if models[1] then
        row_height,
            first_coordinates =
            object_height(
                models[1].object
            )
    end

    if not list_height or
        not row_height then
        return nil
    end

    local spacing = 1

    if models[2] then
        local _, second_coordinates =
            object_height(
                models[2].object
            )

        if first_coordinates and
            second_coordinates then
            spacing =
                math.max(
                    0,
                    second_coordinates.y1 -
                        first_coordinates.y2 -
                        1
                )
        end
    end

    return
        math.max(
            1,
            math.floor(
                (list_height + spacing) /
                (row_height + spacing)
            )
        )
end

function M.attach_scroll_indicator(
    self,
    models,
    options
)
    models = models or {}

    if options == false then
        return nil
    end

    local indicator_options = {}

    if type(options) == "table" then
        for key, value in pairs(options) do
            indicator_options[key] = value
        end
    end

    if indicator_options.visible_items == nil then
        indicator_options.visible_items =
            inferred_visible_items(
                self,
                models
            )
    end

    if indicator_options.height == nil and
        self and self.list then
        local list_height = nil

        pcall(function()
            local coordinates =
                self.list:get_coords()
            list_height =
                coordinates.y2 -
                coordinates.y1 + 1
        end)

        if type(list_height) == "number" and
            list_height > 0 then
            indicator_options.height =
                math.max(1, list_height - 4)
        end
    end

    local indicator =
        jellyfin_scroll_indicator.create(
            self and self.list,
            indicator_options
        )

    if not indicator then
        return nil
    end

    indicator.models = models
    indicator.item_count =
        math.max(
            #models,
            math.floor(
                tonumber(
                    indicator_options.total_count or
                    indicator_options.item_count
                ) or #models
            )
        )

    local function bind_focus(
        model,
        row_index
    )
        if model then
            local previous_on_focus =
                model.on_focus

            model.on_focus = function()
                if type(previous_on_focus) ==
                        "function" then
                    previous_on_focus()
                end

                indicator:update(
                    indicator.item_count,
                    row_index
                )
            end
        end
    end

    for index, model in ipairs(models) do
        bind_focus(model, index)
    end

    -- Several controls may share one logical scrollbar row (for example the
    -- three horizontal Sync quick actions). Bind those focus aliases to the
    -- same logical index without adding them to the item count.
    for _, alias in ipairs(
        indicator_options.focus_aliases or {}
    ) do
        bind_focus(
            alias.model or alias[1],
            math.max(
                1,
                math.floor(
                    tonumber(
                        alias.index or alias[2]
                    ) or 1
                )
            )
        )
    end

    indicator:initialize(
        indicator.item_count,
        math.max(
            1,
            math.floor(
                tonumber(
                    indicator_options
                        .initial_index
                ) or 1
            )
        )
    )

    self.scroll_indicator = indicator

    return indicator
end

function M.add_action_row(
    self,
    label,
    options
)
    options = options or {}

    local row =
        self.list:Button {
            w = lvgl.PCT(100),
            h = tonumber(options.height) or MENU_ROW_HEIGHT,
            pad_all = 0,
            border_width = 0,
            outline_width = 0,
            shadow_width = 0,
            radius = 3,
            bg_opa = 0,
        }

    local text =
        jellyfin_marquee.create(
            row,
            {
                x = tonumber(options.x) or 5,
                y = tonumber(options.y) or MENU_TEXT_Y,
                w = tonumber(options.width) or 150,
                h = tonumber(options.text_height) or MENU_TEXT_HEIGHT,
                text = label or "",
                text_color =
                    options.text_color or
                    COLORS.primary,
                align = options.align,
            }
        )

    local model = {
        object = row,
        label = text,
        marquees = {text},
        on_click = options.on_click,
        on_long_press = options.on_long_press,
        selection_id =
            normalize_selection_id(
                options.selection_id
            ),
    }

    function model:set_label(next_label)
        text:set(next_label or "")
    end

    attach_row_events(model)
    register_model(self, model)

    if options.leading then
        register_leading_row(self, model)
    end

    return model
end

function M.add_quick_actions(
    self,
    actions
)
    local container =
        self.list:Object {
            w = lvgl.PCT(100),
            h = 34,
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_opa = 0,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    container:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    container:clear_flag(
        lvgl.FLAG.CLICKABLE
    )
    remove_from_group(container)

    local models = {}
    local count = math.max(
        1,
        #(actions or {})
    )
    local gap = 2
    local width =
        math.floor(
            (154 - gap * (count - 1)) /
            count
        )

    for index, action in ipairs(
        actions or {}
    ) do
        local button =
            container:Button {
                x =
                    (index - 1) *
                    (width + gap),
                y = 0,
                w = width,
                h = 32,
                pad_all = 0,
                border_width = 1,
                border_color =
                    palette.divider,
                outline_width = 0,
                shadow_width = 0,
                radius = 3,
                bg_color =
                    COLORS.selected,
                bg_opa = 0,
            }

        local icon
        local icon_parts = {}
        local icon_color = COLORS.primary

        local function icon_part(properties)
            properties.pad_all = 0
            properties.shadow_width = 0
            properties.bg_color =
                properties.bg_color or
                icon_color
            properties.bg_opa =
                properties.bg_opa or 255
            local part =
                button:Object(properties)
            part:clear_flag(
                lvgl.FLAG.CLICKABLE
            )
            part:clear_flag(
                lvgl.FLAG.SCROLLABLE
            )
            remove_from_group(part)
            table.insert(icon_parts, part)
            return part
        end

        if action.icon_kind == "search" then
            icon_part {
                x = math.floor(width / 2) - 5,
                y = 2,
                w = 8,
                h = 8,
                radius = 4,
                border_width = 1,
                border_color = icon_color,
                bg_opa = 0,
            }
            icon_part {
                x = math.floor(width / 2) + 2,
                y = 9,
                w = 2,
                h = 2,
                radius = 0,
                border_width = 0,
            }
            icon_part {
                x = math.floor(width / 2) + 4,
                y = 11,
                w = 2,
                h = 2,
                radius = 0,
                border_width = 0,
            }
        elseif action.icon_kind == "album" then
            icon_part {
                x = math.floor(width / 2) - 6,
                y = 2,
                w = 12,
                h = 12,
                radius = 2,
                border_width = 1,
                border_color = icon_color,
                bg_opa = 0,
            }
            icon_part {
                x = math.floor(width / 2) - 2,
                y = 6,
                w = 4,
                h = 4,
                radius = 2,
                border_width = 0,
            }
        elseif action.icon_kind == "tracks" then
            icon_part {
                x = math.floor(width / 2),
                y = 2,
                w = 2,
                h = 9,
                radius = 0,
                border_width = 0,
            }
            icon_part {
                x = math.floor(width / 2),
                y = 2,
                w = 7,
                h = 2,
                radius = 0,
                border_width = 0,
            }
            icon_part {
                x = math.floor(width / 2) - 4,
                y = 9,
                w = 5,
                h = 4,
                radius = 2,
                border_width = 0,
            }
        else
            icon =
                button:Label {
                    x = 0,
                    y = 2,
                    w = width,
                    h = 12,
                    text = action.icon or "",
                    text_align = 1,
                    text_color =
                        COLORS.primary,
                    text_font =
                        font.fusion_10,
                }
            icon:clear_flag(
                lvgl.FLAG.CLICKABLE
            )
        end

        local label =
            button:Label {
                x = 0,
                y = 17,
                w = width,
                h = 12,
                text = action.label or "",
                text_align = 2,
                text_color =
                    COLORS.secondary,
                text_font =
                    font.fusion_10,
            }

        label:clear_flag(
            lvgl.FLAG.CLICKABLE
        )

        local model = {
            object = button,
            icon = icon,
            icon_parts = icon_parts,
            label = label,
            icon_text = action.icon or "",
            label_text = action.label or "",
            label_text_align = 2,
            marquees = {},
            on_click = action.on_click,
            selection_id =
                normalize_selection_id(
                    action.selection_id
                ),
        }

        attach_row_events(model)
        register_model(self, model)
        register_leading_row(
            self,
            model
        )
        table.insert(models, model)
    end

    return models, container
end

function M.add_toggle_actions(
    self,
    actions
)
    local container =
        self.list:Object {
            w = lvgl.PCT(100),
            h = 27,
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_opa = 0,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    container:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    container:clear_flag(
        lvgl.FLAG.CLICKABLE
    )
    remove_from_group(container)

    local models = {}
    local gap = 3
    local count = math.max(
        1,
        #(actions or {})
    )
    local width =
        math.floor(
            (154 - gap * (count - 1)) /
            count
        )

    for index, action in ipairs(
        actions or {}
    ) do
        local button =
            container:Button {
                x = (index - 1) *
                    (width + gap),
                y = 1,
                w = width,
                h = 24,
                pad_all = 0,
                border_width = 1,
                border_color =
                    palette.divider,
                outline_width = 0,
                shadow_width = 0,
                radius = 4,
                bg_color =
                    COLORS.selected,
                bg_opa =
                    action.active and
                    150 or 0,
            }
        local label =
            button:Label {
                x = 0,
                y = 6,
                w = width,
                h = 13,
                text = action.label or "",
                text_align = 2,
                text_color =
                    COLORS.primary,
                text_font =
                    font.fusion_10,
            }
        label:clear_flag(
            lvgl.FLAG.CLICKABLE
        )

        local model = {
            object = button,
            label = label,
            label_text_align = 2,
            active = action.active == true,
            marquees = {},
            on_click = action.on_click,
            selection_id =
                normalize_selection_id(
                    action.selection_id
                ),
        }

        function model:set_active(active)
            self.active = active == true
            self.object:set {
                bg_color =
                    self.active and
                    palette.accent_muted or
                    COLORS.selected,
                bg_opa =
                    self.active and
                    255 or 0,
            }
        end

        model.on_focus_style =
            function()
                button:set {
                    bg_color =
                        model.active and
                        palette.accent or
                        COLORS.selected,
                    bg_opa = 255,
                }
            end
        model.on_defocus_style =
            function()
                button:set {
                    bg_color =
                        model.active and
                        palette.accent_muted or
                        COLORS.selected,
                    bg_opa =
                        model.active and
                        255 or 0,
                }
            end
        attach_row_events(model)
        register_model(self, model)
        model:set_active(model.active)
        table.insert(models, model)
    end

    return models, container
end

function M.add_section_label(
    self,
    value
)
    local row =
        self.list:Object {
            w = lvgl.PCT(100),
            h = 17,
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_opa = 0,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    row:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    row:clear_flag(
        lvgl.FLAG.CLICKABLE
    )
    remove_from_group(row)

    local label =
        row:Label {
            x = 0,
            y = 2,
            w = 154,
            h = 13,
            text = value or "",
            text_align = 2,
            text_color =
                COLORS.primary,
            text_font =
                font.fusion_10,
        }

    label:clear_flag(
        lvgl.FLAG.CLICKABLE
    )
    remove_from_group(label)

    return {
        object = row,
        label = label,
        text = value or "",
    }
end

function M.add_count_row(
    self,
    title,
    count,
    callback,
    selection_id
)
    local row =
        media_row_parent(self):Button {
            w = lvgl.PCT(100),
            h = MENU_ROW_HEIGHT,
            pad_all = 0,
            border_width = 0,
            outline_width = 0,
            shadow_width = 0,
            radius = 3,
            bg_opa = 0,
        }

    local badge =
        create_badge(
            row,
            count,
            3,
            151
        )

    local title_marquee =
        jellyfin_marquee.create(
            row,
            {
                x = 5,
                y = MENU_TEXT_Y,
                w = 139 - badge.width,
                h = MENU_TEXT_HEIGHT,
                text = title,
                text_color =
                    COLORS.primary,
            }
        )

    local model = {
        object = row,
        marquees = {
            title_marquee,
        },
        title = title_marquee,
        badge = badge,
        on_click = callback,
        selection_id =
            normalize_selection_id(
                selection_id
            ),
    }

    function model:update(
        next_title,
        next_count,
        next_callback,
        next_selection_id
    )
        local width =
            badge:set(
                next_count
            )

        title_marquee:set_width(
            139 - width
        )
        title_marquee:set(
            next_title or ""
        )
        model.on_click =
            next_callback
        update_model_selection(
            model,
            next_selection_id
        )
    end

    attach_row_events(model)

    return register_model(
        self,
        model
    )
end

function M.add_compact_text_row(
    self,
    title,
    callback,
    selection_id,
    width
)
    local row =
        media_row_parent(self):Button {
            w = lvgl.PCT(100),
            h = 13,
            pad_all = 0,
            border_width = 0,
            outline_width = 0,
            shadow_width = 0,
            radius = 2,
            bg_opa = 0,
        }

    local label = row:Label {
        x = 4,
        y = 1,
        w = tonumber(width) or 146,
        h = 11,
        text = title or "",
        text_color = COLORS.primary,
        text_font = font.fusion_10,
        long_mode = lvgl.LABEL.LONG_DOT,
    }
    label:clear_flag(lvgl.FLAG.CLICKABLE)
    remove_from_group(label)

    local model = {
        object = row,
        label = label,
        on_click = callback,
        selection_id =
            normalize_selection_id(
                selection_id
            ),
    }

    function model:update(
        next_title,
        next_callback,
        next_selection_id
    )
        label:set {text = next_title or ""}
        model.on_click = next_callback
        update_model_selection(
            model,
            next_selection_id
        )
    end

    attach_row_events(model)
    return register_model(self, model)
end

function M.add_album_row(
    self,
    album,
    artwork_source,
    callback_or_options
)
    local options =
        type(callback_or_options) == "table" and
        callback_or_options or
        {
            on_click = callback_or_options,
        }
    local row =
        media_row_parent(self):Button {
            w = lvgl.PCT(100),
            h = MEDIA_ROW_HEIGHT,
            pad_all = 0,
            border_width = 0,
            outline_width = 0,
            shadow_width = 0,
            radius = 3,
            bg_opa = 0,
        }

    local artwork =
        create_artwork(
            row,
            artwork_source,
            MEDIA_ARTWORK_SIZE
        )

    local badge_hidden =
        options.hide_trailing_badge == true
    local badge_value =
        badge_hidden and "" or
        (
            options.trailing_status or
            album.track_count or 0
        )
    local badge =
        create_badge(
            row,
            badge_value,
            2,
            151
        )

    if badge_hidden then
        badge.object:add_flag(
            lvgl.FLAG.HIDDEN
        )
        pcall(function()
            badge.label:add_flag(
                lvgl.FLAG.HIDDEN
            )
        end)
    elseif options.trailing_status then
        -- Status badges use secondary styling so they do not look like
        -- ordinary completed track-count chips.
        pcall(function()
            badge.object:set {
                bg_color = COLORS.secondary,
            }
            badge.label:set {
                text_color = COLORS.primary,
            }
        end)
    end

    local width =
        badge_hidden and MEDIA_TEXT_WIDTH or
        (MEDIA_TEXT_WIDTH - badge.width)

    local title =
        jellyfin_marquee.create(
            row,
            {
                x = MEDIA_TEXT_X,
                y = MEDIA_TITLE_Y,
                w = width,
                h = 13,
                text =
                    album.name or
                    "Unknown Album",
                text_color =
                    COLORS.primary,
                text_font =
                    font.fusion_10,
            }
        )

    local artist =
        jellyfin_marquee.create(
            row,
            {
                x = MEDIA_TEXT_X,
                y = MEDIA_DETAIL_Y,
                w = width,
                h = 13,
                text =
                    album.artist or
                    "Unknown Artist",
                text_color =
                    COLORS.secondary,
                text_font =
                    font.fusion_10,
            }
        )

    local model = {
        object = row,
        marquees = {
            title,
            artist,
        },
        artwork = artwork,
        title = title,
        artist = artist,
        badge = badge,
        on_click = options.on_click,
        on_long_press = options.on_long_press,
        selection_id =
            item_selection_id(album),
        available =
            options.available ~= false,
    }

    local function apply_availability(
        available,
        click_handler,
        long_press_handler,
        dimmed
    )
        model.available =
            available ~= false
        model.on_click =
            model.available and
            click_handler or nil
        model.on_long_press =
            model.available and
            long_press_handler or nil

        title.view:set {
            text_color =
                model.available and
                COLORS.primary or
                COLORS.secondary,
        }
        artist.view:set {
            text_color = COLORS.secondary,
        }
        row:set {
            opa = dimmed == true and 128 or 255,
        }

        if model.available then
            add_to_group(
                self.focus_group or
                lvgl.group.get_default(),
                row
            )
            row:add_flag(lvgl.FLAG.CLICKABLE)
        else
            remove_from_group(row)
            row:clear_flag(lvgl.FLAG.CLICKABLE)
        end
    end

    apply_availability(
        options.available,
        options.on_click,
        options.on_long_press,
        options.dimmed
    )

    function model:update(
        next_album,
        next_artwork,
        next_callback_or_options
    )
        local next_options =
            type(next_callback_or_options) ==
                "table" and
            next_callback_or_options or
            {
                on_click =
                    next_callback_or_options,
            }
        next_album = next_album or {}

        artwork:set(
            next_artwork
        )

        local badge_hidden =
            next_options.hide_trailing_badge ==
            true
        local next_badge =
            badge_hidden and "" or
            (
                next_options.trailing_status or
                next_album.track_count or 0
            )
        local next_width =
            badge_hidden and MEDIA_TEXT_WIDTH or
            (
                MEDIA_TEXT_WIDTH -
                badge:set(next_badge)
            )

        if badge_hidden then
            badge.object:add_flag(
                lvgl.FLAG.HIDDEN
            )
            pcall(function()
                badge.label:add_flag(
                    lvgl.FLAG.HIDDEN
                )
            end)
        else
            badge.object:clear_flag(
                lvgl.FLAG.HIDDEN
            )
            pcall(function()
                badge.label:clear_flag(
                    lvgl.FLAG.HIDDEN
                )
            end)
            if next_options.trailing_status then
                pcall(function()
                    badge.object:set {
                        bg_color =
                            COLORS.secondary,
                    }
                    badge.label:set {
                        text_color =
                            COLORS.primary,
                    }
                end)
            else
                pcall(function()
                    badge.object:set {
                        bg_color = COLORS.badge,
                    }
                    badge.label:set {
                        text_color =
                            COLORS.badge_text,
                    }
                end)
            end
        end

        title:set_width(
            next_width
        )
        artist:set_width(
            next_width
        )

        title:set(
            next_album.name or
            "Unknown Album"
        )
        artist:set(
            next_album.artist or
            "Unknown Artist"
        )

        apply_availability(
            next_options.available,
            next_options.on_click,
            next_options.on_long_press,
            next_options.dimmed
        )
        update_model_selection(
            model,
            item_selection_id(
                next_album
            )
        )
    end

    attach_row_events(model)

    return register_model(
        self,
        model
    )
end

function M.add_playlist_row(
    self,
    collection,
    artwork_source,
    callback_or_options
)
    local options =
        type(callback_or_options) == "table" and
        callback_or_options or
        {
            on_click = callback_or_options,
        }
    local row =
        media_row_parent(self):Button {
            w = lvgl.PCT(100),
            h = MEDIA_ROW_HEIGHT,
            pad_all = 0,
            border_width = 0,
            outline_width = 0,
            shadow_width = 0,
            radius = 3,
            bg_opa = 0,
        }

    local artwork =
        create_artwork(
            row,
            artwork_source,
            MEDIA_ARTWORK_SIZE
        )

    local count =
        collection.track_count or
        #(collection.items or {})

    local badge =
        create_badge(
            row,
            count,
            2,
            151
        )

    local name =
        jellyfin_marquee.create(
            row,
            {
                x = MEDIA_TEXT_X,
                y = MEDIA_SINGLE_Y,
                w =
                    MEDIA_TEXT_WIDTH -
                    badge.width,
                h = 11,
                text =
                    collection.name or
                    "Playlist",
                text_color =
                    COLORS.primary,
                text_font =
                    font.fusion_10,
            }
        )

    local model = {
        object = row,
        marquees = {name},
        artwork = artwork,
        name = name,
        badge = badge,
        on_click = options.on_click,
        on_long_press = options.on_long_press,
        selection_id =
            item_selection_id(
                collection
            ),
    }

    function model:update(
        next_collection,
        next_artwork,
        next_callback_or_options
    )
        local next_options =
            type(next_callback_or_options) ==
                "table" and
            next_callback_or_options or
            {
                on_click =
                    next_callback_or_options,
            }
        next_collection =
            next_collection or {}

        artwork:set(
            next_artwork
        )

        local next_count =
            next_collection
                .track_count or
            #(
                next_collection
                    .items or {}
            )

        local width =
            badge:set(
                next_count
            )

        name:set_width(
            MEDIA_TEXT_WIDTH - width
        )
        name:set(
            next_collection.name or
            "Playlist"
        )

        model.on_click =
            next_options.on_click
        model.on_long_press =
            next_options.on_long_press
        update_model_selection(
            model,
            item_selection_id(
                next_collection
            )
        )
    end

    attach_row_events(model)

    return register_model(
        self,
        model
    )
end

function M.add_track_row(
    self,
    track,
    options
)
    options = options or {}

    local artwork_source =
        options.artwork

    local has_artwork =
        type(artwork_source) ==
            "string" and
        artwork_source ~= ""

    local row =
        media_row_parent(self):Button {
            w = lvgl.PCT(100),
            h = MEDIA_ROW_HEIGHT,
            pad_all = 0,
            border_width = 0,
            outline_width = 0,
            shadow_width = 0,
            radius = 3,
            bg_opa = 0,
        }

    local artwork = nil
    local x = 5
    local width = 146

    if has_artwork then
        artwork =
            create_artwork(
                row,
                artwork_source,
                MEDIA_ARTWORK_SIZE
            )
        x = MEDIA_TEXT_X
        width = MEDIA_TEXT_WIDTH
    end

    local title =
        jellyfin_marquee.create(
            row,
            {
                x = x,
                y = MEDIA_TITLE_Y,
                w =
                    tonumber(
                        options.text_width
                    ) or width,
                h = 13,
                text =
                    track.title or
                    "Unknown Track",
                text_color =
                    COLORS.primary,
                text_font =
                    font.fusion_10,
            }
        )

    local detail =
        jellyfin_marquee.create(
            row,
            {
                x = x,
                y = MEDIA_DETAIL_Y,
                w =
                    tonumber(
                        options.detail_width
                    ) or
                    tonumber(
                        options.text_width
                    ) or
                    width,
                h = 13,
                text =
                    options.detail or
                    track.artist or
                    track.album or "",
                text_color =
                    COLORS.secondary,
                text_font =
                    font.fusion_10,
            }
        )

    local model = {
        object = row,
        marquees = {
            title,
            detail,
        },
        artwork = artwork,
        title = title,
        detail = detail,
        on_click = options.on_click,
        on_long_press =
            options.on_long_press,
        selection_id =
            item_selection_id(track),
        available =
            options.available ~= false,
    }

    local function apply_availability(
        available,
        click_handler
    )
        model.available =
            available ~= false
        model.on_click =
            model.available and
            click_handler or nil

        title.view:set {
            text_color =
                model.available and
                COLORS.primary or
                COLORS.secondary,
        }
        detail.view:set {
            text_color =
                COLORS.secondary,
        }
    end

    apply_availability(
        options.available,
        options.on_click
    )

    function model:update(
        next_track,
        next_options
    )
        next_track =
            next_track or {}
        next_options =
            next_options or {}

        if artwork and
            type(next_options.artwork) ==
                "string" and
            next_options.artwork ~= "" then
            artwork:set(
                next_options.artwork
            )
        end

        title:set(
            next_track.title or
            "Unknown Track"
        )
        detail:set(
            next_options.detail or
            next_track.artist or
            next_track.album or ""
        )

        local next_text_width =
            tonumber(
                next_options.text_width
            )
        local next_detail_width =
            tonumber(
                next_options.detail_width
            ) or next_text_width

        if next_text_width then
            title:set_width(next_text_width)
        end

        if next_detail_width then
            detail:set_width(
                next_detail_width
            )
        end

        apply_availability(
            next_options.available,
            next_options.on_click
        )
        model.on_long_press =
            next_options.on_long_press
        update_model_selection(
            model,
            item_selection_id(
                next_track
            )
        )
    end

    attach_row_events(model)

    return register_model(
        self,
        model
    )
end

function M.add_message(
    self,
    message
)
    local row =
        self.list:Button {
            w = lvgl.PCT(100),
            h = 28,
            pad_all = 0,
            border_width = 0,
            outline_width = 0,
            shadow_width = 0,
            radius = 3,
            bg_opa = 0,
        }

    local label =
        jellyfin_marquee.create(
            row,
            {
                x = 5,
                y = 7,
                w = 146,
                h = 14,
                text = message,
                align = "center",
                text_color =
                    COLORS.secondary,
            }
        )

    local model = {
        object = row,
        marquees = {label},
        label = label,
        on_click =
            function()
            end,
    }

    function model:update(next_message)
        label:set(
            next_message or ""
        )
    end

    attach_row_events(model)

    return register_model(
        self,
        model
    )
end

M.colors = COLORS

M.cancel_plain_list_scroll =
    cancel_plain_list_scroll
M.capture_list_scroll =
    capture_plain_list_scroll
M.restore_list_scroll =
    restore_plain_list_scroll

return M

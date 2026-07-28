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

local M = {}

local COLORS = {
    background = "#07080C",
    selected = "#34363F",
    primary = "#FFFFFF",
    secondary = "#AEB0B8",
    badge = "#3B536A",
    badge_text = "#E2EDF6",
    art_background = "#161820",
    modal = "#11131A",
    modal_border = "#555862",
}

local function media_row_parent(self)
    return
        self.virtual_row_parent or
        self.list
end

local pending_initial_scrolls =
    setmetatable(
        {},
        {__mode = "k"}
    )

local initial_scroll_timer = nil

local INITIAL_SCROLL_Y = 25
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
                selected_id then
            return model.object
        end
    end

    return nil
end

local function apply_initial_scroll(self)
    if not self or
        not self.ui_active or
        not self.list or
        not self.sort_row or
        not self.first_row or
        self.first_row ==
            self.sort_row.object then
        return false
    end

    local applied = false

    pcall(
        function()
            self.list:scroll_to {
                x = 0,
                y = INITIAL_SCROLL_Y,
                anim = false,
            }

            local list_coordinates =
                self.list:get_coords()

            local row_coordinates =
                self.first_row:get_coords()

            local sort_coordinates =
                self.sort_row.object
                    :get_coords()

            local list_height =
                list_coordinates.y2 -
                list_coordinates.y1 + 1

            applied =
                list_height >= 20 and
                row_coordinates.y1 >=
                    list_coordinates.y1 - 2 and
                row_coordinates.y1 <=
                    list_coordinates.y1 + 1 and
                sort_coordinates.y2 <
                    list_coordinates.y1
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
    if apply_initial_scroll(self) then
        pending_initial_scrolls[self] = nil
        return
    end

    if not self or
        not self.ui_active or
        not self.sort_row or
        not self.first_row or
        self.first_row ==
            self.sort_row.object then
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
            object:scroll_to_view_recursive(false)
        end
    )
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
    for _, marquee in ipairs(
        model.marquees or {}
    ) do
        if marquee and
            type(marquee.start) ==
                "function" then
            marquee:start()
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
                model.owner.selected_item_id =
                    model.selection_id
            end

            set_row_focus(
                object,
                true
            )
            start_marquees(model)

            if type(model.on_focus) ==
                    "function" then
                model.on_focus()
            end
        end
    )

    object:onevent(
        lvgl.EVENT.DEFOCUSED,
        function()
            model.focused = false
            set_row_focus(
                object,
                false
            )
            stop_marquees(model)
        end
    )

    local suppress_click = false

    object:onevent(
        lvgl.EVENT.PRESSED,
        function()
            suppress_click = false
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
            model.on_long_press()
        end
    )

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
    source
)
    local model = {}

    model.frame =
        row:Object {
            x = 2,
            y = 2,
            w = 28,
            h = 28,
            pad_all = 0,
            border_width = 0,
            radius = 2,
            bg_color =
                COLORS.art_background,
            bg_opa = 255,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    model.frame:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    model.frame:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    if source == "__favorites_star__" then
        model.frame:set {
            bg_color = "#000000",
            bg_opa = 255,
        }

        local star_color = "#DCEAF3"

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

        for _, segment in ipairs(
            segments
        ) do
            local piece =
                model.frame:Object {
                    x = segment[1],
                    y = segment[2],
                    w = segment[3],
                    h = segment[4],
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

    model.image =
        model.frame:Image {
            x = 0,
            y = 0,
            src =
                lvgl.ImgData(source),
        }

    model.image:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    function model:set(next_source)
        model.image:set {
            src =
                lvgl.ImgData(
                    next_source
                ),
        }
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

    self.header =
        self.root:Label {
            x = 5,
            y = 15,
            w = 150,
            h = 13,
            text = title or "",
            text_align = 2,
            text_color =
                COLORS.primary,
            text_font =
                font.fusion_10,
            long_mode =
                lvgl.LABEL.LONG_CLIP,
        }

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
        bg_opa = 255,
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
    }

    self.rows = {}
    self.media_rows = {}
    self.ui_active = false

    remove_from_group(self.list)
    remove_from_group(self.header)
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

local function sort_method_title(method)
    if method == "recent" then
        return "Recently Added"
    end

    return "Alphabetical"
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
    self.sort_options = options
    self.sort_dirty = false
    self.sort_menu_open = false
    self.sort_selected_method =
        options.current_method or
        methods[1]
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
        method
    )
        if type(callback) ~= "function" then
            return false
        end

        local state = callback(method)

        if type(state) ~= "table" then
            return false
        end

        self.sort_dirty = true
        self.update_sort_labels(state)

        return true
    end

    function self.sort_select(method)
        return update_from(
            options.on_highlight or
                options.on_select,
            method
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
            bg_color = "#000000",
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

        option:Label {
            x = 6,
            y = 5,
            w = 104,
            h = 13,
            text =
                sort_method_title(
                    method
                ),
            text_color =
                COLORS.primary,
            text_font =
                font.fusion_10,
        }

        local order_badge =
            create_badge(
                option,
                method == "recent" and
                    (
                        options.recent_label or
                        "NEW"
                    ) or
                    (
                        options.alpha_label or
                        "A-Z"
                    ),
                3,
                147
            )

        local option_model = {
            object = option,
            method = method,
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
                    method
                )
            end

        option_model.on_click =
            function()
                update_from(
                    options.on_toggle or
                        options.on_select,
                    method
                )
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

function M.install_controls(self)
    self.ui_active = true

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

    local restored_object =
        resuming and
        selected_row_object(self) or
        nil

    self.suppress_selection_tracking = true

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
        self.first_row or
        (
            self.rows[1] and
            self.rows[1].object
        )

    focus_object(initial_object)

    self.suppress_selection_tracking = false

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

function M.attach_scroll_indicator(
    self,
    models,
    options
)
    models = models or {}

    local indicator =
        jellyfin_scroll_indicator.create(
            self and self.list,
            options
        )

    if not indicator then
        return nil
    end

    indicator.models = models
    indicator.item_count = #models

    for index, model in ipairs(models) do
        local row_index = index

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

    indicator:update(
        indicator.item_count,
        1
    )

    self.scroll_indicator = indicator

    return indicator
end

function M.add_count_row(
    self,
    title,
    count,
    callback,
    selection_id
)
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
                y = 5,
                w = 139 - badge.width,
                h = 14,
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

function M.add_album_row(
    self,
    album,
    artwork_source,
    callback
)
    local row =
        media_row_parent(self):Button {
            w = lvgl.PCT(100),
            h = 32,
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
            artwork_source
        )

    local badge =
        create_badge(
            row,
            album.track_count or 0,
            7,
            151
        )

    local width =
        114 - badge.width

    local title =
        jellyfin_marquee.create(
            row,
            {
                x = 35,
                y = 1,
                w = width,
                h = 14,
                text =
                    album.name or
                    "Unknown Album",
                text_color =
                    COLORS.primary,
            }
        )

    local artist =
        jellyfin_marquee.create(
            row,
            {
                x = 35,
                y = 16,
                w = width,
                h = 14,
                text =
                    album.artist or
                    "Unknown Artist",
                text_color =
                    COLORS.secondary,
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
        on_click = callback,
        selection_id =
            item_selection_id(album),
    }

    function model:update(
        next_album,
        next_artwork,
        next_callback
    )
        next_album =
            next_album or {}

        artwork:set(
            next_artwork
        )

        local next_width =
            114 -
            badge:set(
                next_album.track_count or 0
            )

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

        model.on_click =
            next_callback
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
    callback
)
    local row =
        self.list:Button {
            w = lvgl.PCT(100),
            h = 32,
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
            artwork_source
        )

    local count =
        collection.track_count or
        #(collection.items or {})

    local badge =
        create_badge(
            row,
            count,
            7,
            151
        )

    local name =
        jellyfin_marquee.create(
            row,
            {
                x = 35,
                y = 9,
                w = 114 - badge.width,
                h = 14,
                text =
                    collection.name or
                    "Playlist",
                text_color =
                    COLORS.primary,
            }
        )

    local model = {
        object = row,
        marquees = {name},
        artwork = artwork,
        name = name,
        badge = badge,
        on_click = callback,
        selection_id =
            item_selection_id(
                collection
            ),
    }

    function model:update(
        next_collection,
        next_artwork,
        next_callback
    )
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
            114 - width
        )
        name:set(
            next_collection.name or
            "Playlist"
        )

        model.on_click =
            next_callback
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
            h = 32,
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
                artwork_source
            )
        x = 35
        width = 116
    end

    local title =
        jellyfin_marquee.create(
            row,
            {
                x = x,
                y = 1,
                w = width,
                h = 14,
                text =
                    track.title or
                    "Unknown Track",
                text_color =
                    COLORS.primary,
            }
        )

    local detail =
        jellyfin_marquee.create(
            row,
            {
                x = x,
                y = 16,
                w = width,
                h = 14,
                text =
                    options.detail or
                    track.artist or
                    track.album or "",
                text_color =
                    COLORS.secondary,
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
    }

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

        model.on_click =
            next_options.on_click
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

return M

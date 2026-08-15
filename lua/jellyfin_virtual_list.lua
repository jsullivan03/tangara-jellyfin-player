local lvgl = require("lvgl")
local controls = require("controls")
local jellyfin_scroll_indicator =
    require("jellyfin_scroll_indicator")
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
            "fixed-list " .. tostring(message)
        )
    end
end

local function trace_fixed_rows(
    controller,
    stage
)
    if not resume_metrics or
        type(resume_metrics.trace) ~=
            "function" then
        return
    end

    local viewport = nil
    local canvas = nil

    pcall(
        function()
            viewport =
                controller.screen_list:
                    get_coords()
            canvas =
                controller.canvas:get_coords()
        end
    )

    resume_trace(
        stage ..
            " selected=" ..
            tostring(controller.selected_index) ..
            " window=" ..
            tostring(controller.window_start) ..
            " view=" ..
            tostring(controller.fixed_view_start) ..
            " base_y=" ..
            tostring(controller.fixed_base_y) ..
            " parent_scroll_y=" ..
            tostring(
                viewport and canvas and
                (canvas.y1 - viewport.y1) or
                "unknown"
            ) ..
            " clip=" ..
            tostring(viewport and viewport.x1) ..
            "," ..
            tostring(viewport and viewport.y1) ..
            "-" ..
            tostring(viewport and viewport.x2) ..
            "," ..
            tostring(viewport and viewport.y2)
    )

    for slot, model in ipairs(
        controller.pool or {}
    ) do
        local coordinates = nil
        local visible = false
        local parent = nil

        pcall(
            function()
                coordinates =
                    model.object:get_coords()
                visible =
                    model.object:is_visible()
                parent =
                    model.object:get_parent()
            end
        )

        resume_trace(
            stage ..
                " row slot=" ..
                tostring(slot) ..
                " bound=" ..
                tostring(model.virtual_index) ..
                " y=" ..
                tostring(
                    coordinates and
                    coordinates.y1
                ) ..
                " h=" ..
                tostring(
                    coordinates and
                    coordinates.y2 -
                        coordinates.y1 + 1
                ) ..
                " hidden=" ..
                tostring(not visible) ..
                " parent=" ..
                tostring(parent)
        )
    end
end

local DEFAULT_POOL_SIZE = 7
local DEFAULT_ANCHOR = 4
local DEFAULT_ROW_HEIGHT = 23
local DEFAULT_ROW_GAP = 1

local function normalize_id(value)
    if value == nil then
        return nil
    end

    local text = tostring(value)

    if text == "" then
        return nil
    end

    return text
end

local function default_item_id(item)
    if type(item) ~= "table" then
        return nil
    end

    -- Track-shaped rows use the canonical track key for selection/resume.
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
            normalize_id(item[key])

        if value then
            return value
        end
    end

    return nil
end

local function clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    end

    if value > maximum then
        return maximum
    end

    return value
end

local function focus_object(object)
    if not object then
        return
    end

    pcall(
        function()
            lvgl.group.focus_obj(object)
        end
    )

    pcall(
        function()
            object:scroll_to_view_recursive(false)
        end
    )
end

local function focus_group_only(object)
    if not object then
        return
    end

    pcall(
        function()
            lvgl.group.focus_obj(object)
        end
    )
end

local function remove_from_group(object)
    if not object then
        return
    end

    pcall(
        function()
            lvgl.group.remove_obj(object)
        end
    )
end

function M.create(
    screen,
    items,
    options
)
    options = options or {}
    items = items or {}

    local item_label =
        tostring(
            options.item_label or
            "item"
        )
    local item_plural =
        tostring(
            options.item_plural or
            item_label .. "s"
        )

    assert(
        type(screen) == "table",
        "virtual list requires a screen"
    )
    assert(
        screen.list,
        "virtual list requires a list parent"
    )
    assert(
        #items > 0,
        "virtual list requires " ..
            item_plural
    )
    assert(
        type(options.create_row) ==
            "function",
        "virtual list requires create_row"
    )
    assert(
        type(options.update_row) ==
            "function",
        "virtual list requires update_row"
    )

    local resolve_item_id =
        type(options.item_id) ==
            "function" and
        options.item_id or
        default_item_id

    local row_height =
        math.max(
            1,
            math.floor(
                tonumber(
                    options.row_height
                ) or
                DEFAULT_ROW_HEIGHT
            )
        )
    local row_gap =
        math.max(
            0,
            math.floor(
                tonumber(
                    options.row_gap
                ) or
                DEFAULT_ROW_GAP
            )
        )
    local row_stride =
        row_height + row_gap
    local measured_viewport_height = 100

    pcall(
        function()
            local coordinates =
                screen.list:get_coords()
            local height =
                coordinates.y2 -
                coordinates.y1 + 1

            if height > 0 then
                measured_viewport_height =
                    height
            end
        end
    )

    local fixed_viewport_height =
        math.max(
            row_height,
            math.floor(
                tonumber(
                    options.viewport_height
                ) or
                measured_viewport_height
            )
        )
    local pool_limit =
        math.max(
            1,
            math.floor(
                tonumber(
                    options.pool_size
                ) or
                DEFAULT_POOL_SIZE
            )
        )
    local content_height =
        math.max(
            1,
            #items * row_stride -
                row_gap
        )
    local fixed_viewport =
        options.fixed_viewport == true or
        (
            options.fixed_viewport == nil and
            content_height >
                fixed_viewport_height
        )

    local controller = {
        screen_list = screen.list,
        screen = screen,
        items = {},
        pool = {},
        window_start = 1,
        selected_index = 1,
        rebalancing = false,
        continuous_input_active = false,
        continuous_input_suspended = false,
        continuous_at_sort = false,
        continuous_focus_change = false,
        continuous_refreshing = false,
        continuous_focus_model = nil,
        continuous_encoder_callback = nil,
        options = options,
        row_height = row_height,
        row_gap = row_gap,
        row_stride = row_stride,
        fixed_viewport = fixed_viewport,
        fixed_viewport_height =
            fixed_viewport_height,
        fixed_base_y = 0,
        fixed_view_start = nil,
        motion_duration =
            math.max(
                1,
                math.floor(
                    tonumber(
                        options.motion_duration
                    ) or 90
                )
            ),
        motion_generation = 0,
        pool_limit = pool_limit,
        total_count =
            math.max(
                #items,
                math.floor(
                    tonumber(
                        options.total_count
                    ) or #items
                )
            ),
        total_count_authoritative =
            options.total_count ~= nil,
        anchor =
            math.max(
                1,
                math.floor(
                    tonumber(
                        options.anchor
                    ) or
                    DEFAULT_ANCHOR
                )
            ),
    }


    local function assign_selected_id(id)
        if screen.discography_selection_lock then
            screen.selected_item_id =
                screen.discography_selection_lock
            return
        end

        screen.selected_item_id = id
    end

    local function item_id(item)
        return
            normalize_id(
                resolve_item_id(item)
            )
    end

    local function row_handlers(model)
        return {
            on_click =
                model and
                    model.virtual_on_click or
                    nil,
            on_long_press =
                model and
                    model.virtual_on_long_press or
                    nil,
        }
    end

    local function update_row(
        model,
        item
    )
        options.update_row(
            model,
            item,
            row_handlers(model)
        )
    end

    function controller:find_index(id)
        id = normalize_id(id)

        if not id then
            return nil
        end

        for index, item in ipairs(
            self.items
        ) do
            local candidate = item_id(item)

            if candidate == id then
                return index
            end

            if jellyfin_track_identity
                    .matches_selection(
                        id,
                        item
                    ) or
                (
                    candidate and
                    jellyfin_track_identity
                        .matches_selection(
                            id,
                            candidate
                        )
                ) then
                return index
            end
        end

        return nil
    end

    function controller:logical_count()
        return #self.items
    end

    function controller:pool_count()
        return #self.pool
    end

    function controller:scroll_thumb_height(
        item_count
    )
        local indicator =
            self.scroll_indicator

        if not indicator then
            return 0
        end

        local total = #self.items
        if self.total_count_authoritative then
            total = self.total_count or total
        end

        return
            indicator:thumb_height_for(
                item_count or total
            )
    end

    function controller:update_scroll_indicator()
        local indicator =
            self.scroll_indicator

        if not indicator then
            return
        end

        local total = #self.items

        if self.total_count_authoritative then
            total =
                math.max(
                    total,
                    math.floor(
                        tonumber(
                            self.total_count
                        ) or total
                    )
                )
        end

        indicator.item_count = total
        indicator:update(
            total,
            self.selected_index
        )

        if type(options.on_focus) ==
                "function" then
            options.on_focus(
                self.selected_index,
                self.items[
                    self.selected_index
                ]
            )
        end
    end

    function controller:canvas_height(
        item_count
    )
        local count =
            math.max(
                1,
                math.floor(
                    tonumber(item_count) or
                    #self.items
                )
            )

        if self.fixed_viewport then
            return self.fixed_viewport_height
        end

        return
            math.max(
                1,
                count * self.row_stride -
                    self.row_gap
            )
    end

    function controller:fixed_pool_height()
        return
            math.max(
                1,
                #self.pool * self.row_stride -
                    self.row_gap
            )
    end

    function controller:fixed_visible_count()
        return
            math.min(
                #self.pool,
                math.max(
                    1,
                    math.floor(
                        (
                            self.fixed_viewport_height +
                            self.row_gap
                        ) / self.row_stride
                    )
                )
            )
    end

    function controller:fixed_resolve_view_start(
        index
    )
        local visible_count =
            self:fixed_visible_count()
        local maximum_start =
            math.max(
                1,
                #self.items -
                    visible_count + 1
            )
        local current =
            tonumber(
                self.fixed_view_start
            )

        if not current then
            current =
                index -
                visible_count + 1
        end

        current =
            clamp(
                math.floor(current),
                1,
                maximum_start
            )

        if index < current then
            current = index
        elseif index >
                current +
                    visible_count - 1 then
            current =
                index -
                visible_count + 1
        end

        return
            clamp(
                current,
                1,
                maximum_start
            )
    end

    function controller:fixed_pool_start_for(
        view_start
    )
        local visible_count =
            self:fixed_visible_count()
        local overscan =
            math.max(
                0,
                #self.pool -
                    visible_count
            )
        local overscan_above =
            math.floor(
                overscan / 2
            )
        local maximum_start =
            math.max(
                1,
                #self.items -
                    #self.pool + 1
            )

        return
            clamp(
                view_start -
                    overscan_above,
                1,
                maximum_start
            )
    end

    function controller:resize_canvas()
        if not self.canvas then
            return
        end

        local height =
            self:canvas_height()

        self.canvas:set {
            h = height,
        }

        if self.motion_layer then
            self.motion_layer:set {
                h = self:fixed_pool_height(),
            }
        end
    end

    function controller:set_viewport_height(
        next_height
    )
        next_height =
            math.max(
                self.row_height,
                math.floor(
                    tonumber(next_height) or
                    self.fixed_viewport_height
                )
            )

        local changed =
            next_height ~=
            self.fixed_viewport_height

        self.screen_list:set {
            h = next_height,
        }

        if changed then
            self:fixed_cancel_motion()
            self.fixed_viewport_height =
                next_height
            self:resize_canvas()

            if self.fixed_viewport then
                self:fixed_prepare_selection()
                self:invalidate_viewport()
            end
        end

        -- Always resync the custom scrollbar track to the usable list height.
        -- Mini-player may already have resized the list before this virtual
        -- list was created, so an unchanged height must still update geometry.
        if self.scroll_indicator then
            local track_height =
                math.max(
                    1,
                    next_height - 4
                )

            if type(
                self.scroll_indicator
                    .set_track_height
            ) == "function" then
                self.scroll_indicator:
                    set_track_height(
                        track_height
                    )
            else
                self.scroll_indicator.height =
                    track_height
            end

            self.scroll_indicator.visible_items =
                self:fixed_visible_count()
            self:update_scroll_indicator()
        end

        return changed
    end

    function controller:row_y(index)
        return
            math.max(
                0,
                index - 1
            ) * self.row_stride
    end

    function controller:position_model(
        model,
        logical_index
    )
        if not model or
            not model.object then
            return
        end

        local positioned_index =
            logical_index

        if self.fixed_viewport then
            positioned_index =
                model.virtual_slot or 1
        end

        model.object:set {
            x = 0,
            y = self:row_y(
                positioned_index
            ),
        }
    end

    function controller:window_for(index)
        local count = #self.items
        local pool_count = #self.pool

        if count == 0 or pool_count == 0 then
            return 1
        end

        local maximum_start =
            math.max(
                1,
                count - pool_count + 1
            )

        return clamp(
            index - self.anchor + 1,
            1,
            maximum_start
        )
    end

    function controller:slot_for(index)
        return
            index -
            self.window_start + 1
    end

    function controller:synchronize_row_tables()
        local pool_models = {}

        for _, model in ipairs(
            self.pool
        ) do
            pool_models[model] = true
        end

        local next_rows = {}

        for _, model in ipairs(
            screen.rows or {}
        ) do
            if not pool_models[model] then
                table.insert(
                    next_rows,
                    model
                )
            end
        end

        for slot, model in ipairs(
            self.pool
        ) do
            model.virtual_slot = slot
            table.insert(
                next_rows,
                model
            )
        end

        screen.rows = next_rows
        screen.media_rows = self.pool
    end

    function controller:rotate_group_order(
        previous_pool,
        direction
    )
        if not screen.ui_active then
            return
        end

        local group =
            screen.focus_group or
            lvgl.group.get_default()

        if not group or
            type(group.swap_obj) ~=
                "function" then
            return
        end

        if direction > 0 then
            local recycled =
                previous_pool[1]

            for index = 2,
                    #previous_pool do
                pcall(
                    function()
                        group:swap_obj(
                            recycled.object,
                            previous_pool[index]
                                .object
                        )
                    end
                )
            end
        elseif direction < 0 then
            local recycled =
                previous_pool[
                    #previous_pool
                ]

            for index =
                    #previous_pool - 1,
                    1,
                    -1 do
                pcall(
                    function()
                        group:swap_obj(
                            recycled.object,
                            previous_pool[index]
                                .object
                        )
                    end
                )
            end
        end
    end

    function controller:bind_window(start)
        local count = #self.items
        local pool_count = #self.pool

        if count == 0 or pool_count == 0 then
            return
        end

        local maximum_start =
            math.max(
                1,
                count - pool_count + 1
            )

        self.window_start =
            clamp(
                start,
                1,
                maximum_start
            )

        local previous_suppression =
            screen.suppress_selection_tracking

        screen.suppress_selection_tracking =
            true

        for slot, model in ipairs(
            self.pool
        ) do
            local logical_index =
                self.window_start +
                slot - 1
            local item =
                self.items[logical_index]

            model.virtual_slot = slot
            model.virtual_index =
                logical_index
            self:position_model(
                model,
                logical_index
            )
            update_row(
                model,
                item
            )
        end

        screen.suppress_selection_tracking =
            previous_suppression
        self:synchronize_row_tables()
    end

    function controller:model_for_index(index)
        if self.continuous_input_active then
            for _, model in ipairs(
                self.pool
            ) do
                if model.virtual_index ==
                        index then
                    return model
                end
            end

            return nil
        end

        local slot = self:slot_for(index)

        if slot < 1 or
            slot > #self.pool then
            return nil
        end

        return self.pool[slot]
    end

    function controller:selected_model()
        return
            self:model_for_index(
                self.selected_index
            )
    end

    function controller:focus_index(index)
        index =
            clamp(
                math.floor(
                    tonumber(index) or 1
                ),
                1,
                #self.items
            )

        self.selected_index = index
        self:update_scroll_indicator()

        if self.fixed_viewport then
            local model = nil
            local id =
                item_id(
                    self.items[index]
                )

            if id then
                assign_selected_id(id)
            end

            if screen.suppress_focus_scroll then
                -- Resume/discography return: keep the restored motion offset
                -- when the selection is already mounted and visible. If the
                -- row is missing or clipped (e.g. Search still using a stale
                -- native scroll offset against a fixed motion layer), snap
                -- instantly without animation.
                model =
                    self:ensure_selection_visible()
            else
                model =
                    self:fixed_prepare_selection()
            end

            if not model then
                return nil
            end

            if screen.ui_active then
                local previous_suppression =
                    screen.suppress_selection_tracking

                self.rebalancing = true
                screen.suppress_selection_tracking =
                    true
                focus_group_only(model.object)
                screen.suppress_selection_tracking =
                    previous_suppression
                self.rebalancing = false
            end

            return model.object
        end

        local next_start =
            self:window_for(index)

        if next_start ~=
                self.window_start then
            self:bind_window(next_start)
        end

        local model =
            self:model_for_index(index)

        if not model then
            return nil
        end

        local id =
            item_id(
                self.items[index]
            )

        if id then
            assign_selected_id(id)
        end

        if screen.ui_active then
            local previous_suppression =
                screen.suppress_selection_tracking

            self.rebalancing = true
            screen.suppress_selection_tracking =
                true
            if screen.suppress_focus_scroll then
                focus_group_only(model.object)
            else
                focus_object(model.object)
            end
            screen.suppress_selection_tracking =
                previous_suppression
            self.rebalancing = false
        end

        return model.object
    end

    function controller:rotate_window_once(
        direction
    )
        local pool_count = #self.pool

        if pool_count == 0 then
            return false
        end

        local previous_pool = {}

        for index, model in ipairs(
            self.pool
        ) do
            previous_pool[index] = model
        end

        local previous_suppression =
            screen.suppress_selection_tracking

        self.rebalancing = true
        screen.suppress_selection_tracking =
            true

        local recycled = nil
        local logical_index = nil

        if direction > 0 then
            local maximum_start =
                math.max(
                    1,
                    #self.items -
                        pool_count + 1
                )

            if self.window_start >=
                    maximum_start then
                screen.suppress_selection_tracking =
                    previous_suppression
                self.rebalancing = false
                return false
            end

            recycled =
                table.remove(
                    self.pool,
                    1
                )
            table.insert(
                self.pool,
                recycled
            )
            self.window_start =
                self.window_start + 1
            logical_index =
                self.window_start +
                pool_count - 1

            pcall(
                function()
                    recycled.object
                        :move_to_index(
                            pool_count - 1
                        )
                end
            )
        elseif direction < 0 then
            if self.window_start <= 1 then
                screen.suppress_selection_tracking =
                    previous_suppression
                self.rebalancing = false
                return false
            end

            recycled =
                table.remove(
                    self.pool,
                    pool_count
                )
            table.insert(
                self.pool,
                1,
                recycled
            )
            self.window_start =
                self.window_start - 1
            logical_index =
                self.window_start

            pcall(
                function()
                    recycled.object
                        :move_to_index(0)
                end
            )
        else
            screen.suppress_selection_tracking =
                previous_suppression
            self.rebalancing = false
            return false
        end

        recycled.virtual_index =
            logical_index
        self:position_model(
            recycled,
            logical_index
        )
        update_row(
            recycled,
            self.items[logical_index]
        )

        self:synchronize_row_tables()
        self:rotate_group_order(
            previous_pool,
            direction
        )

        screen.suppress_selection_tracking =
            previous_suppression
        self.rebalancing = false

        return true
    end

    function controller:rotate_to_start(
        next_start
    )
        next_start =
            clamp(
                next_start,
                1,
                math.max(
                    1,
                    #self.items -
                        #self.pool + 1
                )
            )

        while self.window_start <
                next_start do
            if not self:rotate_window_once(1) then
                break
            end
        end

        while self.window_start >
                next_start do
            if not self:rotate_window_once(-1) then
                break
            end
        end
    end

    function controller:set_scroll_on_focus(enabled)
        local flag =
            lvgl.FLAG.SCROLL_ON_FOCUS

        if not flag then
            return
        end

        local function apply(object)
            if not object then
                return
            end

            pcall(
                function()
                    if enabled then
                        object:add_flag(flag)
                    else
                        object:clear_flag(flag)
                    end
                end
            )
        end

        for _, model in ipairs(
            screen.leading_rows or {}
        ) do
            apply(model and model.object)
        end

        for _, model in ipairs(
            self.pool
        ) do
            apply(model.object)
        end
    end

    function controller:continuous_leading_rows()
        local rows = {}
        local seen = {}

        -- Any focusable control registered before the virtual canvas is a
        -- leading row. Keeping the shared registration order makes the fixed
        -- viewport work consistently for Sort, multi-select, create, quick
        -- action, and other list controls without screen-specific branches.
        for _, model in ipairs(
            screen.leading_rows or {}
        ) do
            if model and
                model.object and
                not seen[model] then
                seen[model] = true
                rows[#rows + 1] = model
            end
        end

        if #rows == 0 and
            screen.sort_row then
            rows[1] = screen.sort_row
        end

        return rows
    end

    function controller:continuous_bind_model(
        model,
        logical_index
    )
        if not model or
            not model.object or
            not logical_index or
            not self.items[logical_index] then
            return false
        end

        if model.virtual_index ==
                logical_index then
            return false
        end

        model.virtual_index = logical_index
        self:position_model(
            model,
            logical_index
        )
        update_row(
            model,
            self.items[logical_index]
        )

        return true
    end

    function controller:continuous_first_visible_index()
        local list_coordinates = nil
        local row_coordinates = nil
        local row_index = nil

        local ok = pcall(
            function()
                list_coordinates =
                    screen.list:get_coords()

                for _, model in ipairs(
                    self.pool
                ) do
                    if model.object and
                        type(model.virtual_index) ==
                            "number" then
                        row_coordinates =
                            model.object:get_coords()
                        row_index =
                            model.virtual_index
                        break
                    end
                end
            end
        )

        if not ok or
            not list_coordinates or
            not row_coordinates or
            not row_index then
            return self.selected_index
        end

        -- Derive the row-coordinate origin from an actual row instead of
        -- the canvas border. LVGL positions children from the parent's
        -- content origin, which can differ from get_coords().y1 by a few
        -- pixels. Using the canvas border left coverage five pixels short
        -- at some animated positions and exposed the background.
        local row_origin_y =
            row_coordinates.y1 -
            self:row_y(row_index)
        local offset =
            math.max(
                0,
                list_coordinates.y1 -
                    row_origin_y
            )

        return clamp(
            math.floor(
                offset / self.row_stride
            ) + 1,
            1,
            #self.items
        )
    end

    function controller:continuous_coverage_indices()
        local coverage_count =
            math.max(
                0,
                #self.pool - 1
            )

        if coverage_count == 0 then
            return {}
        end

        local item_count = #self.items
        local first_visible =
            self:continuous_first_visible_index()
        local maximum_start =
            math.max(
                1,
                item_count -
                    coverage_count + 1
            )
        local start =
            clamp(
                first_visible - 1,
                1,
                maximum_start
            )
        local desired = {}
        local used = {}

        local function add(index)
            if index < 1 or
                index > item_count or
                index == self.selected_index or
                used[index] then
                return
            end

            used[index] = true
            table.insert(
                desired,
                index
            )
        end

        for index = start,
                start + coverage_count - 1 do
            add(index)
        end

        local lower = start - 1
        local upper =
            start + coverage_count

        while #desired < coverage_count and
            (lower >= 1 or
                upper <= item_count) do
            if upper <= item_count then
                add(upper)
                upper = upper + 1
            end

            if #desired >= coverage_count then
                break
            end

            if lower >= 1 then
                add(lower)
                lower = lower - 1
            end
        end

        table.sort(desired)

        return desired
    end

    function controller:synchronize_continuous_rows()
        local pool_models = {}

        for _, model in ipairs(
            self.pool
        ) do
            pool_models[model] = true
        end

        local next_rows = {}

        for _, model in ipairs(
            screen.rows or {}
        ) do
            if not pool_models[model] then
                table.insert(
                    next_rows,
                    model
                )
            end
        end

        local ordered = {}

        for _, model in ipairs(
            self.pool
        ) do
            table.insert(
                ordered,
                model
            )
        end

        table.sort(
            ordered,
            function(left, right)
                return
                    (left.virtual_index or 0) <
                    (right.virtual_index or 0)
            end
        )

        for slot, model in ipairs(
            ordered
        ) do
            model.virtual_slot = slot
            table.insert(
                next_rows,
                model
            )
        end

        screen.rows = next_rows
        screen.media_rows = ordered
    end

    function controller:continuous_refresh_coverage()
        if not self.continuous_input_active or
            self.continuous_input_suspended or
            self.continuous_refreshing then
            return false
        end

        if self.fixed_viewport then
            local model =
                self:model_for_index(
                    self.selected_index
                )

            if model then
                self.continuous_focus_model = model
                return false
            end

            self:fixed_cancel_motion()
            self:fixed_focus_selection()
            return true
        end

        local focus_model =
            self.continuous_focus_model

        if not focus_model then
            return false
        end

        self.continuous_refreshing = true

        local previous_suppression =
            screen.suppress_selection_tracking

        self.rebalancing = true
        screen.suppress_selection_tracking = true

        local focus_changed =
            self:continuous_bind_model(
                focus_model,
                self.selected_index
            )

        -- A newly retargeted focus row must settle before its coordinates
        -- are used to derive the visible logical range. Ordinary scroll
        -- frames skip this pass because no row position changed.
        if focus_changed then
            pcall(
                function()
                    self.canvas:update_layout()
                end
            )
        end

        local desired =
            self:continuous_coverage_indices()
        local coverage_models = {}

        for _, model in ipairs(
            self.pool
        ) do
            if model ~= focus_model then
                table.insert(
                    coverage_models,
                    model
                )
            end
        end

        local coverage_changed = false

        for slot, model in ipairs(
            coverage_models
        ) do
            local logical_index =
                desired[slot]

            if logical_index and
                self:continuous_bind_model(
                    model,
                    logical_index
                ) then
                coverage_changed = true
            end
        end

        local bindings_changed =
            focus_changed or
            coverage_changed

        if bindings_changed then
            local minimum_index =
                self.selected_index

            for _, model in ipairs(
                self.pool
            ) do
                if model.virtual_index then
                    minimum_index =
                        math.min(
                            minimum_index,
                            model.virtual_index
                        )
                end
            end

            self.window_start = minimum_index
            self:synchronize_continuous_rows()
        end

        -- Only recycled coverage rows need a second layout pass. When the
        -- bindings are already correct, the scroll event is now a no-op.
        if coverage_changed then
            pcall(
                function()
                    self.canvas:update_layout()
                end
            )
        end

        screen.suppress_selection_tracking =
            previous_suppression
        self.rebalancing = false
        self.continuous_refreshing = false

        return bindings_changed
    end

    function controller:continuous_focus(model)
        if not model or
            not model.object then
            return
        end

        local previous_suppression =
            screen.suppress_selection_tracking

        self.continuous_focus_change = true
        screen.suppress_selection_tracking = true
        focus_group_only(model.object)
        screen.suppress_selection_tracking =
            previous_suppression
        self.continuous_focus_change = false
    end

    function controller:continuous_is_scrolling()
        local scrolling = false

        pcall(
            function()
                scrolling =
                    screen.list:is_scrolling()
            end
        )

        return scrolling == true
    end

    function controller:continuous_scroll_to(
        object,
        animate
    )
        if not object then
            return
        end

        pcall(
            function()
                screen.list:remove_all_anim()
            end
        )

        pcall(
            function()
                object:scroll_to_view_recursive(
                    animate == true
                )
            end
        )
    end

    function controller:fixed_cancel_motion()
        if not self.fixed_viewport or
            not self.motion_layer then
            return
        end

        self.motion_generation =
            self.motion_generation + 1

        pcall(
            function()
                self.motion_layer:
                    remove_all_anim()
            end
        )

        self.motion_layer:set {
            y = self.fixed_base_y or 0,
        }
    end

    function controller:fixed_prepare_selection()
        if not self.fixed_viewport then
            return nil
        end

        local view_start =
            self:fixed_resolve_view_start(
                self.selected_index
            )
        local pool_start =
            self:fixed_pool_start_for(
                view_start
            )

        self.fixed_view_start =
            view_start
        self:bind_window(pool_start)

        local model =
            self:model_for_index(
                self.selected_index
            )

        if not model then
            return nil
        end

        local pool_height =
            self:fixed_pool_height()
        local maximum_scroll =
            math.max(
                0,
                pool_height -
                    self.fixed_viewport_height
            )
        local desired_scroll =
            math.max(
                0,
                (
                    view_start -
                        pool_start
                ) * self.row_stride
            )

        self.fixed_base_y =
            -clamp(
                desired_scroll,
                0,
                maximum_scroll
            )
        self.motion_layer:set {
            y = self.fixed_base_y,
        }

        return model
    end

    function controller:selection_in_viewport()
        if not self.fixed_viewport or
            not screen.list then
            return false
        end

        local model =
            self:model_for_index(
                self.selected_index
            )

        if not model or not model.object then
            return false
        end

        local visible = false
        pcall(
            function()
                screen.list:update_layout()
                if self.motion_layer then
                    self.motion_layer:
                        update_layout()
                end
                if self.canvas then
                    self.canvas:update_layout()
                end

                local list_coordinates =
                    screen.list:get_coords()
                local row_coordinates =
                    model.object:get_coords()

                visible =
                    row_coordinates.y1 >=
                        list_coordinates.y1 - 1 and
                    row_coordinates.y2 <=
                        list_coordinates.y2 + 1
            end
        )

        return visible
    end

    function controller:ensure_selection_visible()
        if not self.fixed_viewport then
            return nil
        end

        local locked =
            normalize_id(
                screen.discography_selection_lock
            )
        local selected_id =
            locked or
            normalize_id(
                screen.selected_item_id
            )
        local index =
            self:find_index(selected_id)

        if index then
            self.selected_index = index
            if selected_id then
                assign_selected_id(selected_id)
            end
        end

        local model =
            self:model_for_index(
                self.selected_index
            )

        if model and
            self:selection_in_viewport() then
            return model
        end

        return self:fixed_prepare_selection()
    end

    function controller:fixed_focus_selection(animate_parent)
        local model =
            self:fixed_prepare_selection()

        if not model then
            return nil
        end

        self.continuous_focus_model = model
        self:continuous_focus(model)

        -- Lifecycle resume must not native-scroll the clipped canvas. Encoder
        -- motion uses fixed_animate instead.
        if not screen.suppress_focus_scroll then
            pcall(
                function()
                    self.canvas:update_layout()
                    self.canvas:
                        scroll_to_view_recursive(
                            animate_parent == true
                        )
                end
            )
        end

        return model
    end

    function controller:resume_viewport()
        if not self.fixed_viewport then
            return nil
        end

        local selected_id =
            normalize_id(
                screen.selected_item_id
            )
        local selected_index =
            self:find_index(selected_id)

        if selected_index then
            self.selected_index =
                selected_index
        end

        local preserved_window_start =
            self.window_start
        local preserved_base_y =
            self.fixed_base_y or 0

        self:fixed_cancel_motion()
        self:bind_window(
            preserved_window_start
        )

        local maximum_scroll =
            math.max(
                0,
                self:fixed_pool_height() -
                    self.fixed_viewport_height
            )

        self.fixed_base_y =
            -clamp(
                -preserved_base_y,
                0,
                maximum_scroll
            )
        self.motion_layer:set {
            y = self.fixed_base_y,
        }
        self.fixed_view_start =
            clamp(
                self.window_start +
                math.floor(
                    (-self.fixed_base_y) /
                    self.row_stride
                ),
                1,
                math.max(
                    1,
                    #self.items -
                        self:fixed_visible_count() + 1
                )
            )

        local model =
            self:model_for_index(
                self.selected_index
            )

        if not model then
            model =
                self:fixed_prepare_selection()
        end

        self.continuous_focus_model = model
        self:update_scroll_indicator()

        self:invalidate_viewport()

        self.resume_generation =
            (self.resume_generation or 0) + 1
        self.last_resume_bound_count =
            #self.pool

        trace_fixed_rows(
            self,
            "resume"
        )

        return model
    end

    function controller:capture_resume_viewport()
        if not self.fixed_viewport then
            return false
        end

        pcall(
            function()
                screen.list:update_layout()
                self.canvas:update_layout()

                local viewport =
                    screen.list:get_coords()
                local canvas =
                    self.canvas:get_coords()

                self.resume_native_offset_y =
                    canvas.y1 - viewport.y1
            end
        )

        return true
    end

    function controller:restore_resume_viewport()
        if not self.fixed_viewport then
            return false
        end

        -- Fixed catalogs scroll exclusively through motion_layer. Native list
        -- scroll must stay origin-aligned; restoring a stale native offset
        -- (from list:scroll_to / scroll_to_view) fights fixed_base_y and can
        -- park the selected row above or below the clip after Escape.
        pcall(
            function()
                screen.list:update_layout()
                self.canvas:update_layout()

                local viewport =
                    screen.list:get_coords()
                local canvas =
                    self.canvas:get_coords()
                local current =
                    canvas.y1 - viewport.y1

                if current ~= 0 then
                    screen.list:scroll_by(
                        0,
                        -current,
                        false
                    )
                    screen.list:update_layout()
                    self.canvas:update_layout()
                end
            end
        )

        self.resume_native_offset_y = 0
        return true
    end

    function controller:invalidate_viewport()
        if not self.fixed_viewport then
            return false
        end

        -- Settle parent geometry first, then the clipped fixed-list layers.
        -- install_controls() invokes this once more after restoring focus so
        -- the complete viewport, rather than only the focus damage region,
        -- is ready for the first rendered frame after Back.
        pcall(
            function()
                screen.list:update_layout()
                self.motion_layer:update_layout()
                self.canvas:update_layout()
            end
        )

        resume_trace(
            "invalidate complete viewport"
        )

        for _, row_model in ipairs(
            self.pool
        ) do
            if row_model.object then
                row_model.object:invalidate()
            end
        end

        pcall(
            function()
                self.motion_layer:invalidate()
                self.canvas:invalidate()
                screen.list:invalidate()
                if screen.root then
                    screen.root:invalidate()
                end
            end
        )

        return true
    end

    function controller:repair_resumed_viewport()
        if not self.fixed_viewport then
            return false
        end

        -- A simulator Back pop calls the parent's on_show before the native
        -- backstack loads that parent's LVGL screen. Rebind the complete pool
        -- once the parent is active, while preserving the logical viewport
        -- and selection restored synchronously by resume_viewport().
        local preserved_window_start =
            self.window_start
        local preserved_base_y =
            self.fixed_base_y or 0
        local preserved_selected_index =
            self.selected_index

        self:bind_window(
            preserved_window_start
        )

        self.window_start =
            preserved_window_start
        self.fixed_base_y =
            preserved_base_y
        self.selected_index =
            preserved_selected_index

        self:restore_resume_viewport()
        self.motion_layer:set {
            y = self.fixed_base_y,
        }

        self.fixed_view_start =
            clamp(
                self.window_start +
                math.floor(
                    (-self.fixed_base_y) /
                    self.row_stride
                ),
                1,
                math.max(
                    1,
                    #self.items -
                        self:fixed_visible_count() + 1
                )
            )

        self:update_scroll_indicator()
        self:invalidate_viewport()

        -- Native canvas realignment can leave a recycled selection clipped
        -- (especially Search, which historically used list:scroll_to). Snap
        -- instantly when the logical selection is not fully inside the list.
        self:ensure_selection_visible()

        self.post_resume_repaint_count =
            (self.post_resume_repaint_count or 0) + 1
        self.last_post_resume_bound_count =
            #self.pool

        trace_fixed_rows(
            self,
            "post-pop"
        )

        return true
    end

    function controller:fixed_animate(
        direction,
        animate
    )
        if not self.fixed_viewport or
            not self.motion_layer then
            return
        end

        self:fixed_cancel_motion()

        if animate ~= true or
            direction == 0 then
            return
        end

        local pool_height =
            self:fixed_pool_height()
        local minimum_y =
            math.min(
                0,
                self.fixed_viewport_height -
                    pool_height
            )
        local target_y =
            self.fixed_base_y or 0
        local proposed_start =
            target_y +
            (
                direction > 0 and
                self.row_stride or
                -self.row_stride
            )
        local start_y =
            clamp(
                proposed_start,
                minimum_y,
                0
            )

        if start_y == target_y then
            self.motion_layer:set {
                y = target_y,
            }
            return
        end

        local generation =
            self.motion_generation

        self.motion_layer:set {
            y = start_y,
        }

        self.motion_layer:Anim {
            run = true,
            start_value = start_y,
            end_value = target_y,
            duration = self.motion_duration,
            path = "linear",
            exec_cb =
                function(
                    animated_object,
                    position
                )
                    if self.motion_generation ~=
                            generation then
                        return
                    end

                    animated_object:set {
                        y = position,
                    }
                end,
            done_cb = function()
                if self.motion_generation ==
                        generation and
                    self.motion_layer then
                    self.motion_layer:set {
                        y = self.fixed_base_y or 0,
                    }
                end
            end,
        }
    end

    function controller:fixed_select(
        index,
        animate
    )
        local previous_index =
            self.selected_index
        local previous_view_start =
            self.fixed_view_start
        local from_leading =
            self.continuous_at_sort == true

        index = clamp(
            math.floor(
                tonumber(index) or 1
            ),
            1,
            #self.items
        )

        local direction = 0
        if index > previous_index then
            direction = 1
        elseif index < previous_index then
            direction = -1
        end

        self.selected_index = index
        self.continuous_at_sort = false
        self:update_scroll_indicator()

        local id =
            item_id(
                self.items[index]
            )

        if id then
            assign_selected_id(id)
        end

        -- Stop the prior one-layer animation before rebinding. LVGL does not
        -- draw between these synchronous operations, so the old pool is never
        -- exposed half-recycled. The next frame contains a complete fixed
        -- seven-row window with two or more overscan rows on each side.
        self:fixed_cancel_motion()
        local model =
            self:fixed_focus_selection(
                animate == true and
                    from_leading
            )
        local viewport_moved =
            previous_view_start ~= nil and
            self.fixed_view_start ~=
                previous_view_start

        self:fixed_animate(
            direction,
            animate == true and
                viewport_moved
        )

        return model
    end

    function controller:continuous_select(
        index,
        animate,
        rebase_direction
    )
        index = clamp(
            math.floor(
                tonumber(index) or 1
            ),
            1,
            #self.items
        )

        if self.fixed_viewport then
            return self:fixed_select(
                index,
                animate
            )
        end

        self.selected_index = index
        self.continuous_at_sort = false
        self:update_scroll_indicator()

        local id =
            item_id(
                self.items[index]
            )

        if id then
            assign_selected_id(id)
        end

        local focus_model = nil

        if rebase_direction == 1 or
            rebase_direction == -1 then
            pcall(
                function()
                    screen.list:remove_all_anim()
                end
            )

            -- A burst can move the logical selection farther than the
            -- seven-row pool can animate through. Reuse an already bound
            -- destination row when possible; otherwise rebind the pool
            -- around the destination. Then jump to a covered target
            -- viewport and animate only the final row. Logical selection
            -- remains immediate while visual motion stays short and
            -- consistent.
            local pool_count = #self.pool
            local maximum_start =
                math.max(
                    1,
                    #self.items - pool_count + 1
                )
            local directional_start = nil

            -- Stage burst animations with the destination row at the edge
            -- that is entering the viewport. The other six pooled rows then
            -- cover the entire viewport behind it while the final one-row
            -- motion completes. Centering the destination left only three
            -- rows on the trailing side and exposed the transparent canvas
            -- as a black band during fast scrolling.
            if rebase_direction > 0 then
                directional_start =
                    clamp(
                        index - pool_count + 1,
                        1,
                        maximum_start
                    )
            else
                directional_start =
                    clamp(
                        index,
                        1,
                        maximum_start
                    )
            end

            self:bind_window(directional_start)
            focus_model =
                self:model_for_index(index)

            if not focus_model then
                self:bind_window(
                    self:window_for(index)
                )
                focus_model =
                    self:model_for_index(index) or
                    self.pool[1]
            end
            self.continuous_focus_model =
                focus_model
            self:continuous_focus(focus_model)

            pcall(
                function()
                    self.canvas:update_layout()
                    focus_model.object
                        :scroll_to_view_recursive(
                            false
                        )
                    self.canvas:update_layout()

                    local list_coordinates =
                        screen.list:get_coords()
                    local focus_coordinates =
                        focus_model.object
                            :get_coords()
                    local stage_delta = 0

                    if rebase_direction > 0 then
                        stage_delta =
                            list_coordinates.y2 +
                            self.row_gap + 1 -
                            focus_coordinates.y1
                    else
                        stage_delta =
                            list_coordinates.y1 -
                            self.row_gap - 1 -
                            focus_coordinates.y2
                    end

                    screen.list
                        :scroll_by_bounded(
                            0,
                            stage_delta,
                            false
                        )
                    focus_model.object
                        :scroll_to_view_recursive(
                            animate == true
                        )
                end
            )

            self:continuous_refresh_coverage()
            return focus_model
        end

        focus_model =
            self.continuous_focus_model

        if not focus_model then
            focus_model =
                self:model_for_index(index) or
                self.pool[1]
            self.continuous_focus_model =
                focus_model
        end

        self:continuous_refresh_coverage()
        self:continuous_focus(focus_model)
        self:continuous_scroll_to(
            focus_model.object,
            animate
        )

        return focus_model
    end

    function controller:continuous_move_to_leading(
        index
    )
        local leading_rows =
            self:continuous_leading_rows()
        local model = leading_rows[index]

        if not model or not model.object then
            return
        end

        if self.fixed_viewport then
            self:fixed_cancel_motion()
        end

        self.continuous_at_sort = true
        self.continuous_leading_index = index
        self.continuous_focus_change = true
        focus_group_only(model.object)
        self.continuous_focus_change = false
        self:continuous_scroll_to(
            model.object,
            true
        )
    end

    function controller:continuous_move_to_sort()
        self:continuous_move_to_leading(1)
    end

    function controller:continuous_retarget(diff)
        if not self.continuous_input_active or
            self.continuous_input_suspended then
            return
        end

        diff = math.floor(
            tonumber(diff) or 0
        )

        if diff == 0 then
            return
        end

        local group =
            screen.focus_group or
            lvgl.group.get_default()
        local focused = nil
        local list_was_scrolling =
            self:continuous_is_scrolling()

        pcall(
            function()
                focused = group:get_focused()
            end
        )

        local leading_rows =
            self:continuous_leading_rows()

        for index, model in ipairs(
            leading_rows
        ) do
            if model and
                focused == model.object then
                self.continuous_at_sort = true
                self.continuous_leading_index =
                    index
                break
            end
        end

        if self.continuous_at_sort then
            if diff > 0 then
                local next_leading =
                    (
                        self
                            .continuous_leading_index or
                        1
                    ) + diff

                if next_leading <=
                    #leading_rows then
                    self
                        :continuous_move_to_leading(
                            next_leading
                        )
                else
                    local target_index =
                        math.min(
                            next_leading -
                                #leading_rows,
                            #self.items
                        )
                    local rapid =
                        math.abs(diff) > 1 or
                        list_was_scrolling

                    self:continuous_select(
                        target_index,
                        true,
                        rapid and 1 or nil
                    )
                end
            elseif diff < 0 then
                self:continuous_move_to_leading(
                    math.max(
                        1,
                        (
                            self
                                .continuous_leading_index or
                            1
                        ) + diff
                    )
                )
            end

            return
        end

        local next_index =
            self.selected_index + diff

        if next_index < 1 then
            local leading_index =
                math.max(
                    1,
                    #leading_rows + next_index
                )

            if #leading_rows > 0 then
                self:continuous_move_to_leading(
                    leading_index
                )
            end
            return
        end

        local target_index =
            math.min(
                next_index,
                #self.items
            )
        local direction =
            target_index >=
                self.selected_index and
            1 or -1
        local rapid =
            math.abs(diff) > 1 or
            list_was_scrolling

        self:continuous_select(
            target_index,
            true,
            rapid and direction or nil
        )
    end

    function controller:continuous_adopt_focus(model)
        if not model or
            type(model.virtual_index) ~=
                "number" then
            return
        end

        self.continuous_focus_model = model
        self.continuous_at_sort = false
        self.continuous_leading_index = nil
        self.selected_index =
            model.virtual_index
        self:update_scroll_indicator()

        local id =
            item_id(
                self.items[
                    self.selected_index
                ]
            )

        if id then
            assign_selected_id(id)
        end

        -- Fixed catalogs keep coverage via motion_layer / fixed_prepare.
        -- Native continuous refresh rebases the window and fights Escape
        -- restore when focus is reassigned during resume repaint.
        if not self.fixed_viewport then
            self:continuous_refresh_coverage()
        end
    end

    function controller:install_continuous_input()
        if self.continuous_input_active then
            return true
        end

        if type(controls.set_encoder_handler) ~=
                "function" then
            return false
        end

        local callback =
            function(diff)
                -- Raw encoder deltas use the opposite sign from LVGL's
                -- normal focus navigation. Invert only at this custom
                -- virtual-list boundary so Tracks and Albums match Local
                -- Library without changing any other screen.
                self:continuous_retarget(-diff)
            end
        local ok, supported =
            pcall(
                controls.set_encoder_handler,
                callback
            )

        if not ok or supported ~= true then
            pcall(
                controls.set_encoder_handler,
                nil
            )
            return false
        end

        self.continuous_input_active = true
        self.continuous_input_suspended = false
        self.continuous_encoder_callback = callback

        local group =
            screen.focus_group or
            lvgl.group.get_default()
        local focused = nil

        pcall(
            function()
                focused = group:get_focused()
            end
        )

        self.continuous_at_sort = false
        self.continuous_leading_index = nil

        for index, model in ipairs(
            self:continuous_leading_rows()
        ) do
            if model and
                focused == model.object then
                self.continuous_at_sort = true
                self.continuous_leading_index =
                    index
                break
            end
        end

        if not self.continuous_at_sort then
            for _, model in ipairs(
                self.pool
            ) do
                if focused == model.object then
                    self.continuous_focus_model =
                        model
                    break
                end
            end
        end

        self.continuous_focus_model =
            self.continuous_focus_model or
            self:model_for_index(
                self.selected_index
            ) or
            self.pool[1]

        self:set_scroll_on_focus(false)
        self:continuous_refresh_coverage()

        return true
    end

    function controller:suspend_continuous_input()
        if not self.continuous_input_active or
            self.continuous_input_suspended then
            return
        end

        self.continuous_input_suspended = true

        pcall(
            function()
                screen.list:remove_all_anim()
            end
        )
        pcall(
            controls.set_encoder_handler,
            nil
        )
        self:set_scroll_on_focus(true)
    end

    function controller:resume_continuous_input()
        if not self.continuous_input_active or
            not self.continuous_input_suspended then
            return
        end

        local callback =
            self.continuous_encoder_callback
        local ok, supported =
            pcall(
                controls.set_encoder_handler,
                callback
            )

        if not ok or supported ~= true then
            self.continuous_input_active = false
            self.continuous_input_suspended = false
            self.continuous_encoder_callback = nil
            self:set_scroll_on_focus(true)
            return
        end

        self.continuous_input_suspended = false
        self:set_scroll_on_focus(false)

        local group =
            screen.focus_group or
            lvgl.group.get_default()
        local focused = nil

        pcall(
            function()
                focused = group:get_focused()
            end
        )

        self.continuous_at_sort = false
        self.continuous_leading_index = nil

        for index, model in ipairs(
            self:continuous_leading_rows()
        ) do
            if model and
                focused == model.object then
                self.continuous_at_sort = true
                self.continuous_leading_index =
                    index
                break
            end
        end
        self:continuous_refresh_coverage()
    end

    function controller:restore_continuous_input()
        if not self.continuous_input_active then
            return
        end

        pcall(
            function()
                screen.list:remove_all_anim()
            end
        )
        pcall(
            controls.set_encoder_handler,
            nil
        )
        self:set_scroll_on_focus(true)

        self.continuous_input_suspended = false
        self.continuous_input_active = false
        self.continuous_encoder_callback = nil
        self.continuous_at_sort = false
        self.continuous_leading_index = nil
        self.continuous_focus_change = false
        self.continuous_refreshing = false
        self.continuous_focus_model = nil

        if self.fixed_viewport then
            self:fixed_cancel_motion()
        else
            self:bind_window(
                self:window_for(
                    self.selected_index
                )
            )
        end
    end

    function controller:on_row_focused(model)
        if self.continuous_focus_change or
            self.rebalancing or
            screen.suppress_selection_tracking or
            screen.suppress_focus_scroll or
            screen.discography_selection_lock then
            return
        end

        if self.continuous_input_active and
            not self.continuous_input_suspended then
            self:continuous_adopt_focus(model)
            return
        end

        local logical_index =
            model.virtual_index

        if type(logical_index) ~=
                "number" then
            return
        end

        local previous_index =
            self.selected_index
        local direction = 0

        if logical_index > previous_index then
            direction = 1
        elseif logical_index < previous_index then
            direction = -1
        end

        self.selected_index =
            logical_index
        self:update_scroll_indicator()

        local selected =
            self.items[logical_index]
        local selected_id =
            item_id(selected)

        if selected_id then
            assign_selected_id(selected_id)
        end

        local selected_slot =
            model.virtual_slot or
            self:slot_for(
                logical_index
            )
        local target_slot = nil

        if direction > 0 and
            selected_slot >
                self.forward_slot then
            target_slot =
                self.forward_slot
        elseif direction < 0 and
            selected_slot <
                self.backward_slot then
            target_slot =
                self.backward_slot
        end

        if not target_slot then
            return
        end

        local maximum_start =
            math.max(
                1,
                #self.items -
                    #self.pool + 1
            )
        local next_start =
            clamp(
                logical_index -
                    target_slot + 1,
                1,
                maximum_start
            )

        if next_start ==
                self.window_start then
            return
        end

        self:rotate_to_start(
            next_start
        )

        if selected_id then
            assign_selected_id(selected_id)
        end
    end

    function controller:set_items(
        next_items,
        set_options
    )
        next_items = next_items or {}
        set_options = set_options or {}

        assert(
            #next_items > 0,
            "virtual list cannot be empty"
        )

        if self.continuous_input_active then
            pcall(
                function()
                    screen.list:remove_all_anim()
                end
            )
        end

        self.items = next_items
        self.total_count_authoritative =
            set_options.total_count ~= nil
        self.total_count =
            math.max(
                #next_items,
                math.floor(
                    tonumber(
                        set_options.total_count
                    ) or #next_items
                )
            )
        self:resize_canvas()

        local selected_index = nil

        if not set_options.reset_selection then
            local selected_id =
                normalize_id(
                    screen.selected_item_id
                )

            selected_index =
                self:find_index(
                    selected_id
                )
        end

        self.selected_index =
            selected_index or 1

        local selected_item =
            self.items[self.selected_index]
        local resolved_id =
            item_id(selected_item)

        if resolved_id then
            assign_selected_id(resolved_id)
        end

        if self.fixed_viewport then
            if set_options.reset_selection then
                self.fixed_view_start = nil
            end

            self:fixed_prepare_selection()
        else
            self:bind_window(
                self:window_for(
                    self.selected_index
                )
            )
        end

        if self.continuous_input_active then
            self.continuous_focus_model =
                self:model_for_index(
                    self.selected_index
                ) or
                self.pool[1]
            self:continuous_refresh_coverage()
        end

        self:update_scroll_indicator()
    end

    local pool_count =
        math.min(
            controller.pool_limit,
            #items
        )

    controller.anchor =
        math.min(
            controller.anchor,
            pool_count
        )
    controller.backward_slot =
        math.max(
            1,
            controller.anchor - 1
        )
    controller.forward_slot =
        math.min(
            pool_count,
            controller.anchor + 1
        )

    controller.canvas =
        screen.list:Object {
            w = lvgl.PCT(100),
            h = controller:canvas_height(
                #items
            ),
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_opa = 0,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    controller.canvas:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    controller.canvas:clear_flag(
        lvgl.FLAG.CLICKABLE
    )
    remove_from_group(
        controller.canvas
    )

    screen.virtual_row_canvas =
        controller.canvas
    screen.media_rows = {}

    local row_parent =
        controller.canvas

    if controller.fixed_viewport then
        controller.motion_layer =
            controller.canvas:Object {
                x = 0,
                y = 0,
                w = lvgl.PCT(100),
                h = math.max(
                    1,
                    pool_count * row_stride -
                        row_gap
                ),
                pad_all = 0,
                border_width = 0,
                radius = 0,
                bg_opa = 0,
                scrollbar_mode =
                    lvgl.SCROLLBAR_MODE.OFF,
            }
        controller.motion_layer:
            clear_flag(
                lvgl.FLAG.SCROLLABLE
            )
        controller.motion_layer:
            clear_flag(
                lvgl.FLAG.CLICKABLE
            )
        remove_from_group(
            controller.motion_layer
        )
        row_parent =
            controller.motion_layer
    end

    local previous_row_parent =
        screen.virtual_row_parent

    screen.virtual_row_parent =
        row_parent

    for slot = 1, pool_count do
        local item = items[slot]
        local model =
            options.create_row(
                screen,
                item
            )

        assert(
            type(model) == "table" and
                model.object,
            "virtual list create_row must return a row model"
        )

        model.virtual_slot = slot
        model.virtual_index = slot

        model.virtual_on_click =
            type(options.on_click) ==
                "function" and
            function()
                local current =
                    controller.items[
                        model.virtual_index
                    ]

                if current then
                    options.on_click(
                        current
                    )
                end
            end or
            nil

        model.virtual_on_long_press =
            type(options.on_long_press) ==
                "function" and
            function()
                local current =
                    controller.items[
                        model.virtual_index
                    ]

                if current then
                    options.on_long_press(
                        current
                    )
                end
            end or
            nil

        model.on_click =
            model.virtual_on_click
        model.on_long_press =
            model.virtual_on_long_press

        if model.available == false then
            model.on_click = nil
            model.on_long_press = nil
        end

        local previous_on_focus =
            model.on_focus
        model.on_focus =
            function()
                if type(previous_on_focus) ==
                        "function" then
                    previous_on_focus()
                end
                controller:on_row_focused(
                    model
                )
            end

        controller:position_model(
            model,
            slot
        )
        update_row(
            model,
            item
        )

        table.insert(
            controller.pool,
            model
        )
        table.insert(
            screen.media_rows,
            model
        )
    end

    screen.virtual_row_parent =
        previous_row_parent

    local scroll_indicator_options =
        options.scroll_indicator

    if scroll_indicator_options ~= false then
        local normalized_options = {}

        if type(scroll_indicator_options) ==
                "table" then
            for key, value in pairs(
                scroll_indicator_options
            ) do
                normalized_options[key] = value
            end
        end

        if normalized_options.visible_items ==
                nil then
            normalized_options.visible_items =
                math.max(
                    1,
                    math.floor(
                        (
                            fixed_viewport_height +
                            row_gap
                        ) / row_stride
                    )
                )
        end

        if normalized_options.height == nil then
            normalized_options.height =
                math.max(
                    1,
                    fixed_viewport_height - 4
                )
        end

        scroll_indicator_options =
            normalized_options
    end

    controller.scroll_indicator =
        jellyfin_scroll_indicator.create(
            screen.list,
            scroll_indicator_options
        )

    if controller.scroll_indicator then
        controller.scroll_indicator.models =
            screen.media_rows
    end

    screen.virtual_scroll_indicator =
        controller.scroll_indicator
    screen.scroll_indicator =
        controller.scroll_indicator
    screen.virtual_list_controller = controller

    screen.list:onevent(
        lvgl.EVENT.SCROLL,
        function()
            -- The custom encoder path prepares all seven pooled rows before
            -- starting a one-row animation. Rebinding rows again from inside
            -- each LVGL scroll frame makes objects move while the frame is
            -- being invalidated, which appears as flashing or a black band
            -- creeping in from the trailing edge. Leave the prepared pool
            -- stable for the animation and reconcile once at SCROLL_END.
            if not controller.fixed_viewport and
                (
                    not controller
                        .continuous_input_active or
                    controller
                        .continuous_input_suspended
                ) then
                controller:continuous_refresh_coverage()
            end
        end
    )

    screen.list:onevent(
        lvgl.EVENT.SCROLL_END,
        function()
            if not controller.fixed_viewport then
                controller:
                    continuous_refresh_coverage()
            end
        end
    )

    screen.selection_object_for_id =
        function(id)
            local index =
                controller:find_index(id)

            if not index then
                return nil
            end

            controller.selected_index =
                index
            controller:update_scroll_indicator()

            if controller.fixed_viewport then
                local model =
                    controller:
                        fixed_prepare_selection()

                return
                    model and
                    model.object or
                    nil
            end

            if controller.continuous_input_active then
                controller.continuous_focus_model =
                    controller.continuous_focus_model or
                    controller:model_for_index(index) or
                    controller.pool[1]
                controller:continuous_refresh_coverage()

                return
                    controller.continuous_focus_model and
                    controller.continuous_focus_model.object or
                    nil
            end

            local slot =
                controller:slot_for(index)

            if slot < 1 or
                slot >
                    #controller.pool then
                controller:bind_window(
                    controller:window_for(
                        index
                    )
                )
            end

            local model =
                controller:model_for_index(
                    index
                )

            return model and
                model.object or
                nil
        end

    controller:set_items(
        items,
        {
            total_count =
                options.total_count,
        }
    )

    return controller
end

return M

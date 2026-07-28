local lvgl = require("lvgl")
local controls = require("controls")
local jellyfin_scroll_indicator =
    require("jellyfin_scroll_indicator")

local M = {}

local DEFAULT_POOL_SIZE = 7
local DEFAULT_ANCHOR = 4
local DEFAULT_ROW_HEIGHT = 32
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

    local controller = {
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
        pool_limit =
            math.max(
                1,
                math.floor(
                    tonumber(
                        options.pool_size
                    ) or
                    DEFAULT_POOL_SIZE
                )
            ),
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
            if item_id(item) == id then
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

        return
            indicator:thumb_height_for(
                item_count or #self.items
            )
    end

    function controller:update_scroll_indicator()
        local indicator =
            self.scroll_indicator

        if not indicator then
            return
        end

        indicator:update(
            #self.items,
            self.selected_index
        )
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

        return
            math.max(
                1,
                count * self.row_stride -
                    self.row_gap
            )
    end

    function controller:resize_canvas()
        if not self.canvas then
            return
        end

        self.canvas:set {
            h = self:canvas_height(),
        }
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

        model.object:set {
            x = 0,
            y = self:row_y(
                logical_index
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
            screen.selected_item_id = id
        end

        if screen.ui_active then
            local previous_suppression =
                screen.suppress_selection_tracking

            self.rebalancing = true
            screen.suppress_selection_tracking =
                true
            focus_object(model.object)
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

        apply(
            screen.sort_row and
                screen.sort_row.object or
                nil
        )

        for _, model in ipairs(
            self.pool
        ) do
            apply(model.object)
        end
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

    function controller:continuous_scroll_to(object)
        if not object then
            return
        end

        pcall(
            function()
                object:scroll_to_view_recursive(
                    true
                )
            end
        )
    end

    function controller:continuous_select(index)
        index = clamp(
            math.floor(
                tonumber(index) or 1
            ),
            1,
            #self.items
        )

        self.selected_index = index
        self.continuous_at_sort = false
        self:update_scroll_indicator()

        local id =
            item_id(
                self.items[index]
            )

        if id then
            screen.selected_item_id = id
        end

        local focus_model =
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
            focus_model.object
        )

        return focus_model
    end

    function controller:continuous_move_to_sort()
        local sort_model = screen.sort_row

        if not sort_model or
            not sort_model.object then
            return
        end

        self.continuous_at_sort = true
        self.continuous_focus_change = true
        focus_group_only(sort_model.object)
        self.continuous_focus_change = false
        self:continuous_scroll_to(
            sort_model.object
        )
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

        pcall(
            function()
                focused = group:get_focused()
            end
        )

        if screen.sort_row and
            focused == screen.sort_row.object then
            self.continuous_at_sort = true
        end

        if self.continuous_at_sort then
            if diff > 0 then
                self:continuous_select(
                    math.min(
                        diff,
                        #self.items
                    )
                )
            end

            return
        end

        local next_index =
            self.selected_index + diff

        if next_index < 1 then
            self:continuous_move_to_sort()
            return
        end

        self:continuous_select(
            math.min(
                next_index,
                #self.items
            )
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
            screen.selected_item_id = id
        end

        self:continuous_refresh_coverage()
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

        self.continuous_at_sort =
            screen.sort_row and
            focused == screen.sort_row.object or
            false

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

        self.continuous_at_sort =
            screen.sort_row and
            focused == screen.sort_row.object or
            false
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
        self.continuous_focus_change = false
        self.continuous_refreshing = false
        self.continuous_focus_model = nil

        self:bind_window(
            self:window_for(
                self.selected_index
            )
        )
    end

    function controller:on_row_focused(model)
        if self.continuous_focus_change or
            self.rebalancing or
            screen.suppress_selection_tracking then
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
            screen.selected_item_id =
                selected_id
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
            screen.selected_item_id =
                selected_id
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
            screen.selected_item_id =
                resolved_id
        end

        self:bind_window(
            self:window_for(
                self.selected_index
            )
        )

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

    local previous_row_parent =
        screen.virtual_row_parent

    screen.virtual_row_parent =
        controller.canvas

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
        model.on_focus =
            function()
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

    controller.scroll_indicator =
        jellyfin_scroll_indicator.create(
            screen.list,
            options.scroll_indicator
        )
    screen.virtual_scroll_indicator =
        controller.scroll_indicator
    screen.virtual_list_controller = controller

    screen.list:onevent(
        lvgl.EVENT.SCROLL,
        function()
            controller:continuous_refresh_coverage()
        end
    )

    screen.list:onevent(
        lvgl.EVENT.SCROLL_END,
        function()
            controller:continuous_refresh_coverage()
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

    controller:set_items(items)

    return controller
end

return M

local M = {}

local DEFAULT_POOL_SIZE = 7
local DEFAULT_ANCHOR = 4

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
            object:scroll_to_view(false)
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

    local controller = {
        screen = screen,
        items = {},
        pool = {},
        window_start = 1,
        selected_index = 1,
        rebalancing = false,
        options = options,
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

            model.virtual_index =
                logical_index
            update_row(
                model,
                item
            )
        end

        screen.suppress_selection_tracking =
            previous_suppression
    end

    function controller:model_for_index(index)
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

    function controller:rebind_focused_index(
        logical_index,
        next_start,
        focused_model
    )
        local previous_y = nil

        if focused_model and
            focused_model.object then
            pcall(
                function()
                    focused_model.object
                        :scroll_to_view(false)
                end
            )

            local ok, coordinates =
                pcall(
                    function()
                        return
                            focused_model.object
                                :get_coords()
                    end
                )

            if ok and coordinates then
                previous_y =
                    coordinates.y1
            end
        end

        self.rebalancing = true

        local previous_suppression =
            screen.suppress_selection_tracking

        screen.suppress_selection_tracking =
            true
        self:bind_window(next_start)

        local next_model =
            self:model_for_index(
                logical_index
            )

        if next_model then
            focus_object(
                next_model.object
            )

            if previous_y and
                screen.list then
                pcall(
                    function()
                        local coordinates =
                            next_model.object
                                :get_coords()
                        local delta =
                            previous_y -
                            coordinates.y1

                        if delta ~= 0 then
                            screen.list
                                :scroll_by_bounded(
                                    0,
                                    delta,
                                    false
                                )
                        end
                    end
                )
            end
        end

        screen.suppress_selection_tracking =
            previous_suppression
        self.rebalancing = false

        return next_model
    end

    function controller:on_row_focused(model)
        if self.rebalancing or
            screen.suppress_selection_tracking then
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

        self:rebind_focused_index(
            logical_index,
            next_start,
            model
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

        self.items = next_items

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

    screen.media_rows = {}

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

    screen.selection_object_for_id =
        function(id)
            local index =
                controller:find_index(id)

            if not index then
                return nil
            end

            controller.selected_index =
                index

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

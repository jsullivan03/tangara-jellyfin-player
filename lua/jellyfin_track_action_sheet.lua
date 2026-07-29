local lvgl = require("lvgl")
local backstack = require("backstack")
local jellyfin_navigation =
    require("jellyfin_navigation")
local jellyfin_track_actions =
    require("jellyfin_track_actions")
local jellyfin_text_entry =
    require("jellyfin_text_entry")
local sync_library_view =
    require("sync_library_view")
local sync_operation_queue =
    require("sync_operation_queue")

local M = {}

local SCREEN_WIDTH = 160
local SCREEN_HEIGHT = 128
local BUTTON_HEIGHT = 15
local MAX_MAIN_HEIGHT = 109
local PLAYLIST_HEIGHT = 76
local SHEET_ANIMATION_MS = 170

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

local function add_to_group(group, object)
    if not group or not object then
        return
    end

    local added = pcall(
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

local function focus_object(object)
    if not object then
        return
    end

    local focused = pcall(
        function()
            lvgl.group.focus_obj(object)
        end
    )

    if not focused then
        pcall(
            function()
                object:focus()
            end
        )
    end
end

local function animate_y(
    object,
    start_y,
    end_y,
    done_callback
)
    object:set {
        y = start_y,
    }

    object:Anim {
        run = true,
        start_value = start_y,
        end_value = end_y,
        duration = SHEET_ANIMATION_MS,
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
        done_cb = done_callback,
    }
end

local function add_sheet_button(
    list,
    label,
    callback,
    on_focus
)
    local button =
        list:add_btn(nil, label)

    button:set {
        w = lvgl.PCT(100),
        h = BUTTON_HEIGHT,
        pad_left = 7,
        pad_right = 3,
        pad_top = 0,
        pad_bottom = 0,
        border_width = 0,
        outline_width = 0,
        shadow_width = 0,
        radius = 0,
        bg_opa = 0,
        text_color = "#FFFFFF",
        text_font = font.fusion_10,
    }

    if type(on_focus) == "function" then
        button:onevent(
            lvgl.EVENT.FOCUSED,
            function()
                on_focus(button)
            end
        )
    end

    button:onClicked(callback)

    return button
end

local function owner_rows(owner)
    return owner and owner.rows or {}
end

local function controller_for(owner)
    local controller = {
        owner = owner,
        is_open = false,
        animating = false,
        page = "main",
        main_buttons = {},
        main_action_ids = {},
        main_actions_by_id = {},
        playlist_buttons = {},
        playlist_create_button = nil,
        playlist_initial_button = nil,
        playlist_initial_scroll_y = 0,
        highlighted_button = nil,
        active_button_count = 0,
        group = nil,
        previous_wrap = nil,
        previous_focus = nil,
        track = nil,
        item = nil,
        context = nil,
        favorite = false,
    }

    local original_go_back = owner.go_back

    local function refresh_highlight(
        focused_button
    )
        controller.highlighted_button =
            focused_button

        if focused_button then
            pcall(function()
                focused_button
                    :scroll_to_view_recursive(false)
            end)
        end

        local stale_focus_state =
            lvgl.STATE.FOCUSED |
            lvgl.STATE.FOCUS_KEY

        local function update(button)
            if not button then
                return
            end

            if button ~= focused_button then
                pcall(
                    function()
                        button:clear_state(
                            stale_focus_state
                        )
                    end
                )
            end

            pcall(
                function()
                    button:set {
                        bg_opa = 0,
                        text_color =
                            button ==
                                focused_button and
                                "#72AFFF" or
                                "#FFFFFF",
                    }
                end
            )
        end

        for _, button in ipairs(
            controller.main_buttons
        ) do
            update(button)
        end

        for _, button in ipairs(
            controller.playlist_buttons
        ) do
            update(button)
        end
    end

    local function remove_sheet_buttons()
        for _, button in ipairs(
            controller.main_buttons
        ) do
            remove_from_group(button)
        end

        for _, button in ipairs(
            controller.playlist_buttons
        ) do
            remove_from_group(button)
        end

        controller.active_button_count = 0
        refresh_highlight(nil)
    end

    local function remove_owner_rows()
        for _, model in ipairs(
            owner_rows(owner)
        ) do
            remove_from_group(
                model and model.object
            )
        end
    end

    local function add_owner_rows(group)
        if not owner.ui_active then
            return
        end

        for _, model in ipairs(
            owner_rows(owner)
        ) do
            add_to_group(
                group,
                model and model.object
            )
        end
    end

    local function prepare_focus()
        local group =
            controller.group or
            owner.focus_group or
            lvgl.group.get_default()

        if not group then
            return nil
        end

        if not controller.group then
            controller.group = group

            local ok, wrap = pcall(
                function()
                    return group:get_wrap()
                end
            )

            controller.previous_wrap =
                ok and wrap or true

            local focus_ok, focused = pcall(
                function()
                    return group:get_focused()
                end
            )

            if focus_ok then
                controller.previous_focus =
                    focused
            end
        end

        pcall(
            function()
                group:set_wrap(false)
            end
        )

        remove_owner_rows()
        remove_sheet_buttons()

        return group
    end

    local function activate_buttons(
        buttons,
        initial_button
    )
        local group = prepare_focus()

        if not group then
            return
        end

        for _, button in ipairs(buttons) do
            add_to_group(group, button)
        end

        controller.active_button_count =
            #buttons

        focus_object(
            initial_button or buttons[1]
        )
    end

    local function add_playlist_scroll_spacer(
        list,
        button_count
    )
        -- Keep one row of upward scroll available even when there is only a
        -- single real playlist. That lets Create playlist live just above the
        -- initial viewport instead of being permanently visible.
        local viewport_height = 68
        local required_content_height =
            viewport_height + BUTTON_HEIGHT
        local spacer_height =
            required_content_height -
            (button_count * BUTTON_HEIGHT)

        if spacer_height <= 0 then
            return nil
        end

        local spacer = list:add_btn(nil, "")

        spacer:set {
            w = lvgl.PCT(100),
            h = spacer_height,
            pad_all = 0,
            border_width = 0,
            outline_width = 0,
            shadow_width = 0,
            radius = 0,
            bg_opa = 0,
            text_color = "#11131A",
        }
        spacer:clear_flag(lvgl.FLAG.CLICKABLE)
        remove_from_group(spacer)

        return spacer
    end

    local function position_playlist_chooser()
        local scroll_y = 0

        if #controller.playlist_buttons > 1 then
            scroll_y = BUTTON_HEIGHT
        end

        controller.playlist_initial_scroll_y =
            scroll_y

        local function apply_scroll()
            pcall(function()
                controller.playlist_list:scroll_to {
                    x = 0,
                    y = scroll_y,
                    anim = false,
                }
            end)
        end

        -- Apply once immediately and once after LVGL has recalculated the
        -- list content height. The second pass is what makes the offset
        -- reliable on both the simulator and hardware.
        apply_scroll()
        lvgl.Timer {
            period = 1,
            repeat_count = 1,
            cb = apply_scroll,
        }
    end

    local function restore_focus()
        local group =
            controller.group or
            owner.focus_group or
            lvgl.group.get_default()

        remove_sheet_buttons()
        add_owner_rows(group)

        if group and
            controller.previous_wrap ~= nil then
            pcall(
                function()
                    group:set_wrap(
                        controller.previous_wrap ~=
                            false
                    )
                end
            )
        end

        if owner.ui_active then
            focus_object(
                controller.previous_focus or
                owner.first_row
            )
        end

        controller.group = nil
        controller.previous_wrap = nil
        controller.previous_focus = nil

        if owner.ui_active and
            owner.virtual_list_controller then
            owner.virtual_list_controller
                :resume_continuous_input()
        end

        jellyfin_navigation.set_back(
            owner.go_back
        )
    end

    local function ensure_ui()
        if controller.overlay then
            return
        end

        local overlay =
            owner.root:Object {
                x = 0,
                y = 0,
                w = SCREEN_WIDTH,
                h = SCREEN_HEIGHT,
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

        local dimmer =
            overlay:Button {
                x = 0,
                y = 0,
                w = SCREEN_WIDTH,
                h = SCREEN_HEIGHT,
                pad_all = 0,
                border_width = 0,
                outline_width = 0,
                shadow_width = 0,
                radius = 0,
                bg_color = "#000000",
                bg_opa = 95,
            }

        local main_sheet =
            overlay:Object {
                x = 0,
                y = SCREEN_HEIGHT,
                w = SCREEN_WIDTH,
                h = 34,
                pad_all = 0,
                border_width = 1,
                border_color = "#555862",
                radius = 8,
                bg_color = "#11131A",
                bg_opa = 248,
                scrollbar_mode =
                    lvgl.SCROLLBAR_MODE.OFF,
            }

        main_sheet:clear_flag(
            lvgl.FLAG.SCROLLABLE
        )

        local main_list =
            lvgl.List(
                main_sheet,
                {
                    x = 2,
                    y = 2,
                    w = 156,
                    h = 30,
                }
            )

        main_list:set {
            pad_all = 0,
            pad_row = 0,
            border_width = 0,
            radius = 0,
            bg_opa = 0,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.AUTO,
        }

        local playlist_sheet =
            overlay:Object {
                x = 0,
                y = SCREEN_HEIGHT,
                w = SCREEN_WIDTH,
                h = PLAYLIST_HEIGHT,
                pad_all = 0,
                border_width = 1,
                border_color = "#555862",
                radius = 8,
                bg_color = "#11131A",
                bg_opa = 248,
                scrollbar_mode =
                    lvgl.SCROLLBAR_MODE.OFF,
            }

        playlist_sheet:clear_flag(
            lvgl.FLAG.SCROLLABLE
        )
        playlist_sheet:add_flag(
            lvgl.FLAG.HIDDEN
        )

        local playlist_title =
            playlist_sheet:Label {
                x = 6,
                y = 5,
                w = 148,
                text = "",
                text_align = 2,
                text_color = "#D7D8DE",
                text_font = font.fusion_10,
            }

        playlist_title:add_flag(
            lvgl.FLAG.HIDDEN
        )

        local playlist_list =
            lvgl.List(
                playlist_sheet,
                {
                    x = 4,
                    y = 4,
                    w = 152,
                    h = 68,
                }
            )

        playlist_list:set {
            pad_all = 0,
            pad_row = 0,
            border_width = 0,
            radius = 0,
            bg_opa = 0,
        }

        remove_from_group(dimmer)

        controller.overlay = overlay
        controller.dimmer = dimmer
        controller.main_sheet = main_sheet
        controller.main_list = main_list
        controller.playlist_sheet =
            playlist_sheet
        controller.playlist_title =
            playlist_title
        controller.playlist_list =
            playlist_list
        controller.playlist_header_visible = false
        controller.main_height = 34
        controller.main_target_y = 94
        controller.playlist_target_y =
            SCREEN_HEIGHT - PLAYLIST_HEIGHT

        dimmer:onClicked(
            function()
                controller:close()
            end
        )
    end

    local function finish_close()
        if not controller.overlay then
            return
        end

        controller.overlay:add_flag(
            lvgl.FLAG.HIDDEN
        )
        controller.main_sheet:clear_flag(
            lvgl.FLAG.HIDDEN
        )
        controller.playlist_sheet:add_flag(
            lvgl.FLAG.HIDDEN
        )
        controller.main_sheet:set {
            y = SCREEN_HEIGHT,
        }
        controller.playlist_sheet:set {
            y = SCREEN_HEIGHT,
        }

        controller.is_open = false
        controller.animating = false
        controller.page = "main"

        restore_focus()
    end

    function controller:close(immediate)
        if not self.is_open then
            return
        end

        if immediate == true then
            finish_close()
            return
        end

        if self.animating then
            return
        end

        self.animating = true
        prepare_focus()

        local current_sheet =
            self.page == "playlists" and
            self.playlist_sheet or
            self.main_sheet
        local current_y =
            self.page == "playlists" and
            self.playlist_target_y or
            self.main_target_y

        animate_y(
            current_sheet,
            current_y,
            SCREEN_HEIGHT,
            finish_close
        )
    end

    local function close_soon()
        lvgl.Timer {
            period = 350,
            repeat_count = 1,
            cb = function()
                controller:close()
            end,
        }
    end

    local function open_artist(artist)
        if not artist then
            return
        end

        controller:close(true)

        local local_library =
            require("jellyfin_local_library")

        backstack.push(
            local_library.Artist:new {
                title =
                    artist.name or "Artist",
                artist_key = artist.key,
            }
        )
    end

    local function queue_favorite()
        local operation,
            operation_error =
            sync_operation_queue
                .enqueue_set_favorite(
                    controller.track.id,
                    not controller.favorite
                )

        if not operation then
            if controller.favorite_button then
                controller.favorite_button:set {
                    text =
                        operation_error or
                        "Unable to queue change",
                }
            end

            return
        end

        controller.favorite =
            not controller.favorite

        if controller.favorite_button then
            controller.favorite_button:set {
                text =
                    controller.favorite and
                    "Remove favorite" or
                    "Add favorite",
            }
        end

        close_soon()
    end

    local function remove_from_playlist()
        local context =
            controller.context or {}
        local entry_id = context.entry_id

        if type(entry_id) ~= "string" or
            entry_id == "" or
            entry_id:match(
                "^local%-entry:"
            ) then
            if controller.remove_button then
                controller.remove_button:set {
                    text = "Waiting for sync",
                }
            end

            return
        end

        local operation,
            operation_error =
            sync_operation_queue
                .enqueue_remove_playlist_item(
                    context.collection_id,
                    entry_id
                )

        if not operation then
            if controller.remove_button then
                controller.remove_button:set {
                    text =
                        operation_error or
                        "Unable to remove",
                }
            end

            return
        end

        close_soon()
    end

    local function show_main()
        if controller.animating then
            return
        end

        controller.animating = true
        prepare_focus()

        animate_y(
            controller.playlist_sheet,
            controller.playlist_target_y,
            SCREEN_HEIGHT,
            function()
                controller.playlist_sheet
                    :add_flag(
                        lvgl.FLAG.HIDDEN
                    )
                controller.main_sheet
                    :clear_flag(
                        lvgl.FLAG.HIDDEN
                    )

                controller.page = "main"
                controller.animating = false

                animate_y(
                    controller.main_sheet,
                    SCREEN_HEIGHT,
                    controller.main_target_y,
                    function()
                        activate_buttons(
                            controller.main_buttons,
                            controller.main_buttons[1]
                        )
                    end
                )
            end
        )
    end

    local function rebuild_playlist_buttons(
        library
    )
        for _, button in ipairs(
            controller.playlist_buttons
        ) do
            remove_from_group(button)
        end

        controller.playlist_list:clean()
        controller.playlist_buttons = {}
        controller.playlist_labels = {}
        controller.playlist_activators = {}
        controller.playlist_create_button = nil
        controller.playlist_initial_button = nil
        controller.playlist_initial_scroll_y = 0

        local function register_playlist_button(
            label,
            button,
            activate
        )
            table.insert(
                controller.playlist_buttons,
                button
            )
            table.insert(
                controller.playlist_labels,
                label
            )
            table.insert(
                controller.playlist_activators,
                activate
            )
        end

        local create_action = function()
            local track_id =
                controller.track and
                controller.track.id

            controller:close(true)

            backstack.push(
                jellyfin_text_entry.new {
                    title = "New playlist",
                    on_submit =
                        function(name)
                            local local_id,
                                operation_or_error =
                                sync_operation_queue
                                    .enqueue_create_playlist(
                                        name,
                                        {track_id}
                                    )

                            if not local_id then
                                return false,
                                    operation_or_error
                            end

                            return true
                        end,
                }
            )
        end

        local create_button =
            add_sheet_button(
                controller.playlist_list,
                "Create playlist",
                create_action,
                refresh_highlight
            )

        register_playlist_button(
            "Create playlist",
            create_button,
            create_action
        )
        controller.playlist_create_button =
            create_button

        for _, playlist in ipairs(
            library and
            library.playlists or {}
        ) do
            local playlist_copy = playlist

            local playlist_action = function()
                local playlist_id =
                    playlist_copy.local_id or
                    playlist_copy.id

                local operation,
                    operation_error =
                    sync_operation_queue
                        .enqueue_add_playlist_item(
                            playlist_id,
                            controller.track.id
                        )

                if not operation then
                    controller.playlist_list:add_flag(
                        lvgl.FLAG.HIDDEN
                    )
                    controller.playlist_title:set {
                        text =
                            operation_error or
                            "Unable to queue add",
                    }
                    controller.playlist_title:clear_flag(
                        lvgl.FLAG.HIDDEN
                    )
                    controller.playlist_header_visible = true
                    return
                end

                close_soon()
            end

            local label =
                playlist_copy.name or
                "Playlist"
            local button =
                add_sheet_button(
                    controller.playlist_list,
                    label,
                    playlist_action,
                    refresh_highlight
                )

            register_playlist_button(
                label,
                button,
                playlist_action
            )

        end

        controller.playlist_initial_button =
            controller.playlist_buttons[2] or
            controller.playlist_buttons[1]

        controller.playlist_scroll_spacer =
            add_playlist_scroll_spacer(
                controller.playlist_list,
                #controller.playlist_buttons
            )
    end

    local function show_playlists()
        if controller.animating then
            return
        end

        controller.playlist_title:add_flag(
            lvgl.FLAG.HIDDEN
        )
        controller.playlist_list:clear_flag(
            lvgl.FLAG.HIDDEN
        )
        controller.playlist_header_visible = false
        controller.animating = true
        prepare_focus()

        animate_y(
            controller.main_sheet,
            controller.main_target_y,
            SCREEN_HEIGHT,
            function()
                controller.main_sheet:add_flag(
                    lvgl.FLAG.HIDDEN
                )
                controller.playlist_sheet
                    :clear_flag(
                        lvgl.FLAG.HIDDEN
                    )

                controller.page = "playlists"
                controller.animating = false

                animate_y(
                    controller.playlist_sheet,
                    SCREEN_HEIGHT,
                    controller.playlist_target_y,
                    function()
                        activate_buttons(
                            controller.playlist_buttons,
                            controller.playlist_initial_button or
                                controller.playlist_buttons[1]
                        )
                        position_playlist_chooser()
                    end
                )
            end
        )
    end

    local function rebuild_main_actions(
        library
    )
        for _, button in ipairs(
            controller.main_buttons
        ) do
            remove_from_group(button)
        end

        controller.main_list:clean()
        controller.main_buttons = {}
        controller.main_action_ids = {}
        controller.main_actions_by_id = {}
        controller.favorite_button = nil
        controller.remove_button = nil

        local actions =
            jellyfin_track_actions.main {
                track = controller.track,
                item = controller.item,
                context = controller.context,
                favorite = controller.favorite,
                handlers = {
                    open_artist = open_artist,
                    toggle_favorite =
                        queue_favorite,
                    show_playlists =
                        show_playlists,
                    remove_from_playlist =
                        remove_from_playlist,
                },
            }

        for _, action in ipairs(actions) do
            local button =
                add_sheet_button(
                    controller.main_list,
                    action.label,
                    action.activate,
                    refresh_highlight
                )

            table.insert(
                controller.main_buttons,
                button
            )
            table.insert(
                controller.main_action_ids,
                action.id
            )
            controller.main_actions_by_id[
                action.id
            ] = action.activate

            if action.id == "favorite" then
                controller.favorite_button =
                    button
            elseif action.id ==
                    "remove_from_playlist" then
                controller.remove_button =
                    button
            end
        end

        local content_height =
            #controller.main_buttons *
            BUTTON_HEIGHT

        controller.main_height =
            math.min(
                MAX_MAIN_HEIGHT,
                content_height + 4
            )
        controller.main_target_y =
            SCREEN_HEIGHT -
            controller.main_height

        controller.main_sheet:set {
            h = controller.main_height,
        }
        controller.main_list:set {
            h = controller.main_height - 4,
        }
    end

    function controller:open(
        track,
        context,
        item
    )
        if self.is_open or self.animating then
            return
        end

        ensure_ui()

        self.track = track or {}
        self.context = context or {}
        self.item = item or track or {}

        local library =
            sync_library_view.current()

        self.favorite =
            jellyfin_track_actions
                .favorite_state(
                    library,
                    self.track.id
                )

        rebuild_main_actions(library)
        rebuild_playlist_buttons(library)

        self.playlist_title:add_flag(
            lvgl.FLAG.HIDDEN
        )
        self.playlist_list:clear_flag(
            lvgl.FLAG.HIDDEN
        )
        self.playlist_header_visible = false
        self.playlist_sheet:add_flag(
            lvgl.FLAG.HIDDEN
        )
        self.main_sheet:clear_flag(
            lvgl.FLAG.HIDDEN
        )
        self.overlay:clear_flag(
            lvgl.FLAG.HIDDEN
        )

        self.is_open = true
        self.page = "main"
        self.animating = true

        if owner.virtual_list_controller then
            owner.virtual_list_controller
                :suspend_continuous_input()
        end

        prepare_focus()
        jellyfin_navigation.set_back(
            owner.go_back
        )

        animate_y(
            self.main_sheet,
            SCREEN_HEIGHT,
            self.main_target_y,
            function()
                self.animating = false
                activate_buttons(
                    self.main_buttons,
                    self.main_buttons[1]
                )
            end
        )
    end

    function controller:activate(action_id)
        local callback =
            self.main_actions_by_id[
                action_id
            ]

        if type(callback) ~= "function" then
            return false
        end

        callback()
        return true
    end

    function controller:activate_playlist(action)
        local index = nil

        if type(action) == "number" then
            index = action
        else
            for candidate_index, label in ipairs(
                self.playlist_labels or {}
            ) do
                if label == action then
                    index = candidate_index
                    break
                end
            end
        end

        local activate =
            index and
            self.playlist_activators and
            self.playlist_activators[index]

        if type(activate) == "function" then
            activate()
            return true
        end

        return false
    end

    function controller:state()
        local highlighted_action = nil

        for index, button in ipairs(
            self.main_buttons
        ) do
            if button ==
                    self.highlighted_button then
                highlighted_action =
                    self.main_action_ids[index]
                break
            end
        end

        return {
            open = self.is_open,
            animating = self.animating,
            page = self.page,
            main_count =
                #self.main_buttons,
            playlist_count =
                #self.playlist_buttons,
            playlist_labels =
                self.playlist_labels or {},
            playlist_header_visible =
                self.playlist_header_visible == true,
            playlist_initial_scroll_y =
                self.playlist_initial_scroll_y or 0,
            playlist_create_hidden_on_open =
                (self.playlist_initial_scroll_y or 0) >=
                    BUTTON_HEIGHT,
            playlist_initial_label =
                (function()
                    for index, button in ipairs(
                        self.playlist_buttons
                    ) do
                        if button ==
                                self.playlist_initial_button then
                            return self.playlist_labels[index]
                        end
                    end

                    return nil
                end)(),
            active_count =
                self.active_button_count,
            main_actions =
                self.main_action_ids,
            highlighted_action =
                highlighted_action,
        }
    end

    owner.go_back = function()
        if controller.is_open then
            if controller.page == "playlists" then
                show_main()
            else
                controller:close()
            end
            return
        end

        original_go_back()
    end

    controller.original_go_back =
        original_go_back

    return controller
end

function M.attach(owner)
    if owner.track_action_sheet then
        return owner.track_action_sheet
    end

    local controller =
        controller_for(owner)

    owner.track_action_sheet = controller

    return controller
end

return M

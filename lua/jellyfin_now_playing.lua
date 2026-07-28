local lvgl = require("lvgl")
local backstack = require("backstack")
local controls = require("controls")
local jellyfin_navigation =
    require("jellyfin_navigation")
local jellyfin_playback =
    require("jellyfin_playback")
local playback = require("playback")
local power = require("power")
local premium =
    require("premium_now_playing_screen")
local screen = require("screen")
local sync_config = require("sync_config")
local sync_library_view =
    require("sync_library_view")
local sync_operation_queue =
    require("sync_operation_queue")
local sync_runtime = require("sync_runtime")

local function format_time(value)
    value =
        math.max(
            0,
            math.floor(value or 0)
        )

    return string.format(
        "%d:%02d",
        math.floor(value / 60),
        value % 60
    )
end

local function current_clock()
    local ok, value =
        pcall(
            function()
                return os.date("%H:%M")
            end
        )

    if ok and
        type(value) == "string" and
        value ~= "" then
        return value
    end

    return "--:--"
end

local function simulator_mode()
    local ok, value =
        pcall(
            function()
                return os.getenv(
                    "TANGARA_SIM_SERVER_URL"
                )
            end
        )

    return ok and
        type(value) == "string" and
        value ~= ""
end

local function charging_state()
    local state =
        power.charge_state:get()

    return state ==
            "charge_regular" or
        state == "charge_fast" or
        state == "full_charge"
end

local function artwork_value(
    active,
    name,
    fallback
)
    local item_artwork =
        active and
        active.item and
        active.item.artwork

    local track_artwork =
        active and
        active.track and
        active.track.artwork

    if type(item_artwork) == "table" and
        type(item_artwork[name]) ==
            "string" and
        item_artwork[name] ~= "" then
        return item_artwork[name]
    end

    if type(track_artwork) == "table" and
        type(track_artwork[name]) ==
            "string" and
        track_artwork[name] ~= "" then
        return track_artwork[name]
    end

    return fallback
end

local function server_connected(active)
    if active and
        active.context and
        active.context.server_connected ~=
            nil then
        return active.context
            .server_connected == true
    end

    local status = sync_config.status()

    if not status.connected then
        return simulator_mode()
    end

    local library_result =
        sync_runtime.last_library_result()

    if type(library_result) ==
            "table" then
        return library_result.ok == true
    end

    local result =
        sync_runtime.last_result()

    if type(result) == "table" then
        return result.ok == true
    end

    return status.connected == true
end

local function favorite_state(
    library,
    item_id
)
    if not library or
        not library.favorites then
        return false
    end

    for _, track in ipairs(
        library.favorites.items or {}
    ) do
        if track.id == item_id then
            return true
        end
    end

    return false
end

local function add_sheet_button(
    list,
    label,
    callback
)
    local button =
        list:add_btn(nil, label)

    button:set {
        w = lvgl.PCT(100),
        h = 15,
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

    button:onevent(
        lvgl.EVENT.FOCUSED,
        function()
            button:set {
                bg_opa = 0,
                text_color = "#72AFFF",
            }
        end
    )

    button:onevent(
        lvgl.EVENT.DEFOCUSED,
        function()
            button:set {
                bg_opa = 0,
                text_color = "#FFFFFF",
            }
        end
    )

    button:onClicked(callback)

    return button
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
        duration = 170,
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

local NowPlaying =
    screen:new {
        create_ui = function(self)
            local active =
                jellyfin_playback.current()

            local track =
                active and
                active.track or {}

            local context =
                active and
                active.context or {}

            local duration =
                tonumber(track.duration)
                or tonumber(
                    active and
                    active.item and
                    active.item.duration
                )
                or 0

            self.go_back =
                function()
                    backstack.pop()
                end

            self.view =
                premium.create {
                    background =
                        artwork_value(
                            active,
                            "background",
                            "//lua/img/background_placeholder.png"
                        ),
                    cover =
                        artwork_value(
                            active,
                            "cover",
                            "//lua/img/cover_placeholder.png"
                        ),
                    title =
                        track.title or
                        "Nothing playing",
                    artist =
                        track.artist or "",
                    progress = 0,
                    elapsed = "0:00",
                    paused =
                        playback.playing:get() ~=
                        true,
                    remaining =
                        format_time(
                            duration
                        ),
                    clock =
                        current_clock(),
                    connected =
                        server_connected(
                            active
                        ),
                    battery_pct =
                        power.battery_pct
                            :get(),
                    charging =
                        charging_state(),
                }

            self.root = self.view.root
            self.sheet_open = false
            self.sheet_animating = false
            self.sheet_page = "main"

            local menu_hitbox =
                self.root:Button {
                    x = 0,
                    y = 13,
                    w = 160,
                    h = 115,
                    pad_all = 0,
                    border_width = 0,
                    outline_width = 0,
                    shadow_width = 0,
                    radius = 0,
                    bg_opa = 0,
                }

            self.menu_hitbox =
                menu_hitbox

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
                    bg_opa = 95,
                }

            local option_count = 2

            if context.collection_kind ==
                "playlist" then
                option_count = 3
            end

            local main_height =
                option_count * 15 + 4
            local main_target_y =
                128 - main_height

            local main_sheet =
                overlay:Object {
                    x = 0,
                    y = 128,
                    w = 160,
                    h = main_height,
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
                        h = main_height - 4,
                    }
                )

            main_list:set {
                pad_all = 0,
                pad_row = 0,
                border_width = 0,
                radius = 0,
                bg_opa = 0,
                scrollbar_mode =
                    lvgl.SCROLLBAR_MODE.OFF,
            }

            local playlist_height = 76
            local playlist_target_y =
                128 - playlist_height

            local playlist_sheet =
                overlay:Object {
                    x = 0,
                    y = 128,
                    w = 160,
                    h = playlist_height,
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
                    text = "Add to playlist",
                    text_align = 2,
                    text_color = "#D7D8DE",
                    text_font = font.fusion_10,
                }

            local playlist_list =
                lvgl.List(
                    playlist_sheet,
                    {
                        x = 4,
                        y = 17,
                        w = 152,
                        h = 55,
                    }
                )

            playlist_list:set {
                pad_all = 0,
                pad_row = 0,
                border_width = 0,
                radius = 0,
                bg_opa = 0,
            }

            local library =
                sync_library_view.current()

            local favorite =
                favorite_state(
                    library,
                    track.id
                )

            local favorite_button
            local main_buttons = {}
            local playlist_buttons = {}
            local sheet_group = nil
            local previous_sheet_wrap = nil
            local active_sheet_button_count = 0

            local function remove_sheet_buttons()
                for _, button in ipairs(
                    main_buttons
                ) do
                    remove_from_group(button)
                end

                for _, button in ipairs(
                    playlist_buttons
                ) do
                    remove_from_group(button)
                end

                active_sheet_button_count = 0
            end

            local function prepare_sheet_focus()
                local group =
                    sheet_group or
                    lvgl.group.get_default()

                if not group then
                    return nil
                end

                if not sheet_group then
                    sheet_group = group

                    local ok, wrap = pcall(
                        function()
                            return group:get_wrap()
                        end
                    )

                    if ok then
                        previous_sheet_wrap = wrap
                    else
                        previous_sheet_wrap = true
                    end
                end

                pcall(
                    function()
                        group:set_wrap(false)
                    end
                )

                remove_from_group(menu_hitbox)
                remove_from_group(dimmer)
                remove_sheet_buttons()

                return group
            end

            local function activate_sheet_buttons(
                buttons,
                initial_button
            )
                local group = prepare_sheet_focus()

                if not group then
                    return
                end

                for _, button in ipairs(
                    buttons
                ) do
                    add_to_group(group, button)
                end

                active_sheet_button_count =
                    #buttons

                focus_object(
                    initial_button or
                    buttons[1]
                )
            end

            local function restore_player_focus()
                local group =
                    sheet_group or
                    lvgl.group.get_default()

                remove_sheet_buttons()
                remove_from_group(dimmer)
                remove_from_group(menu_hitbox)

                if group then
                    add_to_group(
                        group,
                        menu_hitbox
                    )

                    if previous_sheet_wrap ~= nil then
                        pcall(
                            function()
                                group:set_wrap(
                                    previous_sheet_wrap
                                )
                            end
                        )
                    end
                end

                sheet_group = nil
                previous_sheet_wrap = nil

                focus_object(menu_hitbox)
            end

            self.release_sheet_focus =
                restore_player_focus

            self.sheet_focus_state =
                function()
                    return {
                        page = self.sheet_page,
                        main_count = #main_buttons,
                        playlist_count =
                            #playlist_buttons,
                        active_count =
                            active_sheet_button_count,
                        wrap_disabled =
                            sheet_group ~= nil,
                    }
                end

            local function finish_close()
                overlay:add_flag(
                    lvgl.FLAG.HIDDEN
                )

                main_sheet:clear_flag(
                    lvgl.FLAG.HIDDEN
                )

                playlist_sheet:add_flag(
                    lvgl.FLAG.HIDDEN
                )

                main_sheet:set {
                    y = 128,
                }

                playlist_sheet:set {
                    y = 128,
                }

                self.sheet_open = false
                self.sheet_animating = false
                self.sheet_page = "main"

                restore_player_focus()
            end

            self.close_sheet =
                function()
                    if not self.sheet_open or
                        self.sheet_animating then
                        return
                    end

                    self.sheet_animating = true
                    prepare_sheet_focus()

                    local current_sheet =
                        self.sheet_page ==
                            "playlists" and
                        playlist_sheet or
                        main_sheet

                    local current_y =
                        self.sheet_page ==
                            "playlists" and
                        playlist_target_y or
                        main_target_y

                    animate_y(
                        current_sheet,
                        current_y,
                        128,
                        finish_close
                    )
                end

            local function close_soon()
                lvgl.Timer {
                    period = 350,
                    repeat_count = 1,
                    cb = function()
                        self.close_sheet()
                    end,
                }
            end

            local function queue_favorite()
                local operation,
                    operation_error =
                    sync_operation_queue
                        .enqueue_set_favorite(
                            track.id,
                            not favorite
                        )

                if not operation then
                    favorite_button:set {
                        text =
                            operation_error or
                            "Unable to queue change",
                    }

                    return
                end

                favorite = not favorite

                favorite_button:set {
                    text =
                        favorite and
                        "Remove favorite" or
                        "Add favorite",
                }

                close_soon()
            end

            favorite_button =
                add_sheet_button(
                    main_list,
                    favorite and
                        "Remove favorite" or
                        "Add favorite",
                    queue_favorite
                )
            table.insert(
                main_buttons,
                favorite_button
            )

            local playlist_back

            local function show_playlists()
                if self.sheet_animating then
                    return
                end

                self.sheet_animating = true
                prepare_sheet_focus()

                animate_y(
                    main_sheet,
                    main_target_y,
                    128,
                    function()
                        main_sheet:add_flag(
                            lvgl.FLAG.HIDDEN
                        )

                        playlist_sheet
                            :clear_flag(
                                lvgl.FLAG.HIDDEN
                            )

                        self.sheet_page =
                            "playlists"
                        self.sheet_animating =
                            false

                        animate_y(
                            playlist_sheet,
                            128,
                            playlist_target_y,
                            function()
                                activate_sheet_buttons(
                                    playlist_buttons,
                                    playlist_back
                                )
                            end
                        )
                    end
                )
            end

            local add_playlist_button =
                add_sheet_button(
                    main_list,
                    "Add to playlist",
                    show_playlists
                )
            table.insert(
                main_buttons,
                add_playlist_button
            )

            if context.collection_kind ==
                "playlist" then
                local remove_button

                remove_button =
                    add_sheet_button(
                        main_list,
                        "Remove from playlist",
                        function()
                            local entry_id =
                                context.entry_id

                            if type(entry_id) ~=
                                    "string" or
                                entry_id == "" or
                                entry_id:match(
                                    "^local%-entry:"
                                ) then
                                remove_button:set {
                                    text =
                                        "Waiting for sync",
                                }

                                return
                            end

                            local operation,
                                operation_error =
                                sync_operation_queue
                                    .enqueue_remove_playlist_item(
                                        context
                                            .collection_id,
                                        entry_id
                                    )

                            if not operation then
                                remove_button:set {
                                    text =
                                        operation_error or
                                        "Unable to remove",
                                }

                                return
                            end

                            close_soon()
                        end
                    )
                table.insert(
                    main_buttons,
                    remove_button
                )
            end

            playlist_back =
                add_sheet_button(
                    playlist_list,
                    "Back",
                    function()
                        if self.sheet_animating then
                            return
                        end

                        self.sheet_animating = true
                        prepare_sheet_focus()

                        animate_y(
                            playlist_sheet,
                            playlist_target_y,
                            128,
                            function()
                                playlist_sheet
                                    :add_flag(
                                        lvgl.FLAG.HIDDEN
                                    )

                                main_sheet
                                    :clear_flag(
                                        lvgl.FLAG.HIDDEN
                                    )

                                self.sheet_page =
                                    "main"
                                self.sheet_animating =
                                    false

                                animate_y(
                                    main_sheet,
                                    128,
                                    main_target_y,
                                    function()
                                        activate_sheet_buttons(
                                            main_buttons,
                                            favorite_button
                                        )
                                    end
                                )
                            end
                        )
                    end
                )
            table.insert(
                playlist_buttons,
                playlist_back
            )

            if library then
                for _, playlist in ipairs(
                    library.playlists or {}
                ) do
                    local playlist_copy =
                        playlist

                    local playlist_button =
                        add_sheet_button(
                            playlist_list,
                            playlist_copy.name or
                                "Playlist",
                            function()
                            local playlist_id =
                                playlist_copy
                                    .local_id or
                                playlist_copy.id

                            local operation,
                                operation_error =
                                sync_operation_queue
                                    .enqueue_add_playlist_item(
                                        playlist_id,
                                        track.id
                                    )

                            if not operation then
                                playlist_title:set {
                                    text =
                                        operation_error or
                                        "Unable to queue add",
                                }

                                return
                            end

                            playlist_title:set {
                                text =
                                    "Added to " ..
                                    (
                                        playlist_copy
                                            .name or
                                        "playlist"
                                    ),
                            }

                                close_soon()
                            end
                        )
                    table.insert(
                        playlist_buttons,
                        playlist_button
                    )
                end
            end

            remove_from_group(dimmer)
            remove_sheet_buttons()

            self.open_sheet =
                function()
                    if self.sheet_open or
                        self.sheet_animating then
                        return
                    end

                    self.sheet_open = true
                    self.sheet_page = "main"

                    playlist_title:set {
                        text = "Add to playlist",
                    }

                    playlist_sheet:add_flag(
                        lvgl.FLAG.HIDDEN
                    )

                    main_sheet:clear_flag(
                        lvgl.FLAG.HIDDEN
                    )

                    overlay:clear_flag(
                        lvgl.FLAG.HIDDEN
                    )

                    self.sheet_animating = true
                    prepare_sheet_focus()

                    animate_y(
                        main_sheet,
                        128,
                        main_target_y,
                        function()
                            self.sheet_animating =
                                false
                            activate_sheet_buttons(
                                main_buttons,
                                favorite_button
                            )
                        end
                    )
                end

            self.toggle_sheet =
                function()
                    if self.sheet_open then
                        self.close_sheet()
                    else
                        self.open_sheet()
                    end
                end

            self.handle_back =
                function()
                    if self.sheet_open then
                        self.close_sheet()
                    else
                        self.go_back()
                    end
                end

            local suppress_player_click =
                false

            dimmer:onClicked(
                self.close_sheet
            )

            menu_hitbox:onevent(
                lvgl.EVENT.LONG_PRESSED,
                function()
                    suppress_player_click =
                        true
                    self.open_sheet()

                    lvgl.Timer {
                        period = 1000,
                        repeat_count = 1,
                        cb = function()
                            suppress_player_click =
                                false
                        end,
                    }
                end
            )

            menu_hitbox:onClicked(
                function()
                    if suppress_player_click then
                        suppress_player_click =
                            false
                        return
                    end

                    playback.playing:set(
                        not playback.playing:get()
                    )
                end
            )

            self.playing_binding =
                playback.playing:bind(
                    function(playing)
                        self.view:update {
                            paused =
                                playing ~= true,
                        }
                    end
                )

            self.position_binding =
                playback.position:bind(
                    function(position)
                        local current =
                            jellyfin_playback
                                .current()

                        local current_track =
                            current and
                            current.track or {}

                        local current_duration =
                            tonumber(
                                current_track
                                    .duration
                            )
                            or duration

                        local progress = 0

                        if current_duration >
                                0 then
                            progress =
                                math.max(
                                    0,
                                    math.min(
                                        1,
                                        (
                                            position
                                            or 0
                                        ) /
                                        current_duration
                                    )
                                )
                        end

                        self.view:update {
                            progress =
                                progress,
                            elapsed =
                                format_time(
                                    position
                                ),
                            remaining =
                                format_time(
                                    math.max(
                                        0,
                                        current_duration -
                                        (
                                            position
                                            or 0
                                        )
                                    )
                                ),
                        }
                    end
                )

            self.battery_binding =
                power.battery_pct:bind(
                    function(percentage)
                        self.view:update {
                            battery_pct =
                                percentage,
                        }
                    end
                )

            self.charge_binding =
                power.charge_state:bind(
                    function()
                        self.view:update {
                            charging =
                                charging_state(),
                        }
                    end
                )

            self.plugged_binding =
                power.plugged_in:bind(
                    function()
                        self.view:update {
                            charging =
                                charging_state(),
                        }
                    end
                )

            self.status_timer =
                lvgl.Timer {
                    period = 1000,
                    cb = function()
                        self.view:update {
                            clock =
                                current_clock(),
                            connected =
                                server_connected(
                                    jellyfin_playback
                                        .current()
                                ),
                        }
                    end,
                }
        end,

        on_show = function(self)
            jellyfin_navigation.set_back(
                self.handle_back
            )

            if self.menu_hitbox then
                lvgl.group.focus_obj(
                    self.menu_hitbox
                )
            end

            local hooks =
                controls.hooks()

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
                    input_method.up
                        .long_press

                input_method.up
                    .long_press =
                    self.handle_back
            end

            if input_method.center then
                self.previous_center_long =
                    input_method.center
                        .long_press

                input_method.center
                    .long_press =
                    self.toggle_sheet
            end
        end,

        on_hide = function(self)
            jellyfin_navigation.clear_back(
                self.handle_back
            )

            if self.release_sheet_focus then
                self.release_sheet_focus()
            end

            local input_method =
                self.input_method

            if not input_method then
                return
            end

            if input_method.up and
                input_method.up
                    .long_press ==
                    self.handle_back then
                input_method.up
                    .long_press =
                    self.previous_up_long
            end

            if input_method.center and
                input_method.center
                    .long_press ==
                    self.toggle_sheet then
                input_method.center
                    .long_press =
                    self.previous_center_long
            end

            self.input_method = nil
        end,
    }

return NowPlaying

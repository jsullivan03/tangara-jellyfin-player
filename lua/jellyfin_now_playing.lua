local lvgl = require("lvgl")
local backstack = require("backstack")
local controls = require("controls")
local jellyfin_navigation =
    require("jellyfin_navigation")
local jellyfin_playback =
    require("jellyfin_playback")
local jellyfin_track_actions =
    require("jellyfin_track_actions")
local jellyfin_text_entry =
    require("jellyfin_text_entry")
local playback = require("playback")
local power = require("power")
local queue = require("queue")
local premium =
    require("premium_now_playing_screen")
local screen = require("screen")
local sync_config = require("sync_config")
local sync_library_view =
    require("sync_library_view")
local sync_operation_queue =
    require("sync_operation_queue")
local sync_runtime = require("sync_runtime")
local volume = require("volume")

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

local function set_sim_transport_mode(enabled)
    local callback =
        rawget(
            _G,
            "tangara_sim_set_transport_mode"
        )

    if type(callback) == "function" then
        pcall(callback, enabled == true)
    end
end

local function usable_artwork(value)
    return type(value) == "string" and
        value ~= "" and
        value ~=
            "//lua/img/cover_placeholder.png" and
        value ~=
            "//lua/img/background_placeholder.png"
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

    local candidates

    if name == "background" then
        candidates = {
            {item_artwork, "background"},
            {track_artwork, "background"},
            {item_artwork, "cover"},
            {track_artwork, "cover"},
            {item_artwork, "thumbnail"},
            {track_artwork, "thumbnail"},
            {track_artwork,
                "album_thumbnail"},
        }
    else
        candidates = {
            {item_artwork, "cover"},
            {track_artwork, "cover"},
            {item_artwork, "thumbnail"},
            {track_artwork, "thumbnail"},
            {track_artwork,
                "album_thumbnail"},
            {track_artwork,
                "playlist_thumbnail"},
        }
    end

    for _, candidate in ipairs(
        candidates
    ) do
        local artwork = candidate[1]
        local key = candidate[2]
        local value =
            type(artwork) == "table" and
            artwork[key] or nil

        if usable_artwork(value) then
            return value
        end
    end

    -- A placeholder is still preferable to a missing source, but only after
    -- checking every real per-track artwork alias above.
    for _, artwork in ipairs({
        item_artwork,
        track_artwork,
    }) do
        if type(artwork) == "table" then
            local value = artwork[name]

            if type(value) == "string" and
                value ~= "" then
                return value
            end
        end
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

            -- Encoder rotation normally changes LVGL focus. Keep two tiny,
            -- transparent sentinels around the player hitbox so a physical
            -- wheel tick can be converted into a seek step, then immediately
            -- return focus to the player. The desktop simulator filters its
            -- transport events before LVGL sees them, so the same controls do
            -- not fire twice there.
            local seek_back_focus =
                self.root:Button {
                    x = 0,
                    y = 13,
                    w = 1,
                    h = 1,
                    pad_all = 0,
                    border_width = 0,
                    outline_width = 0,
                    shadow_width = 0,
                    radius = 0,
                    bg_opa = 0,
                }

            local seek_forward_focus =
                self.root:Button {
                    x = 159,
                    y = 13,
                    w = 1,
                    h = 1,
                    pad_all = 0,
                    border_width = 0,
                    outline_width = 0,
                    shadow_width = 0,
                    radius = 0,
                    bg_opa = 0,
                }

            self.seek_back_focus =
                seek_back_focus
            self.seek_forward_focus =
                seek_forward_focus

            remove_from_group(
                seek_back_focus
            )
            remove_from_group(
                seek_forward_focus
            )

            seek_back_focus:onevent(
                lvgl.EVENT.FOCUSED,
                function()
                    if self.transport_active and
                        not self.installing_player_focus and
                        not self.sheet_open and
                        self.seek_by then
                        self.seek_by(-1)
                    end

                    focus_object(menu_hitbox)
                end
            )

            seek_forward_focus:onevent(
                lvgl.EVENT.FOCUSED,
                function()
                    if self.transport_active and
                        not self.installing_player_focus and
                        not self.sheet_open and
                        self.seek_by then
                        self.seek_by(1)
                    end

                    focus_object(menu_hitbox)
                end
            )

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

            local main_height = 34
            local main_target_y = 94

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
                    lvgl.SCROLLBAR_MODE.AUTO,
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

            local playlist_header_visible = false

            local library =
                sync_library_view.current()

            local favorite =
                jellyfin_track_actions
                    .favorite_state(
                        library,
                        track.id
                    )

            local favorite_button
            local remove_button
            local main_buttons = {}
            local main_action_ids = {}
            local main_actions_by_id = {}
            local main_initial_button
            local rebuild_main_actions
            local playlist_buttons = {}
            local playlist_labels = {}
            local playlist_activators = {}
            local playlist_initial_button
            local create_playlist_button
            local playlist_initial_scroll_y = 0
            local sheet_group = nil
            local previous_sheet_wrap = nil
            local active_sheet_button_count = 0
            local highlighted_sheet_button = nil

            local function refresh_sheet_highlight(
                focused_button
            )
                highlighted_sheet_button =
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
                    main_buttons
                ) do
                    update(button)
                end

                for _, button in ipairs(
                    playlist_buttons
                ) do
                    update(button)
                end
            end

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
                refresh_sheet_highlight(nil)
            end

            local function install_player_focus(
                group
            )
                group =
                    group or
                    lvgl.group.get_default()

                if not group then
                    return
                end

                self.installing_player_focus = true

                remove_from_group(
                    seek_back_focus
                )
                remove_from_group(
                    menu_hitbox
                )
                remove_from_group(
                    seek_forward_focus
                )

                add_to_group(
                    group,
                    seek_back_focus
                )
                add_to_group(
                    group,
                    menu_hitbox
                )
                add_to_group(
                    group,
                    seek_forward_focus
                )

                focus_object(menu_hitbox)
                self.installing_player_focus = false
            end

            self.install_player_focus =
                install_player_focus

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

                remove_from_group(
                    seek_back_focus
                )
                remove_from_group(menu_hitbox)
                remove_from_group(
                    seek_forward_focus
                )
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

            local function add_playlist_scroll_spacer(
                list,
                button_count
            )
                local button_height = 15
                local viewport_height = 68
                local required_content_height =
                    viewport_height + button_height
                local spacer_height =
                    required_content_height -
                    (button_count * button_height)

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
                spacer:clear_flag(
                    lvgl.FLAG.CLICKABLE
                )
                remove_from_group(spacer)

                return spacer
            end

            local function position_playlist_chooser()
                local scroll_y = 0

                if #playlist_buttons > 1 then
                    scroll_y = 15
                end

                playlist_initial_scroll_y =
                    scroll_y

                local function apply_scroll()
                    pcall(function()
                        playlist_list:scroll_to {
                            x = 0,
                            y = scroll_y,
                            anim = false,
                        }
                    end)
                end

                apply_scroll()
                lvgl.Timer {
                    period = 1,
                    repeat_count = 1,
                    cb = apply_scroll,
                }
            end

            local function restore_player_focus()
                local group =
                    sheet_group or
                    lvgl.group.get_default()

                remove_sheet_buttons()
                remove_from_group(dimmer)

                if group and
                    previous_sheet_wrap ~= nil then
                    pcall(
                        function()
                            group:set_wrap(
                                previous_sheet_wrap
                            )
                        end
                    )
                end

                sheet_group = nil
                previous_sheet_wrap = nil

                install_player_focus(group)
            end

            self.release_sheet_focus =
                restore_player_focus

            self.activate_sheet_action =
                function(action_id)
                    local callback =
                        main_actions_by_id[
                            action_id
                        ]

                    if type(callback) ~= "function" then
                        return false
                    end

                    callback()
                    return true
                end

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
                        main_actions =
                            main_action_ids,
                        playlist_labels =
                            playlist_labels,
                        playlist_header_visible =
                            playlist_header_visible,
                        playlist_initial_scroll_y =
                            playlist_initial_scroll_y,
                        playlist_create_hidden_on_open =
                            playlist_initial_scroll_y >= 15,
                        playlist_initial_label =
                            (function()
                                for index, button in ipairs(
                                    playlist_buttons
                                ) do
                                    if button ==
                                            playlist_initial_button then
                                        return playlist_labels[index]
                                    end
                                end

                                return nil
                            end)(),
                        highlighted_action =
                            (function()
                                for index, button in ipairs(
                                    main_buttons
                                ) do
                                    if button ==
                                            highlighted_sheet_button then
                                        return main_action_ids[
                                            index
                                        ]
                                    end
                                end

                                return nil
                            end)(),
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
                set_sim_transport_mode(
                    self.transport_active
                )
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

            local function shuffle_enabled()
                return
                    queue.random and
                    type(queue.random.get) ==
                        "function" and
                    queue.random:get() == true or
                    false
            end

            local function toggle_shuffle()
                if not queue.random or
                    type(queue.random.set) ~=
                        "function" then
                    return
                end

                queue.random:set(
                    not shuffle_enabled()
                )
                close_soon()
            end

            local function open_queue()
                finish_close()

                backstack.push(
                    require(
                        "jellyfin_queue"
                    ):new()
                )
            end

            local function open_artist(
                artist
            )
                artist =
                    artist or
                    jellyfin_track_actions
                        .artist_target(
                            track,
                            active and
                            active.item
                        )

                if not artist then
                    return
                end

                finish_close()

                local local_library =
                    require(
                        "jellyfin_local_library"
                    )

                backstack.push(
                    local_library.Artist:new {
                        title =
                            artist.name or
                            "Artist",
                        artist_key =
                            artist.key,
                    }
                )
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
                    if favorite_button then
                        favorite_button:set {
                            text =
                                operation_error or
                                "Unable to queue change",
                        }
                    end

                    return
                end

                favorite = not favorite

                if favorite_button then
                    favorite_button:set {
                        text =
                            favorite and
                            "Remove favorite" or
                            "Add favorite",
                    }
                end

                close_soon()
            end

            local function remove_from_playlist()
                local entry_id =
                    context.entry_id

                if type(entry_id) ~= "string" or
                    entry_id == "" or
                    entry_id:match(
                        "^local%-entry:"
                    ) then
                    if remove_button then
                        remove_button:set {
                            text =
                                "Waiting for sync",
                        }
                    end

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
                    if remove_button then
                        remove_button:set {
                            text =
                                operation_error or
                                "Unable to remove",
                        }
                    end

                    return
                end

                close_soon()
            end

            self.seek_generation = 0
            self.seek_pending = false
            self.seek_target = nil
            self.transport_active = false

            local function current_duration()
                return
                    tonumber(track.duration)
                    or tonumber(
                        active and
                        active.item and
                        active.item.duration
                    )
                    or 0
            end

            local function update_position_view(
                position
            )
                position =
                    math.max(
                        0,
                        tonumber(position) or 0
                    )

                local next_duration =
                    current_duration()
                local progress = 0

                if next_duration > 0 then
                    progress =
                        math.max(
                            0,
                            math.min(
                                1,
                                position /
                                    next_duration
                            )
                        )
                end

                self.view:update {
                    progress = progress,
                    elapsed =
                        format_time(position),
                    remaining =
                        format_time(
                            next_duration
                        ),
                }
            end

            self.refresh_active =
                function(next_active)
                    local previous_track_id =
                        track and track.id

                    active =
                        next_active or
                        jellyfin_playback
                            .current()

                    track =
                        active and
                        active.track or {}
                    context =
                        active and
                        active.context or {}
                    duration =
                        current_duration()

                    favorite =
                        jellyfin_track_actions
                            .favorite_state(
                                library,
                                track.id
                            )

                    if rebuild_main_actions then
                        rebuild_main_actions()
                    elseif favorite_button then
                        favorite_button:set {
                            text =
                                favorite and
                                "Remove favorite" or
                                "Add favorite",
                        }
                    end

                    self.seek_generation =
                        self.seek_generation + 1
                    self.seek_pending = false
                    self.seek_target = nil

                    self.view:update {
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
                        connected =
                            server_connected(
                                active
                            ),
                    }

                    local position =
                        playback.position:get() or 0

                    if previous_track_id ~= nil and
                        track.id ~= previous_track_id then
                        position = 0
                    end

                    update_position_view(position)
                end

            self.seek_by =
                function(step_count)
                    if self.sheet_open or
                        self.sheet_animating or
                        not self.transport_active then
                        return false
                    end

                    step_count =
                        tonumber(step_count) or 0

                    if step_count == 0 then
                        return false
                    end

                    local next_duration =
                        current_duration()

                    if next_duration <= 0 then
                        return false
                    end

                    local base =
                        self.seek_pending and
                        self.seek_target or
                        playback.position:get() or 0

                    self.seek_target =
                        math.max(
                            0,
                            math.min(
                                next_duration,
                                base +
                                    step_count * 5
                            )
                        )
                    self.seek_pending = true
                    self.seek_generation =
                        self.seek_generation + 1

                    local generation =
                        self.seek_generation

                    update_position_view(
                        self.seek_target
                    )

                    lvgl.Timer {
                        period = 300,
                        repeat_count = 1,
                        cb = function()
                            if generation ~=
                                    self.seek_generation or
                                not self.seek_pending then
                                return
                            end

                            local target =
                                self.seek_target

                            self.seek_pending = false
                            self.seek_target = nil

                            playback.position:set(
                                math.floor(
                                    target or 0
                                )
                            )
                        end,
                    }

                    return true
                end

            self.previous_track =
                function(count)
                    if self.sheet_open or
                        self.sheet_animating then
                        return false
                    end

                    count = math.max(
                        1,
                        math.floor(
                            tonumber(count) or 1
                        )
                    )

                    for _ = 1, count do
                        jellyfin_playback.previous()
                    end

                    return true
                end

            self.next_track =
                function(count)
                    if self.sheet_open or
                        self.sheet_animating then
                        return false
                    end

                    count = math.max(
                        1,
                        math.floor(
                            tonumber(count) or 1
                        )
                    )

                    for _ = 1, count do
                        jellyfin_playback.next()
                    end

                    return true
                end

            self.transport =
                function(action, amount)
                    if action == "seek" then
                        return self.seek_by(
                            amount
                        )
                    elseif action ==
                            "previous" then
                        return self.previous_track(
                            amount
                        )
                    elseif action == "next" then
                        return self.next_track(
                            amount
                        )
                    elseif action == "toggle" then
                        if self.sheet_open or
                            self.sheet_animating then
                            return false
                        end

                        playback.playing:set(
                            not playback.playing:get()
                        )
                        return true
                    elseif action ==
                            "volume_up" or
                        action ==
                            "volume_down" then
                        if self.sheet_open or
                            self.sheet_animating then
                            return false
                        end

                        local direction =
                            action ==
                                "volume_up" and
                            1 or -1
                        local count =
                            math.max(
                                1,
                                math.abs(
                                    tonumber(amount) or
                                    1
                                )
                            )
                        local percentage =
                            tonumber(
                                volume.current_pct
                                    :get()
                            ) or 0

                        volume.current_pct:set(
                            math.max(
                                0,
                                math.min(
                                    100,
                                    percentage +
                                        direction *
                                        count * 5
                                )
                            )
                        )

                        return true
                    end

                    return false
                end

            self.transport_state =
                function()
                    return {
                        active =
                            self.transport_active ==
                            true,
                        seek_pending =
                            self.seek_pending == true,
                        seek_target =
                            self.seek_target,
                        queue_position =
                            queue.position:get(),
                        queue_size =
                            queue.size:get(),
                    }
                end

            local function show_main_sheet()
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
                        playlist_sheet:add_flag(
                            lvgl.FLAG.HIDDEN
                        )

                        main_sheet:clear_flag(
                            lvgl.FLAG.HIDDEN
                        )

                        self.sheet_page = "main"
                        self.sheet_animating = false

                        animate_y(
                            main_sheet,
                            128,
                            main_target_y,
                            function()
                                activate_sheet_buttons(
                                    main_buttons,
                                    main_initial_button
                                )
                            end
                        )
                    end
                )
            end

            local function show_playlists()
                if self.sheet_animating then
                    return
                end

                playlist_title:add_flag(
                    lvgl.FLAG.HIDDEN
                )
                playlist_list:clear_flag(
                    lvgl.FLAG.HIDDEN
                )
                playlist_header_visible = false
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
                                    playlist_initial_button or
                                        playlist_buttons[1]
                                )
                                position_playlist_chooser()
                            end
                        )
                    end
                )
            end

            rebuild_main_actions =
                function()
                    for _, button in ipairs(
                        main_buttons
                    ) do
                        remove_from_group(button)
                    end

                    if self.sheet_page == "main" then
                        active_sheet_button_count = 0
                    end

                    main_list:clean()

                    main_buttons = {}
                    main_action_ids = {}
                    main_actions_by_id = {}
                    main_initial_button = nil
                    favorite_button = nil
                    remove_button = nil

                    local actions =
                        jellyfin_track_actions.main {
                            track = track,
                            item =
                                active and
                                active.item,
                            context = context,
                            favorite = favorite,
                            shuffle =
                                shuffle_enabled(),
                            handlers = {
                                open_queue =
                                    open_queue,
                                toggle_shuffle =
                                    toggle_shuffle,
                                open_artist =
                                    open_artist,
                                toggle_favorite =
                                    queue_favorite,
                                show_playlists =
                                    show_playlists,
                                remove_from_playlist =
                                    remove_from_playlist,
                            },
                        }

                    for _, action in ipairs(
                        actions
                    ) do
                        local button =
                            add_sheet_button(
                                main_list,
                                action.label,
                                action.activate,
                                refresh_sheet_highlight
                            )

                        table.insert(
                            main_buttons,
                            button
                        )
                        table.insert(
                            main_action_ids,
                            action.id
                        )
                        main_actions_by_id[
                            action.id
                        ] = action.activate

                        if not main_initial_button then
                            main_initial_button =
                                button
                        end

                        if action.id == "favorite" then
                            favorite_button =
                                button
                        elseif action.id ==
                                "remove_from_playlist" then
                            remove_button =
                                button
                        end
                    end

                    local content_height =
                        #main_buttons * 15

                    main_height =
                        math.min(
                            109,
                            content_height + 4
                        )
                    main_target_y =
                        128 - main_height

                    main_sheet:set {
                        h = main_height,
                    }
                    main_list:set {
                        h = main_height - 4,
                    }

                    if self.sheet_open and
                        self.sheet_page == "main" and
                        not self.sheet_animating then
                        main_sheet:set {
                            y = main_target_y,
                        }
                    end
                end

            local function register_playlist_button(
                label,
                button,
                activate
            )
                table.insert(
                    playlist_buttons,
                    button
                )
                table.insert(
                    playlist_labels,
                    label
                )
                table.insert(
                    playlist_activators,
                    activate
                )
            end

            local create_playlist_action =
                function()
                    local track_id =
                        track and track.id

                    finish_close()

                    backstack.push(
                        jellyfin_text_entry.new {
                            title = "New playlist",
                            on_submit = function(name)
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

            create_playlist_button =
                add_sheet_button(
                    playlist_list,
                    "Create playlist",
                    create_playlist_action,
                    refresh_sheet_highlight
                )

            register_playlist_button(
                "Create playlist",
                create_playlist_button,
                create_playlist_action
            )

            if library then
                for _, playlist in ipairs(
                    library.playlists or {}
                ) do
                    local playlist_copy =
                        playlist

                    local playlist_action =
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
                                playlist_list:add_flag(
                                    lvgl.FLAG.HIDDEN
                                )
                                playlist_title:set {
                                    text =
                                        operation_error or
                                        "Unable to queue add",
                                }
                                playlist_title:clear_flag(
                                    lvgl.FLAG.HIDDEN
                                )
                                playlist_header_visible = true
                                return
                            end

                            close_soon()
                        end

                    local label =
                        playlist_copy.name or
                        "Playlist"
                    local playlist_button =
                        add_sheet_button(
                            playlist_list,
                            label,
                            playlist_action,
                            refresh_sheet_highlight
                        )

                    register_playlist_button(
                        label,
                        playlist_button,
                        playlist_action
                    )

                end
            end

            playlist_initial_button =
                playlist_buttons[2] or
                playlist_buttons[1]

            local playlist_scroll_spacer =
                add_playlist_scroll_spacer(
                    playlist_list,
                    #playlist_buttons
                )

            self.activate_playlist_action =
                function(label)
                    for index, candidate in ipairs(
                        playlist_labels
                    ) do
                        if candidate == label then
                            playlist_activators[index]()
                            return true
                        end
                    end

                    return false
                end

            remove_from_group(dimmer)
            remove_sheet_buttons()

            self.open_sheet =
                function()
                    if self.sheet_open or
                        self.sheet_animating then
                        return
                    end

                    rebuild_main_actions()

                    self.sheet_open = true
                    self.sheet_page = "main"
                    set_sim_transport_mode(false)

                    playlist_title:add_flag(
                        lvgl.FLAG.HIDDEN
                    )
                    playlist_list:clear_flag(
                        lvgl.FLAG.HIDDEN
                    )
                    playlist_header_visible = false
                    playlist_initial_scroll_y = 0

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
                                main_initial_button
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
                        if self.sheet_page ==
                                "playlists" then
                            show_main_sheet()
                        else
                            self.close_sheet()
                        end
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

                    self.transport(
                        "toggle"
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
                        if self.seek_pending then
                            return
                        end

                        update_position_view(
                            position
                        )
                    end
                )

            self.queue_binding =
                queue.position:bind(
                    function(position)
                        local next_active =
                            jellyfin_playback
                                .sync_position(
                                    position
                                )

                        if next_active then
                            self.refresh_active(
                                next_active
                            )
                        end
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
            self.transport_active = true

            if self.view and
                self.view.refresh_media_layout then
                self.view:refresh_media_layout()
            end

            jellyfin_navigation.set_back(
                self.handle_back
            )

            if self.install_player_focus then
                self.install_player_focus()
            elseif self.menu_hitbox then
                lvgl.group.focus_obj(
                    self.menu_hitbox
                )
            end

            self.sim_transport_handler =
                function(action, amount)
                    return self.transport(
                        action,
                        amount
                    )
                end

            _G.tangara_sim_transport_event =
                self.sim_transport_handler

            set_sim_transport_mode(
                not self.sheet_open
            )

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

            if input_method.left then
                self.previous_left_click =
                    input_method.left.click
                input_method.left.click =
                    self.previous_track
            end

            if input_method.right then
                self.previous_right_click =
                    input_method.right.click
                input_method.right.click =
                    self.next_track
            end
        end,

        on_hide = function(self)
            self.transport_active = false
            self.seek_generation =
                (self.seek_generation or 0) + 1
            self.seek_pending = false
            self.seek_target = nil

            set_sim_transport_mode(false)

            if _G.tangara_sim_transport_event ==
                    self.sim_transport_handler then
                _G.tangara_sim_transport_event =
                    nil
            end

            self.sim_transport_handler = nil

            jellyfin_navigation.clear_back(
                self.handle_back
            )

            if self.release_sheet_focus then
                self.release_sheet_focus()
            end

            remove_from_group(
                self.seek_back_focus
            )
            remove_from_group(
                self.menu_hitbox
            )
            remove_from_group(
                self.seek_forward_focus
            )

            local input_method =
                self.input_method

            if input_method then
                if input_method.up then
                    input_method.up
                        .long_press =
                        self.previous_up_long
                end

                if input_method.center then
                    input_method.center
                        .long_press =
                        self.previous_center_long
                end

                if input_method.left then
                    input_method.left.click =
                        self.previous_left_click
                end

                if input_method.right then
                    input_method.right.click =
                        self.previous_right_click
                end
            end

            self.input_method = nil
        end,
    }

return NowPlaying

local backstack = require("backstack")
local device = require("device")
local jellyfin_collection_playback =
    require("jellyfin_collection_playback")
local jellyfin_list_ui =
    require("jellyfin_list_ui")
local jellyfin_mini_player =
    require("jellyfin_mini_player")
local jellyfin_now_playing =
    require("jellyfin_now_playing")
local jellyfin_playback =
    require("jellyfin_playback")
local jellyfin_playlist_action_sheet =
    require("jellyfin_playlist_action_sheet")
local jellyfin_text_entry =
    require("jellyfin_text_entry")
local jellyfin_local_index =
    require("jellyfin_local_index")
local jellyfin_sort =
    require("jellyfin_sort")
local jellyfin_track_action_sheet =
    require("jellyfin_track_action_sheet")
local jellyfin_virtual_track_list =
    require("jellyfin_virtual_track_list")
local jellyfin_track_identity =
    require("jellyfin_track_identity")
local jellyfin_playback_session =
    require("jellyfin_playback_session")
local lvgl = require("lvgl")
local screen = require("screen")
local sync_library_view =
    require("sync_library_view")
local sync_operation_queue =
    require("sync_operation_queue")
local sync_runtime = require("sync_runtime")

local LibraryScreen
local CollectionScreen
local function playable_tracks(items)
    local result = {}

    for _, track in ipairs(items or {}) do
        if jellyfin_playback.local_item(track) then
            result[#result + 1] = track
        end
    end

    return result
end

local active_local_screen = nil
local local_poll_timer = nil

local function runtime_generation()
    if type(sync_runtime.state_generation) ==
            "function" then
        return sync_runtime.state_generation()
    end

    return 0
end

local function poll_local_screen()
    local self = active_local_screen

    if not self or not self.ui_active then
        return
    end

    local generation = runtime_generation()

    if generation ==
        (self.download_state_generation or -1) then
        return
    end

    self.download_state_generation = generation

    if type(self.refresh_download_state) ==
            "function" then
        self:refresh_download_state()
    end
end

local function ensure_local_poll_timer()
    if local_poll_timer then
        return
    end

    local_poll_timer = lvgl.Timer {
        period = 250,
        cb = poll_local_screen,
    }
end

local function create_local_root(
    self,
    title
)
    jellyfin_list_ui.create_root(
        self,
        title
    )
    jellyfin_mini_player.attach(self)
end

local function local_on_show(self)
    active_local_screen = self
    ensure_local_poll_timer()

    local previous_generation =
        self.download_state_generation
    local generation = runtime_generation()
    local should_refresh =
        previous_generation ~= nil and
        previous_generation ~= generation

    self.download_state_generation =
        generation

    -- A newly started session can make the mini-player appear for the first
    -- time while returning from Now Playing. Reserve its list space before
    -- restoring the pooled viewport and focus, otherwise resizing afterward
    -- can rebind the focused row object to the adjacent logical track.
    if self.mini_player then
        self.mini_player:refresh()
    end

    -- Playlist/Favorites track lists must re-select the user's track before
    -- install_controls / schedule_resume_repaint. Play-button entry leaves
    -- selected_item_id=control:play otherwise and wipes track chrome.
    if self.virtual_track_list and
        type(
            jellyfin_playback_session
                .restore_track_list_resume
        ) == "function" then
        jellyfin_playback_session
            .restore_track_list_resume(self)

        if self.track_list_resume or
            self.album_track_resume then
            local snapshot =
                self.track_list_resume or
                self.album_track_resume
            local track_key =
                snapshot.track_key or
                snapshot.track_id
            local lock_generation =
                (
                    self.track_list_resume_lock_generation or
                    0
                ) + 1

            self.track_list_resume_lock_generation =
                lock_generation
            self.discography_selection_lock =
                track_key
            self.selected_item_id = track_key

            if type(
                self.selection_object_for_id
            ) == "function" then
                local object =
                    self.selection_object_for_id(
                        track_key
                    )

                if object then
                    self.initial_focus_object =
                        object
                    self.first_row = object
                end
            end

            lvgl.Timer {
                period = 1,
                repeat_count = 1,
                cb = function()
                    if self.track_list_resume_lock_generation ~=
                            lock_generation then
                        return
                    end

                    if type(
                        jellyfin_playback_session
                            .clear_track_list_resume_lock
                    ) == "function" then
                        jellyfin_playback_session
                            .clear_track_list_resume_lock(
                                self
                            )
                    end
                end,
            }
        end
    end

    jellyfin_list_ui.install_controls(self)

    if self.mini_player then
        self.mini_player:on_show()
    end

    -- create_ui already applied the current download state. Rebinding every
    -- track on each show re-enters local_item/manifest work and stalls
    -- Favorites and Now Playing navigation. Refresh only when sync reports a
    -- newer generation after this screen has already been shown once.
    if should_refresh and
        type(self.refresh_download_state) ==
            "function" then
        self:refresh_download_state()
    end
end

local function local_on_hide(self)
    if active_local_screen == self then
        active_local_screen = nil
    end

    if self.virtual_track_list and
        type(
            jellyfin_playback_session
                .capture_track_list_resume
        ) == "function" then
        jellyfin_playback_session
            .capture_track_list_resume(self)
    end

    if self.mini_player then
        self.mini_player:on_hide()
    end

    jellyfin_list_ui.restore_controls(self)
end

local function display_artwork_path(value)
    if type(value) ~= "string" or
        value == "" or
        value:sub(1, 1) ~= "/" or
        value:sub(1, 2) == "//" then
        return value
    end

    local ok, root =
        pcall(device.storage_root)

    if not ok or type(root) ~= "string" or
        root == "" or root == "/sd" then
        return value
    end

    local display_root =
        "/" ..
        root:gsub("^/+", "")
            :gsub("/+$", "")

    if value == display_root or
        value:sub(
            1,
            #display_root + 1
        ) == display_root .. "/" then
        return value
    end

    return display_root ..
        value
end

local function artwork_path(
    collection,
    fallback
)
    local artwork =
        type(collection) == "table" and
        collection.artwork or nil

    if type(artwork) == "table" then
        for _, key in ipairs({
            "thumbnail",
            "cover",
            "album_thumbnail",
            "playlist_thumbnail",
        }) do
            local value = artwork[key]

            if type(value) == "string" and
                value ~= "" then
                return display_artwork_path(
                    value
                )
            end
        end
    end

    return fallback
end

local function normalized_album_name(value)
    if type(value) ~= "string" then
        return nil
    end

    local normalized =
        value:lower()
            :gsub("^%s+", "")
            :gsub("%s+$", "")
            :gsub("%s+", " ")

    if normalized == "" then
        return nil
    end

    return normalized
end

local function local_album_artwork()
    local library =
        jellyfin_local_index.load()

    local by_name = {}

    if type(library) ~= "table" then
        return by_name
    end

    for _, album in ipairs(
        library.albums or {}
    ) do
        local name =
            normalized_album_name(
                album.name or
                album.title
            )

        local source =
            artwork_path(
                album,
                nil
            )

        if name and source then
            by_name[name] = source
        end
    end

    return by_name
end

local function track_artwork_path(
    track,
    by_album_name
)
    local direct =
        artwork_path(
            track,
            nil
        )

    if direct then
        return direct
    end

    local album_name =
        normalized_album_name(
            track and
            (
                track.album or
                track.album_name
            )
        )

    if album_name and
        by_album_name[album_name] then
        return by_album_name[album_name]
    end

    return nil
end

local function find_playlist(
    library,
    playlist_id
)
    for _, playlist in ipairs(
        library.playlists or {}
    ) do
        if playlist.id == playlist_id or
            playlist.local_id ==
                playlist_id then
            return playlist
        end
    end

    return nil
end

local function selection_state(
    sort_key
)
    local selected =
        jellyfin_sort.current(
            sort_key,
            "tracks"
        )

    selected.alpha_label =
        jellyfin_sort.order_label(
            sort_key,
            "alpha",
            "tracks"
        )

    selected.recent_label =
        jellyfin_sort.order_label(
            sort_key,
            "recent",
            "tracks"
        )

    return selected
end

local function create_track_sort(
    self,
    sort_key
)
    jellyfin_sort.ensure(
        sort_key,
        "tracks",
        {
            "alpha",
            "recent",
        }
    )

    local current =
        selection_state(
            sort_key
        )

    jellyfin_list_ui.add_sort_control(
        self,
        {
            methods = {
                "alpha",
                "recent",
            },
            current_method =
                current.method,
            current_label =
                current.label,
            alpha_label =
                current.alpha_label,
            recent_label =
                current.recent_label,
            on_highlight =
                function(method)
                    local selected =
                        jellyfin_sort.choose(
                            sort_key,
                            method,
                            "tracks"
                        )

                    if not selected then
                        return nil
                    end

                    return selection_state(
                        sort_key
                    )
                end,
            on_toggle =
                function(method)
                    local selected =
                        jellyfin_sort.toggle(
                            sort_key,
                            method,
                            "tracks"
                        )

                    if not selected then
                        return nil
                    end

                    return selection_state(
                        sort_key
                    )
                end,
            on_apply =
                function()
                    if type(
                        self.apply_sort
                    ) == "function" then
                        self.apply_sort()
                    end
                end,
        }
    )
end

CollectionScreen =
    screen:new {
        create_ui = function(self)
            create_local_root(
                self,
                self.title or "Playlist"
            )

            jellyfin_track_action_sheet
                .attach(self)

            local library,
                library_error =
                sync_library_view.current()

            if not library then
                local row =
                    jellyfin_list_ui
                        .add_message(
                            self,
                            library_error or
                                "Library unavailable"
                        )

                self.first_row =
                    row.object
                return
            end

            local collection

            if self.collection_kind ==
                    "favorites" then
                collection =
                    library.favorites
            else
                collection =
                    find_playlist(
                        library,
                        self.collection_id
                    )
            end

            if not collection then
                local row =
                    jellyfin_list_ui
                        .add_message(
                            self,
                            "Playlist unavailable"
                        )

                self.first_row =
                    row.object
                return
            end

            local album_artwork =
                local_album_artwork()

            local sort_key

            if self.collection_kind ==
                    "favorites" then
                sort_key = "favorites"
            else
                sort_key =
                    "playlist:" ..
                    tostring(
                        self.collection_id or
                        collection.id or
                        "unknown"
                    )
            end

            create_track_sort(
                self,
                sort_key
            )

            local items =
                collection.items or {}

            if #items == 0 then
                local row =
                    jellyfin_list_ui
                        .add_message(
                            self,
                            "No tracks"
                        )

                self.media_rows = {row}
                self.first_row = row.object
                return
            end

            jellyfin_collection_playback
                .attach(
                    self,
                    {
                        tracks =
                            function()
                                return playable_tracks(
                                    self.sorted_tracks or
                                    items
                                )
                            end,
                        context = {
                            collection_kind =
                                self.collection_kind,
                            collection_id =
                                self.collection_id,
                        },
                    }
                )

            local function track_context(track)
                return {
                    collection_kind =
                        self.collection_kind,
                    collection_id =
                        self.collection_id,
                    entry_id =
                        track.playlist_entry_id,
                    queue_tracks =
                        playable_tracks(
                            self.sorted_tracks
                        ),
                }
            end

            local function track_available(track)
                return
                    jellyfin_playback.local_item(
                        track
                    ) ~= nil
            end

            local function play_track(track)
                if not track_available(track) then
                    return
                end

                local played =
                    jellyfin_playback.play(
                        track,
                        track_context(track)
                    )

                if played then
                    backstack.push(
                        jellyfin_now_playing:new()
                    )
                end
            end

            local function open_track(track)
                if not track_available(track) then
                    return
                end

                self.track_action_sheet:open(
                    track,
                    track_context(track),
                    track
                )
            end

            function self.apply_sort()
                local sorted =
                    jellyfin_sort.sort(
                        sort_key,
                        items,
                        "tracks"
                    )

                self.sorted_tracks = sorted

                if self.virtual_track_list then
                    self.virtual_track_list:
                        set_items(sorted)
                else
                    jellyfin_virtual_track_list
                        .create(
                            self,
                            sorted,
                            {
                                item_id =
                                    function(track)
                                        return
                                            jellyfin_track_identity
                                                .key(
                                                    track
                                                )
                                    end,
                                artwork =
                                    function(track)
                                        return
                                            track_artwork_path(
                                                track,
                                                album_artwork
                                            )
                                    end,
                                detail =
                                    function(track)
                                        return track.artist
                                    end,
                                available =
                                    track_available,
                                on_click = play_track,
                                on_long_press =
                                    open_track,
                            }
                        )
                end

                self.first_row =
                    self.media_rows[1].object
            end

            function self:refresh_download_state()
                local next_library =
                    sync_library_view.current()
                local next_collection = nil

                if type(next_library) == "table" then
                    if self.collection_kind ==
                            "favorites" then
                        next_collection =
                            next_library.favorites
                    else
                        next_collection =
                            find_playlist(
                                next_library,
                                self.collection_id
                            )
                    end
                end

                if type(next_collection) ~= "table" then
                    return
                end

                items = next_collection.items or {}
                album_artwork =
                    local_album_artwork()
                self.apply_sort()
            end

            self.apply_sort()
        end,

        on_show = local_on_show,
        on_hide = local_on_hide,
    }

LibraryScreen =
    screen:new {
        create_ui = function(self)
            create_local_root(
                self,
                "Playlists"
            )

            self.playlist_action_sheet = nil

            local library,
                library_error =
                sync_library_view.current()

            if not library then
                local row =
                    jellyfin_list_ui
                        .add_message(
                            self,
                            library_error or
                                "Library unavailable"
                        )

                self.first_row =
                    row.object
                return
            end

            local create_row =
                jellyfin_list_ui
                    .add_action_row(
                        self,
                        "Create playlist",
                        {
                            leading = true,
                            height = 24,
                            y = 5,
                            text_height = 14,
                            selection_id =
                                "control:create-playlist",
                            on_click = function()
                                backstack.push(
                                    jellyfin_text_entry.new {
                                        title =
                                            "New playlist",
                                        on_submit =
                                            function(name)
                                                local local_id,
                                                    operation_or_error =
                                                    sync_operation_queue
                                                        .enqueue_create_playlist(
                                                            name,
                                                            {}
                                                        )

                                                if not local_id then
                                                    return false,
                                                        operation_or_error
                                                end

                                                self.selected_item_id =
                                                    local_id
                                                self.needs_playlist_rebuild =
                                                    true
                                                return true
                                            end,
                                    }
                                )
                            end,
                        }
                    )

            local favorites = {}

            for key, value in pairs(
                library.favorites or {}
            ) do
                favorites[key] = value
            end

            favorites.artwork = nil
            favorites.key =
                "special:favorites"

            local favorites_row =
                jellyfin_list_ui
                    .add_playlist_row(
                        self,
                        favorites,
                        "__favorites_star__",
                        function()
                            backstack.push(
                                CollectionScreen:new {
                                    title = "Favorites",
                                    collection_kind =
                                        "favorites",
                                }
                            )
                        end
                    )

            self.first_row =
                favorites_row.object
            self.initial_focus_object =
                favorites_row.object
            self.initial_scroll_anchor =
                favorites_row.object

            local playlist_rows = {
                favorites_row,
            }

            local list_rows = {
                create_row,
                favorites_row,
            }

            local action_sheet =
                jellyfin_playlist_action_sheet
                    .attach(self)

            for _, playlist in ipairs(
                library.playlists or {}
            ) do
                local playlist_copy =
                    playlist

                local playlist_id =
                    playlist_copy.local_id or
                    playlist_copy.id

                local playlist_artwork =
                    artwork_path(
                        playlist_copy,
                        nil
                    )

                playlist_artwork =
                    playlist_artwork or
                    "__playlist_blue__"

                local row =
                    jellyfin_list_ui
                        .add_playlist_row(
                            self,
                            playlist_copy,
                            playlist_artwork,
                            {
                                on_click = function()
                                    backstack.push(
                                        CollectionScreen:new {
                                            title =
                                                playlist_copy.name or
                                                "Playlist",
                                            collection_kind =
                                                "playlist",
                                            collection_id =
                                                playlist_id,
                                        }
                                    )
                                end,
                                on_long_press =
                                    function()
                                        action_sheet:open(
                                            playlist_copy
                                        )
                                    end,
                            }
                        )

                table.insert(
                    playlist_rows,
                    row
                )
                table.insert(
                    list_rows,
                    row
                )
            end

            self.create_playlist_row =
                create_row
            self.playlist_rows = playlist_rows
            self.list_rows = list_rows

            jellyfin_list_ui
                .attach_scroll_indicator(
                    self,
                    list_rows
                )

            function self:request_playlist_rebuild()
                self.needs_playlist_rebuild =
                    false

                local was_active =
                    self.ui_active == true

                if was_active then
                    local_on_hide(self)
                end

                if self.root then
                    pcall(function()
                        self.root:delete()
                    end)
                end

                self.root = nil
                self.playlist_action_sheet = nil
                self:create_ui()

                if was_active then
                    local_on_show(self)
                end
            end
        end,

        on_show = function(self)
            if self.needs_playlist_rebuild and
                type(self.request_playlist_rebuild) ==
                    "function" then
                self:request_playlist_rebuild()
            end

            local_on_show(self)
        end,

        on_hide = function(self)
            local_on_hide(self)
        end,
    }

LibraryScreen.Collection =
    CollectionScreen

return LibraryScreen

local backstack = require("backstack")
local jellyfin_list_ui =
    require("jellyfin_list_ui")
local jellyfin_now_playing =
    require("jellyfin_now_playing")
local jellyfin_playback =
    require("jellyfin_playback")
local jellyfin_local_index =
    require("jellyfin_local_index")
local jellyfin_sort =
    require("jellyfin_sort")
local jellyfin_track_action_sheet =
    require("jellyfin_track_action_sheet")
local screen = require("screen")
local sync_library_view =
    require("sync_library_view")

local LibraryScreen
local CollectionScreen

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
                return value
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
            jellyfin_list_ui.create_root(
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

            self.media_rows = {}

            for _, track in ipairs(
                items
            ) do
                local row =
                    jellyfin_list_ui
                        .add_track_row(
                            self,
                            track,
                            {
                                artwork =
                                    track_artwork_path(
                                        track,
                                        album_artwork
                                    ),
                                detail =
                                    track.artist,
                                on_click =
                                    function()
                                    end,
                            }
                        )

                table.insert(
                    self.media_rows,
                    row
                )
            end

            function self.apply_sort()
                local sorted =
                    jellyfin_sort.sort(
                        sort_key,
                        items,
                        "tracks"
                    )

                for index, track in ipairs(
                    sorted
                ) do
                    local track_copy =
                        track

                    local context = {
                        collection_kind =
                            self.collection_kind,
                        collection_id =
                            self.collection_id,
                        entry_id =
                            track_copy
                                .playlist_entry_id,
                        queue_tracks = sorted,
                    }

                    self.media_rows[index]
                        :update(
                            track_copy,
                            {
                                artwork =
                                    track_artwork_path(
                                        track_copy,
                                        album_artwork
                                    ),
                                detail =
                                    track_copy.artist,
                                on_click =
                                    function()
                                        local played =
                                            jellyfin_playback
                                                .play(
                                                    track_copy,
                                                    context
                                                )

                                        if played then
                                            backstack.push(
                                                jellyfin_now_playing
                                                    :new()
                                            )
                                        end
                                    end,
                                on_long_press =
                                    function()
                                        self.track_action_sheet
                                            :open(
                                                track_copy,
                                                context,
                                                track_copy
                                            )
                                    end,
                            }
                        )
                end

                self.first_row =
                    self.media_rows[1]
                        .object
            end

            self.apply_sort()

            jellyfin_list_ui
                .attach_scroll_indicator(
                    self,
                    self.media_rows
                )
        end,

        on_show =
            jellyfin_list_ui
                .install_controls,
        on_hide =
            jellyfin_list_ui
                .restore_controls,
    }

LibraryScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                "Playlists"
            )

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

            local playlist_rows = {
                favorites_row,
            }

            for _, playlist in ipairs(
                library.playlists or {}
            ) do
                local playlist_copy =
                    playlist

                local playlist_id =
                    playlist_copy.local_id or
                    playlist_copy.id

                local row =
                    jellyfin_list_ui
                        .add_playlist_row(
                            self,
                            playlist_copy,
                            artwork_path(
                                playlist_copy,
                                "//lua/img/playlist_placeholder.png"
                            ),
                            function()
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
                            end
                        )

                table.insert(
                    playlist_rows,
                    row
                )
            end

            self.playlist_rows = playlist_rows

            jellyfin_list_ui
                .attach_scroll_indicator(
                    self,
                    playlist_rows
                )
        end,

        on_show =
            jellyfin_list_ui
                .install_controls,
        on_hide =
            jellyfin_list_ui
                .restore_controls,
    }

LibraryScreen.Collection =
    CollectionScreen

return LibraryScreen

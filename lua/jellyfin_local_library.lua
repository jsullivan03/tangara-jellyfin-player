local backstack = require("backstack")
local jellyfin_list_ui =
    require("jellyfin_list_ui")
local jellyfin_local_index =
    require("jellyfin_local_index")
local jellyfin_now_playing =
    require("jellyfin_now_playing")
local jellyfin_playback =
    require("jellyfin_playback")
local jellyfin_sort =
    require("jellyfin_sort")
local jellyfin_track_action_sheet =
    require("jellyfin_track_action_sheet")
local jellyfin_virtual_list =
    require("jellyfin_virtual_list")
local jellyfin_virtual_track_list =
    require("jellyfin_virtual_track_list")
local screen = require("screen")
local sync_library_view =
    require("sync_library_view")

local M = {}

local RootScreen
local ArtistsScreen
local ArtistScreen
local AlbumsScreen
local AlbumScreen
local TracksScreen

local function artwork_path(item)
    local artwork =
        item and item.artwork

    if type(artwork) == "table" then
        for _, key in ipairs({
            "thumbnail",
            "cover",
            "album_thumbnail",
            "playlist_thumbnail",
        }) do
            local value =
                artwork[key]

            if type(value) == "string" and
                value ~= "" then
                return value
            end
        end
    end

    return
        "//lua/img/playlist_placeholder.png"
end

local function load_library(self)
    local library,
        library_error =
        jellyfin_local_index.load()

    if library then
        return library
    end

    local message =
        jellyfin_list_ui.add_message(
            self,
            library_error or
                "Local library unavailable"
        )

    self.first_row =
        message.object

    return nil
end

local function play_track(
    track,
    context
)
    local played =
        jellyfin_playback.play(
            track,
            context
        )

    if not played then
        return
    end

    backstack.push(
        jellyfin_now_playing:new()
    )
end

local function find_album(
    library,
    album_key
)
    for _, album in ipairs(
        library.albums or {}
    ) do
        if album.key == album_key then
            return album
        end
    end

    return nil
end

local function find_artist(
    library,
    artist_key
)
    for _, artist in ipairs(
        library.artists or {}
    ) do
        if artist.key == artist_key then
            return artist
        end
    end

    return nil
end

local function selection_state(
    sort_key,
    sort_kind
)
    local selected =
        jellyfin_sort.current(
            sort_key,
            sort_kind
        )

    selected.alpha_label =
        jellyfin_sort.order_label(
            sort_key,
            "alpha",
            sort_kind
        )

    selected.recent_label =
        jellyfin_sort.order_label(
            sort_key,
            "recent",
            sort_kind
        )

    return selected
end

local function create_sortable_root(
    self,
    title,
    sort_key,
    sort_kind,
    methods
)
    jellyfin_list_ui.create_root(
        self,
        title
    )

    jellyfin_sort.ensure(
        sort_key,
        sort_kind,
        methods
    )

    local current =
        selection_state(
            sort_key,
            sort_kind
        )

    jellyfin_list_ui.add_sort_control(
        self,
        {
            methods = methods,
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
                            sort_kind
                        )

                    if not selected then
                        return nil
                    end

                    return selection_state(
                        sort_key,
                        sort_kind
                    )
                end,
            on_toggle =
                function(method)
                    local selected =
                        jellyfin_sort.toggle(
                            sort_key,
                            method,
                            sort_kind
                        )

                    if not selected then
                        return nil
                    end

                    return selection_state(
                        sort_key,
                        sort_kind
                    )
                end,
            on_apply =
                function()
                    if type(
                        self.apply_sort
                    ) == "function" then
                        self.apply_sort(true)
                    end
                end,
        }
    )
end

local function set_first_media_row(self)
    local first =
        self.media_rows and
        self.media_rows[1]

    if first then
        self.first_row =
            first.object
        return
    end

    if self.sort_row then
        self.first_row =
            self.sort_row.object
    end
end

local function create_empty_row(
    self,
    message
)
    local row =
        jellyfin_list_ui.add_message(
            self,
            message
        )

    self.media_rows = {row}
    self.first_row = row.object
end

AlbumScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                self.title or "Album"
            )

            jellyfin_track_action_sheet
                .attach(self)

            local library =
                load_library(self)

            if not library then
                return
            end

            local album =
                find_album(
                    library,
                    self.album_key
                )

            if not album then
                create_empty_row(
                    self,
                    "Album unavailable"
                )
                return
            end

            self.media_rows = {}

            for _, track in ipairs(
                album.tracks or {}
            ) do
                local track_copy = track
                local context = {
                    collection_kind =
                        "local_album",
                    collection_id =
                        album.key,
                    queue_tracks =
                        album.tracks,
                }

                local row =
                    jellyfin_list_ui
                        .add_track_row(
                            self,
                            track_copy,
                            {
                                detail =
                                    track_copy.artist,
                                on_click =
                                    function()
                                        play_track(
                                            track_copy,
                                            context
                                        )
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

                table.insert(
                    self.media_rows,
                    row
                )
            end

            if #self.media_rows == 0 then
                create_empty_row(
                    self,
                    "No local tracks"
                )
            else
                set_first_media_row(
                    self
                )

                jellyfin_list_ui
                    .attach_scroll_indicator(
                        self,
                        self.media_rows
                    )
            end
        end,

        on_show =
            jellyfin_list_ui
                .install_controls,
        on_hide =
            jellyfin_list_ui
                .restore_controls,
    }

ArtistScreen =
    screen:new {
        create_ui = function(self)
            local sort_key =
                "artist:" ..
                tostring(
                    self.artist_key or
                    "unknown"
                )

            jellyfin_list_ui.create_root(
                self,
                self.title or "Artist"
            )

            jellyfin_sort.ensure(
                sort_key,
                "albums",
                {
                    "alpha",
                    "recent",
                }
            )

            local library =
                load_library(self)

            if not library then
                return
            end

            local artist =
                find_artist(
                    library,
                    self.artist_key
                )

            if not artist then
                create_empty_row(
                    self,
                    "Artist unavailable"
                )
                return
            end

            local releases =
                artist.releases or {}

            if #releases == 0 then
                create_empty_row(
                    self,
                    "No local releases"
                )
                return
            end

            self.media_rows = {}

            for _, album in ipairs(
                releases
            ) do
                local row =
                    jellyfin_list_ui
                        .add_album_row(
                            self,
                            album,
                            artwork_path(album),
                            function()
                            end
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
                        releases,
                        "albums"
                    )

                for index, album in ipairs(
                    sorted
                ) do
                    local album_copy =
                        album

                    self.media_rows[index]
                        :update(
                            album_copy,
                            artwork_path(
                                album_copy
                            ),
                            function()
                                backstack.push(
                                    AlbumScreen:new {
                                        title =
                                            album_copy.name,
                                        album_key =
                                            album_copy.key,
                                    }
                                )
                            end
                        )
                end

                set_first_media_row(
                    self
                )

                if self.scroll_indicator then
                    self.scroll_indicator:update(
                        #self.media_rows,
                        1
                    )
                end
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

ArtistsScreen =
    screen:new {
        create_ui = function(self)
            create_sortable_root(
                self,
                "Artists",
                "artists",
                "artists",
                {
                    "alpha",
                }
            )

            local library =
                load_library(self)

            if not library then
                return
            end

            local artists =
                library.artists or {}

            if #artists == 0 then
                create_empty_row(
                    self,
                    "No local artists"
                )
                return
            end

            self.media_rows = {}

            for _, artist in ipairs(
                artists
            ) do
                local row =
                    jellyfin_list_ui
                        .add_count_row(
                            self,
                            artist.name,
                            artist.release_count,
                            function()
                            end,
                            artist.key
                        )

                table.insert(
                    self.media_rows,
                    row
                )
            end

            function self.apply_sort()
                local sorted =
                    jellyfin_sort.sort(
                        "artists",
                        artists,
                        "artists"
                    )

                for index, artist in ipairs(
                    sorted
                ) do
                    local artist_copy =
                        artist

                    self.media_rows[index]
                        :update(
                            artist_copy.name,
                            artist_copy
                                .release_count,
                            function()
                                backstack.push(
                                    ArtistScreen:new {
                                        title =
                                            artist_copy.name,
                                        artist_key =
                                            artist_copy.key,
                                    }
                                )
                            end,
                            artist_copy.key
                        )
                end

                set_first_media_row(
                    self
                )

                if self.scroll_indicator then
                    self.scroll_indicator:update(
                        #self.media_rows,
                        1
                    )
                end
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

AlbumsScreen =
    screen:new {
        create_ui = function(self)
            create_sortable_root(
                self,
                "Albums",
                "albums",
                "albums",
                {
                    "alpha",
                    "recent",
                }
            )

            local library =
                load_library(self)

            if not library then
                return
            end

            local albums =
                library.albums or {}

            if #albums == 0 then
                create_empty_row(
                    self,
                    "No local albums"
                )
                return
            end

            function self.apply_sort(
                reset_selection
            )
                local sorted =
                    jellyfin_sort.sort(
                        "albums",
                        albums,
                        "albums"
                    )

                if self.virtual_album_list then
                    self.virtual_album_list
                        :set_items(
                            sorted,
                            {
                                reset_selection =
                                    reset_selection ==
                                    true,
                            }
                        )
                else
                    self.virtual_album_list =
                        jellyfin_virtual_list
                            .create(
                                self,
                                sorted,
                                {
                                    item_label =
                                        "album",
                                    item_plural =
                                        "albums",
                                    create_row =
                                        function(
                                            owner,
                                            album
                                        )
                                            return
                                                jellyfin_list_ui
                                                    .add_album_row(
                                                        owner,
                                                        album,
                                                        artwork_path(
                                                            album
                                                        ),
                                                        nil
                                                    )
                                        end,
                                    update_row =
                                        function(
                                            model,
                                            album,
                                            handlers
                                        )
                                            model:update(
                                                album,
                                                artwork_path(
                                                    album
                                                ),
                                                handlers
                                                    .on_click
                                            )
                                        end,
                                    on_click =
                                        function(album)
                                            backstack.push(
                                                AlbumScreen:new {
                                                    title =
                                                        album.name,
                                                    album_key =
                                                        album.key,
                                                }
                                            )
                                        end,
                                }
                            )
                end

                set_first_media_row(
                    self
                )
            end

            self.apply_sort()
        end,

        on_show =
            jellyfin_list_ui
                .install_controls,
        on_hide =
            jellyfin_list_ui
                .restore_controls,
    }

TracksScreen =
    screen:new {
        create_ui = function(self)
            create_sortable_root(
                self,
                "Tracks",
                "tracks",
                "tracks",
                {
                    "alpha",
                    "recent",
                }
            )

            jellyfin_track_action_sheet
                .attach(self)

            local library =
                load_library(self)

            if not library then
                return
            end

            local tracks =
                library.tracks or {}

            if #tracks == 0 then
                create_empty_row(
                    self,
                    "No local tracks"
                )
                return
            end

            function self.apply_sort(
                reset_selection
            )
                local sorted =
                    jellyfin_sort.sort(
                        "tracks",
                        tracks,
                        "tracks"
                    )

                self.sorted_tracks = sorted

                if self.virtual_track_list then
                    self.virtual_track_list
                        :set_items(
                            sorted,
                            {
                                reset_selection =
                                    reset_selection ==
                                    true,
                            }
                        )
                else
                    jellyfin_virtual_track_list
                        .create(
                            self,
                            sorted,
                            {
                                artwork =
                                    artwork_path,
                                detail =
                                    function(track)
                                        return
                                            track.artist
                                    end,
                                on_click =
                                    function(track)
                                        play_track(
                                            track,
                                            {
                                                collection_kind =
                                                    "local_tracks",
                                                queue_tracks =
                                                    self.sorted_tracks,
                                            }
                                        )
                                    end,
                                on_long_press =
                                    function(track)
                                        local context = {
                                            collection_kind =
                                                "local_tracks",
                                            queue_tracks =
                                                self.sorted_tracks,
                                        }

                                        self.track_action_sheet
                                            :open(
                                                track,
                                                context,
                                                track
                                            )
                                    end,
                            }
                        )
                end

                set_first_media_row(
                    self
                )
            end

            self.apply_sort()
        end,

        on_show =
            jellyfin_list_ui
                .install_controls,
        on_hide =
            jellyfin_list_ui
                .restore_controls,
    }

RootScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                "Local Library",
                {
                    on_back =
                        function()
                        end,
                }
            )

            self.list:set {
                y = 28,
                h = 100,
                pad_row = 1,
            }

            local library =
                load_library(self)

            if not library then
                return
            end

            local sync_library =
                sync_library_view.current()

            local playlist_count = 0

            if type(sync_library) ==
                    "table" then
                playlist_count =
                    #(
                        sync_library
                            .playlists or {}
                    )
            end

            local playlists =
                jellyfin_list_ui
                    .add_count_row(
                        self,
                        "Playlists",
                        playlist_count,
                        function()
                            backstack.push(
                                require(
                                    "jellyfin_library"
                                ):new()
                            )
                        end,
                        "root:playlists"
                    )

            jellyfin_list_ui.add_count_row(
                self,
                "Artists",
                library.counts.artists,
                function()
                    backstack.push(
                        ArtistsScreen:new()
                    )
                end,
                "root:artists"
            )

            jellyfin_list_ui.add_count_row(
                self,
                "Albums",
                library.counts.albums,
                function()
                    backstack.push(
                        AlbumsScreen:new()
                    )
                end,
                "root:albums"
            )

            jellyfin_list_ui.add_count_row(
                self,
                "Tracks",
                library.counts.tracks,
                function()
                    backstack.push(
                        TracksScreen:new()
                    )
                end,
                "root:tracks"
            )

            self.first_row =
                playlists.object
        end,

        on_show =
            jellyfin_list_ui
                .install_controls,
        on_hide =
            jellyfin_list_ui
                .restore_controls,
    }

M.Root = RootScreen
M.Artists = ArtistsScreen
M.Albums = AlbumsScreen
M.Tracks = TracksScreen
M.Artist = ArtistScreen
M.Album = AlbumScreen

return M

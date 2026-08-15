local backstack = require("backstack")
local jellyfin_collection_playback =
    require("jellyfin_collection_playback")
local jellyfin_list_ui =
    require("jellyfin_list_ui")
local jellyfin_mini_player =
    require("jellyfin_mini_player")
local jellyfin_local_index =
    require("jellyfin_local_index")
local jellyfin_local_artwork =
    require("jellyfin_local_artwork")
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
local jellyfin_theme =
    require("jellyfin_theme")
local lvgl = require("lvgl")
local screen = require("screen")
local sync_library_view =
    require("sync_library_view")
local sync_runtime = require("sync_runtime")
local sync_download_state =
    require("sync_download_state")
local jellyfin_album_identity =
    require("jellyfin_album_identity")
local jellyfin_track_identity =
    require("jellyfin_track_identity")
local jellyfin_playback_session =
    require("jellyfin_playback_session")

local M = {}

local RootScreen
local ArtistsScreen
local ArtistScreen
local AlbumsScreen
local AlbumScreen
local TracksScreen
local artwork_path
local active_local_screen = nil
local local_poll_timer = nil

local function runtime_generation()
    local runtime = 0
    if type(sync_runtime.state_generation) ==
            "function" then
        runtime =
            tonumber(
                sync_runtime.state_generation()
            ) or 0
    end

    return runtime +
        (sync_download_state.generation() or 0)
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

local function artists_layout_mode()
    local value = rawget(
        _G,
        "tangara_sim_artists_layout"
    )

    if value == nil and os and
        type(os.getenv) == "function" then
        local ok, configured = pcall(
            os.getenv,
            "TANGARA_SIM_ARTISTS_LAYOUT"
        )

        if ok then
            value = configured
        end
    end

    return value == "preview" and
        "preview" or "compact"
end

local function bind_preview_artwork(
    image,
    source,
    x,
    y,
    size
)
    image:set {src = lvgl.ImgData(source)}
    local width, height = image:get_img_size()
    width = tonumber(width) or size
    height = tonumber(height) or size
    local zoom = math.max(1, math.floor(
        math.min(size / width, size / height) *
            256 + 0.5
    ))

    image:set {
        x = x,
        y = y,
        w = width,
        h = height,
        align = lvgl.ALIGN.TOP_LEFT,
        offset_x = 0,
        offset_y = 0,
        angle = 0,
        zoom = zoom,
        pivot = {
            x = math.floor(width / 2),
            y = math.floor(height / 2),
        },
        inner_align = lvgl.IMAGE_ALIGN.CENTER,
        transform_width = 0,
        transform_height = 0,
        antialias = true,
    }
end

local function create_artist_preview(self)
    local palette = jellyfin_theme.current()
    local height =
        self.mini_player and
        self.mini_player.visible and
        76 or 100
    local pane = self.root:Object {
        x = 98,
        y = 28,
        w = 60,
        h = height,
        pad_all = 0,
        border_width = 1,
        border_color = palette.divider,
        radius = 3,
        bg_color = palette.placeholder_cover,
        bg_opa = 255,
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
    }
    pane:clear_flag(lvgl.FLAG.SCROLLABLE)
    pane:clear_flag(lvgl.FLAG.CLICKABLE)

    local images = {}

    for index = 1, 4 do
        images[index] = pane:Image {
            x = 2,
            y = 2,
            w = 27,
            h = 27,
        }
        images[index]:clear_flag(
            lvgl.FLAG.CLICKABLE
        )
        images[index]:add_flag(
            lvgl.FLAG.HIDDEN
        )
    end

    local initials = pane:Label {
        x = 4,
        y = 17,
        w = 50,
        h = 22,
        text = "?",
        text_align = 2,
        text_color = palette.foreground,
        text_font = font.fusion_12,
    }
    initials:clear_flag(lvgl.FLAG.CLICKABLE)

    local name = pane:Label {
        x = 3,
        y = 64,
        w = 52,
        h = 28,
        text = "",
        text_align = 2,
        text_color = palette.foreground,
        text_font = font.fusion_10,
        long_mode = lvgl.LABEL.LONG_DOT,
    }
    name:clear_flag(lvgl.FLAG.CLICKABLE)

    local model = {
        object = pane,
        images = images,
        initials = initials,
        name = name,
        sources = {},
    }

    function model:update(artist)
        local sources = {}
        local seen = {}

        for _, album in ipairs(
            artist and artist.releases or {}
        ) do
            local source = artwork_path(
                album
            )

            if type(source) == "string" and
                source ~= "" and
                not source:find(
                    "placeholder",
                    1,
                    true
                ) then
                source =
                    jellyfin_local_artwork
                        .display_path(source)

                if not seen[source] then
                    seen[source] = true
                    sources[#sources + 1] = source
                end
            end

            if #sources >= 4 then
                break
            end
        end

        for _, image in ipairs(images) do
            image:add_flag(lvgl.FLAG.HIDDEN)
        end

        local artist_name =
            artist and artist.name or ""
        name:set {text = artist_name}

        if #sources == 0 then
            local first = artist_name:match(
                "[%w\128-\255]"
            ) or "?"
            initials:set {text = first:upper()}
            initials:clear_flag(
                lvgl.FLAG.HIDDEN
            )
        else
            initials:add_flag(lvgl.FLAG.HIDDEN)

            if #sources == 1 then
                bind_preview_artwork(
                    images[1],
                    sources[1],
                    2,
                    2,
                    54
                )
                images[1]:clear_flag(
                    lvgl.FLAG.HIDDEN
                )
            else
                local positions = {
                    {2, 2}, {30, 2},
                    {2, 30}, {30, 30},
                }

                for index, source in ipairs(sources) do
                    bind_preview_artwork(
                        images[index],
                        source,
                        positions[index][1],
                        positions[index][2],
                        27
                    )
                    images[index]:clear_flag(
                        lvgl.FLAG.HIDDEN
                    )
                end
            end
        end

        self.sources = sources
        self.artist_key =
            artist and artist.key
    end

    self.on_mini_player_visibility =
        function(_, visible, next_height)
            pane:set {h = next_height}
            name:set {
                y = visible and 62 or 64,
                h = visible and 12 or 28,
            }
        end

    self.artist_preview = model
    return model
end

local function create_local_root(
    self,
    title,
    options
)
    jellyfin_list_ui.create_root(
        self,
        title,
        options
    )
    jellyfin_mini_player.attach(self)
end

-- Defined after focus_selected_local_item so album Now Playing resume can
-- rebind the stable track row before install_controls paints the first frame.
local local_on_show
local local_on_hide

artwork_path = function(item)
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
                return jellyfin_local_artwork
                    .display_path(value)
            end
        end
    end

    if type(item) == "table" and
        type(item.artwork_path) == "string" and
        item.artwork_path ~= "" then
        -- Reuse the Sync/Search artwork cache resolution without inventing a
        -- new fetch pipeline. Cached/on-disk hits resolve synchronously.
        local ok_cache, sync_artwork_cache =
            pcall(require, "sync_artwork_cache")
        if ok_cache and
            type(sync_artwork_cache) == "table" and
            type(sync_artwork_cache.resolved) ==
                "function" then
            local resolved =
                sync_artwork_cache.resolved(item)
            if type(resolved) == "string" and
                resolved ~= "" then
                return resolved
            end
        end

        return jellyfin_local_artwork
            .display_path(item.artwork_path)
    end

    return
        "//lua/img/playlist_placeholder.png"
end

local function album_row_options(
    album,
    on_click,
    on_long_press
)
    local pending =
        type(album) == "table" and
        album.pending_download == true and
        (
            album.download_state == "queued" or
            album.download_state == "downloading"
        )

    return {
        -- Pending rows reserve list position only: dimmed, not activatable,
        -- no trailing chips/bars/counts.
        available = not pending,
        on_click = pending and nil or on_click,
        on_long_press =
            pending and nil or on_long_press,
        hide_trailing_badge = pending == true,
        dimmed = pending == true,
    }
end


local function background_artwork_path(item)
    local artwork =
        item and item.artwork

    if type(artwork) == "table" then
        local value =
            artwork.background

        if type(value) == "string" and
            value ~= "" and
            value ~=
                "//lua/img/background_placeholder.png" then
            return value
        end
    end

    local tracks =
        item and item.tracks

    if type(tracks) == "table" then
        for _, track in ipairs(tracks) do
            local track_artwork =
                track.artwork
            local value =
                type(track_artwork) == "table" and
                track_artwork.background or nil

            if type(value) == "string" and
                value ~= "" and
                value ~=
                    "//lua/img/background_placeholder.png" then
                return value
            end
        end
    end

    -- Older Local albums can predate the 160x128 derivative while still
    -- having a persistent offline cover. Use that viewed album's own cover as
    -- a centered, dimmed background instead of borrowing playback artwork.
    local fallback_sources = {}

    if type(artwork) == "table" then
        table.insert(
            fallback_sources,
            artwork
        )
    end

    if type(tracks) == "table" then
        for _, track in ipairs(tracks) do
            if type(track.artwork) ==
                    "table" then
                table.insert(
                    fallback_sources,
                    track.artwork
                )
            end
        end
    end

    for _, source in ipairs(
        fallback_sources
    ) do
        if type(source) == "table" then
            for _, key in ipairs({
                "cover",
                "thumbnail",
                "album_thumbnail",
            }) do
                local value = source[key]

                if type(value) == "string" and
                    value ~= "" and
                    value ~=
                        "//lua/img/cover_placeholder.png" then
                    return value
                end
            end
        end
    end

    return nil
end

local function stable_item_id(item)
    return jellyfin_track_identity.key(
        item
    ) or
        jellyfin_album_identity.item_id(
            item
        )
end

local function playable_tracks(items)
    local result = {}

    for _, track in ipairs(items or {}) do
        if not track.pending_download and
            jellyfin_playback.local_item(track) then
            result[#result + 1] = track
        end
    end

    return result
end

local function apply_device_download_recency(items)
    if type(sync_runtime.local_downloaded_at) ~=
            "function" then
        return
    end

    for _, item in ipairs(items or {}) do
        if type(item) == "table" and
            not item.pending_download then
            local downloaded_at =
                sync_runtime.local_downloaded_at(
                    item
                )

            if downloaded_at ~= nil then
                item.local_downloaded_at =
                    downloaded_at
            end
        end
    end
end

local function open_local_album_options(
    owner,
    album
)
    if type(owner) ~= "table" or
        type(album) ~= "table" or
        album.pending_download or
        not owner.track_action_sheet then
        return false
    end

    local function action_tracks()
        return playable_tracks(
            album.tracks or {}
        )
    end
    local context = {
        collection_kind = "local_album",
        collection_id = album.key,
    }
    local actions = {
        {
            id = "play_album",
            label = "Play",
            activate = function()
                jellyfin_collection_playback
                    .start(
                        action_tracks(),
                        context,
                        false
                    )
            end,
        },
        {
            id = "shuffle_album",
            label = "Shuffle",
            activate = function()
                jellyfin_collection_playback
                    .start(
                        action_tracks(),
                        context,
                        true
                    )
            end,
        },
        {
            id = "remove_local_album",
            label =
                "Remove from this Tangara",
            activate = function()
                local jellyfin_storage =
                    require("jellyfin_storage")
                local storage_ui =
                    require("jellyfin_storage_ui")

                backstack.push(
                    storage_ui.Confirm:new {
                        message =
                            "Keep the Jellyfin copy; remove this Tangara album?",
                        confirm_label =
                            "Remove album",
                        on_confirm =
                            function()
                                return
                                    jellyfin_storage
                                        .remove_album(
                                            album
                                        )
                            end,
                        on_success =
                            function()
                                if type(
                                    owner
                                        .refresh_download_state
                                ) ==
                                    "function" then
                                    owner:
                                        refresh_download_state()
                                end
                            end,
                    }
                )
            end,
        },
    }

    return owner.track_action_sheet:
        open_custom(actions)
end

local function pending_entries()
    local result = {}
    local seen = {}

    local placeholders =
        sync_download_state.pending_placeholders()
    for _, entry in ipairs(placeholders) do
        local item =
            entry.album or entry.item
        local key =
            entry.key or
            sync_download_state.key(item)
        if type(item) == "table" and
            key and not seen[key] then
            seen[key] = true
            result[#result + 1] = {
                item = item,
                state =
                    entry.state or
                    item.download_state or
                    "queued",
                key = key,
                progress =
                    entry.progress or
                    item.download_progress,
            }
        end
    end

    if type(sync_runtime.pending_items) ==
            "function" then
        local ok, entries = pcall(
            sync_runtime.pending_items
        )
        if ok and type(entries) == "table" then
            for _, entry in ipairs(entries) do
                local item = entry.item
                local key =
                    sync_download_state.key(
                        item
                    )
                if type(item) == "table" and
                    key and not seen[key] then
                    seen[key] = true
                    result[#result + 1] = {
                        item = item,
                        state =
                            entry.state or
                            "queued",
                        key = key,
                    }
                end
            end
        end
    end

    return result
end

local function merge_pending_tracks(tracks)
    local merged = {}
    local seen = {}

    for _, track in ipairs(tracks or {}) do
        merged[#merged + 1] = track
        local item_id = stable_item_id(track)

        if item_id then
            seen[item_id] = true
        end
    end

    for _, entry in ipairs(pending_entries()) do
        local item = entry.item
        local item_id = stable_item_id(item)

        if type(item) == "table" and
            item.kind ~= "album" and
            item_id and not seen[item_id] then
            local placeholder = {
                id = item_id,
                jellyfin_id = item_id,
                track_key =
                    jellyfin_track_identity.key(
                        {
                            jellyfin_id = item_id,
                            id = item_id,
                            album_id =
                                item.album_id or
                                item.jellyfin_album_id,
                            album =
                                item.album or
                                item.album_name,
                            artist =
                                item.artist or "",
                            title =
                                item.title or
                                item.name,
                        }
                    ),
                title =
                    item.title or
                    item.name or
                    "Downloading",
                artist = item.artist or "",
                album =
                    item.album or
                    item.album_name or "",
                album_id =
                    item.album_id or
                    item.jellyfin_album_id,
                album_key =
                    jellyfin_album_identity
                        .track_album_key(item),
                duration = item.duration or 0,
                artwork = item.artwork,
                pending_download = true,
                download_state =
                    entry.state or "queued",
            }
            merged[#merged + 1] = placeholder
            seen[item_id] = true
        end
    end

    return merged
end

local function merge_pending_albums(albums)
    local merged = {}
    local by_key = {}

    local function album_map_key(album)
        return jellyfin_album_identity.key(
            album
        ) or ""
    end

    for _, album in ipairs(albums or {}) do
        merged[#merged + 1] = album
        by_key[album_map_key(album)] = album
    end

    for _, entry in ipairs(pending_entries()) do
        local item = entry.item

        if type(item) == "table" then
            local key =
                entry.key or album_map_key(item)
            local existing =
                key ~= "" and by_key[key] or nil

            -- Prefer the enriched placeholder model from the owner.
            if item.pending_download and
                item.key and
                key ~= "" then
                if existing then
                    -- A Local index can legitimately contain the first files
                    -- of an album before the durable album operation is done.
                    -- Do not let that partial inventory turn the row into an
                    -- activatable album. Overlay a pending copy so the cached
                    -- Local index stays immutable and the row remains a
                    -- greyed placeholder until authoritative completion.
                    local pending_album = {}
                    for field, value in pairs(existing) do
                        pending_album[field] = value
                    end

                    pending_album.pending_download = true
                    pending_album.download_state =
                        entry.state or
                        item.download_state or
                        "queued"
                    pending_album.download_progress =
                        entry.progress or
                        item.download_progress
                    pending_album.artwork =
                        item.artwork or
                        existing.artwork
                    pending_album.artwork_path =
                        item.artwork_path or
                        existing.artwork_path
                    pending_album.jellyfin_id =
                        item.jellyfin_id or
                        existing.jellyfin_id
                    pending_album.jellyfin_artist_id =
                        item.jellyfin_artist_id or
                        existing.jellyfin_artist_id
                    pending_album.server_track_count =
                        item.server_track_count or
                        existing.server_track_count or
                        existing.track_count
                    pending_album.local_track_count =
                        item.local_track_count or
                        existing.local_track_count or
                        #(existing.tracks or {})
                    pending_album.track_count =
                        pending_album.server_track_count or
                        existing.track_count or 0
                    pending_album.download_op_id =
                        item.download_op_id
                    pending_album.download_queue_index =
                        item.download_queue_index
                    -- The row is intentionally not enterable while pending;
                    -- keeping no partial track payload also prevents accidental
                    -- deep links from rendering an incomplete album.
                    pending_album.tracks = {}

                    for index, candidate in ipairs(merged) do
                        if candidate == existing then
                            merged[index] = pending_album
                            break
                        end
                    end
                    by_key[key] = pending_album
                else
                    local placeholder = {
                        id =
                            item.id or
                            item.jellyfin_id or
                            key,
                        jellyfin_id =
                            item.jellyfin_id,
                        key = key,
                        kind = "album",
                        name =
                            item.name or
                            item.title or
                            "Downloading",
                        title =
                            item.title or
                            item.name,
                        artist =
                            item.artist or "",
                        jellyfin_artist_id =
                            item.jellyfin_artist_id or
                            item.artist_id,
                        track_count =
                            item.server_track_count or
                            item.track_count or
                            0,
                        server_track_count =
                            item.server_track_count or
                            item.track_count,
                        local_track_count =
                            item.local_track_count or
                            0,
                        tracks =
                            item.tracks or {},
                        artwork = item.artwork,
                        artwork_path =
                            item.artwork_path,
                        artwork_source =
                            item.artwork_source,
                        artwork_revision =
                            item.artwork_revision,
                        PrimaryImageTag =
                            item.PrimaryImageTag,
                        image_tag =
                            item.image_tag,
                        pending_download = true,
                        download_state =
                            entry.state or
                            item.download_state or
                            "queued",
                        download_progress =
                            entry.progress or
                            item.download_progress,
                        download_op_id =
                            item.download_op_id,
                        download_queue_index =
                            item.download_queue_index,
                        jellyfin_track_ids =
                            item.jellyfin_track_ids,
                    }
                    merged[#merged + 1] =
                        placeholder
                    by_key[key] = placeholder
                end
            elseif key ~= "" and not by_key[key] then
                local album_id =
                    jellyfin_album_identity
                        .album_id(item)
                local album_name =
                    item.kind == "album" and
                    (
                        item.title or item.name
                    ) or
                    item.album or
                    item.album_name
                local artwork =
                    type(item.artwork) == "table" and
                    item.artwork or {}
                if type(item.artwork_path) ==
                        "string" and
                    item.artwork_path ~= "" and
                    not artwork.thumbnail then
                    artwork = {
                        thumbnail =
                            item.artwork_path,
                        cover =
                            item.artwork_path,
                    }
                end
                local placeholder = {
                    id = album_id or key,
                    jellyfin_id = album_id,
                    key = key,
                    kind = "album",
                    name =
                        album_name or
                        "Downloading",
                    artist = item.artist or "",
                    jellyfin_artist_id =
                        item.jellyfin_artist_id or
                        item.artist_id,
                    track_count =
                        tonumber(
                            item.track_count
                        ) or 0,
                    server_track_count =
                        tonumber(
                            item.track_count
                        ),
                    local_track_count = 0,
                    tracks = {},
                    artwork = artwork,
                    artwork_path =
                        item.artwork_path,
                    pending_download = true,
                    pending_from_tracks =
                        item.kind ~= "album",
                    download_state =
                        entry.state or "queued",
                    download_progress =
                        entry.progress,
                }
                merged[#merged + 1] =
                    placeholder
                by_key[key] = placeholder
            elseif key ~= "" and
                by_key[key] and
                by_key[key].pending_download and
                by_key[key].pending_from_tracks and
                item.kind ~= "album" then
                by_key[key].track_count =
                    (by_key[key].track_count or 0) + 1
            end
        end
    end

    return merged
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
    local wanted =
        jellyfin_album_identity
            .canonical_id(album_key) or
        tostring(album_key or "")
    local wanted_key =
        jellyfin_album_identity
            .local_album_key(wanted) or
        tostring(album_key or "")

    for _, album in ipairs(
        library and library.albums or {}
    ) do
        local album_id =
            jellyfin_album_identity
                .album_id(album)
        if album.key == album_key or
            album.key == wanted_key or
            (
                album_id and
                (
                    album_id == wanted or
                    jellyfin_album_identity
                        .local_album_key(
                            album_id
                        ) == album_key
                )
            ) then
            return album
        end
    end

    for _, album in ipairs(
        merge_pending_albums({})
    ) do
        local album_id =
            jellyfin_album_identity
                .album_id(album)
        local key = tostring(
            album.key or ""
        )

        if key == album_key or
            key == wanted_key or
            (
                album_id and
                (
                    album_id == wanted or
                    album_key == album_id or
                    album_key ==
                        jellyfin_album_identity
                            .local_album_key(
                                album_id
                            )
                )
            ) then
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
    create_local_root(
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

local function focus_selected_local_item(self)
    local selected_id =
        self and self.selected_item_id

    if type(selected_id) ~= "string" or
        selected_id == "" then
        return nil
    end

    if type(self.selection_object_for_id) ~=
            "function" then
        return nil
    end

    local object =
        self.selection_object_for_id(
            selected_id
        )

    if not object then
        return nil
    end

    self.initial_focus_object = object
    self.first_row = object
    return object
end

local function is_local_album_track_list(self)
    return
        self and
        self.album_key ~= nil and
        self.virtual_track_list ~= nil
end

local function capture_local_album_track_resume(
    self
)
    if not is_local_album_track_list(self) then
        return nil
    end

    return jellyfin_playback_session
        .capture_track_list_resume(self)
end

local function restore_local_album_track_resume(
    self
)
    if not is_local_album_track_list(self) then
        return nil
    end

    local restored =
        jellyfin_playback_session
            .restore_track_list_resume(self)

    if restored then
        focus_selected_local_item(self)
    end

    return restored
end

local function clear_local_album_track_resume_lock(
    self
)
    jellyfin_playback_session
        .clear_track_list_resume_lock(self)
end
local_on_show = function(self)
    active_local_screen = self
    ensure_local_poll_timer()

    if self._download_unsub then
        pcall(self._download_unsub)
        self._download_unsub = nil
    end

    self._download_unsub =
        sync_download_state.subscribe(
            function(payload)
                if not self.ui_active then
                    return
                end
                self.download_state_generation =
                    runtime_generation()
                if type(
                    self.refresh_download_state
                ) == "function" then
                    self:refresh_download_state(
                        payload and payload.keys
                    )
                end
            end
        )

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

    -- Album track lists must re-select the user's track before install_controls
    -- / schedule_resume_repaint. Otherwise a Play-button entry leaves
    -- selected_item_id=control:play and the post-pop repaint steals focus from
    -- the restored track row, wiping track-list selection chrome.
    restore_local_album_track_resume(self)

    jellyfin_list_ui.install_controls(self)

    if self.mini_player then
        self.mini_player:on_show()
    end

    if is_local_album_track_list(self) and
        self.album_track_resume then
        -- Keep the track lock through the deferred resume-repaint tick so a
        -- delayed FOCUSED on Play cannot rewrite selected_item_id.
        local track_key =
            self.album_track_resume.track_key or
            self.album_track_resume.track_id
        local lock_generation =
            (
                self.album_track_resume_lock_generation or
                0
            ) + 1

        self.album_track_resume_lock_generation =
            lock_generation
        self.discography_selection_lock =
            track_key
        self.selected_item_id = track_key

        lvgl.Timer {
            period = 1,
            repeat_count = 1,
            cb = function()
                if self.album_track_resume_lock_generation ~=
                        lock_generation then
                    return
                end

                clear_local_album_track_resume_lock(
                    self
                )
            end,
        }
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

local_on_hide = function(self)
    if self._download_unsub then
        pcall(self._download_unsub)
        self._download_unsub = nil
    end

    if active_local_screen == self then
        active_local_screen = nil
    end

    capture_local_album_track_resume(self)

    if self.mini_player then
        self.mini_player:on_hide()
    end

    jellyfin_list_ui.restore_controls(self)
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
            local library,
                library_error =
                jellyfin_local_index.load()

            local album =
                library and
                find_album(
                    library,
                    self.album_key
                ) or nil

            local album_tracks =
                album and
                album.tracks or {}
            local local_album_tracks = {}

            for _, track in ipairs(
                album_tracks
            ) do
                if type(
                        jellyfin_playback
                            .local_item
                    ) ~= "function" or
                    jellyfin_playback
                        .local_item(track) then
                    local_album_tracks[
                        #local_album_tracks + 1
                    ] = track
                end
            end

            album_tracks = local_album_tracks

            local simulator_cache =
                rawget(
                    _G,
                    "tangara_sim_cache_track_background"
                )

            if album_tracks[1] and
                type(simulator_cache) ==
                    "function" then
                pcall(
                    simulator_cache,
                    album_tracks[1]
                )

                album.artwork =
                    album_tracks[1].artwork
            end

            create_local_root(
                self,
                self.title or "Album",
                {
                    background =
                        jellyfin_local_artwork
                            .display_path(
                                background_artwork_path(
                                    album
                                )
                            ),
                    background_dimmer_opa =
                        118,
                }
            )

            jellyfin_track_action_sheet
                .attach(self)

            if not library then
                local message =
                    jellyfin_list_ui
                        .add_message(
                            self,
                            library_error or
                                "Local library unavailable"
                        )

                self.first_row =
                    message.object
                return
            end

            if not album then
                create_empty_row(
                    self,
                    "Album unavailable"
                )
                return
            end

            local pending_tracks = {}
            for _, entry in ipairs(
                pending_entries()
            ) do
                local item = entry.item
                if item and
                    item.kind ~= "album" and
                    jellyfin_album_identity.same(
                        item,
                        {
                            key = self.album_key,
                            album_key =
                                self.album_key,
                            id =
                                jellyfin_album_identity
                                    .canonical_id(
                                        self.album_key
                                    ),
                        }
                    ) then
                    pending_tracks[
                        #pending_tracks + 1
                    ] = {
                        id =
                            jellyfin_track_identity
                                .stable_id(item) or
                            item.jellyfin_id or
                            item.id,
                        jellyfin_id =
                            jellyfin_track_identity
                                .stable_id(item) or
                            item.jellyfin_id or
                            item.id,
                        track_key =
                            jellyfin_track_identity
                                .key(item),
                        title =
                            item.title or
                            item.name or
                            "Downloading",
                        artist =
                            item.artist or "",
                        album =
                            item.album or
                            item.album_name or
                            "",
                        album_id =
                            jellyfin_album_identity
                                .album_id(item),
                        album_key =
                            jellyfin_album_identity
                                .track_album_key(
                                    item
                                ),
                        duration =
                            item.duration or 0,
                        artwork = item.artwork,
                        pending_download = true,
                        download_state =
                            entry.state or
                            "queued",
                    }
                end
            end

            if #album_tracks == 0 and
                #pending_tracks > 0 then
                album_tracks = pending_tracks
            elseif #pending_tracks > 0 then
                album_tracks =
                    merge_pending_tracks(
                        album_tracks
                    )
            end

            if #album_tracks == 0 then
                create_empty_row(
                    self,
                    "No local tracks"
                )

                function self:refresh_download_state()
                    local next_library =
                        jellyfin_local_index.load()
                    local next_album =
                        next_library and
                        find_album(
                            next_library,
                            self.album_key
                        )
                    local next_tracks =
                        next_album and
                        next_album.tracks or {}

                    if next_album and
                        not next_album.pending_download and
                        #next_tracks > 0 then
                        -- Completed album for this key: rebuild this screen
                        -- content without inventing pending status chrome.
                        local selected =
                            self.selected_item_id
                        backstack.pop()
                        backstack.push(
                            AlbumScreen:new {
                                album_key =
                                    next_album.key or
                                    self.album_key,
                                title =
                                    next_album.name or
                                    self.title,
                                selected_item_id =
                                    selected,
                            }
                        )
                    end
                end
                return
            end

            local context = {
                collection_kind =
                    "local_album",
                collection_id =
                    album.key,
            }

            local requested_selection =
                self.selected_item_id

            jellyfin_collection_playback
                .attach(
                    self,
                    {
                        tracks = function()
                            return playable_tracks(
                                album_tracks
                            )
                        end,
                        context = context,
                    }
                )

            local function track_context()
                return {
                    collection_kind =
                        context.collection_kind,
                    collection_id =
                        context.collection_id,
                    queue_tracks =
                        playable_tracks(album_tracks),
                }
            end

            jellyfin_virtual_track_list.create(
                self,
                album_tracks,
                {
                    item_id = stable_item_id,
                    detail = function(track)
                        return track.artist
                    end,
                    on_click = function(track)
                        play_track(
                            track,
                            track_context()
                        )
                    end,
                    on_long_press =
                        function(track)
                            local next_context =
                                track_context()
                            self.track_action_sheet:
                                open(
                                    track,
                                    next_context,
                                    track
                                )
                        end,
                }
            )

            -- Virtual-list initialization owns a track index and therefore
            -- adopts track 1 when there is no track resume target.  On a
            -- genuinely new album entry the leading Play control is the
            -- intended focus; only an explicit/deep-link track selection
            -- should replace it.
            if requested_selection == nil or
                requested_selection == "" or
                requested_selection ==
                    "control:play" then
                self.selected_item_id =
                    self.play_row and
                    self.play_row.selection_id or
                    "control:play"
                self.initial_focus_object =
                    self.play_row and
                    self.play_row.object or
                    self.initial_focus_object
            end

            set_first_media_row(self)
            focus_selected_local_item(self)
        end,

        on_show = local_on_show,
        on_hide = local_on_hide,
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

            create_local_root(
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

            local function open_album(album)
                backstack.push(
                    AlbumScreen:new {
                        title = album.name,
                        album_key = album.key,
                    }
                )
            end

            function self.apply_sort()
                local sorted =
                    jellyfin_sort.sort(
                        sort_key,
                        releases,
                        "albums"
                    )

                self.sorted_releases = sorted

                if self.virtual_release_list then
                    self.virtual_release_list:
                        set_items(sorted)
                else
                    self.virtual_release_list =
                        jellyfin_virtual_list.create(
                            self,
                            sorted,
                            {
                                item_label = "release",
                                item_plural = "releases",
                                item_id = function(album)
                                    return album.key
                                end,
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
                                            handlers.on_click
                                        )
                                    end,
                                on_click = open_album,
                            }
                        )
                end

                set_first_media_row(self)
            end

            self.apply_sort()
        end,

        on_show = local_on_show,
        on_hide = local_on_hide,
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

            self.artist_layout_mode =
                artists_layout_mode()

            if self.artist_layout_mode ==
                    "preview" then
                self.list:set {w = 94}
            end

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

            local preview =
                self.artist_layout_mode ==
                    "preview" and
                create_artist_preview(self) or
                nil

            local function open_artist(artist)
                backstack.push(
                    ArtistScreen:new {
                        title = artist.name,
                        artist_key = artist.key,
                    }
                )
            end

            function self.apply_sort()
                local sorted =
                    jellyfin_sort.sort(
                        "artists",
                        artists,
                        "artists"
                    )

                self.sorted_artists = sorted

                if self.virtual_artist_list then
                    self.virtual_artist_list:
                        set_items(sorted)
                else
                    self.virtual_artist_list =
                        jellyfin_virtual_list.create(
                            self,
                            sorted,
                            {
                                item_label = "artist",
                                item_plural = "artists",
                                row_height = 13,
                                row_gap = 0,
                                pool_size = 10,
                                anchor = 4,
                                scroll_indicator =
                                    self.artist_layout_mode ==
                                            "preview" and
                                        {
                                            x = 91,
                                        } or nil,
                                on_focus =
                                    function(_, artist)
                                        if preview and artist then
                                            preview:update(artist)
                                        end
                                    end,
                                item_id = function(artist)
                                    return artist.key
                                end,
                                create_row =
                                    function(
                                        owner,
                                        artist
                                    )
                                        return
                                            jellyfin_list_ui
                                                .add_compact_text_row(
                                                    owner,
                                                    artist.name,
                                                    nil,
                                                    artist.key,
                                                    self.artist_layout_mode ==
                                                            "preview" and
                                                        84 or 146
                                                )
                                    end,
                                update_row =
                                    function(
                                        model,
                                        artist,
                                        handlers
                                    )
                                        model:update(
                                            artist.name,
                                            handlers.on_click,
                                            artist.key
                                        )
                                    end,
                                on_click = open_artist,
                            }
                        )
                end

                set_first_media_row(self)

                if preview and sorted[1] then
                    preview:update(sorted[1])
                end
            end

            self.apply_sort()
        end,

        on_show = local_on_show,
        on_hide = local_on_hide,
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

            jellyfin_track_action_sheet
                .attach(self)

            local library =
                load_library(self)

            if not library then
                return
            end

            local albums =
                merge_pending_albums(
                    library.albums or {}
                )

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
                apply_device_download_recency(
                    albums
                )

                local sorted =
                    jellyfin_sort.sort(
                        "albums",
                        albums,
                        "albums"
                    )

                self.sorted_albums = sorted

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
                                            local model =
                                                jellyfin_list_ui
                                                    .add_album_row(
                                                        owner,
                                                        album,
                                                        artwork_path(
                                                            album
                                                        ),
                                                        album_row_options(
                                                            album
                                                        )
                                                    )
                                            if album.pending_download and
                                                type(album.artwork_path) ==
                                                    "string" and
                                                album.artwork_path ~= "" and
                                                model and
                                                model.artwork then
                                                local ok_cache,
                                                    sync_artwork_cache =
                                                    pcall(
                                                        require,
                                                        "sync_artwork_cache"
                                                    )
                                                if ok_cache and
                                                    type(
                                                        sync_artwork_cache
                                                            .request
                                                    ) == "function" and
                                                    not sync_artwork_cache
                                                        .resolved(
                                                            album
                                                        ) then
                                                    sync_artwork_cache
                                                        .request(
                                                            album,
                                                            function(path)
                                                                if type(path) ==
                                                                        "string" and
                                                                    path ~= "" and
                                                                    model.artwork and
                                                                    type(
                                                                        model
                                                                            .artwork
                                                                            .set
                                                                    ) ==
                                                                        "function" then
                                                                    model.artwork
                                                                        :set(
                                                                            path
                                                                        )
                                                                end
                                                            end
                                                        )
                                                end
                                            end
                                            return model
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
                                                album_row_options(
                                                    album,
                                                    handlers
                                                        .on_click,
                                                    handlers
                                                        .on_long_press
                                                )
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
                                    on_long_press =
                                        function(album)
                                            open_local_album_options(
                                                self,
                                                album
                                            )
                                        end,
                                }
                            )
                end

                set_first_media_row(
                    self
                )
            end

            function self:refresh_download_state()
                local next_library =
                    jellyfin_local_index.load()

                if type(next_library) ~= "table" then
                    return
                end

                albums = merge_pending_albums(
                    next_library.albums or {}
                )
                self.apply_sort()
            end

            self.apply_sort()
        end,

        on_show = local_on_show,
        on_hide = local_on_hide,
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
                merge_pending_tracks(
                    library.tracks or {}
                )

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
                apply_device_download_recency(
                    tracks
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
                                item_id =
                                    stable_item_id,
                                artwork =
                                    artwork_path,
                                detail =
                                    function(track)
                                        return
                                            track.artist
                                    end,
                                available =
                                    function(track)
                                        return
                                            not track
                                                .pending_download and
                                            jellyfin_playback
                                                .local_item(
                                                    track
                                                ) ~= nil
                                    end,
                                on_click =
                                    function(track)
                                        if track
                                                .pending_download then
                                            return
                                        end

                                        play_track(
                                            track,
                                            {
                                                collection_kind =
                                                    "local_tracks",
                                                queue_tracks =
                                                    playable_tracks(
                                                        self.sorted_tracks
                                                    ),
                                            }
                                        )
                                    end,
                                on_long_press =
                                    function(track)
                                        if track.pending_download then
                                            return
                                        end

                                        local context = {
                                            collection_kind =
                                                "local_tracks",
                                            queue_tracks =
                                                playable_tracks(
                                                    self.sorted_tracks
                                                ),
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
                focus_selected_local_item(
                    self
                )
            end

            function self:refresh_download_state()
                local next_library =
                    jellyfin_local_index.load()

                if type(next_library) ~= "table" then
                    return
                end

                tracks = merge_pending_tracks(
                    next_library.tracks or {}
                )
                self.apply_sort()
            end

            self.apply_sort()
        end,

        on_show = local_on_show,
        on_hide = local_on_hide,
    }

RootScreen =
    screen:new {
        create_ui = function(self)
            create_local_root(
                self,
                "Local"
            )

            local mini_visible =
                self.mini_player and
                self.mini_player.visible == true

            self.list:set {
                y = 28,
                h = mini_visible and 72 or 100,
                pad_row = 1,
            }

            if self.mini_player then
                self.mini_player:refresh()
            end

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

        on_show = local_on_show,
        on_hide = local_on_hide,
    }

M.Root = RootScreen
M.Artists = ArtistsScreen
M.Albums = AlbumsScreen
M.Tracks = TracksScreen
M.Artist = ArtistScreen
M.Album = AlbumScreen

return M

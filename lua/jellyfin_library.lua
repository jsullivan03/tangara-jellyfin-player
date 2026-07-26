local lvgl = require("lvgl")
local backstack = require("backstack")
local jellyfin_now_playing =
    require("jellyfin_now_playing")
local jellyfin_playback =
    require("jellyfin_playback")
local jellyfin_sort =
    require("jellyfin_sort")
local jellyfin_track_menu =
    require("jellyfin_track_menu")
local styles = require("styles")
local sync_library_view =
    require("sync_library_view")
local widgets = require("widgets")

local LibraryScreen
local CollectionScreen

local function text(value, fallback)
    if type(value) == "string" and
        value ~= "" then
        return value
    end

    return fallback or ""
end

local function pending_text(library)
    local pending =
        tonumber(library.pending_changes)
        or 0

    if pending == 0 then
        return "Library synced"
    end

    if pending == 1 then
        return "1 change waiting to sync"
    end

    return tostring(pending) ..
        " changes waiting to sync"
end

local function track_title(track)
    local title =
        text(track.title, "Unknown Track")
    local artist = text(track.artist)

    if artist == "" then
        return title
    end

    return title .. " - " .. artist
end

local function create_content(self)
    return self.root:Object {
        flex = {
            flex_direction = "column",
            flex_wrap = "nowrap",
            justify_content = "flex-start",
            align_items = "flex-start",
            align_content = "flex-start",
        },
        w = lvgl.PCT(100),
        flex_grow = 1,
        pad_left = 2,
        pad_right = 2,
        pad_bottom = 2,
        pad_row = 2,
    }
end

local function create_status(parent, value)
    return parent:Label {
        w = lvgl.PCT(100),
        text = value or "",
        text_font = font.fusion_10,
        text_align = 2,
        long_mode = lvgl.LABEL.LONG_WRAP,
        pad_top = 1,
        pad_bottom = 1,
    }
end

local function create_list(parent)
    return lvgl.List(parent, {
        w = lvgl.PCT(100),
        h = lvgl.PCT(100),
        flex_grow = 1,
    })
end

local function add_button(
    list,
    label,
    callback
)
    local button =
        list:add_btn(nil, label)

    button:add_style(styles.list_item)
    button:onClicked(callback)

    return button
end

local function add_track_button(
    list,
    label,
    click_callback,
    context_callback
)
    local button =
        list:add_btn(nil, label)
    local suppress_click = false

    button:add_style(styles.list_item)

    button:onevent(
        lvgl.EVENT.LONG_PRESSED,
        function()
            suppress_click = true
            context_callback()

            lvgl.Timer {
                period = 1000,
                repeat_count = 1,
                cb = function()
                    suppress_click = false
                end,
            }
        end
    )

    button:onClicked(
        function()
            if suppress_click then
                suppress_click = false
                return
            end

            click_callback()
        end
    )

    return button
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

CollectionScreen =
    widgets.MenuScreen:new {
        show_back = true,
        title = "Playlist",

        create_ui = function(self)
            widgets.MenuScreen.create_ui(self)

            local content =
                create_content(self)
            local library, library_error =
                sync_library_view.current()
            local status_label =
                create_status(content, "")
            local list =
                create_list(content)

            local back_button =
                add_button(
                    list,
                    "Back to playlists",
                    backstack.pop
                )

            back_button:focus()

            if not library then
                status_label:set {
                    text =
                        library_error or
                        "Jellyfin library is unavailable",
                }

                return
            end

            local collection = nil

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
                status_label:set {
                    text =
                        "This playlist is no longer available",
                }

                return
            end

            status_label:set {
                text =
                    tostring(
                        #collection.items
                    ) ..
                    " tracks; newest added first; hold for options",
            }

            local sorted_items =
                jellyfin_sort.newest_added(
                    collection.items
                )

            if #sorted_items == 0 then
                add_button(
                    list,
                    "No tracks",
                    function()
                    end
                )

                return
            end

            for _, track in ipairs(
                sorted_items
            ) do
                local track_copy = track
                local context = {
                    collection_kind =
                        self.collection_kind,
                    collection_id =
                        self.collection_id,
                    entry_id =
                        track_copy
                            .playlist_entry_id,
                }

                add_track_button(
                    list,
                    track_title(track_copy),
                    function()
                        local played,
                            play_error =
                            jellyfin_playback.play(
                                track_copy,
                                context
                            )

                        if not played then
                            status_label:set {
                                text =
                                    play_error or
                                    "Unable to play track",
                            }

                            return
                        end

                        backstack.push(
                            jellyfin_now_playing:new()
                        )
                    end,
                    function()
                        backstack.push(
                            jellyfin_track_menu:new {
                                track =
                                    track_copy,
                                collection_kind =
                                    context
                                        .collection_kind,
                                collection_id =
                                    context
                                        .collection_id,
                                entry_id =
                                    context.entry_id,
                            }
                        )
                    end
                )
            end
        end,
    }

LibraryScreen =
    widgets.MenuScreen:new {
        show_back = true,
        title = "Playlists",

        create_ui = function(self)
            widgets.MenuScreen.create_ui(self)

            local content =
                create_content(self)
            local library, library_error =
                sync_library_view.current()
            local status_label =
                create_status(content, "")
            local list =
                create_list(content)

            if not library then
                status_label:set {
                    text =
                        library_error or
                        "Jellyfin library is unavailable",
                }

                local back_button =
                    add_button(
                        list,
                        "Back",
                        backstack.pop
                    )

                back_button:focus()
                return
            end

            status_label:set {
                text =
                    text(
                        library.user and
                            library.user.name,
                        "Jellyfin"
                    ) ..
                    "; " ..
                    pending_text(library),
            }

            local favorites =
                library.favorites

            local favorites_button =
                add_button(
                    list,
                    "Favorites (" ..
                        tostring(
                            #favorites.items
                        ) ..
                        ")",
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

            favorites_button:focus()

            for _, playlist in ipairs(
                library.playlists or {}
            ) do
                local playlist_copy =
                    playlist
                local playlist_id =
                    playlist_copy.local_id or
                    playlist_copy.id
                local label =
                    text(
                        playlist_copy.name,
                        "Playlist"
                    )

                if playlist_copy.pending then
                    label =
                        label .. " (pending)"
                end

                add_button(
                    list,
                    label ..
                        " (" ..
                        tostring(
                            #playlist_copy.items
                        ) ..
                        ")",
                    function()
                        backstack.push(
                            CollectionScreen:new {
                                title =
                                    text(
                                        playlist_copy.name,
                                        "Playlist"
                                    ),
                                collection_kind =
                                    "playlist",
                                collection_id =
                                    playlist_id,
                            }
                        )
                    end
                )
            end
        end,
    }

return LibraryScreen


package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
local backstack =
    require("firmware_backstack")

local image_data_calls = {}

lvgl.ImgData = function(path)
    image_data_calls[path] =
        (image_data_calls[path] or 0) + 1
    return "imgdata:" .. tostring(path)
end

require("mocks").install(lvgl)

package.loaded["backstack"] = backstack
package.preload["backstack"] = function()
    return backstack
end

package.loaded["sync_config"] = {
    status = function()
        return {
            configured = true,
            started = true,
            connected = true,
        }
    end,
}

package.loaded["sync_runtime"] = {
    last_library_result = function()
        return {ok = true}
    end,
    last_result = function()
        return {ok = true}
    end,
}

local starts = {}

package.loaded["jellyfin_playback"] = {
    play = function()
        return false
    end,
    play_queue = function(
        tracks,
        context,
        options
    )
        table.insert(
            starts,
            {
                tracks = tracks,
                context = context,
                options = options,
            }
        )
        return false
    end,
    current = function()
        return nil
    end,
}

package.loaded["jellyfin_now_playing"] = {
    new = function()
        return {}
    end,
}

package.loaded["jellyfin_track_action_sheet"] = {
    attach = function(owner)
        owner.track_action_sheet = {
            is_open = false,
            open = function()
            end,
            close = function()
            end,
        }
        return owner.track_action_sheet
    end,
}

local track_a = {
    id = "track-a",
    title = "Track A",
    artist = "Artist A",
    artist_key = "id:artist-a",
    album = "Album A",
}
local track_b = {
    id = "track-b",
    title = "Track B",
    artist = "Artist A",
    artist_key = "id:artist-a",
    album = "Album B",
}
local album_a = {
    key = "album-a",
    name = "Album A",
    tracks = {track_a},
    artwork = {
        background =
            "/album-a-background.png",
    },
}
local album_b = {
    key = "album-b",
    name = "Album B",
    tracks = {track_b},
}
local artist_a = {
    key = "id:artist-a",
    name = "Artist A",
    release_count = 2,
    releases = {album_a, album_b},
}

local local_library = {
    artists = {artist_a},
    albums = {album_a, album_b},
    tracks = {track_a, track_b},
    counts = {
        artists = 1,
        albums = 2,
        tracks = 2,
    },
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return local_library
    end,
}

local playlist_track = {
    id = "track-a",
    title = "Track A",
    artist = "Artist A",
    artist_id = "artist-a",
    playlist_entry_id = "entry-a",
}
local sync_library = {
    favorites = {
        name = "Favorites",
        items = {playlist_track},
    },
    playlists = {
        {
            id = "playlist-1",
            local_id = "playlist-1",
            name = "Playlist 1",
            items = {playlist_track},
        },
    },
}

package.loaded["sync_library_view"] = {
    current = function()
        return sync_library
    end,
}

for _, module_name in ipairs({
    "jellyfin_sort",
    "jellyfin_marquee",
    "jellyfin_scroll_indicator",
    "jellyfin_list_ui",
    "jellyfin_collection_playback",
    "jellyfin_virtual_list",
    "jellyfin_virtual_track_list",
    "jellyfin_local_library",
    "jellyfin_library",
}) do
    package.loaded[module_name] = nil
end

local local_module =
    dofile("lua/jellyfin_local_library.lua")

local album_screen =
    local_module.Album:new {
        title = "Album A",
        album_key = "album-a",
    }
album_screen:create_ui()
local album_background =
    album_screen:background_state()
assert(
    album_background.enabled == true and
        album_background.source ==
            "/album-a-background.png" and
        album_background.dimmer_opa == 118 and
        album_background.list_transparent ==
            true and
        image_data_calls[
            "/album-a-background.png"
        ] == 1,
    "individual album did not use its uniformly dimmed blurred artwork background"
)
assert(
    album_screen.play_row,
    "individual album did not receive the compact Play control"
)
assert(
    album_screen.play_row.play_icon and
        #album_screen.play_row.play_icon == 5 and
        album_screen.play_row.shuffle_icon and
        #album_screen.play_row.shuffle_icon == 11 and
        album_screen.play_row.icon_mode == "play",
    "compact Play control did not build its visible pixel Play and Shuffle icons"
)
album_screen.play_row.set_shuffle_preview(true)
assert(
    album_screen.play_row.icon_mode == "shuffle",
    "compact Play control did not switch to its held Shuffle icon"
)
album_screen.play_row.set_shuffle_preview(false)
assert(
    album_screen.play_row.icon_mode == "play",
    "compact Play control did not restore its Play icon after the held preview"
)
assert(
    album_screen.play_row.label == nil and
        album_screen.play_row.container and
        album_screen.initial_focus_object ==
            album_screen.play_row.object and
        album_screen.initial_scroll_anchor ==
            album_screen.play_row.object,
    "album Play control was not configured as the compact default selection"
)
album_screen:on_show()
assert(
    album_screen.focus_group:get_focused() ==
        album_screen.play_row.object,
    "individual album did not initially focus Play"
)
album_screen:on_hide()
assert(
    album_screen.play_row
            .defer_long_press_until_release ==
            true and
        type(
            album_screen.play_row
                .on_long_press_preview
        ) == "function",
    "album Play control did not expose held Shuffle preview behavior"
)

album_screen.play_row.on_click()
assert(
    starts[#starts].tracks ==
            album_a.tracks and
        starts[#starts].context
            .collection_kind ==
            "local_album" and
        starts[#starts].options.shuffle ==
            false,
    "album Play did not start its ordered track queue"
)

album_screen.play_row.on_long_press()
assert(
    starts[#starts].tracks ==
            album_a.tracks and
        starts[#starts].options.shuffle ==
            true,
    "album long hold did not start shuffled playback"
)

local artist_screen =
    local_module.Artist:new {
        title = "Artist A",
        artist_key = "id:artist-a",
    }
artist_screen:create_ui()
assert(
    artist_screen:background_state()
        .enabled == false,
    "artist release page unexpectedly inherited an album background"
)
assert(
    artist_screen.play_row == nil,
    "individual artist release pages should not expose Play"
)

local artists_screen =
    local_module.Artists:new()
artists_screen:create_ui()
assert(
    artists_screen.play_row == nil,
    "top-level Artists should not expose Play"
)

local albums_screen =
    local_module.Albums:new()
albums_screen:create_ui()
assert(
    albums_screen.play_row == nil,
    "top-level Albums should not expose Play"
)

local tracks_screen =
    local_module.Tracks:new()
tracks_screen:create_ui()
assert(
    tracks_screen.play_row == nil,
    "top-level Tracks should not expose Play"
)

local playlist_module =
    dofile("lua/jellyfin_library.lua")

local playlist_root =
    playlist_module:new()
playlist_root:create_ui()
assert(
    playlist_root.play_row == nil,
    "top-level Playlists should not expose Play"
)

local favorites_screen =
    playlist_module.Collection:new {
        title = "Favorites",
        collection_kind = "favorites",
    }
favorites_screen:create_ui()
assert(
    favorites_screen:background_state()
        .enabled == false,
    "Favorites unexpectedly received an album artwork background"
)
assert(
    favorites_screen.play_row and
        favorites_screen.play_row.label == nil and
        favorites_screen.initial_focus_object ==
            favorites_screen.play_row.object and
        favorites_screen.initial_scroll_anchor ==
            favorites_screen.play_row.object,
    "Favorites did not receive Play as its compact default selection"
)
favorites_screen:on_show()
assert(
    favorites_screen.focus_group:get_focused() ==
        favorites_screen.play_row.object,
    "Favorites did not initially focus Play"
)
local favorites_list_coords =
    favorites_screen.list:get_coords()
local favorites_sort_coords =
    favorites_screen.sort_row.object:get_coords()
local favorites_play_coords =
    favorites_screen.play_row.object:get_coords()
assert(
    favorites_sort_coords.y2 <
            favorites_list_coords.y1 and
        favorites_play_coords.y1 >=
            favorites_list_coords.y1 - 1 and
        favorites_play_coords.y1 <=
            favorites_list_coords.y1 + 1,
    "Favorites did not initially hide Sort above the focused Play control"
)
favorites_screen:on_hide()

favorites_screen.play_row.on_long_press()
assert(
    starts[#starts].context
            .collection_kind ==
            "favorites" and
        starts[#starts].options.shuffle ==
            true,
    "Favorites long hold did not start shuffled playback"
)

local playlist_screen =
    playlist_module.Collection:new {
        title = "Playlist 1",
        collection_kind = "playlist",
        collection_id = "playlist-1",
    }
playlist_screen:create_ui()
assert(
    playlist_screen:background_state()
        .enabled == false,
    "playlist unexpectedly received an album artwork background"
)
assert(
    playlist_screen.play_row and
        playlist_screen.play_row.label == nil and
        playlist_screen.initial_focus_object ==
            playlist_screen.play_row.object,
    "individual playlist did not receive Play as its compact default selection"
)
playlist_screen:on_show()
assert(
    playlist_screen.focus_group:get_focused() ==
        playlist_screen.play_row.object,
    "individual playlist did not initially focus Play"
)
playlist_screen:on_hide()

playlist_screen.play_row.on_click()
assert(
    starts[#starts].context
            .collection_kind ==
            "playlist" and
        starts[#starts].context
            .collection_id ==
            "playlist-1" and
        starts[#starts].options.shuffle ==
            false,
    "playlist Play did not retain playlist context"
)

print(
    "Only album, Favorites, and playlist track collections expose compact Play and Shuffle controls"
)
os.exit(0)

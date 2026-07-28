package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
local backstack = require("firmware_backstack")

lvgl.ImgData = function(path)
    return path
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

package.loaded["jellyfin_playback"] = {
    play = function()
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

local opened = {}

package.loaded["jellyfin_track_action_sheet"] = {
    attach = function(owner)
        local controller = {
            is_open = false,
        }

        function controller:open(
            track,
            context,
            item
        )
            table.insert(
                opened,
                {
                    track = track,
                    context = context,
                    item = item,
                }
            )
        end

        function controller:close()
            self.is_open = false
        end

        owner.track_action_sheet =
            controller

        return controller
    end,
}

local local_track = {
    id = "track-local",
    title = "Local Track",
    artist = "Local Artist",
    artist_key = "id:artist-local",
    album = "Local Album",
}

local local_library = {
    artists = {},
    albums = {
        {
            key = "album-local",
            name = "Local Album",
            tracks = {local_track},
        },
    },
    tracks = {local_track},
    counts = {
        artists = 0,
        albums = 1,
        tracks = 1,
    },
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return local_library
    end,
}

local playlist_track = {
    id = "track-playlist",
    title = "Playlist Track",
    artist = "Playlist Artist",
    artist_id = "artist-playlist",
    playlist_entry_id = "entry-1",
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
        title = "Local Album",
        album_key = "album-local",
    }

album_screen:create_ui()

assert(
    type(
        album_screen.media_rows[1]
            .on_long_press
    ) == "function",
    "album track row did not receive a long-press action"
)

album_screen.media_rows[1]
    .on_long_press()

assert(
    opened[#opened].context
            .collection_kind ==
        "local_album",
    "album long press did not retain local album context"
)

local tracks_screen =
    local_module.Tracks:new()

tracks_screen:create_ui()

local virtual_row =
    tracks_screen.virtual_track_list
        .pool[1]

assert(
    type(virtual_row.on_long_press) ==
        "function",
    "virtual Tracks row did not receive a long-press action"
)

virtual_row.on_long_press()

assert(
    opened[#opened].context
            .collection_kind ==
        "local_tracks",
    "Tracks long press did not retain Local Tracks context"
)

local playlist_module =
    dofile("lua/jellyfin_library.lua")

package.loaded["jellyfin_library"] =
    playlist_module

local playlist_root =
    playlist_module:new()

backstack.reset(playlist_root)
backstack.flush(12)

local favorites_row =
    playlist_root.playlist_rows[1]

favorites_row.on_click()
backstack.flush(12)

local favorites_screen =
    backstack.current()
local favorite_track_row =
    favorites_screen.media_rows[1]

assert(
    type(favorite_track_row.on_long_press) ==
        "function",
    "Favorites track row did not receive a long-press action"
)

favorite_track_row.on_long_press()

assert(
    opened[#opened].context
            .collection_kind ==
        "favorites",
    "Favorites long press did not retain Favorites context"
)

favorites_screen.go_back()
backstack.flush(12)

local playlist_row =
    playlist_root.playlist_rows[2]

playlist_row.on_click()
backstack.flush(12)

local playlist_screen =
    backstack.current()
local playlist_item_row =
    playlist_screen.media_rows[1]

playlist_item_row.on_long_press()

local playlist_open = opened[#opened]

assert(
    playlist_open.context
            .collection_kind ==
        "playlist" and
        playlist_open.context
            .collection_id ==
            "playlist-1" and
        playlist_open.context.entry_id ==
            "entry-1",
    "playlist long press did not preserve removal context"
)

print(
    "Album, Tracks, Favorites, and playlist rows expose the same long-hold action sheet"
)

os.exit(0)

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
    local_item = function(track)
        return track
    end,
}

package.loaded["jellyfin_now_playing"] = {
    new = function()
        return {}
    end,
}

package.loaded["jellyfin_track_menu"] = {
    new = function()
        return {}
    end,
}

local tracks = {}

for index = 1, 6 do
    tracks[index] = {
        id = string.format("track-%02d", index),
        title = string.format("Track %02d", index),
        artist = "Artist",
        album = "Album",
    }
end

local library = {
    favorites = {
        name = "Favorites",
        track_count = #tracks,
        items = tracks,
    },
    playlists = {
        {
            id = "playlist-01",
            local_id = "playlist-01",
            name = "Playlist 01",
            track_count = 1,
            items = {tracks[1]},
        },
        {
            id = "playlist-02",
            local_id = "playlist-02",
            name = "Playlist 02",
            track_count = 1,
            items = {tracks[2]},
        },
    },
}

package.loaded["sync_library_view"] = {
    current = function()
        return library
    end,
}

for _, module_name in ipairs({
    "jellyfin_sort",
    "jellyfin_marquee",
    "jellyfin_scroll_indicator",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_virtual_track_list",
    "jellyfin_library",
}) do
    package.loaded[module_name] = nil
end

local library_module =
    dofile("lua/jellyfin_library.lua")

package.loaded["jellyfin_library"] =
    library_module

local playlist_root =
    library_module:new()

backstack.reset(playlist_root)
backstack.flush(12)

local favorites_row =
    playlist_root.playlist_rows[1]

assert(
    favorites_row.selection_id ==
        "special:favorites",
    "Favorites needs a stable selection id"
)

backstack.focus(favorites_row.object)
backstack.flush(3)

assert(
    playlist_root.selected_item_id ==
        "special:favorites",
    "Focusing Favorites did not retain its selection"
)

favorites_row.on_click()
backstack.flush(12)

local favorites_screen =
    backstack.current()

backstack.focus(
    favorites_screen.media_rows[
        #favorites_screen.media_rows
    ].object
)
backstack.flush(4)

favorites_screen.go_back()
backstack.flush(12)

assert(
    backstack.current() == playlist_root,
    "Back did not return to Playlists"
)
assert(
    playlist_root.selected_item_id ==
        "special:favorites",
    "Favorites selection was replaced while its child screen was open"
)
assert(
    backstack.is_focused(
        favorites_row.object
    ),
    "Returning from Favorites focused the next playlist"
)

print(
    "Favorites selection restores after scrolling its collection and returning"
)

os.exit(0)

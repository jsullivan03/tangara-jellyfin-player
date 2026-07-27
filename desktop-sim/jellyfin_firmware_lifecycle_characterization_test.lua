package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local backstack =
    require("firmware_backstack")

package.loaded["backstack"] =
    backstack
package.preload["backstack"] =
    function()
        return backstack
    end

local root =
    "/tmp/tangara-firmware-lifecycle"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

package.loaded["device"] = nil
package.preload["device"] =
    function()
        return {
            id = function()
                return "firmware-lifecycle-test"
            end,
            storage_root = function()
                return root
            end,
        }
    end

package.loaded["sync_config"] = {
    status = function()
        return {
            configured = true,
            started = true,
            connected = true,
            server_url =
                "http://localhost",
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

local tracks = {}
local albums = {}
local artists = {}

for index = 1, 7 do
    local track = {
        id = "track-" .. index,
        jellyfin_id = "track-" .. index,
        title = "Track " .. index,
        artist = "Artist " .. index,
        album = "Album " .. index,
        date_created = string.format(
            "2026-01-%02dT00:00:00Z",
            index
        ),
    }

    local album = {
        key = "album-" .. index,
        id = "album-" .. index,
        name = "Album " .. index,
        artist = "Artist " .. index,
        track_count = 1,
        tracks = {track},
        date_created = track.date_created,
        artwork = {
            thumbnail =
                "//lua/img/favorites_playlist.png",
        },
    }

    local artist = {
        key = "artist-" .. index,
        name = "Artist " .. index,
        release_count = 1,
        track_count = 1,
        releases = {album},
        date_created = track.date_created,
    }

    table.insert(tracks, track)
    table.insert(albums, album)
    table.insert(artists, artist)
end

local local_library = {
    artists = artists,
    albums = albums,
    tracks = tracks,
    counts = {
        artists = #artists,
        albums = #albums,
        tracks = #tracks,
    },
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return local_library
    end,
}

package.loaded["sync_library_view"] = {
    current = function()
        return {
            favorites = {
                name = "Favorites",
                items = {},
            },
            playlists = {},
        }
    end,
}

package.loaded["jellyfin_playback"] = {
    play = function()
        return true
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

package.loaded["jellyfin_track_menu"] = {
    new = function()
        return {}
    end,
}

package.loaded["jellyfin_sort"] = nil
package.loaded["jellyfin_marquee"] = nil
package.loaded["jellyfin_list_ui"] = nil
package.loaded["jellyfin_local_library"] = nil

local local_module =
    dofile("lua/jellyfin_local_library.lua")

package.loaded["jellyfin_local_library"] =
    local_module

local artist_screen =
    local_module.Artists:new()

backstack.reset(artist_screen)
backstack.flush(10)

assert(backstack.current() == artist_screen)
assert(artist_screen.media_rows[1])
assert(backstack.is_focused(artist_screen.first_row))

local list_coordinates =
    artist_screen.list:get_coords()
local sort_coordinates =
    artist_screen.sort_row.object:get_coords()
local first_coordinates =
    artist_screen.first_row:get_coords()

local fresh_sort_hidden =
    sort_coordinates.y2 <
        list_coordinates.y1

local first_row_at_top =
    first_coordinates.y1 >=
        list_coordinates.y1 - 2 and
    first_coordinates.y1 <=
        list_coordinates.y1 + 1

assert(
    fresh_sort_hidden and
        first_row_at_top,
    "Fresh entry did not place Sort above the viewport with the first media row at the top"
)

assert(
    artist_screen.screen_loaded == false,
    "The Lua child root unexpectedly received the native screen-loaded event"
)

local middle_row =
    artist_screen.media_rows[4]

backstack.focus(middle_row.object)
backstack.flush(4)

assert(backstack.is_focused(middle_row.object))

middle_row.on_click()
backstack.flush(10)

local artist_detail =
    backstack.current()

assert(artist_detail ~= artist_screen)
assert(artist_detail.sort_row == nil)
assert(artist_detail.open_sort_menu == nil)

backstack.pop()
backstack.flush(10)

assert(backstack.current() == artist_screen)

local middle_restored =
    backstack.is_focused(middle_row.object)
local first_restored =
    backstack.is_focused(
        artist_screen.first_row
    )
local default_group =
    lvgl.group.get_default()

assert(
    artist_screen.focus_group ==
        default_group,
    "The restored screen did not regain its own focus group before on_show"
)

assert(
    middle_restored and
        not first_restored,
    "Returning from artist detail did not restore the selected middle artist"
)

assert(
    artist_screen.selected_item_id ==
        "artist-4",
    "The Artists screen did not retain the selected artist ID"
)

print(
    "Firmware-parity Local Library characterization passed"
)
print(
    string.format(
        "FIXED fresh-entry Sort placement: sort=%d..%d list=%d..%d first=%d..%d",
        sort_coordinates.y1,
        sort_coordinates.y2,
        list_coordinates.y1,
        list_coordinates.y2,
        first_coordinates.y1,
        first_coordinates.y2
    )
)
print(
    "FIXED native pop ordering: the parent root and focus group are active before on_show"
)
print(
    "FIXED selection restoration: returning from artist detail restores the selected middle artist"
)

os.execute("rm -rf " .. root)
os.exit(0)

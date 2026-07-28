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

local case_name =
    os.getenv("TANGARA_EAGER_INDICATOR_CASE") or
    "artists-long"

local valid_cases = {
    ["artists-long"] = true,
    ["artists-short"] = true,
    ["playlists-long"] = true,
    ["playlists-short"] = true,
    ["playlist-tracks-long"] = true,
    ["playlist-tracks-short"] = true,
}

assert(
    valid_cases[case_name],
    "unknown eager indicator case: " .. case_name
)

local root =
    "/tmp/tangara-eager-scroll-indicator-" ..
    case_name

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

package.loaded["device"] = nil
package.preload["device"] = function()
    return {
        id = function()
            return "eager-scroll-indicator-test"
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
            server_url = "http://localhost",
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

package.loaded["jellyfin_track_menu"] = {
    new = function()
        return {}
    end,
}

local tracks = {}
local albums = {}
local artists = {}

for index = 1, 6 do
    local track = {
        id = string.format("track-%02d", index),
        jellyfin_id =
            string.format("track-%02d", index),
        title = string.format("Track %02d", index),
        artist = string.format("Artist %02d", index),
        album = string.format("Album %02d", index),
    }
    local album = {
        key = string.format("album-%02d", index),
        id = string.format("album-%02d", index),
        name = string.format("Album %02d", index),
        artist = string.format("Artist %02d", index),
        track_count = 1,
        tracks = {track},
        artwork = {
            thumbnail =
                "//lua/img/playlist_placeholder.png",
        },
    }

    tracks[index] = track
    albums[index] = album
    artists[index] = {
        key = string.format("artist-%02d", index),
        name = string.format("Artist %02d", index),
        release_count = 1,
        track_count = 1,
        releases = {album},
    }
end

local artist_count =
    case_name == "artists-short" and 4 or 6
local local_artists = {}

for index = 1, artist_count do
    local_artists[index] = artists[index]
end

local local_library = {
    artists = local_artists,
    albums = albums,
    tracks = tracks,
    counts = {
        artists = #local_artists,
        albums = #albums,
        tracks = #tracks,
    },
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return local_library
    end,
}

local all_playlists = {}

for index = 1, 5 do
    all_playlists[index] = {
        id = string.format("playlist-%02d", index),
        local_id =
            string.format("playlist-%02d", index),
        name = string.format("Playlist %02d", index),
        track_count = 1,
        items = {tracks[index]},
        artwork = {
            cover =
                "//lua/img/playlist_placeholder.png",
        },
    }
end

if case_name == "playlist-tracks-long" then
    all_playlists[1].items = {
        tracks[1],
        tracks[2],
        tracks[3],
        tracks[4],
        tracks[5],
    }
    all_playlists[1].track_count = 5
elseif case_name == "playlist-tracks-short" then
    all_playlists[1].items = {
        tracks[1],
        tracks[2],
        tracks[3],
    }
    all_playlists[1].track_count = 3
end

local playlist_count =
    case_name == "playlists-short" and 2 or 5
local playlists = {}

for index = 1, playlist_count do
    playlists[index] = all_playlists[index]
end

local synced_library = {
    favorites = {
        name = "Favorites",
        track_count = 0,
        items = {},
    },
    playlists = playlists,
}

package.loaded["sync_library_view"] = {
    current = function()
        return synced_library
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
    "jellyfin_local_library",
}) do
    package.loaded[module_name] = nil
end

local function assert_thumb_only(
    indicator,
    label
)
    assert(indicator, label .. " indicator missing")
    assert(
        indicator.track == nil,
        label .. " indicator created a background track"
    )
    assert(
        indicator.width == 2 and
            indicator.thumb_color == "#FFFFFF" and
            indicator.thumb_opacity == 255,
        label ..
            " indicator is not a solid two-pixel white thumb"
    )
end

local function verify_long_screen(
    screen,
    label,
    visible_items,
    item_count
)
    backstack.reset(screen)
    backstack.flush(12)

    local indicator =
        screen.scroll_indicator

    assert_thumb_only(indicator, label)
    assert(
        indicator.visible_items == visible_items,
        label .. " visible-row count is wrong"
    )
    assert(
        indicator.item_count == item_count,
        label .. " logical item count is wrong"
    )
    assert(
        indicator.hidden == false,
        label .. " should show an indicator"
    )
    assert(
        indicator.thumb_y == 0,
        label .. " indicator should start at the top"
    )

    local group =
        screen.focus_group or
        lvgl.group.get_default()

    for _ = 1, item_count - 1 do
        group:focus_next()
        backstack.flush(2)
    end

    assert(
        indicator.thumb_y ==
            indicator.height -
                indicator.thumb_height,
        label ..
            " indicator did not reach the bottom"
    )
end

local function verify_short_screen(
    screen,
    label,
    visible_items,
    item_count
)
    backstack.reset(screen)
    backstack.flush(12)

    local indicator =
        screen.scroll_indicator

    assert_thumb_only(indicator, label)
    assert(
        indicator.visible_items == visible_items,
        label .. " visible-row count is wrong"
    )
    assert(
        indicator.item_count == item_count,
        label .. " logical item count is wrong"
    )
    assert(
        indicator.hidden == true,
        label ..
            " fits without scrolling and should hide the indicator"
    )
end

if case_name == "artists-long" or
    case_name == "artists-short" then
    local local_module =
        dofile("lua/jellyfin_local_library.lua")

    package.loaded["jellyfin_local_library"] =
        local_module

    local artists_screen =
        local_module.Artists:new()

    if case_name == "artists-long" then
        verify_long_screen(
            artists_screen,
            "Artists",
            4,
            6
        )
    else
        verify_short_screen(
            artists_screen,
            "Artists",
            4,
            4
        )
    end
else
    local playlist_module =
        dofile("lua/jellyfin_library.lua")

    package.loaded["jellyfin_library"] =
        playlist_module

    if case_name == "playlists-long" or
        case_name == "playlists-short" then
        local playlists_screen =
            playlist_module:new()

        if case_name == "playlists-long" then
            verify_long_screen(
                playlists_screen,
                "Playlists",
                3,
                6
            )
        else
            verify_short_screen(
                playlists_screen,
                "Playlists",
                3,
                3
            )
        end
    else
        local collection_screen =
            playlist_module.Collection:new {
                title = "Playlist 01",
                collection_kind = "playlist",
                collection_id = "playlist-01",
            }

        if case_name ==
                "playlist-tracks-long" then
            verify_long_screen(
                collection_screen,
                "Playlist tracks",
                3,
                5
            )
        else
            verify_short_screen(
                collection_screen,
                "Playlist tracks",
                3,
                3
            )
        end
    end
end

os.execute("rm -rf " .. root)

print(
    "Eager thumb-only indicator case passed: " ..
    case_name
)

os.exit(0)

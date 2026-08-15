package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
local backstack =
    require("firmware_backstack")

lvgl.ImgData = function(path)
    return path
end

_G.tangara_sim_enable_encoder_handler = true
_G.tangara_sim_set_encoder_mode =
    function()
    end

require("mocks").install(lvgl)

package.loaded["backstack"] = backstack
package.preload["backstack"] = function()
    return backstack
end

local root =
    "/tmp/tangara-universal-fixed-viewport"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

package.loaded["device"] = nil
package.preload["device"] = function()
    return {
        id = function()
            return "universal-fixed-viewport-test"
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

local albums = {}
local artists = {}
local all_tracks = {}

local function make_album(
    artist_index,
    album_index,
    track_count
)
    local album_key = string.format(
        "artist-%02d-album-%02d",
        artist_index,
        album_index
    )
    local album_tracks = {}

    for track_index = 1, track_count do
        local track = {
            id = string.format(
                "%s-track-%02d",
                album_key,
                track_index
            ),
            jellyfin_id = string.format(
                "%s-track-%02d",
                album_key,
                track_index
            ),
            title = string.format(
                "Track %02d",
                track_index
            ),
            artist = string.format(
                "Artist %02d",
                artist_index
            ),
            album = string.format(
                "Album %02d",
                album_index
            ),
            artwork = {
                thumbnail =
                    "//lua/img/playlist_placeholder.png",
            },
        }

        album_tracks[#album_tracks + 1] =
            track
        all_tracks[#all_tracks + 1] = track
    end

    local album = {
        key = album_key,
        id = album_key,
        name = string.format(
            "Album %02d",
            album_index
        ),
        artist = string.format(
            "Artist %02d",
            artist_index
        ),
        track_count = track_count,
        tracks = album_tracks,
        artwork = {
            thumbnail =
                "//lua/img/playlist_placeholder.png",
        },
    }

    albums[#albums + 1] = album
    return album
end

for artist_index = 1, 12 do
    local release_count =
        artist_index == 12 and 2 or 12
    local releases = {}

    for album_index = 1, release_count do
        releases[#releases + 1] =
            make_album(
                artist_index,
                album_index,
                artist_index == 1 and
                    album_index == 1 and
                    20 or 1
            )
    end

    artists[#artists + 1] = {
        key = string.format(
            "artist-%02d",
            artist_index
        ),
        name = string.format(
            "Artist %02d",
            artist_index
        ),
        release_count = #releases,
        releases = releases,
    }
end

local library = {
    artists = artists,
    albums = albums,
    tracks = all_tracks,
    counts = {
        artists = #artists,
        albums = #albums,
        tracks = #all_tracks,
    },
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return library
    end,
}

for _, module_name in ipairs({
    "jellyfin_sort",
    "jellyfin_marquee",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_virtual_track_list",
    "jellyfin_local_library",
}) do
    package.loaded[module_name] = nil
end

local local_library =
    dofile("lua/jellyfin_local_library.lua")

local function assert_native_motion(
    controller,
    logical_count,
    label
)
    assert(controller, label .. ": missing controller")
    assert(
        controller:logical_count() ==
            logical_count,
        label .. ": wrong logical count"
    )
    assert(
        controller.fixed_viewport == false and
            controller.motion_layer == nil and
            controller.continuous_input_active ==
                true,
        label .. ": did not use the shared native viewport owner"
    )
    assert(
        controller:pool_count() ==
            math.min(
                controller.pool_limit,
                logical_count
            ),
        label .. ": did not keep its bounded reusable row pool"
    )

    for _, model in ipairs(controller.pool) do
        assert(
            model.object:get_parent() ==
                controller.canvas,
            label ..
                ": a reusable row escaped the native virtual canvas"
        )
    end
end

local artists_screen =
    local_library.Artists:new()
backstack.reset(artists_screen)
backstack.flush(10)
assert_native_motion(
    artists_screen.virtual_artist_list,
    #artists,
    "local Artists"
)

local artist_screen =
    local_library.Artist:new {
        title = artists[1].name,
        artist_key = artists[1].key,
    }
backstack.reset(artist_screen)
backstack.flush(10)
assert_native_motion(
    artist_screen.virtual_release_list,
    #artists[1].releases,
    "local artist releases"
)

local album_screen =
    local_library.Album:new {
        title = albums[1].name,
        album_key = albums[1].key,
    }
backstack.reset(album_screen)
backstack.flush(10)
assert_native_motion(
    album_screen.virtual_track_list,
    #albums[1].tracks,
    "local album tracks"
)

local short_artist = artists[12]
local short_artist_screen =
    local_library.Artist:new {
        title = short_artist.name,
        artist_key = short_artist.key,
    }
backstack.reset(short_artist_screen)
backstack.flush(10)

assert(
    short_artist_screen
        .virtual_release_list
        .fixed_viewport == false,
    "a two-release artist should retain the compact ordinary list"
)
assert(
    short_artist_screen
        .virtual_release_list
        :pool_count() == 2,
    "a short artist list created unnecessary pooled rows"
)

os.execute("rm -rf " .. root)

print(
    "Local Artists, releases, and album tracks share one native viewport owner while keeping bounded row pools"
)

os.exit(0)

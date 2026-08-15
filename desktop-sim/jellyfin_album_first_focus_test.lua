package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
local firmware_backstack =
    require("firmware_backstack")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

package.loaded["backstack"] =
    firmware_backstack
package.preload["backstack"] =
    function()
        return firmware_backstack
    end

local screen = require("screen")
local root =
    "/tmp/tangara-local-album-np-resume"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

package.loaded["device"] = nil
package.preload["device"] = function()
    return {
        id = function()
            return "local-album-np-resume"
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
    content_generation = function()
        return 0
    end,
    state_generation = function()
        return 0
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

local played_track = nil
local queue_tracks = {}

package.loaded["jellyfin_playback"] = {
    play = function(track, context)
        played_track = track
        queue_tracks =
            context and
            context.queue_tracks or
            {track}
        return true
    end,
    play_queue = function(tracks)
        queue_tracks = tracks or {}
        played_track = queue_tracks[1]
        return true
    end,
    current = function()
        return played_track and {
            track = played_track,
            item = played_track,
            generation = 1,
            queue = {
                items = queue_tracks,
                position = 1,
            },
        } or nil
    end,
    local_item = function(track)
        return track
    end,
}

local NowPlaying =
    screen:new {
        create_ui = function(self)
            self.root =
                lvgl.Object(nil, {
                    w = 160,
                    h = 128,
                    pad_all = 0,
                    border_width = 0,
                })

            self.button =
                self.root:Button {
                    x = 20,
                    y = 48,
                    w = 120,
                    h = 28,
                }
        end,
        on_show = function(self)
            require("jellyfin_playback_session")
                .set_now_playing_visible(true)
            lvgl.group.get_default()
                :add_obj(self.button)
            lvgl.group.focus_obj(
                self.button
            )
        end,
        on_hide = function(self)
            require("jellyfin_playback_session")
                .set_now_playing_visible(false)
        end,
    }

package.loaded["jellyfin_now_playing"] = {
    new = function()
        return NowPlaying:new()
    end,
}

local tracks = {}

for index = 1, 40 do
    tracks[index] = {
        id = string.format(
            "album-track-%03d",
            index
        ),
        jellyfin_id = string.format(
            "album-track-%03d",
            index
        ),
        title = string.format(
            "Track %03d",
            index
        ),
        artist = "Resume Artist",
        album = "Resume Album",
        album_id = "resume-album",
        local_path =
            "/tmp/album-track-" ..
            tostring(index) ..
            ".mp3",
        artwork = {
            thumbnail =
                "//lua/img/playlist_placeholder.png",
            background =
                "//lua/img/background_placeholder.png",
        },
    }
end

local album = {
    key = "id:resume-album",
    id = "resume-album",
    name = "Resume Album",
    tracks = tracks,
    artwork = tracks[1].artwork,
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {
            artists = {},
            albums = {album},
            tracks = tracks,
            counts = {
                artists = 0,
                albums = 1,
                tracks = #tracks,
            },
        }
    end,
}

for _, module_name in ipairs({
    "jellyfin_sort",
    "jellyfin_marquee",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_virtual_track_list",
    "jellyfin_mini_player",
    "jellyfin_collection_playback",
    "jellyfin_track_action_sheet",
    "jellyfin_local_artwork",
    "jellyfin_album_identity",
    "jellyfin_playback_session",
    "jellyfin_local_library",
}) do
    package.loaded[module_name] = nil
end

local local_library =
    dofile(
        "lua/jellyfin_local_library.lua"
    )
local backstack = firmware_backstack

-- Exercise the same production entry path as live: mount Local Albums, bind
-- its virtual album row, activate that row, and allow the child screen's
-- native load/focus lifecycle to settle.
local albums_screen =
    local_library.Albums:new()

backstack.reset(albums_screen)
backstack.flush(10)

local album_row =
    assert(
        albums_screen.virtual_album_list:
            continuous_select(1, false),
        "Local Albums did not bind the production album row"
    )

album_row.on_click()
backstack.flush(14)

local album_screen =
    assert(
        backstack.current(),
        "album activation did not push a child screen"
    )


local virtual =
    assert(
        album_screen.virtual_track_list,
        "Local album must use a virtual track list"
    )

assert(
    album_screen.play_row ~= nil,
    "Local album must expose the Play control"
)
assert(
    album_screen.selected_item_id == "control:play",
    "Fresh album entry did not retain control:play as the logical selection"
)
assert(
    backstack.is_focused(
        album_screen.play_row.object
    ),
    "Fresh album entry did not focus Play after production load lifecycle"
)

local list_coordinates =
    album_screen.list:get_coords()
local play_coordinates =
    album_screen.play_row.object:get_coords()

assert(
    play_coordinates.y1 >= list_coordinates.y1 and
        play_coordinates.y2 <= list_coordinates.y2,
    "Fresh album entry focused Play but left it outside the visible list viewport"
)

print("Production Local album first-entry Play focus passed")
os.exit(0)

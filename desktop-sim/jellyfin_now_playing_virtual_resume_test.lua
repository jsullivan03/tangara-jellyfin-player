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

_G.tangara_sim_enable_encoder_handler = true
_G.tangara_sim_set_encoder_mode =
    function()
    end

local simulator =
    require("mocks").install(lvgl)

local backstack_kind =
    os.getenv(
        "TANGARA_RESUME_BACKSTACK"
    ) or "firmware"
local backstack =
    backstack_kind == "simulator" and
    simulator.backstack or
    firmware_backstack

assert(
    backstack_kind == "firmware" or
        backstack_kind == "simulator",
    "unknown resume backstack: " ..
        tostring(backstack_kind)
)

local screen = require("screen")
local track_identity =
    require("jellyfin_track_identity")

package.loaded["backstack"] = backstack
package.preload["backstack"] = function()
    return backstack
end

local root =
    "/tmp/tangara-now-playing-virtual-resume"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

package.loaded["device"] = nil
package.preload["device"] = function()
    return {
        id = function()
            return "now-playing-resume-test"
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

local played_track = nil

package.loaded["jellyfin_playback"] = {
    play = function(track)
        played_track = track
        return true
    end,
    current = function()
        return played_track
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
            lvgl.group.get_default()
                :add_obj(self.button)
            lvgl.group.focus_obj(
                self.button
            )
        end,
    }

package.loaded["jellyfin_now_playing"] = {
    new = function()
        return NowPlaying:new()
    end,
}

local tracks = {}

for index = 1, 80 do
    tracks[index] = {
        id = string.format(
            "track-%03d",
            index
        ),
        jellyfin_id = string.format(
            "track-%03d",
            index
        ),
        title = string.format(
            "Track %03d",
            index
        ),
        artist = "Resume Artist",
        album = "Resume Album",
        artwork = {
            thumbnail =
                "//lua/img/playlist_placeholder.png",
        },
    }
end

local library = {
    artists = {},
    albums = {},
    tracks = tracks,
    counts = {
        artists = 0,
        albums = 0,
        tracks = #tracks,
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
    dofile(
        "lua/jellyfin_local_library.lua"
    )

local tracks_screen =
    local_library.Tracks:new()

backstack.reset(tracks_screen)
backstack.flush(10)

local virtual =
    assert(
        tracks_screen.virtual_track_list
    )
local starting_model =
    assert(
        virtual:continuous_select(
            25,
            false
        )
    )
backstack.flush(2)

local selected_id =
    assert(tracks_screen.selected_item_id)
local selected_index =
    virtual.selected_index

for cycle = 1, 5 do
    local selected_model =
        assert(virtual:selected_model())
    local list_coordinates =
        tracks_screen.list:get_coords()
    local row_coordinates =
        selected_model.object:get_coords()
    local selected_offset =
        row_coordinates.y1 -
        list_coordinates.y1

    selected_model.on_click()
    backstack.flush(12)

    assert(
        backstack.current() ~= tracks_screen,
        "Now Playing was not pushed"
    )

    backstack.pop()

    -- on_show is synchronous with pop, before firmware_backstack loads or
    -- renders the restored LVGL screen.
    assert(
        backstack.current() == tracks_screen,
        "Back did not restore the existing Local screen"
    )
    assert(
        tracks_screen.selected_item_id ==
            selected_id and
        virtual.selected_index ==
            selected_index,
        "Back changed the logical selection"
    )
    local restored_model =
        assert(virtual:selected_model())
    assert(
        backstack.is_focused(
            restored_model.object
        ),
        "Back did not restore row focus"
    )
    list_coordinates =
        tracks_screen.list:get_coords()
    row_coordinates =
        restored_model.object:get_coords()
    assert(
        row_coordinates.y1 -
            list_coordinates.y1 ==
            selected_offset,
        "Back changed the selected row viewport anchor"
    )

    backstack.flush(12)
    assert(
        tracks_screen.selected_item_id ==
            selected_id and
        virtual.selected_index ==
            selected_index and
        backstack.is_focused(
            assert(virtual:selected_model()).object
        ),
        "settled Back changed restored Local state"
    )
end

print(
    "Now Playing Back restores the native Local viewport and canonical focus (" ..
        backstack_kind .. ")"
)
os.exit(0)

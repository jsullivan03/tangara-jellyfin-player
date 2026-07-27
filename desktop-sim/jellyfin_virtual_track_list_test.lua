package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
local metrics = require("sim_metrics")
local backstack = require("firmware_backstack")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local screen = require("screen")

package.loaded["backstack"] = backstack
package.preload["backstack"] = function()
    return backstack
end

local root =
    "/tmp/tangara-virtual-track-list"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

package.loaded["device"] = nil
package.preload["device"] = function()
    return {
        id = function()
            return "virtual-track-list-test"
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

for index = 1, 100 do
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
        artist = string.format(
            "Artist %03d",
            index
        ),
        album = string.format(
            "Album %03d",
            index
        ),
        date_created = string.format(
            "2026-%02d-%02dT00:00:00Z",
            ((index - 1) % 12) + 1,
            ((index - 1) % 28) + 1
        ),
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
    "jellyfin_virtual_track_list",
    "jellyfin_local_library",
}) do
    package.loaded[module_name] = nil
end

local local_library =
    dofile(
        "lua/jellyfin_local_library.lua"
    )

package.loaded["jellyfin_local_library"] =
    local_library

local tracks_screen =
    local_library.Tracks:new()

backstack.reset(tracks_screen)
backstack.flush(12)

local virtual =
    assert(
        tracks_screen.virtual_track_list
    )

assert(
    virtual:logical_count() == 100,
    "virtual list did not retain all 100 logical tracks"
)
assert(
    virtual:pool_count() == 7,
    "virtual list did not create exactly seven reusable rows"
)
assert(
    #tracks_screen.media_rows == 7,
    "Tracks screen exposed an unexpected media-row count"
)
local initial_id =
    assert(
        virtual.items[1].id,
        "first sorted track did not expose an ID"
    )

assert(
    tracks_screen.selected_item_id ==
        initial_id,
    "initial selected ID should match the first sorted track " ..
        tostring(initial_id) ..
        ", got " ..
        tostring(tracks_screen.selected_item_id)
)
assert(
    virtual.selected_index == 1,
    "initial virtual index should be 1, got " ..
        tostring(virtual.selected_index)
)

local initial_metrics =
    metrics.snapshot()

local list_coordinates =
    tracks_screen.list:get_coords()
local sort_coordinates =
    tracks_screen.sort_row.object
        :get_coords()
local first_coordinates =
    tracks_screen.first_row:get_coords()

assert(
    sort_coordinates.y2 <
        list_coordinates.y1
)
assert(
    first_coordinates.y1 >=
        list_coordinates.y1 - 2 and
    first_coordinates.y1 <=
        list_coordinates.y1 + 1
)

local group =
    assert(tracks_screen.focus_group)

for _ = 1, 24 do
    group:focus_next()
    backstack.flush(2)
end

assert(
    virtual.selected_index == 25,
    "24 forward moves should select logical index 25, got " ..
        tostring(virtual.selected_index)
)
local index_25_id =
    assert(
        virtual.items[25].id,
        "sorted track at index 25 did not expose an ID"
    )

assert(
    tracks_screen.selected_item_id ==
        index_25_id,
    "24 forward moves should select sorted index 25 (" ..
        tostring(index_25_id) ..
        "), got " ..
        tostring(tracks_screen.selected_item_id)
)

local selected_model =
    assert(virtual:selected_model())

assert(
    group:get_focused() ==
        selected_model.object
)

selected_model.on_click()

assert(
    played_track,
    "activating a recycled row did not call playback"
)
assert(
    played_track.id == index_25_id,
    "recycled row activated the wrong track: expected " ..
        tostring(index_25_id) ..
        ", got " ..
        tostring(played_track.id)
)

local navigation_metrics =
    metrics.snapshot()

assert(
    navigation_metrics.active_objects ==
        initial_metrics.active_objects
)

for _ = 1, 10 do
    group:focus_prev()
    backstack.flush(2)
end

assert(
    virtual.selected_index == 15,
    "10 backward moves should select logical index 15, got " ..
        tostring(virtual.selected_index)
)
local index_15_id =
    assert(
        virtual.items[15].id,
        "sorted track at index 15 did not expose an ID"
    )

assert(
    tracks_screen.selected_item_id ==
        index_15_id,
    "10 backward moves should select sorted index 15 (" ..
        tostring(index_15_id) ..
        "), got " ..
        tostring(tracks_screen.selected_item_id)
)

local child =
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
                    x = 4,
                    y = 4,
                    w = 80,
                    h = 24,
                }

            lvgl.group.get_default()
                :add_obj(self.button)
            lvgl.group.focus_obj(
                self.button
            )
        end,
    }

backstack.push(child)
backstack.flush(8)
backstack.pop()
backstack.flush(10)

assert(backstack.current() == tracks_screen)
assert(
    virtual.selected_index == 15,
    "10 backward moves should select logical index 15, got " ..
        tostring(virtual.selected_index)
)
assert(
    tracks_screen.selected_item_id ==
        index_15_id,
    "child return should restore sorted index 15 ID " ..
        tostring(index_15_id) ..
        ", got " ..
        tostring(tracks_screen.selected_item_id)
)

selected_model =
    assert(virtual:selected_model())

assert(
    tracks_screen.focus_group
        :get_focused() ==
        selected_model.object
)

tracks_screen.open_sort_menu()
tracks_screen.sort_select("alpha")
tracks_screen.sort_options.on_toggle("alpha")
tracks_screen.close_sort_menu(false)
backstack.flush(8)

assert(
    virtual:pool_count() == 7,
    "sorting changed the virtual row-pool size"
)
assert(
    #tracks_screen.media_rows == 7,
    "sorting changed the Tracks screen media-row count"
)
assert(
    virtual.selected_index == 1,
    "applying a new sort should reset logical selection to 1, got " ..
        tostring(virtual.selected_index)
)
assert(
    virtual.window_start == 1,
    "applying a new sort should reset the virtual window to 1, got " ..
        tostring(virtual.window_start)
)
local sorted_first_id =
    assert(
        virtual.items[1].id,
        "first track after sorting did not expose an ID"
    )
assert(
    tracks_screen.selected_item_id ==
        sorted_first_id,
    "applying a new sort should select the first sorted track " ..
        tostring(sorted_first_id) ..
        ", got " ..
        tostring(tracks_screen.selected_item_id)
)
assert(
    virtual.pool[1].virtual_index == 1,
    "first physical row should bind to logical track 1 after sorting"
)
assert(
    tracks_screen.focus_group:get_focused() ==
        tracks_screen.sort_row.object,
    "closing Sort should keep focus on the Sort row"
)

tracks_screen.focus_group:focus_next()
backstack.flush(2)

assert(
    virtual.selected_index == 1,
    "first move below Sort skipped logical track 1 and selected " ..
        tostring(virtual.selected_index)
)
assert(
    tracks_screen.selected_item_id ==
        sorted_first_id,
    "first move below Sort selected the wrong track"
)

tracks_screen.focus_group:focus_next()
backstack.flush(2)

assert(
    virtual.selected_index == 2,
    "second move below Sort should select logical track 2, got " ..
        tostring(virtual.selected_index)
)
local sorted_second_id =
    assert(
        virtual.items[2].id,
        "second sorted track did not expose an ID"
    )
assert(
    tracks_screen.selected_item_id ==
        sorted_second_id,
    "second move below Sort selected the wrong track"
)

backstack.push(child)
backstack.flush(8)
backstack.pop()
backstack.flush(10)

assert(
    tracks_screen.selected_item_id ==
        sorted_second_id,
    "post-sort child return changed the selected sorted track"
)
assert(
    tracks_screen.focus_group
        :get_focused() ==
        virtual:selected_model().object,
    "post-sort child return did not focus the selected virtual row"
)

os.execute("rm -rf " .. root)

print(
    "Virtual Tracks row recycling, navigation, activation, sorting, and restoration passed"
)

os.exit(0)

package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
local jellyfin_theme =
    require("jellyfin_theme")
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
assert(
    virtual.canvas ==
        tracks_screen.virtual_row_canvas,
    "Tracks screen did not expose the virtual row canvas"
)
assert(
    virtual.canvas:get_parent() ==
        tracks_screen.list,
    "virtual row canvas is not attached to the Tracks list"
)
for _, model in ipairs(virtual.pool) do
    assert(
        model.object:get_parent() ==
            virtual.canvas,
        "a reusable Tracks row is not parented to the virtual canvas"
    )
end
local initial_row_one_coordinates =
    virtual.pool[1].object:get_coords()
local initial_row_two_coordinates =
    virtual.pool[2].object:get_coords()
assert(
    initial_row_two_coordinates.y1 -
        initial_row_one_coordinates.y1 ==
        virtual.row_stride,
    "virtual Tracks rows are not independently positioned at the row stride"
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

local scroll_indicator =
    assert(
        virtual.scroll_indicator,
        "virtual Tracks list did not create a scroll indicator"
    )

assert(
    tracks_screen.virtual_scroll_indicator ==
        scroll_indicator,
    "Tracks screen did not expose the virtual scroll indicator"
)
assert(
    scroll_indicator.width == 2,
    "virtual scroll indicator should be two pixels wide"
)
assert(
    virtual:scroll_thumb_height(20) >
        virtual:scroll_thumb_height(100) and
    virtual:scroll_thumb_height(100) >
        virtual:scroll_thumb_height(5000),
    "scroll thumb height should decrease as the logical list grows"
)
assert(
    scroll_indicator.thumb_height ==
        virtual:scroll_thumb_height(100),
    "initial scroll thumb height does not match the 100-track list"
)
assert(
    scroll_indicator.thumb_y == 0,
    "initial scroll thumb should begin at the top"
)
assert(
    scroll_indicator.hidden == false,
    "100-track scroll indicator should be visible"
)

assert(
    scroll_indicator.track == nil,
    "scroll indicator should not create a background track"
)
assert(
    scroll_indicator.thumb_color ==
        jellyfin_theme.color("accent") and
        scroll_indicator.thumb_opacity == 255,
    "scroll indicator thumb should use the semantic accent"
)

local indicator_thumb_coordinates =
    scroll_indicator.thumb:get_coords()

assert(
    indicator_thumb_coordinates.x2 -
        indicator_thumb_coordinates.x1 + 1 == 2,
    "scroll indicator thumb is not two pixels wide"
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

local first_recycle_focus_object =
    virtual.pool[6].object

for _ = 1, 5 do
    group:focus_next()
    backstack.flush(2)
end

assert(
    virtual.selected_index == 6,
    "five forward moves should select logical index 6"
)
assert(
    virtual.window_start == 2,
    "logical index 6 should rotate the virtual window once"
)
assert(
    group:get_focused() ==
        first_recycle_focus_object and
    virtual:selected_model().object ==
        first_recycle_focus_object,
    "recycling changed the focused row object instead of preserving it"
)
assert(
    virtual:selected_model().virtual_slot ==
        virtual.forward_slot,
    "the preserved focused row did not settle at the lower focus-band slot"
)
assert(
    virtual.pool[1].virtual_index == 2 and
        virtual.pool[7].virtual_index == 8,
    "the first forward recycle did not rotate only the offscreen row"
)

for _ = 1, 19 do
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
assert(
    selected_model.virtual_slot ==
        virtual.forward_slot,
    "continued downward navigation should settle on the lower focus-band slot"
)
assert(
    scroll_indicator.thumb_y > 0,
    "scroll indicator did not move after navigating to track 25"
)

local downward_indicator_y =
    scroll_indicator.thumb_y
local downward_window_start =
    virtual.window_start

group:focus_prev()
backstack.flush(2)

assert(
    virtual.selected_index == 24,
    "reversing upward should select logical index 24, got " ..
        tostring(virtual.selected_index)
)
assert(
    virtual.window_start ==
        downward_window_start,
    "the first upward reversal should move focus within the visible window before recycling"
)
assert(
    virtual:selected_model().virtual_slot ==
        virtual.forward_slot - 1,
    "the first upward reversal should move the highlight up one physical row"
)
assert(
    scroll_indicator.thumb_y <=
        downward_indicator_y,
    "scroll indicator moved in the wrong direction while navigating upward"
)

group:focus_next()
backstack.flush(2)

assert(
    virtual.selected_index == 25,
    "returning downward should restore logical index 25, got " ..
        tostring(virtual.selected_index)
)
assert(
    virtual.window_start ==
        downward_window_start,
    "returning downward inside the focus band should not recycle the row pool"
)

selected_model =
    assert(virtual:selected_model())
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
assert(
    selected_model.virtual_slot ==
        virtual.backward_slot,
    "child return should preserve the selected row at the upper focus-band slot"
)

local restored_window_start =
    virtual.window_start

tracks_screen.focus_group:focus_next()
backstack.flush(2)

assert(
    virtual.selected_index == 16,
    "the first downward move after child return should select logical index 16, got " ..
        tostring(virtual.selected_index)
)
assert(
    virtual.window_start ==
        restored_window_start,
    "the first downward move after child return should move the highlight before scrolling"
)
assert(
    virtual:selected_model().virtual_slot ==
        virtual.backward_slot + 1,
    "the first downward move after child return should move the highlight down one physical row"
)

tracks_screen.focus_group:focus_prev()
backstack.flush(2)

assert(
    virtual.selected_index == 15,
    "returning upward should restore logical index 15, got " ..
        tostring(virtual.selected_index)
)
assert(
    virtual.window_start ==
        restored_window_start,
    "returning upward inside the focus band should not recycle the row pool"
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
assert(
    scroll_indicator.thumb_y == 0,
    "sorting should reset the scroll indicator to the top"
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
    "first move below Sort should select logical track 1, got " ..
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
    "third move below Sort selected the wrong track"
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

local full_list_thumb_height =
    scroll_indicator.thumb_height
local original_items = virtual.items
local original_selected_index =
    virtual.selected_index
local short_tracks = {}

for index = 1, 12 do
    short_tracks[index] =
        original_items[index]
end

virtual.items = short_tracks
virtual.selected_index = 1
virtual:update_scroll_indicator()

assert(
    scroll_indicator.thumb_height >
        full_list_thumb_height,
    "scroll thumb did not grow when the logical list became shorter"
)
assert(
    scroll_indicator.thumb_y == 0,
    "shorter list should position the thumb at the top"
)
assert(
    scroll_indicator.hidden == false,
    "12-track scroll indicator should remain visible"
)

virtual.items = {
    short_tracks[1],
    short_tracks[2],
    short_tracks[3],
}
virtual.selected_index = 1
virtual:update_scroll_indicator()

assert(
    scroll_indicator.hidden == true,
    "scroll indicator should hide when all logical items fit"
)

virtual.items = original_items
virtual.selected_index =
    original_selected_index
virtual:update_scroll_indicator()

assert(
    scroll_indicator.hidden == false and
        scroll_indicator.thumb_height ==
            full_list_thumb_height,
    "scroll indicator did not restore after the size checks"
)

os.execute("rm -rf " .. root)

print(
    "Virtual Tracks row recycling, navigation, activation, sorting, and restoration passed"
)

os.exit(0)

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

package.loaded["backstack"] = backstack
package.preload["backstack"] = function()
    return backstack
end

local root =
    "/tmp/tangara-virtual-album-list"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

package.loaded["device"] = nil
package.preload["device"] = function()
    return {
        id = function()
            return "virtual-album-list-test"
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
local tracks = {}

for index = 1, 100 do
    local id =
        string.format(
            "album-%03d",
            index
        )
    local track = {
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
    }

    tracks[index] = track
    albums[index] = {
        key = id,
        id = id,
        name = string.format(
            "Album %03d",
            index
        ),
        artist = string.format(
            "Artist %03d",
            index
        ),
        track_count = index,
        tracks = {track},
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
    albums = albums,
    tracks = tracks,
    counts = {
        artists = 0,
        albums = #albums,
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

package.loaded["jellyfin_local_library"] =
    local_library

local albums_screen =
    local_library.Albums:new()

backstack.reset(albums_screen)
backstack.flush(12)

local virtual =
    assert(
        albums_screen.virtual_album_list
    )

assert(
    virtual:logical_count() == 100,
    "virtual list did not retain all 100 logical albums"
)
assert(
    virtual:pool_count() == 7,
    "virtual list did not create exactly seven reusable album rows"
)
assert(
    #albums_screen.media_rows == 7,
    "Albums screen exposed an unexpected media-row count"
)
assert(
    virtual.canvas ==
        albums_screen.virtual_row_canvas,
    "Albums screen did not expose the virtual row canvas"
)
assert(
    virtual.canvas:get_parent() ==
        albums_screen.list,
    "virtual row canvas is not attached to the Albums list"
)
for _, model in ipairs(virtual.pool) do
    assert(
        model.object:get_parent() ==
            virtual.canvas,
        "a reusable Albums row is not parented to the virtual canvas"
    )
end

local initial_id =
    assert(
        virtual.items[1].id,
        "first sorted album did not expose an ID"
    )

assert(
    albums_screen.selected_item_id ==
        initial_id,
    "initial selected ID should match the first sorted album"
)
assert(
    virtual.selected_index == 1,
    "initial virtual album index should be 1"
)

local scroll_indicator =
    assert(
        virtual.scroll_indicator,
        "virtual Albums list did not create a scroll indicator"
    )

assert(
    albums_screen.virtual_scroll_indicator ==
        scroll_indicator,
    "Albums screen did not expose the virtual scroll indicator"
)
assert(
    scroll_indicator.width == 2 and
        scroll_indicator.hidden == false,
    "Albums scroll indicator should be a visible two-pixel bar"
)
assert(
    scroll_indicator.track == nil and
        scroll_indicator.thumb_color == "#FFFFFF" and
        scroll_indicator.thumb_opacity == 255,
    "Albums scroll indicator should be a solid white thumb with no track"
)
assert(
    scroll_indicator.thumb_height ==
        virtual:scroll_thumb_height(100),
    "Albums scroll thumb height does not match its logical list size"
)

local initial_metrics =
    metrics.snapshot()

local list_coordinates =
    albums_screen.list:get_coords()
local sort_coordinates =
    albums_screen.sort_row.object
        :get_coords()
local first_coordinates =
    albums_screen.first_row:get_coords()

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
    assert(albums_screen.focus_group)

for _ = 1, 24 do
    group:focus_next()
    backstack.flush(2)
end

assert(
    virtual.selected_index == 25,
    "24 forward moves should select logical album 25"
)

local index_25_id =
    assert(
        virtual.items[25].id,
        "sorted album at index 25 did not expose an ID"
    )

assert(
    albums_screen.selected_item_id ==
        index_25_id,
    "24 forward moves selected the wrong album"
)
assert(
    scroll_indicator.thumb_y > 0,
    "Albums scroll indicator did not move with navigation"
)

local selected_model =
    assert(virtual:selected_model())

assert(
    group:get_focused() ==
        selected_model.object
)
assert(selected_model.artwork)
assert(selected_model.title)
assert(selected_model.artist)
assert(selected_model.badge)
assert(
    selected_model.selection_id ==
        index_25_id,
    "recycled album row retained the wrong selection ID"
)

selected_model.on_click()
backstack.flush(8)

local album_detail =
    assert(backstack.current())

assert(
    album_detail ~= albums_screen,
    "album activation did not open a child screen"
)
assert(
    album_detail.album_key ==
        index_25_id,
    "recycled row opened the wrong album detail"
)

backstack.pop()
backstack.flush(10)

assert(backstack.current() == albums_screen)
assert(
    virtual.selected_index == 25,
    "album return changed the selected logical index"
)
assert(
    albums_screen.selected_item_id ==
        index_25_id,
    "album return changed the selected album ID"
)
assert(
    albums_screen.focus_group
        :get_focused() ==
        virtual:selected_model().object,
    "album return did not restore the selected virtual row"
)

local navigation_metrics =
    metrics.snapshot()

assert(
    navigation_metrics.active_objects ==
        initial_metrics.active_objects,
    "album navigation changed the active LVGL object count"
)

albums_screen.open_sort_menu()
albums_screen.sort_select("alpha")
albums_screen.sort_options.on_toggle("alpha")
albums_screen.close_sort_menu(false)
backstack.flush(8)

assert(
    virtual:pool_count() == 7,
    "sorting changed the album row-pool size"
)
assert(
    #albums_screen.media_rows == 7,
    "sorting changed the Albums media-row count"
)
assert(
    virtual.selected_index == 1,
    "sorting should reset logical album selection to 1"
)
assert(
    virtual.window_start == 1,
    "sorting should reset the album window to 1"
)
assert(
    scroll_indicator.thumb_y == 0,
    "sorting should reset the Albums scroll indicator"
)

local sorted_first_id =
    assert(
        virtual.items[1].id,
        "first album after sorting did not expose an ID"
    )

assert(
    albums_screen.selected_item_id ==
        sorted_first_id,
    "sorting should select the first sorted album"
)
assert(
    virtual.pool[1].virtual_index == 1,
    "first physical row should bind to album 1 after sorting"
)
assert(
    albums_screen.focus_group:get_focused() ==
        albums_screen.sort_row.object,
    "closing Sort should keep focus on the Sort row"
)

albums_screen.focus_group:focus_next()
backstack.flush(2)

assert(
    virtual.selected_index == 1,
    "first move below Sort should select logical album 1"
)
assert(
    albums_screen.selected_item_id ==
        sorted_first_id,
    "first move below Sort selected the wrong album"
)

albums_screen.focus_group:focus_next()
backstack.flush(2)

assert(
    virtual.selected_index == 2,
    "second move below Sort should select logical album 2"
)

local sorted_second_id =
    assert(
        virtual.items[2].id,
        "second sorted album did not expose an ID"
    )

assert(
    albums_screen.selected_item_id ==
        sorted_second_id,
    "third move below Sort selected the wrong album"
)

virtual:selected_model().on_click()
backstack.flush(8)

assert(
    backstack.current().album_key ==
        sorted_second_id,
    "post-sort activation opened the wrong album"
)

backstack.pop()
backstack.flush(10)

assert(
    albums_screen.selected_item_id ==
        sorted_second_id,
    "post-sort child return changed the selected album"
)
assert(
    albums_screen.focus_group
        :get_focused() ==
        virtual:selected_model().object,
    "post-sort child return did not focus the selected album row"
)

os.execute("rm -rf " .. root)

print(
    "Virtual Albums row recycling, layout fields, navigation, activation, sorting, and restoration passed"
)

os.exit(0)

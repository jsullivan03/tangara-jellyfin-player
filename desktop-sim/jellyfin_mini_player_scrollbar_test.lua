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

require("mocks").install(lvgl)
package.loaded["backstack"] = backstack
package.preload["backstack"] = function()
    return backstack
end

local root =
    "desktop-sim/sd/jellyfin-library-ui"

package.loaded["device"] = {
    id = function()
        return "tangara-sim-001"
    end,
    storage_root = function()
        return root
    end,
}

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
    pending_items = function()
        return {}
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

local playing = {
    id = "creep",
    jellyfin_id = "creep",
    title = "Creep",
    artist = "Radiohead",
    album = "Pablo Honey",
    duration = 100,
    local_path = "/tmp/creep.flac",
}

package.loaded["jellyfin_playback"] = {
    current = function()
        return {
            track = playing,
            item = playing,
            generation = 1,
            queue = {
                items = {playing},
                position = 1,
            },
        }
    end,
    local_item = function(track)
        return track
    end,
    play = function()
        return true
    end,
}

for _, module_name in ipairs({
    "jellyfin_local_index",
    "jellyfin_local_library",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_mini_player",
    "jellyfin_scroll_indicator",
    "jellyfin_sort",
    "jellyfin_marquee",
    "jellyfin_collection_playback",
    "jellyfin_track_action_sheet",
    "jellyfin_local_artwork",
    "jellyfin_album_identity",
    "jellyfin_artist_identity",
    "jellyfin_playback_session",
}) do
    package.loaded[module_name] = nil
end

local mini_player =
    require("jellyfin_mini_player")
local local_index =
    require("jellyfin_local_index")
local local_library =
    require("jellyfin_local_library")

local viewport =
    mini_player.usable_viewport(true)

assert(
    viewport.usable_top ==
        mini_player.LIST_Y
)
assert(
    viewport.usable_height ==
        mini_player.MINI_LIST_HEIGHT
)
assert(
    viewport.usable_bottom ==
        mini_player.LIST_Y +
        mini_player.MINI_LIST_HEIGHT
)

local full =
    mini_player.usable_viewport(false)

assert(
    full.usable_height ==
        mini_player.FULL_LIST_HEIGHT
)

local library =
    assert(local_index.load())
local artist = nil

for _, candidate in ipairs(
    library.artists or {}
) do
    if tostring(candidate.name):upper()
            :find("RADIOHEAD", 1, true) then
        artist = candidate
        break
    end
end

if not artist then
    for _, candidate in ipairs(
        library.artists or {}
    ) do
        if #(candidate.releases or {}) >=
                3 then
            artist = candidate
            break
        end
    end
end

assert(
    artist,
    "fixture requires an artist with releases"
)

local function indicator_geometry(screen)
    local indicator =
        assert(
            screen.scroll_indicator or
            screen.virtual_scroll_indicator
        )
    local list =
        screen.list:get_coords()
    local thumb =
        indicator.thumb:get_coords()
    local mini =
        screen.mini_player:state()

    return {
        indicator = indicator,
        list = list,
        thumb = thumb,
        mini = mini,
        list_height =
            list.y2 - list.y1 + 1,
        track_bottom =
            list.y1 + indicator.y +
            indicator.height - 1,
    }
end

local function assert_scrollbar_above_mini(
    screen,
    label
)
    local geometry =
        indicator_geometry(screen)

    assert(
        geometry.mini.visible == true,
        label .. ": mini-player hidden"
    )
    assert(
        geometry.list_height ==
            mini_player.MINI_LIST_HEIGHT,
        label ..
            ": list height not reduced"
    )
    assert(
        geometry.list.y2 <=
            geometry.mini.root_coordinates.y1,
        label ..
            ": list still overlaps mini-player"
    )
    assert(
        geometry.indicator.height ==
            mini_player.scroll_track_height(
                geometry.list_height
            ),
        label ..
            ": scrollbar track height mismatch"
    )
    assert(
        geometry.track_bottom <=
            geometry.list.y2,
        label ..
            ": scrollbar track exceeds list"
    )
    assert(
        geometry.thumb.y2 <=
            geometry.mini.root_coordinates.y1,
        label ..
            ": scrollbar remains behind mini-player"
    )
    assert(
        geometry.thumb.y2 <=
            geometry.list.y2 + 1,
        label ..
            ": thumb painted below list bottom"
    )

    return geometry
end

local discography =
    local_library.Artist:new {
        title = artist.name,
        artist_key = artist.key,
    }

backstack.reset(discography)
backstack.flush(10)

local first =
    assert_scrollbar_above_mini(
        discography,
        "artist discography open"
    )

-- Top / middle / bottom thumb positions with mini visible.
local total =
    #(discography.sorted_releases or {})

for _, index in ipairs({
    1,
    math.max(1, math.floor(total / 2)),
    total,
}) do
    discography.virtual_list_controller:
        focus_index(index)
    backstack.flush(2)
    local geometry =
        assert_scrollbar_above_mini(
            discography,
            "focus index " .. tostring(index)
        )
    assert(
        geometry.indicator.thumb_height <=
            geometry.indicator.height,
        "thumb taller than reduced track"
    )
end

local selected_id =
    discography.selected_item_id
local selected_index =
    discography.virtual_list_controller
        .selected_index
local window_start =
    discography.virtual_list_controller
        .window_start
local fixed_base_y =
    discography.virtual_list_controller
        .fixed_base_y

-- Hide mini-player and restore full scrollbar.
package.loaded["jellyfin_playback"].current =
    function()
        return nil
    end

discography.mini_player:refresh()
backstack.flush(4)

local hidden =
    indicator_geometry(discography)

assert(
    hidden.mini.visible == false,
    "mini-player did not hide"
)
assert(
    hidden.list_height ==
        mini_player.FULL_LIST_HEIGHT,
    "list did not restore full height"
)
assert(
    hidden.indicator.height ==
        mini_player.scroll_track_height(
            hidden.list_height
        ),
    "scrollbar did not restore full track height"
)

-- Show again and confirm no height accumulation across NP cycles.
package.loaded["jellyfin_playback"].current =
    function()
        return {
            track = playing,
            item = playing,
            generation = 1,
            queue = {
                items = {playing},
                position = 1,
            },
        }
    end

for cycle = 1, 4 do
    discography.mini_player:refresh()
    backstack.flush(2)
    local geometry =
        assert_scrollbar_above_mini(
            discography,
            "cycle " .. tostring(cycle)
        )
    assert(
        geometry.list_height ==
            first.list_height,
        "list height drifted across cycles"
    )
    assert(
        geometry.indicator.height ==
            first.indicator.height,
        "scrollbar height drifted across cycles"
    )
end

assert(
    discography.selected_item_id ==
        selected_id and
    discography.virtual_list_controller
        .selected_index == selected_index,
    "selection was lost across mini-player show/hide"
)
assert(
    discography.virtual_list_controller
        .window_start == window_start or
    discography.virtual_list_controller:
        selection_in_viewport(),
    "selected row left the usable viewport"
)

-- Plain-list path: Local root.
local root_screen =
    local_library.Root:new()

backstack.reset(root_screen)
backstack.flush(8)

assert(
    root_screen.mini_player.visible == true
)

local root_list =
    root_screen.list:get_coords()
local root_height =
    root_list.y2 - root_list.y1 + 1

assert(
    root_height ==
        mini_player.MINI_LIST_HEIGHT
)
assert(
    root_list.y2 <=
        root_screen.mini_player:state()
            .root_coordinates.y1
)

print(
    string.format(
        "Mini-player scrollbar geometry passed artist=%s track_h=%d list_h=%d",
        tostring(artist.name),
        first.indicator.height,
        first.list_height
    )
)
os.exit(0)

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

package.loaded["jellyfin_playback"] = {
    local_item = function(track)
        return track
    end,
    play = function()
        return true
    end,
    current = function()
        return nil
    end,
}

for _, module_name in ipairs({
    "jellyfin_local_index",
    "jellyfin_artist_identity",
    "jellyfin_local_library",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_mini_player",
    "jellyfin_sort",
    "jellyfin_marquee",
    "jellyfin_collection_playback",
    "jellyfin_track_action_sheet",
    "jellyfin_local_artwork",
    "jellyfin_album_identity",
}) do
    package.loaded[module_name] = nil
end

local local_index =
    require("jellyfin_local_index")
local local_library =
    require("jellyfin_local_library")

local library =
    assert(local_index.load())

local function count_name(name)
    local count = 0

    for _, artist in ipairs(
        library.artists or {}
    ) do
        if artist.name == name then
            count = count + 1
        end
    end

    return count
end

local before_total =
    library.counts.artists

assert(
    count_name("Travis Scott") == 1,
    "live Travis Scott must be one artist row"
)
assert(
    count_name("Xxxtentacion") == 1,
    "live Xxxtentacion must be one artist row"
)

local travis = nil
local xxx = nil

for _, artist in ipairs(library.artists) do
    if artist.name == "Travis Scott" then
        travis = artist
    elseif artist.name == "Xxxtentacion" then
        xxx = artist
    end
end

assert(travis and xxx)
assert(
    travis.key:sub(1, 3) == "id:"
)
assert(xxx.key:sub(1, 3) == "id:")
assert(
    travis.release_count >= 1
)
assert(
    xxx.release_count == 3,
    "Xxx discography must include all unique albums once"
)

local seen_albums = {}

for _, album in ipairs(travis.releases) do
    assert(
        not seen_albums[album.key],
        "Travis discography duplicated album " ..
            tostring(album.key)
    )
    seen_albums[album.key] = true
end

local artists_screen =
    local_library.Artists:new()

backstack.reset(artists_screen)
backstack.flush(8)

assert(
    #(artists_screen.sorted_artists or {}) ==
        before_total,
    "Artists screen must use the deduped model count"
)

local selected =
    assert(
        artists_screen.virtual_artist_list:
            selected_model()
    )
local selected_id =
    artists_screen.selected_item_id or
    selected.selection_id

for cycle = 1, 3 do
    backstack.pop()
    backstack.flush(2)
    backstack.push(
        local_library.Artists:new()
    )
    backstack.flush(8)
    artists_screen = backstack.current()
    assert(
        #(artists_screen.sorted_artists or {}) ==
            before_total,
        "re-entering Artists grew the count on cycle " ..
            tostring(cycle)
    )
end

-- Open Travis discography by canonical key and Escape.
local travis_index = nil

for index, artist in ipairs(
    artists_screen.sorted_artists
) do
    if artist.key == travis.key then
        travis_index = index
        break
    end
end

assert(travis_index)
artists_screen.virtual_artist_list:
    focus_index(travis_index)
backstack.flush(2)

assert(
    artists_screen.selected_item_id ==
        travis.key
)

local before_window =
    artists_screen.virtual_artist_list
        .window_start
local before_base =
    artists_screen.virtual_artist_list
        .fixed_base_y

local focused =
    assert(
        artists_screen.virtual_artist_list:
            selected_model()
    )

focused.on_click()
backstack.flush(6)

local artist_screen =
    assert(backstack.current())
assert(
    artist_screen ~= artists_screen
)

backstack.pop()
backstack.flush(6)

assert(
    backstack.current() ==
        artists_screen
)
assert(
    artists_screen.selected_item_id ==
        travis.key,
    "Escape must restore Artists selection by canonical key"
)
assert(
    artists_screen.virtual_artist_list
        .window_start == before_window or
    artists_screen.virtual_artist_list
        .selected_index == travis_index,
    "Artists viewport/selection must survive Escape"
)

-- Simulator "restart": reload index and confirm stable unique count.
package.loaded["jellyfin_local_index"] = nil
local_index =
    require("jellyfin_local_index")
local reloaded =
    assert(local_index.load())

assert(
    reloaded.counts.artists ==
        before_total
)
assert(
    count_name("Travis Scott") == 1
)
assert(
    count_name("Xxxtentacion") == 1
)

print(
    string.format(
        "Local Artists lifecycle passed total=%d travis=%s xxx_releases=%d",
        before_total,
        travis.key,
        xxx.release_count
    )
)
os.exit(0)

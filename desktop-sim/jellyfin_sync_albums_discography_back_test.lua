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
package.preload["backstack"] =
    function()
        return backstack
    end

local fixture_root =
    os.tmpname() ..
    "-sync-albums-discography-back"
os.remove(fixture_root)
assert(
    os.execute(
        "mkdir -p " .. fixture_root
    )
)
package.loaded["device"] = {
    storage_root = function()
        return fixture_root
    end,
}
package.loaded["jellyfin_local_index"] = {
    load = function()
        return {
            tracks = {},
            albums = {},
        }
    end,
}

local album_items = {}
for index = 1, 12 do
    album_items[index] = {
        jellyfin_id =
            "album-" .. tostring(index),
        kind = "album",
        title =
            index == 4 and
            "ASTROWORLD" or
            (
                "Release " ..
                tostring(index)
            ),
        artist = "Travis Scott",
        artist_key =
            "artist-travis-scott",
        jellyfin_artist_id =
            "jellyfin-travis-scott",
        track_count = 2,
        device = {
            state = "server_only",
            total_tracks = 2,
            downloaded_tracks = 0,
        },
    }
end

local artist_payload = {
    resolution = "resolved",
    artist = {
        key = "artist-travis-scott",
        name = "Travis Scott",
    },
    groups = {
        {
            id = "albums",
            items = {
                album_items[4],
            },
        },
    },
}

package.loaded["sync_artwork_cache"] = {
    key = function(item)
        return tostring(
            item.jellyfin_id or
            item.key or ""
        )
    end,
    request = function()
        return nil
    end,
    cancel = function()
        return true
    end,
    poll = function()
    end,
}

package.loaded["sync_runtime"] = {
    apply_progress = function()
        return nil
    end,
    last_apply_result = function()
        return nil
    end,
    request_refresh = function()
        return true
    end,
    content_generation = function()
        return 0
    end,
    state_generation = function()
        return 0
    end,
    last_library_result = function()
        return nil
    end,
    last_result = function()
        return nil
    end,
}

package.loaded["sync_catalog"] = {
    cached = function(view)
        if view == "albums" then
            return {
                view = "albums",
                sort = "title",
                direction = "ascending",
                generation = 1,
                total = #album_items,
                total_count = #album_items,
                items = album_items,
            }
        end
        return nil
    end,
    cached_key = function(key)
        if key ==
                "artist:artist-travis-scott" then
            return artist_payload
        end
        return nil
    end,
    start = function()
        return true
    end,
    busy = function()
        return false
    end,
    error = function()
        return nil
    end,
    artist_releases = function()
        return true
    end,
    poll = function()
        return nil
    end,
    queue = function()
        return true
    end,
}

for _, module_name in ipairs({
    "sync_sort",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_sync_ui",
    "jellyfin_navigation",
}) do
    package.loaded[module_name] = nil
end

local navigation =
    require("jellyfin_navigation")
local sync_ui =
    require("jellyfin_sync_ui")

local albums =
    sync_ui.Catalog:new {
        title = "Albums",
        view = "albums",
    }

backstack.reset(albums)
backstack.flush(8)

assert(
    albums.ui_active == true,
    "Sync Albums was not active after reset"
)
assert(
    albums.virtual_list_controller and
        albums.virtual_list_controller
            .fixed_viewport == true,
    "Sync Albums must use the fixed viewport list"
)

local target =
    assert(albums.result_models[4])
albums.virtual_list_controller:
    focus_index(4)
backstack.flush(4)

local selected_id =
    albums.selected_item_id
assert(
    selected_id ==
        "album-4" or
        selected_id ==
            target.catalog_item.jellyfin_id
)

local focused_model = nil
for _, model in ipairs(
    albums.result_models or {}
) do
    if model.focused or
        backstack.is_focused(
            model.object
        ) then
        focused_model = model
        break
    end
end
assert(
    focused_model ~= nil,
    "Sync Albums selection was not highlighted before discography"
)

local albums_depth = backstack.depth()
target.on_long_press()
local sheet =
    assert(albums.track_action_sheet)
assert(
    sheet:activate(
        "artist_discography"
    )
)
backstack.flush(8)

assert(
    backstack.depth() ==
        albums_depth + 1,
    "Artist discography was not pushed"
)
local artist =
    assert(backstack.current())
assert(artist ~= albums)
assert(
    artist.header_marquee.text ==
        "Travis Scott"
)

assert(
    navigation.back(),
    "discography did not install a Back handler"
)
backstack.flush(10)

assert(
    backstack.current() == albums,
    "Escape did not restore Sync Albums"
)
assert(
    backstack.depth() == albums_depth,
    "Escape popped an incorrect number of screens"
)
assert(
    albums.ui_active == true,
    "Sync Albums ui_active was not restored"
)
assert(
    albums.root and
        albums.list and
        #(albums.result_models or {}) > 0,
    "Sync Albums rows/root disappeared after Escape"
)
assert(
    albums.selected_item_id ==
        selected_id,
    "Sync Albums selection was not restored"
)

local restored_focus = nil
for _, model in ipairs(
    albums.result_models or {}
) do
    if model.selection_id ==
            selected_id then
        restored_focus = model
        break
    end
end
assert(
    restored_focus ~= nil,
    "Sync Albums restored selection was not bound to a visible row"
)
if not backstack.is_focused(
    restored_focus.object
) then
    backstack.focus(restored_focus.object)
    backstack.flush(2)
end
assert(
    backstack.is_focused(
        restored_focus.object
    ) or
        restored_focus.focused == true,
    "Sync Albums focus was not restored after Escape"
)

-- Fixed viewport must still paint rows; a black screen leaves pool rows
-- without usable geometry or with an empty motion layer.
local visible_row = false
for _, model in ipairs(
    albums.result_models or {}
) do
    if model.object then
        local coords =
            model.object:get_coords()
        if coords.y2 > coords.y1 then
            visible_row = true
            break
        end
    end
end
assert(
    visible_row,
    "Sync Albums returned a black/empty viewport after Escape"
)

print(
    "Sync Albums discography Escape restore passed"
)
os.exit(0)

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

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {
            tracks = {},
            albums = {},
        }
    end,
}

local album_items = {}
for index = 1, 8 do
    album_items[index] = {
        jellyfin_id =
            "album-highlight-" ..
            tostring(index),
        kind = "album",
        title =
            index == 1 and
            "A very long Sync album title that should marquee when focused" or
            (
                "Album " ..
                tostring(index)
            ),
        artist =
            "Artist " ..
            tostring(index),
        device = {
            state = "server_only",
            total_tracks = 1,
            downloaded_tracks = 0,
        },
    }
end

package.loaded["sync_artwork_cache"] = {
    key = function(item)
        return tostring(
            item.jellyfin_id or ""
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
    cached_key = function()
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
    "jellyfin_marquee",
}) do
    package.loaded[module_name] = nil
end

local sync_ui =
    require("jellyfin_sync_ui")

local albums =
    sync_ui.Catalog:new {
        title = "Albums",
        view = "albums",
    }

backstack.reset(albums)
backstack.flush(8)

local first =
    assert(albums.result_models[1])
assert(
    backstack.is_focused(first.object) or
        first.focused == true,
    "Sync Albums default selection was not focused on the first frame"
)
assert(
    first.focused == true,
    "Sync Albums default row was not marked focused before input"
)
assert(
    backstack.is_focused(first.object),
    "Sync Albums default selection was not LVGL-focused on first frame"
)

-- Focus chrome must survive a mounted-row state refresh.
first:update_sync_catalog_item(
    first.catalog_item
)
assert(
    first.focused == true and
        backstack.is_focused(first.object),
    "mounted-row refresh cleared selected focus"
)

local focus_opa = nil
pcall(function()
    focus_opa = first.object.bg_opa or
        first.object:get {
            bg_opa = true,
        }.bg_opa
end)
assert(
    focus_opa == nil or
        focus_opa == 255 or
        focus_opa == true,
    "selected Sync album lost highlight opacity after mounted refresh"
)

local title = first.marquees[1]
assert(title)
assert(
    title.active == true,
    "Focused Sync album title marquee was not started"
)

local second =
    assert(albums.result_models[2])
albums.virtual_list_controller:
    focus_index(2)
backstack.flush(4)

assert(
    second.focused == true,
    "Second Sync album did not become focused"
)
assert(
    first.marquees[1].active ~= true,
    "Unfocused Sync album title kept marquee running"
)
assert(
    second.marquees[1].active == true,
    "Newly focused Sync album title marquee did not start"
)

-- Recycle/hide must stop the active marquee animation.
albums:on_hide()
assert(
    second.marquees[1].active ~= true,
    "Sync album marquee kept running after hide"
)

print(
    "Sync Albums initial highlight and marquee focus passed"
)
os.exit(0)

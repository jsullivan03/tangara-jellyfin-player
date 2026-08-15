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

local function album(id, title, date_created)
    return {
        jellyfin_id = id,
        kind = "album",
        title = title,
        artist = "Refresh Artist",
        date_created = date_created,
        device = {
            state = "server_only",
            total_tracks = 1,
            downloaded_tracks = 0,
        },
    }
end

local cached = {
    view = "albums",
    sort = "date_added",
    direction = "descending",
    items = {
        album(
            "album-old",
            "Previously Cached",
            "2026-07-31T00:00:00Z"
        ),
    },
}
local next_payload = nil
local request_pending = false
local request_count = 0
local last_request = nil
local companion_request_blocked = false
local catalog_generation = 0
local ticks = 1000

package.loaded["time"] = {
    ticks = function()
        return ticks
    end,
}

package.loaded["sync_catalog"] = {
    next_generation = function(key)
        assert(key == "new")
        catalog_generation =
            catalog_generation + 1
        return catalog_generation
    end,
    cached = function(key)
        if key == "new" then
            return cached
        end
        return nil
    end,
    cached_key = function()
        return nil
    end,
    start = function(
        view,
        cursor,
        limit,
        options
    )
        if companion_request_blocked then
            return false,
                "sync request is already active"
        end
        assert(not request_pending)
        request_pending = true
        request_count = request_count + 1
        last_request = {
            view = view,
            cursor = cursor,
            limit = limit,
            options = options,
        }
        return true
    end,
    busy = function()
        return request_pending
    end,
    error = function()
        return nil
    end,
    poll = function()
        if not request_pending or
            not next_payload then
            return nil
        end
        cached = next_payload
        next_payload = nil
        request_pending = false
        return {
            ok = true,
            kind = "catalog",
            view = "albums",
            payload = cached,
        }
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
package.loaded["sync_runtime"] = {
    apply_progress = function()
        return nil
    end,
    last_apply_result = function()
        return nil
    end,
    last_library_result = function()
        return nil
    end,
    last_result = function()
        return nil
    end,
    request_refresh = function()
        return true
    end,
}
package.loaded["sync_artwork_cache"] = {
    key = function(item)
        return tostring(item.jellyfin_id)
    end,
    request = function(_item, callback)
        callback(nil)
        return nil
    end,
    cancel = function()
        return true
    end,
    poll = function()
    end,
}

local ui_poll = nil
local poll_callbacks = {}
local original_timer = lvgl.Timer
lvgl.Timer = function(options)
    if options.period == 250 and
        type(options.cb) == "function" then
        poll_callbacks[#poll_callbacks + 1] =
            options.cb
        ui_poll = function()
            for _, callback in ipairs(
                poll_callbacks
            ) do
                callback()
            end
        end
    end
    return original_timer(options)
end

for _, module_name in ipairs({
    "sync_sort",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_sync_ui",
}) do
    package.loaded[module_name] = nil
end

local sync_ui = require("jellyfin_sync_ui")
local root = sync_ui.Root:new()
backstack.reset(root)
backstack.flush(8)

assert(type(ui_poll) == "function")
assert(request_count == 1)
assert(request_pending)
assert(root.rows[4].title.text == "Previously Cached")
assert(last_request.view == "albums")
assert(last_request.cursor == nil)
assert(last_request.limit == 20)
assert(last_request.options.cache_key == "new")
assert(last_request.options.sort == "date_added")
assert(last_request.options.direction == "descending")
assert(last_request.options.generation == 1)

local refreshed_items = {}
for index = 1, 24 do
    refreshed_items[index] = album(
        string.format("album-%02d", index),
        string.format("Fresh %02d", index),
        string.format(
            "2026-08-%02dT00:00:00Z",
            25 - index
        )
    )
end
next_payload = {
    view = "albums",
    sort = "date_added",
    direction = "descending",
    items = refreshed_items,
}
ui_poll()

assert(root.rows[4].title.text == "Fresh 01")
assert(#root.rows - 3 == 20)
for index = 4, #root.rows do
    assert(root.rows[index].catalog_item.kind == "album")
end

-- Download-state generations may repaint rows, but cannot trigger catalog IO.
require("sync_download_state").notify_changed({
    "id:download-state-only",
})
ui_poll()
assert(
    request_count == 1,
    "download-state generation retriggered catalog refresh"
)

-- Mounted Sync New refreshes on one bounded screen-level cadence. An
-- identical response finishes without creating a request loop.
ticks = 61000
ui_poll()
assert(request_count == 2 and request_pending)
assert(last_request.options.generation == 2)
next_payload = cached
ui_poll()
assert(not request_pending)
ui_poll()
ui_poll()
assert(
    request_count == 2,
    "identical catalog response caused an infinite refresh loop"
)

-- A later changed response updates the mounted visible data.
ticks = 121000
ui_poll()
assert(request_count == 3 and request_pending)
assert(last_request.options.generation == 3)
next_payload = {
    view = "albums",
    sort = "date_added",
    direction = "descending",
    items = {
        album(
            "album-periodic",
            "Periodic Newest",
            "2026-08-14T00:00:00Z"
        ),
    },
}
ui_poll()
assert(root.rows[4].title.text == "Periodic Newest")

-- Returning to the same landing screen triggers another bounded refresh while
-- the newly cached rows stay present. Model the real shared-client case where
-- another companion request temporarily owns the HTTP transport even though
-- this catalog request itself is not busy.
companion_request_blocked = true
root.quick_rows[1].on_click()
backstack.flush(8)
assert(backstack.depth() == 1)
backstack.pop()
backstack.flush(8)
assert(backstack.depth() == 0)
assert(request_count == 3)
assert(not request_pending)
assert(root.rows[4].title.text == "Periodic Newest")

companion_request_blocked = false
ui_poll()
assert(request_count == 4)
assert(request_pending)
assert(last_request.options.generation == 4)
assert(root.rows[4].title.text == "Periodic Newest")

next_payload = {
    view = "albums",
    sort = "date_added",
    direction = "descending",
    items = {
        album(
            "album-newest",
            "Newest After Return",
            "2026-08-01T23:59:59Z"
        ),
    },
}
ui_poll()
assert(root.rows[4].title.text == "Newest After Return")

print("Sync New bounded reopen refresh passed")
os.exit(0)

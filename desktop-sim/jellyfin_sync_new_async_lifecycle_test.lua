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

local active_request = nil
local next_response = nil
local request_count = 0

package.loaded["sync_client"] = {
    get = function(path, owner)
        assert(active_request == nil)
        request_count = request_count + 1
        active_request = {
            path = path,
            owner = owner,
        }
        return true
    end,
    post = function()
        return false, "not used"
    end,
    busy = function(owner)
        if owner then
            return active_request and
                active_request.owner == owner
        end
        return active_request ~= nil
    end,
    poll = function(owner)
        if not active_request or
            active_request.owner ~= owner or
            not next_response then
            return nil
        end
        local response = next_response
        next_response = nil
        active_request = nil
        return response
    end,
}
package.loaded["device_identity"] = {
    catalog_path = function(
        view,
        cursor,
        limit,
        options
    )
        assert(view == "albums")
        assert(cursor == nil)
        assert(limit == 20)
        assert(options.sort == "date_added")
        assert(options.direction == "descending")
        return "/catalog/new"
    end,
}

package.loaded["sync_catalog"] = nil
local sync_catalog =
    require("sync_catalog")

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
    request = function()
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
local encode = require("json_encode").encode

local function album(id, title)
    return {
        jellyfin_id = id,
        kind = "album",
        title = title,
        artist = "Async Artist",
        device = {
            state = "server_only",
            total_tracks = 1,
        },
    }
end

local function success(id, title)
    return {
        ok = true,
        status = 200,
        body = encode {
            view = "albums",
            sort = "date_added",
            direction = "descending",
            total = 1,
            total_count = 1,
            items = {
                album(id, title),
            },
        },
    }
end

local function visible_value(landing)
    local row = landing.rows[4]
    return row.label and row.label.text or
        row.title and row.title.text
end

-- No cache: an unfinished current request remains Loading.
sync_catalog.reset()
local first = sync_ui.Landing:new()
backstack.reset(first)
backstack.flush(8)

assert(type(ui_poll) == "function")
assert(request_count == 1)
assert(active_request ~= nil)
assert(visible_value(first) == "Loading")

ui_poll()
assert(visible_value(first) == "Loading")
assert(first.new_failed_generation == nil)

next_response = success(
    "album-current",
    "Current Generation"
)
ui_poll()

assert(visible_value(first) == "Current Generation")
assert(first.new_error == nil)
assert(first.new_failed_generation == nil)
assert(first.new_refresh_pending == false)

-- Repeat without cached rows. Returning while generation 1 is pending creates
-- generation 2. A late failure from generation 1 must neither render an error
-- nor populate/overwrite the generation-2 cache.
sync_catalog.reset()
active_request = nil
next_response = nil
request_count = 0

local overlapping = sync_ui.Landing:new()
backstack.reset(overlapping)
backstack.flush(8)

assert(request_count == 1)
assert(visible_value(overlapping) == "Loading")

overlapping.quick_rows[1].on_click()
backstack.flush(4)
backstack.pop()
backstack.flush(4)

assert(overlapping.new_catalog_generation == 2)
assert(overlapping.new_refresh_pending == true)
assert(request_count == 1)

next_response = {
    ok = false,
    status = 504,
    body = encode {
        error = "old generation timeout",
    },
    error = "old generation timeout",
}
ui_poll()

assert(
    request_count == 2,
    "expected newest retry request count 2 got " ..
        tostring(request_count)
)
assert(active_request ~= nil)
assert(visible_value(overlapping) == "Loading")
assert(overlapping.new_failed_generation == nil)
assert(sync_catalog.error() == nil)
assert(sync_catalog.cached("new") == nil)

next_response = success(
    "album-newest-generation",
    "Newest Generation"
)
ui_poll()

assert(visible_value(overlapping) == "Newest Generation")
assert(overlapping.new_error == nil)
assert(overlapping.new_failed_generation == nil)
assert(overlapping.new_refresh_pending == false)
assert(
    sync_catalog.cached("new").items[1]
        .jellyfin_id ==
        "album-newest-generation"
)

print(
    "Sync New keeps Loading while pending and only the newest generation controls rows or errors"
)
os.exit(0)

package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
require("mocks").install(lvgl)

local refresh_starts = 0
local regular_refresh_result = {
    ok = false,
    error = "older refresh completed",
}
local apply_starts = 0
local reconcile_plan = {
    download = {},
    artwork = {},
    actions = {},
}

package.loaded["sync_apply"] = {
    busy = function()
        return false
    end,
    progress = function()
        return nil
    end,
    current = function()
        return nil
    end,
    start = function()
        apply_starts = apply_starts + 1
        return true
    end,
}
package.loaded["sync_artwork_cache"] = {
    busy = function()
        return false
    end,
    poll = function()
    end,
}
package.loaded["sync_config"] = {
    status = function()
        return {connected = true}
    end,
}
package.loaded["sync_library_refresh"] = {
    busy = function()
        return false
    end,
    poll = function()
        return nil
    end,
}
package.loaded["sync_library_artwork"] = {
    busy = function()
        return false
    end,
    poll = function()
        return nil
    end,
}
package.loaded["sync_library_view"] = {}
package.loaded["sync_inventory_report"] = {
    busy = function()
        return false
    end,
    start = function()
        return false
    end,
}
package.loaded["sync_operation_flush"] = {
    busy = function()
        return false
    end,
    poll = function()
        return nil
    end,
}
package.loaded["sync_operation_queue"] = {
    status = function()
        return {pending = 0}
    end,
}
package.loaded["sync_managed_paths"] = {
    load = function()
        return {}, nil, false
    end,
}
package.loaded["sync_manifest_state"] = {
    load_cached = function()
        return {
            ok = false,
            error = "no cache",
        }
    end,
    poll = function()
        local result = regular_refresh_result
        regular_refresh_result = nil
        return result
    end,
    busy = function()
        return false
    end,
    start_refresh = function()
        refresh_starts = refresh_starts + 1
        return true
    end,
}
package.loaded["sync_reconcile"] = {
    plan = function()
        return reconcile_plan
    end,
}
package.loaded["time"] = {
    ticks = function()
        return 1000
    end,
}

local runtime_poll = nil
local original_timer = lvgl.Timer
lvgl.Timer = function(options)
    if options.period == 500 then
        runtime_poll = options.cb
    end
    return original_timer(options)
end

package.loaded["sync_runtime"] = nil
local sync_runtime = require("sync_runtime")
local started, start_error =
    sync_runtime.start()
assert(started, start_error)
assert(type(runtime_poll) == "function")

sync_runtime.request_refresh()
runtime_poll()

assert(
    refresh_starts == 0,
    "an older in-flight manifest response was mistaken for the requested refresh"
)
runtime_poll()

assert(
    refresh_starts == 1,
    "accepted Sync request did not wake an immediate manifest refresh"
)

reconcile_plan = {
    download = {},
    artwork = {
        {
            kind = "artwork",
        },
    },
    actions = {
        {
            kind = "artwork",
        },
    },
}
regular_refresh_result = {
    ok = true,
    manifest = {
        device = {
            id = "tangara-sim-001",
        },
        items = {},
    },
}
runtime_poll()
assert(
    apply_starts == 1,
    "an artwork-only reconcile plan did not start sync_apply"
)

print("Sync runtime refresh wake passed")
os.exit(0)

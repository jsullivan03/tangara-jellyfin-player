package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
require("mocks").install(lvgl)

local now = 1000
local manifest_busy = false
local manifest_result = nil
local refresh_starts = 0
local library_busy = false
local library_result = nil
local library_start_enabled = false
local reconcile_plan = {
    download = {{}},
    artwork = {},
    actions = {{}},
}
local catalog_kind = nil
local catalog_result = nil
local catalog_callback = nil
local catalog_busy_override = false
local durable_starts = 0

package.loaded["sync_apply"] = {
    busy = function() return false end,
    progress = function() return nil end,
    current = function() return nil end,
    start = function() return false, "not started" end,
    generation = function() return 0 end,
    item_states = function() return {} end,
    pending_items = function() return {} end,
}
package.loaded["sync_artwork_cache"] = {
    busy = function() return false end,
    poll = function() end,
}
package.loaded["sync_config"] = {
    status = function() return {connected = true} end,
}
package.loaded["sync_client"] = {
    busy = function()
        return catalog_kind ~= nil or
            catalog_busy_override
    end,
}
package.loaded["sync_catalog"] = {
    pending_kind = function()
        return catalog_kind
    end,
    busy = function()
        return catalog_kind ~= nil or
            catalog_busy_override
    end,
    download_requests = function(callback)
        assert(catalog_kind == nil)
        durable_starts = durable_starts + 1
        catalog_kind = "download_requests"
        catalog_callback = callback
        return true
    end,
    poll = function()
        if not catalog_result then
            return nil
        end
        local result = catalog_result
        local callback = catalog_callback
        catalog_result = nil
        catalog_callback = nil
        catalog_kind = nil
        if callback then
            callback(result)
        end
        return result
    end,
}
package.loaded["sync_library_refresh"] = {
    busy = function() return library_busy end,
    poll = function()
        local result = library_result
        library_result = nil
        if result then
            library_busy = false
        end
        return result
    end,
    start = function()
        if not library_start_enabled then
            return false
        end
        library_busy = true
        return true
    end,
    progress = function() return nil end,
}
package.loaded["sync_library_artwork"] = {
    busy = function() return false end,
    poll = function() return nil end,
    start = function() return false end,
}
package.loaded["sync_library_view"] = {
    current = function() return nil, nil, nil end,
}
package.loaded["sync_inventory_report"] = {
    busy = function() return false end,
    poll = function() return nil end,
    start = function() return false end,
}
package.loaded["sync_operation_flush"] = {
    busy = function() return false end,
    poll = function() return nil end,
}
package.loaded["sync_operation_queue"] = {
    status = function() return {pending = 0} end,
}
package.loaded["sync_managed_paths"] = {
    load = function() return {}, nil, false end,
}
package.loaded["sync_manifest_state"] = {
    load_cached = function()
        return {
            ok = true,
            manifest = {device = {id = "sim"}, items = {}},
        }
    end,
    busy = function() return manifest_busy end,
    poll = function()
        local result = manifest_result
        manifest_result = nil
        if result then
            manifest_busy = false
        end
        return result
    end,
    start_refresh = function()
        assert(not manifest_busy)
        refresh_starts = refresh_starts + 1
        manifest_busy = true
        return true
    end,
}
package.loaded["sync_reconcile"] = {
    plan = function() return reconcile_plan end,
}
package.loaded["sync_offline_bootstrap"] = {
    initial_sync_complete = function() return true end,
    busy = function() return false end,
    poll = function() return nil end,
    start = function() return false end,
    initial_sync_required = function() return false end,
    mark_initial_sync_complete = function() return true end,
}
package.loaded["time"] = {
    ticks = function() return now end,
}
local owner_states = {}
local owner_reconciles = 0
local reconcile_completed_key = nil
local startup_reconcile = nil
local completed_attempts = {}
local failed_attempts = {}
local matching_failed_attempt_id = nil
local owner_operations = {}
package.loaded["sync_download_state"] = {
    set_dispatcher = function() return true end,
    reconcile_startup = function(options)
        startup_reconcile = options
        return {}
    end,
    generation = function() return 0 end,
    lookup = function(item)
        return {
            state = owner_states[item.jellyfin_id] or
                "server_only",
        }
    end,
    request = function(item)
        owner_states[item.jellyfin_id] = "downloading"
        return true
    end,
    operations = function()
        return owner_operations
    end,
    fail = function(item)
        owner_states[item.jellyfin_id] = "failed"
        return true
    end,
    complete_attempt = function(request_id)
        completed_attempts[#completed_attempts + 1] =
            request_id
        return false, "no matching attempt"
    end,
    fail_attempt = function(request_id)
        failed_attempts[#failed_attempts + 1] =
            request_id
        if request_id == matching_failed_attempt_id then
            return true
        end
        return false, "no matching attempt"
    end,
    pump_dispatch = function() return false end,
    reconcile = function()
        owner_reconciles = owner_reconciles + 1
        if reconcile_completed_key then
            owner_states[reconcile_completed_key] =
                "downloaded"
        end
        return {}
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
local runtime = require("sync_runtime")
assert(runtime.start())
assert(type(runtime_poll) == "function")
assert(runtime.activity().mode == "idle")

-- Startup first observes the durable companion request set independently of
-- manifest success.
runtime_poll()
assert(catalog_kind == "download_requests" and durable_starts == 1)
local stale_optimistic = {
    jellyfin_id = "stale-optimistic-a",
    kind = "album",
    title = "Stale Optimistic A",
    device = {state = "server_only"},
}
assert(runtime.note_queued(stale_optimistic))
assert(
    runtime.item_state(stale_optimistic) == "queued",
    "stale optimism setup failed"
)
catalog_result = {
    ok = true,
    kind = "download_requests",
    payload = {
        requests = {
            {
                id = "durable-refresh-a",
                root_jellyfin_id = "durable-refresh-a",
                kind = "album",
                state = "queued",
                created_at = 20,
            },
            {
                id = "durable-refresh-a-old",
                root_jellyfin_id = "durable-refresh-a",
                kind = "album",
                state = "failed",
                created_at = 10,
            },
            {
                id = "offline-selection",
                root_jellyfin_id = "offline-selection",
                kind = "selection",
                state = "queued",
            },
        },
    },
    status = 200,
}
runtime_poll()
assert(
    startup_reconcile and
        startup_reconcile.remote_operations[1]
            .root_jellyfin_id == "durable-refresh-a" and
        #startup_reconcile.remote_operations == 1 and
        startup_reconcile.cleanup_unconfirmed == true,
    "durable startup set was not reconciled"
)
assert(
    startup_reconcile.remote_keys[
        "id:durable-refresh-a"
    ] == true,
    "observed durable key was omitted"
)
assert(
    startup_reconcile.remote_keys[
        "id:stale-optimistic-a"
    ] ~= true,
    "local optimism contaminated observed remote keys"
)
assert(
    #failed_attempts == 0 and
        #completed_attempts == 0,
    "older same-album terminal superseded newer active request"
)
assert(
    runtime.item_state(stale_optimistic) ~= "queued" and
        runtime.item_state(stale_optimistic) ~= "downloading",
    "successful omission left stale local optimism authoritative"
)

local item = {
    jellyfin_id = "refresh-album",
    kind = "album",
    title = "Refresh Album",
    device = {state = "server_only"},
}

-- Manifest observation failure is separate from an accepted remote download.
assert(runtime.note_queued(item))
assert(owner_states[item.jellyfin_id] == "downloading")
-- The real sync_download_state owner always exposes an accepted head through
-- operations(). This lifecycle test uses a lightweight owner mock, so mirror
-- that durable accepted-download state before asserting status-bar activity.
owner_operations = {
    {
        id = "refresh-album-operation",
        key = "id:refresh-album",
        item = item,
        status = "downloading",
        dispatched = true,
    },
}
runtime.request_refresh()
runtime_poll()
assert(manifest_busy and refresh_starts == 1)
local active_before_timeout = runtime.activity()
assert(active_before_timeout.mode == "indeterminate")
assert(
    active_before_timeout.phase == "downloading",
    "manifest refresh replaced active-download indicator"
)

manifest_result = {
    ok = false,
    status = 0,
    error = "curl timed out",
}
runtime_poll()
assert(not manifest_busy, "busy did not clear after timeout")
local active_after_timeout = runtime.activity()
assert(
    active_after_timeout.mode == "indeterminate" and
        active_after_timeout.phase == "downloading",
    "manifest timeout replaced or cleared accepted-download indicator"
)
assert(
    owner_states[item.jellyfin_id] == "downloading",
    "timeout terminated the accepted download"
)

-- Failure schedules a bounded retry rather than restarting every poll.
runtime_poll()
assert(refresh_starts == 1, "failed refresh restarted immediately")
now = now + 15000
runtime_poll()
assert(manifest_busy and refresh_starts == 2)

manifest_result = {
    ok = false,
    status = 503,
    error = "manifest HTTP error",
}
runtime_poll()
assert(not manifest_busy, "busy did not clear after HTTP error")
local active_after_http_error = runtime.activity()
assert(
    active_after_http_error.mode == "indeterminate" and
        active_after_http_error.phase == "downloading",
    "manifest HTTP error replaced or cleared accepted-download indicator"
)
assert(
    owner_states[item.jellyfin_id] == "downloading",
    "HTTP error terminated the accepted download"
)

now = now + 15000
runtime_poll()
assert(manifest_busy and refresh_starts == 3)

reconcile_plan = {
    download = {},
    artwork = {},
    actions = {},
}
manifest_result = {
    ok = true,
    manifest = {device = {id = "sim"}, items = {}},
}
runtime_poll()
assert(not manifest_busy, "busy did not clear after success")
assert(
    owner_states[item.jellyfin_id] == "downloading",
    "successful observation lost active owner before reconciliation"
)

-- The successful observation finalizes through the existing library path.
reconcile_completed_key = item.jellyfin_id
library_start_enabled = true
runtime_poll()
assert(library_busy, "library reconciliation did not start")
local remaining_item = {
    jellyfin_id = "remaining-fifo-album",
    kind = "album",
    title = "Remaining FIFO Album",
    device = {state = "queued"},
}
assert(runtime.note_queued(remaining_item))
owner_operations = {
    {
        id = "remaining-fifo-operation",
        key = "id:remaining-fifo-album",
        item = remaining_item,
        status = "queued",
    },
}
library_result = {ok = true, library = {tracks = {}, albums = {}}}
runtime_poll()
assert(runtime.activity().mode == "idle")
assert(owner_reconciles > 0, "successful observation did not reconcile owner")
assert(
    owner_states[item.jellyfin_id] == "downloaded",
    "successful observation did not complete owner state=" ..
        tostring(owner_states[item.jellyfin_id]) ..
        " library_busy=" .. tostring(library_busy) ..
        " catalog_kind=" .. tostring(catalog_kind)
)
assert(
    runtime.item_state(remaining_item) == "queued",
    "completion cleared the next FIFO operation's optimism"
)
owner_operations = {}

-- An explicit terminal operation failure still changes the owner to failed.
local failed_item = {
    jellyfin_id = "explicit-failure",
    kind = "album",
    title = "Explicit Failure",
    device = {state = "server_only"},
}
assert(runtime.note_queued(failed_item))
assert(runtime.note_failed(failed_item))
assert(
    owner_states[failed_item.jellyfin_id] == "failed",
    "explicit terminal operation failure was not retained"
)

catalog_busy_override = true
assert(
    runtime.activity().mode == "idle",
    "routine catalog refresh activated the user-visible sync indicator"
)
catalog_busy_override = false
assert(
    runtime.activity().mode == "idle",
    "refresh indicator remained active while idle"
)

-- A failed durable observation supplies no negative evidence and therefore
-- cannot clear locally retained lifecycle state.
local failure_preserved = {
    jellyfin_id = "durable-failure-preserved",
    kind = "album",
    title = "Durable Failure Preserved",
    device = {state = "server_only"},
}
assert(runtime.note_queued(failure_preserved))
now = 61000
runtime_poll()
assert(
    catalog_kind == "download_requests" and
        durable_starts == 2,
    "bounded durable follow-up did not start"
)
catalog_result = {
    ok = false,
    kind = "download_requests",
    status = 502,
    error = "durable observation failed",
}
runtime_poll()
assert(
    runtime.item_state(failure_preserved) == "queued",
    "failed durable observation destructively cleared local state"
)
assert(
    owner_states[failure_preserved.jellyfin_id] == "downloading",
    "failed durable observation removed the accepted owner operation"
)

-- Durable terminal records are forwarded by exact companion request ID. They
-- never use album identity when no matching owner attempt exists.
local current_failed_item = {
    jellyfin_id = "terminal-current-failed-album",
    kind = "album",
    title = "Terminal Current Failed",
    device = {state = "server_only"},
}
assert(runtime.note_queued(current_failed_item))
matching_failed_attempt_id =
    "terminal-current-failed-request"
now = 76000
runtime_poll()
assert(
    catalog_kind == "download_requests" and
        durable_starts == 3,
    "durable retry after observation failure did not start"
)
catalog_result = {
    ok = true,
    kind = "download_requests",
    status = 200,
    payload = {
        requests = {
            {
                id = "terminal-complete-request-2",
                root_jellyfin_id = "terminal-complete-album",
                kind = "album",
                state = "downloaded",
                created_at = 30,
            },
            {
                id = "terminal-failed-request-2",
                root_jellyfin_id = "terminal-failed-album",
                kind = "album",
                state = "failed",
                created_at = 40,
                error = "terminal failure",
            },
            {
                id = matching_failed_attempt_id,
                root_jellyfin_id =
                    current_failed_item.jellyfin_id,
                kind = "album",
                state = "failed",
                created_at = 50,
                error = "current terminal failure",
            },
        },
    },
}
runtime_poll()
assert(
    completed_attempts[#completed_attempts] ==
        "terminal-complete-request-2",
    "durable completion did not use exact request ID"
)
assert(
    runtime.local_downloaded_at({
        kind = "album",
        jellyfin_id =
            "terminal-complete-album",
    }) == 30,
    "durable downloaded request did not expose device download recency"
)
assert(
    failed_attempts[#failed_attempts] ==
        matching_failed_attempt_id,
    "durable failure did not use exact request ID"
)
assert(
    runtime.item_state(current_failed_item) == "failed",
    "matching durable failure retained queued optimism"
)
assert(
    runtime.activity().mode == "error",
    "matching durable failure did not stop download lifecycle"
)

print("Sync runtime refresh lifecycle passed")
os.exit(0)

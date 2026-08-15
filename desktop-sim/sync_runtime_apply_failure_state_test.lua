package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
require("mocks").install(lvgl)

local now = 1000
local manifest_busy = false
local manifest_result = nil
local apply_busy = false
local apply_result = nil
local apply_states = {}
local apply_starts = 0
local dispatches = {}

local album_a = {
    jellyfin_id = "apply-failure-a",
    kind = "album",
    title = "Apply Failure A",
    device = {state = "server_only"},
}
local album_b = {
    jellyfin_id = "apply-failure-b",
    kind = "album",
    title = "Apply Failure B",
    child_track_ids = {"apply-failure-b-track"},
    device = {state = "server_only"},
}
local manifest_album_b = {
    jellyfin_id = album_b.jellyfin_id,
    kind = album_b.kind,
    title = album_b.title,
    child_track_ids = album_b.child_track_ids,
    device = {state = "server_only"},
}

local plan = {
    download = {{item = manifest_album_b}},
    artwork = {},
    actions = {
        {kind = "media", item = album_a},
        {kind = "media", item = manifest_album_b},
    },
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {tracks = {}, albums = {}}
    end,
}
package.loaded["sync_apply"] = {
    busy = function() return apply_busy end,
    progress = function() return nil end,
    current = function() return nil end,
    start = function()
        apply_starts = apply_starts + 1
        apply_busy = true
        apply_states[album_b.jellyfin_id] =
            "downloading"
        return true
    end,
    poll = function()
        local result = apply_result
        apply_result = nil
        if result then
            apply_busy = false
            apply_states = {}
        end
        return result
    end,
    generation = function() return 0 end,
    item_states = function() return apply_states end,
    pending_items = function() return {} end,
}
package.loaded["sync_artwork_cache"] = {
    busy = function() return false end,
    poll = function() end,
}
package.loaded["sync_catalog"] = {
    queue = function(item)
        dispatches[#dispatches + 1] =
            item.jellyfin_id
        return true
    end,
}
package.loaded["sync_config"] = {
    status = function() return {connected = true} end,
}
package.loaded["sync_inventory_report"] = {
    busy = function() return false end,
    poll = function() return nil end,
    start = function() return false end,
}
package.loaded["sync_library_artwork"] = {
    busy = function() return false end,
    poll = function() return nil end,
    start = function() return false end,
}
package.loaded["sync_library_refresh"] = {
    busy = function() return false end,
    poll = function() return nil end,
    start = function() return false end,
    progress = function() return nil end,
}
package.loaded["sync_library_view"] = {
    current = function() return nil, nil, nil end,
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
        manifest_busy = true
        return true
    end,
}
package.loaded["sync_offline_bootstrap"] = {
    initial_sync_complete = function() return true end,
    busy = function() return false end,
    poll = function() return nil end,
    start = function() return false end,
    initial_sync_required = function() return false end,
    mark_initial_sync_complete = function() return true end,
}
package.loaded["sync_operation_flush"] = {
    busy = function() return false end,
    poll = function() return nil end,
}
package.loaded["sync_operation_queue"] = {
    status = function() return {pending = 0} end,
}
package.loaded["sync_reconcile"] = {
    plan = function() return plan end,
}
package.loaded["time"] = {
    ticks = function() return now end,
}

package.loaded["sync_download_state"] = nil
local owner = require("sync_download_state")
owner.reset_for_tests()

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

-- A is active while B is queued in both owner and optimistic runtime state.
assert(owner.request(album_a))
assert(runtime.note_queued(album_a))
assert(owner.request(album_b))
assert(runtime.note_queued(album_b))
local original_b_attempt = {
    jellyfin_id = album_b.jellyfin_id,
    kind = album_b.kind,
    title = album_b.title,
    child_track_ids = album_b.child_track_ids,
    device = {
        state = album_b.device.state,
        download_operation_id =
            album_b.device.download_operation_id,
    },
}
assert(owner.lookup(album_a).state == "downloading")
assert(owner.lookup(album_b).state == "queued")
assert(runtime.item_state(album_a) == "queued")
assert(runtime.item_state(album_b) == "queued")
assert(#dispatches == 1 and dispatches[1] == album_a.jellyfin_id)

-- Enter apply and terminate B with an explicit apply result.
runtime.request_refresh()
runtime_poll()
assert(manifest_busy)
manifest_result = {
    ok = true,
    manifest = {
        device = {id = "sim"},
        items = {album_a, album_b},
    },
}
runtime_poll()
assert(apply_busy and apply_starts == 1)
assert(
    manifest_album_b.device.download_operation_id ==
        original_b_attempt.device.download_operation_id,
    "apply session was not bound to the exact owner attempt"
)

apply_result = {
    ok = false,
    error = "explicit apply failure",
    failed_action = {
        kind = "media",
        item = manifest_album_b,
    },
}
runtime_poll()
assert(not apply_busy)

assert(
    runtime.item_state(album_b) == "failed",
    "failed B retained stale queued optimism"
)
local failed_projection = owner.lookup(album_b)
assert(failed_projection.state == "failed", "owner failure was overwritten")
assert(failed_projection.can_retry == true, "failed B did not expose retry")
assert(owner.lookup(album_a).state == "downloading", "failure changed A owner")
assert(runtime.item_state(album_a) == "queued", "failure cleared A optimism")
assert(#dispatches == 1, "failure redispatched A")
assert(
    runtime.activity().mode ~= "error",
    "tail failure terminated the unrelated active lifecycle"
)

-- Ordinary polling cannot erase the terminal state.
for _ = 1, 5 do
    runtime_poll()
end
assert(runtime.item_state(album_b) == "failed")
assert(owner.lookup(album_b).state == "failed")
assert(owner.lookup(album_b).can_retry == true)

-- Explicit retry creates a fresh queued operation without disturbing A.
assert(owner.request(album_b))
assert(runtime.note_queued(album_b))
assert(owner.lookup(album_b).state == "queued")
assert(owner.lookup(album_b).can_retry == false)
assert(owner.lookup(album_a).state == "downloading")
assert(#dispatches == 1, "queued retry bypassed active A")

-- A delayed apply failure carrying B's old attempt identity cannot fail the
-- newer same-album retry.
local retry_operation = owner.operations()[2]
local retry_generation = owner.generation()
now = now + 15000
runtime_poll()
assert(apply_busy and apply_starts == 2,
    "retry apply session did not start")
apply_result = {
    ok = false,
    error = "stale apply failure",
    failed_action = {
        kind = "media",
        item = original_b_attempt,
    },
}
runtime_poll()
local after_stale = owner.operations()[2]
assert(after_stale and after_stale.id == retry_operation.id)
assert(after_stale.status == retry_operation.status)
assert(owner.generation() == retry_generation)
assert(owner.lookup(album_b).state == "queued")
assert(runtime.item_state(album_b) == "queued")
assert(#dispatches == 1, "stale apply failure redispatched work")

-- If a different durable request for B is observed, an album-keyed manifest
-- action is ambiguous and must not be attached to the newer local retry.
owner.reconcile_startup({
    remote_operations = {
        {
            id = "historical-remote-b",
            root_jellyfin_id = album_b.jellyfin_id,
            kind = "album",
            state = "downloading",
        },
    },
    remote_keys = {
        [owner.key(album_a)] = true,
    },
    cleanup_unconfirmed = false,
})
assert(owner.operations()[2].attempt_conflicted)
now = now + 15000
runtime_poll()
assert(apply_busy and apply_starts == 3,
    "ambiguous apply session did not start")
assert(
    manifest_album_b.device.download_attempt_ambiguous == true and
        manifest_album_b.device.download_operation_id == nil,
    "ambiguous manifest action was attached to the local retry"
)
local before_ambiguous_generation = owner.generation()
apply_result = {
    ok = false,
    error = "ambiguous historical apply failure",
    failed_action = {
        kind = "media",
        item = manifest_album_b,
    },
}
runtime_poll()
assert(owner.generation() == before_ambiguous_generation)
assert(owner.lookup(album_b).state == "queued")
assert(runtime.item_state(album_b) == "queued")

-- Explicit companion rejection already replaces queued optimism with failed.
local rejected = {
    jellyfin_id = "companion-rejected",
    kind = "album",
    title = "Companion Rejected",
    device = {state = "server_only"},
}
assert(runtime.note_queued(rejected))
assert(runtime.note_failed(rejected))
assert(runtime.item_state(rejected) == "failed")
assert(owner.lookup(rejected).state == "failed")
assert(runtime.item_state(album_a) == "queued")
assert(owner.lookup(album_a).state == "downloading")

print("Sync runtime apply failure state passed")
os.exit(0)

package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local json = require("json")
local pending = nil
local response = nil
local posts = {}
local gets = {}

package.loaded["device_identity"] = {
    id = function() return "async-device" end,
    download_requests_path = function()
        return "/devices/async-device/download-requests"
    end,
}
package.loaded["sync_client"] = {
    busy = function() return pending ~= nil end,
    post = function(path, body, owner)
        pending = {path = path, body = body, owner = owner}
        posts[#posts + 1] = pending
        return true
    end,
    get = function(path, owner)
        pending = {method = "GET", path = path, owner = owner}
        gets[#gets + 1] = pending
        return true
    end,
    poll = function(owner)
        if not pending or pending.owner ~= owner or
            response == nil then
            return nil
        end
        pending = nil
        local completed = response
        response = nil
        return completed
    end,
}
package.loaded["time"] = {
    ticks = function() return 4242 end,
}
package.loaded["jellyfin_local_index"] = {
    load = function() return {tracks = {}, albums = {}} end,
}
package.loaded["sync_runtime"] = {
    content_generation = function() return 0 end,
    item_state = function() return nil end,
    apply_progress = function() return nil end,
}

package.loaded["sync_catalog"] = nil
package.loaded["sync_download_state"] = nil
local catalog = require("sync_catalog")
local state = require("sync_download_state")

local function album(id)
    return {
        jellyfin_id = id,
        kind = "album",
        title = id,
        device = {state = "server_only"},
    }
end

local function install_dispatcher()
    state.set_dispatcher(function(item, operation)
        return catalog.queue(item, function(result)
            local payload = result.payload or {}
            state.resolve_dispatch(
                operation.id,
                result.ok == true,
                {
                    status = result.status,
                    replayed = payload.replayed == true,
                    error = result.error,
                }
            )
        end)
    end)
end

state.reset_for_tests()
state.set_dispatcher(nil)
local unwired = album("async-unwired")
assert(state.request(unwired))
assert(state.lookup(unwired).state == "queued")
assert(not state.operations()[1].dispatched,
    "missing dispatcher was treated as acceptance")
local wired_dispatches = 0
state.set_dispatcher(function()
    wired_dispatches = wired_dispatches + 1
    return true
end)
state.pump_dispatch("runtime-wired")
assert(wired_dispatches == 1)
assert(state.lookup(unwired).state == "downloading")

state.reset_for_tests()
install_dispatcher()
local a = album("async-a")
local b = album("async-b")
local accepted, detail = state.request(a)
assert(accepted and detail.state == "queued")
assert(state.operations()[1].dispatched == false)
assert(state.lookup(a).state == "queued")
assert(#posts == 1)
assert(json.decode(posts[1].body).jellyfin_item_id == "async-a")

assert(state.request(b))
assert(state.lookup(b).state == "queued")
for _ = 1, 5 do
    state.pump_dispatch("poll")
end
assert(#posts == 1, "in-flight head emitted duplicate POSTs")

response = {
    ok = true,
    status = 202,
    body = '{"request":{"id":"request-a","state":"queued"},"replayed":false}',
}
assert(catalog.poll().ok)
assert(state.lookup(a).state == "downloading")
assert(state.lookup(b).state == "queued")
assert(#posts == 1, "B posted before A became active/terminal")

assert(state.complete(a))
assert(#posts == 2, "B promotion did not POST exactly once")
assert(state.lookup(b).state == "queued")
for _ = 1, 5 do
    state.pump_dispatch("poll")
end
assert(#posts == 2, "B promotion duplicated its POST")

response = {
    ok = true,
    status = 200,
    body = '{"request":{"id":"request-b","state":"queued"},"replayed":true}',
}
assert(catalog.poll().ok)
assert(state.lookup(b).state == "downloading")

state.reset_for_tests()
install_dispatcher()
local already_durable = album("async-already-durable")
assert(state.request(already_durable))
response = {
    ok = false,
    status = 409,
    body = '{"error":"already queued",' ..
        '"code":"already_downloaded_or_queued"}',
}
assert(catalog.poll().ok)
assert(state.lookup(already_durable).state == "downloading")

state.reset_for_tests()
install_dispatcher()
local rejected = album("async-rejected")
assert(state.request(rejected))
response = {
    ok = false,
    status = 400,
    body = '{"error":"invalid request"}',
}
local rejection = catalog.poll()
assert(rejection and rejection.ok == false)
assert(state.lookup(rejected).state == "failed")
assert(state.lookup(rejected).can_retry == true)

state.reset_for_tests()
install_dispatcher()
local timed_out = album("async-timeout")
assert(state.request(timed_out))
response = {
    ok = false,
    status = 0,
    body = "",
    error = "request timed out",
}
local timeout = catalog.poll()
assert(timeout and timeout.ok == false)
assert(state.lookup(timed_out).state == "failed")
assert(state.lookup(timed_out).can_retry == true)
assert(state.request(timed_out), "timeout did not clear dispatch lock for retry")
response = {
    ok = true,
    status = 202,
    body = '{"request":{"id":"request-timeout-retry","state":"queued"}}',
}
assert(catalog.poll().ok)

local durable_result = nil
assert(catalog.download_requests(function(result)
    durable_result = result
end))
assert(#gets == 1)
assert(gets[1].path == "/devices/async-device/download-requests")
response = {
    ok = true,
    status = 200,
    body = '{"requests":[{"id":"request-timeout-retry",' ..
        '"root_jellyfin_id":"async-timeout",' ..
        '"kind":"album","state":"queued"}]}',
}
assert(catalog.poll().kind == "download_requests")
assert(durable_result.payload.requests[1].root_jellyfin_id == "async-timeout")

-- Exercise the production runtime callback gate. The callback is bound to an
-- operation ID, not merely the canonical album key reused by retries.
local runtime_callbacks = {}
local runtime_posts = {}
package.loaded["lvgl"] = {}
package.loaded["sync_apply"] = {
    busy = function() return false end,
    progress = function() return nil end,
    generation = function() return 0 end,
    item_states = function() return {} end,
    pending_items = function() return {} end,
}
package.loaded["sync_artwork_cache"] = {
    busy = function() return false end,
}
package.loaded["sync_config"] = {
    status = function() return {connected = true} end,
}
package.loaded["sync_library_refresh"] = {
    busy = function() return false end,
    progress = function() return nil end,
}
package.loaded["sync_library_artwork"] = {
    busy = function() return false end,
}
package.loaded["sync_library_view"] = {
    current = function() return nil, nil, nil end,
}
package.loaded["sync_inventory_report"] = {
    busy = function() return false end,
}
package.loaded["sync_operation_flush"] = {
    busy = function() return false end,
}
package.loaded["sync_offline_bootstrap"] = {
    busy = function() return false end,
}
package.loaded["sync_operation_queue"] = {
    status = function() return {pending = 0} end,
}
package.loaded["sync_managed_paths"] = {
    load = function() return {}, nil, false end,
}
package.loaded["sync_manifest_state"] = {
    busy = function() return false end,
}
package.loaded["sync_reconcile"] = {}
package.loaded["sync_client"] = {
    busy = function() return false end,
}
package.loaded["sync_catalog"] = {
    queue = function(item, callback)
        runtime_posts[#runtime_posts + 1] =
            item.jellyfin_id
        runtime_callbacks[#runtime_callbacks + 1] =
            callback
        return true, "pending"
    end,
}
package.loaded["sync_runtime"] = nil
local runtime = require("sync_runtime")

local function assert_retry_unchanged(
    label,
    stale_result
)
    state.reset_for_tests()
    state.set_dispatcher(runtime.dispatch_download)
    runtime_callbacks = {}
    runtime_posts = {}

    local retry_item = album("race-" .. label .. "-a")
    local other_item = album("race-" .. label .. "-b")
    assert(state.request(retry_item))
    local op1 = state.operations()[1]
    local old_callback = runtime_callbacks[1]
    assert(type(old_callback) == "function")

    -- A separate authoritative lifecycle decision supersedes op1 before its
    -- delayed transport callback arrives.
    assert(state.resolve_dispatch(op1.id, false, {
        error = "superseded attempt",
    }))
    assert(runtime.note_failed(retry_item))
    assert(state.request(retry_item))
    local op2 = state.operations()[1]
    assert(op2.id ~= op1.id, label .. ": retry reused operation ID")
    assert(op2.key == op1.key, label .. ": retry changed canonical key")
    assert(op2.dispatched == false, label .. ": retry not pending")
    assert(state.request(other_item))
    local before_operations = state.operations()
    local before_owner_generation = state.generation()
    local before_runtime_generation = runtime.state_generation()
    local notifications = 0
    local unsubscribe = state.subscribe(function()
        notifications = notifications + 1
    end)

    local function assert_unchanged(stage)
        local after_operations = state.operations()
        assert(#after_operations == 2,
            label .. ": " .. stage .. " removed an op")
        assert(after_operations[1].id == op2.id,
            label .. ": " .. stage .. " replaced the retry")
        assert(after_operations[1].dispatched == false,
            label .. ": " .. stage .. " accepted the retry")
        assert(after_operations[2].id == before_operations[2].id,
            label .. ": " .. stage .. " changed other album")
        assert(#runtime_posts == 2,
            label .. ": " .. stage .. " dispatched another POST")
        assert(state.generation() == before_owner_generation,
            label .. ": " .. stage .. " notified owner subscribers")
        assert(runtime.state_generation() == before_runtime_generation,
            label .. ": " .. stage .. " mutated runtime state")
        assert(notifications == 0,
            label .. ": " .. stage .. " notified mounted consumers")
    end

    -- The preserved old operation table contains both op1.id and the album
    -- key shared by op2. Its ID must prevent any key-based alias to op2.
    local table_resolved = state.resolve_dispatch(
        op1,
        stale_result.ok == true,
        {
            status = stale_result.status,
            error = stale_result.error,
        }
    )
    assert(table_resolved == false,
        label .. ": stale operation table resolved against retry")
    assert_unchanged("stale operation table")

    -- There is no current key-only dispatch callback caller. Keep the API
    -- attempt-specific rather than allowing a missing ID to select op2.
    local key_only_resolved = state.resolve_dispatch(
        {key = op2.key},
        true,
        {status = 202}
    )
    assert(key_only_resolved == false,
        label .. ": key-only resolution reached retry")
    assert_unchanged("key-only resolution")

    old_callback(stale_result)
    assert_unchanged("stale runtime callback")
    unsubscribe()

    -- The callback belonging to op2 still owns normal acceptance.
    runtime_callbacks[2]({
        ok = true,
        status = 202,
        payload = {
            replayed = false,
            request = {
                id = "request-" .. label .. "-2",
            },
        },
    })
    assert(state.operations()[1].id == op2.id,
        label .. ": current callback lost retry")
    assert(state.operations()[1].dispatched == true,
        label .. ": current callback did not accept retry")
    assert(
        state.operations()[1].request_id ==
            "request-" .. label .. "-2",
        label .. ": durable request ID was not retained"
    )
    assert(state.lookup(retry_item).state == "downloading")
    assert(state.lookup(other_item).state == "queued")
    assert(#runtime_posts == 2,
        label .. ": current acceptance prematurely dispatched B")
end

assert_retry_unchanged("failure", {
    ok = false,
    status = 400,
    error = "delayed rejection",
})
assert_retry_unchanged("success", {
    ok = true,
    status = 202,
    payload = {replayed = false},
})
assert_retry_unchanged("timeout", {
    ok = false,
    status = 0,
    error = "delayed timeout",
})

-- A matching failure callback still follows the normal terminal path.
state.reset_for_tests()
state.set_dispatcher(runtime.dispatch_download)
runtime_callbacks = {}
runtime_posts = {}
local current_failure = album("race-current-failure")
assert(state.request(current_failure))
local current_failure_id = state.operations()[1].id
runtime_callbacks[1]({
    ok = false,
    status = 400,
    error = "current rejection",
})
assert(state.lookup(current_failure).state == "failed")
assert(state.lookup(current_failure).can_retry == true)
assert(#state.operations() == 0)
assert(current_failure_id ~= nil)

print("Async download dispatch acknowledgement passed")

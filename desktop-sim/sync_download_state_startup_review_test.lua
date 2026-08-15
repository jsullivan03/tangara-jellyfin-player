package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local local_library = {tracks = {}, albums = {}}
local local_content_generation = 0
package.loaded["jellyfin_local_index"] = {
    load = function()
        return local_library
    end,
}
package.loaded["sync_runtime"] = {
    content_generation = function()
        return local_content_generation
    end,
    item_state = function() return nil end,
    apply_progress = function() return nil end,
}

package.loaded["sync_download_state"] = nil
local state = require("sync_download_state")

local function album(id)
    return {
        jellyfin_id = id,
        kind = "album",
        title = id,
        device = {state = "server_only"},
    }
end

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(
            label .. " expected " ..
                tostring(expected) .. " got " ..
                tostring(actual)
        )
    end
end

local dispatches
local function reset(dispatch_ok)
    state.reset_for_tests()
    local_library = {tracks = {}, albums = {}}
    local_content_generation =
        local_content_generation + 1
    dispatches = {}
    state.set_dispatcher(function(_, operation)
        dispatches[#dispatches + 1] = operation.key
        if dispatch_ok == false then
            return false, "busy"
        end
        return true
    end)
end

-- A stale local head cannot hide the different operation confirmed remotely.
reset()
local stale_a = album("startup-stale-a")
local remote_b = album("startup-remote-b")
assert(state.request(stale_a))
assert(state.request(remote_b))
state.reconcile_startup({
    remote_keys = {"id:startup-remote-b"},
    remote_busy = true,
})
local ops = state.operations()
assert_eq(ops[1].key, "id:startup-remote-b", "remote B becomes head")
assert(ops[1].dispatched, "remote B was not preserved")
assert_eq(state.lookup(stale_a).state, "failed", "stale A cleared")
assert_eq(state.lookup(remote_b).state, "downloading", "remote B active")
assert_eq(#dispatches, 1, "remote B was dispatched twice")

-- Matching active A remains active when both key and busy agree.
reset()
local active_a = album("startup-active-a")
assert(state.request(active_a))
state.reconcile_startup({
    remote_keys = {["id:startup-active-a"] = true},
    remote_busy = true,
})
assert_eq(state.lookup(active_a).state, "downloading", "active A preserved")
assert_eq(#dispatches, 1, "active A duplicated")

-- A canonical remote-key match is stronger than an inconsistent busy=false.
reset(false)
local inconsistent_a = album("startup-inconsistent-a")
assert(state.request(inconsistent_a))
assert_eq(state.lookup(inconsistent_a).state, "queued", "A initially queued")
state.reconcile_startup({
    remote_keys = {"id:startup-inconsistent-a"},
    remote_busy = false,
})
assert_eq(
    state.lookup(inconsistent_a).state,
    "downloading",
    "remote key did not confirm A"
)
assert_eq(#dispatches, 1, "remote-confirmed A was redispatched")

-- Reconcile multiple locally dispatched markers against exactly one remote key.
reset()
local multi_a = album("startup-multi-a")
local multi_b = album("startup-multi-b")
local multi_c = album("startup-multi-c")
assert(state.request(multi_a))
assert(state.request(multi_b))
assert(state.request(multi_c))
state.reconcile_startup({
    remote_keys = {
        ["id:startup-multi-a"] = true,
        ["id:startup-multi-b"] = true,
    },
    remote_busy = true,
})
ops = state.operations()
assert(ops[1].dispatched and ops[2].dispatched,
    "remote-confirmed operations were not retained")
state.reconcile_startup({
    remote_keys = {["id:startup-multi-b"] = true},
    remote_busy = true,
})
ops = state.operations()
assert_eq(ops[1].key, "id:startup-multi-b", "only remote B retained")
assert(ops[1].dispatched, "remote B lost dispatch confirmation")
assert_eq(state.lookup(multi_a).state, "failed", "stale dispatched A cleared")
assert_eq(state.lookup(multi_c).state, "queued", "unconfirmed C remains queued")
assert_eq(#dispatches, 1, "startup reconciliation duplicated dispatch")

-- With no remote operation, a stale dispatched marker is cleaned for retry.
reset()
local abandoned = album("startup-abandoned")
assert(state.request(abandoned))
state.reconcile_startup({remote_keys = {}, remote_busy = false})
assert_eq(state.lookup(abandoned).state, "failed", "abandoned op not cleaned")
assert_eq(#state.operations(), 0, "abandoned op still occupies FIFO")
assert_eq(#dispatches, 1, "abandoned op was automatically duplicated")

-- Durable companion operations reconstruct an empty in-memory owner by the
-- canonical Phase 1 album key and remain authoritative without a manifest.
reset()
state.reconcile_startup({
    remote_operations = {
        {
            id = "durable-a-queued",
            root_jellyfin_id = "durable-a",
            kind = "album",
            state = "queued",
            title = "Durable A",
            artist = "Durable Artist",
            total_tracks = 8,
            track_ids = {"a-1", "a-2"},
            created_at = 20,
        },
        {
            id = "durable-a-active",
            root_jellyfin_id = "durable-a",
            kind = "album",
            state = "downloading",
            title = "Durable A",
            created_at = 10,
        },
        {
            id = "durable-b",
            root_jellyfin_id = "durable-b",
            kind = "album",
            state = "queued",
            title = "Durable B",
            created_at = 30,
        },
    },
    cleanup_unconfirmed = true,
})
ops = state.operations()
assert_eq(#ops, 2, "durable duplicate album created duplicate operations")
assert_eq(ops[1].key, "id:durable-a", "durable A canonical key")
assert_eq(ops[2].key, "id:durable-b", "durable B canonical key")
assert_eq(ops[1].id, "durable-a-active",
    "durable A request ID was not retained as operation ID")
assert_eq(ops[2].id, "durable-b",
    "durable B request ID was not retained as operation ID")
assert_eq(state.lookup("id:durable-a").state, "downloading", "durable A state")
assert_eq(state.lookup("id:durable-b").state, "queued", "durable B state")
local placeholders = state.pending_placeholders()
assert_eq(#placeholders, 2, "durable Local placeholders missing")
assert_eq(
    placeholders[1].item.title,
    "Durable A",
    "durable metadata not preserved"
)
state.pump_dispatch("manifest-502")
assert_eq(#dispatches, 0, "durable request was redispatched")
assert_eq(
    state.lookup("id:durable-a").state,
    "downloading",
    "manifest observation failure erased durable A"
)

-- An authoritative empty startup set removes even an undispatched stale op.
reset(false)
local undispatched = album("startup-undispatched")
assert(state.request(undispatched))
assert_eq(state.lookup(undispatched).state, "queued", "setup queued state")
state.reconcile_startup({
    remote_operations = {},
    remote_keys = {},
    cleanup_unconfirmed = true,
})
assert_eq(#state.operations(), 0, "absent stale local op survived")
assert_eq(state.lookup(undispatched).state, "failed", "stale local was not failed")

-- A POST that has not resolved is protected by the owner's private in-flight
-- lifecycle, but a successful empty observation does not confirm it remotely.
state.reset_for_tests()
dispatches = {}
state.set_dispatcher(function(_, operation)
    dispatches[#dispatches + 1] = operation.key
    return true, "pending"
end)
local pending_a = album("startup-pending-a")
assert(state.request(pending_a))
assert_eq(state.lookup(pending_a).state, "queued", "pending A public state")
state.reconcile_startup({
    remote_operations = {},
    remote_keys = {},
    cleanup_unconfirmed = true,
})
ops = state.operations()
assert_eq(#ops, 1, "dispatch-pending A was destructively removed")
assert_eq(ops[1].key, "id:startup-pending-a", "pending A key")
assert(not ops[1].dispatched, "pending A was classified as observed remote")
assert_eq(#dispatches, 1, "pending A was posted twice")
assert(state.resolve_dispatch(ops[1].id, true, {status = 202}))
assert_eq(state.lookup(pending_a).state, "downloading", "accepted A not retained")
assert_eq(#dispatches, 1, "accepted A was reposted before durable poll")

-- The accepted POST can finish after the durable GET snapshot was taken.
-- One omission consumes the grace observation; a later omission can clear it.
state.reconcile_startup({
    remote_operations = {},
    remote_keys = {},
    cleanup_unconfirmed = false,
})
assert_eq(#state.operations(), 1,
    "first omission erased newly accepted A")
assert_eq(state.lookup(pending_a).state, "downloading",
    "first omission changed accepted A")
state.reconcile_startup({
    remote_operations = {},
    remote_keys = {},
    cleanup_unconfirmed = false,
})
assert_eq(#state.operations(), 0,
    "second omission did not clear stale accepted A")

-- Initial cleanup targets only operations that existed at runtime startup;
-- a request created while the first durable GET is in flight is preserved.
reset()
local startup_old = album("startup-boundary-old")
local startup_new = album("startup-boundary-new")
assert(state.request(startup_old))
local startup_old_id = state.operations()[1].id
assert(state.request(startup_new))
state.reconcile_startup({
    remote_operations = {},
    remote_keys = {},
    cleanup_unconfirmed = true,
    cleanup_attempt_ids = {
        [startup_old_id] = true,
    },
})
ops = state.operations()
assert_eq(#ops, 1, "startup cleanup removed a new local attempt")
assert_eq(ops[1].key, "id:startup-boundary-new",
    "startup cleanup retained the wrong attempt")

-- A formerly confirmed operation loses that confirmation when a later
-- successful durable observation omits it.
reset()
local formerly_remote_a = album("startup-formerly-remote-a")
state.reconcile_startup({
    remote_operations = {
        {
            id = "durable-former-a",
            root_jellyfin_id = "startup-formerly-remote-a",
            kind = "album",
            state = "downloading",
        },
    },
    cleanup_unconfirmed = false,
})
assert_eq(
    state.lookup(formerly_remote_a).state,
    "downloading",
    "remote A was not reconstructed"
)
state.reconcile_startup({
    remote_operations = {},
    remote_keys = {},
    cleanup_unconfirmed = false,
})
assert_eq(#state.operations(), 0, "omitted confirmed A survived")
assert_eq(
    state.lookup(formerly_remote_a).state,
    "failed",
    "omitted confirmed A did not become retryable"
)
assert_eq(#dispatches, 0, "omitted confirmed A was reposted")

-- Local queued work behind a real remote head remains local-only across later
-- successful observations and is not promoted or dispatched prematurely.
reset()
local real_remote_a = album("startup-real-remote-a")
local local_tail_b = album("startup-local-tail-b")
state.reconcile_startup({
    remote_operations = {
        {
            id = "durable-real-a",
            root_jellyfin_id = "startup-real-remote-a",
            kind = "album",
            state = "downloading",
        },
    },
    cleanup_unconfirmed = true,
})
assert(state.request(local_tail_b))
assert_eq(state.lookup(real_remote_a).state, "downloading", "remote A changed")
assert_eq(state.lookup(local_tail_b).state, "queued", "local B not queued")
state.reconcile_startup({
    remote_operations = {
        {
            id = "durable-real-a",
            root_jellyfin_id = "startup-real-remote-a",
            kind = "album",
            state = "downloading",
        },
    },
    cleanup_unconfirmed = false,
})
ops = state.operations()
assert_eq(#ops, 2, "local B was removed by durable observation")
assert_eq(ops[1].key, "id:startup-real-remote-a", "remote A lost head")
assert_eq(ops[2].key, "id:startup-local-tail-b", "local B lost tail")
assert(not ops[2].dispatched, "local B became remotely confirmed")
assert_eq(#dispatches, 0, "local B was posted before remote A completed")

-- A durable same-album request with a different request ID is represented
-- independently. It must never bind to or confirm the newer local retry.
state.reset_for_tests()
local_library = {tracks = {}, albums = {}}
local_content_generation = local_content_generation + 1
dispatches = {}
state.set_dispatcher(function(_, operation)
    dispatches[#dispatches + 1] = operation.key
    return true, "pending"
end)
local collision_a = album("durable-collision-a")
assert(state.request(collision_a))
local collision_op2 = state.operations()[1]
local collision_notifications = 0
state.subscribe(function()
    collision_notifications = collision_notifications + 1
end)
local collision_generation = state.generation()
local old_remote = {
    id = "durable-collision-request-1",
    root_jellyfin_id = "durable-collision-a",
    kind = "album",
    state = "downloading",
    created_at = 10,
}
state.reconcile_startup({
    remote_operations = {old_remote},
    cleanup_unconfirmed = false,
})
ops = state.operations()
assert_eq(#ops, 1, "remote collision duplicated local FIFO operation")
assert_eq(ops[1].id, collision_op2.id,
    "remote collision replaced local op2")
assert_eq(ops[1].request_id, nil,
    "old durable request ID was attached to op2")
assert(ops[1].attempt_conflicted,
    "same-album remote attempt conflict was not exposed")
assert(not ops[1].dispatched,
    "old durable request accepted dispatch-pending op2")
assert_eq(state.generation(), collision_generation,
    "remote collision changed op2 generation")
assert_eq(collision_notifications, 0,
    "remote collision notified op2")
assert(state.complete_attempt("durable-collision-request-1"),
    "remote shadow completion was not consumed")
assert_eq(state.operations()[1].id, collision_op2.id,
    "remote shadow completion removed op2")
assert_eq(state.generation(), collision_generation,
    "remote shadow completion notified op2")

-- The same protection applies after op2 is accepted under its own request ID
-- and when the old remote attempt later fails.
assert(state.resolve_dispatch(collision_op2.id, true, {
    status = 202,
    request_id = "durable-collision-request-2",
}))
local accepted_generation = state.generation()
state.reconcile_startup({
    remote_operations = {old_remote},
    cleanup_unconfirmed = false,
})
ops = state.operations()
assert_eq(ops[1].id, collision_op2.id,
    "old remote displaced accepted op2")
assert_eq(ops[1].request_id,
    "durable-collision-request-2",
    "old remote rebound accepted op2")
assert(ops[1].attempt_conflicted,
    "accepted op2 lost its old-attempt conflict marker")
assert(ops[1].dispatched,
    "old remote cleared accepted op2 dispatch")
assert_eq(state.lookup(collision_a).state,
    "downloading", "old remote changed accepted op2 state")
assert_eq(state.generation(), accepted_generation,
    "old remote notified accepted op2")
assert(state.fail_attempt("durable-collision-request-1", {
    message = "historical remote failure",
    retriable = true,
}))
assert_eq(state.lookup(collision_a).state,
    "downloading", "remote shadow failure failed op2")
assert_eq(state.operations()[1].request_id,
    "durable-collision-request-2",
    "remote shadow failure changed op2 identity")
assert_eq(state.generation(), accepted_generation,
    "remote shadow failure notified op2")

-- A terminal shadow releases remote capacity and pumps the local head that
-- was waiting behind it, without rebinding the shadow request identity.
state.reset_for_tests()
local_library = {tracks = {}, albums = {}}
local_content_generation = local_content_generation + 1
dispatches = {}
state.set_dispatcher(function(_, operation)
    dispatches[#dispatches + 1] = operation.key
    return true, "pending"
end)
local shadow_tail_b = album("shadow-tail-b")
local remote_head = {
    id = "shadow-remote-head-a",
    root_jellyfin_id = "shadow-head-a",
    kind = "album",
    state = "downloading",
}
local remote_tail = {
    id = "shadow-old-tail-b",
    root_jellyfin_id = "shadow-tail-b",
    kind = "album",
    state = "queued",
}
state.reconcile_startup({remote_operations = {remote_head}})
assert(state.request(shadow_tail_b))
state.reconcile_startup({
    remote_operations = {remote_head, remote_tail},
})
assert_eq(#dispatches, 0, "remote shadow posted local tail early")
assert(state.complete_attempt(remote_head.id))
assert_eq(#dispatches, 0, "shadow did not retain remote capacity")
assert(state.complete_attempt(remote_tail.id))
assert_eq(#dispatches, 1, "terminal shadow did not pump local head")
assert_eq(dispatches[1], "id:shadow-tail-b",
    "terminal shadow dispatched the wrong key")

-- Durable terminal events are attempt-specific. An old request ID cannot
-- complete or fail a newer dispatch-pending retry for the same album.
state.reset_for_tests()
local_library = {tracks = {}, albums = {}}
local_content_generation = local_content_generation + 1
dispatches = {}
state.set_dispatcher(function(_, operation)
    dispatches[#dispatches + 1] = operation.key
    return true, "pending"
end)
local terminal_pending_a = album("terminal-pending-a")
assert(state.request(terminal_pending_a))
local pending_op2 = state.operations()[1]
local terminal_notifications = 0
state.subscribe(function()
    terminal_notifications = terminal_notifications + 1
end)
local terminal_generation = state.generation()
assert(not state.fail_attempt("request-1", {
    message = "historical failure",
    retriable = true,
}))
assert(not state.complete_attempt("request-1"))
assert_eq(state.generation(), terminal_generation,
    "historical terminal changed generation")
assert_eq(terminal_notifications, 0,
    "historical terminal notified retry")
ops = state.operations()
assert_eq(#ops, 1, "historical terminal removed pending op2")
assert_eq(ops[1].id, pending_op2.id,
    "historical terminal replaced pending op2")
assert(not ops[1].dispatched,
    "historical completion accepted pending op2")
assert_eq(#dispatches, 1,
    "historical terminal redispatched pending op2")

-- Binding the accepted POST to request-2 makes its matching durable terminal
-- result valid without replacing the local callback attempt ID.
assert(state.resolve_dispatch(pending_op2.id, true, {
    status = 202,
    request_id = "request-2",
}))
ops = state.operations()
assert_eq(ops[1].id, pending_op2.id,
    "acceptance replaced local operation ID")
assert_eq(ops[1].request_id, "request-2",
    "durable request ID was not retained")
assert(state.complete_attempt("request-2"))
assert_eq(state.lookup(terminal_pending_a).state,
    "downloaded", "matching completion did not complete op2")

-- A historical failure cannot affect a newer active/downloading operation,
-- while that operation's exact durable request ID can fail it normally.
state.reset_for_tests()
local_library = {tracks = {}, albums = {}}
local_content_generation = local_content_generation + 1
dispatches = {}
state.set_dispatcher(function(_, operation)
    dispatches[#dispatches + 1] = operation.key
    return true, "pending"
end)
local terminal_active_a = album("terminal-active-a")
assert(state.request(terminal_active_a))
local active_op2 = state.operations()[1]
assert(state.resolve_dispatch(active_op2.id, true, {
    status = 202,
    request_id = "request-active-2",
}))
terminal_generation = state.generation()
terminal_notifications = 0
state.subscribe(function()
    terminal_notifications = terminal_notifications + 1
end)
assert(not state.fail_attempt("request-active-1", {
    message = "old failure",
    retriable = true,
}))
assert_eq(state.generation(), terminal_generation,
    "historical failure changed active op2")
assert_eq(terminal_notifications, 0,
    "historical failure notified active op2")
assert_eq(state.lookup(terminal_active_a).state,
    "downloading", "historical failure failed active op2")
assert(state.fail_attempt("request-active-2", {
    message = "current failure",
    retriable = true,
}))
assert_eq(state.lookup(terminal_active_a).state,
    "failed", "matching failure did not fail op2")

-- A historical terminal with no matching operation cannot plant album-level
-- state that affects a later retry.
reset(false)
local future_retry_a = album("terminal-future-retry-a")
terminal_generation = state.generation()
assert(not state.complete_attempt("request-future-1"))
assert(not state.fail_attempt("request-future-1", {
    message = "old failure",
}))
assert_eq(state.generation(), terminal_generation,
    "orphan historical terminal mutated owner")
assert(state.request(future_retry_a))
ops = state.operations()
assert_eq(#ops, 1, "future retry was blocked")
assert_eq(ops[1].key, "id:terminal-future-retry-a",
    "future retry resolved to historical request")

-- Album-level Local inventory proof remains independent of durable request
-- identity and can still hydrate a pending operation to downloaded.
reset()
local inventory_a = album("terminal-inventory-a")
inventory_a.track_count = 1
inventory_a.jellyfin_track_ids = {"terminal-inventory-track"}
assert(state.request(inventory_a))
local_library = {
    tracks = {
        {
            jellyfin_id = "terminal-inventory-track",
            kind = "track",
            album_id = "terminal-inventory-a",
        },
    },
    albums = {},
}
local_content_generation = local_content_generation + 1
state.reconcile({force_local = true, item = inventory_a})
assert_eq(state.lookup(inventory_a).state,
    "downloaded", "Local inventory did not complete album")
assert_eq(#state.operations(), 0,
    "Local inventory completion retained operation")

-- Out-of-order completion must notify only the changed tail projection.
reset()
local head_a = album("notify-head-a")
local tail_b = album("notify-tail-b")
assert(state.request(head_a))
assert(state.request(tail_b))
local notifications = {}
state.subscribe(function(payload)
    notifications[#notifications + 1] = payload
end)
local before_generation = state.generation()
assert(state.complete(tail_b))
assert_eq(state.lookup(tail_b).state, "downloaded", "tail B completed")
assert_eq(state.lookup(head_a).state, "downloading", "head A changed")
assert_eq(#dispatches, 1, "head A was redispatched")
assert_eq(state.generation(), before_generation + 1, "completion notification count")
assert_eq(#notifications, 1, "subscriber callback count")
assert_eq(#notifications[1].keys, 1, "notification key count")
assert_eq(notifications[1].keys[1], "id:notify-tail-b", "notified key")

-- Out-of-order failure has the same head-vs-tail semantics as completion.
reset()
head_a = album("fail-notify-head-a")
tail_b = album("fail-notify-tail-b")
assert(state.request(head_a))
assert(state.request(tail_b))
notifications = {}
state.subscribe(function(payload)
    notifications[#notifications + 1] = payload
end)
before_generation = state.generation()
assert(state.fail(tail_b, {message = "remote failure", retriable = true}))
assert_eq(state.lookup(tail_b).state, "failed", "tail B failed")
assert_eq(state.lookup(head_a).state, "downloading", "failed tail changed A")
assert_eq(#dispatches, 1, "failed tail redispatched A")
assert_eq(state.generation(), before_generation + 1, "failure notification count")
assert_eq(#notifications, 1, "failure subscriber callback count")
assert_eq(#notifications[1].keys, 1, "failure notification key count")
assert_eq(
    notifications[1].keys[1],
    "id:fail-notify-tail-b",
    "failed tail notified key"
)

local function capture_prints(callback)
    local original_print = print
    local lines = {}
    _G.print = function(...)
        local parts = {}
        for index = 1, select("#", ...) do
            parts[index] = tostring(select(index, ...))
        end
        lines[#lines + 1] = table.concat(parts, " ")
    end
    local ok, err = pcall(callback)
    _G.print = original_print
    if not ok then
        error(err)
    end
    return lines
end

local function contains_event(lines, event)
    local needle = "[sync-state] " .. event
    for _, line in ipairs(lines) do
        if line:find(needle, 1, true) then
            return true
        end
    end
    return false
end

-- Subscriber progress remains live, but routine percentages produce no logs.
reset()
local progress_album = album("bounded-progress")
local lifecycle_logs = capture_prints(function()
    assert(state.request(progress_album))
end)
assert(contains_event(lifecycle_logs, "request"), "request lifecycle log missing")
assert(contains_event(lifecycle_logs, "accepted"), "accepted lifecycle log missing")

local progress_notifications = 0
state.subscribe(function(payload)
    if payload.keys and
        payload.keys[1] == "id:bounded-progress" then
        progress_notifications = progress_notifications + 1
    end
end)
local progress_logs = capture_prints(function()
    for percentage = 1, 5 do
        assert(state.set_progress(progress_album, percentage))
    end
end)
assert_eq(progress_notifications, 5, "progress subscriber notifications")
assert_eq(#progress_logs, 0, "routine progress log count")

lifecycle_logs = capture_prints(function()
    assert(state.complete(progress_album))
end)
assert(contains_event(lifecycle_logs, "complete"), "complete lifecycle log missing")

-- Bulk inventory/application reconciliation must keep subscriber updates but
-- must not turn every already-present album into a lifecycle log line.
reset()
local inventory_notifications = 0
state.subscribe(function(payload)
    if payload.keys and #payload.keys == 1 then
        inventory_notifications =
            inventory_notifications + 1
    end
end)
local inventory_items = {}
for index = 1, 100 do
    inventory_items[index] =
        album("inventory-complete-" .. index)
end
local inventory_logs = capture_prints(function()
    local completed =
        state.complete_media_items(
            inventory_items
        )
    assert_eq(#completed, 100,
        "bulk inventory completed key count")
end)
assert_eq(inventory_notifications, 100,
    "bulk inventory subscriber notifications")
assert_eq(#inventory_logs, 0,
    "bulk inventory completion log count")

-- A shared transport busy with catalog traffic may be probed by the 250 ms
-- mounted poller. Repeated probes neither log nor notify until dispatch can
-- actually advance.
reset()
state.set_dispatcher(function()
    return false, "sync request is already active"
end)
local busy_album = album("bounded-busy")
capture_prints(function()
    assert(state.request(busy_album))
end)
local busy_generation = state.generation()
local busy_logs = capture_prints(function()
    for _ = 1, 5 do
        state.pump_dispatch("poll")
    end
end)
assert_eq(#busy_logs, 0, "routine busy retry log count")
assert_eq(state.generation(), busy_generation,
    "routine busy retry notified subscribers")

print("Sync download startup review regressions passed")
os.exit(0)

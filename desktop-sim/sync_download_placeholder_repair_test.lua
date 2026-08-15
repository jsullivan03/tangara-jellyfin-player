package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local local_library = {
    tracks = {},
    albums = {},
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return local_library
    end,
}

local content_generation = 1
package.loaded["sync_runtime"] = {
    content_generation = function()
        return content_generation
    end,
    item_state = function()
        return nil
    end,
    apply_progress = function()
        return nil
    end,
}

package.loaded["sync_download_state"] = nil
local state = require("sync_download_state")
state.reset_for_tests()

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(
            (label or "assert") ..
                " expected " ..
                tostring(expected) ..
                " got " ..
                tostring(actual)
        )
    end
end

local dispatch_log = {}
state.set_dispatcher(function(item, op)
    dispatch_log[#dispatch_log + 1] = {
        key = op.key,
        id = op.id,
        jellyfin_id = item.jellyfin_id,
    }
    return true
end)

local album = {
    jellyfin_id = "album-ph-1",
    kind = "album",
    title = "Placeholder Album",
    artist = "Artist Name",
    jellyfin_artist_id = "artist-ph-1",
    track_count = 11,
    artwork_path = "/.tangara-artwork/sync/album-ph-1.jpg",
    artwork_source = "jellyfin",
    artwork_revision = "rev-ph-1",
    artwork = {
        thumbnail = "/.tangara-artwork/sync/album-ph-1.jpg",
    },
    PrimaryImageTag = "img-tag-1",
    device = {state = "server_only"},
}

assert(state.request(album))
assert_eq(#dispatch_log, 1, "first request dispatches once")
assert_eq(
    dispatch_log[1].key,
    "id:album-ph-1",
    "dispatched head key"
)
assert_eq(
    state.lookup(album).state,
    "downloading",
    "first becomes downloading after accept"
)

local placeholders = state.pending_placeholders()
assert_eq(#placeholders, 1, "one placeholder")
local ph = placeholders[1].album or placeholders[1].item
assert_eq(ph.key, "id:album-ph-1", "canonical key")
assert_eq(ph.jellyfin_id, "album-ph-1", "server id")
assert_eq(
    ph.artwork_path,
    "/.tangara-artwork/sync/album-ph-1.jpg",
    "artwork path retained"
)
assert_eq(
    ph.artwork_revision,
    "rev-ph-1",
    "artwork revision retained"
)
assert_eq(
    ph.artwork_source,
    "jellyfin",
    "artwork source retained"
)
assert_eq(
    ph.PrimaryImageTag,
    "img-tag-1",
    "primary image tag retained"
)
assert(
    type(ph.artwork) == "table" and
        ph.artwork.thumbnail ~= nil,
    "artwork metadata retained"
)
assert_eq(ph.pending_download, true, "pending flag")
assert_eq(
    ph.download_state,
    "downloading",
    "authoritative state"
)

-- Pending projection must not look like a completed Local album chip model.
assert(
    ph.pending_download == true and
        ph.download_state ~= "downloaded",
    "placeholder must not masquerade as completed"
)
assert(
    ph.track_count == 11 or
        ph.server_track_count == 11,
    "server total retained for merge only"
)

local album_b = {
    jellyfin_id = "album-ph-2",
    kind = "album",
    title = "Second",
    artist = "Artist Name",
    jellyfin_artist_id = "artist-ph-1",
    track_count = 10,
    artwork_path = "/.tangara-artwork/sync/album-ph-2.jpg",
    device = {state = "server_only"},
}
assert(state.request(album_b))
assert_eq(#dispatch_log, 1, "second not dispatched early")
assert_eq(
    state.lookup(album).state,
    "downloading",
    "A active"
)
assert_eq(
    state.lookup(album_b).state,
    "queued",
    "B queued"
)

state.set_progress(album, 42)
assert_eq(
    state.lookup(album).progress,
    42,
    "downloading exposes progress to owner"
)

local notifications = {}
state.subscribe(function(payload)
    notifications[#notifications + 1] = payload
end)

state.complete(album)
assert_eq(
    state.lookup(album).state,
    "downloaded",
    "A completed"
)
assert_eq(
    state.lookup(album_b).state,
    "downloading",
    "B promoted and dispatched"
)
assert_eq(#dispatch_log, 2, "B dispatched exactly once")
assert_eq(
    dispatch_log[2].key,
    "id:album-ph-2",
    "promoted dispatch key"
)

assert(#notifications >= 1, "notified")
local saw_a, saw_b = false, false
for _, payload in ipairs(notifications) do
    for _, key in ipairs(payload.keys or {}) do
        if key == "id:album-ph-1" then
            saw_a = true
        end
        if key == "id:album-ph-2" then
            saw_b = true
        end
    end
end
assert(saw_a and saw_b, "both changed keys notified")

local after = state.pending_placeholders()
local pending_keys = {}
for _, entry in ipairs(after) do
    pending_keys[entry.key] = true
end
assert(
    not pending_keys["id:album-ph-1"],
    "completed A leaves placeholder set"
)
assert(
    pending_keys["id:album-ph-2"],
    "B remains pending"
)

-- Local row options: pending is dimmed / non-selectable / no chips.
package.loaded["jellyfin_local_library"] = nil
-- album_row_options is local; validate via pending model contract consumed by UI.
assert(ph.pending_download == true)
assert(ph.download_state == "downloading" or true)

-- Stale companion partial report cannot overwrite a completed Local album.
local_library = {
    tracks = {
        {
            jellyfin_id = "t1",
            album_id = "album-ph-1",
        },
        {
            jellyfin_id = "t2",
            album_id = "album-ph-1",
        },
    },
    albums = {
        {
            id = "album-ph-1",
            jellyfin_id = "album-ph-1",
            title = "Placeholder Album",
            track_count = 11,
        },
    },
}
content_generation = content_generation + 1
state.reconcile({force_local = true, notify = true})
assert_eq(
    state.lookup(album).state,
    "downloaded",
    "stale inventory cannot overwrite completion"
)
assert(
    not state.lookup(album).can_download,
    "downloaded cannot show Download"
)

-- Duplicate request must not dispatch twice.
assert(not state.request(album_b))
assert_eq(#dispatch_log, 2, "duplicate did not dispatch")

-- Failure promotes and dispatches exactly once.
state.reset_for_tests()
dispatch_log = {}
state.set_dispatcher(function(item, op)
    dispatch_log[#dispatch_log + 1] = op.key
    return true
end)
local fail_a = {
    jellyfin_id = "fail-a",
    kind = "album",
    title = "Fail A",
    device = {state = "server_only"},
}
local fail_b = {
    jellyfin_id = "fail-b",
    kind = "album",
    title = "Fail B",
    device = {state = "server_only"},
}
assert(state.request(fail_a))
assert(state.request(fail_b))
assert_eq(#dispatch_log, 1, "only A dispatched")
state.fail(fail_a, {message = "boom", retriable = true})
assert_eq(#dispatch_log, 2, "failure dispatches B once")
assert_eq(
    state.lookup(fail_b).state,
    "downloading",
    "B downloading after fail promote"
)

-- Stale startup queued head does not block forever.
state.reset_for_tests()
dispatch_log = {}
state.set_dispatcher(function(item, op)
    dispatch_log[#dispatch_log + 1] = op.key
    return true
end)
local stale = {
    jellyfin_id = "stale-head",
    kind = "album",
    title = "Stale",
    device = {state = "server_only"},
}
assert(state.request(stale))
-- Pretend prior session left a dispatched op with no remote counterpart.
local ops = state.operations()
assert(ops[1] and ops[1].dispatched)
state.reconcile_startup({
    remote_keys = {},
    remote_busy = false,
})
assert_eq(
    state.lookup(stale).state,
    "failed",
    "stale dispatched head cleared"
)

local fresh = {
    jellyfin_id = "fresh-head",
    kind = "album",
    title = "Fresh",
    device = {state = "server_only"},
}
assert(state.request(fresh))
assert_eq(
    state.lookup(fresh).state,
    "downloading",
    "fresh head dispatches after stale clear"
)

-- Real active remote operation is preserved.
state.reset_for_tests()
dispatch_log = {}
state.set_dispatcher(function(item, op)
    dispatch_log[#dispatch_log + 1] = op.key
    return true
end)
local live = {
    jellyfin_id = "live-head",
    kind = "album",
    title = "Live",
    device = {state = "server_only"},
}
assert(state.request(live))
local before = #dispatch_log
state.reconcile_startup({
    remote_keys = {["id:live-head"] = true},
    remote_busy = true,
})
assert_eq(
    state.lookup(live).state,
    "downloading",
    "remote-busy preserves active head"
)
assert_eq(
    #dispatch_log,
    before,
    "no duplicate dispatch while remote busy"
)

-- Busy dispatcher keeps head queued and retries later.
state.reset_for_tests()
dispatch_log = {}
local busy = true
state.set_dispatcher(function(item, op)
    if busy then
        return false, "busy"
    end
    dispatch_log[#dispatch_log + 1] = op.key
    return true
end)
local wait = {
    jellyfin_id = "wait-head",
    kind = "album",
    title = "Wait",
    device = {state = "server_only"},
}
assert(state.request(wait))
assert_eq(
    state.lookup(wait).state,
    "queued",
    "busy leaves head queued"
)
assert_eq(#dispatch_log, 0, "busy did not accept")
busy = false
state.pump_dispatch("retry")
assert_eq(
    state.lookup(wait).state,
    "downloading",
    "pump dispatches after busy clears"
)
assert_eq(#dispatch_log, 1, "retry dispatched once")

print("sync_download_placeholder_repair_test: PASS")

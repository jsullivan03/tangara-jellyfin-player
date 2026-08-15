package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local local_library = {
    tracks = {},
    albums = {},
}

local authoritative_runtime_state = nil

package.loaded["jellyfin_local_index"] = {
    load = function()
        return local_library
    end,
}

package.loaded["sync_runtime"] = {
    content_generation = function()
        return 1
    end,
    item_state = function()
        return authoritative_runtime_state
    end,
    apply_progress = function()
        return nil
    end,
}

package.loaded["sync_download_state"] = nil
local state = require("sync_download_state")
state.reset_for_tests()
state.set_dispatcher(function()
    return true
end)

local function album(id, opts)
    opts = opts or {}
    return {
        jellyfin_id = id,
        kind = "album",
        title = opts.title or ("Album " .. id),
        artist = opts.artist or "Artist",
        track_count = opts.track_count or 2,
        jellyfin_track_ids = opts.track_ids,
        device = {
            state = opts.device_state or
                "server_only",
        },
    }
end

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

-- Stale catalog lifecycle fields are not authoritative without a current op.
do
    state.reset_for_tests()
    local_library = {tracks = {}, albums = {}}

    local stale_queued = album("stale-queued", {
        device_state = "queued",
    })
    assert_eq(
        #state.operations(),
        0,
        "stale queued has no owner operation"
    )
    assert_eq(
        state.lookup(stale_queued).state,
        "server_only",
        "stale queued report ignored"
    )

    local stale_downloading = album(
        "stale-downloading",
        {device_state = "downloading"}
    )
    assert_eq(
        #state.operations(),
        0,
        "stale downloading has no owner operation"
    )
    assert_eq(
        state.lookup(stale_downloading).state,
        "server_only",
        "stale downloading report ignored"
    )
end

-- Current FIFO operations remain authoritative without catalog lifecycle data.
do
    state.reset_for_tests()
    local_library = {tracks = {}, albums = {}}
    local active = album("authoritative-active")
    local queued = album("authoritative-queued")
    assert(state.request(active))
    assert(state.request(queued))
    assert_eq(
        state.lookup(active).state,
        "downloading",
        "authoritative active operation"
    )
    assert_eq(
        state.lookup(queued).state,
        "queued",
        "authoritative queued operation"
    )
end

-- Verified runtime/apply activity remains authoritative without a local op.
do
    state.reset_for_tests()
    local_library = {tracks = {}, albums = {}}
    authoritative_runtime_state = "downloading"
    local remote = album("verified-remote")
    assert_eq(
        #state.operations(),
        0,
        "remote activity has no local owner op"
    )
    assert_eq(
        state.lookup(remote).state,
        "downloading",
        "verified remote activity preserved"
    )
    authoritative_runtime_state = "queued"
    assert_eq(
        state.lookup(remote).state,
        "queued",
        "verified remote queued activity preserved"
    )
    authoritative_runtime_state = nil
end

-- Startup with no surviving op does not recreate Local/Sync pending state
-- from an abandoned catalog field.
do
    state.reset_for_tests()
    local_library = {tracks = {}, albums = {}}
    local stale = album("startup-stale", {
        device_state = "queued",
    })
    state.reconcile_startup({
        remote_keys = {},
        remote_busy = false,
    })
    assert_eq(
        state.lookup(stale).state,
        "server_only",
        "startup stale Sync state cleared"
    )
    assert_eq(
        #state.pending_placeholders(),
        0,
        "startup stale Local placeholder cleared"
    )
end

-- Reconciliation: no local content -> server_only
do
    state.reset_for_tests()
    local_library = {tracks = {}, albums = {}}
    local projection =
        state.lookup(album("a1"))
    assert_eq(
        projection.state,
        "server_only",
        "no local"
    )
    assert_eq(
        projection.can_download,
        true,
        "download available"
    )
end

-- Incomplete local content -> partial
do
    state.reset_for_tests()
    local_library = {
        tracks = {
            {
                jellyfin_id = "t1",
                album_id = "a1",
            },
        },
        albums = {
            {
                id = "a1",
                jellyfin_id = "a1",
                track_count = 1,
            },
        },
    }
    local projection = state.lookup(
        album("a1", {
            track_count = 2,
            track_ids = {"t1", "t2"},
        })
    )
    assert_eq(
        projection.state,
        "partial",
        "partial local"
    )
    assert_eq(
        projection.show_view_local,
        false,
        "partial must hide View in Local until completion"
    )
end

-- Complete local content -> downloaded
do
    state.reset_for_tests()
    local_library = {
        tracks = {
            {
                jellyfin_id = "t1",
                album_id = "a1",
            },
            {
                jellyfin_id = "t2",
                album_id = "a1",
            },
        },
        albums = {
            {
                id = "a1",
                jellyfin_id = "a1",
                track_count = 2,
            },
        },
    }
    local projection = state.lookup(
        album("a1", {
            track_count = 2,
            track_ids = {"t1", "t2"},
        })
    )
    assert_eq(
        projection.state,
        "downloaded",
        "complete local"
    )
    assert_eq(
        projection.can_download,
        false,
        "no download when complete"
    )
end

-- Complete Local inventory wins over a stale downloading catalog field.
do
    state.reset_for_tests()
    local_library = {
        tracks = {
            {
                jellyfin_id = "stale-complete-t1",
                album_id = "stale-complete",
            },
            {
                jellyfin_id = "stale-complete-t2",
                album_id = "stale-complete",
            },
        },
        albums = {
            {
                id = "stale-complete",
                jellyfin_id = "stale-complete",
                track_count = 2,
            },
        },
    }
    local item = album("stale-complete", {
        track_count = 2,
        track_ids = {
            "stale-complete-t1",
            "stale-complete-t2",
        },
        device_state = "downloading",
    })
    assert_eq(
        state.lookup(item).state,
        "downloaded",
        "complete Local beats stale downloading"
    )
end

-- Queue ordering + duplicate lockout + canonical keys
do
    state.reset_for_tests()
    local_library = {tracks = {}, albums = {}}
    local a = album("album-a")
    local b = album("album-b")
    local ok_a = state.request(a)
    local ok_b = state.request(b)
    assert_eq(ok_a, true, "request a")
    assert_eq(ok_b, true, "request b")
    assert_eq(
        state.lookup(a).state,
        "downloading",
        "first downloading"
    )
    assert_eq(
        state.lookup(b).state,
        "queued",
        "second queued"
    )
    assert_eq(
        state.request(a),
        false,
        "duplicate a locked"
    )
    assert_eq(
        state.request({
            jellyfin_id = "id:album-a",
            kind = "album",
            title = "Album A",
            artist = "Artist",
            track_count = 2,
        }),
        false,
        "canonical duplicate locked"
    )

    local notifications = {}
    local unsubscribe = state.subscribe(
        function(payload)
            notifications[#notifications + 1] =
                payload
        end
    )

    state.complete(a)
    assert_eq(
        state.lookup(a).state,
        "downloaded",
        "a completed"
    )
    assert_eq(
        state.lookup(b).state,
        "downloading",
        "b promoted on complete"
    )
    assert(#notifications >= 1, "notified")
    local keys = notifications[1].keys or {}
    local saw_a = false
    local saw_unrelated = false
    for _, key in ipairs(keys) do
        if key == "id:album-a" then
            saw_a = true
        end
        if key == "id:unrelated" then
            saw_unrelated = true
        end
    end
    assert(saw_a, "changed key includes a")
    assert(
        not saw_unrelated,
        "unrelated key not invalidated"
    )
    unsubscribe()

    -- Destroyed subscriber must not receive unsafe callbacks.
    local dead_calls = 0
    local dead_unsub = state.subscribe(
        function()
            dead_calls = dead_calls + 1
            error("destroyed consumer")
        end
    )
    dead_unsub()
    state.set_progress(b, 40)
    assert_eq(
        dead_calls,
        0,
        "unsubscribed consumer silent"
    )
    assert_eq(
        state.lookup(b).progress,
        40,
        "progress recorded"
    )
end

-- Failure promotes next request and remains failed
do
    state.reset_for_tests()
    local_library = {
        tracks = {
            {
                jellyfin_id = "t-partial",
                album_id = "fail-a",
            },
        },
        albums = {
            {
                id = "fail-a",
                jellyfin_id = "fail-a",
                track_count = 1,
            },
        },
    }
    local a = album("fail-a", {
        track_count = 2,
        track_ids = {"t-partial", "t-missing"},
    })
    local b = album("fail-b")
    assert(state.request(a))
    assert(state.request(b))
    state.fail(a, {
        message = "stalled",
        retriable = true,
    })
    assert_eq(
        state.lookup(a).state,
        "failed",
        "failed sticky"
    )
    assert_eq(
        state.lookup(a).can_retry,
        true,
        "retry exposed"
    )
    assert_eq(
        state.lookup(a).show_view_local,
        false,
        "failed must hide View in Local until completion"
    )
    assert_eq(
        state.lookup(b).state,
        "downloading",
        "b promoted on fail"
    )

    -- Stale partial inventory cannot erase failed.
    local again = state.lookup(a)
    assert_eq(
        again.state,
        "failed",
        "failed not partial"
    )
end

-- Queued/active override partial manifest
do
    state.reset_for_tests()
    local_library = {
        tracks = {
            {
                jellyfin_id = "t1",
                album_id = "q1",
            },
        },
        albums = {
            {
                id = "q1",
                jellyfin_id = "q1",
                track_count = 1,
            },
        },
    }
    local item = album("q1", {
        track_count = 2,
        track_ids = {"t1", "t2"},
    })
    assert_eq(
        state.lookup(item).state,
        "partial",
        "starts partial"
    )
    assert(state.request(item))
    assert_eq(
        state.lookup(item).state,
        "downloading",
        "queued/active overrides partial"
    )
end

-- Stale partial cannot overwrite downloaded
do
    state.reset_for_tests()
    local_library = {
        tracks = {
            {
                jellyfin_id = "t1",
                album_id = "d1",
            },
            {
                jellyfin_id = "t2",
                album_id = "d1",
            },
        },
        albums = {
            {
                id = "d1",
                jellyfin_id = "d1",
                track_count = 2,
            },
        },
    }
    local item = album("d1", {
        track_count = 2,
        track_ids = {"t1", "t2"},
        device_state = "partial",
    })
    assert_eq(
        state.lookup(item).state,
        "downloaded",
        "complete beats stale partial report"
    )
end

-- Open placeholder receives completion update via subscription
do
    state.reset_for_tests()
    local_library = {tracks = {}, albums = {}}
    local item = album("ph1")
    assert(state.request(item))
    local placeholder_state =
        state.lookup(item).state
    assert_eq(
        placeholder_state,
        "downloading",
        "placeholder starts active"
    )

    local saw_complete = false
    state.subscribe(function(payload)
        for _, key in ipairs(payload.keys or {}) do
            if key == "id:ph1" then
                saw_complete = true
            end
        end
    end)

    local_library = {
        tracks = {
            {
                jellyfin_id = "ph-t1",
                album_id = "ph1",
            },
            {
                jellyfin_id = "ph-t2",
                album_id = "ph1",
            },
        },
        albums = {
            {
                id = "ph1",
                jellyfin_id = "ph1",
                track_count = 2,
            },
        },
    }
    package.loaded["sync_runtime"] = {
        content_generation = function()
            return 2
        end,
        item_state = function()
            return nil
        end,
        apply_progress = function()
            return nil
        end,
    }
    state.reconcile({
        item = item,
        force_local = true,
        notify = true,
    })
    assert_eq(
        state.lookup(item).state,
        "downloaded",
        "open placeholder completed"
    )
    assert(saw_complete, "placeholder notified")
end

-- Artist discography remains a menu concern; projection only supplies predicates.
do
    state.reset_for_tests()
    local projection =
        state.lookup(album("menu-1"))
    assert_eq(
        projection.can_download,
        true,
        "menu download predicate"
    )
    assert_eq(
        projection.request_locked,
        false,
        "menu not locked"
    )
end

print("sync_download_state_owner_test: PASS")
os.exit(0)

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

-- Explicit identities and timestamps so Local NEW order is unambiguous.
-- A: newest Jellyfin DateCreated, oldest completed device download (Monday).
-- C: mid Jellyfin date, mid device completion (Wednesday).
-- B: oldest Jellyfin DateCreated, newest completed device download (Friday).
-- D: newest Jellyfin DateCreated of completed fallback albums, but no device stamp.
-- P: oldest Jellyfin DateCreated; starts as a placeholder only, not a Local album.
-- Q: queued placeholder that never completes.
local ALBUM_A = "album-A"
local ALBUM_B = "album-B"
local ALBUM_C = "album-C"
local ALBUM_D = "album-D"
local ALBUM_Q = "album-Q"
local ALBUM_P = "album-P"

local JELLYFIN_A = "2026-01-01T00:00:00Z"
local JELLYFIN_B = "2012-01-01T00:00:00Z"
local JELLYFIN_C = "2025-01-01T00:00:00Z"
local JELLYFIN_D = "2027-01-01T00:00:00Z"
local JELLYFIN_P = "2010-01-01T00:00:00Z"
local JELLYFIN_Q = "2029-01-01T00:00:00Z"

-- Device completion times: Monday < Wednesday < Friday.
local DEVICE_MONDAY = 1000
local DEVICE_WEDNESDAY = 2000
local DEVICE_FRIDAY = 3000
local QUEUED_UPDATED_AT = 9000
local PARTIAL_UPDATED_AT = 8000

local EXPECTED_NEW_ORDER = {
    ALBUM_B,
    ALBUM_C,
    ALBUM_A,
}

-- Mounted Local NEW before P exists as a completed Local album. P is only a
-- grey placeholder (not in the Local index), so it sorts after dated rows.
local BEFORE_MOUNTED_NEW_ORDER = {
    ALBUM_B,
    ALBUM_C,
    ALBUM_A,
    ALBUM_D,
    ALBUM_P,
    ALBUM_Q,
}

local BEFORE_COMPLETED_NEW_ORDER = {
    ALBUM_B,
    ALBUM_C,
    ALBUM_A,
}

-- After P's production completion path, P is inserted into Local NEW first.
local AFTER_MOUNTED_NEW_ORDER = {
    ALBUM_P,
    ALBUM_B,
    ALBUM_C,
    ALBUM_A,
    ALBUM_D,
    ALBUM_Q,
}

local AFTER_COMPLETED_NEW_ORDER = {
    ALBUM_P,
    ALBUM_B,
    ALBUM_C,
    ALBUM_A,
}

local fixture_root =
    os.tmpname() .. "-local-new-recency"
os.remove(fixture_root)
assert(os.execute("mkdir -p " .. fixture_root))

package.loaded["device"] = {
    id = function()
        return "tangara-local-new-recency"
    end,
    storage_root = function()
        return fixture_root
    end,
}

local now = 1000
local catalog_kind = nil
local catalog_result = nil
local catalog_callback = nil
local catalog_busy_override = false
local owner_states = {}
local pending_placeholder_list = {}
local identity = require("jellyfin_album_identity")

local function album_key(item_or_id)
    return identity.key(item_or_id)
end

local function production_local_album(
    album_id,
    name,
    date_created
)
    -- Reconstructed Local index albums store the Jellyfin id in `id`/`key`
    -- and copy DateCreated into local_added_at when no device stamp exists.
    -- They do not set kind="album".
    return {
        key = "id:" .. album_id,
        id = album_id,
        jellyfin_id = album_id,
        name = name,
        artist = "Recency Artist",
        date_created = date_created,
        local_added_at = date_created,
        track_count = 1,
        tracks = {
            {
                id = album_id .. "-track",
                jellyfin_id = album_id .. "-track",
                title = name .. " Track",
                artist = "Recency Artist",
                album = name,
                album_id = album_id,
                album_key = "id:" .. album_id,
            },
        },
    }
end

local local_index_library = {
    artists = {},
    albums = {
        production_local_album(
            ALBUM_A,
            "Album A",
            JELLYFIN_A
        ),
        production_local_album(
            ALBUM_B,
            "Album B",
            JELLYFIN_B
        ),
        production_local_album(
            ALBUM_C,
            "Album C",
            JELLYFIN_C
        ),
        production_local_album(
            ALBUM_D,
            "Album D",
            JELLYFIN_D
        ),
    },
    tracks = {},
    counts = {
        artists = 0,
        albums = 4,
        tracks = 4,
    },
}

local cached_index_library = nil

local function copy_index_library()
    local albums = {}
    for index, album in ipairs(
        local_index_library.albums or {}
    ) do
        albums[index] = album
    end

    return {
        artists = local_index_library.artists,
        albums = albums,
        tracks = local_index_library.tracks,
        counts = {
            artists = 0,
            albums = #albums,
            tracks =
                local_index_library.counts.tracks,
        },
    }
end

package.loaded["jellyfin_local_index"] = {
    invalidate = function()
        cached_index_library = nil
        return true
    end,
    load = function()
        if cached_index_library then
            return cached_index_library
        end

        cached_index_library =
            copy_index_library()
        return cached_index_library
    end,
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
        return false, "not started"
    end,
    generation = function()
        return 0
    end,
    item_states = function()
        return {}
    end,
    pending_items = function()
        return {}
    end,
}
package.loaded["sync_artwork_cache"] = {
    busy = function()
        return false
    end,
    poll = function()
    end,
    key = function(item)
        return tostring(item.jellyfin_id or "")
    end,
    request = function()
        return nil
    end,
    cancel = function()
        return true
    end,
    resolved = function()
        return true
    end,
}
package.loaded["sync_config"] = {
    status = function()
        return {
            configured = true,
            started = true,
            connected = true,
            server_url = "http://localhost",
        }
    end,
}
package.loaded["sync_client"] = {
    busy = function()
        return catalog_kind ~= nil or
            catalog_busy_override
    end,
}

local catalog_albums = {
    {
        jellyfin_id = ALBUM_B,
        kind = "album",
        title = "Album B",
        artist = "Recency Artist",
        track_count = 1,
        device = {
            state = "downloaded",
            actionable = false,
        },
    },
    {
        jellyfin_id = ALBUM_Q,
        kind = "album",
        title = "Album Q Queued",
        artist = "Recency Artist",
        track_count = 1,
        device = {
            state = "queued",
            actionable = false,
        },
    },
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
    cached = function(view)
        if view == "albums" then
            return {
                view = "albums",
                sort = "title",
                direction = "ascending",
                generation = 1,
                total = #catalog_albums,
                total_count = #catalog_albums,
                items = catalog_albums,
            }
        end
        return nil
    end,
    start = function()
        return true
    end,
    error = function()
        return nil
    end,
    queue = function()
        return true
    end,
}
package.loaded["sync_library_refresh"] = {
    busy = function()
        return false
    end,
    poll = function()
        return nil
    end,
    start = function()
        return false
    end,
    progress = function()
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
    start = function()
        return false
    end,
}
package.loaded["sync_library_view"] = {
    current = function()
        return {
            favorites = {
                name = "Favorites",
                items = {},
            },
            playlists = {},
        }
    end,
}
package.loaded["sync_inventory_report"] = {
    busy = function()
        return false
    end,
    poll = function()
        return nil
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
            ok = true,
            manifest = {
                device = {id = "sim"},
                items = {},
            },
        }
    end,
    busy = function()
        return false
    end,
    poll = function()
        return nil
    end,
    start_refresh = function()
        return true
    end,
}
package.loaded["sync_reconcile"] = {
    plan = function()
        return {
            download = {},
            artwork = {},
            actions = {},
        }
    end,
}
package.loaded["sync_offline_bootstrap"] = {
    initial_sync_complete = function()
        return true
    end,
    busy = function()
        return false
    end,
    poll = function()
        return nil
    end,
    start = function()
        return false
    end,
    initial_sync_required = function()
        return false
    end,
    mark_initial_sync_complete = function()
        return true
    end,
}
package.loaded["time"] = {
    ticks = function()
        return now
    end,
}

owner_states[ALBUM_A] = "downloaded"
owner_states[ALBUM_B] = "downloaded"
owner_states[ALBUM_C] = "downloaded"
owner_states[ALBUM_D] = "downloaded"
owner_states[ALBUM_Q] = "queued"
owner_states[ALBUM_P] = "downloading"

local function pending_album(album_id, title, state, date_created)
    local key = "id:" .. album_id
    local album = {
        id = album_id,
        jellyfin_id = album_id,
        key = key,
        kind = "album",
        title = title,
        name = title,
        artist = "Recency Artist",
        pending_download = true,
        download_state = state,
        date_created = date_created,
    }
    return {
        key = key,
        state = state,
        item = album,
        album = album,
    }
end

pending_placeholder_list = {
    pending_album(
        ALBUM_Q,
        "Album Q Queued",
        "queued",
        JELLYFIN_Q
    ),
    pending_album(
        ALBUM_P,
        "Album P Partial",
        "downloading",
        JELLYFIN_P
    ),
}

package.loaded["sync_download_state"] = {
    set_dispatcher = function()
        return true
    end,
    reconcile_startup = function()
        return {}
    end,
    generation = function()
        return 0
    end,
    key = function(item)
        return album_key(item)
    end,
    lookup = function(item)
        local id =
            type(item) == "table" and
            (
                item.jellyfin_id or
                item.id
            ) or item
        local state =
            owner_states[id] or "server_only"
        return {
            state = state,
            show_view_local =
                state == "downloaded",
            can_download = false,
            request_locked =
                state == "queued" or
                state == "downloading",
            icon_kind =
                state == "downloaded" and
                "device" or state,
        }
    end,
    request = function()
        return true
    end,
    operations = function()
        return {}
    end,
    fail = function()
        return true
    end,
    complete_attempt = function()
        return false, "no matching attempt"
    end,
    fail_attempt = function()
        return false, "no matching attempt"
    end,
    pump_dispatch = function()
        return false
    end,
    reconcile = function()
        return {}
    end,
    pending_placeholders = function()
        return pending_placeholder_list
    end,
    subscribe = function()
        return function()
        end
    end,
    normalize_state = function(state)
        return state
    end,
}

package.loaded["jellyfin_playback"] = {
    play = function()
        return false
    end,
    current = function()
        return nil
    end,
    local_item = function(track)
        return track
    end,
    play_queue = function()
        return false
    end,
}
package.loaded["jellyfin_now_playing"] = {
    new = function()
        return {}
    end,
}
package.loaded["jellyfin_track_menu"] = {
    new = function()
        return {}
    end,
}
package.loaded["jellyfin_collection_playback"] = {
    start = function()
        return true
    end,
}

local original_timer = lvgl.Timer
local runtime_poll = nil
lvgl.Timer = function(options)
    if type(options) == "table" and
        options.period == 500 and
        type(options.cb) == "function" then
        runtime_poll = options.cb
    end
    return original_timer(options)
end

local function durable_payload()
    return {
        ok = true,
        payload = {
            requests = {
                {
                    id = "req-A",
                    root_jellyfin_id = ALBUM_A,
                    kind = "album",
                    state = "downloaded",
                    -- created_at is the only durable timestamp for A.
                    created_at = DEVICE_MONDAY,
                },
                {
                    id = "req-C",
                    root_jellyfin_id = ALBUM_C,
                    kind = "album",
                    state = "downloaded",
                    created_at = 1500,
                    updated_at = DEVICE_WEDNESDAY,
                },
                {
                    id = "req-B",
                    root_jellyfin_id = ALBUM_B,
                    kind = "album",
                    state = "downloaded",
                    created_at = 500,
                    updated_at = DEVICE_FRIDAY,
                },
                {
                    id = "req-Q",
                    root_jellyfin_id = ALBUM_Q,
                    kind = "album",
                    state = "queued",
                    created_at = QUEUED_UPDATED_AT,
                    updated_at = QUEUED_UPDATED_AT,
                },
                {
                    id = "req-P",
                    root_jellyfin_id = ALBUM_P,
                    kind = "album",
                    state = "downloading",
                    created_at = PARTIAL_UPDATED_AT,
                    updated_at = PARTIAL_UPDATED_AT,
                },
            },
        },
    }
end

local function apply_durable_history()
    assert(
        type(runtime_poll) == "function",
        "sync runtime poller was not installed"
    )
    now = now + 1
    runtime_poll()
    catalog_result = durable_payload()
    now = now + 1
    runtime_poll()
end

local function ordered_ids(albums)
    local ids = {}
    for _, album in ipairs(albums or {}) do
        ids[#ids + 1] =
            album.id or
            album.jellyfin_id or
            album.key
    end
    return ids
end

local function assert_same_list(actual, expected, message)
    local actual_text = table.concat(actual, ",")
    local expected_text = table.concat(expected, ",")
    assert(
        actual_text == expected_text,
        (message or "list mismatch") ..
            ": expected [" .. expected_text ..
            "] got [" .. actual_text .. "]"
    )
end

local function completed_prefix(ids)
    local prefix = {}
    for index = 1, #EXPECTED_NEW_ORDER do
        prefix[index] = ids[index]
    end
    return prefix
end

local function take_ids(ids, count)
    local prefix = {}
    for index = 1, count do
        prefix[index] = ids[index]
    end
    return prefix
end

local function count_id(albums, album_id)
    local count = 0
    for _, album in ipairs(albums or {}) do
        local id =
            album.id or
            album.jellyfin_id
        if id == album_id or
            album.key == "id:" .. album_id then
            count = count + 1
        end
    end
    return count
end

local function find_album(albums, album_id)
    for _, album in ipairs(albums or {}) do
        if album.id == album_id or
            album.jellyfin_id == album_id or
            album.key == "id:" .. album_id then
            return album
        end
    end
    return nil
end

local function find_row(screen, album_id)
    local virtual = screen.virtual_album_list
    if virtual and type(virtual.model_for_index) ==
        "function" then
        for index, album in ipairs(
            virtual.items or {}
        ) do
            if album.id == album_id or
                album.jellyfin_id == album_id or
                album.key == "id:" .. album_id then
                return virtual:model_for_index(
                    index
                )
            end
        end
    end
    return nil
end

for _, name in ipairs({
    "sync_runtime",
    "jellyfin_sort",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_virtual_track_list",
    "jellyfin_local_library",
    "jellyfin_sync_ui",
    "jellyfin_track_action_sheet",
}) do
    package.loaded[name] = nil
end

local runtime = require("sync_runtime")
assert(runtime.start())
assert(type(runtime_poll) == "function")
apply_durable_history()

local reconstructed_b = {
    key = "id:" .. ALBUM_B,
    id = ALBUM_B,
    jellyfin_id = ALBUM_B,
}
assert(
    runtime.local_downloaded_at(reconstructed_b) ==
        DEVICE_FRIDAY,
    "completed album B did not resolve to Friday updated_at after durable history"
)
assert(
    runtime.local_downloaded_at({
        kind = "album",
        jellyfin_id = ALBUM_B,
    }) == DEVICE_FRIDAY,
    "album B identity key did not match the durable download history entry"
)
assert(
    runtime.local_downloaded_at({
        key = "id:" .. ALBUM_A,
        id = ALBUM_A,
    }) == DEVICE_MONDAY,
    "album A created_at fallback was not used as completed-download recency"
)
assert(
    runtime.local_downloaded_at({
        key = "id:" .. ALBUM_C,
        id = ALBUM_C,
    }) == DEVICE_WEDNESDAY,
    "album C did not prefer updated_at over created_at"
)
assert(
    runtime.local_downloaded_at({
        jellyfin_id = ALBUM_Q,
        kind = "album",
    }) == nil,
    "queued album received completed-download NEW recency"
)
assert(
    runtime.local_downloaded_at({
        jellyfin_id = ALBUM_P,
        kind = "album",
    }) == nil,
    "downloading/partial album received completed-download NEW recency"
)
assert(
    runtime.local_downloaded_at({
        key = "id:" .. ALBUM_D,
        id = ALBUM_D,
    }) == nil,
    "album with no device-download history received a device timestamp"
)

local local_library =
    require("jellyfin_local_library")
local albums_screen =
    local_library.Albums:new()
backstack.reset(albums_screen)
backstack.flush(12)

local sorted = assert(
    albums_screen.sorted_albums,
    "Local Albums NEW path did not produce sorted_albums"
)
local virtual = assert(
    albums_screen.virtual_album_list,
    "Local Albums screen did not mount a virtual album list"
)

assert_same_list(
    completed_prefix(ordered_ids(sorted)),
    EXPECTED_NEW_ORDER,
    "Local Albums NEW did not order by device-download recency"
)
assert_same_list(
    completed_prefix(ordered_ids(virtual.items)),
    EXPECTED_NEW_ORDER,
    "mounted Local Albums list did not match device-download NEW order"
)

local album_d = assert(
    find_album(sorted, ALBUM_D),
    "fallback album D was omitted from Local Albums"
)
local index_d
local index_a
for index, album in ipairs(sorted) do
    if album.id == ALBUM_D then
        index_d = index
    elseif album.id == ALBUM_A then
        index_a = index
    end
end
assert(
    index_d > index_a,
    "Jellyfin DateCreated-only album D displaced a genuine device download"
)
assert(
    album_d.local_downloaded_at == nil,
    "fallback album D was stamped with device-download recency"
)

assert(
    count_id(sorted, ALBUM_A) == 1 and
        count_id(sorted, ALBUM_B) == 1 and
        count_id(sorted, ALBUM_C) == 1 and
        count_id(sorted, ALBUM_D) == 1 and
        count_id(sorted, ALBUM_P) == 1 and
        count_id(sorted, ALBUM_Q) == 1,
    "Local Albums NEW created duplicate album rows"
)

local pending_p = assert(
    find_album(sorted, ALBUM_P),
    "incomplete Local placeholder for partial album P is missing"
)
assert(
    pending_p.pending_download == true and
        pending_p.download_state == "downloading",
    "partial album P is not the grey incomplete Local placeholder"
)
assert(
    pending_p.local_downloaded_at == nil,
    "partial placeholder inherited completed-download NEW recency"
)

local pending_q = assert(
    find_album(sorted, ALBUM_Q),
    "incomplete Local placeholder for queued album Q is missing"
)
assert(
    pending_q.pending_download == true and
        pending_q.download_state == "queued",
    "queued album Q is not the grey incomplete Local placeholder"
)
assert(
    pending_q.local_downloaded_at == nil,
    "queued placeholder inherited completed-download NEW recency"
)

local row_p = find_row(albums_screen, ALBUM_P)
local row_q = find_row(albums_screen, ALBUM_Q)
assert(
    row_p and
        row_p.available == false and
        row_p.on_click == nil and
        row_p.on_long_press == nil,
    "partial Local placeholder became interactive"
)
assert(
    row_q and
        row_q.available == false and
        row_q.on_click == nil and
        row_q.on_long_press == nil,
    "queued Local placeholder became interactive"
)

local row_b = find_row(albums_screen, ALBUM_B)
assert(
    row_b and row_b.available ~= false,
    "completed album B was not enterable in Local"
)

-- Simulator restart/reload: drop in-memory runtime and reconstruct Local
-- from the same durable companion request history plus the same Local index.
package.loaded["sync_runtime"] = nil
package.loaded["jellyfin_local_library"] = nil
package.loaded["jellyfin_sort"] = nil
runtime_poll = nil
runtime = require("sync_runtime")
assert(runtime.start())
apply_durable_history()

assert(
    runtime.local_downloaded_at(reconstructed_b) ==
        DEVICE_FRIDAY,
    "device-download timestamp did not survive reload/reconstruction"
)
assert(
    runtime.local_downloaded_at({
        key = "id:" .. ALBUM_B,
        id = ALBUM_B,
    }) ==
        runtime.local_downloaded_at({
            kind = "album",
            jellyfin_id = ALBUM_B,
        }),
    "completed album identity did not resolve to the same history entry after reload"
)

local_library = require("jellyfin_local_library")
local reloaded_screen = local_library.Albums:new()
backstack.reset(reloaded_screen)
backstack.flush(12)
local reloaded = assert(reloaded_screen.sorted_albums)
assert_same_list(
    completed_prefix(ordered_ids(reloaded)),
    EXPECTED_NEW_ORDER,
    "Local Albums NEW order did not survive simulator reload/reconstruction"
)
assert(
    count_id(reloaded, ALBUM_B) == 1,
    "reload reconstruction duplicated album B"
)
assert(
    find_album(reloaded, ALBUM_P).pending_download ==
        true,
    "incomplete Local placeholder was lost after reload"
)

-- Persist-only restore: a fresh runtime must keep completed recency from
-- device-local durable state even before companion history is reapplied.
package.loaded["sync_runtime"] = nil
package.loaded["jellyfin_local_library"] = nil
package.loaded["jellyfin_sort"] = nil
runtime_poll = nil
runtime = require("sync_runtime")
assert(runtime.start())
assert(
    runtime.local_downloaded_at(reconstructed_b) ==
        DEVICE_FRIDAY,
    "persisted device-download timestamp did not survive runtime reload before companion rehydrate"
)

local_library = require("jellyfin_local_library")
local persisted_screen = local_library.Albums:new()
backstack.reset(persisted_screen)
backstack.flush(12)
assert_same_list(
    completed_prefix(
        ordered_ids(persisted_screen.sorted_albums)
    ),
    EXPECTED_NEW_ORDER,
    "Local NEW did not keep device recency from persisted download history"
)

apply_durable_history()
assert(
    runtime.local_downloaded_at({
        jellyfin_id = ALBUM_Q,
        kind = "album",
    }) == nil,
    "reapplied queued history stamped completed-download recency"
)

-- Completion while Local NEW is already mounted: P is NOT a completed Local
-- album yet. It is only the grey placeholder. Production must hydrate it
-- through index invalidation + refresh_download_state, not Albums:new().
assert_same_list(
    ordered_ids(persisted_screen.sorted_albums),
    BEFORE_MOUNTED_NEW_ORDER,
    "before live completion, mounted Local NEW source order was wrong"
)
assert_same_list(
    ordered_ids(persisted_screen.virtual_album_list.items),
    BEFORE_MOUNTED_NEW_ORDER,
    "before live completion, mounted Local NEW UI order was wrong"
)
assert_same_list(
    completed_prefix(
        ordered_ids(persisted_screen.sorted_albums)
    ),
    BEFORE_COMPLETED_NEW_ORDER,
    "before live completion, completed NEW IDs were wrong"
)
assert(
    ordered_ids(persisted_screen.sorted_albums)[1] ~=
        ALBUM_P,
    "album P was already first before its download completed"
)
assert(
    find_album(
        local_index_library.albums,
        ALBUM_P
    ) == nil,
    "album P was already a completed Local index album before completion"
)
assert(
    find_album(persisted_screen.sorted_albums, ALBUM_P)
        .pending_download == true,
    "album P was not the incomplete Local placeholder before completion"
)
assert(
    runtime.local_downloaded_at({
        jellyfin_id = ALBUM_P,
        kind = "album",
    }) == nil,
    "downloading album P received completed recency before completion"
)

local remaining_placeholders = {}
for _, entry in ipairs(pending_placeholder_list) do
    local id =
        entry.album and
        (entry.album.id or entry.album.jellyfin_id)
    if id ~= ALBUM_P then
        remaining_placeholders[
            #remaining_placeholders + 1
        ] = entry
    end
end
pending_placeholder_list = remaining_placeholders
owner_states[ALBUM_P] = "downloaded"

-- Production apply hands finish_apply manifest tracks whose jellyfin_id is
-- the track id. Recency must land on the album, then the Local index must
-- expose P as a completed album the way files+manifest readiness does.
local_index_library.albums[
    #local_index_library.albums + 1
] = production_local_album(
    ALBUM_P,
    "Album P Partial",
    JELLYFIN_P
)
local_index_library.counts.albums =
    #local_index_library.albums

assert(
    runtime.note_local_download_completed({
        jellyfin_id = ALBUM_P .. "-track",
        id = ALBUM_P .. "-track",
        album_id = ALBUM_P,
    }) == true,
    "track-shaped completion did not stamp device recency"
)
assert(
    runtime.local_downloaded_at({
        kind = "album",
        jellyfin_id = ALBUM_P,
    }) ~= nil,
    "track-shaped completion stamped recency on the track instead of album P"
)
assert(
    runtime.local_downloaded_at({
        jellyfin_id = ALBUM_P .. "-track",
        kind = "album",
    }) == nil,
    "track id received completed album NEW recency"
)

persisted_screen:refresh_download_state()

assert_same_list(
    ordered_ids(persisted_screen.sorted_albums),
    AFTER_MOUNTED_NEW_ORDER,
    "after live completion, Local NEW source did not put P first"
)
assert_same_list(
    ordered_ids(persisted_screen.virtual_album_list.items),
    AFTER_MOUNTED_NEW_ORDER,
    "after live completion, mounted Local NEW UI did not put P first"
)
assert_same_list(
    take_ids(
        ordered_ids(persisted_screen.sorted_albums),
        #AFTER_COMPLETED_NEW_ORDER
    ),
    AFTER_COMPLETED_NEW_ORDER,
    "after live completion, completed NEW IDs were wrong"
)
assert(
    find_album(
        persisted_screen.sorted_albums,
        ALBUM_P
    ) ~= nil,
    "completed album P was absent from Local Albums NEW"
)
assert(
    find_album(
        local_index_library.albums,
        ALBUM_P
    ) ~= nil,
    "completed album P was absent from the Local index"
)

local completed_p = assert(
    find_album(persisted_screen.sorted_albums, ALBUM_P),
    "completed album P disappeared from Local NEW"
)
assert(
    completed_p.pending_download ~= true,
    "completed album P remained a grey placeholder"
)
assert(
    type(completed_p.local_downloaded_at) == "number" and
        completed_p.local_downloaded_at > DEVICE_FRIDAY,
    "completed album P did not receive a device timestamp newer than existing downloads"
)
assert(
    runtime.local_downloaded_at({
        key = "id:" .. ALBUM_P,
        id = ALBUM_P,
    }) == completed_p.local_downloaded_at,
    "mounted album P recency did not match the runtime completed-download map"
)
assert(
    count_id(persisted_screen.sorted_albums, ALBUM_P) ==
        1,
    "placeholder -> completed hydration duplicated album P"
)

local still_q = assert(
    find_album(persisted_screen.sorted_albums, ALBUM_Q),
    "queued album Q disappeared during P completion"
)
assert(
    still_q.pending_download == true and
        still_q.download_state == "queued",
    "queued album Q did not remain one grey noninteractive placeholder"
)
assert(
    still_q.local_downloaded_at == nil,
    "queued album Q received completed recency when P completed"
)
assert(
    runtime.local_downloaded_at({
        jellyfin_id = ALBUM_Q,
        kind = "album",
    }) == nil,
    "queued request state received completed-download recency"
)

local row_p_after = find_row(persisted_screen, ALBUM_P)
local row_q_after = find_row(persisted_screen, ALBUM_Q)
assert(
    row_p_after and row_p_after.available ~= false,
    "completed album P was not enterable in Local after hydration"
)
assert(
    row_q_after and
        row_q_after.available == false and
        row_q_after.on_click == nil and
        row_q_after.on_long_press == nil,
    "queued Local placeholder became interactive after P completion"
)

-- Restart/reload must keep the live completion order from persisted recency
-- without rebuilding the completion fixture by hand.
package.loaded["sync_runtime"] = nil
package.loaded["jellyfin_local_library"] = nil
package.loaded["jellyfin_sort"] = nil
runtime_poll = nil
runtime = require("sync_runtime")
assert(runtime.start())
assert(
    runtime.local_downloaded_at({
        key = "id:" .. ALBUM_P,
        id = ALBUM_P,
    }) == completed_p.local_downloaded_at,
    "live completion recency did not persist across runtime reload"
)

local_library = require("jellyfin_local_library")
local reloaded_after_completion =
    local_library.Albums:new()
backstack.reset(reloaded_after_completion)
backstack.flush(12)
assert_same_list(
    ordered_ids(reloaded_after_completion.sorted_albums),
    AFTER_MOUNTED_NEW_ORDER,
    "Local NEW did not keep live-completion order after reload"
)
assert_same_list(
    ordered_ids(
        reloaded_after_completion.virtual_album_list.items
    ),
    AFTER_MOUNTED_NEW_ORDER,
    "mounted Local NEW did not keep live-completion order after reload"
)
assert(
    count_id(
        reloaded_after_completion.sorted_albums,
        ALBUM_P
    ) == 1,
    "reload after live completion duplicated album P"
)

local sync_ui = require("jellyfin_sync_ui")
local sync_albums = sync_ui.Catalog:new {
    title = "Albums",
    view = "albums",
}
backstack.reset(sync_albums)
backstack.flush(8)

local function catalog_row(album_id)
    for _, model in ipairs(
        sync_albums.result_models or
        sync_albums.media_rows or
        {}
    ) do
        local item = model.catalog_item
        if type(item) == "table" and
            item.jellyfin_id == album_id then
            return model
        end
    end
    return nil
end

local downloaded_row = assert(
    catalog_row(ALBUM_B),
    "Sync catalog did not mount completed album B"
)
local queued_row = assert(
    catalog_row(ALBUM_Q),
    "Sync catalog did not mount queued album Q"
)

assert(
    sync_ui.item_state(catalog_albums[1]) ==
        "downloaded",
    "completed album B was not authoritative downloaded in Sync"
)
assert(
    sync_ui.item_state(catalog_albums[2]) ==
        "queued",
    "queued album Q was not queued in Sync"
)

downloaded_row.on_long_press()
local downloaded_actions =
    sync_albums.track_action_sheet:state()
    .main_actions
local has_view_local = false
for _, action_id in ipairs(downloaded_actions) do
    if action_id == "view_album_local" or
        action_id == "view_local" then
        has_view_local = true
        break
    end
end
assert(
    has_view_local,
    "View in Local was missing after authoritative downloaded completion"
)

sync_albums.track_action_sheet:activate("cancel")
queued_row.on_long_press()
local queued_actions =
    sync_albums.track_action_sheet:state()
    .main_actions
for _, action_id in ipairs(queued_actions) do
    assert(
        action_id ~= "view_album_local" and
            action_id ~= "view_local",
        "View in Local appeared before authoritative downloaded completion"
    )
end

print(
    "Local Albums NEW device-download recency contract passed"
)
print(
    "seeded order: B Friday/" ..
        JELLYFIN_B ..
        " > C Wednesday/" ..
        JELLYFIN_C ..
        " > A Monday/" ..
        JELLYFIN_A
)
print(
    "expected album-id order: " ..
        table.concat(EXPECTED_NEW_ORDER, ",")
)
print(
    "completed before: " ..
        table.concat(BEFORE_COMPLETED_NEW_ORDER, ",")
)
print(
    "completed after: " ..
        table.concat(AFTER_COMPLETED_NEW_ORDER, ",")
)
print(
    "mounted before completion: " ..
        table.concat(BEFORE_MOUNTED_NEW_ORDER, ",")
)
print(
    "mounted after completion: " ..
        table.concat(AFTER_MOUNTED_NEW_ORDER, ",")
)

os.exit(0)

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

local ui_poll = nil
local original_timer = lvgl.Timer
lvgl.Timer = function(options)
    local timer = original_timer(options)
    if options.period == 250 and
        type(options.cb) == "function" then
        ui_poll = options.cb
    end
    return timer
end

-- Live Around the Fur shape: Sync catalog uses jellyfin_id, completed Local
-- album uses id + id:<id> key without jellyfin_id, while stale device counts
-- still report partial.
local album_id =
    "2aa082e41589d8de16d94a12e2412704"
local track_ids = {
    "8c5c0e47281cf3b659efc708da31f664",
    "ad28ddec3d3cb3582f14502b20cf92c1",
    "d9c0fff0d61c5b183209da56b6a67c82",
    "ab62d8defcb52b77c13861701d3eef32",
    "806b6c22345069d068f8104dda915068",
    "f3fdd79f1e15dfbb04f349bf4d4c3d0e",
    "f47f42f63a476613186305c04a2e371c",
    "1467e8a35570c2be898708cffd747111",
    "a58eebddd6760e79acb86a10e6866062",
    "89299df8b0e796cb2901a813d3c2a89f",
}

local album = {
    jellyfin_id = album_id,
    kind = "album",
    title = "Around the Fur",
    artist = "Deftones",
    jellyfin_artist_id =
        "272cdacd57102406275a7291c1c5ba41",
    track_count = 10,
    device = {
        state = "server_only",
        actionable = true,
        total_tracks = 10,
        downloaded_tracks = 0,
    },
}

local local_library = {
    tracks = {},
    albums = {},
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return local_library
    end,
}

package.loaded["sync_artwork_cache"] = {
    key = function(item)
        return tostring(
            item.jellyfin_id or ""
        )
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

package.loaded["sync_catalog"] = {
    cached = function(view)
        if view == "albums" then
            return {
                view = "albums",
                sort = "title",
                direction = "ascending",
                generation = 1,
                total = 1,
                total_count = 1,
                items = {album},
            }
        end
        return nil
    end,
    start = function()
        return true
    end,
    busy = function()
        return false
    end,
    error = function()
        return nil
    end,
    poll = function()
        return nil
    end,
    queue = function()
        return true
    end,
}

for _, name in ipairs({
    "sync_apply",
    "sync_runtime",
    "sync_sort",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_sync_ui",
    "jellyfin_local_library",
    "jellyfin_album_identity",
    "sync_download_state",
}) do
    package.loaded[name] = nil
end

local identity =
    require("jellyfin_album_identity")
local sync_download_state =
    require("sync_download_state")
sync_download_state.reset_for_tests()
local sync_apply = require("sync_apply")
local sync_runtime = require("sync_runtime")
local sync_ui = require("jellyfin_sync_ui")

assert(identity.album_id(album) == album_id)
assert(
    identity.local_album_key(album) ==
        ("id:" .. album_id)
)
assert(
    identity.same(album_id, "id:" .. album_id)
)
assert(
    identity.album_id({
        kind = "album",
        id = album_id,
        key = "id:" .. album_id,
    }) == album_id,
    "Local-shaped album ids must canonicalize"
)

local albums =
    sync_ui.Catalog:new {
        title = "Albums",
        view = "albums",
    }
backstack.reset(albums)
backstack.flush(8)
assert(type(ui_poll) == "function")

local row = assert(albums.result_models[1])
local row_object = row.object
assert(row.state == "server_only")

row.on_long_press()
assert(
    albums.track_action_sheet:activate(
        "download"
    )
)
assert(
    sync_runtime.item_state(album) == "queued"
)
assert(
    row.state == "downloading",
    "first request must become downloading"
)
assert(row.state_icon.kind == "downloading")
assert(
    sync_ui.download_icon_anim_active(),
    "downloading must start the spinner"
)

local pending = sync_runtime.pending_items()
local found_pending = false
for _, entry in ipairs(pending) do
    if identity.album_id(entry.item) ==
        album_id then
        found_pending = true
        break
    end
end
assert(
    found_pending,
    "queued album must create Local placeholder"
)

-- Authoritative downloading for the mounted album's canonical key.
local original_item_states =
    sync_apply.item_states
sync_apply.item_states = function()
    local states = {}
    states[album_id] = "downloading"
    return states
end

row:update_sync_catalog_item(album)
assert(
    row.state == "downloading",
    "active op must resolve to mounted album"
)
assert(row.state_icon.kind == "downloading")
sync_ui.sync_download_icon_anim(albums)
assert(
    sync_ui.download_icon_anim_active(),
    "spinner runs only while downloading"
)

-- Promote placeholder to completed Local inventory. Leave stale companion
-- partial counts and a stale expected-track cache on the Sync row.
sync_apply.item_states = function()
    return {}
end

local completed_tracks = {}
for index, track_id in ipairs(track_ids) do
    completed_tracks[index] = {
        jellyfin_id = track_id,
        id = track_id,
        album_id = album_id,
        album_key = "id:" .. album_id,
        title = "Track " .. index,
        artist = "Deftones",
        album = "Around the Fur",
    }
end

local_library = {
    tracks = completed_tracks,
    albums = {
        {
            key = "id:" .. album_id,
            id = album_id,
            name = "Around the Fur",
            track_count = 10,
        },
    },
}

album.device.state = "partial"
album.device.downloaded_tracks = 1
album.device.total_tracks = 10
album.jellyfin_track_ids = {
    track_ids[1],
    track_ids[2],
    "stale-missing-bonus",
}

assert(row.object == row_object)
row:update_sync_catalog_item(album)

assert(
    sync_ui.item_state(album) == "downloaded",
    "completed Local must override stale partial"
)
assert(
    row.state == "downloaded",
    "mounted row must update without recreation"
)
assert(
    row.state_icon and
        row.state_icon.kind == "device",
    "mounted icon must become local-device"
)
assert(
    not sync_ui.download_icon_anim_active(),
    "spinner must stop on downloaded"
)
assert(
    sync_runtime.item_state(album) == nil or
        sync_runtime.item_state(album) ~=
            "queued",
    "optimistic queued must clear"
)

row.on_long_press()
local done_actions =
    albums.track_action_sheet:state()
        .main_actions
assert(
    done_actions[1] == "view_album_local" and
        done_actions[2] ==
            "artist_discography" and
        done_actions[3] == "cancel",
    "downloaded menu must drop Download"
)
for _, action_id in ipairs(done_actions) do
    assert(action_id ~= "download")
end

assert(
    albums.track_action_sheet:activate(
        "view_album_local"
    )
)
backstack.flush(6)
local local_album = backstack.current()
assert(
    identity.canonical_id(
        local_album.album_key
    ) == album_id,
    "View in Local uses canonical key"
)
backstack.pop()
backstack.flush(4)

local remount =
    sync_ui.Catalog:new {
        title = "Albums",
        view = "albums",
    }
backstack.reset(remount)
backstack.flush(8)
local remount_row =
    assert(remount.result_models[1])
assert(
    remount_row.state == "downloaded",
    "re-entering Sync Albums still downloaded"
)
assert(remount_row.state_icon.kind == "device")

-- Incomplete Local album remains partial.
local_library = {
    tracks = {
        completed_tracks[1],
        completed_tracks[2],
    },
    albums = {
        {
            key = "id:" .. album_id,
            id = album_id,
            name = "Around the Fur",
            track_count = 2,
        },
    },
}
album.device.downloaded_tracks = 2
album.jellyfin_track_ids = nil
assert(
    sync_ui.item_state(album) == "partial",
    "incomplete Local album remains partial"
)

sync_apply.item_states = original_item_states
print(
    "jellyfin_sync_album_identity_state_test ok"
)
os.exit(0)

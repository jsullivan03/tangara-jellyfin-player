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

local fixture_root =
    os.tmpname() .. "-sync-complete"
os.remove(fixture_root)
assert(os.execute("mkdir -p " .. fixture_root))
package.loaded["device"] = {
    storage_root = function()
        return fixture_root
    end,
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

local album = {
    jellyfin_id = "album-complete-1",
    kind = "album",
    title = "Completion Album",
    artist = "Artist",
    jellyfin_artist_id = "artist-1",
    track_count = 2,
    device = {
        state = "server_only",
        actionable = true,
    },
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
    "sync_download_state",
}) do
    package.loaded[name] = nil
end

local sync_download_state =
    require("sync_download_state")
sync_download_state.reset_for_tests()

local sync_runtime = require("sync_runtime")
local sync_ui = require("jellyfin_sync_ui")
local local_ui =
    require("jellyfin_local_library")

local albums =
    sync_ui.Catalog:new {
        title = "Albums",
        view = "albums",
    }
backstack.reset(albums)
backstack.flush(8)

local row = assert(albums.result_models[1])
local row_object = row.object

row.on_long_press()
assert(
    albums.track_action_sheet:activate(
        "download"
    )
)

assert(
    sync_runtime.item_state(album) == "queued",
    "note_queued did not lock album-complete-1"
)
assert(
    row.state == "downloading",
    "first Sync request must become downloading"
)
assert(row.state_icon.kind == "downloading")

local pending = sync_runtime.pending_items()
local found_pending = false
for _, entry in ipairs(pending) do
    if entry.item and
        entry.item.jellyfin_id ==
            "album-complete-1" then
        found_pending = true
        break
    end
end
assert(
    found_pending,
    "queued album was not exposed as a Local placeholder pending item"
)

row.on_long_press()
local queued_actions =
    albums.track_action_sheet:state()
    .main_actions
assert(
    queued_actions[1] ==
        "artist_discography" and
        queued_actions[2] == "cancel" and
        queued_actions[3] == nil,
    "downloading album exposed View in Local before completion"
)
albums.track_action_sheet:close(true)

-- Partial inventory may appear on disk while the durable album operation is
-- still active. Local must keep that album as one dimmed, non-enterable
-- placeholder instead of exposing the subset of tracks already transferred.
local_library = {
    tracks = {
        {
            jellyfin_id = "track-c-1",
            album_id = "album-complete-1",
            title = "One",
            artist = "Artist",
        },
    },
    albums = {
        {
            id = "album-complete-1",
            key = "id:album-complete-1",
            name = "Completion Album",
            artist = "Artist",
            track_count = 1,
            tracks = {
                {
                    jellyfin_id = "track-c-1",
                    album_id = "album-complete-1",
                    title = "One",
                    artist = "Artist",
                },
            },
        },
    },
}

local local_albums =
    local_ui.Albums:new()
backstack.push(local_albums)
backstack.flush(6)

local pending_local_row =
    assert(
        local_albums.virtual_album_list and
        local_albums.virtual_album_list.pool[1]
    )
assert(
    pending_local_row.available == false and
        pending_local_row.on_click == nil and
        pending_local_row.on_long_press == nil,
    "partially transferred Local album became enterable before completion"
)

backstack.pop()
backstack.flush(4)
assert(backstack.current() == albums)

-- Authoritative completion: local inventory has every track; optimistic must clear.
local_library = {
    tracks = {
        {
            jellyfin_id = "track-c-1",
            album_id = "album-complete-1",
            title = "One",
            artist = "Artist",
        },
        {
            jellyfin_id = "track-c-2",
            album_id = "album-complete-1",
            title = "Two",
            artist = "Artist",
        },
    },
    albums = {
        {
            id = "album-complete-1",
            track_count = 2,
        },
    },
}

row = nil
for _, model in ipairs(
    albums.result_models or {}
) do
    if model.catalog_item and
        model.catalog_item.jellyfin_id ==
            "album-complete-1" then
        row = model
        break
    end
end
assert(row)
assert(row.object == row_object)

row:update_sync_catalog_item(row.catalog_item)
assert(
    sync_runtime.item_state(album) == nil or
        sync_runtime.item_state(album) ~=
            "queued",
    "optimistic queued was not cleared by authoritative local completion"
)
assert(
    row.state == "downloaded",
    "mounted row stayed queued after local completion"
)
assert(
    row.state_icon and
        row.state_icon.kind == "device",
    "mounted trailing icon did not become device/local"
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
    "completed menu did not rebuild from downloaded state"
)

print(
    "Sync authoritative completion and Local placeholder passed"
)
os.execute("rm -rf " .. fixture_root)
os.exit(0)

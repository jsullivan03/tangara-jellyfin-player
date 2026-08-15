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

local album = {
    jellyfin_id = "album-center",
    kind = "album",
    title = "Centered",
    artist = "Artist",
    jellyfin_artist_id = "artist-1",
    track_count = 1,
    device = {state = "server_only"},
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {tracks = {}, albums = {}}
    end,
}

package.loaded["sync_artwork_cache"] = {
    key = function()
        return "k"
    end,
    request = function(_, cb)
        if cb then
            cb(nil)
        end
        return nil
    end,
    cancel = function()
        return true
    end,
    poll = function()
    end,
}

local runtime_state = "server_only"
package.loaded["sync_runtime"] = {
    apply_progress = function()
        return nil
    end,
    last_apply_result = function()
        return nil
    end,
    request_refresh = function()
        return true
    end,
    content_generation = function()
        return 0
    end,
    state_generation = function()
        return 0
    end,
    item_state = function()
        return runtime_state ~=
                "server_only" and
            runtime_state or nil
    end,
    clear_optimistic = function()
        return true
    end,
    last_library_result = function()
        return nil
    end,
    last_result = function()
        return nil
    end,
    pending_items = function()
        return {}
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
    "sync_sort",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_sync_ui",
}) do
    package.loaded[name] = nil
end

local sync_ui = require("jellyfin_sync_ui")
local cell = assert(sync_ui.status_cell)

local albums =
    sync_ui.Catalog:new {
        title = "Albums",
        view = "albums",
    }
backstack.reset(albums)
backstack.flush(8)

local row = assert(albums.result_models[1])
local centers = {}

local function capture(label)
    assert(
        row.state_icon and
            row.state_icon.cell,
        label .. " missing status cell"
    )
    assert(
        row.state_icon.cell.center_x ==
            cell.center_x and
            row.state_icon.cell.center_y ==
                cell.center_y and
            row.state_icon.cell.x == cell.x and
            row.state_icon.cell.y == cell.y and
            row.state_icon.cell.w == cell.w and
            row.state_icon.cell.h == cell.h,
        label .. " left the shared trailing cell"
    )
    centers[#centers + 1] = {
        label = label,
        kind = row.state_icon.kind,
        x = row.state_icon.cell.center_x,
        y = row.state_icon.cell.center_y,
    }
end

capture("server")

runtime_state = "queued"
album.device.state = "queued"
row:update_sync_catalog_item(album)
assert(row.state_icon.kind == "queued")
capture("queued")

runtime_state = "downloading"
album.device.state = "downloading"
row:update_sync_catalog_item(album)
assert(
    row.state_icon.kind == "downloading" and
        row.state_icon.spinner ~= nil,
    "downloading must use a native rotating spinner object"
)
capture("downloading")

runtime_state = "failed"
album.device.state = "failed"
row:update_sync_catalog_item(album)
assert(row.state_icon.kind == "failed")
capture("failed")

runtime_state = nil
album.device.state = {
    state = "downloaded",
    total_tracks = 1,
    downloaded_tracks = 1,
}
album.track_count = 1
-- Force device-inventory completion without swapping the required local_index
-- module binding that jellyfin_sync_ui already captured.
album.device = {
    state = "downloaded",
    total_tracks = 1,
    downloaded_tracks = 1,
}
row:update_sync_catalog_item(album)
assert(
    row.state == "downloaded",
    "device inventory did not mark downloaded"
)
assert(row.state_icon.kind == "device")
capture("downloaded")

for index = 2, #centers do
    assert(
        centers[index].x == centers[1].x and
            centers[index].y ==
                centers[1].y,
        centers[index].label ..
            " center drifted from " ..
            centers[1].label
    )
end

print(
    "Sync trailing status cell center geometry passed"
)
os.exit(0)

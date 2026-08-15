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
    if options.period == 250 and
        type(options.cb) == "function" then
        ui_poll = options.cb
    end
    return original_timer(options)
end

local track = {
    jellyfin_id = "track-progress-1",
    kind = "track",
    title = "Small Download",
    artist = "Test Artist",
    album = "Progress Album",
    album_id = "album-progress-1",
    device = {
        state = "server_only",
        actionable = true,
    },
}

local payload = {
    view = "tracks",
    sort = "title",
    direction = "ascending",
    total = 1,
    total_count = 1,
    items = {track},
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

local queued_item = nil
local queue_result_pending = false
package.loaded["sync_catalog"] = {
    cached = function(view)
        if view == "tracks" then
            return payload
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
    queue = function(item)
        queued_item = item
        queue_result_pending = true
        return true
    end,
    poll = function()
        if not queue_result_pending then
            return nil
        end
        queue_result_pending = false
        queued_item.device.state = "queued"
        queued_item.device.actionable = false
        return {
            ok = true,
            kind = "queue",
            payload = {},
        }
    end,
}

local runtime_progress = nil
local runtime_result = nil
local refresh_requests = 0
package.loaded["sync_runtime"] = {
    apply_progress = function()
        return runtime_progress
    end,
    last_apply_result = function()
        return runtime_result
    end,
    request_refresh = function()
        refresh_requests =
            refresh_requests + 1
        return true
    end,
    last_library_result = function()
        return nil
    end,
    last_result = function()
        return nil
    end,
}

package.loaded["sync_artwork_cache"] = {
    key = function(item)
        return tostring(
            item.jellyfin_id or ""
        )
    end,
    request = function(_item, callback)
        callback(nil)
        return nil
    end,
    cancel = function()
        return true
    end,
    poll = function()
    end,
}

for _, module_name in ipairs({
    "sync_sort",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_sync_ui",
}) do
    package.loaded[module_name] = nil
end

local sync_ui =
    require("jellyfin_sync_ui")
local tracks =
    sync_ui.Catalog:new {
        title = "Tracks",
        view = "tracks",
    }

backstack.reset(tracks)
backstack.flush(8)
assert(type(ui_poll) == "function")

local row = assert(tracks.result_models[1])
local row_object = row.object
lvgl.group.focus_obj(row.object)
local focused_before =
    tracks.focus_group:get_focused()
local list_before = tracks.list:get_coords()

row.on_click()
local sheet = assert(tracks.track_action_sheet)
assert(sheet.is_open)
assert(sheet:activate("download"))
ui_poll()

assert(
    queued_item and
        queued_item.jellyfin_id ==
            track.jellyfin_id
)
assert(refresh_requests == 1)
assert(row.object == row_object)
-- Track rows may remain queued until apply progress promotes them; album-key
-- owner head is downloading after dispatch.
assert(
    row.state == "queued" or
        row.state == "downloading"
)
assert(
    not row.detail.text:find(
        "Queued",
        1,
        true
    ),
    "queued state leaked into artist/detail text"
)
assert(
    row.detail.text:find(
        "Test Artist",
        1,
        true
    ),
    "queued row lost original artist/detail text"
)
assert(
    row.state_icon and
        (
            row.state_icon.kind == "queued" or
            row.state_icon.kind == "downloading"
        ),
    "download row did not swap to compact trailing icon"
)
assert(
    row.on_click == nil and
        row.on_long_press ~= nil and
        sync_ui.actionable(track),
    "queued row must keep long-hold without Download click"
)
assert(
    row.virtual_on_long_press ~= nil and
        row.on_long_press ==
            row.virtual_on_long_press,
    "queued runtime refresh replaced the virtual long-hold handler"
)
row.on_long_press()
local queued_sheet =
    assert(tracks.track_action_sheet)
local queued_state = queued_sheet:state()
assert(
    queued_sheet.is_open and
        queued_state.main_actions[1] ==
            "artist_discography" and
        queued_state.main_actions[2] ==
            "cancel" and
        queued_state.main_actions[3] == nil,
    "queued Sync row must hide View in Local until download completion"
)
queued_sheet:close(true)

local depth_while_queued =
    backstack.depth()
sync_ui.activate(track, tracks)
assert(
    backstack.depth() ==
        depth_while_queued,
    "queued row opened a separate status screen"
)

runtime_result = {
    ok = false,
    error = "fixture transfer failed",
    failed_action = {
        kind = "media",
        item = track,
    },
}
ui_poll()
assert(row.object == row_object)
assert(row.state == "failed")
assert(
    not row.detail.text:find(
        "Failed",
        1,
        true
    ),
    "failed state leaked into artist/detail text"
)
assert(
    row.state_icon and
        row.state_icon.kind == "failed"
)
assert(
    row.on_long_press ~= nil,
    "failed row lost long-hold retry"
)
row.on_long_press()
local retry_sheet = assert(tracks.track_action_sheet)
local retry_state = retry_sheet:state()
assert(
    retry_sheet.is_open and
        retry_state.main_actions[1] ==
            "retry_download" and
        retry_state.main_actions[2] ==
            "artist_discography" and
        retry_state.main_actions[3] ==
            "cancel",
    "failed Sync row did not expose Retry Download, Artist Discography, Cancel"
)
retry_sheet:close(true)

runtime_progress = {
    action = {
        kind = "media",
        item = track,
    },
    bytes = 512,
    bytes_total = 1024,
    completed = 0,
    total = 1,
}
runtime_result = nil
ui_poll()

assert(row.object == row_object)
assert(row.state == "downloading")
assert(
    row.sync_progress_visible ~= true,
    "Sync rows must not show a download progress bar"
)
assert(
    row.sync_progress_track == nil,
    "Sync progress track objects must not exist"
)
assert(
    row.state_icon and
        row.state_icon.kind == "downloading",
    "downloading row must use compact trailing icon only"
)
assert(
    not row.detail.text:find(
        "Downloading",
        1,
        true
    ),
    "downloading state leaked into artist/detail text"
)
assert(
    row.on_click == nil and
        row.on_long_press ~= nil and
        sync_ui.actionable(track),
    "downloading row must keep long-hold without Download click"
)
assert(
    sync_ui.download_icon_anim_active(),
    "downloading state did not start the shared trailing-icon animation"
)
row.on_long_press()
local downloading_sheet =
    assert(tracks.track_action_sheet)
local downloading_state =
    downloading_sheet:state()
assert(
    downloading_sheet.is_open and
        downloading_state.main_actions[1] ==
            "artist_discography" and
        downloading_state.main_actions[2] ==
            "cancel" and
        downloading_state.main_actions[3] == nil,
    "downloading Sync row must hide View in Local until download completion"
)
downloading_sheet:close(true)
assert(
    tracks.focus_group:get_focused() ==
        focused_before,
    "progress update moved focus"
)
local list_during = tracks.list:get_coords()
assert(
    list_during.y1 == list_before.y1 and
        list_during.y2 == list_before.y2,
    "progress update moved the list"
)

-- A completed media download invalidates the real local index.  Model that
-- resulting new index object here and verify the existing Sync row upgrades
-- in place without reopening the page.
local_library = {
    tracks = {
        {
            jellyfin_id =
                "track-progress-1",
            title = "Small Download",
            artist = "Test Artist",
            album = "Progress Album",
            album_id = "album-progress-1",
            date_created =
                "2026-08-01T12:00:00Z",
        },
    },
    albums = {
        {
            id = "album-progress-1",
            track_count = 1,
            date_created =
                "2026-08-01T12:00:00Z",
        },
    },
}
runtime_progress = nil
runtime_result = {
    ok = true,
    completed = 1,
    total = 1,
}
ui_poll()

assert(row.object == row_object)
assert(row.state == "downloaded")
assert(row.sync_progress_visible == false)
assert(
    row.state_icon and
        row.state_icon.kind == "device"
)
assert(
    row.on_click == nil and
        row.on_long_press ~= nil and
        sync_ui.actionable(track),
    "on-device row was not long-holdable for View in Local"
)
assert(
    tracks.focus_group:get_focused() ==
        focused_before,
    "completion update moved focus"
)

row.on_long_press()
local local_sheet = assert(tracks.track_action_sheet)
local local_state = local_sheet:state()
assert(
    local_sheet.is_open and
        local_state.main_actions[1] ==
            "view_local" and
        local_state.main_actions[2] ==
            "artist_discography" and
        local_state.main_actions[3] ==
            "cancel",
    "completed Sync track did not expose View in Local, Artist Discography, Cancel"
)
local_sheet:close(true)

print(
    "Sync queued/download progress/completion UI passed"
)
os.exit(0)

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
local anim_timers = {}
local original_timer = lvgl.Timer
lvgl.Timer = function(options)
    local timer = original_timer(options)
    if options.period == 250 and
        type(options.cb) == "function" then
        ui_poll = options.cb
    end
    if options.period == 50 or
        options.period == 125 then
        anim_timers[#anim_timers + 1] = {
            options = options,
            timer = timer,
        }
    end
    return timer
end

local album_a = {
    jellyfin_id = "album-a",
    kind = "album",
    title = "Album A",
    artist = "Shared Artist",
    jellyfin_artist_id = "artist-1",
    track_count = 2,
    device = {
        state = "server_only",
        actionable = true,
    },
}

local album_b = {
    jellyfin_id = "album-b",
    kind = "album",
    title = "Album B",
    artist = "Shared Artist",
    jellyfin_artist_id = "artist-1",
    track_count = 1,
    device = {
        state = "server_only",
        actionable = true,
    },
}

local track_no_album = {
    jellyfin_id = "track-orphan-1",
    kind = "track",
    title = "Orphan Track",
    artist = "Shared Artist",
    jellyfin_artist_id = "artist-1",
    device = {
        state = "server_only",
        actionable = true,
    },
}

local payload = {
    view = "albums",
    sort = "title",
    direction = "ascending",
    total = 2,
    total_count = 2,
    items = {album_a, album_b},
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

local queued_items = {}
local queue_results = {}
package.loaded["sync_catalog"] = {
    cached = function(view)
        if view == "albums" then
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
        queued_items[#queued_items + 1] =
            item
        queue_results[#queue_results + 1] =
            true
        return true
    end,
    poll = function()
        return nil
    end,
}

local apply_states = {}
local runtime_progress = nil
local runtime_result = nil
local optimistic = {}
local content_generation = 1

package.loaded["sync_runtime"] = {
    apply_progress = function()
        return runtime_progress
    end,
    last_apply_result = function()
        return runtime_result
    end,
    request_refresh = function()
        return true
    end,
    last_library_result = function()
        return nil
    end,
    last_result = function()
        return nil
    end,
    content_generation = function()
        return content_generation
    end,
    state_generation = function()
        return content_generation
    end,
    note_queued = function(item)
        local id = item.jellyfin_id
        local owner =
            package.loaded["sync_download_state"]
        local owner_state =
            type(owner) == "table" and
            type(owner.lookup) == "function" and
            owner.lookup(item) or nil
        local state =
            owner_state and
            (
                owner_state.state == "downloading" or
                owner_state.state == "queued"
            ) and
            owner_state.state or
            "queued"
        optimistic[id] = state
        if type(item.device) ~= "table" then
            item.device = {}
        end
        item.device.state = state
        return true
    end,
    note_failed = function(item)
        local id = item.jellyfin_id
        optimistic[id] = "failed"
        if type(item.device) ~= "table" then
            item.device = {}
        end
        item.device.state = "failed"
        return true
    end,
    item_state = function(item)
        local id =
            type(item) == "table" and
            item.jellyfin_id or item
        if apply_states[id] then
            return apply_states[id]
        end
        return optimistic[id]
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
    "sync_download_state",
}) do
    package.loaded[module_name] = nil
end

local sync_download_state =
    require("sync_download_state")
sync_download_state.reset_for_tests()

local sync_ui =
    require("jellyfin_sync_ui")

-- Sync projections must not be written back into the legacy catalog source.
local stale_catalog_album = {
    jellyfin_id = "stale-catalog-album",
    kind = "album",
    title = "Stale Catalog Album",
    artist = "Shared Artist",
    track_count = 1,
    device = {
        state = "queued",
        actionable = true,
    },
}
assert(
    sync_ui.item_state(stale_catalog_album) ==
        "server_only",
    "stale catalog queued state remained authoritative"
)
assert(
    stale_catalog_album.device.state ==
        "queued",
    "owner projection fed back into legacy device.state"
)

local albums =
    sync_ui.Catalog:new {
        title = "Albums",
        view = "albums",
    }

backstack.reset(albums)
backstack.flush(8)
assert(type(ui_poll) == "function")

local function row_for(id)
    for _, model in ipairs(
        albums.result_models or {}
    ) do
        if model.catalog_item and
            model.catalog_item.jellyfin_id ==
                id then
            return model
        end
    end
    return nil
end

local function assert_actions(model, expected, label)
    assert(model.on_long_press ~= nil, label)
    model.on_long_press()
    local sheet = assert(albums.track_action_sheet)
    local state = sheet:state()
    assert(sheet.is_open, label)
    for index, action_id in ipairs(expected) do
        assert(
            state.main_actions[index] ==
                action_id,
            label ..
                " expected " ..
                action_id ..
                " at " ..
                tostring(index) ..
                " got " ..
                tostring(
                    state.main_actions[index]
                )
        )
    end
    assert(
        #state.main_actions == #expected,
        label .. " action count"
    )
    sheet:close(true)
end

local row_a = assert(row_for("album-a"))
local row_b = assert(row_for("album-b"))

assert_actions(
    row_a,
    {
        "download",
        "artist_discography",
        "cancel",
    },
    "undownloaded album menu"
)

row_a.on_long_press()
albums.track_action_sheet:activate("download")
assert(
    row_a.state == "downloading",
    "first request becomes downloading"
)
assert(
    row_a.state_icon and
        row_a.state_icon.kind == "downloading"
)
assert_actions(
    row_a,
    {
        "artist_discography",
        "cancel",
    },
    "downloading album menu after first request"
)

-- Second album request while A is still downloading.
row_b.on_long_press()
albums.track_action_sheet:activate("download")
assert(row_b.state == "queued")
assert(
    row_b.state_icon and
        row_b.state_icon.kind == "queued"
)

apply_states["album-a"] = "downloading"
apply_states["album-b"] = "queued"
runtime_progress = {
    action = {
        kind = "media",
        item = album_a,
    },
    bytes = 10,
    bytes_total = 100,
}
content_generation = content_generation + 1
ui_poll()

assert(row_a.state == "downloading")
assert(
    row_a.state_icon and
        row_a.state_icon.kind ==
            "downloading"
)
assert(row_b.state == "queued")
assert(
    row_b.state_icon and
        row_b.state_icon.kind == "queued"
)
assert(
    #anim_timers == 1 and
        sync_ui.download_icon_anim_active(),
    "expected exactly one shared downloading animation timer"
)
assert_actions(
    row_a,
    {
        "artist_discography",
        "cancel",
    },
    "downloading album menu"
)
assert_actions(
    row_b,
    {
        "artist_discography",
        "cancel",
    },
    "queued album B menu"
)

-- Promote B when A completes.
local_library = {
    tracks = {
        {
            jellyfin_id = "track-a-1",
            album_id = "album-a",
            title = "A1",
            artist = "Shared Artist",
        },
        {
            jellyfin_id = "track-a-2",
            album_id = "album-a",
            title = "A2",
            artist = "Shared Artist",
        },
    },
    albums = {
        {
            id = "album-a",
            track_count = 2,
        },
    },
}
apply_states["album-a"] = nil
optimistic["album-a"] = nil
album_a.device.state = "downloaded"
apply_states["album-b"] = "downloading"
runtime_progress = {
    action = {
        kind = "media",
        item = album_b,
    },
    bytes = 20,
    bytes_total = 100,
}
runtime_result = {
    ok = true,
    completed = 1,
    total = 2,
}
content_generation = content_generation + 1
ui_poll()

assert(
    row_a.state == "downloaded",
    "album A did not complete in place"
)
assert(
    row_a.state_icon and
        row_a.state_icon.kind == "device"
)
assert(row_b.state == "downloading")
assert(
    row_b.state_icon and
        row_b.state_icon.kind ==
            "downloading"
)
assert_actions(
    row_a,
    {
        "view_album_local",
        "artist_discography",
        "cancel",
    },
    "downloaded album menu"
)

-- Complete B and verify animation stops / queue promotion finished.
apply_states["album-b"] = nil
optimistic["album-b"] = nil
album_b.device.state = "downloaded"
local_library.tracks[#local_library.tracks + 1] = {
    jellyfin_id = "track-b-1",
    album_id = "album-b",
    title = "B1",
    artist = "Shared Artist",
}
runtime_progress = nil
runtime_result = {
    ok = true,
    completed = 2,
    total = 2,
}
content_generation = content_generation + 1
ui_poll()
assert(
    row_b.state == "downloaded",
    "album B state=" .. tostring(row_b.state)
)
assert(
    row_b.state_icon and
        row_b.state_icon.kind == "device"
)
assert(
    not sync_ui.download_icon_anim_active(),
    "download animation kept running after no downloading rows"
)
assert_actions(
    row_b,
    {
        "view_album_local",
        "artist_discography",
        "cancel",
    },
    "downloaded album B menu"
)

local pushed = nil
local original_push = backstack.push
backstack.push = function(screen)
    pushed = screen
    return true
end
assert(
    row_a.available ~= false and
        row_a.on_click ~= nil,
    "downloaded album row was not focusable/activatable"
)
sync_ui.activate(album_a, albums)
assert(
    pushed and pushed.album_key == "id:album-a",
    "downloaded album activation did not open canonical Local album"
)
pushed = nil
row_a.on_long_press()
albums.track_action_sheet:activate(
    "view_album_local"
)
backstack.push = original_push
assert(
    pushed and
        pushed.album_key == "id:album-a",
    "View in Local did not open exact album id"
)
assert(
    pushed.selected_item_id == nil,
    "View in Local should not force a track selection"
)

-- Track without album opens Local Tracks with exact selection.
local_library.tracks[#local_library.tracks + 1] =
    {
        jellyfin_id = "track-orphan-1",
        title = "Orphan Track",
        artist = "Shared Artist",
    }
content_generation = content_generation + 1
track_no_album.device.state = "downloaded"
optimistic["track-orphan-1"] = nil
row_a:update_sync_catalog_item(track_no_album)
assert(row_a.state == "downloaded")
assert_actions(
    row_a,
    {
        "view_local",
        "artist_discography",
        "cancel",
    },
    "downloaded track without album menu"
)
pushed = nil
backstack.push = function(screen)
    pushed = screen
    return true
end
row_a.on_long_press()
albums.track_action_sheet:activate("view_local")
backstack.push = original_push
assert(
    pushed and
        pushed.selected_item_id ==
            "track-orphan-1",
    "track without album did not open Local Tracks with exact track id"
)

-- Track with album selects exact track on Local album.
local track_with_album = {
    jellyfin_id = "track-a-2",
    kind = "track",
    title = "A2",
    artist = "Shared Artist",
    jellyfin_artist_id = "artist-1",
    album_id = "album-a",
    device = {state = "downloaded"},
}
row_a:update_sync_catalog_item(
    track_with_album
)
assert(row_a.state == "downloaded")
pushed = nil
backstack.push = function(screen)
    pushed = screen
    return true
end
row_a.on_long_press()
albums.track_action_sheet:activate("view_local")
backstack.push = original_push
assert(
    pushed and
        pushed.album_key == "id:album-a" and
        pushed.selected_item_id ==
            "track-a-2",
    "downloaded track did not open exact Local album with exact track selected"
)

-- Recycled row must not keep downloading icon/animation target.
row_a:update_sync_catalog_item({
    jellyfin_id = "album-fresh",
    kind = "album",
    title = "Fresh",
    artist = "Shared Artist",
    jellyfin_artist_id = "artist-1",
    device = {state = "server_only"},
})
assert(
    row_a.state == "server_only" and
        row_a.state_icon and
        row_a.state_icon.kind == "server",
    "recycled row retained prior download state"
)
assert_actions(
    row_a,
    {
        "download",
        "artist_discography",
        "cancel",
    },
    "recycled undownloaded album menu"
)

-- Failed exposes Retry Download + Artist Discography.
optimistic["album-fresh"] = "failed"
row_a:update_sync_catalog_item({
    jellyfin_id = "album-fresh",
    kind = "album",
    title = "Fresh",
    artist = "Shared Artist",
    jellyfin_artist_id = "artist-1",
    device = {state = "failed"},
})
assert(row_a.state == "failed")
assert_actions(
    row_a,
    {
        "retry_download",
        "artist_discography",
        "cancel",
    },
    "failed album menu"
)

-- Duplicate download lockout.
local queue_count = #queued_items
optimistic["album-fresh"] = nil
row_a:update_sync_catalog_item({
    jellyfin_id = "album-fresh",
    kind = "album",
    title = "Fresh",
    artist = "Shared Artist",
    jellyfin_artist_id = "artist-1",
    device = {state = "server_only"},
})
row_a.on_long_press()
albums.track_action_sheet:activate("download")
assert(
    row_a.state == "downloading",
    "duplicate lockout setup state"
)
local after_first = #queued_items
assert(after_first == queue_count + 1)
row_a.on_long_press()
local busy_state =
    albums.track_action_sheet:state()
assert(
    busy_state.main_actions[1] ~= "download",
    "Download remained available after queueing"
)
albums.track_action_sheet:close(true)
assert(
    #queued_items == after_first,
    "duplicate download was requested"
)

-- Legacy confirmation and status screens must enter the same owner FIFO;
-- neither may POST directly around attempt tracking.
sync_download_state.reset_for_tests()
local confirm_item = {
    jellyfin_id = "confirm-owner-path",
    kind = "album",
    title = "Confirm Owner Path",
    artist = "Shared Artist",
    device = {state = "server_only"},
}
local confirm_screen = sync_ui.Confirm:new {
    item = confirm_item,
}
confirm_screen:create_ui()
local confirm_queue_before = #queued_items
confirm_screen.confirm_row.on_click()
local confirm_operations =
    sync_download_state.operations()
assert(#queued_items == confirm_queue_before + 1)
assert(
    confirm_operations[1] and
        confirm_operations[1].key ==
            "id:confirm-owner-path",
    "Confirm bypassed the owner FIFO"
)

sync_download_state.reset_for_tests()
local retry_item = {
    jellyfin_id = "status-owner-path",
    kind = "album",
    title = "Status Owner Path",
    artist = "Shared Artist",
    device = {state = "failed"},
}
optimistic[retry_item.jellyfin_id] = "failed"
assert(sync_download_state.fail(retry_item, {
    message = "retry",
    retriable = true,
}))
local status_screen = sync_ui.Status:new {
    item = retry_item,
}
status_screen:create_ui()
local retry_queue_before = #queued_items
status_screen.rows[2].on_click()
local retry_operations =
    sync_download_state.operations()
assert(#queued_items == retry_queue_before + 1)
assert(
    retry_operations[1] and
        retry_operations[1].key ==
            "id:status-owner-path",
    "Status retry bypassed the owner FIFO"
)

print(
    "Sync download state machine / composed menus passed"
)
os.exit(0)

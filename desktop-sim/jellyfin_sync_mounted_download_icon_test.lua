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
local anim_starts = 0
local original_timer = lvgl.Timer
lvgl.Timer = function(options)
    if options.period == 250 and
        type(options.cb) == "function" then
        ui_poll = options.cb
    end
    return original_timer(options)
end

local album = {
    jellyfin_id = "album-808s",
    kind = "album",
    title = "808s & Heartbreak",
    artist = "Kanye West",
    jellyfin_artist_id = "artist-kanye",
    track_count = 2,
    device = {
        state = "server_only",
        actionable = true,
    },
}

local items = {album}
for index = 2, 8 do
    items[index] = {
        jellyfin_id =
            "album-pad-" .. tostring(index),
        kind = "album",
        title = "Pad " .. tostring(index),
        artist = "Artist",
        track_count = 1,
        device = {state = "server_only"},
    }
end

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
    request = function(_, callback)
        callback(nil)
        return nil
    end,
    cancel = function()
        return true
    end,
    poll = function()
    end,
}

local queued_item = nil
package.loaded["sync_catalog"] = {
    cached = function(view)
        if view == "albums" then
            return {
                view = "albums",
                sort = "title",
                direction = "ascending",
                generation = 1,
                total = #items,
                total_count = #items,
                items = items,
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
    queue = function(item)
        queued_item = item
        return true
    end,
    poll = function()
        return nil
    end,
}

-- Real sync_runtime so note_queued / item_state share stable IDs with catalog.
for _, name in ipairs({
    "sync_apply",
    "sync_runtime",
    "sync_sort",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_sync_ui",
    "sync_download_state",
}) do
    package.loaded[name] = nil
end

local sync_download_state =
    require("sync_download_state")
sync_download_state.reset_for_tests()

local sync_runtime = require("sync_runtime")
local sync_ui = require("jellyfin_sync_ui")

local albums =
    sync_ui.Catalog:new {
        title = "Albums",
        view = "albums",
    }

backstack.reset(albums)
backstack.flush(8)

local function mounted_row(id)
    for _, model in ipairs(
        albums.media_rows or {}
    ) do
        if model.catalog_item and
            model.catalog_item.jellyfin_id ==
                id then
            return model
        end
    end
    return nil
end

local row = assert(mounted_row("album-808s"))
local row_object = row.object
assert(
    row.state_icon and
        row.state_icon.kind == "server"
)
assert(
    row.focused == true,
    "mounted selected album was not focused after virtual-list mount"
)
assert(
    backstack.is_focused(row.object),
    "mounted selected album was not LVGL-focused on first frame"
)

-- Download through the real sheet → close → start_download path.
row.on_long_press()
assert(albums.track_action_sheet:activate("download"))

row = assert(mounted_row("album-808s"))
assert(
    row.object == row_object,
    "download refresh replaced the mounted row object"
)
assert(
    queued_item and
        queued_item.jellyfin_id ==
            "album-808s"
)
assert(
    sync_runtime.item_state(row.catalog_item) ==
        "queued",
    "runtime item_state was not queued for album-808s"
)
assert(
    row.state == "downloading",
    "mounted row state not downloading after Download"
)
assert(
    row.state_icon and
        row.state_icon.kind == "downloading" and
        #(row.state_icon.parts or {}) > 0 and
        row.state_icon.cell and
        row.state_icon.cell.center_x ==
            sync_ui.status_cell.center_x,
    "mounted trailing icon did not become downloading in the shared status cell"
)

-- Promote to downloading using the same stable album id the mounted row holds.
local original_item_state =
    sync_runtime.item_state
sync_runtime.item_state = function(item)
    local id =
        type(item) == "table" and
        item.jellyfin_id or item
    if id == "album-808s" then
        return "downloading"
    end
    return original_item_state(item)
end
sync_runtime.apply_progress = function()
    return {
        action = {
            kind = "media",
            item = {
                jellyfin_id = "track-808s-1",
                album_id = "album-808s",
                kind = "track",
            },
        },
        bytes = 40,
        bytes_total = 100,
    }
end

albums.sync_runtime_signature = "force"
ui_poll()
row = assert(mounted_row("album-808s"))
assert(
    row.object == row_object,
    "downloading refresh replaced mounted row"
)
assert(
    row.state == "downloading",
    "mounted row did not become downloading"
)
assert(
    row.state_icon and
        row.state_icon.kind ==
            "downloading" and
        row.state_icon.spinner ~= nil and
        row.state_icon.cell.center_x ==
            sync_ui.status_cell.center_x,
    "mounted trailing icon did not become a centered native spinner"
)

-- Completion with local tracks for this album id.
local_library = {
    tracks = {
        {
            jellyfin_id = "track-808s-1",
            album_id = "album-808s",
            title = "Say You Will",
            artist = "Kanye West",
        },
        {
            jellyfin_id = "track-808s-2",
            album_id = "album-808s",
            title = "Welcome To Heartbreak",
            artist = "Kanye West",
        },
    },
    albums = {
        {
            id = "album-808s",
            track_count = 2,
        },
    },
}
sync_runtime.item_state = function()
    return nil
end
sync_runtime.apply_progress = function()
    return nil
end
row:update_sync_catalog_item(row.catalog_item)
assert(
    row.object == row_object,
    "completion refresh replaced mounted row"
)
assert(
    row.state == "downloaded",
    "mounted row did not become downloaded after local tracks appeared"
)
assert(
    row.state_icon and
        row.state_icon.kind == "device",
    "mounted trailing icon did not become device/local"
)

row.on_long_press()
local actions =
    albums.track_action_sheet:state()
    .main_actions
assert(
    actions[1] == "view_album_local" and
        actions[2] ==
            "artist_discography" and
        actions[3] == "cancel",
    "completed mounted album menu order wrong"
)

print(
    "Sync mounted-row download icon path passed"
)
os.exit(0)

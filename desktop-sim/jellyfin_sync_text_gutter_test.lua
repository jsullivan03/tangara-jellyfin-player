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

local track_icon = {
    jellyfin_id = "track-long-1",
    kind = "track",
    title =
        "Extremely Long Sync Track Title That Must Not Draw Under The Icon",
    artist =
        "Extremely Long Artist Name That Also Truncates Before The Icon",
    album = "Progress Album",
    device = {
        state = "server_only",
        actionable = true,
    },
}

local track_plain = {
    key = "opaque-external-1",
    kind = "track",
    title = "Plain Track Without Icon",
    artist = "Plain Artist Without Icon",
    album = "Plain Album",
    availability = "available",
}

local payload = {
    view = "tracks",
    sort = "title",
    direction = "ascending",
    total = 2,
    total_count = 2,
    items = {track_icon, track_plain},
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {tracks = {}, albums = {}}
    end,
}

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
    poll = function()
        return nil
    end,
    page = function()
        return {
            ok = true,
            items = payload.items,
            total = 2,
        }
    end,
    queue = function()
        return true
    end,
}

package.loaded["sync_runtime"] = {
    note_queued = function()
        return true
    end,
    item_state = function()
        return nil
    end,
    apply_progress = function()
        return nil
    end,
    last_apply_result = function()
        return nil
    end,
    last_library_result = function()
        return {ok = true}
    end,
    content_generation = function()
        return 1
    end,
    state_generation = function()
        return 1
    end,
    request_refresh = function()
    end,
}

package.loaded["sync_artwork_cache"] = {
    key = function()
        return nil
    end,
    request = function()
        return nil, nil
    end,
    cancel = function()
    end,
    poll = function()
    end,
}

package.loaded["jellyfin_navigation"] = {
    set_back = function()
    end,
    clear_back = function()
    end,
}

local sync_ui = require("jellyfin_sync_ui")
local page =
    sync_ui.Catalog:new {
        title = "Tracks",
        view = "tracks",
    }

backstack.reset(page)
backstack.flush(8)

local icon_row = assert(page.result_models[1])
local plain_row = assert(page.result_models[2])

assert(
    icon_row.state_icon ~= nil,
    "server-only Sync row missing trailing icon"
)
assert(
    plain_row.state_icon == nil,
    "available Sync row unexpectedly gained a trailing icon"
)

local icon_left = 139
local title_coords =
    icon_row.title.view:get_coords()
local detail_coords =
    icon_row.detail.view:get_coords()

assert(
    title_coords.x2 < icon_left and
        detail_coords.x2 < icon_left,
    "Sync title/detail entered the trailing-icon gutter"
)

assert(
    icon_row.title.width <= 111 and
        icon_row.detail.width <= 111,
    "icon Sync row did not reserve the trailing text gutter"
)

assert(
    plain_row.title.width >= 127 and
        plain_row.detail.width >= 127,
    "icon-less Sync row was shortened unnecessarily"
)

-- Recycle a downloading style onto the plain row, then restore availability.
icon_row:update_sync_catalog_item({
    jellyfin_id = "track-long-1",
    kind = "track",
    title = track_icon.title,
    artist = track_icon.artist,
    album = track_icon.album,
    device = {state = "server_only"},
})
plain_row:update_sync_catalog_item({
    key = "opaque-external-1",
    kind = "track",
    title = "Was Downloading",
    artist = "Artist",
    album = "Album",
})

-- Force queued styling through runtime item_state mock.
package.loaded["sync_runtime"].item_state =
    function(item)
        if item.key ==
                "opaque-external-1" or
            item.jellyfin_id ==
                "track-plain-1" then
            return "queued"
        end
        return nil
    end

plain_row:update_sync_catalog_item({
    jellyfin_id = "track-plain-1",
    key = "opaque-external-1",
    kind = "track",
    title = "Was Downloading",
    artist = "Artist",
    album = "Album",
    device = {state = "queued"},
})

assert(
    plain_row.state == "queued" and
        plain_row.state_icon and
        not plain_row.detail.text:find(
            "Queued",
            1,
            true
        ) and
        plain_row.detail.text:find(
            "Artist",
            1,
            true
        ),
    "queued recycle styling was not applied without detail status text"
)

package.loaded["sync_runtime"].item_state =
    function()
        return nil
    end

plain_row:update_sync_catalog_item(
    track_plain
)

assert(
    plain_row.state_icon == nil and
        plain_row.title.width >= 127,
    "virtual-list recycle retained prior download styling"
)

print(
    "Sync trailing-icon text gutter and recycle passed"
)
os.exit(0)

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

local root =
    "/tmp/tangara-sync-virtual-sort"
os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

package.loaded["device"] = {
    storage_root = function()
        return root
    end,
}
package.loaded["jellyfin_local_index"] = {
    load = function()
        return {
            tracks = {},
            albums = {},
        }
    end,
}

local payload = {
    generation = 1,
    total = 80,
    total_count = 80,
    next_cursor = "title-page-2",
    sort = "title",
    direction = "ascending",
    items = {},
}

for index = 1, 50 do
    payload.items[index] = {
        jellyfin_id =
            string.format(
                "album-%03d",
                index
            ),
        kind = "album",
        title =
            string.format(
                "Album %03d",
                index
            ),
        artist = "Artist",
        date_created =
            string.format(
                "2026-01-%02dT00:00:00Z",
                (index - 1) % 28 + 1
            ),
        device = {
            state = "server_only",
            total_tracks = 1,
            downloaded_tracks = 0,
        },
    }
end

local request = nil
package.loaded["sync_catalog"] = {
    cached = function(view)
        if view == "albums" then
            return payload
        end
        return nil
    end,
    start = function(
        view,
        cursor,
        limit,
        options
    )
        request = {
            view = view,
            cursor = cursor,
            limit = limit,
            sort = options.sort,
            direction = options.direction,
            generation =
                options.generation,
        }
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
}
package.loaded["sync_artwork_cache"] = {
    key = function(item)
        return tostring(
            item.artwork_revision or
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

for _, module_name in ipairs({
    "sync_sort",
    "jellyfin_sync_ui",
}) do
    package.loaded[module_name] = nil
end

local sync_ui =
    require("jellyfin_sync_ui")
local albums =
    sync_ui.Catalog:new {
        title = "Albums",
        view = "albums",
    }

backstack.reset(albums)
backstack.flush(8)

local old_controller =
    albums.virtual_list_controller
local old_first_object =
    albums.result_models[1].object

albums.open_sort_menu()
albums.focus_group:focus_next()
albums.close_sort_menu(false)

assert(request)
assert(request.view == "albums")
assert(request.cursor == nil)
assert(request.limit == 50)
assert(request.sort == "date_added")
assert(request.direction == "descending")
assert(request.generation == 2)
assert(
    albums.virtual_list_controller ==
        old_controller,
    "Sort destroyed the live virtual list before the replacement page arrived"
)
assert(
    albums.result_models[1].object ==
        old_first_object,
    "Sort rebuilt LVGL rows inside the Sort activation callback"
)
assert(
    albums.items[1].date_created >=
        albums.items[2].date_created,
    "Sort did not preview the newly selected order on the live rows"
)

local reversed = {}
for index = 50, 1, -1 do
    reversed[#reversed + 1] =
        payload.items[index]
end
payload = {
    generation = 2,
    total = 80,
    total_count = 80,
    next_cursor = "date-page-2",
    sort = "date_added",
    direction = "descending",
    items = reversed,
}

albums:render()
backstack.flush(4)

assert(
    albums.items[1].jellyfin_id ==
        "album-050",
    "completed Sort response did not replace the catalog order"
)
assert(
    albums.virtual_list_controller ~= nil and
        albums.virtual_list_controller:
            pool_count() == 7,
    "completed Sort response did not restore the seven-row virtual list"
)

os.execute("rm -rf " .. root)
print(
    "Sync virtual Sort keeps live rows until the replacement page arrives"
)
os.exit(0)

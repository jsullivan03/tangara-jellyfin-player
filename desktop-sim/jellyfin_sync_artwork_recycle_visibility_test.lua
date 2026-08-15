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
    "/tmp/tangara-sync-artwork-visibility"
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
    total = 50,
    total_count = 50,
    next_cursor = nil,
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
        artwork_revision =
            string.format(
                "revision-%03d",
                index
            ),
        artwork_path =
            string.format(
                "/artwork/%03d",
                index
            ),
        device = {
            state = "server_only",
            total_tracks = 1,
            downloaded_tracks = 0,
        },
    }
end

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
    poll = function()
        return nil
    end,
}

local callbacks = {}
package.loaded["sync_artwork_cache"] = {
    key = function(item)
        return tostring(
            item.artwork_revision or
            item.jellyfin_id or ""
        )
    end,
    request = function(item, callback)
        local subscription = {
            cancelled = false,
        }
        callbacks[#callbacks + 1] = {
            key = tostring(
                item.artwork_revision or
                item.jellyfin_id or ""
            ),
            callback = callback,
            subscription = subscription,
        }
        return nil, subscription
    end,
    cancel = function(subscription)
        subscription.cancelled = true
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
local albums =
    sync_ui.Catalog:new {
        title = "Albums",
        view = "albums",
    }

backstack.reset(albums)
backstack.flush(8)

local controller =
    assert(albums.virtual_list_controller)
local recycled = controller.pool[1]
local recycled_object = recycled.object

assert(
    recycled.catalog_item.jellyfin_id ==
        "album-001"
)
assert(
    recycled.artwork.placeholder_visible ==
        true,
    "initial unresolved artwork did not show the placeholder surface"
)

callbacks[1].callback(
    "/tmp/album-001.png",
    callbacks[1].key
)
assert(
    recycled.artwork.current_source ==
        "/tmp/album-001.png"
)
assert(
    recycled.artwork.placeholder_visible ==
        false,
    "resolved artwork remained hidden"
)

controller:focus_index(8)
backstack.flush(4)

assert(
    controller.pool[1] == recycled and
        recycled.object ==
            recycled_object,
    "virtual navigation did not reuse the first LVGL row"
)
assert(
    recycled.catalog_item.jellyfin_id ~=
        "album-001",
    "test did not recycle the row onto a different album"
)
assert(
    recycled.artwork.current_source ==
        "//lua/img/cover_placeholder.png",
    "recycled row retained the previous album source while the new cover was pending"
)
assert(
    recycled.artwork.placeholder_visible ==
        true,
    "recycled row left the previous decoded album visible"
)

local recycled_revision =
    tostring(
        recycled.catalog_item
            .artwork_revision or ""
    )
local recycled_path =
    "/tmp/" ..
    tostring(
        recycled.catalog_item
            .jellyfin_id or
            "recycled"
    ) .. ".png"

local current_callback = nil
for index = #callbacks, 1, -1 do
    if callbacks[index].key ==
            recycled_revision and
        not callbacks[index]
            .subscription.cancelled then
        current_callback =
            callbacks[index]
        break
    end
end
assert(current_callback)

current_callback.callback(
    recycled_path,
    current_callback.key
)
assert(
    recycled.artwork.current_source ==
        recycled_path
)
assert(
    recycled.artwork.placeholder_visible ==
        false,
    "current recycled-row artwork did not replace the placeholder"
)

os.execute("rm -rf " .. root)
print(
    "Sync recycled rows hide obsolete covers until the current artwork resolves"
)
os.exit(0)

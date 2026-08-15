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
package.preload["backstack"] =
    function()
        return backstack
    end

local callbacks = {}
local payload = {
    items = {
        {
            jellyfin_id = "album-async",
            kind = "album",
            title = "非同期",
            artist = "音楽家",
            track_count = 2,
            device = {
                state = "server_only",
            },
        },
    },
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {
            tracks = {},
            albums = {},
        }
    end,
}

package.loaded["sync_artwork_cache"] = {
    key = function(item)
        return tostring(
            item.jellyfin_id or
            item.key or ""
        )
    end,
    request = function(item, callback)
        table.insert(
            callbacks,
            {
                key = tostring(
                    item.jellyfin_id or
                    item.key or ""
                ),
                callback = callback,
            }
        )
    end,
    poll = function()
        return nil
    end,
}

package.loaded["sync_catalog"] = {
    cached = function(view)
        if view == "albums" then
            return payload
        end
        return nil
    end,
    cached_key = function()
        return nil
    end,
    error = function()
        return nil
    end,
    busy = function()
        return false
    end,
    start = function()
        return true
    end,
    poll = function()
        return nil
    end,
    queue = function()
        return true
    end,
    local_artist_releases = function()
        return nil
    end,
}

package.loaded["jellyfin_sync_ui"] = nil
local sync_ui =
    require("jellyfin_sync_ui")

local albums =
    sync_ui.Catalog:new {
        title = "Albums",
        view = "albums",
    }

backstack.reset(albums)
backstack.flush(8)

assert(#callbacks == 1)
local stale_row = albums.rows[2]
local stale_source =
    stale_row.artwork.current_source

albums:render()
backstack.flush(4)

assert(
    #callbacks == 2,
    "expected two artwork requests, got " ..
    tostring(#callbacks)
)
local current_row = albums.rows[2]
assert(current_row ~= stale_row)
assert(not stale_row.artwork:is_valid())

callbacks[1].callback(
    "/desktop-sim/stale.png",
    callbacks[1].key
)

assert(
    stale_row.artwork.current_source ==
        stale_source,
    "destroyed row accepted a stale artwork completion"
)
assert(
    current_row.artwork.current_source ~=
        "/desktop-sim/stale.png",
    "stale completion was assigned to the recycled row"
)

local current_object = current_row.object
local current_image =
    current_row.artwork.image
local focused_before =
    lvgl.group.get_default():get_focused()

callbacks[2].callback(
    "/desktop-sim/current.png",
    callbacks[2].key
)

assert(
    albums.rows[2].object ==
        current_object,
    "valid artwork completion rebuilt the list row"
)
assert(
    current_row.artwork.image ==
        current_image,
    "valid artwork completion recreated the image object"
)
assert(
    current_row.artwork.current_source ==
        "/desktop-sim/current.png",
    "valid artwork did not appear immediately"
)
assert(
    lvgl.group.get_default():
        get_focused() ==
        focused_before,
    "artwork completion moved list focus"
)

print(
    "Sync artwork discards destroyed rows and updates live images in place"
)
os.exit(0)

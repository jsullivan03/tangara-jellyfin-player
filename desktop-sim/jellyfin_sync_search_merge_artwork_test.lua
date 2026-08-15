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
            key =
                "0123456789abcdef" ..
                "0123456789abcdef",
            kind = "album",
            title = "ASTROWORLD",
            artist = "Travis Scott",
            artists = {
                "Travis Scott",
            },
            year = 2018,
            artwork_path =
                "/external/astroworld",
            artwork_revision =
                "external-revision",
            artwork_source =
                "external",
            availability = "available",
        },
    },
    external_search_pending = true,
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
        return table.concat(
            {
                tostring(
                    item.jellyfin_id or
                    item.key or ""
                ),
                tostring(
                    item.artwork_revision or
                    ""
                ),
                tostring(
                    item.artwork_path or ""
                ),
            },
            ":"
        )
    end,
    request = function(item, callback)
        if type(item.artwork_path) ~=
                "string" or
            item.artwork_path == "" then
            return nil
        end
        callbacks[#callbacks + 1] = {
            key =
                table.concat(
                    {
                        tostring(
                            item.jellyfin_id or
                            item.key or ""
                        ),
                        tostring(
                            item.artwork_revision or
                            ""
                        ),
                        tostring(
                            item.artwork_path or
                            ""
                        ),
                    },
                    ":"
                ),
            path = item.artwork_path,
            callback = callback,
        }
        return nil
    end,
    poll = function()
        return nil
    end,
}

package.loaded["sync_catalog"] = {
    cached_key = function(key)
        if key ==
            "search:Travis Scott" then
            return payload
        end
        return nil
    end,
    cached = function()
        return nil
    end,
    error = function()
        return nil
    end,
    busy = function()
        return false
    end,
    queue = function()
        return true
    end,
    external_job = function()
        return true
    end,
    local_artist_releases = function()
        return nil
    end,
}

package.loaded["jellyfin_sync_ui"] = nil
local sync_ui =
    require("jellyfin_sync_ui")

local results =
    sync_ui.Results:new {
        query = "Travis Scott",
    }

backstack.reset(results)
backstack.flush(8)

assert(#callbacks == 1)
assert(#results.result_models == 1)
local row = results.result_models[1]
local row_object = row.object
local image_object = row.artwork.image
backstack.focus(row.object)
local focused_before =
    lvgl.group.get_default():get_focused()

callbacks[1].callback(
    "/desktop-sim/astroworld-external.png",
    callbacks[1].key
)
assert(
    row.artwork.current_source ==
        "/desktop-sim/astroworld-external.png",
    "external artwork did not appear before canonical merge"
)

payload = {
    items = {
        {
            jellyfin_id =
                "jellyfin-astroworld",
            kind = "album",
            title = "ASTROWORLD",
            artist = "Cactus Jack",
            artists = {
                "Cactus Jack",
                "Travis Scott",
            },
            year = 2018,
            track_count = 17,
            artwork_path =
                "/jellyfin/astroworld",
            artwork_revision =
                "jellyfin-revision",
            artwork_source =
                "jellyfin",
            device = {
                state = "server_only",
            },
        },
    },
    external_available = true,
    external_search_pending = false,
}

results:render(false)

assert(#results.result_models == 1)
assert(
    results.result_models[1] == row,
    "late canonical merge replaced the logical row model: " ..
    tostring(results.result_models[1]) ..
    " ~= " .. tostring(row)
)
assert(
    row.object == row_object,
    "late canonical merge rebuilt the visible row"
)
assert(
    row.artwork.image == image_object,
    "late canonical merge recreated the artwork image"
)
assert(
    row.catalog_item.jellyfin_id ==
        "jellyfin-astroworld"
)
assert(row.state == "server_only")
assert(
    row.state_icon and
        row.state_icon.kind == "server",
    "availability overlay did not add the On server icon"
)
assert(#callbacks == 2)
assert(
    callbacks[2].path ==
        "/jellyfin/astroworld",
    "canonical merge did not request Jellyfin artwork"
)
assert(
    lvgl.group.get_default():
        get_focused() ==
        focused_before,
    "availability update moved focus"
)

local source_after_merge =
    row.artwork.current_source
callbacks[1].callback(
    "/desktop-sim/stale-external.png",
    callbacks[1].key
)
assert(
    row.artwork.current_source ==
        source_after_merge,
    "late external artwork replaced canonical Jellyfin artwork"
)

callbacks[2].callback(
    "/desktop-sim/astroworld-jellyfin.png",
    callbacks[2].key
)
assert(
    row.artwork.current_source ==
        "/desktop-sim/astroworld-jellyfin.png",
    "Jellyfin artwork did not update the existing image in place"
)
assert(
    lvgl.group.get_default():
        get_focused() ==
        focused_before,
    "canonical artwork completion moved focus"
)

payload = {
    items = {
        {
            jellyfin_id =
                "jellyfin-astroworld",
            kind = "album",
            title = "ASTROWORLD",
            artist = "Cactus Jack",
            artists = {
                "Cactus Jack",
                "Travis Scott",
            },
            year = 2018,
            track_count = 17,
            artwork_path = "",
            artwork_revision = "",
            artwork_source =
                "jellyfin",
            device = {
                state = "server_only",
            },
        },
    },
    external_available = true,
}
results:render(false)
assert(#callbacks == 2)
assert(
    row.artwork.current_source ==
        "//lua/img/cover_placeholder.png",
    "missing canonical artwork did not retain the semantic placeholder"
)

print(
    "Sync Search upgrades ASTROWORLD in place with canonical state and artwork"
)
os.exit(0)

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
    "/tmp/tangara-sync-shared-album-artwork"
local artwork_directory =
    root .. "/.tangara-artwork/sync"
os.execute(
    "mkdir -p " .. artwork_directory
)

local album_id =
    "0a23585b1772b09d412c20bc2ccbdbcb"
local album_revision =
    "8fdd89a3625108fe8e8ae2e7cab1a3bd"
local album_key =
    "sq28-v3:jellyfin:" ..
    album_revision
local album_file =
    artwork_directory ..
    "/sq28-v3_jellyfin_" ..
    album_revision ..
    "-sq28.png"

os.remove(album_file)

local pending = false
local next_result = nil
local starts = 0

package.loaded["device"] = {
    storage_root = function()
        return root
    end,
}
package.loaded["filesystem"] = {
    chkdir = function()
        return true
    end,
    mkdir = function()
        return true
    end,
}
package.loaded["sync_client"] = {
    url = function(path)
        return "http://companion" .. path
    end,
}
package.loaded["download"] = {
    busy = function()
        return pending
    end,
    start = function()
        starts = starts + 1
        pending = true
        return true
    end,
    poll = function()
        local result = next_result
        next_result = nil
        if result then
            pending = false
        end
        return result
    end,
}

package.loaded["sync_artwork_cache"] = nil
local artwork_cache =
    require("sync_artwork_cache")

-- Preserve a real negative entry for the old track-specific identity.
artwork_cache.request {
    jellyfin_id =
        "84e29df07ee50bcc8261a111337dcf59",
    artwork_path = "/old-track-artwork",
    artwork_source = "jellyfin",
}
next_result = {ok = false}
assert(not artwork_cache.poll().ok)

-- Also prove an existing on-device parent file overrides a prior failure for
-- that exact album-level key instead of remaining trapped behind the negative
-- cache entry.
artwork_cache.request {
    jellyfin_id = album_id,
    artwork_path = "/parent-artwork",
    artwork_revision = album_revision,
    artwork_source = "jellyfin",
}
next_result = {ok = false}
assert(not artwork_cache.poll().ok)

local file = assert(io.open(album_file, "wb"))
file:write("existing album artwork")
file:close()

local function track(id, title)
    return {
        jellyfin_id = id,
        kind = "track",
        title = title,
        artist = "Vegyn",
        album =
            "The Road To Hell Is Paved With Good Intentions",
        album_id = album_id,
        image_tags = {},
        artwork_owner_id = album_id,
        artwork_revision = album_revision,
        artwork_source = "jellyfin",
        artwork_path =
            "/devices/tangara-sim-001/items/" ..
            album_id ..
            "/artwork/thumbnail?revision=" ..
            album_revision,
        device = {
            state = "server_only",
        },
    }
end

local payload = {
    generation = 1,
    total = 3,
    total_count = 3,
    sort = "title",
    direction = "ascending",
    items = {
        track(
            "10fe2d872bcfebdfa7e84ebbea4eccc6",
            "Another 9 Days"
        ),
        track(
            "003fb0e8284afcfddae333333026317f",
            "Halo Flip"
        ),
        track(
            "84e29df07ee50bcc8261a111337dcf59",
            "Turn Me Inside"
        ),
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
package.loaded["sync_catalog"] = {
    cached = function(view)
        return view == "tracks" and
            payload or nil
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

assert(#tracks.result_models == 3)
local display_path = album_file

for index, model in ipairs(
    tracks.result_models
) do
    assert(
        model.catalog_item.artwork_owner_id ==
            album_id
    )
    assert(
        artwork_cache.key(
            model.catalog_item
        ) == album_key
    )
    assert(
        model.artwork.current_source ==
            display_path,
        model.catalog_item.title ..
            " did not immediately reuse the existing album cover"
    )
    assert(
        model.artwork.placeholder_visible ==
            false
    )
    assert(
        model.sync_artwork_generation >= 1
    )
    assert(
        model.sync_artwork_stable_id ==
            model.catalog_item.jellyfin_id
    )
    assert(
        model.sync_artwork_subscription == nil
    )

    print(table.concat({
        model.catalog_item.title,
        "track=" ..
            model.catalog_item.jellyfin_id,
        "album=" .. album_id,
        "key=" .. album_key,
        "path=" .. display_path,
        "generation=" ..
            tostring(
                model.sync_artwork_generation
            ),
        "binding=" ..
            model.sync_artwork_stable_id,
    }, " | "))
end

assert(
    starts == 2,
    "visible sibling rows fetched artwork despite the shared on-device file"
)

print(
    "Sync sibling tracks reuse one parent-album artwork file before scrolling"
)
os.exit(0)

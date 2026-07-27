package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
local metrics = require("sim_metrics")
local backstack = require("firmware_backstack")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

package.loaded["backstack"] = backstack
package.preload["backstack"] = function()
    return backstack
end

local root =
    "/tmp/tangara-local-library-virtualized-albums"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

package.loaded["device"] = nil
package.preload["device"] = function()
    return {
        id = function()
            return "virtual-album-benchmark"
        end,
        storage_root = function()
            return root
        end,
    }
end

package.loaded["sync_config"] = {
    status = function()
        return {
            configured = true,
            started = true,
            connected = true,
            server_url = "http://localhost",
        }
    end,
}

package.loaded["sync_runtime"] = {
    last_library_result = function()
        return {ok = true}
    end,
    last_result = function()
        return {ok = true}
    end,
}

package.loaded["sync_library_view"] = {
    current = function()
        return {
            favorites = {
                name = "Favorites",
                items = {},
            },
            playlists = {},
        }
    end,
}

package.loaded["jellyfin_playback"] = {
    play = function()
        return true
    end,
    current = function()
        return nil
    end,
}

package.loaded["jellyfin_now_playing"] = {
    new = function()
        return {}
    end,
}

package.loaded["jellyfin_track_menu"] = {
    new = function()
        return {}
    end,
}

local function positive_integer(value, name)
    local number = tonumber(value)

    assert(
        number and
            number >= 1 and
            number == math.floor(number),
        name .. " must be a positive integer"
    )

    return number
end

local album_count =
    positive_integer(
        os.getenv(
            "TANGARA_VIRTUAL_ALBUMS"
        ) or "100",
        "TANGARA_VIRTUAL_ALBUMS"
    )

local function make_library(count)
    local albums = {}

    for index = 1, count do
        local id =
            string.format(
                "album-%05d",
                index
            )

        albums[index] = {
            key = id,
            id = id,
            name = string.format(
                "Album %05d",
                index
            ),
            artist = string.format(
                "Artist %04d",
                ((index - 1) % 250) + 1
            ),
            track_count =
                ((index - 1) % 24) + 1,
            tracks = {},
            date_created = string.format(
                "2026-%02d-%02dT00:00:00Z",
                ((index - 1) % 12) + 1,
                ((index - 1) % 28) + 1
            ),
            artwork = {
                thumbnail =
                    "//lua/img/playlist_placeholder.png",
            },
        }
    end

    return {
        artists = {},
        albums = albums,
        tracks = {},
        counts = {
            artists = 0,
            albums = count,
            tracks = 0,
        },
    }
end

local current_library = nil

package.loaded["jellyfin_local_index"] = {
    load = function()
        return current_library
    end,
}

for _, module_name in ipairs({
    "jellyfin_sort",
    "jellyfin_marquee",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_virtual_track_list",
    "jellyfin_local_library",
}) do
    package.loaded[module_name] = nil
end

local local_library_module =
    dofile(
        "lua/jellyfin_local_library.lua"
    )

package.loaded["jellyfin_local_library"] =
    local_library_module

local blank = {
    create_ui = function()
    end,
    on_show = function()
    end,
    on_hide = function()
    end,
}

backstack.reset(blank)
backstack.flush(6)
collectgarbage("collect")
collectgarbage("collect")

local empty = metrics.snapshot()

current_library =
    make_library(album_count)
collectgarbage("collect")

local data = metrics.snapshot()
local started = metrics.now_us()
local screen =
    local_library_module.Albums:new()

backstack.reset(screen)
backstack.flush(10)

local create_ms =
    (metrics.now_us() - started) / 1000

collectgarbage("collect")

local loaded = metrics.snapshot()
local object_delta =
    loaded.active_objects -
    data.active_objects
local timer_delta =
    loaded.timers -
    data.timers
local lua_ui_delta =
    loaded.lua_kb -
    data.lua_kb
local rss_ui_delta =
    loaded.rss_kb -
    data.rss_kb

local virtual =
    assert(screen.virtual_album_list)

local pool_rows =
    virtual:pool_count()

assert(
    virtual:logical_count() ==
        album_count
)
assert(pool_rows <= 7)
assert(
    #(screen.media_rows or {}) ==
        pool_rows
)
assert(object_delta < 120)
assert(lua_ui_delta > 0)
assert(timer_delta >= 0)

local output_path =
    os.getenv(
        "TANGARA_VIRTUAL_ALBUM_OUTPUT"
    )

if output_path and output_path ~= "" then
    local output =
        assert(io.open(output_path, "a"))

    output:write(string.format(
        "%d,%.3f,%d,%d,%d,%d,%d,%d,%.3f,%.3f,%.3f,%.3f,%d,%d,%d,%d,%d\n",
        album_count,
        create_ms,
        pool_rows,
        empty.active_objects,
        data.active_objects,
        loaded.active_objects,
        object_delta,
        loaded.timers,
        empty.lua_kb,
        data.lua_kb,
        loaded.lua_kb,
        lua_ui_delta,
        empty.rss_kb,
        data.rss_kb,
        loaded.rss_kb,
        rss_ui_delta,
        loaded.max_rss_kb
    ))

    output:close()
end

print(string.format(
    "VIRTUAL albums=%d create_ms=%.3f pool_rows=%d objects=%d object_delta=%d timers=%d lua_ui_kb=%.1f rss_ui_kb=%d max_rss_kb=%d",
    album_count,
    create_ms,
    pool_rows,
    loaded.active_objects,
    object_delta,
    loaded.timers,
    lua_ui_delta,
    rss_ui_delta,
    loaded.max_rss_kb
))

os.execute("rm -rf " .. root)
os.exit(0)

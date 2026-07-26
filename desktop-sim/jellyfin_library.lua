if _G.jellyfin_library_ui_started then
    return
end

_G.jellyfin_library_ui_started = true

package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

local network =
    dofile("desktop-sim/network.lua")

local server_url =
    os.getenv("TANGARA_SIM_SERVER_URL")

local device_id =
    os.getenv("TANGARA_SIM_DEVICE_ID")
    or "tangara-sim-001"

if type(server_url) ~= "string" or
    server_url == "" then
    error(
        "TANGARA_SIM_SERVER_URL is required"
    )
end

local root =
    "desktop-sim/sd/jellyfin-library-ui-clean"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

local simulator =
    require("mocks").install(lvgl)

package.loaded["backstack"] =
    simulator.backstack

package.loaded["http"] = nil
package.preload["http"] = function()
    return network.http
end

package.loaded["device"] = nil
package.preload["device"] = function()
    return {
        id = function()
            return device_id
        end,
        storage_root = function()
            return root
        end,
    }
end

package.loaded["sync_config"] = nil
package.preload["sync_config"] = function()
    return {
        load = function()
            return {
                ssid = "desktop-sim",
                password = "",
                server_url = server_url,
            }
        end,
        valid = function(config)
            if type(config.server_url)
                ~= "string" or
                config.server_url == "" then
                return false,
                    "sync server URL is required"
            end

            return true
        end,
        save = function()
            return true
        end,
        reload_wifi = function()
            return true
        end,
        status = function()
            return {
                configured = true,
                started = true,
                connected = false,
                ssid = "desktop-sim",
                server_url = server_url,
            }
        end,
    }
end

local function ticks()
    local process =
        assert(io.popen("date +%s%3N"))

    local value =
        tonumber((process:read("*l")))

    process:close()

    return assert(value)
end

local refresh =
    require("sync_library_refresh")

local started, start_error =
    refresh.start()

assert(started, start_error)

local deadline = ticks() + 120000
local result = nil

while ticks() < deadline do
    result = refresh.poll()

    if result then
        break
    end

    os.execute("sleep 0.05")
end

assert(result, "library refresh timed out")
assert(result.ok, result.error)

local json_encode =
    require("json_encode")
local manifest_cache =
    require("sync_manifest_cache")
local manifest = {
    device = {
        id = device_id,
    },
    items = {},
}
local seen = {}
local counter = 0

local function add_track(track)
    if seen[track.id] then
        return
    end

    seen[track.id] = true
    counter = counter + 1

    local local_path =
        "/sim-media/" ..
        tostring(counter) ..
        ".flac"

    os.execute(
        "mkdir -p " ..
        root ..
        "/sim-media"
    )

    local file =
        assert(
            io.open(
                root .. local_path,
                "wb"
            )
        )

    file:write("simulator")
    file:close()

    table.insert(
        manifest.items,
        {
            id = track.id,
            jellyfin_id = track.id,
            title = track.title,
            artist = track.artist,
            album = track.album,
            duration =
                track.duration or 240,
            local_path = local_path,
            sync_state = "ready",
            pinned = true,
            artwork = {
                cover =
                    "//lua/img/cover_placeholder.png",
                background =
                    "//lua/img/background_placeholder.png",
            },
        }
    )
end

for _, track in ipairs(
    result.library.favorites.items or {}
) do
    add_track(track)
end

for _, playlist in ipairs(
    result.library.playlists or {}
) do
    for _, track in ipairs(
        playlist.items or {}
    ) do
        add_track(track)
    end
end

assert(
    manifest_cache.save(
        json_encode.encode(manifest)
    )
)

print(
    "Jellyfin UI ready: playlists=" ..
    tostring(#result.library.playlists) ..
    " favorites=" ..
    tostring(#result.library.favorites.items) ..
    " playable_tracks=" ..
    tostring(#manifest.items)
)

local ok, message =
    pcall(dofile, "lua/main.lua")

if not ok then
    error(
        "Failed to load Tangara UI:\n" ..
        tostring(message)
    )
end

local library_screen =
    dofile("lua/jellyfin_library.lua")

package.loaded["jellyfin_library"] =
    library_screen

simulator.backstack.push(
    library_screen:new()
)


package.path =
    "lua/?.lua;" ..
    "desktop-sim/?.lua;" ..
    package.path

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
    "desktop-sim/sd/library-live-test"

os.execute("mkdir -p " .. root)

package.preload["http"] = function()
    return network.http
end

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
    }
end

local function ticks()
    local process =
        assert(io.popen("date +%s%3N"))

    local value =
        tonumber(process:read("*l"))

    process:close()

    return assert(value)
end

local cache =
    require("sync_library_cache")
local refresh =
    require("sync_library_refresh")
local view =
    require("sync_library_view")

local function clean()
    local paths = assert(cache.paths())

    os.remove(paths.path)
    os.remove(paths.temporary)
    os.remove(paths.backup)

    local queue =
        require("sync_operation_queue")
    paths = assert(queue.paths())

    os.remove(paths.path)
    os.remove(paths.temporary)
    os.remove(paths.backup)
end

clean()

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

    os.execute("sleep 0.1")
end

assert(result, "library refresh timed out")
assert(result.ok, result.error)
assert(type(result.library.user.name) ==
    "string")
assert(type(result.library.playlists) ==
    "table")
assert(type(result.library.favorites.items) ==
    "table")

local playlist_tracks = 0

for _, playlist in ipairs(
    result.library.playlists
) do
    assert(#playlist.items ==
        playlist.track_count)

    playlist_tracks =
        playlist_tracks +
        #playlist.items
end

assert(#result.library.favorites.items ==
    result.library.favorites.track_count)

local cached = assert(cache.load())
local current = assert(view.current())

assert(cached.revision ==
    result.library.revision)
assert(current.revision ==
    result.library.revision)

print(
    "live Jellyfin library cache passed"
)
print(
    "playlists=" ..
    tostring(#cached.playlists) ..
    " playlist_tracks=" ..
    tostring(playlist_tracks) ..
    " favorites=" ..
    tostring(#cached.favorites.items)
)

clean()

os.exit(0)

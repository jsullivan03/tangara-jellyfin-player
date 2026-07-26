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
    "desktop-sim/sd/operation-live-test"

os.execute(
    "mkdir -p " .. root
)

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

local queue =
    require("sync_operation_queue")

local flush =
    require("sync_operation_flush")

local function clean()
    local paths = assert(queue.paths())

    os.remove(paths.path)
    os.remove(paths.temporary)
    os.remove(paths.backup)
end

clean()

local name =
    "Tangara Offline Queue Test " ..
    tostring(ticks())

local local_id = assert(
    queue.enqueue_create_playlist(name)
)

assert(
    queue.enqueue_rename_playlist(
        local_id,
        name .. " Renamed"
    )
)

assert(
    queue.enqueue_delete_playlist(
        local_id
    )
)

local started, start_error =
    flush.start(25)

assert(started, start_error)

local deadline = ticks() + 60000
local result = nil

while ticks() < deadline do
    result = flush.poll()

    if result then
        break
    end

    os.execute("sleep 0.1")
end

assert(result, "operation upload timed out")
assert(result.ok, result.error)
assert(result.applied == 3)
assert(result.pending == 0)

local status = queue.status()

assert(status.pending == 0)
assert(status.blocked == false)

clean()

print(
    "live offline operation upload passed"
)

os.exit(0)

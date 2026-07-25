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

package.preload["http"] = function()
    return network.http
end

package.preload["device"] = function()
    return {
        id = function()
            return device_id
        end,
    }
end

package.preload["sync_config"] = function()
    return {
        load = function()
            return {
                wifi_ssid = "desktop-sim",
                wifi_password = "",
                server_url = server_url,
            }
        end,
        valid = function(config)
            if type(config.server_url) ~= "string" or
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

package.preload["time"] = function()
    return {
        ticks = ticks,
    }
end

local sync_link = require("sync_link")

local started, start_error =
    sync_link.start(true)

assert(started, start_error)

local deadline = ticks() + 180000
local shown_code = nil
local last_phase = nil

while ticks() < deadline do
    local event, poll_error =
        sync_link.poll()

    assert(
        poll_error == nil,
        poll_error
    )

    local state =
        event or sync_link.state()

    if state.phase ~= last_phase then
        print("phase=" .. state.phase)
        last_phase = state.phase
    end

    if state.code and state.code ~= shown_code then
        shown_code = state.code

        print()
        print("==============================")
        print(
            "QUICK CONNECT CODE: " ..
            state.code
        )
        print("==============================")
        print()
        print(
            "Approve this code in Jellyfin."
        )
    end

    if state.linked then
        assert(type(state.user) == "table")
        assert(type(state.user.id) == "string")
        assert(type(state.user.name) == "string")

        print(
            "linked_user=" ..
            state.user.name
        )
        print(
            "Lua Quick Connect controller passed"
        )

        os.exit(0)
    end

    if state.phase == "error" then
        error(state.error or "linking failed")
    end

    os.execute("sleep 0.25")
end

error("Quick Connect controller timed out")

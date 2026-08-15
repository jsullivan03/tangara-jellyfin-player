package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

dofile("desktop-sim/jellyfin_library.lua")

local volume = require("volume")
local backstack = require("backstack")
local jellyfin_home = require("jellyfin_home")

local function flush()
    backstack.flush(8)
end

local home = jellyfin_home.Home:new()
backstack.reset(home)
flush()

assert(
    type(_G.tangara_sim_transport_event) ==
        "function",
    "global simulator volume transport missing"
)

if type(_G.tangara_sim_set_transport_mode) ==
        "function" then
    _G.tangara_sim_set_transport_mode(false)
end

volume.current_pct:set(40)
assert(
    _G.tangara_sim_transport_event(
        "volume_up",
        1
    ) == true
)
assert(
    tonumber(volume.current_pct:get()) == 45,
    "global volume_up failed on Home"
)

assert(
    _G.tangara_sim_transport_event(
        "volume_down",
        2
    ) == true
)
assert(
    tonumber(volume.current_pct:get()) == 35,
    "global volume_down failed on Home"
)

-- Simulate Now Playing temporarily owning the transport sink, then restoring
-- the persistent global volume handler on hide.
local global_handler =
    _G.tangara_sim_transport_event

if type(_G.tangara_sim_set_transport_mode) ==
        "function" then
    _G.tangara_sim_set_transport_mode(true)
end

_G.tangara_sim_transport_event =
    function(action, amount)
        if action == "volume_up" or
            action == "volume_down" then
            return global_handler(
                action,
                amount
            )
        end

        return true
    end

volume.current_pct:set(60)
assert(
    _G.tangara_sim_transport_event(
        "volume_up",
        1
    ) == true
)
assert(
    tonumber(volume.current_pct:get()) == 65,
    "volume failed while Now Playing owned transport"
)

if type(_G.tangara_sim_set_transport_mode) ==
        "function" then
    _G.tangara_sim_set_transport_mode(false)
end

_G.tangara_sim_transport_event =
    global_handler

volume.current_pct:set(50)
assert(
    _G.tangara_sim_transport_event(
        "volume_up",
        1
    ) == true
)
assert(
    tonumber(volume.current_pct:get()) == 55,
    "global volume failed after closing Now Playing"
)

print(
    "Global volume outside Now Playing passed"
)
os.exit(0)

package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

local fired = 0
local target = 160
local keepalive = {}

local function spawn_one_shot(index)
    lvgl.Timer {
        period = 1,
        repeat_count = 1,
        cb = function(completed)
            fired = fired + 1

            -- Keep some completed userdata reachable and let the rest become
            -- collectible. Native timer addresses are deliberately reused.
            if index % 11 == 0 then
                keepalive[#keepalive + 1] = completed
            end

            if index < target then
                spawn_one_shot(index + 1)
            end

            if index % 5 == 0 then
                collectgarbage("collect")
            end
        end,
    }
end

-- Explicit deletion must also be safe more than once.
local deleted = lvgl.Timer {
    paused = true,
    period = 1000,
    cb = function() end,
}

deleted:delete()
deleted:delete()
deleted = nil
collectgarbage("collect")

spawn_one_shot(1)

local verifier
verifier = lvgl.Timer {
    period = 5,
    cb = function()
        collectgarbage("collect")

        if fired < target then
            return
        end

        for _, completed in ipairs(keepalive) do
            completed:delete()
            completed:delete()
        end

        keepalive = {}
        collectgarbage("collect")
        collectgarbage("collect")

        verifier:delete()
        verifier:delete()

        print(
            "Luavgl one-shot timer completion, address reuse, repeated delete, and forced GC passed"
        )
        os.exit(0)
    end,
}

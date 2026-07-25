local lvgl = require("lvgl")
local sync_config = require("sync_config")
local sync_manifest_state = require("sync_manifest_state")
local time = require("time")

local M = {}

local poll_period_ms = 500
local refresh_interval_ms = 60000
local retry_interval_ms = 15000

local timer = nil
local next_refresh_at = 0
local last_result = nil

local function schedule_next(result, now)
    if result.ok then
        next_refresh_at = now + refresh_interval_ms
    else
        next_refresh_at = now + retry_interval_ms
    end
end

local function poll()
    local now = time.ticks()
    local result = sync_manifest_state.poll()

    if result then
        last_result = result
        schedule_next(result, now)
        return
    end

    if sync_manifest_state.busy() then
        return
    end

    if now < next_refresh_at then
        return
    end

    local status = sync_config.status()

    if not status.connected then
        next_refresh_at = now + 1000
        return
    end

    local started, start_error =
        sync_manifest_state.start_refresh()

    if not started then
        last_result = {
            ok = false,
            error = start_error,
        }
        next_refresh_at = now + retry_interval_ms
    end
end

function M.start()
    if timer then
        return false, "sync runtime is already started"
    end

    local cached = sync_manifest_state.load_cached()

    timer = lvgl.Timer {
        period = poll_period_ms,
        cb = function()
            poll()
        end,
    }

    return true, cached
end

function M.last_result()
    return last_result
end

return M

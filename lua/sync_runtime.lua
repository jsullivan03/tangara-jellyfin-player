local lvgl = require("lvgl")
local sync_config = require("sync_config")
local sync_managed_paths = require("sync_managed_paths")
local sync_manifest_state = require("sync_manifest_state")
local sync_reconcile = require("sync_reconcile")
local time = require("time")

local M = {}

local poll_period_ms = 500
local refresh_interval_ms = 60000
local retry_interval_ms = 15000

local timer = nil
local next_refresh_at = 0
local last_result = nil
local active_plan = nil
local active_plan_error = nil
local managed_paths_recovered = false

local function update_plan(manifest)
    if type(manifest) ~= "table" then
        active_plan = nil
        active_plan_error = "active manifest is unavailable"
        managed_paths_recovered = false
        return nil, active_plan_error, false
    end

    local managed_paths, inventory_error, recovered =
        sync_managed_paths.load()

    if not managed_paths then
        active_plan = nil
        active_plan_error = inventory_error
        managed_paths_recovered = false
        return nil, inventory_error, false
    end

    local plan, plan_error =
        sync_reconcile.plan(manifest, managed_paths)

    if not plan then
        active_plan = nil
        active_plan_error = plan_error
        managed_paths_recovered = recovered
        return nil, plan_error, recovered
    end

    active_plan = plan
    active_plan_error = nil
    managed_paths_recovered = recovered

    return plan, nil, recovered
end

local function attach_plan(result)
    if result.ok and result.manifest then
        local plan, plan_error, recovered =
            update_plan(result.manifest)

        result.plan = plan
        result.plan_error = plan_error
        result.managed_paths_recovered = recovered
    else
        result.plan = active_plan
        result.plan_error = active_plan_error
        result.managed_paths_recovered =
            managed_paths_recovered
    end

    return result
end

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
        result = attach_plan(result)
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
        last_result = attach_plan({
            ok = false,
            error = start_error,
        })
        next_refresh_at = now + retry_interval_ms
    end
end

function M.start()
    if timer then
        return false, "sync runtime is already started"
    end

    local cached = sync_manifest_state.load_cached()
    cached = attach_plan(cached)
    last_result = cached

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

function M.current_plan()
    return active_plan,
        active_plan_error,
        managed_paths_recovered
end

return M

local lvgl = require("lvgl")
local sync_apply = require("sync_apply")
local sync_config = require("sync_config")
local sync_operation_flush =
    require("sync_operation_flush")
local sync_operation_queue =
    require("sync_operation_queue")
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
local next_apply_at = 0
local next_operation_at = 0
local last_result = nil
local last_operation_result = nil
local last_apply_result = nil
local active_manifest = nil
local active_plan = nil
local active_plan_error = nil
local active_plan_authoritative = false
local managed_paths_recovered = false

local function update_plan(manifest, authoritative)
    if type(manifest) ~= "table" then
        active_manifest = nil
        active_plan = nil
        active_plan_error =
            "active manifest is unavailable"
        active_plan_authoritative = false
        managed_paths_recovered = false

        return nil, active_plan_error, false
    end

    local managed_paths, inventory_error, recovered =
        sync_managed_paths.load()

    if not managed_paths then
        active_manifest = manifest
        active_plan = nil
        active_plan_error = inventory_error
        active_plan_authoritative = false
        managed_paths_recovered = false

        return nil, inventory_error, false
    end

    local plan, plan_error =
        sync_reconcile.plan(
            manifest,
            managed_paths
        )

    if not plan then
        active_manifest = manifest
        active_plan = nil
        active_plan_error = plan_error
        active_plan_authoritative = false
        managed_paths_recovered = recovered

        return nil, plan_error, recovered
    end

    active_manifest = manifest
    active_plan = plan
    active_plan_error = nil
    active_plan_authoritative =
        authoritative == true
    managed_paths_recovered = recovered

    return plan, nil, recovered
end

local function attach_plan(result, authoritative)
    if result.ok and result.manifest then
        local plan, plan_error, recovered =
            update_plan(
                result.manifest,
                authoritative
            )

        result.plan = plan
        result.plan_error = plan_error
        result.managed_paths_recovered =
            recovered
    else
        result.plan = active_plan
        result.plan_error =
            active_plan_error
        result.managed_paths_recovered =
            managed_paths_recovered
    end

    result.plan_authoritative =
        active_plan_authoritative

    return result
end

local function update_last_result_plan()
    if type(last_result) ~= "table" then
        return
    end

    last_result.plan = active_plan
    last_result.plan_error =
        active_plan_error
    last_result.plan_authoritative =
        active_plan_authoritative
    last_result.managed_paths_recovered =
        managed_paths_recovered
end

local function schedule_next(result, now)
    if result.ok then
        next_refresh_at =
            now + refresh_interval_ms
    else
        next_refresh_at =
            now + retry_interval_ms
    end
end

local function start_apply(now, status)
    if sync_apply.busy() then
        return false
    end

    if not active_plan_authoritative then
        return false
    end

    if type(active_plan) ~= "table" or
        type(active_plan.download) ~= "table" or
        #active_plan.download == 0 then
        return false
    end

    if now < next_apply_at then
        return false
    end

    status = status or sync_config.status()

    if not status.connected then
        return false
    end

    local started, start_error =
        sync_apply.start(active_plan)

    if not started then
        last_apply_result = {
            ok = false,
            error = start_error,
            completed = 0,
            total = #active_plan.download,
            remaining = #active_plan.download,
        }

        next_apply_at =
            now + retry_interval_ms

        return false, start_error
    end

    last_apply_result = nil

    return true
end

local function finish_apply(result, now)
    last_apply_result = result

    if active_manifest then
        update_plan(
            active_manifest,
            active_plan_authoritative
        )
    end

    if result.ok then
        next_apply_at = now
    else
        next_apply_at =
            now + retry_interval_ms
    end

    update_last_result_plan()

    if type(last_result) == "table" then
        last_result.apply = result
    end
end

local function start_operations(
    now,
    status
)
    if now < next_operation_at or
        not status.connected then
        return false
    end

    local queue_status, queue_error =
        sync_operation_queue.status()

    if queue_error then
        last_operation_result = {
            ok = false,
            error = queue_error,
            blocked = true,
        }

        next_operation_at =
            now + retry_interval_ms

        return false
    end

    if queue_status.pending == 0 then
        next_operation_at = now + 5000
        return false
    end

    if queue_status.blocked then
        last_operation_result = {
            ok = false,
            error = queue_status.error,
            blocked = true,
            pending =
                queue_status.pending,
        }

        next_operation_at =
            now + 60000

        return false
    end

    local started, start_error =
        sync_operation_flush.start()

    if not started then
        last_operation_result = {
            ok = false,
            error = start_error,
            blocked = false,
            pending =
                queue_status.pending,
        }

        next_operation_at =
            now + retry_interval_ms

        return false
    end

    return true
end

local function finish_operations(
    result,
    now
)
    last_operation_result = result

    if result.ok then
        if result.pending and
            result.pending > 0 then
            next_operation_at = now
        else
            next_operation_at = now + 5000
        end

        next_refresh_at = 0
    else
        next_operation_at =
            now + retry_interval_ms
    end
end

local function poll()
    local now = time.ticks()

    if sync_apply.busy() then
        local apply_result =
            sync_apply.poll()

        if apply_result then
            finish_apply(apply_result, now)
        end

        return
    end

    if sync_operation_flush.busy() then
        local operation_result =
            sync_operation_flush.poll()

        if operation_result then
            finish_operations(
                operation_result,
                now
            )
        end

        return
    end

    local result = sync_manifest_state.poll()

    if result then
        local authoritative =
            result.ok and
            type(result.manifest) == "table"

        result = attach_plan(
            result,
            authoritative
        )

        last_result = result
        schedule_next(result, now)

        local status = sync_config.status()
        local started, start_error =
            start_apply(now, status)

        result.apply_started = started
        result.apply_error = start_error

        return
    end

    if sync_manifest_state.busy() then
        return
    end

    local status = sync_config.status()

    if start_operations(now, status) then
        return
    end

    local apply_started =
        start_apply(now, status)

    if apply_started then
        return
    end

    if now < next_refresh_at then
        return
    end

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
        }, false)

        next_refresh_at =
            now + retry_interval_ms
    end
end

function M.start()
    if timer then
        return false,
            "sync runtime is already started"
    end

    local cached =
        sync_manifest_state.load_cached()

    cached = attach_plan(cached, false)
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
        managed_paths_recovered,
        active_plan_authoritative
end

function M.apply_progress()
    return sync_apply.progress()
end

function M.last_apply_result()
    return last_apply_result
end

function M.operation_queue_status()
    return sync_operation_queue.status()
end

function M.last_operation_result()
    return last_operation_result
end

return M

local sync_download = require("sync_download")

local M = {}

local session = nil
local last_result = nil

local function copy_actions(actions)
    if type(actions) ~= "table" then
        return nil, "download plan must be a table"
    end

    local copied = {}

    for index, action in ipairs(actions) do
        if type(action) ~= "table" then
            return nil,
                "download action " .. index ..
                " must be a table"
        end

        table.insert(copied, action)
    end

    return copied
end

local function finish(ok, error_message, download_result)
    local result = {
        ok = ok,
        error = error_message,
        completed = session.completed,
        total = session.total,
        remaining =
            session.total - session.completed,
        download = download_result,
        artwork_failed =
            session.artwork_failed or 0,
    }

    if session.current then
        result.failed_action = session.current
    end

    session = nil
    last_result = result

    return result
end

local function start_next()
    if session.index > session.total then
        return true, nil, true
    end

    local action = session.actions[session.index]
    local started, start_error =
        sync_download.start(action)

    if not started then
        session.current = action
        return false, start_error, false
    end

    session.current = action

    return true, nil, false
end

function M.start(plan)
    if session or sync_download.busy() then
        return false,
            "sync application is already in progress"
    end

    if type(plan) ~= "table" then
        return false, "sync plan must be a table"
    end

    local planned_actions = plan.actions

    if type(planned_actions) ~= "table" then
        planned_actions = {}

        for _, action in ipairs(plan.download or {}) do
            table.insert(planned_actions, action)
        end

        for _, action in ipairs(plan.artwork or {}) do
            table.insert(planned_actions, action)
        end
    end

    local actions, actions_error =
        copy_actions(planned_actions)

    if not actions then
        return false, actions_error
    end

    session = {
        actions = actions,
        index = 1,
        completed = 0,
        total = #actions,
        current = nil,
        artwork_failed = 0,
    }

    last_result = nil

    local started, start_error =
        start_next()

    if not started then
        finish(false, start_error, nil)
        return false, start_error
    end

    return true
end

function M.busy()
    return session ~= nil or sync_download.busy()
end

function M.progress()
    if not session then
        return nil
    end

    local result = {
        busy = true,
        completed = session.completed,
        total = session.total,
        remaining =
            session.total - session.completed,
    }

    if session.current then
        result.local_path =
            session.current.local_path
        result.storage_path =
            session.current.storage_path

        local download_progress =
            sync_download.progress()

        if type(download_progress) == "table" then
            result.bytes = download_progress.bytes
            result.bytes_total =
                download_progress.total
        end
    end

    return result
end

function M.poll()
    if not session then
        return nil
    end

    if session.total == 0 then
        return finish(true, nil, nil)
    end

    local download_result =
        sync_download.poll()

    if not download_result then
        return nil
    end

    if not download_result.ok then
        if session.current and
            session.current.kind ==
                "artwork" then
            session.artwork_failed =
                session.artwork_failed + 1
            session.completed =
                session.completed + 1
            session.index =
                session.index + 1
            session.current = nil

            local started, start_error,
                complete = start_next()

            if not started then
                return finish(
                    false,
                    start_error,
                    download_result
                )
            end

            if complete then
                return finish(
                    true,
                    nil,
                    download_result
                )
            end

            return nil
        end

        return finish(
            false,
            download_result.error or
                "download failed",
            download_result
        )
    end

    if not download_result.inventory_saved then
        return finish(
            false,
            download_result.inventory_error or
                "downloaded file was not added to managed inventory",
            download_result
        )
    end

    session.completed = session.completed + 1
    session.index = session.index + 1
    session.current = nil

    local started, start_error, complete =
        start_next()

    if not started then
        return finish(false, start_error, nil)
    end

    if complete then
        return finish(true, nil, download_result)
    end

    return nil
end

function M.current()
    if not session then
        return nil
    end

    return {
        completed = session.completed,
        total = session.total,
        remaining =
            session.total - session.completed,
        action = session.current,
    }
end

function M.last_result()
    return last_result
end

return M

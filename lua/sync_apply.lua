local sync_download = require("sync_download")
local index_generation =
    require("jellyfin_local_index_generation")
local jellyfin_album_identity =
    require("jellyfin_album_identity")

local M = {}

local session = nil
local last_result = nil
local state_generation = 0

local function stable_item_id(item)
    return jellyfin_album_identity.item_id(
        item
    )
end

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
    if session.changed_local_files then
        index_generation.invalidate(
            "sync apply changed local files"
        )
    end

    local media_items = {}
    for _, action in ipairs(
        session.actions or {}
    ) do
        if action.kind == "media" and
            type(action.item) == "table" then
            media_items[#media_items + 1] =
                action.item
        end
    end

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
        bytes = session.bytes_completed or 0,
        bytes_total = session.bytes_total or 0,
        media_items = media_items,
    }

    if session.current then
        result.failed_action = session.current
    end

    session = nil
    last_result = result
    state_generation = state_generation + 1

    return result
end

local function start_next()
    if session.index > session.total then
        return true, nil, true
    end

    local action = session.actions[session.index]

    if action.kind == "media" and
        type(action.item) == "table" and
        (
            type(action.item.local_added_at) ~=
                "string" or
            action.item.local_added_at == ""
        ) then
        action.item.local_added_at =
            os.date(
                "!%Y-%m-%dT%H:%M:%SZ"
            )
    end

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

    local bytes_total = 0

    for _, action in ipairs(actions) do
        if action.kind == "media" and
            type(action.item) == "table" then
            local size = tonumber(
                action.item.size_bytes
            )

            if size and size > 0 then
                bytes_total =
                    bytes_total + size
            end
        end
    end

    session = {
        actions = actions,
        index = 1,
        completed = 0,
        total = #actions,
        current = nil,
        artwork_failed = 0,
        changed_local_files = false,
        bytes_completed = 0,
        bytes_total = bytes_total,
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
        result.action = session.current
        result.local_path =
            session.current.local_path
        result.storage_path =
            session.current.storage_path

        local download_progress =
            sync_download.progress()

        local current_bytes = 0

        if session.current.kind == "media" and
            type(download_progress) == "table" then
            current_bytes =
                tonumber(
                    download_progress.bytes
                ) or 0
        end

        result.bytes =
            (session.bytes_completed or 0) +
            current_bytes
        result.bytes_total =
            session.bytes_total or 0

        if result.bytes_total <= 0 and
            session.current.kind == "media" and
            type(download_progress) == "table" then
            result.bytes =
                tonumber(
                    download_progress.bytes
                ) or 0
            result.bytes_total =
                tonumber(
                    download_progress.total
                ) or 0
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

    session.changed_local_files = true

    if session.current and
        session.current.kind == "media" then
        index_generation.invalidate(
            "sync apply completed media"
        )
        state_generation =
            state_generation + 1
    end

    if session.current and
        session.current.kind == "media" then
        local expected =
            type(session.current.item) == "table" and
            tonumber(
                session.current.item.size_bytes
            ) or nil
        local completed_bytes =
            tonumber(download_result.total) or
            tonumber(download_result.bytes) or
            expected or 0

        if expected and expected > 0 then
            completed_bytes = expected
        end

        session.bytes_completed =
            (session.bytes_completed or 0) +
            math.max(0, completed_bytes)
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


function M.item_states()
    local states = {}

    if not session then
        return states
    end

    for index = session.index, session.total do
        local action = session.actions[index]
        local item =
            type(action) == "table" and
            action.item or nil
        local item_id = stable_item_id(item)

        if item_id then
            local next_state

            if action.kind == "media" then
                next_state =
                    index == session.index and
                    "downloading" or
                    "queued"
            elseif action.kind == "artwork" then
                next_state = "finalizing"
            end

            local current = states[item_id]
            local priority = {
                finalizing = 1,
                queued = 2,
                downloading = 3,
            }

            if next_state and
                (
                    not current or
                    priority[next_state] >
                        priority[current]
                ) then
                states[item_id] = next_state
            end
        end
    end

    return states
end

function M.pending_items()
    local items = {}
    local seen = {}

    if not session then
        return items
    end

    local states = M.item_states()

    for index = session.index, session.total do
        local action = session.actions[index]
        local item =
            type(action) == "table" and
            action.item or nil
        local item_id = stable_item_id(item)

        if item_id and not seen[item_id] then
            seen[item_id] = true
            items[#items + 1] = {
                item = item,
                state = states[item_id] or
                    "queued",
            }
        end
    end

    return items
end

function M.generation()
    return state_generation
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
        bytes = session.bytes_completed or 0,
        bytes_total = session.bytes_total or 0,
    }
end

function M.last_result()
    return last_result
end

return M

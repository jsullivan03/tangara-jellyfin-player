local device = require("device")
local download = require("download")
local sync_managed_paths = require("sync_managed_paths")
local sync_reconcile = require("sync_reconcile")

local M = {}

local active_action = nil

local function prepare_action(action)
    if type(action) ~= "table" then
        return nil, "download action must be a table"
    end

    local local_path, path_error =
        sync_reconcile.normalize_local_path(
            action.local_path
        )

    if not local_path then
        return nil, path_error
    end

    if type(action.media_url) ~= "string" or
        not action.media_url:match("^https?://") then
        return nil,
            "download media URL must begin with http:// or https://"
    end

    local root, root_error = device.storage_root()

    if type(root) ~= "string" or root == "" then
        return nil,
            root_error or
            "storage root is unavailable"
    end

    root = root:gsub("/+$", "")

    return {
        local_path = local_path,
        storage_path = root .. local_path,
        media_url = action.media_url,
        media_path = action.media_path,
        item = action.item,
    }
end

function M.start(action)
    if active_action or download.busy() then
        return false, "sync download already in progress"
    end

    local prepared, prepare_error =
        prepare_action(action)

    if not prepared then
        return false, prepare_error
    end

    local started, start_error =
        download.start(
            prepared.media_url,
            prepared.storage_path
        )

    if not started then
        return false, start_error
    end

    active_action = prepared

    return true
end

function M.busy()
    return active_action ~= nil or download.busy()
end

function M.progress()
    local progress = download.progress()

    if type(progress) ~= "table" then
        return progress
    end

    if active_action then
        progress.local_path =
            active_action.local_path
        progress.storage_path =
            active_action.storage_path
    end

    return progress
end

function M.poll()
    local result = download.poll()

    if result == nil then
        return nil
    end

    local action = active_action
    active_action = nil

    if not action then
        return {
            ok = false,
            status = result.status,
            bytes = result.bytes,
            total = result.total,
            error =
                "download completed without an active action",
            inventory_saved = false,
        }
    end

    result.local_path = action.local_path
    result.storage_path = action.storage_path
    result.media_path = action.media_path
    result.item = action.item

    if not result.ok then
        result.inventory_saved = false
        return result
    end

    local managed_paths, load_error =
        sync_managed_paths.load()

    if not managed_paths then
        result.inventory_saved = false
        result.inventory_error = load_error
        return result
    end

    table.insert(
        managed_paths,
        action.local_path
    )

    local saved, save_error =
        sync_managed_paths.save(managed_paths)

    result.inventory_saved = saved
    result.inventory_error = save_error

    return result
end

function M.current()
    return active_action
end

return M

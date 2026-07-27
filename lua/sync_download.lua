local device = require("device")
local download = require("download")
local filesystem = require("filesystem")
local sync_managed_paths = require("sync_managed_paths")
local sync_reconcile = require("sync_reconcile")

local M = {}

local active_action = nil

local function ensure_parent_directory(local_path)
    local parent = local_path:match("^/(.+)/[^/]+$")

    if not parent then
        return true
    end

    local current = ""

    for segment in parent:gmatch("[^/]+") do
        if current == "" then
            current = segment
        else
            current = current .. "/" .. segment
        end

        if not filesystem.chkdir(current) then
            local created = filesystem.mkdir(current)

            if not created and not filesystem.chkdir(current) then
                return false,
                    "unable to create " .. current
            end
        end
    end

    return true
end

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

    local kind = action.kind or "media"

    if kind ~= "media" and kind ~= "artwork" then
        return nil, "unsupported download action kind"
    end

    local source_url

    if kind == "artwork" then
        source_url = action.artwork_url
    else
        source_url = action.media_url
    end

    if type(source_url) ~= "string" or
        not source_url:match("^https?://") then
        return nil,
            "download URL must begin with http:// or https://"
    end

    local root, root_error = device.storage_root()

    if type(root) ~= "string" or root == "" then
        return nil,
            root_error or
            "storage root is unavailable"
    end

    root = root:gsub("/+$", "")

    local ready, ready_error =
        ensure_parent_directory(local_path)

    if not ready then
        return nil, ready_error
    end

    return {
        kind = kind,
        local_path = local_path,
        storage_path = root .. local_path,
        download_url = source_url,
        media_path = action.media_path,
        artwork_path = action.artwork_path,
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
            prepared.download_url,
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

    result.kind = action.kind
    result.local_path = action.local_path
    result.storage_path = action.storage_path
    result.media_path = action.media_path
    result.artwork_path = action.artwork_path
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

    local already_managed = false

    for _, path in ipairs(managed_paths) do
        if path == action.local_path then
            already_managed = true
            break
        end
    end

    if not already_managed then
        table.insert(managed_paths, action.local_path)
    end

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

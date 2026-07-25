local device = require("device")
local device_identity = require("device_identity")
local sync_client = require("sync_client")
local sync_manifest = require("sync_manifest")

local M = {}

local function normalize_local_path(path)
    if type(path) ~= "string" or path == "" then
        return nil, "local path must be a non-empty string"
    end

    if path:sub(1, 1) ~= "/" then
        return nil, "local path must begin with /"
    end

    if path:find("\0", 1, true) then
        return nil, "local path contains a null byte"
    end

    if path:find("[\r\n]") then
        return nil, "local path contains a line break"
    end

    local segments = {}

    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then
            return nil, "local path contains an unsafe segment"
        end

        table.insert(segments, segment)
    end

    if #segments == 0 then
        return nil, "local path must identify a file"
    end

    return "/" .. table.concat(segments, "/")
end

M.normalize_local_path = normalize_local_path

local function storage_root()
    local root, root_error = device.storage_root()

    if type(root) ~= "string" or root == "" then
        return nil, root_error or "storage root is unavailable"
    end

    return root:gsub("/+$", "")
end

local function storage_path(root, local_path)
    if root == "" then
        return local_path
    end

    return root .. local_path
end

local function default_file_exists(path)
    local file = io.open(path, "rb")

    if not file then
        return false
    end

    file:close()
    return true
end

function M.plan(manifest, managed_paths, file_exists)
    local valid_manifest, manifest_error =
        sync_manifest.validate(manifest)

    if not valid_manifest then
        return nil, manifest_error
    end

    if managed_paths ~= nil and type(managed_paths) ~= "table" then
        return nil, "managed paths must be a table"
    end

    local root, root_error = storage_root()

    if not root then
        return nil, root_error
    end

    file_exists = file_exists or default_file_exists
    managed_paths = managed_paths or {}

    local plan = {
        keep = {},
        download = {},
        delete = {},
    }

    local desired_paths = {}

    for index, item in ipairs(manifest.items) do
        if type(item) ~= "table" then
            return nil, "manifest item " .. index .. " must be an object"
        end

        local local_path, path_error =
            normalize_local_path(item.local_path)

        if not local_path then
            return nil,
                "manifest item " .. index .. ": " .. path_error
        end

        if desired_paths[local_path] then
            return nil, "duplicate manifest path: " .. local_path
        end

        local media_path, media_path_error =
            device_identity.media_path(item.jellyfin_id)

        if not media_path then
            return nil,
                "manifest item " .. index .. ": " ..
                media_path_error
        end

        desired_paths[local_path] = true

        local full_path = storage_path(root, local_path)
        local action = {
            local_path = local_path,
            storage_path = full_path,
            media_path = media_path,
            item = item,
        }

        if file_exists(full_path) then
            table.insert(plan.keep, action)
        else
            local media_url, media_url_error =
                sync_client.url(media_path)

            if not media_url then
                return nil,
                    "manifest item " .. index .. ": " ..
                    media_url_error
            end

            action.media_url = media_url
            table.insert(plan.download, action)
        end
    end

    local stale_paths = {}
    local seen_managed_paths = {}

    for index, path in ipairs(managed_paths) do
        local local_path, path_error =
            normalize_local_path(path)

        if not local_path then
            return nil,
                "managed path " .. index .. ": " .. path_error
        end

        if not seen_managed_paths[local_path] then
            seen_managed_paths[local_path] = true

            if not desired_paths[local_path] then
                table.insert(stale_paths, local_path)
            end
        end
    end

    table.sort(stale_paths)

    for _, local_path in ipairs(stale_paths) do
        local full_path = storage_path(root, local_path)

        if file_exists(full_path) then
            table.insert(plan.delete, {
                local_path = local_path,
                storage_path = full_path,
            })
        end
    end

    plan.counts = {
        keep = #plan.keep,
        download = #plan.download,
        delete = #plan.delete,
    }

    return plan
end

return M

local device = require("device")
local sync_reconcile = require("sync_reconcile")

local M = {}

local function inventory_paths()
    local root, root_error = device.storage_root()

    if type(root) ~= "string" or root == "" then
        return nil, root_error or "storage root is unavailable"
    end

    root = root:gsub("/+$", "")

    local current =
        root .. "/.tangara_sync_managed_paths"

    return {
        current = current,
        temporary = current .. ".tmp",
        backup = current .. ".bak",
    }
end

local function file_exists(path)
    local file = io.open(path, "rb")

    if not file then
        return false
    end

    file:close()
    return true
end

local function normalize_paths(paths)
    if type(paths) ~= "table" then
        return nil, "managed paths must be a table"
    end

    local result = {}
    local seen = {}

    for index, path in ipairs(paths) do
        local normalized, path_error =
            sync_reconcile.normalize_local_path(path)

        if not normalized then
            return nil,
                "managed path " .. index .. ": " .. path_error
        end

        if not seen[normalized] then
            seen[normalized] = true
            table.insert(result, normalized)
        end
    end

    table.sort(result)

    return result
end

local function load_path(path)
    local file, open_error = io.open(path, "rb")

    if not file then
        return nil, open_error
    end

    local paths = {}

    for line in file:lines() do
        if line ~= "" then
            table.insert(paths, line)
        end
    end

    file:close()

    return normalize_paths(paths)
end

function M.paths()
    return inventory_paths()
end

function M.save(paths)
    local normalized, validation_error =
        normalize_paths(paths)

    if not normalized then
        return false, validation_error
    end

    local files, path_error = inventory_paths()

    if not files then
        return false, path_error
    end

    os.remove(files.temporary)

    local file, open_error =
        io.open(files.temporary, "wb")

    if not file then
        return false, open_error
    end

    for _, path in ipairs(normalized) do
        local written, write_error =
            file:write(path, "\n")

        if not written then
            file:close()
            os.remove(files.temporary)
            return false, write_error
        end
    end

    local flushed, flush_error = file:flush()

    if not flushed then
        file:close()
        os.remove(files.temporary)
        return false, flush_error
    end

    file:close()

    local verified, verify_error =
        load_path(files.temporary)

    if not verified then
        os.remove(files.temporary)
        return false, verify_error
    end

    if #verified ~= #normalized then
        os.remove(files.temporary)
        return false, "managed path verification failed"
    end

    for index, path in ipairs(normalized) do
        if verified[index] ~= path then
            os.remove(files.temporary)
            return false, "managed path verification failed"
        end
    end

    local moved_current = false

    if file_exists(files.current) then
        os.remove(files.backup)

        local moved, move_error =
            os.rename(files.current, files.backup)

        if not moved then
            os.remove(files.temporary)
            return false, move_error
        end

        moved_current = true
    end

    local promoted, promote_error =
        os.rename(files.temporary, files.current)

    if not promoted then
        if moved_current then
            os.rename(files.backup, files.current)
        end

        os.remove(files.temporary)
        return false, promote_error
    end

    os.remove(files.backup)

    return true
end

function M.load()
    local files, path_error = inventory_paths()

    if not files then
        return nil, path_error
    end

    local current_exists = file_exists(files.current)
    local backup_exists = file_exists(files.backup)

    if not current_exists and not backup_exists then
        return {}, nil, false
    end

    local current_error = nil

    if current_exists then
        local paths, load_error =
            load_path(files.current)

        if paths then
            return paths, nil, false
        end

        current_error = load_error
    end

    if backup_exists then
        local paths, load_error =
            load_path(files.backup)

        if paths then
            return paths, nil, true
        end

        return nil, current_error or load_error
    end

    return nil, current_error
end

return M

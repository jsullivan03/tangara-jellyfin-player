local device = require("device")
local device_identity = require("device_identity")
local sync_manifest = require("sync_manifest")
local index_generation =
    require("jellyfin_local_index_generation")

local M = {}

-- Keep the decoded manifest in process memory. Collection screens call
-- jellyfin_playback.local_item() once per track while binding rows; without a
-- memory cache each call re-reads and re-parses the on-disk JSON and freezes
-- navigation for hundreds of milliseconds.
local memory_manifest = nil
local memory_from_backup = false
local memory_valid = false

local function clear_memory_cache()
    memory_manifest = nil
    memory_from_backup = false
    memory_valid = false
end

local function store_memory_cache(
    manifest,
    from_backup
)
    memory_manifest = manifest
    memory_from_backup = from_backup == true
    memory_valid = manifest ~= nil
end

local function cache_paths()
    local root, root_error = device.storage_root()

    if type(root) ~= "string" or root == "" then
        return nil, root_error or "storage root is unavailable"
    end

    root = root:gsub("/+$", "")

    local current = root .. "/.tangara_sync_manifest.json"

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

local function validate_device(manifest)
    local expected_device_id, device_error = device_identity.id()

    if not expected_device_id then
        return nil, device_error
    end

    local manifest_device_id = manifest.device.id

    if type(manifest_device_id) ~= "string" or manifest_device_id == "" then
        return nil, "manifest device ID is missing"
    end

    if manifest_device_id ~= expected_device_id then
        return nil, "manifest device ID does not match this device"
    end

    return manifest
end

local function validate_text(text)
    local manifest, manifest_error = sync_manifest.decode(text)

    if not manifest then
        return nil, manifest_error
    end

    return validate_device(manifest)
end

local function load_path(path)
    local manifest, manifest_error = sync_manifest.load(path)

    if not manifest then
        return nil, manifest_error
    end

    return validate_device(manifest)
end

function M.paths()
    return cache_paths()
end

function M.save(text)
    if type(text) ~= "string" then
        return false, "manifest text must be a string"
    end

    local manifest, validation_error = validate_text(text)

    if not manifest then
        return false, validation_error
    end

    local paths, path_error = cache_paths()

    if not paths then
        return false, path_error
    end

    os.remove(paths.temporary)

    local file, open_error = io.open(paths.temporary, "wb")

    if not file then
        return false, open_error
    end

    local written, write_error = file:write(text)

    if not written then
        file:close()
        os.remove(paths.temporary)
        return false, write_error
    end

    local flushed, flush_error = file:flush()

    if not flushed then
        file:close()
        os.remove(paths.temporary)
        return false, flush_error
    end

    file:close()

    local temporary_manifest, temporary_error =
        load_path(paths.temporary)

    if not temporary_manifest then
        os.remove(paths.temporary)
        return false, temporary_error
    end

    local moved_current = false

    if file_exists(paths.current) then
        os.remove(paths.backup)

        local moved, move_error =
            os.rename(paths.current, paths.backup)

        if not moved then
            os.remove(paths.temporary)
            return false, move_error
        end

        moved_current = true
    end

    local promoted, promote_error =
        os.rename(paths.temporary, paths.current)

    if not promoted then
        if moved_current then
            os.rename(paths.backup, paths.current)
        end

        os.remove(paths.temporary)
        return false, promote_error
    end

    os.remove(paths.backup)

    index_generation.invalidate(
        "manifest cache saved"
    )
    store_memory_cache(
        temporary_manifest,
        false
    )

    return true
end

function M.invalidate_memory(reason)
    clear_memory_cache()
    return reason
end

function M.load()
    if memory_valid and memory_manifest ~= nil then
        return memory_manifest,
            nil,
            memory_from_backup
    end

    local paths, path_error = cache_paths()

    if not paths then
        return nil, path_error
    end

    local manifest, manifest_error = load_path(paths.current)

    if manifest then
        store_memory_cache(
            manifest,
            false
        )
        return manifest, nil, false
    end

    local backup, backup_error = load_path(paths.backup)

    if backup then
        store_memory_cache(
            backup,
            true
        )
        return backup, nil, true
    end

    return nil, manifest_error or backup_error
end

return M

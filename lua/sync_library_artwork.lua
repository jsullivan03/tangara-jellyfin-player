local device = require("device")
local device_identity =
    require("device_identity")
local download = require("download")
local filesystem = require("filesystem")
local sync_client = require("sync_client")
local sync_library_cache =
    require("sync_library_cache")

local M = {}

local session = nil
local completed_result = nil
local last_result = nil

local function copy_value(value)
    if type(value) ~= "table" then
        return value
    end

    local copied = {}

    for key, child in pairs(value) do
        copied[copy_value(key)] =
            copy_value(child)
    end

    return copied
end

local function safe_component(value)
    value = tostring(value or "")
        :gsub("[^A-Za-z0-9._-]", "_")

    if value == "" then
        return "artwork"
    end

    return value
end

local function file_exists(path)
    local file = io.open(path, "rb")

    if not file then
        return false
    end

    file:close()
    return true
end

local function ensure_directory(path)
    if filesystem.chkdir(path) then
        return true
    end

    if filesystem.mkdir(path) then
        return true
    end

    return false,
        "unable to create " .. path
end

local function storage_root()
    local root, root_error =
        device.storage_root()

    if type(root) ~= "string" or
        root == "" then
        return nil,
            root_error or
            "storage root is unavailable"
    end

    return root:gsub("/+$", "")
end

local function collection_job(
    collection,
    name,
    root
)
    local item_id =
        collection.artwork_item_id

    if type(item_id) ~= "string" or
        item_id == "" then
        return nil
    end

    local remote_path, path_error =
        device_identity.artwork_path(
            item_id,
            "thumbnail"
        )

    if not remote_path then
        return nil, path_error
    end

    local remote_url, url_error =
        sync_client.url(remote_path)

    if not remote_url then
        return nil, url_error
    end

    local key =
        collection.artwork_tag

    if type(key) ~= "string" or
        key == "" then
        key =
            collection.revision or
            item_id
    end

    key =
        safe_component(key):sub(1, 24)

    local local_path =
        "/.tangara-artwork/playlists/" ..
        safe_component(name) ..
        "-sq28-" ..
        key ..
        ".png"

    local full_path =
        root .. local_path

    if file_exists(full_path) then
        collection.artwork = {
            cover = local_path,
        }

        return nil
    end

    return {
        collection = collection,
        local_path = local_path,
        full_path = full_path,
        remote_url = remote_url,
    }
end

local function finish()
    local saved, save_error =
        sync_library_cache.save(
            session.library
        )

    local result = {
        ok = saved,
        error = save_error,
        completed = session.completed,
        failed = session.failed,
        total = session.total,
        cache_saved = saved,
    }

    session = nil
    completed_result = result
    last_result = result
end

local function start_next()
    if session.index > session.total then
        finish()
        return true
    end

    local job =
        session.jobs[session.index]

    local started, start_error =
        download.start(
            job.remote_url,
            job.full_path
        )

    if not started then
        return false, start_error
    end

    session.current = job

    return true
end

function M.start(library)
    if session or completed_result or
        download.busy() then
        return false,
            "library artwork sync is busy"
    end

    if type(library) ~= "table" then
        return false,
            "library artwork requires a library"
    end

    local root, root_error =
        storage_root()

    if not root then
        return false, root_error
    end

    local ready, ready_error =
        ensure_directory(
            ".tangara-artwork"
        )

    if not ready then
        return false, ready_error
    end

    ready, ready_error =
        ensure_directory(
            ".tangara-artwork/playlists"
        )

    if not ready then
        return false, ready_error
    end

    local copied =
        copy_value(library)

    local jobs = {}

    local favorite_job,
        favorite_error =
        collection_job(
            copied.favorites,
            "favorites",
            root
        )

    if favorite_error then
        return false, favorite_error
    end

    if favorite_job then
        table.insert(jobs, favorite_job)
    end

    for _, playlist in ipairs(
        copied.playlists or {}
    ) do
        local job, job_error =
            collection_job(
                playlist,
                playlist.id,
                root
            )

        if job_error then
            return false, job_error
        end

        if job then
            table.insert(jobs, job)
        end
    end

    session = {
        library = copied,
        jobs = jobs,
        index = 1,
        total = #jobs,
        completed = 0,
        failed = 0,
        current = nil,
    }

    last_result = nil

    local started, start_error =
        start_next()

    if not started then
        session = nil
        return false, start_error
    end

    return true
end

function M.busy()
    return session ~= nil or
        completed_result ~= nil or
        download.busy()
end

function M.poll()
    if completed_result then
        local result = completed_result
        completed_result = nil
        return result
    end

    if not session or
        not session.current then
        return nil
    end

    local result = download.poll()

    if result == nil then
        return nil
    end

    local job = session.current
    session.current = nil

    if result.ok then
        job.collection.artwork = {
            cover = job.local_path,
        }

        session.completed =
            session.completed + 1
    else
        session.failed =
            session.failed + 1
    end

    session.index = session.index + 1

    local started, start_error =
        start_next()

    if not started then
        local failure = {
            ok = false,
            error = start_error,
            completed =
                session.completed,
            failed =
                session.failed,
            total = session.total,
            cache_saved = false,
        }

        session = nil
        last_result = failure

        return failure
    end

    if completed_result then
        return M.poll()
    end

    return nil
end

function M.last_result()
    return last_result
end

return M

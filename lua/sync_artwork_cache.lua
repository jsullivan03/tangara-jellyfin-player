local device = require("device")
local download = require("download")
local filesystem = require("filesystem")
local sync_client = require("sync_client")

local M = {}
local queue = {}
local queued = {}
local cached = {}
local failed = {}
local active = nil
local next_subscription_id = 0

local function safe(value)
    return tostring(value or "")
        :gsub("[^A-Za-z0-9._-]", "_")
        :sub(1, 72)
end

local function key_for(item)
    local revision = tostring(
        item.artwork_revision or ""
    )
    local source = tostring(
        item.artwork_source or "jellyfin"
    )

    -- Jellyfin tracks commonly inherit the same album image. The revision is
    -- the stable image identity, so keying by the track ID caused one identical
    -- thumbnail download per song. A revision change naturally invalidates the
    -- entry. Fall back to the item/path identity only when no revision exists.
    if revision ~= "" then
        return "sq28-v3:" ..
            source .. ":" .. revision
    end

    return "sq28-v3:item:" ..
        tostring(
            item.jellyfin_id or
            item.key or ""
        ) .. ":" ..
        tostring(
            item.artwork_path or ""
        )
end

local function live_subscription(
    subscription
)
    return
        type(subscription) == "table" and
        subscription.cancelled ~= true and
        type(subscription.callback) ==
            "function"
end

local function job_has_live_callbacks(job)
    for _, subscription in ipairs(
        job and job.callbacks or {}
    ) do
        if live_subscription(
            subscription
        ) then
            return true
        end
    end

    return false
end

local function remove_queued_job(job)
    if not job or active == job then
        return false
    end

    for index, queued_job in ipairs(queue) do
        if queued_job == job then
            table.remove(queue, index)
            queued[job.key] = nil
            return true
        end
    end

    return false
end

local function subscribe(job, callback)
    if type(callback) ~= "function" then
        return nil
    end

    next_subscription_id =
        next_subscription_id + 1

    local subscription = {
        id = next_subscription_id,
        key = job.key,
        job = job,
        callback = callback,
        cancelled = false,
    }

    table.insert(
        job.callbacks,
        subscription
    )

    return subscription
end

local function exists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

local function display_path(root, local_path)
    root = tostring(root or "")
        :gsub("/+$", "")

    if root == "/sd" then
        return local_path
    end

    return "/" ..
        root:gsub("^/+", "") ..
        local_path
end

local function ensure_directory()
    if type(filesystem.mkdir) ~=
            "function" then
        return false
    end

    if type(filesystem.chkdir) ~=
            "function" then
        filesystem.mkdir(
            ".tangara-artwork"
        )
        return filesystem.mkdir(
            ".tangara-artwork/sync"
        ) ~= false
    end

    if filesystem.chkdir(
        ".tangara-artwork/sync"
    ) then
        return true
    end
    if not filesystem.chkdir(
        ".tangara-artwork"
    ) then
        filesystem.mkdir(
            ".tangara-artwork"
        )
    end
    return filesystem.mkdir(
        ".tangara-artwork/sync"
    ) or
        filesystem.chkdir(
            ".tangara-artwork/sync"
        )
end

local function start_next()
    if active or
        #queue == 0 or
        download.busy() then
        return
    end
    local job = table.remove(queue, 1)
    local root = device.storage_root()
    if type(root) ~= "string" or
        not ensure_directory() then
        queued[job.key] = nil
        return
    end
    local url = sync_client.url(
        job.remote_path
    )
    if not url then
        queued[job.key] = nil
        return
    end
    if download.start(
        url,
        root:gsub("/+$", "") ..
            job.local_path
    ) then
        active = job
    else
        queued[job.key] = nil
    end
end

function M.resolved(item)
    if type(item) ~= "table" or
        type(item.artwork_path) ~= "string" or
        item.artwork_path == "" then
        return nil
    end

    local key = key_for(item)
    if cached[key] then
        return cached[key]
    end

    local root = device.storage_root()
    local local_path =
        "/.tangara-artwork/sync/" ..
        safe(key) .. "-sq28.png"
    if type(root) == "string" and
        exists(
            root:gsub("/+$", "") ..
            local_path
        ) then
        cached[key] =
            display_path(root, local_path)
        return cached[key]
    end

    return nil
end

function M.request(item, callback)
    if type(item) ~= "table" or
        type(item.artwork_path) ~=
            "string" or
        item.artwork_path == "" then
        return nil
    end
    local key = key_for(item)
    if cached[key] then
        if callback then
            callback(cached[key], key)
        end
        return cached[key], nil
    end
    local root = device.storage_root()
    local local_path =
        "/.tangara-artwork/sync/" ..
        safe(key) .. "-sq28.png"
    if type(root) == "string" and
        exists(
            root:gsub("/+$", "") ..
            local_path
        ) then
        -- A parent-album image can become available after a track-specific
        -- lookup failed. The on-device file is authoritative: retire any
        -- negative entry before consulting it so sibling tracks reuse the
        -- same decoded album cover immediately and remain offline-capable.
        failed[key] = nil
        cached[key] =
            display_path(
                root,
                local_path
            )
        if callback then
            callback(cached[key], key)
        end
        return cached[key], nil
    end
    if failed[key] then
        return nil
    end
    if queued[key] then
        local subscription =
            subscribe(
                queued[key],
                callback
            )
        return nil, subscription
    end
    local job = {
        key = key,
        remote_path =
            item.artwork_path,
        local_path = local_path,
        display_path =
            display_path(
                root,
                local_path
            ),
        callbacks = {},
    }
    local subscription =
        subscribe(job, callback)
    queued[key] = job
    table.insert(queue, job)
    start_next()
    return nil, subscription
end

function M.cancel(subscription)
    if type(subscription) ~= "table" or
        subscription.cancelled then
        return false
    end

    subscription.cancelled = true
    local job = subscription.job
    subscription.job = nil

    if job and
        not job_has_live_callbacks(job) then
        remove_queued_job(job)
    end

    return true
end

function M.poll()
    if not active then
        start_next()
        return nil
    end
    local result = download.poll()
    if not result then
        return nil
    end
    local job = active
    active = nil
    queued[job.key] = nil
    if result.ok then
        cached[job.key] =
            job.display_path
        for _, subscription in ipairs(
            job.callbacks
        ) do
            if live_subscription(
                subscription
            ) then
                subscription.job = nil
                subscription.callback(
                    job.display_path,
                    job.key
                )
            end
        end
    else
        failed[job.key] = true
    end
    start_next()
    return {
        ok = result.ok == true,
        key = job.key,
        path =
            result.ok and
            job.display_path or nil,
    }
end

function M.busy()
    return active ~= nil
end

function M.key(item)
    return key_for(item)
end

function M.matches(item, key)
    return key_for(item) == key
end

function M.reset()
    queue = {}
    queued = {}
    cached = {}
    failed = {}
    active = nil
    next_subscription_id = 0
end

return M

local sync_manifest_cache = require("sync_manifest_cache")
local sync_manifest_fetch = require("sync_manifest_fetch")

local M = {}

local active_manifest = nil
local active_source = nil
local last_error = nil

function M.load_cached()
    local manifest, cache_error, recovered =
        sync_manifest_cache.load()

    if not manifest then
        last_error = cache_error

        return {
            ok = false,
            error = cache_error,
        }
    end

    active_manifest = manifest
    active_source = recovered and "backup" or "cache"
    last_error = nil

    return {
        ok = true,
        manifest = active_manifest,
        source = active_source,
        recovered = recovered,
    }
end

function M.start_refresh()
    local started, start_error =
        sync_manifest_fetch.start()

    if not started then
        last_error = start_error
        return false, start_error
    end

    return true
end

function M.busy()
    return sync_manifest_fetch.busy()
end

function M.poll()
    local result = sync_manifest_fetch.poll()

    if result == nil then
        return nil
    end

    if not result.ok then
        last_error = result.error

        return {
            ok = false,
            status = result.status,
            error = result.error,
            manifest = active_manifest,
            source = active_source,
        }
    end

    active_manifest = result.manifest
    active_source = "server"
    last_error = result.cache_error

    return {
        ok = true,
        status = result.status,
        manifest = active_manifest,
        source = active_source,
        cache_saved = result.cache_saved,
        cache_error = result.cache_error,
    }
end

function M.current()
    return active_manifest, active_source
end

function M.error()
    return last_error
end

return M

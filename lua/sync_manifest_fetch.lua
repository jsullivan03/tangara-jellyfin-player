local device_identity = require("device_identity")
local sync_client = require("sync_client")
local sync_manifest = require("sync_manifest")
local sync_manifest_cache = require("sync_manifest_cache")

local M = {}

function M.start()
    local path, path_error = device_identity.manifest_path()

    if not path then
        return false, path_error
    end

    return sync_client.get(path)
end

function M.busy()
    return sync_client.busy()
end

function M.poll()
    local response = sync_client.poll()

    if response == nil then
        return nil
    end

    if not response.ok then
        return {
            ok = false,
            status = response.status,
            error = response.error,
            body = response.body,
        }
    end

    local manifest, manifest_error = sync_manifest.decode(response.body)

    if not manifest then
        return {
            ok = false,
            status = response.status,
            error = manifest_error,
            body = response.body,
        }
    end

    local expected_device_id, device_error = device_identity.id()

    if not expected_device_id then
        return {
            ok = false,
            status = response.status,
            error = device_error,
            body = response.body,
        }
    end

    local manifest_device_id = manifest.device.id

    if type(manifest_device_id) ~= "string" or manifest_device_id == "" then
        return {
            ok = false,
            status = response.status,
            error = "manifest device ID is missing",
            body = response.body,
        }
    end

    if manifest_device_id ~= expected_device_id then
        return {
            ok = false,
            status = response.status,
            error = "manifest device ID does not match this device",
            body = response.body,
        }
    end

    local cache_saved, cache_error =
        sync_manifest_cache.save(response.body)

    return {
        ok = true,
        status = response.status,
        manifest = manifest,
        cache_saved = cache_saved,
        cache_error = cache_error,
    }
end

return M

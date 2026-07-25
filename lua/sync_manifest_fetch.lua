local sync_client = require("sync_client")
local sync_manifest = require("sync_manifest")

local M = {}

function M.start(path)
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

    return {
        ok = true,
        status = response.status,
        manifest = manifest,
    }
end

return M

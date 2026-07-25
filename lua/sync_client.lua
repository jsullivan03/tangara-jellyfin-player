local http = require("http")
local sync_config = require("sync_config")

local M = {}

local function join_url(base_url, path)
    base_url = base_url:gsub("/+$", "")

    if path == nil or path == "" then
        return base_url
    end

    if type(path) ~= "string" then
        return nil, "path must be a string"
    end

    if path:match("^https?://") then
        return nil, "path must be relative"
    end

    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    return base_url .. path
end

function M.get(path)
    local config = sync_config.load()
    local valid, validation_error = sync_config.valid(config)

    if not valid then
        return false, validation_error
    end

    local url, url_error = join_url(config.server_url, path)

    if not url then
        return false, url_error
    end

    return http.get(url)
end

function M.busy()
    return http.busy()
end

function M.poll()
    return http.poll()
end

return M

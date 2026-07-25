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

local function prepare(path)
    local config = sync_config.load()
    local valid, validation_error =
        sync_config.valid(config)

    if not valid then
        return nil, validation_error
    end

    return M.url(path)
end

function M.url(path)
    local config = sync_config.load()

    if type(config.server_url) ~= "string" or
        config.server_url == "" then
        return nil, "sync server URL is required"
    end

    if not config.server_url:match("^https?://") then
        return nil,
            "sync server URL must begin with http:// or https://"
    end

    return join_url(config.server_url, path)
end

function M.get(path)
    local url, url_error = prepare(path)

    if not url then
        return false, url_error
    end

    return http.get(url)
end

function M.post(path, body)
    local url, url_error = prepare(path)

    if not url then
        return false, url_error
    end

    return http.post(url, body or "")
end

function M.put(path, body)
    local url, url_error = prepare(path)

    if not url then
        return false, url_error
    end

    if type(body) ~= "string" then
        return false, "request body must be a string"
    end

    return http.put(url, body)
end

function M.busy()
    return http.busy()
end

function M.poll()
    return http.poll()
end

return M

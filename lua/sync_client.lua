local http = require("http")
local sync_config = require("sync_config")

local M = {}

local default_owner = "sync_client_default"
local active_owner = nil

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

local function start_request(
    method,
    path,
    body,
    owner
)
    if active_owner ~= nil or http.busy() then
        return false,
            "HTTP request already in progress"
    end

    local url, url_error = prepare(path)

    if not url then
        return false, url_error
    end

    local started, start_error =
        method(url, body)

    if not started then
        return false, start_error
    end

    active_owner = owner or default_owner

    return true
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

function M.get(path, owner)
    return start_request(
        function(url)
            return http.get(url)
        end,
        path,
        nil,
        owner
    )
end

function M.post(path, body, owner)
    return start_request(
        function(url, request_body)
            return http.post(
                url,
                request_body or ""
            )
        end,
        path,
        body,
        owner
    )
end

function M.put(path, body, owner)
    if type(body) ~= "string" then
        return false, "request body must be a string"
    end

    return start_request(
        http.put,
        path,
        body,
        owner
    )
end

function M.busy(owner)
    if owner ~= nil then
        return active_owner == owner
    end

    return active_owner ~= nil or http.busy()
end

function M.poll(owner)
    local expected_owner =
        owner or default_owner

    if active_owner ~= expected_owner then
        return nil
    end

    local response = http.poll()

    if response ~= nil then
        active_owner = nil
    end

    return response
end

function M.owner()
    return active_owner
end

return M

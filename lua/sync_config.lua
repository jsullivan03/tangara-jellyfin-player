local nvs = require("nvs")
local wifi = require("wifi")

local M = {}

local function string_or_empty(value)
    if type(value) == "string" then
        return value
    end

    return ""
end

function M.load()
    return {
        ssid = string_or_empty(nvs.wifi_ssid()),
        password = string_or_empty(nvs.wifi_password()),
        server_url = string_or_empty(nvs.sync_server_url()),
    }
end

function M.valid(config)
    if type(config) ~= "table" then
        return false, "config must be a table"
    end

    if type(config.ssid) ~= "string" or config.ssid == "" then
        return false, "WiFi SSID is required"
    end

    if config.password ~= nil and type(config.password) ~= "string" then
        return false, "WiFi password must be a string"
    end

    if type(config.server_url) ~= "string" or config.server_url == "" then
        return false, "sync server URL is required"
    end

    if not config.server_url:match("^https?://") then
        return false, "sync server URL must begin with http:// or https://"
    end

    return true
end

function M.save(config)
    local valid, validation_error = M.valid(config)

    if not valid then
        return false, validation_error
    end

    if not nvs.set_wifi_ssid(config.ssid) then
        return false, "failed to save WiFi SSID"
    end

    if not nvs.set_wifi_password(config.password or "") then
        return false, "failed to save WiFi password"
    end

    if not nvs.set_sync_server_url(config.server_url) then
        return false, "failed to save sync server URL"
    end

    return true
end

function M.reload_wifi()
    return wifi.reload()
end

function M.status()
    local config = M.load()
    local configured = M.valid(config)

    return {
        configured = configured,
        started = wifi.started(),
        connected = wifi.connected(),
        ssid = config.ssid,
        server_url = config.server_url,
    }
end

return M

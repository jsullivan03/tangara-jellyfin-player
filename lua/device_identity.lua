local device = require("device")

local M = {}

function M.id()
    local device_id, device_error = device.id()

    if type(device_id) ~= "string" or device_id == "" then
        return nil, device_error or "device identity is unavailable"
    end

    return device_id
end

function M.manifest_path()
    local device_id, device_error = M.id()

    if not device_id then
        return nil, device_error
    end

    return "/devices/" .. device_id .. "/manifest"
end

return M

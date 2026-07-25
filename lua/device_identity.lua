local device = require("device")

local M = {}

local function encode_path_segment(value)
    return (value:gsub(
        "([^A-Za-z0-9._~-])",
        function(character)
            return string.format(
                "%%%02X",
                string.byte(character)
            )
        end
    ))
end

function M.id()
    local device_id, device_error = device.id()

    if type(device_id) ~= "string" or device_id == "" then
        return nil,
            device_error or
            "device identity is unavailable"
    end

    return device_id
end

function M.manifest_path()
    local device_id, device_error = M.id()

    if not device_id then
        return nil, device_error
    end

    return "/devices/" ..
        encode_path_segment(device_id) ..
        "/manifest"
end

function M.media_path(jellyfin_id)
    if type(jellyfin_id) ~= "string" or
        jellyfin_id == "" then
        return nil, "Jellyfin item ID is required"
    end

    local device_id, device_error = M.id()

    if not device_id then
        return nil, device_error
    end

    return "/devices/" ..
        encode_path_segment(device_id) ..
        "/items/" ..
        encode_path_segment(jellyfin_id) ..
        "/media"
end

return M

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

local function device_path(suffix)
    local device_id, device_error = M.id()

    if not device_id then
        return nil, device_error
    end

    return "/devices/" ..
        encode_path_segment(device_id) ..
        suffix
end

function M.id()
    local device_id, device_error = device.id()

    if type(device_id) ~= "string" or
        device_id == "" then
        return nil,
            device_error or
            "device identity is unavailable"
    end

    return device_id
end

function M.manifest_path()
    return device_path("/manifest")
end

function M.media_path(jellyfin_id)
    if type(jellyfin_id) ~= "string" or
        jellyfin_id == "" then
        return nil, "Jellyfin item ID is required"
    end

    return device_path(
        "/items/" ..
        encode_path_segment(jellyfin_id) ..
        "/media"
    )
end

function M.link_start_path(force)
    local suffix = "/link/start"

    if force == true then
        suffix = suffix .. "?force=true"
    end

    return device_path(suffix)
end

function M.link_status_path()
    return device_path("/link/status")
end

function M.sync_sources_path()
    return device_path("/sync/sources")
end

function M.sync_preferences_path()
    return device_path("/sync/preferences")
end

function M.operations_path()
    return device_path("/operations")
end

function M.library_path()
    return device_path("/library")
end

function M.playlist_items_path(
    playlist_id,
    start,
    limit
)
    if type(playlist_id) ~= "string" or
        playlist_id == "" then
        return nil, "playlist ID is required"
    end

    start = tonumber(start) or 0
    limit = tonumber(limit) or 500

    return device_path(
        "/playlists/" ..
        encode_path_segment(playlist_id) ..
        "/items?start=" ..
        tostring(math.floor(start)) ..
        "&limit=" ..
        tostring(math.floor(limit))
    )
end

function M.favorite_items_path(
    start,
    limit
)
    start = tonumber(start) or 0
    limit = tonumber(limit) or 500

    return device_path(
        "/favorites/items?start=" ..
        tostring(math.floor(start)) ..
        "&limit=" ..
        tostring(math.floor(limit))
    )
end

return M

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

function M.artwork_path(
    item_id,
    variant
)
    if type(item_id) ~= "string" or
        item_id == "" then
        return nil,
            "Jellyfin item ID is required"
    end

    variant = variant or "cover"

    if variant ~= "cover" and
        variant ~= "background" and
        variant ~= "thumbnail" then
        return nil,
            "invalid artwork variant"
    end

    return device_path(
        "/items/" ..
        encode_path_segment(item_id) ..
        "/artwork/" ..
        variant
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

function M.catalog_path(
    view,
    cursor,
    limit,
    options
)
    if view ~= "albums" and
        view ~= "tracks" then
        return nil, "invalid catalog view"
    end

    options = options or {}

    local sort = options.sort
    local direction = options.direction
    local valid_sorts = {
        title = true,
        artist = true,
        date_added = true,
    }

    if sort ~= nil and
        not valid_sorts[sort] then
        return nil, "invalid catalog sort"
    end

    if direction ~= nil and
        direction ~= "ascending" and
        direction ~= "descending" then
        return nil, "invalid catalog direction"
    end

    local suffix =
        "/catalog?view=" ..
        encode_path_segment(view) ..
        "&limit=" ..
        tostring(
            math.floor(
                tonumber(limit) or 20
            )
        )

    if sort then
        suffix =
            suffix ..
            "&sort=" ..
            encode_path_segment(sort)
    end

    if direction then
        suffix =
            suffix ..
            "&direction=" ..
            encode_path_segment(direction)
    end

    if type(cursor) == "string" and
        cursor ~= "" then
        suffix =
            suffix ..
            "&cursor=" ..
            encode_path_segment(cursor)
    end

    return device_path(suffix)
end

function M.album_tracks_path(album_id)
    if type(album_id) ~= "string" or
        album_id == "" then
        return nil, "album ID is required"
    end

    return device_path(
        "/catalog/albums/" ..
        encode_path_segment(album_id) ..
        "/tracks"
    )
end

function M.download_requests_path()
    return device_path("/download-requests")
end

function M.sync_search_path()
    return device_path("/sync/search")
end

function M.jellyfin_search_path()
    return device_path(
        "/sync/search/jellyfin"
    )
end

function M.external_search_path()
    return device_path(
        "/sync/search/external"
    )
end

function M.downloads_path()
    return device_path("/downloads")
end

function M.external_jobs_path()
    return device_path("/external/jobs")
end

function M.artist_releases_path(
    artist_key,
    artist_name,
    context
)
    if type(artist_key) ~= "string" or
        artist_key == "" then
        return nil, "artist key is required"
    end

    local path = device_path(
        "/external/artists/" ..
        encode_path_segment(
            artist_key
        ) ..
        "/releases"
    )

    context = context or {}
    local parameters = {}
    local function parameter(key, value)
        if type(value) == "string" and
            value ~= "" then
            parameters[#parameters + 1] =
                encode_path_segment(key) ..
                "=" ..
                encode_path_segment(value)
        end
    end

    parameter("name", artist_name)
    parameter(
        "jellyfin_artist_id",
        context.jellyfin_artist_id
    )
    parameter(
        "item_key",
        context.external_item_key
    )
    parameter(
        "jellyfin_id",
        context.jellyfin_id
    )
    parameter(
        "release_title",
        context.release_title
    )

    if #parameters > 0 then
        path =
            path ..
            "?" ..
            table.concat(parameters, "&")
    end

    return path
end

function M.inventory_path()
    return device_path("/inventory")
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

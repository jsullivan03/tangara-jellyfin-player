local device = require("device")

local M = {}

local function usable(value)
    return type(value) == "string" and
        value ~= "" and
        value ~= "//lua/img/cover_placeholder.png" and
        value ~= "//lua/img/background_placeholder.png"
end

local function file_exists(path)
    local file = io.open(path, "rb")

    if not file then
        return false
    end

    file:close()
    return true
end

function M.display_path(value)
    if not usable(value) or
        value:sub(1, 2) == "//" then
        return value
    end

    if value:sub(1, 1) ~= "/" then
        return value
    end

    local root = device.storage_root()

    if type(root) ~= "string" or
        root == "" then
        return value
    end

    root = root:gsub("/+$", "")
    local full_path = root .. value

    if not file_exists(full_path) then
        return value
    end

    -- The desktop LVGL stdio decoder sees the host working tree, while the
    -- firmware image decoder understands SD-relative paths directly.
    if root:match("^desktop%-sim/") then
        return "/" .. full_path
    end

    return value
end

local function candidate(
    artwork,
    key
)
    local value =
        type(artwork) == "table" and
        artwork[key] or nil

    if not usable(value) then
        return nil
    end

    return M.display_path(value), value
end

function M.active(active, kind)
    local item = active and active.item or nil
    local track = active and active.track or nil
    local item_artwork =
        type(item) == "table" and
        item.artwork or nil
    local track_artwork =
        type(track) == "table" and
        track.artwork or nil
    local keys = kind == "background" and {
        "background",
        "cover",
        "thumbnail",
        "album_thumbnail",
    } or {
        "cover",
        "thumbnail",
        "album_thumbnail",
        "playlist_thumbnail",
    }

    for _, key in ipairs(keys) do
        for _, artwork in ipairs({
            item_artwork,
            track_artwork,
        }) do
            local display, persistent =
                candidate(artwork, key)

            if display then
                local owner_id =
                    artwork[
                        key .. "_item_id"
                    ] or
                    (item and item.album_id) or
                    (track and track.album_id) or
                    (item and
                        (item.jellyfin_id or
                            item.id)) or
                    (track and
                        (track.jellyfin_id or
                            track.id))
                local revision =
                    artwork[
                        key .. "_revision"
                    ] or
                    artwork.image_tag or
                    artwork.revision or
                    persistent

                return display, {
                    key = key,
                    owner_id = owner_id,
                    revision = revision,
                    persistent_path = persistent,
                    derived_cache_path =
                        persistent,
                    requested_dimensions =
                        kind == "background" and
                        "160x128" or "66x66",
                    display_path = display,
                    exists =
                        display ~= persistent or
                        persistent:sub(1, 1) ~= "/" or
                        file_exists(
                            tostring(
                                device.storage_root()
                            ):gsub("/+$", "") ..
                                persistent
                        ),
                    network = false,
                }
            end
        end
    end

    return nil
end

return M

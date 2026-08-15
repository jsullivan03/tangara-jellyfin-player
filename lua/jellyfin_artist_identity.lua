-- Canonical Jellyfin artist identity.
-- Prefer stable artist IDs; use a namespaced name fallback only when no ID
-- exists. Display name is never the primary key for distinct stable IDs.
--
-- Formats:
--   id:<stable-jellyfin-artist-id>
--   name:<normalized-name>   (fallback only)

local M = {}

local function nonempty_string(value)
    return type(value) == "string" and
        value ~= ""
end

function M.canonical_id(value)
    if value == nil then
        return nil
    end

    local text = tostring(value)

    if text == "" or text == "nil" then
        return nil
    end

    if text:sub(1, 3) == "id:" then
        text = text:sub(4)
    elseif text:sub(1, 5) == "name:" then
        return nil
    end

    if text == "" then
        return nil
    end

    return text
end

function M.stable_id(value)
    if type(value) == "table" then
        return M.artist_id(value) or
            M.album_artist_id(value)
    end

    return M.canonical_id(value)
end

function M.normalize_name(value)
    if value == nil then
        return ""
    end

    return tostring(value):lower()
end

local function first_present(...)
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if value ~= nil and value ~= false then
            return value
        end
    end

    return nil
end

function M.artist_id(item)
    if type(item) ~= "table" then
        return M.canonical_id(item)
    end

    local from_list = nil
    if type(item.artist_ids) == "table" then
        from_list = item.artist_ids[1]
    end

    local from_key = nil
    if type(item.key) == "string" and
        item.key:sub(1, 3) == "id:" and
        item.kind == "artist" then
        from_key = item.key
    end

    return M.canonical_id(
        first_present(
            item.artist_id,
            item.jellyfin_artist_id,
            item.album_artist_id,
            from_list,
            item.kind == "artist" and item.id or
                nil,
            from_key
        )
    )
end

function M.album_artist_id(item)
    if type(item) ~= "table" then
        return nil
    end

    return M.canonical_id(
        first_present(
            item.album_artist_id,
            item.jellyfin_album_artist_id
        )
    )
end

function M.display_name(item)
    if type(item) ~= "table" then
        return "Unknown Artist"
    end

    local name =
        item.name or
        item.artist or
        item.album_artist

    if nonempty_string(name) then
        return name
    end

    return "Unknown Artist"
end

-- Stable artist key used by Local Artists / Sync discography / menus.
-- Order: stable artist id, then album-artist id, then name: fallback.
-- Returns key, stable_id (stable_id is nil for name: keys).
function M.canonical_key(item_or_id, fallback_name)
    local artist_id = nil
    local album_artist_id = nil
    local name = fallback_name

    if type(item_or_id) == "table" then
        local from_list = nil
        if type(item_or_id.artist_ids) ==
            "table" then
            from_list = item_or_id.artist_ids[1]
        end

        local from_artist_key = nil
        if nonempty_string(
            item_or_id.artist_key
        ) then
            local existing =
                item_or_id.artist_key
            if existing:sub(1, 3) == "id:" then
                from_artist_key = existing
            elseif existing:sub(1, 5) ==
                "name:" then
                return "name:" ..
                    M.normalize_name(
                        existing:sub(6)
                    ),
                    nil
            else
                from_artist_key = existing
            end
        end

        local from_key = nil
        if type(item_or_id.key) == "string" and
            item_or_id.key:sub(1, 3) == "id:" then
            from_key = item_or_id.key
        end

        -- Prefer explicit artist fields over generic `id` so album/track
        -- objects do not treat their own item id as an artist id.
        artist_id = M.canonical_id(
            first_present(
                item_or_id.artist_id,
                item_or_id.jellyfin_artist_id,
                from_list,
                from_artist_key,
                item_or_id.kind == "artist" and
                    item_or_id.id or nil,
                item_or_id.kind == "artist" and
                    from_key or nil
            )
        )
        album_artist_id =
            M.album_artist_id(item_or_id)
        name =
            name or
            M.display_name(item_or_id)
    else
        artist_id =
            M.canonical_id(item_or_id)
    end

    -- Empty strings are not stable IDs.
    if artist_id == "" then
        artist_id = nil
    end
    if album_artist_id == "" then
        album_artist_id = nil
    end

    local stable =
        artist_id or
        album_artist_id

    if stable then
        return "id:" .. stable, stable
    end

    local normalized =
        M.normalize_name(name)

    if normalized == "" then
        normalized = "unknown artist"
    end

    return "name:" .. normalized, nil
end

function M.key(item_or_id, fallback_name)
    local key = M.canonical_key(
        item_or_id,
        fallback_name
    )
    return key
end

function M.same(left, right)
    if left == nil or right == nil then
        return false
    end

    local left_key, left_stable
    local right_key, right_stable

    if type(left) == "table" or
        type(right) == "table" then
        left_key, left_stable =
            M.canonical_key(left)
        right_key, right_stable =
            M.canonical_key(right)
        if left_stable and right_stable then
            return left_stable == right_stable
        end
        return left_key ~= nil and
            left_key == right_key
    end

    local a = M.canonical_id(left)
    local b = M.canonical_id(right)

    if a ~= nil and b ~= nil then
        return a == b
    end

    left_key = M.key(left)
    right_key = M.key(right)
    return left_key ~= nil and
        left_key == right_key
end

return M

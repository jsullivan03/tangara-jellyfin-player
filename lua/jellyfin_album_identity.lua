-- Canonical Jellyfin album identity shared by Sync catalog, runtime/apply,
-- optimistic queue state, Local placeholders, and Local inventory.
--
-- Formats:
--   id:<stable-jellyfin-album-id>
--   album:<normalized-artist>|<normalized-title>   (fallback only)
--
-- Legacy Local fallback `name:<artist>\0<title>` is still recognized by
-- same()/parse helpers so resume snapshots survive one rebuild cycle.

local M = {}

local function nonempty_string(value)
    return type(value) == "string" and
        value ~= ""
end

local function normalize_text(value)
    if value == nil then
        return ""
    end

    return tostring(value):lower()
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
    elseif text:sub(1, 6) == "album:" or
        text:sub(1, 5) == "name:" or
        text:sub(1, 8) == "pending:" then
        return nil
    end

    if text == "" then
        return nil
    end

    return text
end

M.stable_id = M.canonical_id

function M.stable_id(value)
    if type(value) == "table" then
        return M.album_id(value)
    end

    return M.canonical_id(value)
end

function M.album_id(item)
    if type(item) ~= "table" then
        return M.canonical_id(item)
    end

    if item.kind == "track" then
        return M.canonical_id(
            item.album_id or
            item.parent_id or
            item.jellyfin_album_id
        )
    end

    local direct =
        item.jellyfin_id or
        item.album_id or
        item.jellyfin_album_id
    if direct ~= nil then
        return M.canonical_id(direct)
    end

    -- Local album records store the Jellyfin album id in `id`, with key
    -- shaped as id:<album_id>. Opaque external Sync keys are not Jellyfin ids.
    if item.id ~= nil and
        item.kind ~= "track" then
        local from_id = M.canonical_id(item.id)
        if from_id then
            return from_id
        end
    end

    if type(item.key) == "string" and
        item.key:sub(1, 3) == "id:" then
        return M.canonical_id(item.key)
    end

    if type(item.album_key) == "string" and
        item.album_key:sub(1, 3) == "id:" then
        return M.canonical_id(item.album_key)
    end

    return nil
end

function M.item_id(item)
    if type(item) ~= "table" then
        return M.canonical_id(item)
    end

    if item.kind == "album" then
        return M.album_id(item)
    end

    return M.canonical_id(
        item.jellyfin_id or item.id
    )
end

local function album_title(item)
    if type(item) ~= "table" then
        return ""
    end

    if item.kind == "track" then
        return item.album or
            item.album_name or
            ""
    end

    return item.title or
        item.name or
        item.album or
        item.album_name or
        ""
end

local function album_artist_name(item)
    if type(item) ~= "table" then
        return ""
    end

    return item.album_artist or
        item.artist or
        ""
end

local function fallback_key(item)
    local artist =
        normalize_text(album_artist_name(item))
    local title =
        normalize_text(album_title(item))

    if artist == "" then
        artist = "unknown artist"
    end

    if title == "" then
        title = "unknown album"
    end

    return "album:" .. artist .. "|" .. title
end

-- Legacy Local index used name:<artist>\0<title>.
function M.legacy_name_key(item)
    local artist =
        normalize_text(album_artist_name(item))
    local title =
        normalize_text(album_title(item))

    if artist == "" then
        artist = "unknown artist"
    end

    if title == "" then
        title = "unknown album"
    end

    return "name:" ..
        artist ..
        "\0" ..
        title
end

function M.key(item_or_id)
    if item_or_id == nil then
        return nil
    end

    if type(item_or_id) ~= "table" then
        local album_id =
            M.canonical_id(item_or_id)
        if album_id then
            return "id:" .. album_id
        end
        return nil
    end

    if nonempty_string(item_or_id.album_key) and
        (
            item_or_id.album_key:sub(1, 3) ==
                "id:" or
            item_or_id.album_key:sub(1, 6) ==
                "album:"
        ) then
        local from_album_key =
            M.canonical_id(item_or_id.album_key)
        if from_album_key then
            return "id:" .. from_album_key
        end
        if item_or_id.album_key:sub(1, 6) ==
            "album:" then
            return item_or_id.album_key
        end
    end

    if nonempty_string(item_or_id.key) and
        (
            item_or_id.key:sub(1, 3) == "id:" or
            item_or_id.key:sub(1, 6) == "album:"
        ) then
        local from_key =
            M.canonical_id(item_or_id.key)
        if from_key then
            return "id:" .. from_key
        end
        if item_or_id.key:sub(1, 6) == "album:" then
            return item_or_id.key
        end
    end

    local album_id = M.album_id(item_or_id)
    if album_id then
        return "id:" .. album_id
    end

    return fallback_key(item_or_id)
end

-- Alias used throughout Sync/Local UI.
function M.local_album_key(item_or_id)
    return M.key(item_or_id)
end

function M.track_album_key(track)
    if type(track) ~= "table" then
        return M.key(track)
    end

    local shaped = {
        kind = "track",
        album_id = track.album_id,
        parent_id = track.parent_id,
        jellyfin_album_id =
            track.jellyfin_album_id,
        album_key = track.album_key,
        album = track.album or track.album_name,
        album_name = track.album_name,
        artist = track.album_artist or
            track.artist,
        album_artist = track.album_artist,
    }

    return M.key(shaped)
end

function M.same(left, right)
    if left == nil or right == nil then
        return false
    end

    local left_id = M.album_id(left)
    local right_id = M.album_id(right)

    if left_id and right_id then
        return left_id == right_id
    end

    local left_key = M.key(left)
    local right_key = M.key(right)

    if left_key and right_key and
        left_key == right_key then
        return true
    end

    -- Cross-accept legacy name:\0 keys against album:| keys for one cycle.
    if type(left) == "table" or
        type(right) == "table" then
        local legacy_left =
            type(left) == "table" and
            M.legacy_name_key(left) or
            left
        local legacy_right =
            type(right) == "table" and
            M.legacy_name_key(right) or
            right
        if left_key == legacy_right or
            right_key == legacy_left or
            (
                type(legacy_left) == "string" and
                legacy_left == legacy_right
            ) then
            return true
        end
    end

    local a = M.canonical_id(left)
    local b = M.canonical_id(right)
    return a ~= nil and a == b
end

return M

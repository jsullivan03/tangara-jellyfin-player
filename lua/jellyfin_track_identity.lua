-- Canonical Jellyfin track identity.
-- Prefer stable track IDs; fallback only when no ID exists.
--
-- Formats:
--   id:<stable-jellyfin-track-id>
--   track:<canonical-album-key>|<normalized-disc>|<normalized-track>|<normalized-title>
--
-- Media paths and companion URLs continue to use stable_id() (bare id).
-- Comparisons and selection snapshots should use key()/same().

local jellyfin_album_identity =
    require("jellyfin_album_identity")

local M = {}

local function nonempty_string(value)
    return type(value) == "string" and
        value ~= ""
end

local function normalize_part(value)
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
    elseif text:sub(1, 6) == "track:" then
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
        return M.track_id(value)
    end

    return M.canonical_id(value)
end

function M.track_id(item)
    if type(item) ~= "table" then
        return M.canonical_id(item)
    end

    if item.kind == "album" then
        return nil
    end

    return M.canonical_id(
        item.jellyfin_id or
        item.track_id or
        item.id
    )
end

local function disc_number(item)
    return item.disc or
        item.disc_number or
        item.DiscNumber or
        ""
end

local function track_number(item)
    return item.track or
        item.track_number or
        item.IndexNumber or
        item.index_number or
        ""
end

local function track_title(item)
    return item.title or
        item.name or
        "unknown track"
end

local function fallback_key(item)
    local album_key =
        jellyfin_album_identity
            .track_album_key(item) or
        "album:unknown artist|unknown album"

    return "track:" ..
        album_key ..
        "|" ..
        normalize_part(disc_number(item)) ..
        "|" ..
        normalize_part(track_number(item)) ..
        "|" ..
        normalize_part(track_title(item))
end

function M.key(item_or_id)
    if item_or_id == nil then
        return nil
    end

    if type(item_or_id) ~= "table" then
        local track_id =
            M.canonical_id(item_or_id)
        if track_id then
            return "id:" .. track_id
        end
        return nil
    end

    if nonempty_string(item_or_id.track_key) and
        (
            item_or_id.track_key:sub(1, 3) ==
                "id:" or
            item_or_id.track_key:sub(1, 6) ==
                "track:"
        ) then
        local from_track_key =
            M.canonical_id(item_or_id.track_key)
        if from_track_key then
            return "id:" .. from_track_key
        end
        if item_or_id.track_key:sub(1, 6) ==
            "track:" then
            return item_or_id.track_key
        end
    end

    if nonempty_string(item_or_id.key) and
        (
            item_or_id.key:sub(1, 3) == "id:" or
            item_or_id.key:sub(1, 6) == "track:"
        ) then
        local from_key =
            M.canonical_id(item_or_id.key)
        if from_key then
            return "id:" .. from_key
        end
        if item_or_id.key:sub(1, 6) == "track:" then
            return item_or_id.key
        end
    end

    local track_id = M.track_id(item_or_id)
    if track_id then
        return "id:" .. track_id
    end

    return fallback_key(item_or_id)
end

function M.same(left, right)
    if left == nil or right == nil then
        return false
    end

    local left_id = M.track_id(left)
    local right_id = M.track_id(right)

    if left_id and right_id then
        return left_id == right_id
    end

    local left_key = M.key(left)
    local right_key = M.key(right)
    return left_key ~= nil and
        left_key == right_key
end

-- Resume / list selection must compare through key().
-- Accept bare stable IDs and prefixed keys interchangeably.
function M.matches_selection(stored, item_or_id)
    if stored == nil or item_or_id == nil then
        return false
    end

    if stored == item_or_id then
        return true
    end

    local stored_key = M.key(stored)
    local other_key = M.key(item_or_id)

    if stored_key and other_key and
        stored_key == other_key then
        return true
    end

    local stored_id = M.stable_id(stored)
    local other_id = M.stable_id(item_or_id)

    return stored_id ~= nil and
        stored_id == other_id
end

return M

local json = require("json")
local json_encode = require("json_encode")

local device_ok, device =
    pcall(require, "device")
local M = {}
local PREFERENCE_SCHEMA_VERSION = 5

local preferences = {
    search = "relevance",
    albums = {
        field = "alpha",
        alpha_descending = false,
        recent_descending = true,
    },
    tracks = {
        field = "alpha",
        alpha_descending = false,
        recent_descending = true,
    },
    downloads = "status",
}

local modes = {
    search = {
        "relevance",
        "artist",
        "title",
        "year",
    },
    albums = {
        "alpha",
        "recent",
    },
    tracks = {
        "alpha",
        "recent",
    },
    downloads = {
        "status",
        "newest",
        "title",
    },
}
local loaded = false
local save
local schema_version =
    PREFERENCE_SCHEMA_VERSION

local function path()
    if not device_ok or
        type(device.storage_root) ~=
            "function" then
        return nil
    end
    local ok, root =
        pcall(device.storage_root)
    if not ok or
        type(root) ~= "string" or
        root == "" then
        return nil
    end
    return root:gsub("/+$", "") ..
        "/.tangara_sync_sort.json"
end

local function valid(screen, mode)
    for _, candidate in ipairs(
        modes[screen] or {}
    ) do
        if candidate == mode then
            return true
        end
    end
    return false
end

local function catalog_screen(screen)
    return
        screen == "albums" or
        screen == "tracks"
end

local function catalog_default()
    return {
        field = "alpha",
        alpha_descending = false,
        recent_descending = true,
    }
end

local function valid_catalog_state(value)
    return
        type(value) == "table" and
        (
            value.field == "alpha" or
            value.field == "recent"
        ) and
        type(value.alpha_descending) ==
            "boolean" and
        type(value.recent_descending) ==
            "boolean"
end

local function load()
    if loaded then
        return
    end
    loaded = true
    local file_path = path()
    if not file_path then
        return
    end
    local file = io.open(file_path, "rb")
    if not file then
        return
    end
    local contents = file:read("*a")
    file:close()
    local ok, decoded =
        pcall(json.decode, contents)
    if not ok or
        type(decoded) ~= "table" then
        return
    end
    local migrated =
        tonumber(
            decoded.schema_version
        ) ~= PREFERENCE_SCHEMA_VERSION

    if migrated then
        -- Sort values written by the retired Sync-specific controller are
        -- intentionally not carried forward. This includes a valid-looking
        -- Date-added value: it was often persisted merely by moving focus
        -- through that broken menu, rather than by activating the option.
        preferences.albums =
            catalog_default()
        preferences.tracks =
            catalog_default()
    end

    for screen, mode in pairs(decoded) do
        if screen ~= "schema_version" and
            screen ~= "albums" and
            screen ~= "tracks" and
            valid(screen, mode) then
            preferences[screen] = mode
        end
    end

    if not migrated then
        for _, screen in ipairs({
            "albums",
            "tracks",
        }) do
            local state = decoded[screen]
            if valid_catalog_state(state) then
                preferences[screen] = {
                    field = state.field,
                    alpha_descending =
                        state
                            .alpha_descending,
                    recent_descending =
                        state
                            .recent_descending,
                }
            else
                preferences[screen] =
                    catalog_default()
                migrated = true
            end
        end
    end

    schema_version =
        PREFERENCE_SCHEMA_VERSION
    if migrated then
        save()
    end
end

save = function()
    local file_path = path()
    if not file_path then
        return
    end
    local ok, encoded =
        pcall(
            json_encode.encode,
            {
                schema_version =
                    schema_version,
                search =
                    preferences.search,
                albums =
                    preferences.albums,
                tracks =
                    preferences.tracks,
                downloads =
                    preferences.downloads,
            }
        )
    if not ok then
        return
    end
    local temporary =
        file_path .. ".tmp"
    local file = io.open(temporary, "wb")
    if not file then
        return
    end
    file:write(encoded)
    file:close()
    os.rename(temporary, file_path)
end

local function text(value)
    return tostring(value or ""):lower()
end

local function stable(item)
    return tostring(
        item.jellyfin_id or
        item.key or
        item.id or ""
    )
end

function M.modes(screen)
    return modes[screen] or {}
end

function M.current(screen)
    load()
    if catalog_screen(screen) then
        local current =
            preferences[screen]
        if current.field == "recent" then
            return
                current
                    .recent_descending and
                "date_added" or
                "date_added_asc"
        end
        return
            current.alpha_descending and
            "title_desc" or
            "title_asc"
    end
    return preferences[screen]
end

function M.set(screen, mode)
    load()
    if catalog_screen(screen) then
        local current =
            preferences[screen]
        if mode == "title_asc" then
            current.field = "alpha"
            current.alpha_descending =
                false
        elseif mode == "title_desc" then
            current.field = "alpha"
            current.alpha_descending =
                true
        elseif mode == "date_added" then
            current.field = "recent"
            current.recent_descending =
                true
        elseif mode == "date_added_asc" then
            current.field = "recent"
            current.recent_descending =
                false
        else
            return false
        end
        save()
        return true
    end

    for _, candidate in ipairs(
        modes[screen] or {}
    ) do
        if candidate == mode then
            preferences[screen] = mode
            save()
            return true
        end
    end

    return false
end

function M.next(screen)
    load()
    if catalog_screen(screen) then
        local current =
            preferences[screen]
        current.field =
            current.field == "alpha" and
            "recent" or "alpha"
        save()
        return M.current(screen)
    end

    local values = modes[screen] or {}
    local current = preferences[screen]

    for index, value in ipairs(values) do
        if value == current then
            preferences[screen] =
                values[
                    index % #values + 1
                ]
            save()
            return preferences[screen]
        end
    end

    preferences[screen] = values[1]
    save()
    return preferences[screen]
end

function M.selection(screen, field)
    load()
    if not catalog_screen(screen) then
        return nil
    end

    local current =
        preferences[screen]
    local selected_field =
        field or current.field
    if selected_field ~= "alpha" and
        selected_field ~= "recent" then
        return nil
    end

    local alpha_label =
        current.alpha_descending and
        "Z-A" or "A-Z"
    local recent_label =
        current.recent_descending and
        "New" or "Old"

    return {
        method = selected_field,
        label =
            selected_field == "recent" and
            recent_label or alpha_label,
        alpha_label = alpha_label,
        recent_label = recent_label,
    }
end

function M.select(screen, field)
    load()
    if not catalog_screen(screen) or
        (
            field ~= "alpha" and
            field ~= "recent"
        ) then
        return nil
    end

    local current =
        preferences[screen]
    current.field = field
    save()

    return M.selection(screen)
end

function M.toggle(screen, field)
    load()
    if not catalog_screen(screen) or
        (
            field ~= "alpha" and
            field ~= "recent"
        ) then
        return nil
    end

    local current =
        preferences[screen]
    if field == "recent" then
        current.recent_descending =
            not current.recent_descending
    else
        current.alpha_descending =
            not current.alpha_descending
    end
    current.field = field
    save()

    return M.selection(screen)
end

function M.label(value, screen)
    if value == "title_asc" and
        (
            screen == "albums" or
            screen == "tracks"
        ) then
        return "A-Z"
    elseif value == "title_desc" and
        (
            screen == "albums" or
            screen == "tracks"
        ) then
        return "Z-A"
    elseif value == "date_added" and
        catalog_screen(screen) then
        return "New"
    elseif value == "date_added_asc" and
        catalog_screen(screen) then
        return "Old"
    end

    return ({
        relevance = "Relevance",
        artist = "Artist",
        title = "Title",
        year = "Year",
        date_added = "Date added",
        status = "Status",
        newest = "Newest",
    })[value] or tostring(value)
end

function M.apply(items, mode)
    local copied = {}
    for _, item in ipairs(items or {}) do
        table.insert(copied, item)
    end

    table.sort(
        copied,
        function(a, b)
            local function key(item)
                if mode == "artist" then
                    return text(item.artist) ..
                        "\0" ..
                        text(item.title)
                elseif mode == "year" then
                    return string.format(
                        "%08d",
                        99999999 -
                        (tonumber(item.year) or 0)
                    )
                elseif mode == "date_added" or
                    mode == "date_added_asc" or
                    mode == "newest" then
                    return
                        tostring(
                            item.date_created or
                            item.created_at or ""
                        )
                elseif mode == "status" then
                    return text(
                        item.state or
                        (
                            item.device and
                            item.device.state
                        )
                    )
                end

                return text(item.title)
            end

            local left = key(a)
            local right = key(b)

            if left == right then
                return stable(a) < stable(b)
            end

            if mode == "date_added" or
                mode == "newest" then
                return left > right
            elseif mode ==
                    "date_added_asc" then
                return left < right
            elseif mode == "title_desc" then
                return left > right
            end

            return left < right
        end
    )

    return copied
end

function M.reset()
    preferences.search = "relevance"
    preferences.albums =
        catalog_default()
    preferences.tracks =
        catalog_default()
    preferences.downloads = "status"
    schema_version =
        PREFERENCE_SCHEMA_VERSION
    loaded = true
end

return M

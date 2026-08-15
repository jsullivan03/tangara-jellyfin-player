local json = require("json")
local json_encode = require("json_encode")

local device_ok, device =
    pcall(require, "device")

local M = {}

local VERSION = 3
local FILE_NAME =
    "/.tangara_sort_preferences.json"

local state = {}
local loaded = false

local function text_key(value)
    if type(value) ~= "string" then
        return ""
    end

    return value:lower()
end

local function date_key(item)
    if type(item) ~= "table" then
        return ""
    end

    -- A durable companion download request records when the album was added
    -- to this Tangara. Keep that device-side recency above Jellyfin's source
    -- DateCreated so Local -> New means "new on this device".
    local local_downloaded =
        item.local_downloaded_at

    if type(local_downloaded) == "number" then
        return "2:" .. string.format(
            "%020.0f",
            local_downloaded
        )
    end

    if type(local_downloaded) == "string" and
        local_downloaded ~= "" then
        return "2:" .. local_downloaded
    end

    local value =
        item.local_added_at or
        item.downloaded_at or
        item.date_created

    if type(value) ~= "string" or
        value == "" then
        return ""
    end

    return "1:" .. value
end

local function sort_kind(key, explicit)
    if explicit == "artists" or
        explicit == "albums" or
        explicit == "tracks" then
        return explicit
    end

    if key == "artists" then
        return "artists"
    end

    if key == "tracks" or
        key == "favorites" or
        tostring(key):match(
            "^playlist:"
        ) then
        return "tracks"
    end

    return "albums"
end

local function default_entry(
    key,
    kind
)
    local category =
        sort_kind(key, kind)

    if category == "artists" then
        return {
            method = "alpha",
            descending = false,
            alpha_descending = false,
            recent_descending = true,
        }
    end

    return {
        method = "recent",
        descending = true,
        alpha_descending = false,
        recent_descending = true,
    }
end

local function display_key(
    kind,
    item
)
    if kind == "artists" then
        return text_key(item.name)
    end

    if kind == "albums" then
        return text_key(item.name) ..
            "\0" ..
            text_key(item.artist)
    end

    return text_key(item.title) ..
        "\0" ..
        text_key(item.artist)
end

local function copy_items(items)
    local copied = {}

    for _, item in ipairs(
        items or {}
    ) do
        table.insert(
            copied,
            item
        )
    end

    return copied
end

local function storage_paths()
    if not device_ok or
        type(device) ~= "table" or
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

    root = root:gsub("/+$", "")

    local path = root .. FILE_NAME

    return {
        path = path,
        temporary = path .. ".tmp",
        backup = path .. ".bak",
    }
end

local function valid_entry(entry)
    return type(entry) == "table" and
        (
            entry.method == "alpha" or
            entry.method == "recent"
        ) and
        type(entry.descending) ==
            "boolean"
end

local function direction_for(
    entry,
    method
)
    local field =
        method == "recent" and
            "recent_descending" or
            "alpha_descending"

    if type(entry[field]) ==
            "boolean" then
        return entry[field]
    end

    if entry.method == method and
        type(entry.descending) ==
            "boolean" then
        return entry.descending
    end

    return method == "recent"
end

local function normalize_entry(entry)
    local alpha_descending =
        direction_for(
            entry,
            "alpha"
        )

    local recent_descending =
        direction_for(
            entry,
            "recent"
        )

    return {
        method = entry.method,
        descending =
            entry.method == "recent" and
                recent_descending or
                alpha_descending,
        alpha_descending =
            alpha_descending,
        recent_descending =
            recent_descending,
    }
end

local function load_state()
    if loaded then
        return
    end

    loaded = true

    local paths =
        storage_paths()

    if not paths then
        return
    end

    local file =
        io.open(
            paths.path,
            "rb"
        )

    if not file then
        return
    end

    local contents =
        file:read("*a")

    file:close()

    local ok, decoded =
        pcall(
            json.decode,
            contents
        )

    if not ok or
        type(decoded) ~= "table" or
        (
            decoded.version ~= 1 and
            decoded.version ~= 2 and
            decoded.version ~= VERSION
        ) or
        type(decoded.preferences) ~=
            "table" then
        return
    end

    for key, entry in pairs(
        decoded.preferences
    ) do
        if type(key) == "string" and
            valid_entry(entry) then
            state[key] =
                normalize_entry(entry)
        end
    end
end

local function encoded_state()
    local ok, contents =
        pcall(
            json_encode.encode,
            {
                version = VERSION,
                preferences = state,
            }
        )

    if not ok or
        type(contents) ~= "string" or
        contents == "" then
        return nil,
            tostring(contents)
    end

    return contents
end

local function save_state()
    local paths =
        storage_paths()

    if not paths then
        return true
    end

    local contents,
        encode_error =
        encoded_state()

    if not contents then
        return false,
            encode_error
    end

    local file,
        open_error =
        io.open(
            paths.temporary,
            "wb"
        )

    if not file then
        return false,
            open_error
    end

    local written,
        write_error =
        file:write(contents)

    if written then
        file:flush()
    end

    file:close()

    if not written then
        os.remove(
            paths.temporary
        )
        return false,
            write_error
    end

    os.remove(paths.backup)

    local existing =
        io.open(
            paths.path,
            "rb"
        )

    if existing then
        existing:close()

        local backed_up,
            backup_error =
            os.rename(
                paths.path,
                paths.backup
            )

        if not backed_up then
            os.remove(
                paths.temporary
            )
            return false,
                backup_error
        end
    end

    local promoted,
        promote_error =
        os.rename(
            paths.temporary,
            paths.path
        )

    if not promoted then
        os.rename(
            paths.backup,
            paths.path
        )
        os.remove(
            paths.temporary
        )
        return false,
            promote_error
    end

    os.remove(paths.backup)

    return true
end

local function key_state(
    key,
    kind
)
    load_state()

    key = tostring(
        key or "tracks"
    )

    if not state[key] then
        state[key] =
            default_entry(
                key,
                kind
            )
    elseif type(
        state[key].alpha_descending
    ) ~= "boolean" or
        type(
            state[key].recent_descending
        ) ~= "boolean" then
        state[key] =
            normalize_entry(
                state[key]
            )
    end

    return state[key]
end

local function allowed_method(
    methods,
    method
)
    for _, value in ipairs(
        methods or {}
    ) do
        if value == method then
            return true
        end
    end

    return false
end

function M.ensure(
    key,
    kind,
    methods
)
    local current =
        key_state(
            key,
            kind
        )

    if allowed_method(
        methods,
        current.method
    ) then
        return M.current(
            key,
            kind
        )
    end

    local fallback =
        methods and methods[1] or
        "alpha"

    current.method = fallback
    current.descending =
        direction_for(
            current,
            fallback
        )

    save_state()

    return M.current(
        key,
        kind
    )
end

function M.current(
    key,
    kind
)
    local current =
        key_state(
            key,
            kind
        )

    return {
        method = current.method,
        descending =
            direction_for(
                current,
                current.method
            ),
        kind =
            sort_kind(
                key,
                kind
            ),
        label =
            M.label(
                key,
                kind
            ),
    }
end

function M.label(
    key,
    kind
)
    local current =
        key_state(
            key,
            kind
        )

    if current.method == "recent" then
        return direction_for(
            current,
            "recent"
        ) and "NEW" or "OLD"
    end

    return direction_for(
        current,
        "alpha"
    ) and "Z-A" or "A-Z"
end

function M.order_label(
    key,
    method,
    kind
)
    local current =
        key_state(
            key,
            kind
        )

    if method == "recent" then
        return direction_for(
            current,
            "recent"
        ) and "NEW" or "OLD"
    end

    return direction_for(
        current,
        "alpha"
    ) and "Z-A" or "A-Z"
end

local function selected_with_save(
    key,
    kind,
    saved,
    save_error
)
    local selected =
        M.current(
            key,
            kind
        )

    selected.save_error =
        saved and nil or
        save_error

    return selected
end

function M.choose(
    key,
    method,
    kind
)
    if method ~= "alpha" and
        method ~= "recent" then
        return nil,
            "invalid sort method"
    end

    local current =
        key_state(
            key,
            kind
        )

    if current.method == method then
        return M.current(
            key,
            kind
        )
    end

    current.method = method
    current.descending =
        direction_for(
            current,
            method
        )

    local saved,
        save_error =
        save_state()

    return selected_with_save(
        key,
        kind,
        saved,
        save_error
    )
end

function M.toggle(
    key,
    method,
    kind
)
    if method ~= "alpha" and
        method ~= "recent" then
        return nil,
            "invalid sort method"
    end

    local current =
        key_state(
            key,
            kind
        )

    local field =
        method == "recent" and
            "recent_descending" or
            "alpha_descending"

    current[field] =
        not direction_for(
            current,
            method
        )

    current.method = method
    current.descending =
        current[field]

    local saved,
        save_error =
        save_state()

    return selected_with_save(
        key,
        kind,
        saved,
        save_error
    )
end

function M.select(
    key,
    method,
    kind
)
    local current =
        key_state(
            key,
            kind
        )

    if current.method == method then
        return M.toggle(
            key,
            method,
            kind
        )
    end

    return M.choose(
        key,
        method,
        kind
    )
end

function M.sort(
    key,
    items,
    kind
)
    local result =
        copy_items(items)

    local current =
        key_state(
            key,
            kind
        )

    local category =
        sort_kind(
            key,
            kind
        )

    table.sort(
        result,
        function(left, right)
            local left_name =
                display_key(
                    category,
                    left
                )

            local right_name =
                display_key(
                    category,
                    right
                )

            if current.method ==
                    "alpha" then
                if left_name ==
                        right_name then
                    local left_date =
                        date_key(left)
                    local right_date =
                        date_key(right)

                    if left_date ==
                            right_date then
                        return tostring(
                            left.id or
                            left.key or ""
                        ) <
                            tostring(
                                right.id or
                                right.key or ""
                            )
                    end

                    return left_date >
                        right_date
                end

                if current.descending then
                    return left_name >
                        right_name
                end

                return left_name <
                    right_name
            end

            local left_date =
                date_key(left)

            local right_date =
                date_key(right)

            if left_date ==
                    right_date then
                if left_name ==
                        right_name then
                    return tostring(
                        left.id or
                        left.key or ""
                    ) <
                        tostring(
                            right.id or
                            right.key or ""
                        )
                end

                return left_name <
                    right_name
            end

            if left_date == "" then
                return false
            end

            if right_date == "" then
                return true
            end

            if current.descending then
                return left_date >
                    right_date
            end

            return left_date <
                right_date
        end
    )

    return result
end

function M.newest_added(items)
    local result =
        copy_items(items)

    table.sort(
        result,
        function(left, right)
            local left_date =
                date_key(left)

            local right_date =
                date_key(right)

            if left_date ==
                    right_date then
                return display_key(
                    "tracks",
                    left
                ) <
                    display_key(
                        "tracks",
                        right
                    )
            end

            if left_date == "" then
                return false
            end

            if right_date == "" then
                return true
            end

            return left_date >
                right_date
        end
    )

    return result
end

function M.reset_for_test()
    state = {}
    loaded = false
end

return M

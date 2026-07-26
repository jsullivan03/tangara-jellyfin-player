local device = require("device")
local json = require("json")
local json_encode = require("json_encode")

local M = {}

local version = 1
local file_name =
    "/.tangara_jellyfin_library.json"

local function copy_value(value)
    if type(value) ~= "table" then
        return value
    end

    local copied = {}

    for key, child in pairs(value) do
        copied[copy_value(key)] =
            copy_value(child)
    end

    return copied
end

local function current_seconds()
    if os and type(os.time) == "function" then
        local ok, value = pcall(os.time)

        if ok and type(value) == "number" then
            return value
        end
    end

    return 0
end

local function storage_paths()
    local root, root_error =
        device.storage_root()

    if type(root) ~= "string" or root == "" then
        return nil,
            root_error or
            "storage root is unavailable"
    end

    root = root:gsub("/+$", "")

    local path = root .. file_name

    return {
        path = path,
        temporary = path .. ".tmp",
        backup = path .. ".bak",
    }
end

local function read_file(path)
    local file = io.open(path, "rb")

    if not file then
        return nil
    end

    local contents = file:read("*a")
    file:close()

    return contents
end

local function write_file(path, contents)
    local file, open_error =
        io.open(path, "wb")

    if not file then
        return false, open_error
    end

    local wrote, write_error =
        file:write(contents)

    if wrote then
        file:flush()
    end

    file:close()

    if not wrote then
        return false, write_error
    end

    return true
end

local function valid_track(track)
    return type(track) == "table" and
        type(track.id) == "string" and
        track.id ~= ""
end

local function valid_tracks(items)
    if type(items) ~= "table" then
        return false
    end

    for _, track in ipairs(items) do
        if not valid_track(track) then
            return false
        end
    end

    return true
end

local function valid_collection(collection)
    return type(collection) == "table" and
        type(collection.name) == "string" and
        type(collection.revision) == "string" and
        valid_tracks(collection.items)
end

local function validate_library(library)
    if type(library) ~= "table" then
        return nil,
            "library cache root is invalid"
    end

    if type(library.revision) ~= "string" then
        return nil,
            "library revision is invalid"
    end

    if type(library.user) ~= "table" or
        type(library.user.id) ~= "string" or
        type(library.user.name) ~= "string" then
        return nil,
            "library user is invalid"
    end

    if not valid_collection(
        library.favorites
    ) then
        return nil,
            "favorites cache is invalid"
    end

    if type(library.playlists) ~= "table" then
        return nil,
            "playlist cache is invalid"
    end

    local playlist_ids = {}

    for _, playlist in ipairs(
        library.playlists
    ) do
        if not valid_collection(playlist) or
            type(playlist.id) ~= "string" or
            playlist.id == "" then
            return nil,
                "playlist cache entry is invalid"
        end

        if playlist_ids[playlist.id] then
            return nil,
                "playlist cache contains duplicate IDs"
        end

        playlist_ids[playlist.id] = true
    end

    return copy_value(library)
end

local function decode_state(contents)
    if type(contents) ~= "string" or
        contents == "" then
        return nil,
            "library cache file is empty"
    end

    local ok, state =
        pcall(json.decode, contents)

    if not ok or type(state) ~= "table" then
        return nil,
            "library cache JSON is invalid"
    end

    if state.version ~= version then
        return nil,
            "library cache version is unsupported"
    end

    local library, validation_error =
        validate_library(state.library)

    if not library then
        return nil, validation_error
    end

    return {
        version = version,
        saved_at =
            type(state.saved_at) == "number"
                and state.saved_at
                or 0,
        library = library,
    }
end

local function encode_state(state)
    local ok, contents =
        pcall(json_encode.encode, state)

    if not ok then
        return nil, tostring(contents)
    end

    if type(contents) ~= "string" or
        contents == "" then
        return nil,
            "library cache encoding failed"
    end

    return contents
end

local function save_state(state)
    local paths, path_error =
        storage_paths()

    if not paths then
        return false, path_error
    end

    local contents, encode_error =
        encode_state(state)

    if not contents then
        return false, encode_error
    end

    local wrote, write_error =
        write_file(
            paths.temporary,
            contents
        )

    if not wrote then
        return false, write_error
    end

    os.remove(paths.backup)

    local existing = io.open(
        paths.path,
        "rb"
    )

    if existing then
        existing:close()

        local backed_up, backup_error =
            os.rename(
                paths.path,
                paths.backup
            )

        if not backed_up then
            os.remove(paths.temporary)
            return false, backup_error
        end
    end

    local replaced, replace_error =
        os.rename(
            paths.temporary,
            paths.path
        )

    if not replaced then
        os.rename(
            paths.backup,
            paths.path
        )

        os.remove(paths.temporary)

        return false, replace_error
    end

    os.remove(paths.backup)

    return true
end

function M.empty()
    return {
        revision = "",
        generated_at = 0,
        user = {
            id = "",
            name = "",
        },
        favorites = {
            name = "Favorites",
            revision = "",
            track_count = 0,
            keep_downloaded = false,
            items = {},
        },
        playlists = {},
    }
end

function M.save(library)
    local validated, validation_error =
        validate_library(library)

    if not validated then
        return false, validation_error
    end

    return save_state({
        version = version,
        saved_at = current_seconds(),
        library = validated,
    })
end

function M.load()
    local paths, path_error =
        storage_paths()

    if not paths then
        return nil, false, path_error
    end

    local candidates = {
        paths.path,
        paths.backup,
        paths.temporary,
    }

    local found = false
    local errors = {}

    for index, path in ipairs(candidates) do
        local contents = read_file(path)

        if contents ~= nil then
            found = true

            local state, decode_error =
                decode_state(contents)

            if state then
                local recovered = index ~= 1

                if recovered then
                    local saved, save_error =
                        save_state(state)

                    if not saved then
                        return nil,
                            false,
                            save_error
                    end
                end

                return state.library,
                    recovered,
                    nil,
                    state.saved_at
            end

            table.insert(
                errors,
                decode_error
            )
        end
    end

    if found then
        return nil,
            false,
            "library cache is corrupted: " ..
            table.concat(errors, "; ")
    end

    return nil, false, nil
end

function M.load_or_empty()
    local library, recovered, load_error,
        saved_at = M.load()

    if library then
        return library,
            recovered,
            nil,
            saved_at
    end

    if load_error then
        return nil,
            false,
            load_error,
            0
    end

    return M.empty(), false, nil, 0
end

function M.paths()
    return storage_paths()
end

return M

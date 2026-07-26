local device = require("device")
local json = require("json")
local json_encode = require("json_encode")

local M = {}

local version = 1
local maximum_operations = 1000
local file_name =
    "/.tangara_sync_operations.json"

local supported_operations = {
    create_playlist = true,
    rename_playlist = true,
    delete_playlist = true,
    add_playlist_item = true,
    remove_playlist_item = true,
    move_playlist_item = true,
    set_favorite = true,
}

local function is_integer(value)
    return type(value) == "number" and
        value >= 0 and
        value == math.floor(value)
end

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

local function hash_text(text)
    local first = 5381
    local second = 52711

    for index = 1, #text do
        local byte = text:byte(index)

        first = (
            first * 33 + byte
        ) % 2147483647

        second = (
            second * 65599 + byte
        ) % 2147483629
    end

    return string.format(
        "%08x%08x",
        first,
        second
    )
end

local function client_id()
    local identity = ""

    if type(device.id) == "function" then
        local ok, value = pcall(device.id)

        if ok and type(value) == "string" then
            identity = value
        end
    end

    local seconds = 0

    if os and type(os.time) == "function" then
        local ok, value = pcall(os.time)

        if ok and type(value) == "number" then
            seconds = value
        end
    end

    return hash_text(table.concat({
        identity,
        tostring(seconds),
        tostring({}),
        tostring(math.random()),
    }, ":"))
end

local function default_state()
    return {
        version = version,
        client_id = client_id(),
        next_sequence = 1,
        operations = {},
        playlist_aliases = {},
    }
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

local function valid_failure(failure)
    if failure == nil then
        return true
    end

    return type(failure) == "table" and
        type(failure.message) == "string" and
        type(failure.retriable) == "boolean"
end

local function valid_operation(operation)
    if type(operation) ~= "table" then
        return false
    end

    if type(operation.id) ~= "string" or
        operation.id == "" then
        return false
    end

    if not supported_operations[
        operation.type
    ] then
        return false
    end

    if type(operation.data) ~= "table" then
        return false
    end

    return valid_failure(operation.failure)
end

local function decode_state(contents)
    if type(contents) ~= "string" or
        contents == "" then
        return nil, "queue file is empty"
    end

    local ok, state =
        pcall(json.decode, contents)

    if not ok or type(state) ~= "table" then
        return nil, "queue JSON is invalid"
    end

    if state.version ~= version then
        return nil,
            "queue version is unsupported"
    end

    if type(state.client_id) ~= "string" or
        state.client_id == "" then
        return nil,
            "queue client ID is invalid"
    end

    if not is_integer(state.next_sequence) or
        state.next_sequence < 1 then
        return nil,
            "queue sequence is invalid"
    end

    if type(state.operations) ~= "table" then
        return nil,
            "queue operations are invalid"
    end

    if #state.operations >
        maximum_operations then
        return nil,
            "queue contains too many operations"
    end

    local operations = {}

    for _, operation in ipairs(
        state.operations
    ) do
        if not valid_operation(operation) then
            return nil,
                "queue contains an invalid operation"
        end

        table.insert(
            operations,
            copy_value(operation)
        )
    end

    local aliases = {}

    if state.playlist_aliases ~= nil then
        if type(state.playlist_aliases)
            ~= "table" then
            return nil,
                "playlist aliases are invalid"
        end

        for local_id, jellyfin_id in pairs(
            state.playlist_aliases
        ) do
            if type(local_id) ~= "string" or
                type(jellyfin_id) ~= "string" then
                return nil,
                    "playlist alias is invalid"
            end

            aliases[local_id] = jellyfin_id
        end
    end

    return {
        version = version,
        client_id = state.client_id,
        next_sequence =
            state.next_sequence,
        operations = operations,
        playlist_aliases = aliases,
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
            "queue JSON encoding failed"
    end

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

local function load_state()
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

                return state, recovered
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
            "operation queue is corrupted: " ..
            table.concat(errors, "; ")
    end

    return default_state(), false
end

local function next_sequence(state)
    local sequence = state.next_sequence
    state.next_sequence = sequence + 1

    return sequence
end

local function operation_id(
    state,
    sequence
)
    return table.concat({
        "op",
        state.client_id,
        tostring(sequence),
    }, ":")
end

local function local_playlist_id(
    state,
    sequence
)
    return table.concat({
        "local",
        state.client_id,
        tostring(sequence),
    }, ":")
end

local function require_string(
    value,
    name
)
    if type(value) ~= "string" or
        value == "" then
        return nil,
            name .. " must be a non-empty string"
    end

    return value
end

local function string_list(values, name)
    if values == nil then
        return {}
    end

    if type(values) ~= "table" then
        return nil,
            name .. " must be an array"
    end

    local copied = {}

    for _, value in ipairs(values) do
        if type(value) ~= "string" or
            value == "" then
            return nil,
                name ..
                " must contain non-empty strings"
        end

        table.insert(copied, value)
    end

    return copied
end

local function enqueue(
    operation_type,
    data,
    prepare
)
    if not supported_operations[
        operation_type
    ] then
        return nil,
            "unsupported operation type"
    end

    if type(data) ~= "table" then
        return nil,
            "operation data must be a table"
    end

    local state, _, load_error =
        load_state()

    if not state then
        return nil, load_error
    end

    if #state.operations >=
        maximum_operations then
        return nil,
            "operation queue is full"
    end

    local sequence =
        next_sequence(state)

    if prepare then
        local prepared, prepare_error =
            prepare(
                state,
                sequence,
                copy_value(data)
            )

        if not prepared then
            return nil, prepare_error
        end

        data = prepared
    else
        data = copy_value(data)
    end

    local operation = {
        id = operation_id(
            state,
            sequence
        ),
        type = operation_type,
        data = data,
    }

    table.insert(
        state.operations,
        operation
    )

    local saved, save_error =
        save_state(state)

    if not saved then
        return nil, save_error
    end

    return copy_value(operation)
end

function M.enqueue_create_playlist(
    name,
    item_ids
)
    name = require_string(
        name,
        "playlist name"
    )

    if not name then
        return nil,
            "playlist name must be a non-empty string"
    end

    local items, items_error =
        string_list(
            item_ids,
            "item_ids"
        )

    if not items then
        return nil, items_error
    end

    local operation, enqueue_error =
        enqueue(
            "create_playlist",
            {
                name = name,
                item_ids = items,
            },
            function(state, sequence, data)
                data.local_playlist_id =
                    local_playlist_id(
                        state,
                        sequence
                    )

                return data
            end
        )

    if not operation then
        return nil, enqueue_error
    end

    return operation.data.local_playlist_id,
        operation
end

function M.enqueue_rename_playlist(
    playlist_id,
    name
)
    local valid_playlist, playlist_error =
        require_string(
            playlist_id,
            "playlist_id"
        )

    if not valid_playlist then
        return nil, playlist_error
    end

    local valid_name, name_error =
        require_string(
            name,
            "playlist name"
        )

    if not valid_name then
        return nil, name_error
    end

    return enqueue(
        "rename_playlist",
        {
            playlist_id = valid_playlist,
            name = valid_name,
        }
    )
end

function M.enqueue_delete_playlist(
    playlist_id
)
    local valid, validation_error =
        require_string(
            playlist_id,
            "playlist_id"
        )

    if not valid then
        return nil, validation_error
    end

    return enqueue(
        "delete_playlist",
        {
            playlist_id = valid,
        }
    )
end

function M.enqueue_add_playlist_item(
    playlist_id,
    item_id
)
    local valid_playlist, playlist_error =
        require_string(
            playlist_id,
            "playlist_id"
        )

    if not valid_playlist then
        return nil, playlist_error
    end

    local valid_item, item_error =
        require_string(
            item_id,
            "item_id"
        )

    if not valid_item then
        return nil, item_error
    end

    return enqueue(
        "add_playlist_item",
        {
            playlist_id = valid_playlist,
            item_id = valid_item,
        }
    )
end

function M.enqueue_remove_playlist_item(
    playlist_id,
    entry_id
)
    local valid_playlist, playlist_error =
        require_string(
            playlist_id,
            "playlist_id"
        )

    if not valid_playlist then
        return nil, playlist_error
    end

    local valid_entry, entry_error =
        require_string(
            entry_id,
            "entry_id"
        )

    if not valid_entry then
        return nil, entry_error
    end

    return enqueue(
        "remove_playlist_item",
        {
            playlist_id = valid_playlist,
            entry_id = valid_entry,
        }
    )
end

function M.enqueue_move_playlist_item(
    playlist_id,
    entry_id,
    new_index
)
    local valid_playlist, playlist_error =
        require_string(
            playlist_id,
            "playlist_id"
        )

    if not valid_playlist then
        return nil, playlist_error
    end

    local valid_entry, entry_error =
        require_string(
            entry_id,
            "entry_id"
        )

    if not valid_entry then
        return nil, entry_error
    end

    if not is_integer(new_index) then
        return nil,
            "new_index must be a non-negative integer"
    end

    return enqueue(
        "move_playlist_item",
        {
            playlist_id = valid_playlist,
            entry_id = valid_entry,
            new_index = new_index,
        }
    )
end

function M.enqueue_set_favorite(
    item_id,
    favorite
)
    local valid_item, item_error =
        require_string(
            item_id,
            "item_id"
        )

    if not valid_item then
        return nil, item_error
    end

    if type(favorite) ~= "boolean" then
        return nil,
            "favorite must be a boolean"
    end

    return enqueue(
        "set_favorite",
        {
            item_id = valid_item,
            favorite = favorite,
        }
    )
end

local function queue_status(state, recovered)
    local first = state.operations[1]
    local failure =
        first and first.failure or nil
    local blocked =
        failure ~= nil and
        failure.retriable == false

    return {
        pending = #state.operations,
        blocked = blocked,
        error =
            failure and failure.message
            or nil,
        error_code =
            failure and failure.code
            or nil,
        recovered = recovered == true,
        client_id = state.client_id,
        next_sequence =
            state.next_sequence,
        playlist_aliases =
            copy_value(
                state.playlist_aliases
            ),
    }
end

function M.status()
    local state, recovered, load_error =
        load_state()

    if not state then
        return {
            pending = 0,
            blocked = true,
            error = load_error,
            recovered = false,
        }, load_error
    end

    return queue_status(
        state,
        recovered
    )
end

function M.batch(limit)
    limit = limit or 25

    if not is_integer(limit) or limit < 1 then
        return nil,
            "batch limit must be a positive integer"
    end

    local state, recovered, load_error =
        load_state()

    if not state then
        return nil, load_error
    end

    local status =
        queue_status(state, recovered)

    if status.blocked then
        return nil,
            status.error or
            "operation queue is blocked",
            status
    end

    local batch = {}

    for index = 1, math.min(
        limit,
        #state.operations
    ) do
        local operation =
            copy_value(
                state.operations[index]
            )

        operation.failure = nil

        table.insert(batch, operation)
    end

    return batch, nil, status
end

local function applied_alias(
    state,
    operation,
    result
)
    if operation.type ==
        "create_playlist" then
        local local_id =
            result.local_playlist_id or
            operation.data.local_playlist_id

        local jellyfin_id =
            result.playlist_id

        if type(local_id) == "string" and
            type(jellyfin_id) == "string" then
            state.playlist_aliases[
                local_id
            ] = jellyfin_id
        end
    elseif operation.type ==
        "delete_playlist" then
        local reference =
            operation.data.playlist_id
        local permanent =
            result.playlist_id

        if type(reference) == "string" then
            state.playlist_aliases[
                reference
            ] = nil
        end

        if type(permanent) == "string" then
            for local_id, jellyfin_id in pairs(
                state.playlist_aliases
            ) do
                if jellyfin_id == permanent then
                    state.playlist_aliases[
                        local_id
                    ] = nil
                end
            end
        end
    end
end

function M.apply_results(
    batch,
    results
)
    if type(batch) ~= "table" or
        type(results) ~= "table" then
        return nil,
            "operation results are invalid"
    end

    local state, _, load_error =
        load_state()

    if not state then
        return nil, load_error
    end

    local applied = 0
    local failed = nil
    local changed = false

    for index, result in ipairs(results) do
        local expected = batch[index]
        local current = state.operations[1]

        if not expected or not current then
            break
        end

        if current.id ~= expected.id or
            type(result) ~= "table" or
            result.id ~= expected.id then
            break
        end

        if result.status == "applied" then
            applied_alias(
                state,
                current,
                type(result.result) == "table"
                    and result.result
                    or {}
            )

            table.remove(
                state.operations,
                1
            )

            applied = applied + 1
            changed = true
        elseif result.status == "failed" then
            local error_value =
                type(result.error) == "table"
                    and result.error
                    or {}

            current.failure = {
                code =
                    type(error_value.code)
                        == "string"
                        and error_value.code
                        or "operation_failed",
                message =
                    type(error_value.message)
                        == "string"
                        and error_value.message
                        or "operation failed",
                retriable =
                    error_value.retriable == true,
            }

            failed = copy_value(
                current.failure
            )

            changed = true
            break
        else
            break
        end
    end

    if changed then
        local saved, save_error =
            save_state(state)

        if not saved then
            return nil, save_error
        end
    end

    local status =
        queue_status(state, false)

    return {
        applied = applied,
        failed = failed,
        pending = status.pending,
        blocked = status.blocked,
        error = status.error,
    }
end

function M.mark_failure(
    operation_id,
    failure
)
    if type(operation_id) ~= "string" or
        type(failure) ~= "table" or
        type(failure.message) ~= "string" or
        type(failure.retriable) ~= "boolean" then
        return false,
            "operation failure is invalid"
    end

    local state, _, load_error =
        load_state()

    if not state then
        return false, load_error
    end

    local first = state.operations[1]

    if not first or
        first.id ~= operation_id then
        return false,
            "operation is no longer first in the queue"
    end

    first.failure = {
        code =
            type(failure.code) == "string"
                and failure.code
                or "request_failed",
        message = failure.message,
        retriable = failure.retriable,
    }

    return save_state(state)
end

function M.clear_failure(operation_id)
    local state, _, load_error =
        load_state()

    if not state then
        return false, load_error
    end

    local first = state.operations[1]

    if not first or
        first.id ~= operation_id then
        return false,
            "operation was not found"
    end

    first.failure = nil

    return save_state(state)
end

function M.resolve_playlist_id(
    playlist_id
)
    local state, _, load_error =
        load_state()

    if not state then
        return nil, load_error
    end

    return state.playlist_aliases[
        playlist_id
    ] or playlist_id
end

function M.snapshot()
    local state, recovered, load_error =
        load_state()

    if not state then
        return nil, load_error
    end

    return {
        operations =
            copy_value(state.operations),
        playlist_aliases =
            copy_value(
                state.playlist_aliases
            ),
        client_id = state.client_id,
        next_sequence =
            state.next_sequence,
        recovered = recovered == true,
    }
end

function M.paths()
    return storage_paths()
end

return M

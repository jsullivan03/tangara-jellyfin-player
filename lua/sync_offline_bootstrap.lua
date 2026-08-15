local device = require("device")
local device_identity = require("device_identity")
local json = require("json")
local json_encode = require("json_encode")
local sync_client = require("sync_client")
local time = require("time")

local M = {}

local owner = "sync_offline_bootstrap"
local active = nil
local completed_signatures = {}
local last_result = nil
local next_attempt_at = 0
local retry_interval_ms = 15000
local state_file_name =
    "/.tangara_offline_bootstrap_state"
local persisted_state_loaded = false
local persisted_initial_complete = false
local persisted_signature = nil

local function stable_track_id(item)
    if type(item) ~= "table" then
        return nil
    end

    local value = item.jellyfin_id or item.id

    if type(value) ~= "string" or value == "" then
        return nil
    end

    return value
end

local function collect_track_ids(library)
    local seen = {}
    local ids = {}

    local function add(item)
        local id = stable_track_id(item)

        if id and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end

    local favorites =
        type(library) == "table" and
        library.favorites or nil

    for _, item in ipairs(
        type(favorites) == "table" and
        favorites.items or {}
    ) do
        add(item)
    end

    for _, playlist in ipairs(
        type(library) == "table" and
        library.playlists or {}
    ) do
        for _, item in ipairs(
            type(playlist) == "table" and
            playlist.items or {}
        ) do
            add(item)
        end
    end

    table.sort(ids)
    return ids
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

local function state_path()
    local root, root_error =
        device.storage_root()

    if type(root) ~= "string" or root == "" then
        return nil,
            root_error or
            "storage root is unavailable"
    end

    return root:gsub("/+$", "") ..
        state_file_name
end

local function load_persisted_state()
    if persisted_state_loaded then
        return
    end

    persisted_state_loaded = true

    local path = state_path()

    if not path then
        return
    end

    local file = io.open(path, "rb")

    if not file then
        return
    end

    local signature = file:read("*l")
    file:close()

    if type(signature) == "string" and
        signature ~= "" then
        persisted_initial_complete = true
        persisted_signature = signature
    end
end

local function save_persisted_state(signature)
    local path, path_error = state_path()

    if not path then
        return false, path_error
    end

    local temporary = path .. ".tmp"
    local file, open_error =
        io.open(temporary, "wb")

    if not file then
        return false,
            open_error or
            "offline bootstrap state could not be opened"
    end

    file:write(tostring(signature or "complete"))
    file:write("\n")
    file:close()

    local renamed, rename_error =
        os.rename(temporary, path)

    if not renamed then
        os.remove(temporary)
        return false,
            rename_error or
            "offline bootstrap state could not be saved"
    end

    persisted_state_loaded = true
    persisted_initial_complete = true
    persisted_signature =
        tostring(signature or "complete")

    return true
end

local function signature_for_ids(ids)
    return hash_text(table.concat(ids, "\n"))
end

local function decoded_body(response)
    local ok, payload =
        pcall(
            json.decode,
            response.body or ""
        )

    if ok and type(payload) == "table" then
        return payload
    end

    return nil
end

function M.start(library)
    if active then
        return false,
            "offline bootstrap is already active"
    end

    if sync_client.busy() or
        time.ticks() < next_attempt_at then
        return false, nil
    end

    load_persisted_state()

    local ids = collect_track_ids(library)

    if #ids == 0 then
        if not persisted_initial_complete then
            save_persisted_state("empty")
        end

        return false, nil
    end

    local signature = signature_for_ids(ids)

    if completed_signatures[signature] then
        return false, nil
    end

    local path, path_error =
        device_identity
            .download_requests_path()

    if not path then
        return false, path_error
    end

    local device_id =
        device_identity.id()
    local body =
        json_encode.encode {
            kind = "selection",
            jellyfin_item_ids = ids,
            idempotency_key =
                tostring(device_id) ..
                ":offline-selection:" ..
                signature,
        }

    local started, start_error =
        sync_client.post(
            path,
            body,
            owner
        )

    if not started then
        return false, start_error
    end

    active = {
        signature = signature,
        track_count = #ids,
        ids = ids,
        initial = not persisted_initial_complete,
    }
    last_result = nil

    return true
end

function M.busy()
    return active ~= nil
end

function M.poll()
    if not active then
        return nil
    end

    local response =
        sync_client.poll(owner)

    if not response then
        return nil
    end

    local context = active
    active = nil

    local payload = decoded_body(response)
    local status = tonumber(response.status) or 0
    local accepted = response.ok == true or
        (
            status == 409 and
            type(payload) == "table" and
            payload.code ==
                "already_downloaded_or_queued"
        )

    local result = {
        ok = accepted,
        status = status,
        track_count = context.track_count,
        payload = payload,
        signature = context.signature,
        ids = context.ids,
        initial = context.initial,
        error = accepted and nil or
            (
                type(payload) == "table" and
                payload.error or
                response.error or
                (
                    "HTTP status " ..
                    tostring(response.status)
                )
            ),
    }

    if accepted then
        completed_signatures[
            context.signature
        ] = true
        next_attempt_at = 0
    else
        next_attempt_at =
            time.ticks() + retry_interval_ms
    end

    last_result = result
    return result
end

function M.initial_sync_complete()
    load_persisted_state()
    return persisted_initial_complete,
        persisted_signature
end

function M.initial_sync_required(library)
    load_persisted_state()

    if persisted_initial_complete then
        return false, persisted_signature
    end

    local ids = collect_track_ids(library)

    if #ids == 0 then
        save_persisted_state("empty")
        return false, "empty"
    end

    return true, signature_for_ids(ids)
end

function M.mark_initial_sync_complete(signature)
    load_persisted_state()

    if persisted_initial_complete then
        return true
    end

    return save_persisted_state(
        signature or "complete"
    )
end

function M.last_result()
    return last_result
end

function M.reset()
    active = nil
    completed_signatures = {}
    last_result = nil
    next_attempt_at = 0
end

return M

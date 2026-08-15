local device_identity =
    require("device_identity")
local index_generation =
    require(
        "jellyfin_local_index_generation"
    )
local jellyfin_local_index =
    require("jellyfin_local_index")
local json = require("json")
local json_encode = require("json_encode")
local sync_client = require("sync_client")

local M = {}

local owner = "sync_inventory_report"
local active = false

local function copy_failure(failure)
    if type(failure) ~= "table" then
        return nil
    end

    local item =
        failure.item or
        (
            failure.failed_action and
            failure.failed_action.item
        )
    local jellyfin_id =
        type(item) == "table" and
        (
            item.jellyfin_id or
            item.id
        ) or
        failure.jellyfin_id

    if type(jellyfin_id) ~= "string" or
        jellyfin_id == "" then
        return nil
    end

    return {
        jellyfin_id = jellyfin_id,
        code =
            failure.code or
            "download_failed",
        message =
            failure.error or
            "Download failed",
        retryable =
            failure.retryable ~= false,
    }
end

function M.payload(
    active_download,
    failure
)
    local library, library_error =
        jellyfin_local_index.load()

    if not library then
        return nil, library_error
    end

    local generation =
        index_generation.snapshot()
    local items = {}

    for _, track in ipairs(
        library.tracks or {}
    ) do
        items[#items + 1] = {
            jellyfin_id =
                track.jellyfin_id or
                track.id,
            local_path =
                track.local_path or "",
            size_bytes =
                type(track.source_item) ==
                    "table" and
                track.source_item
                    .size_bytes or
                nil,
        }
    end

    table.sort(
        items,
        function(left, right)
            return left.jellyfin_id <
                right.jellyfin_id
        end
    )

    local active_payload = nil

    if type(active_download) == "table" then
        local action =
            active_download.action or
            active_download
        local item =
            type(action) == "table" and
            action.item or nil
        local jellyfin_id =
            type(item) == "table" and
            (
                item.jellyfin_id or
                item.id
            ) or nil

        if type(jellyfin_id) == "string" and
            jellyfin_id ~= "" then
            active_payload = {
                jellyfin_id = jellyfin_id,
                bytes =
                    tonumber(
                        active_download.bytes
                    ) or 0,
                total_bytes =
                    tonumber(
                        active_download
                            .bytes_total
                    ) or 0,
            }
        end
    end

    local failures = {}
    local normalized_failure =
        copy_failure(failure)

    if normalized_failure then
        failures[1] =
            normalized_failure
    end

    return {
        revision =
            tostring(
                generation.generation or 0
            ) ..
            ":" ..
            tostring(#items),
        generated_at =
            tostring(
                generation.generation or 0
            ),
        items = items,
        active = active_payload,
        failures = failures,
    }
end

function M.start(
    active_download,
    failure
)
    if active or sync_client.busy() then
        return false,
            "sync request is already active"
    end

    local payload, payload_error =
        M.payload(
            active_download,
            failure
        )

    if not payload then
        return false, payload_error
    end

    local path, path_error =
        device_identity.inventory_path()

    if not path then
        return false, path_error
    end

    local started, start_error =
        sync_client.put(
            path,
            json_encode.encode(payload),
            owner
        )

    if not started then
        return false, start_error
    end

    active = true
    return true
end

function M.busy()
    return active
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

    active = false

    local ok, payload =
        pcall(
            json.decode,
            response.body or ""
        )

    if not response.ok then
        return {
            ok = false,
            status = response.status,
            error =
                ok and payload.error or
                response.error or
                "inventory report failed",
        }
    end

    return {
        ok = true,
        status = response.status,
        payload =
            ok and payload or nil,
    }
end

return M

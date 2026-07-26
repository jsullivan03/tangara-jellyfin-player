local device_identity = require("device_identity")
local json = require("json")
local json_encode = require("json_encode")
local sync_client = require("sync_client")
local sync_operation_queue =
    require("sync_operation_queue")

local M = {}

local owner = "sync_operation_flush"
local active_batch = nil

local function decode_body(body)
    if type(body) ~= "string" or
        body == "" then
        return nil,
            "server returned an empty response"
    end

    local ok, payload =
        pcall(json.decode, body)

    if not ok or type(payload) ~= "table" then
        return nil,
            "server returned invalid JSON"
    end

    return payload
end

local function encode_body(batch)
    local ok, body = pcall(
        json_encode.encode,
        {
            operations = batch,
        }
    )

    if not ok or type(body) ~= "string" then
        return nil,
            "operation request encoding failed"
    end

    return body
end

local function response_failure(
    response,
    payload
)
    local retriable =
        response.status == 0 or
        response.status == 408 or
        response.status == 429 or
        response.status >= 500

    if payload and
        payload.link_required == true then
        retriable = true
    end

    return {
        code =
            payload and payload.code
            or "operation_request_failed",
        message =
            payload and payload.error
            or response.error
            or (
                "HTTP status " ..
                tostring(response.status)
            ),
        retriable = retriable,
    }
end

function M.start(limit)
    if active_batch ~= nil or
        sync_client.busy(owner) then
        return false,
            "operation upload is already active"
    end

    if sync_client.busy() then
        return false,
            "HTTP request already in progress"
    end

    local batch, batch_error, status =
        sync_operation_queue.batch(
            limit or 25
        )

    if not batch then
        return false, batch_error, status
    end

    if #batch == 0 then
        return false,
            "operation queue is empty",
            status
    end

    local path, path_error =
        device_identity.operations_path()

    if not path then
        return false, path_error, status
    end

    local body, body_error =
        encode_body(batch)

    if not body then
        return false, body_error, status
    end

    local started, start_error =
        sync_client.post(
            path,
            body,
            owner
        )

    if not started then
        return false, start_error, status
    end

    active_batch = batch

    return true
end

function M.busy()
    return active_batch ~= nil or
        sync_client.busy(owner)
end

function M.poll()
    if active_batch == nil then
        return nil
    end

    local response =
        sync_client.poll(owner)

    if response == nil then
        return nil
    end

    local batch = active_batch
    active_batch = nil

    local payload, decode_error =
        decode_body(response.body)

    if not response.ok then
        local failure =
            response_failure(
                response,
                payload
            )

        sync_operation_queue.mark_failure(
            batch[1].id,
            failure
        )

        local status =
            sync_operation_queue.status()

        return {
            ok = false,
            status = response.status,
            error = failure.message,
            retriable = failure.retriable,
            pending = status.pending,
            blocked = status.blocked,
        }
    end

    if not payload or
        type(payload.results) ~= "table" then
        local failure = {
            code = "invalid_server_response",
            message =
                decode_error or
                "server response lacked operation results",
            retriable = true,
        }

        sync_operation_queue.mark_failure(
            batch[1].id,
            failure
        )

        local status =
            sync_operation_queue.status()

        return {
            ok = false,
            status = response.status,
            error = failure.message,
            retriable = true,
            pending = status.pending,
            blocked = status.blocked,
        }
    end

    local summary, apply_error =
        sync_operation_queue.apply_results(
            batch,
            payload.results
        )

    if not summary then
        return {
            ok = false,
            status = response.status,
            error = apply_error,
            retriable = true,
        }
    end

    return {
        ok =
            payload.ok == true and
            summary.failed == nil,
        status = response.status,
        applied = summary.applied,
        pending = summary.pending,
        blocked = summary.blocked,
        error =
            summary.failed and
            summary.failed.message
            or nil,
        retriable =
            summary.failed and
            summary.failed.retriable
            or nil,
        response = payload,
    }
end

return M

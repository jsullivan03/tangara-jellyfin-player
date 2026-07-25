local device_identity = require("device_identity")
local json = require("json")
local sync_client = require("sync_client")
local time = require("time")

local M = {}

local owner = "sync_link"
local poll_interval_ms = 5000

local phase = "idle"
local request_kind = nil
local code = nil
local user = nil
local error_message = nil
local http_status = nil
local started_at = nil
local next_poll_at = 0

local function snapshot()
    local user_copy = nil

    if type(user) == "table" then
        user_copy = {
            id = user.id,
            name = user.name,
        }
    end

    return {
        phase = phase,
        active =
            phase == "starting" or
            phase == "waiting" or
            phase == "polling",
        linked = phase == "linked",
        pending =
            phase == "waiting" or
            phase == "polling",
        code = code,
        user = user_copy,
        error = error_message,
        status = http_status,
        started_at = started_at,
    }
end

local function fail(message, status)
    phase = "error"
    request_kind = nil
    error_message = message
    http_status = status
    next_poll_at = 0

    return snapshot()
end

local function decode_body(body)
    if type(body) ~= "string" or body == "" then
        return nil, "server returned an empty response"
    end

    local ok, payload = pcall(json.decode, body)

    if not ok then
        return nil, tostring(payload)
    end

    if type(payload) ~= "table" then
        return nil, "server response was not an object"
    end

    return payload
end

local function accept_payload(payload, status)
    http_status = status

    if payload.pending == true then
        if type(payload.code) == "string" and
            payload.code ~= "" then
            code = payload.code
        end

        if type(code) ~= "string" or code == "" then
            return fail(
                "Quick Connect response did not include a code",
                status
            )
        end

        phase = "waiting"
        request_kind = nil
        error_message = nil
        started_at =
            payload.started_at or started_at
        next_poll_at =
            time.ticks() + poll_interval_ms

        return snapshot()
    end

    if payload.linked == true then
        phase = "linked"
        request_kind = nil
        code = nil
        error_message = nil
        next_poll_at = 0

        if type(payload.user) == "table" then
            user = {
                id = payload.user.id,
                name = payload.user.name,
            }
        else
            user = nil
        end

        return snapshot()
    end

    if payload.expired == true or status == 410 then
        return fail(
            "Quick Connect code expired",
            status
        )
    end

    return fail(
        payload.error or
            "unexpected Quick Connect response",
        status
    )
end

local function finish_request(response)
    request_kind = nil
    http_status = response.status

    local payload, decode_error =
        decode_body(response.body)

    if not response.ok then
        if payload and
            (payload.expired == true or
             response.status == 410) then
            return fail(
                "Quick Connect code expired",
                response.status
            )
        end

        return fail(
            payload and payload.error
                or response.error
                or decode_error
                or (
                    "HTTP status " ..
                    tostring(response.status)
                ),
            response.status
        )
    end

    if not payload then
        return fail(
            decode_error,
            response.status
        )
    end

    return accept_payload(
        payload,
        response.status
    )
end

function M.start(force)
    if request_kind ~= nil or
        phase == "starting" or
        phase == "waiting" or
        phase == "polling" then
        return false,
            "Quick Connect is already active"
    end

    local path, path_error =
        device_identity.link_start_path(
            force == true
        )

    if not path then
        return false, path_error
    end

    local started, start_error =
        sync_client.post(
            path,
            "",
            owner
        )

    if not started then
        return false, start_error
    end

    phase = "starting"
    request_kind = "start"
    code = nil
    user = nil
    error_message = nil
    http_status = nil
    started_at = nil
    next_poll_at = 0

    return true
end

function M.poll()
    if request_kind ~= nil then
        local response =
            sync_client.poll(owner)

        if response == nil then
            return nil
        end

        return finish_request(response)
    end

    if phase ~= "waiting" then
        return nil
    end

    if sync_client.busy() then
        return nil
    end

    local path, path_error =
        device_identity.link_status_path()

    if not path then
        return fail(path_error)
    end

    local started, start_error =
        sync_client.get(
            path,
            owner
        )

    if not started then
        next_poll_at =
            time.ticks() + 500
        return nil, start_error
    end

    phase = "polling"
    request_kind = "status"

    return snapshot()
end

function M.state()
    return snapshot()
end

function M.reset()
    if request_kind ~= nil then
        return false,
            "Quick Connect request is still active"
    end

    phase = "idle"
    code = nil
    user = nil
    error_message = nil
    http_status = nil
    started_at = nil
    next_poll_at = 0

    return true
end

return M

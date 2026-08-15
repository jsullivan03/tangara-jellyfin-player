package.path =
    "lua/?.lua;" ..
    "desktop-sim/?.lua;" ..
    package.path

local json = require("json")
local pending = nil
local response = nil

package.loaded["device"] = {
    storage_root = function()
        return "/tmp/tangara-offline-bootstrap-test-missing"
    end,
}
package.loaded["device_identity"] = {
    id = function()
        return "tangara-sim-001"
    end,
    download_requests_path = function()
        return "/devices/tangara-sim-001/download-requests"
    end,
}
package.loaded["time"] = {
    ticks = function()
        return 1000
    end,
}
package.loaded["sync_client"] = {
    busy = function()
        return pending ~= nil
    end,
    post = function(path, body, owner)
        pending = {
            path = path,
            body = body,
            owner = owner,
        }
        return true
    end,
    poll = function(owner)
        if not pending or pending.owner ~= owner then
            return nil
        end
        pending = nil
        local result = response
        response = nil
        return result
    end,
}

package.loaded["sync_offline_bootstrap"] = nil
local bootstrap = require("sync_offline_bootstrap")

local library = {
    favorites = {
        items = {
            {jellyfin_id = "track-c"},
            {jellyfin_id = "track-a"},
        },
    },
    playlists = {
        {
            items = {
                {jellyfin_id = "track-b"},
                {jellyfin_id = "track-a"},
            },
        },
    },
}

local started, start_error = bootstrap.start(library)
assert(started, start_error)
assert(pending.path ==
    "/devices/tangara-sim-001/download-requests")
assert(pending.owner == "sync_offline_bootstrap")

local body = json.decode(pending.body)
assert(body.kind == "selection")
assert(#body.jellyfin_item_ids == 3)
assert(body.jellyfin_item_ids[1] == "track-a")
assert(body.jellyfin_item_ids[2] == "track-b")
assert(body.jellyfin_item_ids[3] == "track-c")
assert(type(body.jellyfin_item_id) == "nil")
assert(type(body.idempotency_key) == "string")
assert(body.idempotency_key:find(
    "tangara-sim-001:offline-selection:",
    1,
    true
) == 1)

response = {
    ok = false,
    status = 400,
    body = [[{"error":"jellyfin_item_id, valid kind, and idempotency_key are required"}]],
}
local result = bootstrap.poll()
assert(result and result.ok == false)
assert(result.status == 400)
assert(result.error ==
    "jellyfin_item_id, valid kind, and idempotency_key are required")

print("Sync offline bootstrap request contract passed")
os.exit(0)

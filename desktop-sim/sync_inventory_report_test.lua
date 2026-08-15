package.path =
    "lua/?.lua;" ..
    "desktop-sim/?.lua;" ..
    package.path

local json = require("json")
local pending = nil

package.loaded["device_identity"] = {
    inventory_path = function()
        return "/devices/device-1/inventory"
    end,
}

package.loaded[
    "jellyfin_local_index_generation"
] = {
    snapshot = function()
        return {
            generation = 7,
        }
    end,
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {
            tracks = {
                {
                    id = "曲-二",
                    jellyfin_id = "曲-二",
                    local_path =
                        "/Music/音楽家/二曲.flac",
                    source_item = {
                        size_bytes = 200,
                    },
                },
                {
                    id = "曲-一",
                    jellyfin_id = "曲-一",
                    local_path =
                        "/Music/音楽家/一曲.flac",
                    source_item = {
                        size_bytes = 100,
                    },
                },
            },
        }
    end,
}

package.loaded["sync_client"] = {
    busy = function()
        return pending ~= nil
    end,
    put = function(path, body, owner)
        pending = {
            path = path,
            body = body,
            owner = owner,
        }
        return true
    end,
    poll = function(owner)
        if not pending or
            pending.owner ~= owner then
            return nil
        end

        pending = nil
        return {
            ok = true,
            status = 200,
            body = '{"ok":true}',
        }
    end,
}

package.loaded["sync_inventory_report"] = nil
local report =
    require("sync_inventory_report")

local payload = assert(
    report.payload(
        {
            action = {
                item = {
                    jellyfin_id = "曲-三",
                },
            },
            bytes = 50,
            bytes_total = 500,
        },
        {
            failed_action = {
                item = {
                    jellyfin_id = "曲-四",
                },
            },
            error = "失敗",
        }
    )
)

assert(payload.revision == "7:2")
assert(
    payload.items[1].jellyfin_id ==
        "曲-一"
)
assert(
    payload.active.jellyfin_id ==
        "曲-三"
)
assert(
    payload.failures[1].message ==
        "失敗"
)

assert(
    report.start(
        nil,
        nil
    )
)
assert(
    pending.path ==
        "/devices/device-1/inventory"
)

local encoded = json.decode(pending.body)
assert(encoded.items[2].jellyfin_id == "曲-二")
assert(report.poll().ok)

print(
    "Device inventory reporting preserves stable IDs and non-Latin metadata"
)
os.exit(0)

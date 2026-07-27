package.path =
    "lua/?.lua;" ..
    package.path

local current_action = nil
local invalidations = 0
local invalidation_reason = nil

package.preload["sync_download"] =
    function()
        return {
            start = function(action)
                current_action = action
                return true
            end,
            busy = function()
                return current_action ~= nil
            end,
            progress = function()
                return nil
            end,
            poll = function()
                if not current_action then
                    return nil
                end

                local action = current_action
                current_action = nil

                return {
                    ok = true,
                    inventory_saved = true,
                    kind = action.kind,
                }
            end,
        }
    end

package.preload[
    "jellyfin_local_index_generation"
] =
    function()
        return {
            invalidate = function(reason)
                invalidations =
                    invalidations + 1
                invalidation_reason = reason
            end,
        }
    end

local sync_apply = require("sync_apply")

local started, start_error =
    sync_apply.start {
        actions = {
            {
                kind = "media",
                local_path = "/one.flac",
            },
            {
                kind = "artwork",
                local_path = "/one.jpg",
            },
        },
    }

assert(started, start_error)
assert(sync_apply.poll() == nil)

local result = sync_apply.poll()

assert(result and result.ok)
assert(result.completed == 2)
assert(invalidations == 1)
assert(
    invalidation_reason ==
        "sync apply changed local files"
)

local empty_started, empty_error =
    sync_apply.start {
        actions = {},
    }

assert(empty_started, empty_error)

local empty_result = sync_apply.poll()

assert(empty_result and empty_result.ok)
assert(invalidations == 1)

print(
    "Sync apply index invalidation passed"
)

os.exit(0)

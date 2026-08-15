package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
require("mocks").install(lvgl)

local sync_apply = require("sync_apply")
local sync_operation_flush =
    require("sync_operation_flush")
local sync_manifest_state =
    require("sync_manifest_state")
local sync_offline_bootstrap =
    require("sync_offline_bootstrap")
local sync_runtime = require("sync_runtime")

local apply_progress = nil
local operation_busy = false
local manifest_busy = false
local bootstrap_busy = false
local catalog_busy = false

sync_apply.progress = function()
    return apply_progress
end
sync_operation_flush.busy = function()
    return operation_busy
end
sync_manifest_state.busy = function()
    return manifest_busy
end
sync_offline_bootstrap.busy = function()
    return bootstrap_busy
end
package.loaded["sync_catalog"] = {
    busy = function()
        return catalog_busy
    end,
}

local function assert_idle(label)
    local activity = sync_runtime.activity()
    assert(
        activity.busy == false and
            activity.mode == "idle",
        label ..
            " must not drive the top-left activity indicator"
    )
end

assert_idle("idle runtime")

manifest_busy = true
assert_idle("manifest refresh")
manifest_busy = false

bootstrap_busy = true
assert_idle("offline bootstrap polling")
bootstrap_busy = false

catalog_busy = true
assert_idle("catalog refresh")
catalog_busy = false

apply_progress = {
    action = {kind = "artwork"},
    bytes = 0,
    bytes_total = 0,
}
assert_idle("standalone artwork work")

apply_progress = {
    action = {kind = "media"},
    bytes = 25,
    bytes_total = 100,
}
local downloading = sync_runtime.activity()
assert(
    downloading.busy == true and
        downloading.mode == "determinate" and
        downloading.phase == "downloading" and
        downloading.bytes == 25 and
        downloading.bytes_total == 100,
    "active media download must drive determinate activity"
)

apply_progress = nil
operation_busy = true
assert_idle("startup/device-state operation flush")
operation_busy = false

print("Sync runtime visible-activity contract passed")

os.exit(0)

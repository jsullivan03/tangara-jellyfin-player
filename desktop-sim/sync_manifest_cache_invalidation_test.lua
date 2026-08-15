package.path =
    "lua/?.lua;" ..
    package.path

local root =
    "/tmp/tangara-manifest-cache-invalidation-test"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

local invalidations = 0
local invalidation_reason = nil

package.preload["device"] =
    function()
        return {
            storage_root = function()
                return root
            end,
        }
    end

package.preload["device_identity"] =
    function()
        return {
            id = function()
                return "cache-test-device"
            end,
        }
    end

package.preload["sync_manifest"] =
    function()
        local manifest = {
            device = {
                id = "cache-test-device",
            },
            items = {},
        }

        return {
            decode = function()
                return manifest
            end,
            load = function(path)
                local file = io.open(path, "rb")

                if not file then
                    return nil, "missing manifest"
                end

                file:close()
                return manifest
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

local cache = require("sync_manifest_cache")

local saved, save_error =
    cache.save("{}")

assert(saved, save_error)
assert(invalidations == 1)
assert(
    invalidation_reason ==
        "manifest cache saved"
)

local loaded, load_error = cache.load()

assert(loaded, load_error)
assert(loaded.device.id == "cache-test-device")

local loads = 0
local original_load = package.loaded["sync_manifest"].load

package.loaded["sync_manifest"].load =
    function(path)
        loads = loads + 1
        return original_load(path)
    end

local loaded_again = assert(cache.load())
assert(loaded_again == loaded)
assert(
    loads == 0,
    "sync_manifest_cache.load re-read disk after a warm memory cache"
)

cache.invalidate_memory("test")
local loaded_cold = assert(cache.load())
assert(loads >= 1)
assert(loaded_cold.device.id == "cache-test-device")

print(
    "Manifest cache index invalidation passed"
)

os.execute("rm -rf " .. root)
os.exit(0)

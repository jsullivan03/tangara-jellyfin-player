package.path =
    "lua/?.lua;" ..
    package.path

local starts = 0
local pending = false
local next_result = nil

package.loaded["device"] = {
    storage_root = function()
        return "/tmp/sync-artwork-test"
    end,
}
package.loaded["filesystem"] = {
    chkdir = function()
        return true
    end,
    mkdir = function()
        return true
    end,
}
package.loaded["sync_client"] = {
    url = function(path)
        return "http://companion" .. path
    end,
}
package.loaded["download"] = {
    busy = function()
        return pending
    end,
    start = function(url, path)
        starts = starts + 1
        pending = true
        assert(url == "http://companion/art/a")
        assert(path:match("sq28%.png$"))
        return true
    end,
    poll = function()
        local result = next_result
        next_result = nil
        if result then
            pending = false
        end
        return result
    end,
}

package.loaded["sync_artwork_cache"] = nil
local cache =
    require("sync_artwork_cache")

local item = {
    jellyfin_id = "作品",
    artwork_revision = "r1",
    artwork_path = "/art/a",
}
local callbacks = 0
cache.request(item, function()
    callbacks = callbacks + 1
end)
cache.request(item, function()
    callbacks = callbacks + 1
end)
assert(starts == 1)

next_result = {ok = true}
local result = cache.poll()
assert(result.ok)
assert(callbacks == 2)

cache.request(item, function(path)
    callbacks = callbacks + 1
    assert(path:match("sq28%.png$"))
end)
assert(starts == 1)
assert(callbacks == 3)
assert(cache.matches(item, cache.key(item)))
assert(not cache.matches(
    {jellyfin_id = "別"},
    cache.key(item)
))

local real_open = io.open
io.open = function(path, mode)
    if tostring(path):match(
        "%.tangara%-artwork/sync/"
    ) then
        return {
            close = function()
            end,
        }
    end
    return real_open(path, mode)
end
package.loaded["sync_artwork_cache"] = nil
local disk_cache =
    require("sync_artwork_cache")
local first_disk_path = nil
disk_cache.request(item, function(path)
    first_disk_path = path
end)
io.open = real_open
assert(
    first_disk_path and
        first_disk_path:match(
            "^/tmp/sync%-artwork%-test/"
        ),
    "first disk-cache callback did not use the simulator display path"
)
cache = disk_cache

local failed = {
    jellyfin_id = "failed",
    artwork_path = "/art/a",
}
cache.request(failed)
next_result = {
    ok = false,
    error = "not found",
}
result = cache.poll()
assert(not result.ok)
local starts_after_failure = starts
cache.request(failed)
cache.request(failed)
assert(
    starts == starts_after_failure,
    "missing artwork retried continuously after a terminal failure"
)

print(
    "Sync artwork lazy queue, stale-key guard, cache reuse, and failure fallback passed"
)
os.exit(0)

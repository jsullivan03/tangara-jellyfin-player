package.path =
    "lua/?.lua;" ..
    package.path

local starts = {}
local pending = false
local next_result = nil

package.loaded["device"] = {
    storage_root = function()
        return "/tmp/sync-artwork-recycle-test"
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
    start = function(url)
        starts[#starts + 1] = url
        pending = true
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
local cache = require("sync_artwork_cache")

local active = {
    jellyfin_id = "active",
    artwork_revision = "revision-active",
    artwork_path = "/art/active",
}
local stale = {
    jellyfin_id = "stale",
    artwork_revision = "revision-stale",
    artwork_path = "/art/stale",
}
local current = {
    jellyfin_id = "current",
    artwork_revision = "revision-current",
    artwork_path = "/art/current",
}

cache.request(active, function()
end)
local _, stale_subscription =
    cache.request(stale, function()
        error("cancelled stale artwork callback ran")
    end)
cache.request(current, function()
end)

assert(#starts == 1)
assert(cache.cancel(stale_subscription))

next_result = {ok = true}
cache.poll()

assert(
    starts[2] ==
        "http://companion/art/current",
    "cancelled recycled-row artwork stayed ahead of the current visible row"
)
assert(
    starts[2] ~=
        "http://companion/art/stale",
    "cancelled stale artwork still downloaded"
)

cache.reset()
starts = {}
pending = false
next_result = nil

local first_track = {
    jellyfin_id = "track-1",
    artwork_source = "jellyfin",
    artwork_revision = "album-image-tag",
    artwork_path = "/art/track-1",
}
local second_track = {
    jellyfin_id = "track-2",
    artwork_source = "jellyfin",
    artwork_revision = "album-image-tag",
    artwork_path = "/art/track-2",
}
local callbacks = 0

cache.request(first_track, function()
    callbacks = callbacks + 1
end)
cache.request(second_track, function()
    callbacks = callbacks + 1
end)

assert(
    cache.key(first_track) ==
        cache.key(second_track),
    "tracks sharing one Jellyfin image revision did not share the artwork cache key"
)
assert(
    #starts == 1,
    "identical inherited album art started duplicate downloads"
)

next_result = {ok = true}
cache.poll()
assert(callbacks == 2)

print(
    "Sync artwork cancels recycled-row jobs and deduplicates inherited album images"
)
os.exit(0)

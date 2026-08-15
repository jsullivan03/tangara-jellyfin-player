package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local encode = require("json_encode").encode
local active = nil
local response = nil
local request_count = 0

package.loaded["device_identity"] = {
    catalog_path = function(view)
        return "/catalog/" .. tostring(view)
    end,
}
package.loaded["time"] = {
    ticks = function() return 1000 end,
}
package.loaded["sync_client"] = {
    busy = function(owner)
        if owner then
            return active and active.owner == owner
        end
        return active ~= nil
    end,
    get = function(path, owner)
        assert(active == nil)
        request_count = request_count + 1
        active = {path = path, owner = owner}
        return true
    end,
    post = function()
        return false, "not used"
    end,
    poll = function(owner)
        if not active or active.owner ~= owner or not response then
            return nil
        end
        local result = response
        response = nil
        active = nil
        return result
    end,
}

package.loaded["sync_catalog"] = nil
local catalog = require("sync_catalog")

local function body(id, title)
    return encode {
        view = "albums",
        items = {
            {
                jellyfin_id = id,
                kind = "album",
                title = title,
            },
        },
    }
end

local generation = catalog.next_generation("new")
assert(catalog.start("albums", nil, 20, {
    cache_key = "new",
    generation = generation,
}))
assert(catalog.busy())
response = {ok = true, status = 200, body = body("same", "Same")}
local result = assert(catalog.poll())
assert(result.ok)
assert(not catalog.busy(), "busy did not clear after success")
assert(catalog.cached("new").items[1].title == "Same")

-- Polling an identical completed response does not manufacture another request.
assert(catalog.poll() == nil)
assert(request_count == 1)

generation = catalog.next_generation("new")
assert(catalog.start("albums", nil, 20, {
    cache_key = "new",
    generation = generation,
}))
response = {
    ok = false,
    status = 500,
    body = encode {error = "refresh failed"},
    error = "refresh failed",
}
result = assert(catalog.poll())
assert(not result.ok)
assert(not catalog.busy(), "busy did not clear after error")

generation = catalog.next_generation("new")
assert(catalog.start("albums", nil, 20, {
    cache_key = "new",
    generation = generation,
}))
response = {
    ok = false,
    status = 0,
    body = "",
    error = "catalog timeout",
}
result = assert(catalog.poll())
assert(not result.ok and result.error == "catalog timeout")
assert(not catalog.busy(), "busy did not clear after timeout")

-- A changed response can run immediately after failure and replaces the cache.
generation = catalog.next_generation("new")
assert(catalog.start("albums", nil, 20, {
    cache_key = "new",
    generation = generation,
}))
response = {ok = true, status = 200, body = body("changed", "Changed")}
result = assert(catalog.poll())
assert(result.ok)
assert(not catalog.busy())
assert(catalog.cached("new").items[1].title == "Changed")
assert(request_count == 4)

print("Sync catalog refresh lifecycle passed")
os.exit(0)

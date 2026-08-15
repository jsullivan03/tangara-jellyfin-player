package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
local backstack =
    require("firmware_backstack")

lvgl.ImgData = function(path)
    return path
end

_G.tangara_sim_enable_encoder_handler = true
_G.tangara_sim_set_encoder_mode =
    function()
    end

require("mocks").install(lvgl)

package.loaded["backstack"] = backstack
package.preload["backstack"] = function()
    return backstack
end

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {
            tracks = {},
            albums = {},
        }
    end,
}

package.loaded["sync_artwork_cache"] = {
    key = function(item)
        return tostring(item.jellyfin_id or "")
    end,
    request = function()
        return nil
    end,
    cancel = function()
        return nil
    end,
    poll = function()
        return nil
    end,
}

local function item(index)
    return {
        jellyfin_id = string.format(
            "search-album-%02d",
            index
        ),
        kind = "album",
        title = string.format(
            "Search Album %02d",
            index
        ),
        artist = string.format(
            "Search Artist %02d",
            index
        ),
        track_count = index,
        artwork_path = "",
        artwork_revision = "",
        artwork_source = "jellyfin",
        device = {
            state = "server_only",
        },
    }
end

local payload = {
    items = {},
    external_search_pending = true,
    total_count = 8,
}

for index = 1, 8 do
    payload.items[index] = item(index)
end

package.loaded["sync_catalog"] = {
    cached_key = function(key)
        if key == "search:fixed" then
            return payload
        end
        return nil
    end,
    cached = function()
        return nil
    end,
    error = function()
        return nil
    end,
    busy = function()
        return false
    end,
    queue = function()
        return true
    end,
    external_job = function()
        return true
    end,
    local_artist_releases = function()
        return nil
    end,
}

package.loaded["jellyfin_sync_ui"] = nil
local sync_ui = require("jellyfin_sync_ui")

local results =
    sync_ui.Results:new {
        query = "fixed",
    }

backstack.reset(results)
backstack.flush(10)

local controller =
    assert(results.virtual_list_controller)

assert(
    controller.fixed_viewport == true and
        controller.motion_layer ~= nil,
    "eight Search results did not adopt the shared fixed viewport"
)
assert(
    controller:pool_count() == 7,
    "Search did not keep the seven-row pool"
)
assert(
    controller:logical_count() == 8,
    "Search lost initial logical results"
)

controller:continuous_select(6, false)
local selected_id =
    controller.items[6].jellyfin_id
local first_model = controller.pool[1]

payload = {
    items = {},
    external_available = true,
    external_search_pending = false,
    total_count = 12,
}

for index = 1, 12 do
    payload.items[index] = item(index)
end

results:render(false)

assert(
    results.virtual_list_controller ==
        controller,
    "Search merge rebuilt the fixed virtual controller"
)
assert(
    controller.pool[1] == first_model and
        controller:pool_count() == 7,
    "Search merge rebuilt the reusable row pool"
)
assert(
    controller:logical_count() == 12,
    "Search merge did not append all logical results"
)
assert(
    results.selected_item_id == selected_id,
    "Search merge lost the selected result identity"
)
assert(
    controller.selected_index == 6,
    "Search merge moved the logical selection"
)

print(
    "Long Sync Search results share the fixed viewport and merge in place"
)

os.exit(0)

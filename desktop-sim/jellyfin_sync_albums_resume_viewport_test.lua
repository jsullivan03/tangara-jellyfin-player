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

local album_items = {}
for index = 1, 20 do
    album_items[index] = {
        jellyfin_id =
            "album-resume-" ..
            tostring(index),
        kind = "album",
        title = "Album " .. tostring(index),
        artist = "Artist " .. tostring(index),
        track_count = 1,
        device = {
            state = "server_only",
            total_tracks = 1,
            downloaded_tracks = 0,
        },
    }
end

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {tracks = {}, albums = {}}
    end,
}

package.loaded["sync_artwork_cache"] = {
    key = function(item)
        return tostring(
            item.jellyfin_id or ""
        )
    end,
    request = function()
        return nil
    end,
    cancel = function()
        return true
    end,
    poll = function()
    end,
}

package.loaded["sync_runtime"] = {
    apply_progress = function()
        return nil
    end,
    last_apply_result = function()
        return nil
    end,
    request_refresh = function()
        return true
    end,
    content_generation = function()
        return 0
    end,
    state_generation = function()
        return 0
    end,
    last_library_result = function()
        return nil
    end,
    last_result = function()
        return nil
    end,
}

package.loaded["sync_catalog"] = {
    cached = function(view)
        if view == "albums" then
            return {
                view = "albums",
                sort = "title",
                direction = "ascending",
                generation = 1,
                total = #album_items,
                total_count = #album_items,
                items = album_items,
            }
        end
        return nil
    end,
    cached_key = function()
        return nil
    end,
    start = function()
        return true
    end,
    busy = function()
        return false
    end,
    error = function()
        return nil
    end,
    poll = function()
        return nil
    end,
    queue = function()
        return true
    end,
}

for _, module_name in ipairs({
    "sync_sort",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_sync_ui",
    "jellyfin_marquee",
}) do
    package.loaded[module_name] = nil
end

local sync_ui =
    require("jellyfin_sync_ui")

local albums =
    sync_ui.Catalog:new {
        title = "Albums",
        view = "albums",
    }

backstack.reset(albums)
backstack.flush(8)

local controller =
    assert(albums.virtual_list_controller)
assert(
    controller.fixed_viewport == false and
        controller.motion_layer == nil
)

-- Move to a nonzero viewport/selection.
controller:continuous_select(12, false)
backstack.flush(4)

local selected_before =
    albums.selected_item_id
local list_coordinates =
    albums.list:get_coords()
local selected_coordinates =
    assert(controller:selected_model())
        .object:get_coords()
local anchor_before =
    selected_coordinates.y1 -
    list_coordinates.y1
local thumb_before =
    albums.scroll_indicator and
    albums.scroll_indicator.thumb_y

assert(
    selected_before ==
        "album-resume-12",
    "precondition selection"
)
-- Child screen then Escape back.
local child =
    require("screen"):new {
        create_ui = function(self)
            self.root = self.content
        end,
        on_show = function()
        end,
        on_hide = function()
        end,
    }

backstack.push(child)
backstack.flush(12)
backstack.pop()

-- Parent restoration is synchronous with pop, before it becomes visible.
local selected_model =
    assert(controller:selected_model())
list_coordinates =
    albums.list:get_coords()
selected_coordinates =
    selected_model.object:get_coords()

assert(
    require("jellyfin_album_identity").same(
        {key = albums.selected_item_id},
        {key = selected_before}
    ),
    "Escape did not preserve selected album id got=" ..
        tostring(albums.selected_item_id) ..
        " expected=" .. tostring(selected_before)
)
assert(
    selected_coordinates.y1 -
        list_coordinates.y1 ==
        anchor_before,
    "Escape did not restore the selected album viewport anchor before paint"
)

assert(
    selected_model and
        selected_model.focused == true,
    "restored selected mounted row was not focused"
)
assert(
    not albums.scroll_indicator or
        albums.scroll_indicator.thumb_y ==
            thumb_before,
    "Escape did not restore the scrollbar with the album viewport"
)

backstack.flush(12)
assert(
    albums.selected_item_id ==
        selected_before and
        assert(controller:selected_model())
            .focused == true,
    "settled pop changed restored Sync Albums state"
)

print(
    "Sync Albums Escape resume viewport passed"
)
os.exit(0)

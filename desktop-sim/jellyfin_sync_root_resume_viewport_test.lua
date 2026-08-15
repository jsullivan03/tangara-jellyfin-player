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

require("mocks").install(lvgl)
package.loaded["backstack"] = backstack
package.preload["backstack"] = function()
    return backstack
end

local anim_starts = 0
local original_anim = nil

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {tracks = {}, albums = {}}
    end,
}

package.loaded["sync_artwork_cache"] = {
    key = function()
        return "k"
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
    local_gate_state = function()
        return {blocked = false}
    end,
}

local album_items = {}
for index = 1, 8 do
    album_items[index] = {
        jellyfin_id =
            "new-album-" .. tostring(index),
        kind = "album",
        title = "New " .. tostring(index),
        artist = "Artist",
        device = {
            state = "server_only",
            total_tracks = 1,
            downloaded_tracks = 0,
        },
    }
end

package.loaded["sync_catalog"] = {
    cached = function(view)
        if view == "new" then
            return {
                view = "albums",
                sort = "date_added",
                direction = "descending",
                generation = 1,
                items = album_items,
            }
        elseif view == "albums" then
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
    next_generation = function()
        return 1
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

for _, name in ipairs({
    "sync_sort",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_sync_ui",
    "jellyfin_home",
    "jellyfin_navigation",
}) do
    package.loaded[name] = nil
end

local list_ui = require("jellyfin_list_ui")
local sync_ui = require("jellyfin_sync_ui")
local navigation = require("jellyfin_navigation")

local root = sync_ui.Root:new()
backstack.reset(root)
backstack.flush(8)

assert(root.ui_active == true)
assert(
    root.virtual_list_controller == nil,
    "Sync root must stay a plain list"
)

-- Scroll into the New albums region.
root.list:scroll_to {
    x = 0,
    y = 72,
    anim = false,
}
backstack.flush(3)

local albums_row = nil
for _, model in ipairs(root.rows or {}) do
    if model.selection_id == "sync:albums" then
        albums_row = model
        break
    end
end
assert(albums_row, "Albums quick action missing")
backstack.focus(albums_row.object)
-- Let the Phase 3 reveal reach its stable target before using that viewport
-- as the resume baseline.
backstack.flush(10)

list_ui.capture_list_scroll(root)
local saved_scroll = root.resume_plain_scroll_y
assert(
    type(saved_scroll) == "number",
    "Sync root did not capture a plain scroll offset"
)

local list_before = root.list:get_coords()
local albums_before =
    albums_row.object:get_coords()
local offset_before =
    list_before.y1 - albums_before.y1

-- Instrument plain-list animated reveal.
local original_timer = lvgl.Timer
lvgl.Timer = function(options)
    return original_timer(options)
end

albums_row.on_click()
backstack.flush(6)
assert(
    backstack.current() ~= root,
    "Albums was not pushed"
)

local resume_anims = 0
local plain_anim_before =
    root.plain_list_scroll_anim

assert(navigation.back())
backstack.flush(10)

assert(
    backstack.current() == root,
    "Escape did not restore Sync root"
)
assert(
    root.ui_active == true,
    "Sync root ui_active not restored"
)
assert(
    root.selected_item_id == "sync:albums",
    "Sync root selection was not restored"
)

local list_after = root.list:get_coords()
albums_row = nil
for _, model in ipairs(root.rows or {}) do
    if model.selection_id == "sync:albums" then
        albums_row = model
        break
    end
end
assert(albums_row)
local albums_after =
    albums_row.object:get_coords()
local offset_after =
    list_after.y1 - albums_after.y1

assert(
    math.abs(offset_after - offset_before) <= 2,
    "Escape did not restore Sync root viewport before first paint before=" ..
        tostring(offset_before) ..
        " after=" .. tostring(offset_after)
)
assert(
    root.plain_list_scroll_anim == nil or
        root.plain_list_scroll_anim ==
            plain_anim_before,
    "Escape resume started a plain-list scroll animation"
)

print(
    "Sync root Escape resume viewport passed"
)
os.exit(0)

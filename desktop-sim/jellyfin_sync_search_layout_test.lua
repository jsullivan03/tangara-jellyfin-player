package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
lvgl.ImgData = function(path)
    return path
end

local simulator =
    require("mocks").install(lvgl)

package.loaded["backstack"] =
    simulator.backstack
local pushed = nil
local original_push =
    simulator.backstack.push
simulator.backstack.push =
    function(value)
        pushed = value
        original_push(value)
    end
package.loaded["sync_catalog"] = {
    search = function()
        return true
    end,
    poll = function()
        return nil
    end,
}

package.loaded["jellyfin_sync_ui"] = nil
local sync_ui =
    require("jellyfin_sync_ui")
local search = sync_ui.Search:new()

simulator.backstack.reset(search)

assert(
    search.rows[1].selection_id ==
        "sync:search:query"
)
assert(#search.toggle_rows == 2)
assert(
    search.toggle_rows[1]
        .label_text_align == 2
)
assert(search.toggle_rows[1].active)
assert(not search.toggle_rows[2].active)

search.toggle_rows[1].on_click()
assert(not search.toggle_rows[1].active)

search.rows[1].on_click()
local entry =
    pushed
assert(
    entry:text_entry_state()
        .carousel_active == true
)

print(
    "Sync Search query-first layout and accent toggles passed"
)
os.exit(0)

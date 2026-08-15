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
package.preload["backstack"] =
    function()
        return backstack
    end

local payloads = {
    new = {
        view = "albums",
        sort = "date_added",
        direction = "descending",
        items = {
            {
                jellyfin_id = "new-1",
                kind = "album",
                title = "新作",
                artist = "音楽家",
                date_created =
                    "2026-07-30T12:00:00Z",
                device = {
                    state = "server_only",
                },
            },
        },
    },
    albums = {
        items = {
            {
                jellyfin_id = "new-1",
                kind = "album",
                title = "新作",
                artist = "音楽家",
                device = {
                    state = "server_only",
                },
            },
        },
    },
}
for index = 2, 20 do
    table.insert(
        payloads.new.items,
        {
            jellyfin_id =
                "new-" .. tostring(index),
            kind = "album",
            title =
                "New album " ..
                tostring(index),
            artist = "Artist",
            date_created =
                string.format(
                    "2026-07-%02dT12:00:00Z",
                    31 - index
                ),
            device = {
                state = "server_only",
            },
        }
    )
end

local new_payload = payloads.new

package.loaded["sync_catalog"] = {
    cached = function(view)
        return payloads[view]
    end,
    cached_key = function(key)
        if key == "downloads" then
            return {
                device_requests = {},
                external_jobs = {},
            }
        end
        return nil
    end,
    local_artist_releases = function()
        return nil
    end,
    error = function()
        return nil
    end,
    busy = function()
        return false
    end,
    start = function()
        return true
    end,
    downloads = function()
        return true
    end,
    poll = function()
        return nil
    end,
    queue = function()
        return true
    end,
}

package.loaded["jellyfin_sync_ui"] = nil
local sync_ui =
    require("jellyfin_sync_ui")
local navigation =
    require("jellyfin_navigation")

local parent =
    sync_ui.Status:new {
        item = {
            state = "queued",
        },
    }
backstack.reset(parent)
backstack.flush(8)

local landing = sync_ui.Root:new()
backstack.push(landing)
backstack.flush(8)

assert(
    backstack.is_focused(
        landing.quick_rows[1].object
    )
)
assert(
    landing.quick_rows[1]
        .selection_id ==
        "sync:search"
)
assert(
    landing.rows[2].selection_id ==
        "sync:albums"
)
assert(
    landing.rows[3].selection_id ==
        "sync:tracks"
)
assert(
    landing.rows[4].selection_id ==
        "new-1"
)
assert(
    landing.scroll_indicator and
        landing.scroll_indicator
            .item_count == 21 and
        landing.scroll_indicator.hidden ==
            false,
    "Sync landing New list did not show a scrollbar for all 20 albums"
)
assert(
    landing.scroll_indicator.thumb_y == 0,
    "fresh Sync landing scrollbar did not initialize at the logical top"
)
local thumb_coordinates =
    landing.scroll_indicator.thumb:
        get_coords()
local list_coordinates =
    landing.list:get_coords()
assert(
    thumb_coordinates.y1 ==
        list_coordinates.y1 +
            landing.scroll_indicator.y,
    "fresh Sync landing scrollbar geometry was not laid out at the top before wheel input"
)

-- All three horizontal controls represent the same logical scrollbar row.
-- Move the indicator down first so each focus transition proves that Search,
-- Albums, and Tracks independently restore it to the top.
local last_new_row =
    landing.rows[#landing.rows]
for _, quick_row in ipairs(
    landing.quick_rows
) do
    backstack.focus(
        last_new_row.object
    )
    backstack.flush(2)
    assert(
        landing.scroll_indicator.thumb_y > 0,
        "Sync landing scrollbar did not move away from the top for the alias test"
    )
    backstack.focus(quick_row.object)
    backstack.flush(2)
    assert(
        landing.scroll_indicator.thumb_y == 0,
        "a Sync quick control did not map back to logical scrollbar index 1"
    )
end
landing.list:scroll_to {
    x = 0,
    y = 0,
    anim = false,
}
landing.list:update_layout()
backstack.focus(
    landing.quick_rows[1].object
)
backstack.flush(2)

list_coordinates =
    landing.list:get_coords()
for _, quick_row in ipairs(
    landing.quick_rows
) do
    local coordinates =
        quick_row.object:get_coords()
    assert(
        coordinates.y1 >=
            list_coordinates.y1 and
        coordinates.y2 <=
            list_coordinates.y2,
        "fresh Sync entry did not keep the complete quick-action row visible"
    )
end

landing.quick_rows[1].on_click()
backstack.flush(8)
assert(
    backstack.current() ~= landing,
    "initially focused Search did not activate immediately"
)
backstack.pop()
backstack.flush(8)
assert(backstack.current() == landing)
assert(
    backstack.is_focused(
        landing.quick_rows[1].object
    ),
    "return from Search did not restore the landing selection"
)

backstack.focus(landing.rows[4].object)
backstack.flush(4)
assert(
    landing.selected_item_id ==
        "new-1"
)
local child =
    sync_ui.Status:new {
        item = payloads.new.items[1],
    }
backstack.push(child)
backstack.flush(6)
backstack.pop()
backstack.flush(8)
assert(
    backstack.is_focused(
        landing.rows[4].object
    ),
    "return from a landing child did not restore its logical selection"
)

assert(navigation.back())
backstack.flush(8)
assert(backstack.current() == parent)

payloads.new = nil
local asynchronous_landing =
    sync_ui.Root:new()
backstack.push(asynchronous_landing)
backstack.flush(8)
assert(
    backstack.is_focused(
        asynchronous_landing
            .quick_rows[1].object
    )
)
payloads.new = new_payload
asynchronous_landing:render()
backstack.flush(8)
assert(
    backstack.is_focused(
        asynchronous_landing
            .quick_rows[1].object
    ),
    "asynchronous New population replaced fresh Search focus"
)
list_coordinates =
    asynchronous_landing.list:get_coords()
for _, quick_row in ipairs(
    asynchronous_landing.quick_rows
) do
    local coordinates =
        quick_row.object:get_coords()
    assert(
        coordinates.y1 >=
            list_coordinates.y1 and
        coordinates.y2 <=
            list_coordinates.y2,
        "asynchronous New population moved fresh Sync below the quick actions"
    )
end
assert(navigation.back())
backstack.flush(8)
assert(backstack.current() == parent)

local fresh_landing = sync_ui.Root:new()
backstack.push(fresh_landing)
backstack.flush(8)
assert(
    backstack.is_focused(
        fresh_landing.quick_rows[1].object
    ),
    "a fresh top-level Sync entry restored an old child selection"
)
list_coordinates =
    fresh_landing.list:get_coords()
for _, quick_row in ipairs(
    fresh_landing.quick_rows
) do
    local coordinates =
        quick_row.object:get_coords()
    assert(
        coordinates.y1 >=
            list_coordinates.y1 and
        coordinates.y2 <=
            list_coordinates.y2,
        "a fresh top-level Sync entry restored an old scroll offset"
    )
end
assert(navigation.back())
backstack.flush(8)
assert(backstack.current() == parent)

local albums =
    sync_ui.Catalog:new {
        title = "Albums",
        view = "albums",
    }
backstack.push(albums)
backstack.flush(8)
assert(
    backstack.is_focused(
        albums.first_row
    )
)

payloads.albums = {
    items = {
        {
            jellyfin_id = "album-a",
            kind = "album",
            title = "A",
            artist = "Artist",
            device = {
                state = "server_only",
            },
        },
        {
            jellyfin_id = "album-b",
            kind = "album",
            title = "B",
            artist = "Artist",
            device = {
                state = "queued",
            },
        },
    },
}
albums:render()
backstack.flush(4)
assert(
    backstack.is_focused(
        albums.first_row
    )
)

backstack.focus(albums.rows[3].object)
backstack.flush(3)
assert(
    albums.selected_item_id ==
        "album-b"
)
child =
    sync_ui.Status:new {
        item = payloads.albums.items[2],
    }
backstack.push(child)
backstack.flush(6)
assert(
    backstack.is_focused(
        child.first_row
    )
)
backstack.pop()
backstack.flush(8)
assert(backstack.current() == albums)
assert(
    backstack.is_focused(
        albums.rows[3].object
    )
)

print(
    "Sync initial focus, untouched Back, async focus, linear order, and restoration passed"
)
os.exit(0)

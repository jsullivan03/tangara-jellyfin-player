package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
local backstack =
    require("firmware_backstack")
local metrics = require("sim_metrics")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)
package.loaded["backstack"] = backstack
package.preload["backstack"] =
    function()
        return backstack
    end

local fixture_root =
    os.tmpname() ..
    "-sync-discography-back"
os.remove(fixture_root)
assert(
    os.execute(
        "mkdir -p " .. fixture_root
    )
)
package.loaded["device"] = {
    storage_root = function()
        return fixture_root
    end,
}
package.loaded["jellyfin_local_index"] = {
    load = function()
        return {
            tracks = {},
            albums = {},
        }
    end,
}

local search_items = {}
for index = 1, 12 do
    search_items[index] = {
        jellyfin_id =
            "search-album-" ..
            tostring(index),
        kind = "album",
        title =
            index == 7 and
            "ASTROWORLD" or
            (
                "Travis release " ..
                tostring(index)
            ),
        artist = "Travis Scott",
        artist_key =
            "artist-travis-scott",
        jellyfin_artist_id =
            "jellyfin-travis-scott",
        device = {
            state = "server_only",
            total_tracks = 2,
            downloaded_tracks = 0,
        },
    }
end

local artist_payload = nil
local artwork_requests = {}
local artist_request_count = 0

package.loaded["sync_artwork_cache"] = {
    key = function(item)
        return table.concat({
            tostring(
                item.jellyfin_id or
                item.key or ""
            ),
            tostring(
                item.artwork_revision or
                ""
            ),
        }, ":")
    end,
    request = function(item, callback)
        if not item.artwork_path or
            item.artwork_path == "" then
            return nil
        end
        artwork_requests[
            #artwork_requests + 1
        ] = {
            item = item,
            callback = callback,
            key = table.concat({
                tostring(
                    item.jellyfin_id or
                    item.key or ""
                ),
                tostring(
                    item.artwork_revision or
                    ""
                ),
            }, ":"),
        }
        return nil
    end,
    poll = function()
        return nil
    end,
}

package.loaded["sync_catalog"] = {
    cached_key = function(key)
        if key ==
            "search:Travis Scott" then
            return {
                query = "Travis Scott",
                items = search_items,
                external_available =
                    true,
            }
        elseif key ==
            "artist:artist-travis-scott" then
            return artist_payload
        end
        return nil
    end,
    cached = function()
        return nil
    end,
    busy = function()
        return false
    end,
    error = function()
        return nil
    end,
    artist_releases = function()
        artist_request_count =
            artist_request_count + 1
        return true
    end,
    queue = function()
        return true
    end,
    external_job = function()
        return true
    end,
    poll = function()
        return nil
    end,
}

package.loaded["jellyfin_sync_ui"] = nil
local sync_ui =
    require("jellyfin_sync_ui")
local navigation =
    require("jellyfin_navigation")

local results =
    sync_ui.Results:new {
        query = "Travis Scott",
    }
local search_parent =
    sync_ui.Search:new()
backstack.reset(search_parent)
backstack.push(results)
backstack.flush(8)
local results_depth =
    backstack.depth()
assert(
    results_depth == 1,
    "fixture did not create the real Search -> Results backstack"
)

local target =
    assert(
        results.result_models[7]
    )
backstack.focus(target.object)
results.list:scroll_to {
    x = 0,
    y = 58,
    anim = false,
}
backstack.flush(3)

local selected_id =
    target.selection_id
assert(
    results.selected_item_id ==
        selected_id
)

local function focused_offset()
    local list_coordinates =
        results.list:get_coords()
    local target_coordinates =
        target.object:get_coords()
    return
        list_coordinates.y1 -
        target_coordinates.y1
end

local expected_scroll_offset =
    focused_offset()
local base_result_count =
    #results.result_models

local function open_discography()
    assert(backstack.current() == results)
    assert(backstack.depth() == results_depth)
    target.on_long_press()
    local sheet =
        assert(results.track_action_sheet)
    assert(
        sheet:activate(
            "artist_discography"
        )
    )
    assert(
        sheet:activate(
            "artist_discography"
        ),
        "duplicate activation fixture could not exercise the push guard"
    )
    backstack.flush(8)
    assert(
        backstack.depth() ==
            results_depth + 1,
        "Artist discography was not pushed exactly once"
    )
    local artist =
        assert(backstack.current())
    assert(artist ~= results)
    assert(
        artist.header_marquee.text ==
            "Travis Scott"
    )
    return artist
end

local function back_to_results()
    assert(
        navigation.back(),
        "discography did not install a Back handler"
    )
    backstack.flush(10)
    assert(
        backstack.current() == results,
        "Back did not restore Search results"
    )
    assert(
        backstack.depth() ==
            results_depth,
        "Back popped an incorrect number of screens"
    )
    assert(
        results.query == "Travis Scott",
        "Search query was not preserved"
    )
    assert(
        results.ui_active == true,
        "Search results ui_active was not restored"
    )
    assert(
        #results.result_models ==
            base_result_count and
            #results.rows > 1,
        "Search rows disappeared after discography Back"
    )
    assert(
        results.selected_item_id ==
            selected_id,
        "Search logical selection was not restored"
    )
    local focused_model = nil
    for _, model in ipairs(
        results.result_models or {}
    ) do
        if model.selection_id ==
                selected_id then
            focused_model = model
            break
        end
    end
    assert(
        focused_model ~= nil,
        "Search restored selection was not bound to a visible row"
    )
    if not backstack.is_focused(
        focused_model.object
    ) then
        backstack.focus(focused_model.object)
        backstack.flush(2)
    end
    assert(
        backstack.is_focused(
            focused_model.object
        ) or
            focused_model.focused == true,
        "Search focus was not restored"
    )
    local list_coordinates =
        results.list:get_coords()
    local focused_coordinates =
        focused_model.object:get_coords()
    assert(
        focused_coordinates.y1 >=
            list_coordinates.y1 - 1 and
            focused_coordinates.y2 <=
                list_coordinates.y2 + 1,
        "Search restored selection was not visible in the list viewport"
    )
    assert(
        navigation.back ~= nil,
        "Search Back handler was not restored"
    )
end

-- Loading state.
artist_payload = nil
local loading_artist =
    open_discography()
assert(loading_artist.waiting_for_catalog)
assert(artist_request_count == 1)
back_to_results()
local stable_metrics = metrics.snapshot()

-- A late catalog completion may populate the cache, but the retired artist
-- screen must reject the corresponding render after Back.
artist_payload = {
    resolution = "resolved",
    artist = {
        key = "artist-travis-scott",
        name = "Travis Scott",
    },
    groups = {
        {
            id = "albums",
            items = {
                {
                    jellyfin_id =
                        "jellyfin-astroworld",
                    kind = "album",
                    title = "ASTROWORLD",
                    artist = "Travis Scott",
                    artwork_path =
                        "/devices/test/items/" ..
                        "jellyfin-astroworld/" ..
                        "artwork/thumbnail",
                    artwork_revision =
                        "astro-art",
                    device = {
                        state = "server_only",
                        total_tracks = 17,
                        downloaded_tracks = 0,
                    },
                },
            },
        },
    },
}
loading_artist:render()
assert(
    loading_artist.discography_leaving,
    "late response reactivated the retired discography"
)
assert(backstack.current() == results)

-- Populated state and artwork in flight.
local populated_artist =
    open_discography()
local populated_row = nil
for _, row in ipairs(
    populated_artist.rows or {}
) do
    if row.catalog_item and
        row.catalog_item.title ==
            "ASTROWORLD" then
        populated_row = row
        break
    end
end
assert(
    populated_row ~= nil
)
assert(#artwork_requests == 1)
local stale_artwork =
    artwork_requests[1]
local stale_row =
    populated_row
local stale_source =
    stale_row.artwork.current_source
back_to_results()
stale_artwork.callback(
    "/desktop-sim/late-astroworld.png",
    stale_artwork.key
)
assert(
    stale_row.artwork.current_source ==
        stale_source,
    "late discography artwork mutated a retired row"
)

-- Empty and repeated cycles use the same single push/pop lifecycle.
artist_payload = {
    resolution = "resolved",
    artist = {
        key = "artist-travis-scott",
        name = "Travis Scott",
    },
    groups = {},
}
for _ = 1, 3 do
    local empty_artist =
        open_discography()
    assert(#empty_artist.rows == 1)
    back_to_results()
end

artist_payload = {
    resolution = "failed",
    artist = {
        key = "artist-travis-scott",
        name = "Travis Scott",
    },
    error = "Discography unavailable",
    groups = {},
}
local failed_artist =
    open_discography()
assert(#failed_artist.rows == 1)
back_to_results()

local final_metrics = metrics.snapshot()
assert(
    final_metrics.active_objects ==
        stable_metrics.active_objects,
    "repeated discography open/Back leaked LVGL objects"
)

os.execute("rm -rf " .. fixture_root)
print(
    "Sync artist discography Back restores Search across loading, populated, artwork, late, empty, and repeated cycles"
)
os.exit(0)

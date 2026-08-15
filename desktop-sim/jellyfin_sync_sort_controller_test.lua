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

local fixture_root =
    os.tmpname() ..
    "-sync-sort-controller"
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

local payloads = {
    albums = {
        items = {
            {
                jellyfin_id = "album-c",
                kind = "album",
                title = "Charlie",
                artist = "Artist",
                date_created =
                    "2026-01-01T00:00:00Z",
                device = {
                    total_tracks = 1,
                    downloaded_tracks = 0,
                    state = "server_only",
                },
            },
            {
                jellyfin_id = "album-a",
                kind = "album",
                title = "Alpha",
                artist = "Artist",
                date_created =
                    "2026-02-01T00:00:00Z",
                device = {
                    total_tracks = 1,
                    downloaded_tracks = 0,
                    state = "server_only",
                },
            },
        },
    },
    tracks = {
        items = {
            {
                jellyfin_id = "track-c",
                kind = "track",
                title = "Charlie",
                artist = "Artist",
                date_created =
                    "2026-01-01T00:00:00Z",
            },
            {
                jellyfin_id = "track-a",
                kind = "track",
                title = "Alpha",
                artist = "Artist",
                date_created =
                    "2026-02-01T00:00:00Z",
            },
        },
    },
}
local requests = {}
package.loaded["sync_catalog"] = {
    cached = function(view)
        return payloads[view]
    end,
    start = function(
        view,
        cursor,
        limit,
        options
    )
        requests[#requests + 1] = {
            view = view,
            cursor = cursor,
            limit = limit,
            sort = options.sort,
            direction =
                options.direction,
        }
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
}
package.loaded["sync_artwork_cache"] = {
    key = function(item)
        return tostring(
            item.jellyfin_id or
            item.key or ""
        )
    end,
    request = function()
        return nil
    end,
    poll = function()
    end,
}

local jellyfin_list_ui =
    require("jellyfin_list_ui")
local original_sort_controller =
    jellyfin_list_ui.add_sort_control
local controller_owners = {}
jellyfin_list_ui.add_sort_control =
    function(owner, options)
        controller_owners[owner] = {
            factory =
                original_sort_controller,
            options = options,
        }
        return original_sort_controller(
            owner,
            options
        )
    end

package.loaded["sync_sort"] = nil
package.loaded["jellyfin_sync_ui"] = nil
local sync_sort = require("sync_sort")
local sync_ui =
    require("jellyfin_sync_ui")

local albums =
    sync_ui.Catalog:new {
        title = "Albums",
        view = "albums",
    }
simulator.backstack.reset(albums)

local tracks =
    sync_ui.Catalog:new {
        title = "Tracks",
        view = "tracks",
    }
tracks:create_ui()

assert(
    controller_owners[albums] and
        controller_owners[albums]
            .factory ==
            original_sort_controller,
    "Albums did not instantiate jellyfin_list_ui.add_sort_control"
)
assert(
    controller_owners[tracks] and
        controller_owners[tracks]
            .factory ==
            original_sort_controller,
    "Tracks did not instantiate jellyfin_list_ui.add_sort_control"
)
assert(
    albums.sort_overlay and
        albums.sort_menu_models and
        albums.open_sort_menu and
        albums.close_sort_menu,
    "Albums did not receive the original Sort controller state"
)
assert(
    tracks.sort_overlay and
        tracks.sort_menu_models and
        tracks.open_sort_menu and
        tracks.close_sort_menu,
    "Tracks did not receive the original Sort controller state"
)
assert(
    albums.track_action_sheet == nil and
        tracks.track_action_sheet ==
            nil,
    "Sync Sort still instantiated the generic track-action bottom sheet"
)

for _, page in ipairs({
    albums,
    tracks,
}) do
    assert(#page.sort_menu_models == 2)
    assert(
        page.sort_menu_models[1]
            .label_text == "Title"
    )
    assert(
        page.sort_menu_models[2]
            .label_text ==
            "Date added"
    )
    for _, model in ipairs(
        page.sort_menu_models
    ) do
        assert(
            model.method ~= "artist"
        )
    end
end

assert(
    sync_sort.current("tracks") ==
        "title_asc",
    "Tracks did not default to A-Z after migration"
)

lvgl.group.focus_obj(
    albums.sort_row.object
)
albums.open_sort_menu()
assert(albums.sort_menu_open)
assert(
    albums.focus_group:get_focused() ==
        albums.sort_menu_models[1]
            .object,
    "original Sort controller did not focus the current option"
)

albums.focus_group:focus_next()
assert(
    albums.sort_selected_method ==
        "recent",
    "original Sort controller rotary movement did not reach Date added"
)
assert(
    sync_sort.current("albums") ==
        "title_asc",
    "rotary highlight persisted before the Sort popup closed"
)
assert(
    albums.go_back() == nil,
    "Sort Back returned an unexpected value"
)
assert(
    not albums.sort_menu_open and
        sync_sort.current("albums") ==
            "date_added" and
        #requests == 1,
    "closing Sort did not apply the highlighted Date-added/New selection"
)
assert(
    requests[#requests].sort ==
        "date_added" and
        requests[#requests].direction ==
            "descending",
    "highlighted Date added did not reload New-first ordering"
)

lvgl.group.focus_obj(
    albums.sort_row.object
)
albums.open_sort_menu()
assert(
    albums.focus_group:get_focused() ==
        albums.sort_menu_models[2]
            .object,
    "current Date-added field was not genuinely focused"
)
albums.sort_menu_models[2].on_click()
assert(
    albums.sort_menu_open,
    "Sort activation closed the popup instead of reusing the established controller"
)
assert(
    sync_sort.current("albums") ==
        "date_added",
    "direction toggle persisted before the Sort popup closed"
)
albums.close_sort_menu(false)
assert(
    sync_sort.current("albums") ==
        "date_added_asc",
    "Date-added activation did not toggle New to Old"
)
assert(
    requests[#requests].sort ==
        "date_added" and
        requests[#requests].direction ==
            "ascending",
    "Old did not reload DateCreated in ascending order"
)

lvgl.group.focus_obj(
    albums.sort_row.object
)
albums.open_sort_menu()
albums.focus_group:focus_prev()
assert(
    sync_sort.current("albums") ==
        "date_added_asc",
    "Title highlight persisted before the Sort popup closed"
)
albums.close_sort_menu(false)
assert(
    sync_sort.current("albums") ==
        "title_asc",
    "closing Sort did not apply the highlighted Title/A-Z selection"
)
assert(
    requests[#requests].sort ==
        "title" and
        requests[#requests].direction ==
            "ascending",
    "A-Z did not reload the catalog globally"
)

lvgl.group.focus_obj(
    albums.sort_row.object
)
albums.open_sort_menu()
albums.sort_menu_models[1].on_click()
assert(
    albums.focus_group:get_focused() ==
        albums.sort_menu_models[1].object,
    "Mouse selection did not move the visible Sort focus to A-Z"
)
assert(
    albums.sort_menu_open,
    "Title activation closed the Sort popup"
)
assert(
    sync_sort.current("albums") ==
        "title_asc",
    "Title direction persisted before the Sort popup closed"
)
albums.close_sort_menu(false)
assert(
    sync_sort.current("albums") ==
        "title_desc",
    "Mouse1 activation did not toggle Title from A-Z to Z-A"
)
assert(
    requests[#requests].sort ==
        "title" and
        requests[#requests].direction ==
            "descending",
    "Z-A did not reload the catalog globally"
)
assert(
    albums.items[1].jellyfin_id ==
        "album-c",
    "Z-A did not immediately reorder the complete list"
)

lvgl.group.focus_obj(
    albums.sort_row.object
)
albums.open_sort_menu()
albums.go_back()
assert(
    albums.focus_group:get_focused() ==
        albums.sort_row.object,
    "original Sort controller did not restore focus to Sort"
)

jellyfin_list_ui.add_sort_control =
    original_sort_controller
os.execute("rm -rf " .. fixture_root)
print(
    "Sync Albums and Tracks reuse the original field/direction Sort controller"
)
os.exit(0)

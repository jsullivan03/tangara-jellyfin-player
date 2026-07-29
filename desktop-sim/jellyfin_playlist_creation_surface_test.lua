package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local pushed = nil
package.loaded["backstack"] = {
    pop = function()
    end,
    push = function(page)
        pushed = page
    end,
}

package.loaded["jellyfin_collection_playback"] = {
    play = function()
    end,
}
package.loaded["jellyfin_now_playing"] = {}
package.loaded["jellyfin_playback"] = {}
package.loaded["jellyfin_local_index"] = {
    load = function()
        return {
            albums = {},
        }
    end,
}
package.loaded["jellyfin_sort"] = {}
package.loaded["jellyfin_track_action_sheet"] = {
    attach = function()
        return {}
    end,
}

local opened_playlist = nil
package.loaded["jellyfin_playlist_action_sheet"] = {
    attach = function()
        return {
            open = function(_, playlist)
                opened_playlist = playlist
            end,
        }
    end,
}

package.loaded["jellyfin_text_entry"] = {
    new = function(options)
        return options
    end,
}

package.loaded["sync_library_view"] = {
    current = function()
        return {
            favorites = {
                name = "Favorites",
                items = {},
            },
            playlists = {
                {
                    id = "playlist-1",
                    name = "Playlist 1",
                    items = {},
                },
                {
                    id = "local:playlist-2",
                    local_id = "local:playlist-2",
                    name = "Offline Mix",
                    items = {},
                    pending = true,
                },
            },
        }
    end,
}

local created_name = nil
package.loaded["sync_operation_queue"] = {
    enqueue_create_playlist = function(name, items)
        created_name = name
        assert(#items == 0)
        return "local:new-playlist", {}
    end,
}

for _, name in ipairs({
    "jellyfin_marquee",
    "jellyfin_scroll_indicator",
    "jellyfin_list_ui",
    "jellyfin_library",
}) do
    package.loaded[name] = nil
end

local LibraryScreen = dofile("lua/jellyfin_library.lua")
local page = LibraryScreen:new()

page:create_ui()
page:on_show()

assert(
    #page.playlist_rows == 3 and
        #page.list_rows == 4,
    "Playlists page did not keep semantic playlist rows separate from Create"
)
local create_row_coordinates =
    page.create_playlist_row.object:get_coords()
local create_label_coordinates =
    page.create_playlist_row.label.view:get_coords()

assert(
    page.create_playlist_row.selection_id ==
            "control:create-playlist" and
        page.list_rows[1] ==
            page.create_playlist_row and
        page.first_row ==
            page.playlist_rows[1].object and
        lvgl.group.get_default():get_focused() ==
            page.playlist_rows[1].object and
        create_label_coordinates.y1 -
            create_row_coordinates.y1 == 5,
    "Playlists page did not keep a vertically centered Create row above the default Favorites selection"
)

page.create_playlist_row.on_click()
assert(
    pushed and pushed.title == "New playlist",
    "Create playlist did not open rotary text entry"
)

local accepted, error_message =
    pushed.on_submit("Road Trip")
assert(
    accepted == true and
        error_message == nil and
        created_name == "Road Trip" and
        page.selected_item_id ==
            "local:new-playlist" and
        page.needs_playlist_rebuild == true,
    "Creating a playlist did not queue it offline and mark the page for refresh"
)

page.playlist_rows[2].on_long_press()
assert(
    opened_playlist and
        opened_playlist.id == "playlist-1",
    "Long-holding a normal playlist did not open playlist actions"
)
assert(
    page.playlist_rows[1].on_long_press == nil,
    "Favorites unexpectedly exposed rename/delete actions"
)

page:on_hide()

print(
    "Playlists expose scroll-up creation, offline optimistic refresh, and long-hold actions"
)
os.exit(0)

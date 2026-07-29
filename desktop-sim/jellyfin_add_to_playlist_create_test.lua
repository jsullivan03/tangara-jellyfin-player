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

package.loaded["jellyfin_local_library"] = {
    Artist = {
        new = function(_, options)
            return options
        end,
    },
}
package.loaded["jellyfin_text_entry"] = {
    new = function(options)
        return options
    end,
}
package.loaded["sync_library_view"] = {
    current = function()
        return {
            favorites = {items = {}},
            playlists = {
                {
                    id = "playlist-1",
                    name = "Playlist 1",
                    items = {},
                },
            },
        }
    end,
}

local created = nil
package.loaded["sync_operation_queue"] = {
    enqueue_set_favorite = function()
        return {}
    end,
    enqueue_add_playlist_item = function()
        return {}
    end,
    enqueue_remove_playlist_item = function()
        return {}
    end,
    enqueue_create_playlist = function(name, ids)
        created = {name = name, ids = ids}
        return "local:new", {}
    end,
}
package.loaded["jellyfin_navigation"] = {
    set_back = function()
    end,
    clear_back = function()
    end,
}

for _, name in ipairs({
    "jellyfin_marquee",
    "jellyfin_scroll_indicator",
    "jellyfin_list_ui",
    "jellyfin_track_action_sheet",
}) do
    package.loaded[name] = nil
end

local list_ui = require("jellyfin_list_ui")
local track_sheet =
    require("jellyfin_track_action_sheet")

local owner = {}
list_ui.create_root(owner, "Tracks")
local row = list_ui.add_action_row(
    owner,
    "Track 1",
    {selection_id = "track-1"}
)
owner.first_row = row.object
list_ui.install_controls(owner)

local sheet = track_sheet.attach(owner)
sheet:open(
    {
        id = "track-1",
        title = "Track 1",
        artist = "Artist 1",
        artist_key = "id:artist-1",
    },
    {collection_kind = "local_tracks"},
    {jellyfin_id = "track-1"}
)

lvgl.Timer {
    period = 240,
    repeat_count = 1,
    cb = function()
        local ok, failure = pcall(function()
            assert(sheet:activate("add_to_playlist"))
        end)

        if not ok then
            io.stderr:write(tostring(failure), "\n")
            os.exit(1)
        end
    end,
}

lvgl.Timer {
    period = 700,
    repeat_count = 1,
    cb = function()
        local ok, failure = pcall(function()
            local state = sheet:state()

            assert(
                state.page == "playlists",
                "Add-to-playlist sheet did not open the playlist page"
            )
            assert(
                state.playlist_count == 2,
                "Add-to-playlist sheet exposed the wrong number of choices: " ..
                    tostring(state.playlist_count)
            )
            assert(
                state.playlist_labels[1] == "Create playlist" and
                    state.playlist_labels[2] == "Playlist 1",
                "Add-to-playlist choices were not ordered as Create playlist then existing playlists"
            )
            assert(
                state.playlist_header_visible == false,
                "Add-to-playlist restored the redundant header"
            )
            assert(
                state.playlist_initial_label == "Playlist 1",
                "Add-to-playlist did not initially focus the first existing playlist: " ..
                    tostring(state.playlist_initial_label)
            )
            assert(
                state.playlist_initial_scroll_y == 15 and
                    state.playlist_create_hidden_on_open == true,
                "Add-to-playlist did not request the one-row initial offset: " ..
                    tostring(state.playlist_initial_scroll_y)
            )

            assert(
                sheet:activate_playlist(
                    "Create playlist"
                ),
                "Create playlist option could not be activated"
            )
            assert(
                pushed and
                    pushed.title == "New playlist",
                "Create from Add to playlist did not open text entry"
            )
            assert(pushed.on_submit("Instant Mix"))
            assert(
                created and
                    created.name == "Instant Mix" and
                    #created.ids == 1 and
                    created.ids[1] == "track-1",
                "Created playlist did not include the active song atomically"
            )

            list_ui.restore_controls(owner)
            print(
                "Add to playlist exposes scroll-up creation and includes the active track"
            )
            os.exit(0)
        end)

        if not ok then
            io.stderr:write(tostring(failure), "\n")
            os.exit(1)
        end
    end,
}

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

package.loaded["jellyfin_text_entry"] = {
    new = function(options)
        return options
    end,
}

package.loaded["jellyfin_navigation"] = {
    set_back = function()
    end,
    clear_back = function()
    end,
}

local active = {
    track = {
        id = "track-1",
        title = "Track 1",
        artist = "Artist 1",
        artist_key = "id:artist-1",
        duration = 180,
    },
    context = {
        server_connected = true,
    },
}

package.loaded["jellyfin_playback"] = {
    current = function()
        return active
    end,
    sync_position = function()
        return active
    end,
}

package.loaded["sync_config"] = {
    status = function()
        return {connected = true}
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

package.loaded["sync_runtime"] = {
    last_library_result = function()
        return {ok = true}
    end,
}

for _, name in ipairs({
    "jellyfin_now_playing",
    "jellyfin_track_actions",
}) do
    package.loaded[name] = nil
end

local NowPlaying = require("jellyfin_now_playing")
local page = NowPlaying:new()
page:create_ui()
page:open_sheet()

lvgl.Timer {
    period = 240,
    repeat_count = 1,
    cb = function()
        local ok, failure = pcall(function()
            assert(
                page.activate_sheet_action(
                    "add_to_playlist"
                ),
                "Now Playing Add to playlist action could not be activated"
            )
        end)

        if not ok then
            io.stderr:write(tostring(failure), "\n")
            os.exit(1)
        end
    end,
}

lvgl.Timer {
    period = 720,
    repeat_count = 1,
    cb = function()
        local ok, failure = pcall(function()
            local state = page.sheet_focus_state()

            assert(
                state.page == "playlists",
                "Now Playing did not open the playlist chooser"
            )
            assert(
                state.playlist_count == 2,
                "Now Playing exposed the wrong number of playlist choices: " ..
                    tostring(state.playlist_count)
            )
            assert(
                state.playlist_labels[1] == "Create playlist" and
                    state.playlist_labels[2] == "Playlist 1",
                "Now Playing playlist choices were not ordered correctly"
            )
            assert(
                state.playlist_header_visible == false,
                "Now Playing restored the redundant Add to playlist header"
            )
            assert(
                state.playlist_initial_label == "Playlist 1",
                "Now Playing did not initially focus the first existing playlist: " ..
                    tostring(state.playlist_initial_label)
            )
            assert(
                state.playlist_initial_scroll_y == 15 and
                    state.playlist_create_hidden_on_open == true,
                "Now Playing did not request the one-row initial offset: " ..
                    tostring(state.playlist_initial_scroll_y)
            )

            assert(
                page.activate_playlist_action(
                    "Create playlist"
                ),
                "Now Playing Create playlist option could not be activated"
            )
            assert(
                pushed and
                    pushed.title == "New playlist",
                "Now Playing Create playlist did not open text entry"
            )
            assert(pushed.on_submit("Instant Mix"))
            assert(
                created and
                    created.name == "Instant Mix" and
                    #created.ids == 1 and
                    created.ids[1] == "track-1",
                "Now Playing-created playlist did not include the active track atomically"
            )

            print(
                "Now Playing Add to playlist replaces Back with Create playlist and includes the active track"
            )
            os.exit(0)
        end)

        if not ok then
            io.stderr:write(tostring(failure), "\n")
            os.exit(1)
        end
    end,
}

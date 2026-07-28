package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

package.loaded["jellyfin_navigation"] = {
    set_back = function()
    end,
    clear_back = function()
    end,
}

local initial = {
    track = {
        id = "track-1",
        title = "Initial Track",
        artist = "Test Artist",
        artist_key = "id:artist-1",
        duration = 180,
    },
    context = {
        server_connected = true,
    },
}

package.loaded["jellyfin_playback"] = {
    current = function()
        return initial
    end,
    sync_position = function()
        return initial
    end,
}

package.loaded["sync_config"] = {
    status = function()
        return {
            connected = true,
        }
    end,
}

package.loaded["sync_library_view"] = {
    current = function()
        return {
            favorites = {
                items = {},
            },
            playlists = {},
        }
    end,
}

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
}

package.loaded["sync_runtime"] = {
    last_library_result = function()
        return {
            ok = true,
        }
    end,
}

local NowPlaying =
    require("jellyfin_now_playing")
local page = NowPlaying:new()

page:create_ui()
page.refresh_active {
    track = {
        id = "track-2",
        title = "Playlist Track",
        artist = "Playlist Artist",
        duration = 210,
    },
    item = {
        artist = "Playlist Artist",
        artist_id = "artist-2",
    },
    context = {
        server_connected = true,
        collection_kind = "playlist",
        collection_id = "playlist-1",
        entry_id = "entry-1",
    },
}
page:open_sheet()

lvgl.Timer {
    period = 240,
    repeat_count = 1,
    cb = function()
        local ok, failure = pcall(
            function()
                local state =
                    page.sheet_focus_state()

                assert(
                    state.main_count == 4 and
                        state.active_count == 4,
                    "Now Playing did not rebuild its sheet for the updated playlist context"
                )

                assert(
                    state.main_actions[1] ==
                            "artist" and
                        state.main_actions[2] ==
                            "favorite" and
                        state.main_actions[3] ==
                            "add_to_playlist" and
                        state.main_actions[4] ==
                            "remove_from_playlist",
                    "Now Playing rebuilt the playlist actions in the wrong order"
                )
            end
        )

        if not ok then
            io.stderr:write(
                tostring(failure),
                "\n"
            )
            os.exit(1)
        end

        print(
            "Now Playing rebuilds contextual actions when the active queue item changes"
        )
        os.exit(0)
    end,
}

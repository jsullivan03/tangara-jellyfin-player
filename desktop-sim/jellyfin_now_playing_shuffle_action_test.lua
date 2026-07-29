package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local queue = require("queue")

package.loaded["jellyfin_navigation"] = {
    set_back = function()
    end,
    clear_back = function()
    end,
}

package.loaded["jellyfin_playback"] = {
    current = function()
        return {
            track = {
                id = "track-1",
                title = "Shuffle Action",
                artist = "Test Artist",
                artist_key = "id:artist-1",
                duration = 180,
            },
            context = {
                server_connected = true,
            },
        }
    end,
    sync_position = function()
        return package.loaded[
            "jellyfin_playback"
        ].current()
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
        return {ok = true}
    end,
}

queue.random:set(false)

local NowPlaying =
    require("jellyfin_now_playing")
local page = NowPlaying:new()

page:create_ui()
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
                    state.main_actions[1] ==
                        "queue" and
                        state.main_actions[2] ==
                        "shuffle",
                    "Queue and shuffle were not the first Now Playing actions"
                )
                assert(
                    page.activate_sheet_action(
                        "shuffle"
                    ) == true,
                    "Now Playing shuffle action was unavailable"
                )
                assert(
                    queue.random:get() == true,
                    "Now Playing shuffle action did not enable native shuffle"
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
            "Now Playing toggles the native queue shuffle state"
        )
        os.exit(0)
    end,
}

package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local pushed
local backstack = require("backstack")

backstack.push = function(value)
    pushed = value
end

package.loaded["jellyfin_local_library"] = {
    Artist = {
        new = function(_, values)
            return values
        end,
    },
}

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
                title = "Artist Action Test",
                artist = "Test Artist",
                duration = 180,
            },
            item = {
                artist = "Test Artist",
                artist_id = "artist-1",
            },
            context = {
                server_connected = true,
                collection_kind = "playlist",
                collection_id = "playlist-1",
                entry_id = "entry-1",
            },
        }
    end,
    sync_position = function()
        return package.loaded["jellyfin_playback"].current()
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
page:open_sheet()

lvgl.Timer {
    period = 240,
    repeat_count = 1,
    cb = function()
        assert(
            page.activate_sheet_action(
                "artist"
            ) == true,
            "Go to artist action was unavailable"
        )

        lvgl.Timer {
            period = 30,
            repeat_count = 1,
            cb = function()
                local ok, failure = pcall(
                    function()
                        assert(
                            pushed and
                                pushed.artist_key ==
                                    "id:artist-1" and
                                pushed.title ==
                                    "Test Artist",
                            "Go to artist did not push the matching local artist screen"
                        )

                        assert(
                            page.sheet_open == false,
                            "Go to artist did not dismiss the Now Playing sheet"
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
                    "Now Playing Go to artist opens the matching local artist screen"
                )
                os.exit(0)
            end,
        }
    end,
}

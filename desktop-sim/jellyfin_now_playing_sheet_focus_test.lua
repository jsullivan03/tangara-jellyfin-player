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

package.loaded["jellyfin_playback"] = {
    current = function()
        return {
            track = {
                id = "track-1",
                title = "Focus Test",
                artist = "Test Artist",
                duration = 180,
            },
            context = {
                server_connected = true,
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
        local ok, failure = pcall(
            function()
                local state =
                    page.sheet_focus_state()

                assert(
                    state.page == "main" and
                        state.main_count == 2 and
                        state.active_count == 2 and
                        state.wrap_disabled == true,
                    "Now Playing main sheet did not restrict focus to its two visible options"
                )

                local group =
                    assert(lvgl.group.get_default())

                local first =
                    assert(group:get_focused())

                group:focus_next()
                local second =
                    assert(group:get_focused())

                assert(
                    second ~= first,
                    "main sheet did not move to its second option"
                )

                group:focus_next()
                group:focus_next()

                assert(
                    group:get_focused() == second,
                    "main sheet wrapped or focused an invisible option below its last visible option"
                )

                group:focus_prev()
                assert(
                    group:get_focused() == first,
                    "main sheet did not move back to its first option"
                )

                group:focus_prev()
                group:focus_prev()

                assert(
                    group:get_focused() == first,
                    "main sheet wrapped or focused an invisible option above its first visible option"
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
            "Now Playing sheet focus is limited to visible options without wrapping"
        )
        os.exit(0)
    end,
}

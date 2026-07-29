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
                artist_key = "id:artist-1",
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
                        state.main_count == 5 and
                        state.active_count == 5 and
                        state.wrap_disabled == true,
                    "Now Playing main sheet did not restrict focus to its five visible options"
                )

                assert(
                    state.main_actions[1] ==
                            "queue" and
                        state.main_actions[2] ==
                            "shuffle" and
                        state.main_actions[3] ==
                            "artist" and
                        state.main_actions[4] ==
                            "favorite" and
                        state.main_actions[5] ==
                            "add_to_playlist",
                    "Now Playing main sheet actions were not built in the expected order"
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
                local third =
                    assert(group:get_focused())

                assert(
                    third ~= second and
                        third ~= first,
                    "main sheet did not move to its third option"
                )

                group:focus_next()
                local fourth =
                    assert(group:get_focused())

                assert(
                    fourth ~= third and
                        fourth ~= second and
                        fourth ~= first,
                    "main sheet did not move to its fourth option"
                )

                group:focus_next()
                local fifth =
                    assert(group:get_focused())

                assert(
                    fifth ~= fourth and
                        fifth ~= third and
                        fifth ~= second and
                        fifth ~= first,
                    "main sheet did not move to its fifth option"
                )

                group:focus_next()
                group:focus_next()

                assert(
                    group:get_focused() == fifth,
                    "main sheet wrapped or focused an invisible option below its last visible option"
                )

                group:focus_prev()
                assert(
                    group:get_focused() == fourth,
                    "main sheet did not move back to its fourth option"
                )

                group:focus_prev()
                assert(
                    group:get_focused() == third,
                    "main sheet did not move back to its third option"
                )

                group:focus_prev()
                assert(
                    group:get_focused() == second,
                    "main sheet did not move back to its second option"
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
            "Now Playing dynamic sheet includes Go to artist and limits focus to visible options"
        )
        os.exit(0)
    end,
}

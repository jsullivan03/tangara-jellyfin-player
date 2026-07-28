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
                title = "Exclusive Highlight",
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
                local group =
                    assert(
                        lvgl.group.get_default()
                    )
                local first =
                    assert(group:get_focused())

                assert(
                    page.sheet_focus_state()
                        .highlighted_action ==
                        "artist",
                    "first Now Playing action was not the sole visual selection"
                )

                group:focus_next()
                assert(
                    page.sheet_focus_state()
                        .highlighted_action ==
                        "favorite",
                    "Now Playing highlight did not follow the second focused action"
                )

                group:focus_next()
                local third =
                    assert(group:get_focused())

                assert(
                    page.sheet_focus_state()
                        .highlighted_action ==
                        "add_to_playlist",
                    "Now Playing highlight did not follow the final focused action"
                )

                -- Reproduce the visual failure mode: an old row retains a
                -- focused state while another row is the real group focus.
                first:add_state(
                    lvgl.STATE.FOCUSED |
                    lvgl.STATE.FOCUS_KEY
                )
                lvgl.group.focus_obj(third)

                assert(
                    first:get_state() &
                            lvgl.STATE.FOCUSED ==
                        0,
                    "exclusive highlight refresh left a stale row focused"
                )
                assert(
                    third:get_state() &
                            lvgl.STATE.FOCUSED ~=
                        0,
                    "exclusive highlight refresh cleared the real focused row"
                )
                assert(
                    page.sheet_focus_state()
                        .highlighted_action ==
                        "add_to_playlist",
                    "exclusive highlight refresh changed the selected action"
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
            "Now Playing clears stale row focus and keeps exactly one highlighted action"
        )
        os.exit(0)
    end,
}

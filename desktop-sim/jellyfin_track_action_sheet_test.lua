package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local pushed_artist = nil

package.loaded["backstack"] = {
    pop = function()
    end,
    push = function(page)
        pushed_artist = page
    end,
}

package.loaded["jellyfin_local_library"] = {
    Artist = {
        new = function(_, options)
            return options
        end,
    },
}

package.loaded["sync_config"] = {
    status = function()
        return {
            configured = true,
            started = true,
            connected = true,
        }
    end,
}

package.loaded["sync_runtime"] = {
    last_library_result = function()
        return {ok = true}
    end,
    last_result = function()
        return {ok = true}
    end,
}

package.loaded["sync_library_view"] = {
    current = function()
        return {
            favorites = {
                items = {},
            },
            playlists = {
                {
                    id = "playlist-1",
                    name = "Playlist 1",
                },
            },
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

for _, module_name in ipairs({
    "jellyfin_marquee",
    "jellyfin_scroll_indicator",
    "jellyfin_list_ui",
    "jellyfin_track_action_sheet",
}) do
    package.loaded[module_name] = nil
end

local jellyfin_list_ui =
    require("jellyfin_list_ui")
local track_action_sheet =
    require("jellyfin_track_action_sheet")

local owner = {}

jellyfin_list_ui.create_root(
    owner,
    "Tracks"
)

local sheet =
    track_action_sheet.attach(owner)

local track = {
    id = "track-1",
    title = "Track 1",
    artist = "Artist 1",
    artist_key = "id:artist-1",
}

local row =
    jellyfin_list_ui.add_track_row(
        owner,
        track,
        {
            detail = track.artist,
            on_long_press =
                function()
                    sheet:open(
                        track,
                        {
                            collection_kind =
                                "local_tracks",
                        },
                        track
                    )
                end,
        }
    )

owner.first_row = row.object

jellyfin_list_ui.install_controls(owner)
row.on_long_press()

lvgl.Timer {
    period = 240,
    repeat_count = 1,
    cb = function()
        local ok, failure = pcall(
            function()
                local state = sheet:state()

                assert(
                    state.open and
                        not state.animating and
                        state.main_count == 3 and
                        state.active_count == 3,
                    "list track action sheet did not open with three normal actions"
                )
                assert(
                    state.main_actions[1] ==
                            "artist" and
                        state.main_actions[2] ==
                            "favorite" and
                        state.main_actions[3] ==
                            "add_to_playlist",
                    "list track action sheet used the wrong action order"
                )
                assert(
                    state.highlighted_action ==
                        "artist",
                    "list action sheet did not focus exactly its first action"
                )

                local group =
                    assert(lvgl.group.get_default())

                assert(
                    group:get_focused() ~=
                        row.object,
                    "list row remained focused behind the action sheet"
                )

                owner.go_back()
            end
        )

        if not ok then
            io.stderr:write(
                tostring(failure),
                "\n"
            )
            os.exit(1)
        end
    end,
}

lvgl.Timer {
    period = 500,
    repeat_count = 1,
    cb = function()
        local ok, failure = pcall(
            function()
                assert(
                    not sheet:state().open,
                    "list action sheet did not close through the screen back handler"
                )
                assert(
                    lvgl.group.get_default()
                        :get_focused() ==
                        row.object,
                    "closing the list action sheet did not restore the selected row"
                )

                sheet:open(
                    track,
                    {
                        collection_kind =
                            "playlist",
                        collection_id =
                            "playlist-1",
                        entry_id = "entry-1",
                    },
                    track
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
    end,
}

lvgl.Timer {
    period = 750,
    repeat_count = 1,
    cb = function()
        local ok, failure = pcall(
            function()
                local state = sheet:state()

                assert(
                    state.main_count == 4 and
                        state.main_actions[4] ==
                            "remove_from_playlist",
                    "playlist list action sheet did not add Remove from playlist"
                )

                assert(
                    sheet:activate("artist"),
                    "list action sheet could not activate Go to artist"
                )
                assert(
                    pushed_artist and
                        pushed_artist.artist_key ==
                            "id:artist-1",
                    "list Go to artist did not push the matching local artist page"
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
            "Track action sheet opens from list rows, restores focus, and keeps playlist context"
        )
        os.exit(0)
    end,
}

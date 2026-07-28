package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local playback = require("playback")
local queue = require("queue")
local controls = require("controls")
local volume = require("volume")

local tracks = {
    {
        track = {
            id = "track-1",
            title = "First",
            artist = "Artist",
            duration = 180,
            artwork = {
                cover = "track-cover-1",
                background =
                    "track-background-1",
            },
        },
        item = {
            duration = 180,
            artwork = {
                cover = "//lua/img/cover_placeholder.png",
                background =
                    "//lua/img/background_placeholder.png",
            },
        },
        context = {
            collection_kind = "local_tracks",
            server_connected = true,
        },
    },
    {
        track = {
            id = "track-2",
            title = "Second",
            artist = "Artist",
            duration = 180,
            artwork = {
                cover = "track-cover-2",
                background =
                    "track-background-2",
            },
        },
        item = {
            duration = 180,
            artwork = {
                cover = "//lua/img/cover_placeholder.png",
                background =
                    "//lua/img/background_placeholder.png",
            },
        },
        context = {
            collection_kind = "local_tracks",
            server_connected = true,
        },
    },
    {
        track = {
            id = "track-3",
            title = "Third",
            artist = "Artist",
            duration = 180,
            artwork = {
                cover = "track-cover-3",
                background =
                    "track-background-3",
            },
        },
        item = {
            duration = 180,
            artwork = {
                cover = "//lua/img/cover_placeholder.png",
                background =
                    "//lua/img/background_placeholder.png",
            },
        },
        context = {
            collection_kind = "local_tracks",
            server_connected = true,
        },
    },
}

local active_index = 2
local next_calls = 0
local previous_calls = 0

queue.size:set(#tracks)
queue.position:set(active_index - 1)
playback.position:set(60)
playback.playing:set(true)

package.loaded["jellyfin_navigation"] = {
    set_back = function()
    end,
    clear_back = function()
    end,
}

package.loaded["jellyfin_playback"] = {
    current = function()
        return tracks[active_index]
    end,
    sync_position = function(position)
        local logical_position = position + 1

        if logical_position >= 1 and
            logical_position <= #tracks then
            active_index = logical_position
        end
        return tracks[active_index]
    end,
    next = function()
        next_calls = next_calls + 1
        active_index =
            math.min(
                #tracks,
                active_index + 1
            )
        queue.position:set(active_index - 1)
        playback.position:set(0)
        return tracks[active_index]
    end,
    previous = function()
        previous_calls =
            previous_calls + 1
        active_index =
            math.max(
                1,
                active_index - 1
            )
        queue.position:set(active_index - 1)
        playback.position:set(0)
        return tracks[active_index]
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

local sim_mode = false

_G.tangara_sim_set_transport_mode =
    function(enabled)
        sim_mode = enabled == true
    end

local hooks = controls.hooks().wheel
local previous_left = function()
end
local previous_right = function()
end

hooks.left.click = previous_left
hooks.right.click = previous_right

local NowPlaying =
    require("jellyfin_now_playing")
local page = NowPlaying:new()

page:create_ui()
page:on_show()

local initial_media =
    page.view:media_state()
local initial_text =
    page.view:media_text_layout_state()

local function expected_text_x(state)
    if state.text_width >
            state.view_width then
        return 0
    end

    return math.max(
        0,
        math.floor(
            (
                state.view_width -
                state.text_width
            ) / 2
        )
    )
end

assert(
    initial_text.title.measured and
        initial_text.artist.measured and
        math.abs(
            initial_text.title.relative_x -
            expected_text_x(
                initial_text.title
            )
        ) <= 1 and
        math.abs(
            initial_text.artist.relative_x -
            expected_text_x(
                initial_text.artist
            )
        ) <= 1,
    "initial Now Playing title or artist was not centered by on_show"
)

assert(
    initial_media.cover ==
        "track-cover-2" and
        initial_media.background ==
            "track-background-2" and
        initial_media.title == "Second",
    "initial Now Playing media did not prefer the real per-track artwork"
)

assert(sim_mode == true)
assert(
    hooks.left.click ==
        page.previous_track
)
assert(
    hooks.right.click ==
        page.next_track
)
assert(
    page.transport_state().seek_pending == false,
    "installing the physical seek focus sentinels triggered an accidental seek"
)

assert(page.transport("seek", 2))

local preview = page.transport_state()

assert(preview.seek_pending == true)
assert(preview.seek_target == 70)
assert(playback.position:get() == 60)

assert(page.transport("volume_up", 2))
assert(volume.current_pct:get() == 60)
assert(page.transport("volume_down", 1))
assert(volume.current_pct:get() == 55)

assert(page.transport("next"))
assert(next_calls == 1)
assert(active_index == 3)

local next_media =
    page.view:media_state()

assert(
    next_media.cover ==
        "track-cover-3" and
        next_media.background ==
            "track-background-3" and
        next_media.title == "Third" and
        next_media.cover_x == 47 and
        next_media.title_y == 83 and
        next_media.artist_y == 95,
    "next-track artwork or fixed text layout did not refresh"
)

assert(page.transport("previous"))
assert(previous_calls == 1)
assert(active_index == 2)

-- Start a fresh buffered seek after the track-navigation checks.
playback.position:set(60)
assert(page.transport("seek", 2))

lvgl.Timer {
    period = 340,
    repeat_count = 1,
    cb = function()
        local ok, failure = pcall(
            function()
                assert(
                    playback.position:get() ==
                        70,
                    "buffered wheel seek did not commit after the quiet period"
                )

                page:open_sheet()
                assert(
                    sim_mode == false,
                    "simulator transport events were not released to the options sheet"
                )
                assert(
                    page.transport(
                        "seek",
                        1
                    ) == false,
                    "seeking should be disabled while the sheet is open"
                )

                page:on_hide()

                assert(sim_mode == false)
                assert(
                    _G.tangara_sim_transport_event ==
                        nil,
                    "simulator transport callback remained installed after hiding"
                )
                assert(
                    hooks.left.click ==
                        previous_left and
                        hooks.right.click ==
                        previous_right,
                    "physical left/right click hooks were not restored"
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
            "Now Playing queue controls, buffered seek, volume keys, and hook restoration passed"
        )
        os.exit(0)
    end,
}

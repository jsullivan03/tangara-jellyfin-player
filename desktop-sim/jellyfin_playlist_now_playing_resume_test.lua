package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
local firmware_backstack =
    require("firmware_backstack")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

package.loaded["backstack"] =
    firmware_backstack
package.preload["backstack"] =
    function()
        return firmware_backstack
    end

local screen = require("screen")
local track_identity =
    require("jellyfin_track_identity")

local root =
    "/tmp/tangara-playlist-np-resume"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

package.loaded["device"] = nil
package.preload["device"] = function()
    return {
        id = function()
            return "playlist-np-resume"
        end,
        storage_root = function()
            return root
        end,
    }
end

package.loaded["sync_config"] = {
    status = function()
        return {
            configured = true,
            started = true,
            connected = true,
            server_url = "http://localhost",
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
    content_generation = function()
        return 0
    end,
    state_generation = function()
        return 0
    end,
}

local played_track = nil
local queue_tracks = {}

package.loaded["jellyfin_playback"] = {
    play = function(track, context)
        played_track = track
        queue_tracks =
            context and
            context.queue_tracks or
            {track}
        return true
    end,
    play_queue = function(tracks)
        queue_tracks = tracks or {}
        played_track = queue_tracks[1]
        return true
    end,
    current = function()
        return played_track and {
            track = played_track,
            item = played_track,
            generation = 1,
            queue = {
                items = queue_tracks,
                position = 1,
            },
        } or nil
    end,
    local_item = function(track)
        return track
    end,
}

local NowPlaying =
    screen:new {
        create_ui = function(self)
            self.root =
                lvgl.Object(nil, {
                    w = 160,
                    h = 128,
                    pad_all = 0,
                    border_width = 0,
                })

            self.button =
                self.root:Button {
                    x = 20,
                    y = 48,
                    w = 120,
                    h = 28,
                }
        end,
        on_show = function(self)
            require("jellyfin_playback_session")
                .set_now_playing_visible(true)
            lvgl.group.get_default()
                :add_obj(self.button)
            lvgl.group.focus_obj(
                self.button
            )
        end,
        on_hide = function(self)
            require("jellyfin_playback_session")
                .set_now_playing_visible(false)
        end,
    }

package.loaded["jellyfin_now_playing"] = {
    new = function()
        return NowPlaying:new()
    end,
}

local tracks = {}

for index = 1, 30 do
    -- Mix numeric and string stable IDs across the list.
    local raw_id

    if index == 12 then
        raw_id = 12012
    else
        raw_id = string.format(
            "playlist-track-%03d",
            index
        )
    end

    tracks[index] = {
        id = raw_id,
        jellyfin_id = raw_id,
        title = string.format(
            "Track %03d",
            index
        ),
        artist = "Playlist Artist",
        album = "Playlist Album",
        local_path =
            "/tmp/playlist-track-" ..
            tostring(index) ..
            ".mp3",
        artwork = {
            thumbnail =
                "//lua/img/playlist_placeholder.png",
        },
    }
end

local library = {
    favorites = {
        name = "Favorites",
        track_count = #tracks,
        items = tracks,
    },
    playlists = {
        {
            id = "playlist-resume",
            local_id = "playlist-resume",
            name = "Resume Playlist",
            track_count = #tracks,
            items = tracks,
        },
    },
}

package.loaded["sync_library_view"] = {
    current = function()
        return library
    end,
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {
            artists = {},
            albums = {},
            tracks = tracks,
            counts = {
                artists = 0,
                albums = 0,
                tracks = #tracks,
            },
        }
    end,
}

for _, module_name in ipairs({
    "jellyfin_sort",
    "jellyfin_marquee",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_virtual_track_list",
    "jellyfin_mini_player",
    "jellyfin_collection_playback",
    "jellyfin_track_action_sheet",
    "jellyfin_track_identity",
    "jellyfin_playback_session",
    "jellyfin_library",
}) do
    package.loaded[module_name] = nil
end

local library_module =
    dofile("lua/jellyfin_library.lua")
local backstack = firmware_backstack

local playlist_screen =
    library_module.Collection:new {
        title = "Resume Playlist",
        collection_kind = "playlist",
        collection_id = "playlist-resume",
    }

backstack.reset(playlist_screen)
backstack.flush(12)

local virtual =
    assert(
        playlist_screen.virtual_track_list,
        "Playlist must use a virtual track list"
    )

assert(
    playlist_screen.play_row ~= nil,
    "Playlist must expose the Play control"
)

local function assert_first_frame_restored(
    label,
    expected
)
    assert(
        backstack.current() ==
            playlist_screen,
        label ..
            ": Escape did not restore the playlist"
    )

    assert(
        playlist_screen.selected_item_id ==
            expected.focus_id,
        label ..
            ": exact focus was not restored got=" ..
            tostring(
                playlist_screen.selected_item_id
            ) ..
            " expected=" ..
            tostring(expected.focus_id)
    )
    assert(
        virtual.selected_index ==
            expected.selected_index,
        label ..
            ": logical selection index was not restored"
    )

    if expected.focus_id == "control:play" then
        assert(
            backstack.is_focused(
                playlist_screen.play_row.object
            ),
            label .. ": Play focus was not restored"
        )
    else
        local model =
            assert(
                virtual:selected_model(),
                label ..
                    ": selected track row was not mounted"
            )

        assert(
            track_identity.matches_selection(
                expected.track_key,
                model.selection_id
            ),
            label ..
                ": mounted row key mismatch"
        )
        assert(
            model.focused == true and
                backstack.is_focused(model.object),
            label ..
                ": track focus/highlight was not restored"
        )
    end
end

local function open_via_play_button()
    local play_index = nil
    for index, model in ipairs(
        virtual:continuous_leading_rows()
    ) do
        if model == playlist_screen.play_row then
            play_index = index
            break
        end
    end
    assert(play_index, "Play is absent from the logical sequence")
    virtual:continuous_move_to_leading(play_index)
    backstack.flush(2)
    assert(
        playlist_screen.selected_item_id ==
            "control:play",
        "Play control focus did not adopt control:play"
    )
    playlist_screen.play_row.on_click()
    backstack.flush(12)
    assert(
        backstack.current() ~=
            playlist_screen,
        "Play button did not open Now Playing"
    )
end

local function cycle_resume(
    label,
    select_index,
    open_path
)
    local starting =
        assert(
            virtual:continuous_select(
                select_index,
                false
            )
        )

    backstack.flush(2)

    local expected = {
        track_key =
            assert(
                track_identity.key(
                    playlist_screen
                        .selected_item_id
                )
            ),
        selected_index =
            virtual.selected_index,
    }
    expected.focus_id = expected.track_key

    assert(
        expected.track_key ~=
            "control:play",
        label ..
            ": fixture must start on a track row"
    )
    assert(
        expected.track_key:sub(1, 3) ==
            "id:",
        label ..
            ": selection must use canonical track key"
    )

    if open_path == "play_button" then
        open_via_play_button()
        expected.focus_id = "control:play"
    elseif open_path == "track_click" then
        starting.on_click()
        backstack.flush(12)
    else
        error("unknown open_path")
    end

    backstack.pop()
    backstack.flush(12)

    assert_first_frame_restored(
        label,
        expected
    )

    -- Second round trip must remain stable.
    if open_path == "play_button" then
        open_via_play_button()
    else
        local model =
            assert(virtual:selected_model())
        model.on_click()
        backstack.flush(12)
    end

    backstack.pop()
    backstack.flush(12)
    assert_first_frame_restored(
        label .. " round-trip",
        expected
    )
end

cycle_resume(
    "playlist Play button mid-list",
    18,
    "play_button"
)

cycle_resume(
    "playlist track click",
    10,
    "track_click"
)

cycle_resume(
    "playlist Play button numeric id",
    12,
    "play_button"
)

-- Favorites uses the same Collection screen path.
local favorites_screen =
    library_module.Collection:new {
        title = "Favorites",
        collection_kind = "favorites",
    }

backstack.reset(favorites_screen)
backstack.flush(12)

virtual =
    assert(
        favorites_screen.virtual_track_list
    )
playlist_screen = favorites_screen

cycle_resume(
    "favorites Play button",
    15,
    "play_button"
)

print(
    "Playlist/Favorites Now Playing resume restores canonical track selection"
)
os.exit(0)

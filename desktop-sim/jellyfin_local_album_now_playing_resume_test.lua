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
local root =
    "/tmp/tangara-local-album-np-resume"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

package.loaded["device"] = nil
package.preload["device"] = function()
    return {
        id = function()
            return "local-album-np-resume"
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

package.loaded["sync_library_view"] = {
    current = function()
        return {
            favorites = {
                name = "Favorites",
                items = {},
            },
            playlists = {},
        }
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

for index = 1, 40 do
    tracks[index] = {
        id = string.format(
            "album-track-%03d",
            index
        ),
        jellyfin_id = string.format(
            "album-track-%03d",
            index
        ),
        title = string.format(
            "Track %03d",
            index
        ),
        artist = "Resume Artist",
        album = "Resume Album",
        album_id = "resume-album",
        local_path =
            "/tmp/album-track-" ..
            tostring(index) ..
            ".mp3",
        artwork = {
            thumbnail =
                "//lua/img/playlist_placeholder.png",
            background =
                "//lua/img/background_placeholder.png",
        },
    }
end

local album = {
    key = "id:resume-album",
    id = "resume-album",
    name = "Resume Album",
    tracks = tracks,
    artwork = tracks[1].artwork,
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {
            artists = {},
            albums = {album},
            tracks = tracks,
            counts = {
                artists = 0,
                albums = 1,
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
    "jellyfin_local_artwork",
    "jellyfin_album_identity",
    "jellyfin_playback_session",
    "jellyfin_local_library",
}) do
    package.loaded[module_name] = nil
end

local local_library =
    dofile(
        "lua/jellyfin_local_library.lua"
    )
local backstack = firmware_backstack

-- Exercise the same production entry path as live: mount Local Albums, bind
-- its virtual album row, activate that row, and allow the child screen's
-- native load/focus lifecycle to settle.
local albums_screen =
    local_library.Albums:new()

backstack.reset(albums_screen)
backstack.flush(10)

local album_row =
    assert(
        albums_screen.virtual_album_list:
            continuous_select(1, false),
        "Local Albums did not bind the production album row"
    )

album_row.on_click()
backstack.flush(14)

local album_screen =
    assert(
        backstack.current(),
        "album activation did not push a child screen"
    )

local virtual =
    assert(
        album_screen.virtual_track_list,
        "Local album must use a virtual track list"
    )

assert(
    virtual.fixed_viewport == false and
        virtual.motion_layer == nil,
    "Local album retained the competing fixed viewport owner"
)
assert(
    album_screen.play_row ~= nil,
    "Local album must expose the Play control"
)
assert(
    backstack.is_focused(
        album_screen.play_row.object
    ),
    "First album entry must focus Play (selected=" ..
        tostring(album_screen.selected_item_id) ..
        ", play_model=" ..
        tostring(album_screen.play_row.focused) ..
        ", selected_model=" ..
        tostring(
            virtual:selected_model() and
            virtual:selected_model().selection_id
        ) .. ")"
)

local first_list_coordinates =
    album_screen.list:get_coords()
local first_play_coordinates =
    album_screen.play_row.object:get_coords()
local first_bubble =
    assert(album_screen.selection_motion)

assert(
    album_screen.selected_item_id ==
        "control:play" and
        first_play_coordinates.y1 >=
            first_list_coordinates.y1 and
        first_play_coordinates.y2 <=
            first_list_coordinates.y2 and
        first_bubble.destination_object ==
            album_screen.play_row.object and
        first_bubble.current_rect.y ==
            first_play_coordinates.y1 -
            first_list_coordinates.y1,
    "first rendered album frame did not visibly settle on Play"
)

local function native_viewport_offset()
    album_screen.list:update_layout()
    virtual.canvas:update_layout()
    local list_coordinates =
        album_screen.list:get_coords()
    local canvas_coordinates =
        virtual.canvas:get_coords()

    return
        canvas_coordinates.y1 -
        list_coordinates.y1
end

local function assert_first_frame_restored(
    label,
    expected
)
    assert(
        backstack.current() ==
            album_screen,
        label ..
            ": Escape did not restore the album screen"
    )
    assert(
        album_screen.selected_item_id ==
            expected.track_id,
        label ..
            ": stable track id was not restored"
    )
    assert(
        virtual.selected_index ==
            expected.selected_index,
        label ..
            ": logical selection index was not restored"
    )

    local list_coordinates =
        album_screen.list:get_coords()

    if expected.track_id == "control:play" then
        assert(
            backstack.is_focused(
                album_screen.play_row.object
            ),
            label ..
                ": Play focus was not restored"
        )
    else
        local model =
            assert(
                virtual:selected_model(),
                label ..
                    ": selected track row was not mounted"
            )

        assert(
            model.selection_id ==
                expected.track_id,
            label ..
                ": mounted row id mismatch"
        )
        assert(
            model.focused == true,
            label ..
                ": selection highlight flag missing"
        )
        assert(
            backstack.is_focused(
                model.object
            ),
            label ..
                ": focus-group object was not the restored track"
        )

        local row_coordinates =
            model.object:get_coords()

        assert(
            row_coordinates.y1 >=
                list_coordinates.y1 - 1 and
            row_coordinates.y2 <=
                list_coordinates.y2 + 1,
            string.format(
                "%s: selected track was not inside the usable viewport (row=%d..%d list=%d..%d saved_anchor=%s saved_id=%s selected=%s)",
                label,
                row_coordinates.y1,
                row_coordinates.y2,
                list_coordinates.y1,
                list_coordinates.y2,
                tostring(virtual.resume_anchor_offset_y),
                tostring(virtual.resume_anchor_id),
                tostring(album_screen.selected_item_id)
            )
        )
    end
    assert(
        album_screen.mini_player and
            album_screen.mini_player.visible ==
                true,
        label ..
            ": mini-player should be visible after playback"
    )
    assert(
        list_coordinates.y2 <= 100,
        label ..
            ": mini-player did not reserve list space"
    )

    if expected.viewport_height_unchanged then
        local anchor_object =
            expected.track_id ==
                "control:play" and
                album_screen.play_row.object or
            assert(
                virtual:selected_model(),
                label .. ": restored anchor is not mounted"
            ).object
        local anchor_coordinates =
            anchor_object:get_coords()
        assert(
            anchor_coordinates.y1 -
                list_coordinates.y1 ==
                expected.anchor_offset,
            string.format(
                "%s: selected anchor offset was not restored (actual=%s expected=%s native=%s/%s)",
                label,
                tostring(
                    anchor_coordinates.y1 -
                        list_coordinates.y1
                ),
                tostring(expected.anchor_offset),
                tostring(native_viewport_offset()),
                tostring(expected.viewport_offset)
            )
        )
    end

    assert(
        (virtual.viewport_generation or 0) ==
            expected.viewport_generation,
        label ..
            ": resume started an unsolicited viewport animation"
    )
end

local function open_now_playing_via_play_button()
    assert(album_screen.play_row)
    local play_index = nil
    for index, model in ipairs(
        virtual:continuous_leading_rows()
    ) do
        if model == album_screen.play_row then
            play_index = index
            break
        end
    end
    assert(play_index, "Play is absent from the logical sequence")
    virtual:continuous_move_to_leading(play_index)
    backstack.flush(2)
    assert(
        album_screen.selected_item_id ==
            "control:play",
        "Play control focus did not adopt control:play"
    )
    album_screen.play_row.on_click()
    backstack.flush(12)
    assert(
        backstack.current() ~=
            album_screen,
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

    do
        local list_coordinates =
            album_screen.list:get_coords()
        local row_coordinates =
            starting.object:get_coords()
        assert(
            row_coordinates.y1 >=
                list_coordinates.y1 - 1 and
            row_coordinates.y2 <=
                list_coordinates.y2 + 1,
            string.format(
                "%s: test selection did not enter the viewport before child navigation (row=%d..%d list=%d..%d)",
                label,
                row_coordinates.y1,
                row_coordinates.y2,
                list_coordinates.y1,
                list_coordinates.y2
            )
        )
    end

    local mini_was_visible =
        album_screen.mini_player and
        album_screen.mini_player.visible ==
            true

    local expected = {
        track_id =
            assert(
                album_screen.selected_item_id
            ),
        selected_index =
            virtual.selected_index,
        viewport_offset =
            native_viewport_offset(),
        viewport_height_unchanged =
            mini_was_visible,
        anchor_offset = nil,
        viewport_generation =
            virtual.viewport_generation or 0,
    }

    assert(
        expected.track_id ~=
            "control:play",
        label ..
            ": fixture must start on a track row"
    )

    if open_path == "play_button" then
        open_now_playing_via_play_button()
        expected.track_id = "control:play"
        expected.viewport_offset =
            native_viewport_offset()
        expected.viewport_generation =
            virtual.viewport_generation or 0
    elseif open_path == "hold_right" then
        if not played_track then
            starting.on_click()
            backstack.flush(4)
            backstack.pop()
            backstack.flush(2)
            -- Re-select the intended track after the priming play.
            starting =
                assert(
                    virtual:continuous_select(
                        select_index,
                        false
                    )
                )
            backstack.flush(2)
            expected.track_id =
                album_screen.selected_item_id
            expected.selected_index =
                virtual.selected_index
            expected.viewport_offset =
                native_viewport_offset()
            expected.viewport_height_unchanged =
                album_screen.mini_player and
                album_screen.mini_player.visible ==
                    true
            expected.viewport_generation =
                virtual.viewport_generation or 0
        end

        require("jellyfin_playback_session")
            .open_now_playing()
        backstack.flush(4)
        assert(
            backstack.current() ~=
                album_screen,
            label ..
                ": hold-right did not open Now Playing"
        )
    else
        starting.on_click()
        backstack.flush(4)
        assert(
            backstack.current() ~=
                album_screen,
            label ..
                ": track play did not open Now Playing"
        )
    end

    -- on_hide captures the exact rendered native viewport before the child
    -- transition retires the parent. A still-running Play/track tween may be
    -- interrupted at that point, so the capture—not hidden-screen geometry—is
    -- the restoration contract.
    expected.viewport_offset =
        virtual.resume_native_offset_y or
        expected.viewport_offset
    expected.anchor_offset =
        virtual.resume_anchor_offset_y

    -- Advance the queue while Now Playing is open. Resume must still restore
    -- the album row selected before entry, not the currently playing track.
    if #queue_tracks > 1 then
        played_track =
            queue_tracks[
                math.min(
                    2,
                    #queue_tracks
                )
            ]
    end

    backstack.pop()

    -- First rendered frame: on_show runs synchronously with pop, before the
    -- firmware backstack loads the restored LVGL screen.
    assert_first_frame_restored(
        label .. " first-frame",
        expected
    )

    backstack.flush(12)
    assert_first_frame_restored(
        label .. " post-repaint",
        expected
    )

    -- The first playback cycle introduces the mini-player and shrinks the
    -- viewport. Capture only after that one layout change has settled; every
    -- subsequent return must preserve this native offset exactly.
    expected.viewport_offset =
        native_viewport_offset()
    do
        local anchor_object =
            expected.track_id ==
                "control:play" and
                album_screen.play_row.object or
            assert(virtual:selected_model()).object
        expected.anchor_offset =
            anchor_object:get_coords().y1 -
            album_screen.list:get_coords().y1
    end
    expected.viewport_height_unchanged =
        true
    expected.viewport_generation =
        virtual.viewport_generation or 0

    return {
        track_id = expected.track_id,
        selected_index =
            expected.selected_index,
        viewport_offset =
            native_viewport_offset(),
    }
end

local first =
    cycle_resume(
        "mid-track play-button",
        18,
        "play_button"
    )

print(
    string.format(
        "first-frame restored selection=%s index=%s viewport=%s",
        tostring(first.track_id),
        tostring(first.selected_index),
        tostring(first.viewport_offset)
    )
)

for cycle = 1, 4 do
    cycle_resume(
        "cycle-" .. tostring(cycle),
        18 + cycle,
        cycle % 2 == 0 and
            "hold_right" or
            "play_button"
    )
end

-- Near-bottom selection with the mini-player already visible.
cycle_resume(
    "bottom-with-mini-player",
    38,
    "hold_right"
)

print(
    "Local album Now Playing Escape resume passed"
)
os.exit(0)

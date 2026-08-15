package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
local metrics = require("sim_metrics")
local backstack = require("firmware_backstack")

lvgl.ImgData = function(path)
    return path
end

local encoder_mode = false

_G.tangara_sim_enable_encoder_handler = true
_G.tangara_sim_set_encoder_mode =
    function(enabled)
        encoder_mode = enabled == true
    end

require("mocks").install(lvgl)

local screen = require("screen")

package.loaded["backstack"] = backstack
package.preload["backstack"] = function()
    return backstack
end

local root =
    "/tmp/tangara-continuous-virtual-scroll"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

package.loaded["device"] = nil
package.preload["device"] = function()
    return {
        id = function()
            return "continuous-virtual-scroll-test"
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

package.loaded["jellyfin_playback"] = {
    play = function(track)
        played_track = track
        return false
    end,
    current = function()
        return nil
    end,
    -- Local library availability checks use local_item() in production.
    -- This fixture models every generated test track as locally playable.
    local_item = function(track)
        return track
    end,
}

package.loaded["jellyfin_now_playing"] = {
    new = function()
        return {}
    end,
}

package.loaded["jellyfin_track_menu"] = {
    new = function()
        return {}
    end,
}

local tracks = {}

for index = 1, 120 do
    tracks[index] = {
        id = string.format(
            "track-%03d",
            index
        ),
        jellyfin_id = string.format(
            "track-%03d",
            index
        ),
        title = string.format(
            "Track %03d",
            index
        ),
        artist = string.format(
            "Artist %03d",
            index
        ),
        album = string.format(
            "Album %03d",
            index
        ),
        artwork = {
            thumbnail =
                "//lua/img/playlist_placeholder.png",
        },
    }
end

local library = {
    artists = {},
    albums = {},
    tracks = tracks,
    counts = {
        artists = 0,
        albums = 0,
        tracks = #tracks,
    },
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return library
    end,
}

for _, module_name in ipairs({
    "jellyfin_sort",
    "jellyfin_marquee",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_virtual_track_list",
    "jellyfin_local_library",
}) do
    package.loaded[module_name] = nil
end

local local_library =
    dofile(
        "lua/jellyfin_local_library.lua"
    )

package.loaded["jellyfin_local_library"] =
    local_library

local tracks_screen =
    local_library.Tracks:new()

backstack.reset(tracks_screen)
backstack.flush(12)

local virtual =
    assert(
        tracks_screen.virtual_track_list
    )
local initial_metrics = metrics.snapshot()

assert(
    virtual.continuous_input_active == true,
    "continuous virtual scrolling was not installed"
)
assert(
    encoder_mode == true and
        type(_G.tangara_sim_encoder_event) ==
            "function",
    "continuous virtual scrolling did not claim raw encoder input"
)
assert(
    virtual:pool_count() == 7,
    "continuous virtual scrolling changed the seven-row pool"
)
assert(
    virtual.fixed_viewport == true and
        virtual.motion_layer ~= nil,
    "long local Tracks did not adopt the shared fixed viewport"
)

local function assert_unique_bindings(label)
    local used = {}

    for _, model in ipairs(
        virtual.pool
    ) do
        local index =
            assert(
                model.virtual_index,
                label ..
                    ": row missing logical index"
            )

        assert(
            not used[index],
            label ..
                ": duplicate logical row " ..
                tostring(index)
        )
        used[index] = true
    end
end

local function assert_viewport_covered(label)
    local list_coordinates =
        tracks_screen.list:get_coords()
    local intervals = {}

    local function add_visible_object(object)
        if not object then
            return
        end

        local coordinates =
            object:get_coords()

        if coordinates.y2 >=
                list_coordinates.y1 and
            coordinates.y1 <=
                list_coordinates.y2 then
            table.insert(
                intervals,
                {
                    y1 = math.max(
                        coordinates.y1,
                        list_coordinates.y1
                    ),
                    y2 = math.min(
                        coordinates.y2,
                        list_coordinates.y2
                    ),
                }
            )
        end
    end

    -- Sort and Play are real visible rows at the beginning of the same
    -- scrollable list. At intermediate offsets such as y=25, Play covers
    -- the top of the viewport while the virtual media rows cover the rest.
    -- Count both kinds of row so this remains a true black-gap test instead
    -- of incorrectly treating a visible leading control as empty space.
    for _, model in ipairs(
        tracks_screen.leading_rows or {}
    ) do
        add_visible_object(model.object)
    end

    for _, model in ipairs(
        virtual.pool
    ) do
        add_visible_object(model.object)
    end

    table.sort(
        intervals,
        function(left, right)
            return left.y1 < right.y1
        end
    )

    assert(
        #intervals >= 3,
        label ..
            ": fewer than three rows intersect the viewport"
    )

    local cursor = list_coordinates.y1
    local largest_gap = 0

    for _, interval in ipairs(
        intervals
    ) do
        if interval.y1 > cursor then
            largest_gap =
                math.max(
                    largest_gap,
                    interval.y1 - cursor
                )
        end

        cursor =
            math.max(
                cursor,
                interval.y2 + 1
            )
    end

    if cursor <= list_coordinates.y2 then
        largest_gap =
            math.max(
                largest_gap,
                list_coordinates.y2 -
                    cursor + 1
            )
    end

    assert(
        largest_gap <=
            virtual.row_gap + 3,
        label ..
            ": viewport exposed a " ..
            tostring(largest_gap) ..
            "-pixel black gap"
    )

    assert_unique_bindings(label)
end

local function assert_fixed_motion_window(
    label
)
    local canvas_coordinates =
        virtual.canvas:get_coords()
    local motion_coordinates =
        virtual.motion_layer:get_coords()
    local relative_y =
        motion_coordinates.y1 -
        canvas_coordinates.y1
    local base_y =
        virtual.fixed_base_y or 0

    assert(
        math.abs(relative_y - base_y) <=
            virtual.row_stride,
        label ..
            ": fixed motion layer moved farther than one row"
    )

    assert(
        motion_coordinates.y1 <=
            canvas_coordinates.y1 and
        motion_coordinates.y2 >=
            canvas_coordinates.y2,
        label ..
            ": fixed motion layer does not cover the clipped viewport"
    )
end

assert_viewport_covered("initial viewport")

virtual:continuous_refresh_coverage()
assert(
    virtual:continuous_refresh_coverage() == false,
    "a settled viewport should not reposition or rebind the seven rows"
)

_G.tangara_sim_encoder_event(-40)

assert(
    virtual.selected_index == 41,
    "a Local-Library-direction forward burst should immediately target logical index 41"
)
assert(
    virtual.continuous_focus_model and
        virtual.continuous_focus_model
            .virtual_index == 41,
    "the focused reusable row did not retarget directly to logical index 41"
)
assert(
    virtual.manual_pending_steps == nil,
    "continuous retargeting must not create the old input queue"
)
assert_viewport_covered(
    "immediate forward retarget"
)
assert_fixed_motion_window(
    "immediate forward retarget"
)

backstack.flush(3)
assert_viewport_covered(
    "forward animation frames"
)
assert_fixed_motion_window(
    "forward animation frames"
)

_G.tangara_sim_encoder_event(27)

assert(
    virtual.selected_index == 14,
    "the opposite raw direction should immediately retarget logical index 14"
)
assert_viewport_covered(
    "immediate reverse retarget"
)
assert_fixed_motion_window(
    "immediate reverse retarget"
)

local real_is_scrolling =
    virtual.continuous_is_scrolling
virtual.continuous_is_scrolling =
    function()
        return true
    end
virtual:continuous_retarget(1)
assert(
    virtual.selected_index == 15,
    "interrupted animation did not apply the next logical step immediately"
)
assert_viewport_covered(
    "interrupted forward animation"
)
assert_fixed_motion_window(
    "interrupted forward animation"
)
virtual:continuous_retarget(-1)
assert(
    virtual.selected_index == 14,
    "interrupted reverse animation did not restore the logical selection"
)
assert_viewport_covered(
    "interrupted reverse animation"
)
assert_fixed_motion_window(
    "interrupted reverse animation"
)
virtual.continuous_is_scrolling =
    real_is_scrolling

backstack.flush(3)
assert_viewport_covered(
    "reverse animation frames"
)
assert_fixed_motion_window(
    "reverse animation frames"
)

_G.tangara_sim_encoder_event(100)

assert(
    virtual.continuous_at_sort == true and
        tracks_screen.focus_group
            :get_focused() ==
            tracks_screen.sort_row.object,
    "scrolling above logical item 1 should focus Sort"
)

_G.tangara_sim_encoder_event(-1)

assert(
    virtual.selected_index == 1 and
        virtual.continuous_at_sort == false,
    "one step below Sort should target logical item 1"
)

assert(
    virtual:continuous_is_scrolling(),
    "moving from a leading control into fixed item 1 should animate instead of snap"
)

_G.tangara_sim_encoder_event(-24)

assert(
    virtual.selected_index == 25,
    "the post-Sort burst should target logical item 25"
)

virtual.continuous_focus_model.on_click()

assert(
    played_track and
        played_track.id ==
            virtual.items[25].id,
    "activating after a rapid retarget selected the wrong track"
)

tracks_screen.open_sort_menu()

assert(
    virtual.continuous_input_suspended == true and
        encoder_mode == false and
        _G.tangara_sim_encoder_event == nil,
    "opening Sort should suspend continuous encoder handling"
)

tracks_screen.close_sort_menu(false)

assert(
    virtual.continuous_input_suspended == false and
        encoder_mode == true and
        _G.tangara_sim_encoder_event ==
            virtual.continuous_encoder_callback,
    "closing Sort should restore the same continuous encoder callback"
)

local final_metrics = metrics.snapshot()

assert(
    final_metrics.active_objects ==
        initial_metrics.active_objects,
    "continuous virtual scrolling changed the active LVGL object count"
)
assert(
    virtual:pool_count() == 7,
    "continuous virtual scrolling changed the fixed row pool"
)

os.execute("rm -rf " .. root)

print(
    "Continuous virtual scrolling retargets bursts through the shared covered fixed viewport and keeps seven rows"
)

os.exit(0)

package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
local backstack =
    require("firmware_backstack")
local metrics = require("sim_metrics")

local small_cover =
    "/desktop-sim/sd/jellyfin-library-ui/" ..
    ".tangara-artwork/albums/" ..
    "3d698c5103e705965c5965d8ba385a1d-sq28.png"
local large_cover =
    "/desktop-sim/sd/jellyfin-library-ui/" ..
    ".tangara-artwork/albums/" ..
    "3d698c5103e705965c5965d8ba385a1d-sq66.png"

lvgl.ImgData = function(path)
    return path
end

_G.tangara_sim_enable_encoder_handler = true
_G.tangara_sim_set_encoder_mode =
    function()
    end

require("mocks").install(lvgl)

package.loaded["backstack"] = backstack
package.preload["backstack"] = function()
    return backstack
end

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

local current_track = nil
local current_session = nil

package.loaded["jellyfin_playback_session"] = {
    current = function()
        return current_session
    end,
    open_now_playing = function()
        return false
    end,
    capture_track_list_resume = function()
        return nil
    end,
    restore_track_list_resume = function()
        return nil
    end,
    clear_track_list_resume_lock = function()
    end,
    track_selection_key = function(track)
        if type(track) == "table" then
            return "id:" .. tostring(
                track.id or
                track.jellyfin_id or
                ""
            )
        end
        return track and ("id:" .. tostring(track)) or nil
    end,
}

package.loaded["jellyfin_playback"] = {
    local_item = function(track)
        return track
    end,
    play = function(track)
        current_track = track
        track.artwork = track.artwork or {}
        track.artwork.thumbnail = nil
        track.artwork.cover = large_cover
        current_session = {
            id = 1,
            track_id = track.id,
            queue_index = 1,
            position = 0,
            paused = false,
            metadata = {
                title = track.title,
                artist = track.artist,
                duration = track.duration or 225,
            },
            artwork = {
                foreground = large_cover,
            },
        }
        return true
    end,
    play_queue = function()
        return false
    end,
    current = function()
        return current_track
    end,
}

local screen = require("screen")
local NowPlaying =
    screen:new {
        create_ui = function(self)
            self.root =
                lvgl.Object(nil, {
                    w = 160,
                    h = 128,
                    pad_all = 0,
                    border_width = 0,
                    bg_color = 0,
                    bg_opa = 255,
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
            lvgl.group.get_default()
                :add_obj(self.button)
            lvgl.group.focus_obj(
                self.button
            )
        end,
    }

package.loaded["jellyfin_now_playing"] = {
    new = function()
        return NowPlaying:new()
    end,
}

package.loaded["jellyfin_track_action_sheet"] = {
    attach = function(owner)
        owner.track_action_sheet = {
            is_open = false,
            open = function() end,
            close = function() end,
        }
        return owner.track_action_sheet
    end,
}

local tracks = {}

for index = 1, 80 do
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
        artist = "Resume Artist",
        artist_key = "artist-resume",
        album = "Resume Album",
        album_id = "album-resume",
        album_key = "album-resume",
        artwork = {
            thumbnail = small_cover,
        },
    }
end

local album = {
    key = "album-resume",
    id = "album-resume",
    name = "Resume Album",
    artist = "Resume Artist",
    track_count = #tracks,
    tracks = tracks,
    artwork = {
        thumbnail = small_cover,
    },
}
local artist = {
    key = "artist-resume",
    id = "artist-resume",
    name = "Resume Artist",
    release_count = 1,
    track_count = #tracks,
    releases = {album},
}
local local_library = {
    artists = {artist},
    albums = {album},
    tracks = tracks,
    counts = {
        artists = 1,
        albums = 1,
        tracks = #tracks,
    },
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return local_library
    end,
}

local playlist_tracks = {}

for index, track in ipairs(tracks) do
    local entry = {}

    for key, value in pairs(track) do
        entry[key] = value
    end

    entry.playlist_entry_id =
        string.format("entry-%03d", index)
    entry.artwork = {
        thumbnail = small_cover,
    }
    playlist_tracks[index] = entry
end

package.loaded["sync_library_view"] = {
    current = function()
        return {
            favorites = {
                name = "Favorites",
                items = playlist_tracks,
            },
            playlists = {
                {
                    id = "playlist-resume",
                    local_id =
                        "playlist-resume",
                    name = "Resume Playlist",
                    track_count =
                        #playlist_tracks,
                    items = playlist_tracks,
                },
            },
        }
    end,
}

for _, module_name in ipairs({
    "jellyfin_sort",
    "jellyfin_marquee",
    "jellyfin_scroll_indicator",
    "jellyfin_list_ui",
    "jellyfin_mini_player",
    "jellyfin_collection_playback",
    "jellyfin_virtual_list",
    "jellyfin_virtual_track_list",
    "jellyfin_local_library",
    "jellyfin_library",
}) do
    package.loaded[module_name] = nil
end

local local_module =
    dofile("lua/jellyfin_local_library.lua")
local playlist_module =
    dofile("lua/jellyfin_library.lua")

local surfaces = {
    {
        name = "Favorites",
        create = function()
            return playlist_module.Collection:new {
                title = "Favorites",
                collection_kind =
                    "favorites",
            }
        end,
    },
    {
        name = "Tracks",
        create = function()
            return local_module.Tracks:new()
        end,
    },
    {
        name = "album tracks",
        create = function()
            return local_module.Album:new {
                title = "Resume Album",
                album_key = "album-resume",
            }
        end,
    },
    {
        name = "playlist",
        create = function()
            return playlist_module.Collection:new {
                title = "Resume Playlist",
                collection_kind = "playlist",
                collection_id =
                    "playlist-resume",
            }
        end,
    },
}

local function reset_artwork()
    album.artwork = {
        thumbnail = small_cover,
    }

    for _, track in ipairs(tracks) do
        track.artwork = {
            thumbnail = small_cover,
        }
    end

    for _, track in ipairs(playlist_tracks) do
        track.artwork = {
            thumbnail = small_cover,
        }
    end
end

local function settle(passes)
    for _ = 1, passes or 3 do
        -- Match the normal simulator's timer cadence. A zero-time burst of
        -- lv_timer_handler calls does not reach LVGL's refresh period and can
        -- inspect the direct framebuffer before the invalidated area draws.
        metrics.wait_ms(12)
        backstack.flush(1)
    end
end

local function rectangle_pixels(
    frame,
    rectangle
)
    local x1 = math.max(0, rectangle.x1)
    local x2 = math.min(
        frame.width - 1,
        rectangle.x2
    )
    local y1 = math.max(0, rectangle.y1)
    local y2 = math.min(
        frame.height - 1,
        rectangle.y2
    )
    local chunks = {}

    for y = y1, y2 do
        local start =
            y * frame.stride +
            x1 * 2 + 1
        local finish =
            y * frame.stride +
            (x2 + 1) * 2

        chunks[#chunks + 1] =
            frame.pixels:sub(
                start,
                finish
            )
    end

    return table.concat(chunks)
end

local function foreground_pixel_count(
    pixels,
    background
)
    local count = 0

    for offset = 1, #pixels, 2 do
        if pixels:sub(
                offset,
                offset + 1
            ) ~= background then
            count = count + 1
        end
    end

    return count
end

local function visible_row_snapshots(
    owner,
    controller,
    frame
)
    local viewport =
        owner.list:get_coords()
    local snapshots = {}

    for _, model in ipairs(controller.pool) do
        local coordinates =
            model.object:get_coords()

        if model.object:is_visible() and
            coordinates.y2 >= viewport.y1 and
            coordinates.y1 <= viewport.y2 then
            local clipped = {
                x1 = math.max(
                    viewport.x1,
                    coordinates.x1
                ),
                x2 = math.min(
                    viewport.x2,
                    coordinates.x2
                ),
                y1 = math.max(
                    viewport.y1,
                    coordinates.y1
                ),
                y2 = math.min(
                    viewport.y2,
                    coordinates.y2
                ),
            }

            snapshots[model.selection_id] = {
                index = model.virtual_index,
                coordinates = clipped,
                pixels = nil,
            }
            snapshots[model.selection_id]
                .pixels =
                rectangle_pixels(
                    frame,
                    clipped
                )
            snapshots[model.selection_id]
                .foreground =
                foreground_pixel_count(
                    snapshots[
                        model.selection_id
                    ].pixels,
                    frame.pixels:sub(1, 2)
                )
        end
    end

    assert(
        next(snapshots) ~= nil,
        "fixture has no painted visible rows"
    )

    return snapshots
end

local function assert_fitted_thumbnail(
    artwork,
    label
)
    assert(
        artwork and artwork.image,
        label .. ": artwork image missing"
    )

    local thumbnail_size = 19
    local geometry =
        metrics.image_geometry(
            artwork.image
        )
    local scaled_width =
        geometry.decoded_width *
            geometry.zoom / 256
    local scaled_height =
        geometry.decoded_height *
            geometry.zoom / 256

    assert(
        geometry.width == thumbnail_size and
        geometry.height == thumbnail_size and
        geometry.parent_width == thumbnail_size and
        geometry.parent_height == thumbnail_size,
        label ..
            ": image or artwork frame is not compact"
    )
    assert(
        geometry.clip_x2 -
            geometry.clip_x1 + 1 ==
                thumbnail_size and
        geometry.clip_y2 -
            geometry.clip_y1 + 1 ==
                thumbnail_size,
        label ..
            ": thumbnail is clipped smaller than its frame"
    )
    assert(
        geometry.size_mode ==
            lvgl.IMAGE_ALIGN.CENTER and
        geometry.alignment ==
            lvgl.ALIGN.TOP_LEFT and
        geometry.offset_x == 0 and
        geometry.offset_y == 0 and
        geometry.rotation == 0 and
        geometry.transform_width == 0 and
        geometry.transform_height == 0,
        label ..
            ": canonical alignment/transform state was not restored"
    )
    assert(
        geometry.pivot_x ==
            math.floor(
                geometry.decoded_width / 2
            ) and
        geometry.pivot_y ==
            math.floor(
                geometry.decoded_height / 2
            ),
        label ..
            ": pivot is not centered on decoded artwork"
    )
    assert(
        scaled_width <=
            thumbnail_size + 1 and
        scaled_height <=
            thumbnail_size + 1 and
        math.max(
            scaled_width,
            scaled_height
        ) >= thumbnail_size - 1,
        label ..
            ": decoded cover is cropped instead of fitted"
    )
    assert(
        artwork.cache_key ==
            artwork.current_source,
        label ..
            ": artwork cache key does not match bound source"
    )

    return geometry
end

local function artwork_frame_snapshot(
    artwork,
    frame
)
    local coordinates =
        artwork.frame:get_coords()
    local pixels =
        rectangle_pixels(
            frame,
            coordinates
        )

    return {
        coordinates = coordinates,
        foreground =
            foreground_pixel_count(
                pixels,
                frame.pixels:sub(1, 2)
            ),
    }
end

for _, surface in ipairs(surfaces) do
    reset_artwork()
    current_track = nil
    current_session = nil
    local owner = surface.create()
    backstack.reset(owner)
    settle(5)

    local controller =
        assert(owner.virtual_track_list)
    local selected_model =
        assert(
            controller:continuous_select(
                25,
                false
            )
        )

    settle(3)

    -- Validate the full-height list before playback, but establish the
    -- repeatable framebuffer baseline only after the mini-player has reduced
    -- the viewport on the first Back cycle.
    visible_row_snapshots(
        owner,
        controller,
        metrics.framebuffer()
    )
    local selected_artwork =
        selected_model.artwork
    local before_thumbnail_geometry =
        selected_artwork and
        assert_fitted_thumbnail(
            selected_artwork,
            surface.name .. " before Back"
        ) or nil
    local before_thumbnail_frame =
        selected_artwork and
        artwork_frame_snapshot(
            selected_artwork,
            metrics.framebuffer()
        ) or nil
    local selected_id =
        assert(owner.selected_item_id)
    local selected_index =
        controller.selected_index
    local resumed_anchor_y = nil
    local resumed_baseline = nil
    local expected_selected_image_object = nil
    local expected_thumbnail_geometry = nil
    local expected_thumbnail_frame = nil

    for cycle = 1, 5 do
        local model =
            assert(controller:selected_model())
        local before_bind_generation =
            model.artwork and
            model.artwork.bind_generation or
            nil

        model.on_click()
        settle(12)
        assert(
            backstack.current() ~= owner,
            surface.name ..
                ": Now Playing was not pushed"
        )

        backstack.pop()

        assert(
            backstack.current() == owner,
            surface.name ..
                ": Back did not restore parent"
        )

        -- The parent state is restored synchronously, while its framebuffer
        -- becomes authoritative after the inverse screen transition settles.
        settle(12)

        assert(
            owner.mini_player:state().visible and
            owner.mini_player:state().list_height == 72,
            surface.name ..
                ": returning from first playback did not reserve mini-player space"
        )

        assert(
            owner.selected_item_id ==
                selected_id and
            controller.selected_index ==
                selected_index,
            surface.name ..
                ": Back changed selected track"
        )

        local resumed_model =
            assert(controller:selected_model())
        local resumed_list_coordinates =
            owner.list:get_coords()
        local resumed_row_coordinates =
            resumed_model.object:get_coords()
        local anchor_y =
            resumed_row_coordinates.y1 -
            resumed_list_coordinates.y1

        if cycle == 1 then
            -- Starting playback makes the mini-player visible for the first
            -- time and intentionally shrinks the list viewport from 100 to 72.
            -- Establish the resized viewport as the resume baseline; later
            -- Back cycles must not drift away from it.
            resumed_anchor_y = anchor_y
        else
            assert(
                anchor_y == resumed_anchor_y,
                string.format(
                    "%s: Back drifted the post-mini-player selected-row anchor (%s/%s)",
                    surface.name,
                    tostring(anchor_y),
                    tostring(resumed_anchor_y)
                )
            )
        end
        assert(
            backstack.is_focused(
                controller:selected_model()
                    .object
            ),
            surface.name ..
                ": Back did not restore focus"
        )

        local painted =
            visible_row_snapshots(
                owner,
                controller,
                metrics.framebuffer()
            )
        local restored_model =
            assert(controller:selected_model())
        if selected_artwork then
            local after_geometry =
                assert_fitted_thumbnail(
                    restored_model.artwork,
                    surface.name ..
                        " cycle " ..
                        tostring(cycle)
                )
            local after_thumbnail_frame =
                artwork_frame_snapshot(
                    restored_model.artwork,
                    metrics.framebuffer()
                )

            local restored_image_object =
                tostring(
                    restored_model.artwork.image
                )

            if cycle == 1 then
                -- The viewport resize can remap the selected logical item to a
                -- different existing pool slot. Preserve that post-resize slot
                -- identity; subsequent Now Playing cycles must reuse it.
                expected_selected_image_object =
                    restored_image_object
                expected_thumbnail_geometry =
                    after_geometry
                expected_thumbnail_frame =
                    after_thumbnail_frame

                assert(
                    type(
                        restored_model.artwork
                            .bind_generation
                    ) == "number",
                    surface.name ..
                        ": resized selected artwork was not rebound"
                )
            else
                assert(
                    restored_image_object ==
                        expected_selected_image_object,
                    surface.name ..
                        ": pooled list image object changed after the mini-player layout stabilized"
                )
                assert(
                    restored_model.artwork
                        .bind_generation >
                        before_bind_generation,
                    surface.name ..
                        ": unchanged artwork binding did not reset geometry"
                )
                assert(
                    after_geometry.x ==
                        expected_thumbnail_geometry.x and
                    after_geometry.y ==
                        expected_thumbnail_geometry.y and
                    after_thumbnail_frame
                        .coordinates.x1 ==
                        expected_thumbnail_frame
                            .coordinates.x1 and
                    after_thumbnail_frame
                        .coordinates.y1 ==
                        expected_thumbnail_frame
                            .coordinates.y1,
                    surface.name ..
                        ": selected thumbnail moved after the mini-player layout stabilized expected=" ..
                        tostring(expected_thumbnail_geometry.x) .. "," ..
                        tostring(expected_thumbnail_geometry.y) ..
                        " got=" .. tostring(after_geometry.x) .. "," ..
                        tostring(after_geometry.y)
                )
            end
            local expected_foreground =
                cycle == 1 and 1 or
                math.max(
                    1,
                    math.floor(
                        expected_thumbnail_frame
                            .foreground * 0.5
                    )
                )

            assert(
                after_thumbnail_frame.foreground >=
                    expected_foreground,
                surface.name ..
                    ": selected thumbnail framebuffer region was not repainted"
            )

            for _, sibling in ipairs(
                controller.pool
            ) do
                if sibling ~= restored_model and
                    sibling.artwork and
                    sibling.object:is_visible() then
                    assert_fitted_thumbnail(
                        sibling.artwork,
                        surface.name ..
                            " sibling cycle " ..
                            tostring(cycle)
                    )
                    break
                end
            end
        end

        if cycle == 1 then
            resumed_baseline = painted
        else
            for id, expected in pairs(
                resumed_baseline
            ) do
                local actual = painted[id]

                assert(
                    actual ~= nil,
                    surface.name ..
                        ": visible row was not bound after Back: " ..
                        tostring(id)
                )
                assert(
                    actual.index == expected.index and
                    actual.coordinates.x1 ==
                        expected.coordinates.x1 and
                    actual.coordinates.x2 ==
                        expected.coordinates.x2 and
                    actual.coordinates.y1 ==
                        expected.coordinates.y1 and
                    actual.coordinates.y2 ==
                        expected.coordinates.y2,
                    surface.name ..
                        ": visible row geometry changed after the mini-player layout stabilized"
                )
                if expected.coordinates.y2 -
                        expected.coordinates.y1 + 1 >=
                        4 then
                    assert(
                        actual.foreground >=
                            math.max(
                                1,
                                math.floor(
                                    expected.foreground *
                                        0.6
                                )
                            ),
                        surface.name ..
                            ": final framebuffer did not repaint row " ..
                            tostring(id) ..
                            " before wheel input (foreground " ..
                            tostring(actual.foreground) ..
                            "/" ..
                            tostring(expected.foreground) ..
                            ")"
                    )
                end
            end
        end
    end
end

print(
    "Favorites, Tracks, album tracks, and playlist repaint every visible native-viewport row after five real Now Playing Back cycles"
)
os.exit(0)

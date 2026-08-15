dofile("desktop-sim/jellyfin_library.lua")

local audio = require("sim_audio")
local backstack = require("backstack")
local native_backstack =
    require("firmware_backstack")
local index = require("jellyfin_local_index")
local jellyfin_playback = require("jellyfin_playback")
local local_library = require("jellyfin_local_library")
local metrics = require("sim_metrics")
local playback = require("playback")
local session = require("jellyfin_playback_session")
local volume = require("volume")

local library = assert(index.load())
local tracks = {}

for _, track in ipairs(library.tracks or {}) do
    if track.album_id ==
            "3d698c5103e705965c5965d8ba385a1d" and
        type(track.local_path) == "string" then
        local path =
            "desktop-sim/sd/jellyfin-library-ui" ..
            track.local_path
        local file = io.open(path, "rb")

        if file then
            local size = file:seek("end")
            file:close()

            if size and size > 1000000 then
                table.insert(tracks, track)
            end
        end
    end
end

table.sort(tracks, function(left, right)
    return (left.track_number or 0) <
        (right.track_number or 0)
end)

assert(#tracks >= 3,
    "stress test requires three distinct real Local FLAC files")

local parent = local_library.Tracks:new()
backstack.push(parent)

assert(jellyfin_playback.play(
    tracks[1],
    {
        collection_kind = "local_tracks",
        queue_tracks = {
            tracks[1],
            tracks[2],
            tracks[3],
        },
    }
))

local baseline = metrics.snapshot()
local initial_session = assert(session.current())
local seen = {
    [initial_session.track_id] = true,
}
local descriptors = {}
local last_consumed = 0
local last_decoder_path = nil

for transition = 1, 100 do
    assert(audio.play())
    local status = audio.poll()
    local frames = math.max(
        1,
        math.floor(status.sample_rate / 10)
    )
    local progressed = audio.pump(frames)
    local decoder_path = assert(
        _G.tangara_sim_local_playback_state
    ).decoder_path

    assert(decoder_path ~= last_decoder_path or
        progressed.consumed_frames >= last_consumed,
        "audio frame clock moved backwards without a track change")
    last_consumed = progressed.consumed_frames
    last_decoder_path = decoder_path

    if transition % 7 == 0 then
        audio.pause()
        local paused = audio.poll()
        audio.pump(frames)
        assert(audio.poll().consumed_frames ==
            paused.consumed_frames)
        audio.play()
    end

    if transition % 9 == 0 then
        assert(audio.seek(5 + transition % 20))
    end

    volume.current_pct:set(
        20 + transition % 70
    )

    if transition % 5 == 0 then
        assert(jellyfin_playback.previous())
    else
        assert(jellyfin_playback.next())
    end

    local current = assert(session.current())
    local simulator = assert(
        _G.tangara_sim_local_playback_state
    )
    local queue_item = assert(
        current.queue.items[current.queue_index]
    )

    assert(queue_item.id == current.track_id)
    assert(queue_item.title == current.metadata.title)
    assert(simulator.decoder_path ==
        current.resolved_local_path)
    assert(simulator.decoder_open == true)
    assert(current.artwork.foreground)
    assert(current.artwork.background)
    seen[current.track_id] = true

    assert(session.open_now_playing())
    local player = backstack.current()
    player.root:update_layout()
    player.root:invalidate()
    native_backstack.flush(3)
    local artwork = player.view:artwork_state()
    local cover_geometry = metrics.image_geometry(
        player.view.cover_image
    )
    local background_geometry = metrics.image_geometry(
        player.view.background_image
    )
    local frame = metrics.framebuffer()

    assert(artwork.background.target_width == 160)
    assert(artwork.background.target_height == 128)
    assert(artwork.clip.x1 == 0 and artwork.clip.y1 == 0)
    assert(artwork.clip.x2 == 159 and artwork.clip.y2 == 127)
    assert(background_geometry.transformed_x1 <= 0)
    assert(background_geometry.transformed_y1 <= 0)
    assert(background_geometry.transformed_x2 >= 159)
    assert(background_geometry.transformed_y2 >= 127)
    assert(type(background_geometry.descriptor) == "string" and
        background_geometry.descriptor ~= "(nil)")
    assert(type(cover_geometry.descriptor) == "string" and
        cover_geometry.descriptor ~= "(nil)")
    assert(#frame.pixels == frame.stride * frame.height)

    local previous_descriptors =
        descriptors[current.track_id]

    if previous_descriptors then
        assert(previous_descriptors.cover ==
            cover_geometry.descriptor)
        assert(previous_descriptors.background ==
            background_geometry.descriptor)
    else
        descriptors[current.track_id] = {
            cover = cover_geometry.descriptor,
            background = background_geometry.descriptor,
        }
    end
    assert(#metrics.missing_glyphs() == 0,
        "Now Playing rendered an unsupported glyph")

    backstack.pop()
    assert(player.status_timer == nil,
        "popped Now Playing did not run on_destroy")
    assert(backstack.current() == parent)
    assert(playback.track:get() ~= nil)
    parent.mini_player:refresh()
    assert(parent.mini_player:state().track_id ==
        current.track_id)

    if transition % 20 == 0 then
        -- Let one-shot volume HUD/status timers retire before checking for
        -- persistent lifecycle growth.
        metrics.wait_ms(1050)
        native_backstack.flush(4)
        collectgarbage("collect")
        local snapshot = metrics.snapshot()

        if snapshot.timers >
                baseline.timers + 3 then
            for _, timer in ipairs(
                metrics.timers()
            ) do
                print(string.format(
                    "TIMER | %s period=%d repeat=%d paused=%s",
                    timer.pointer,
                    timer.period,
                    timer.repeat_count,
                    tostring(timer.paused)
                ))
            end
        end

        assert(snapshot.active_objects <=
            baseline.active_objects + 8,
            "popped Now Playing objects accumulated")
        assert(snapshot.timers <= baseline.timers + 3,
            "popped Now Playing timers accumulated: " ..
                tostring(baseline.timers) .. " -> " ..
                tostring(snapshot.timers))
    end
end

local seen_count = 0
for _ in pairs(seen) do
    seen_count = seen_count + 1
end

assert(seen_count >= 3,
    "stress transitions did not exercise three distinct files")
assert(audio.poll().ok)

local final = metrics.snapshot()
print(string.format(
    "Playback stability passed: transitions=100 files=%d objects=%d->%d " ..
        "timers=%d->%d rss=%dKB->%dKB",
    seen_count,
    baseline.active_objects,
    final.active_objects,
    baseline.timers,
    final.timers,
    baseline.rss_kb,
    final.rss_kb
))
os.exit(0)

dofile("desktop-sim/jellyfin_library.lua")

local backstack = require("backstack")
local index = require("jellyfin_local_index")
local jellyfin_playback = require("jellyfin_playback")
local now_playing = require("jellyfin_now_playing")
local playback = require("playback")
local sim_audio = require("sim_audio")
local lvgl = require("lvgl")

local library = assert(index.load())
local selected
local following

for _, track in ipairs(library.tracks or {}) do
    if track.id ==
            "ce1c15cfac374bfa95508510ec994096" then
        selected = track
    elseif track.id ==
            "cc25acc05e6210f687bd317cd437eeab" then
        following = track
    end
end

assert(selected, "Star Wars Samba is absent from Local")
assert(following, "Local queue needs a second track")

local played, active = jellyfin_playback.play(
    selected,
    {
        source = "tracks",
        queue_tracks = {selected, following},
    }
)

assert(played)
assert(active.track.id == selected.id)

local state = assert(
    _G.tangara_sim_local_playback_state
)
assert(state.file_open)
assert(state.decoder_open)
assert(state.size == 25130793)
assert(state.codec:lower() == "flac")
assert(state.sample_rate == 44100)
assert(state.channels == 2)
assert(state.duration > 225 and state.duration < 226)
assert(state.resolved_path:match(
    "Music/Masayoshi Takanaka/Brasilian Skies/05 Star Wars Samba%.flac$"
))

local metadata = playback.track:get()
assert(metadata.title == "Star Wars Samba")
assert(metadata.artist == "Masayoshi Takanaka")
assert(metadata.album == "Brasilian Skies")
assert(metadata.encoding == "FLAC")
assert(type(metadata.artwork) == "table")

local opened_path = state.resolved_path
local opened_size = state.size
local opened_rate = state.sample_rate
local opened_channels = state.channels
local opened_duration = state.duration
local opened_mode = state.output

local initial_frames = state.consumed_frames
local paused_frames
local resumed_frames
local before_back_frames
local step = 0

lvgl.Timer {
    period = 180,
    cb = function()
        local ok, failure = xpcall(function()
        step = step + 1
        if step == 101 then
            assert(
                state.consumed_frames >
                    before_back_frames
            )
            backstack.pop()
            assert(playback.playing:get() == true)

            print(string.format(
                "Local playback bridge passed: path=%s bytes=%d " ..
                    "rate=%d channels=%d duration=%.3f " ..
                    "mode=%s pause=%d resume=%d next=%s",
                opened_path,
                opened_size,
                opened_rate,
                opened_channels,
                opened_duration,
                opened_mode,
                paused_frames,
                resumed_frames,
                following.title
            ))
            os.exit(0)
        end

        if step == 1 then
            assert(state.consumed_frames > initial_frames)
            assert(state.position > 0)
            playback.playing:set(false)
            paused_frames = state.consumed_frames
        elseif step == 2 then
            assert(state.consumed_frames == paused_frames)
            playback.playing:set(true)
        elseif step == 3 then
            assert(state.consumed_frames > paused_frames)
            resumed_frames = state.consumed_frames
            playback.position:set(90)
        elseif step == 4 then
            assert(state.consumed_frames > resumed_frames)
            assert(math.abs(playback.position:get() - 90) < 1)
            assert(sim_audio.seek(
                opened_duration - 0.01
            ))
        elseif step >= 5 then
            local current = jellyfin_playback.current()

            if current.track.id ~= following.id and
                step < 10 then
                return
            end

            assert(
                current.track.id == following.id,
                "decoder EOF did not advance the existing queue"
            )
            assert(playback.playing:get() == true)

            local tap = sim_audio.analysis()
            assert(tap.sample_rate > 0)
            assert(tap.channels > 0)
            assert(type(tap.pcm_s16le) == "string")

            -- Exercise the actual Now Playing backstack separately from EOF
            -- so the simulator's intentionally persistent property bindings
            -- cannot influence the queue-advance assertion above.
            assert(jellyfin_playback.play(
                selected,
                {
                    source = "tracks",
                    queue_tracks = {selected},
                }
            ))
            backstack.push(now_playing:new())
            before_back_frames =
                state.consumed_frames
            step = 100
        end
        end, debug.traceback)

        if not ok then
            io.stderr:write(failure, "\n")
            os.exit(1)
        end
    end,
}

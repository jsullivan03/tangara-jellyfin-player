dofile("desktop-sim/jellyfin_library.lua")

local backstack = require("backstack")
local index = require("jellyfin_local_index")
local jellyfin_playback = require("jellyfin_playback")
local metrics = require("sim_metrics")
local lvgl = require("lvgl")
local session = require("jellyfin_playback_session")
local sim_audio = require("sim_audio")

local ALBUM_ID =
    "3d698c5103e705965c5965d8ba385a1d"
local STAR_WARS_ID =
    "ce1c15cfac374bfa95508510ec994096"

local library = assert(index.load())
local album

for _, candidate in ipairs(library.albums) do
    if candidate.id == ALBUM_ID then
        album = candidate
        break
    end
end

assert(album and #album.tracks == 8)

for queue_index, track in ipairs(album.tracks) do
    local item = assert(
        jellyfin_playback.local_item(track),
        track.title .. " is not a real Local file"
    )
    local path =
        "desktop-sim/sd/jellyfin-library-ui" ..
        item.local_path
    local file = assert(io.open(path, "rb"))
    local size = assert(file:seek("end"))
    file:close()

    assert(size > 0)
    print(string.format(
        "QUEUE %d | %s | %s | local | %s | bytes=%d",
        queue_index,
        track.title,
        track.id,
        item.local_path,
        size
    ))
end

local selected

for _, track in ipairs(album.tracks) do
    if track.id == STAR_WARS_ID then
        selected = track
        break
    end
end

assert(selected)
assert(jellyfin_playback.play(
    selected,
    {queue_tracks = album.tracks}
))

local simulator = assert(
    _G.tangara_sim_local_playback_state
)

local function checksum(data)
    local value = 0

    for byte_index = 1, #data do
        value = (
            value +
            data:byte(byte_index) * byte_index
        ) % 4294967291
    end

    return value
end

local function fingerprint()
    assert(sim_audio.seek(10))
    assert(sim_audio.play())
    sim_audio.pump(4410)
    local analysis = sim_audio.analysis()

    assert(#analysis.pcm_s16le > 0)
    return checksum(analysis.pcm_s16le)
end

local first = assert(session.current())
local first_path = simulator.decoder_path
local first_duration = simulator.duration
local first_fingerprint = fingerprint()
local first_open_count = simulator.open_count

assert(first.queue_index == 5)
assert(first.track_id == STAR_WARS_ID)
assert(jellyfin_playback.next())

local second = assert(session.current())
local next_transition = simulator.transition
local second_path = simulator.decoder_path
local second_duration = simulator.duration
local second_fingerprint = fingerprint()

assert(second.queue_index == 6)
assert(second.track_id ~= first.track_id)
assert(second_path ~= first_path)
assert(second_duration ~= first_duration)
assert(second_fingerprint ~= first_fingerprint)
assert(next_transition.decoder_before == first_path)
assert(next_transition.decoder_after == second_path)
assert(next_transition.old_decoder_closed == true)
assert(next_transition.new_decoder_opened == true)
assert(simulator.open_count == first_open_count + 1)

local next_open_count = simulator.open_count
assert(jellyfin_playback.previous())
local previous = assert(session.current())
local previous_transition = simulator.transition

assert(previous.queue_index == 5)
assert(previous.track_id == first.track_id)
assert(simulator.decoder_path == first_path)
assert(previous_transition.old_decoder_closed == true)
assert(previous_transition.new_decoder_opened == true)
assert(simulator.open_count == next_open_count + 1)

local before_eof_opens = simulator.open_count
assert(sim_audio.seek(simulator.duration - 0.01))
assert(sim_audio.play())
sim_audio.pump(simulator.sample_rate)

for _ = 1, 5 do
    metrics.wait_ms(10)
end

local attempts = 0

lvgl.Timer {
    period = 50,
    cb = function()
        attempts = attempts + 1
        local after_eof = assert(session.current())

        if after_eof.queue_index ~= 6 and
            attempts < 10 then
            return
        end

        local eof_transition = simulator.transition

        assert(after_eof.queue_index == 6)
        assert(after_eof.track_id == second.track_id)
        assert(simulator.decoder_path == second_path)
        assert(eof_transition.old_decoder_closed == true)
        assert(eof_transition.new_decoder_opened == true)
        assert(simulator.open_count == before_eof_opens + 1)

        print(string.format(
            "Distinct Local queue passed: Star Wars duration=%.3f pcm=%u; " ..
                "%s duration=%.3f pcm=%u; Next/Previous/EOF each reopened the decoder",
            first_duration,
            first_fingerprint,
            second.metadata.title,
            second_duration,
            second_fingerprint
        ))
        os.exit(0)
    end,
}

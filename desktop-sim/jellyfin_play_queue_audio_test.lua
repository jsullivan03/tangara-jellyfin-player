dofile("desktop-sim/jellyfin_library.lua")

local index = require("jellyfin_local_index")
local jellyfin_playback =
    require("jellyfin_playback")
local playback = require("playback")

local ALBUM_ID =
    "3d698c5103e705965c5965d8ba385a1d"
local library = assert(index.load())
local album = nil

for _, candidate in ipairs(
    library.albums or {}
) do
    if candidate.id == ALBUM_ID then
        album = candidate
        break
    end
end

assert(
    album and #album.tracks == 8,
    "Brasilian Skies Local album is unavailable"
)

local played, active =
    jellyfin_playback.play_queue(
        album.tracks,
        {
            collection_kind =
                "play_queue_audio_test",
            collection_id = ALBUM_ID,
        },
        {
            start_index = 1,
            shuffle = false,
        }
    )

assert(played, active)
active = assert(
    jellyfin_playback.current()
)

local simulator = assert(
    _G.tangara_sim_local_playback_state
)

assert(
    simulator.decoder_open == true,
    simulator.audio_error or
        "play_queue did not open the decoder"
)
assert(
    playback.playing:get() == true,
    "play_queue left playback paused"
)
assert(
    simulator.queue_index == 1,
    "play_queue opened the wrong queue index"
)
assert(
    active.track.id ==
        album.tracks[1].id,
    "play_queue did not select the first track"
)
assert(
    simulator.decoder_path ==
        simulator.resolved_path,
    "decoder path does not match the resolved Local file"
)

print(string.format(
    "Collection play_queue audio passed: queue=%d track=%s decoder=%s mode=%s",
    tonumber(simulator.queue_index) or 0,
    tostring(active.track.title),
    tostring(simulator.decoder_path),
    tostring(simulator.output)
))

os.exit(0)
